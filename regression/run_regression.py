#!/usr/bin/env python3.12
"""run_regression.py OUTPUT_DIR --exe BIN --tlist T... --exp E... --mfile M...

Thin orchestrator that reuses the existing create_jobfile.py + rollup.py tooling
to run a Hermes regression over a trace suite and a set of experiments:

  1. create_jobfile.py --local  -> a local parallel jobfile (+ snapshots the exe)
  2. run the jobfile            -> {trace}_{exp}.out/.err in the run directory
  3. rollup.py                  -> stats.csv with the target metrics
  4. compare_runs.py            -> diff vs the most recent previous run

You choose the binary, trace list(s), experiment file(s) and metric file(s) —
exactly like create_jobfile.py — so regression runs on any suite with any
experiments. Runs land in OUTPUT_DIR/hermes_regression/<UTC-ts>[_label]/, where
OUTPUT_DIR lives OUTSIDE this repo (so large dumps are never committed).

Hermes should NOT regress (offchip_pred_location=core) until the predictor is
intentionally enabled at the uncore.

Example:
  ./run_regression.py /home/rahbera/thesis/runs \\
      --exe /home/rahbera/thesis/Hermes/bin/glc-perceptron-no-multi-multi-multi-multi-1core-1ch \\
      --tlist suites/test_suite.tlist.yml \\
      --exp   suites/regression.exp.yml \\
      --mfile suites/regression.mfile.yml
"""

import argparse
import csv
import datetime
import glob
import hashlib
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS = os.path.join(os.path.dirname(_HERE), "scripts")
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import compare_runs  # noqa: E402  (sibling: load_csv, compare, print_table)

CREATE_JOBFILE = os.path.join(_SCRIPTS, "create_jobfile.py")
ROLLUP = os.path.join(_SCRIPTS, "rollup.py")
DEFAULT_HERMES_HOME = "/home/rahbera/thesis/Hermes"

# create_jobfile.py uses argparse.BooleanOptionalAction (Python >= 3.9); run the
# whole pipeline under a matching interpreter (this host's `python3` is 3.8).
if sys.version_info < (3, 9):
    sys.exit("run_regression.py requires Python >= 3.9 — try: python3.12 run_regression.py ...")


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("output_dir", help="where to store run dumps (outside the repo)")
    p.add_argument("--exe", required=True, help="ChampSim binary to test")
    p.add_argument("--tlist", required=True, nargs="+", help="trace list YAML(s)")
    p.add_argument("--exp", required=True, nargs="+", help="experiment YAML(s)")
    p.add_argument("--mfile", required=True, nargs="+", help="metric YAML(s)")
    p.add_argument("--label", default="", help="tag appended to the results dir")
    p.add_argument("--local-parallel", type=int, default=os.cpu_count() or 4,
                   help="max ChampSim runs in parallel (default: cpu_count)")
    p.add_argument("--snapshot-exe", action=argparse.BooleanOptionalAction, default=True,
                   help="snapshot the binary into <run>/bin so a rebuild mid-run "
                        "can't change it (default: on)")
    p.add_argument("--hermes-home", default=os.environ.get("HERMES_HOME", DEFAULT_HERMES_HOME),
                   help="Hermes repo (only for recording the git commit in meta)")
    return p.parse_args()


def md5sum(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_commit(repo):
    try:
        sha = subprocess.check_output(
            ["git", "-C", repo, "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL).decode().strip()
        dirty = subprocess.call(["git", "-C", repo, "diff", "--quiet"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0
        return sha + (" (dirty)" if dirty else "")
    except Exception:
        return "?"


def main():
    args = parse_args()

    for f in [args.exe, *args.tlist, *args.exp, *args.mfile]:
        if not os.path.isfile(f):
            sys.exit(f"regression: input not found: {f}")
    out_base = args.output_dir.rstrip("/")
    if not os.path.isdir(out_base):
        sys.exit(f"regression: OUTPUT_DIR does not exist: {out_base}")

    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    results_root = os.path.join(out_base, "hermes_regression")
    out_dir = os.path.join(results_root, ts + (f"_{args.label}" if args.label else ""))
    os.makedirs(out_dir, exist_ok=True)
    jobfile = os.path.join(out_dir, "jobfile.sh")
    stats_csv = os.path.join(out_dir, "stats.csv")

    # 1. build a local, parallel jobfile (snapshots the exe into out_dir/bin)
    cj = [sys.executable, CREATE_JOBFILE, "--local",
          "--local-parallel", str(args.local_parallel),
          "--no-trace-cache", "--exe", args.exe,
          "--tlist", *args.tlist, "--exp", *args.exp, "-o", jobfile]
    if not args.snapshot_exe:
        cj.append("--no-snapshot-exe")
    print("=== create_jobfile ===")
    subprocess.check_call(cj)

    # 2. run the jobfile locally; {trace}_{exp}.out/.err land in out_dir
    print(f"=== running jobs (parallel={args.local_parallel}) in {out_dir} ===")
    job_rc = subprocess.call(["bash", jobfile], cwd=out_dir)
    if job_rc != 0:
        print(f"WARNING: jobfile exited {job_rc}")

    # 3. roll up the target metrics
    print("=== rollup ===")
    subprocess.check_call([sys.executable, ROLLUP, "--mfile", *args.mfile,
                           "--tlist", *args.tlist, "--exp", *args.exp,
                           "-d", out_dir, "-o", stats_csv])

    # 4. metadata
    snap = sorted(glob.glob(os.path.join(out_dir, "bin", "*")))
    meta = {
        "timestamp_utc": ts,
        "label": args.label or None,
        "host": os.uname().nodename,
        "exe": os.path.abspath(args.exe),
        "snapshot_exe": snap[-1] if snap else None,
        "snapshot_md5": md5sum(snap[-1]) if snap else md5sum(args.exe),
        "hermes_commit": git_commit(args.hermes_home),
        "tlist": [os.path.abspath(p) for p in args.tlist],
        "exp": [os.path.abspath(p) for p in args.exp],
        "mfile": [os.path.abspath(p) for p in args.mfile],
        "local_parallel": args.local_parallel,
    }
    with open(os.path.join(out_dir, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    # 5. show this run's rolled-up stats
    print(f"=== summary ({stats_csv}) ===")
    with open(stats_csv, newline="") as f:
        rows = list(csv.reader(f))
    widths = [max(len(r[i]) for r in rows) + 2 for i in range(len(rows[0]))]
    for r in rows:
        print("".join(c.ljust(widths[i]) for i, c in enumerate(r)))

    # 6. auto-compare against the most recent previous run in this OUTPUT_DIR
    prev = sorted(d for d in glob.glob(os.path.join(results_root, "*"))
                  if os.path.isdir(d)
                  and os.path.abspath(d) != os.path.abspath(out_dir)
                  and os.path.isfile(os.path.join(d, "stats.csv")))
    if prev:
        print(f"=== compare vs previous: {prev[-1]} ===")
        changed, crows, cols = compare_runs.compare(prev[-1], out_dir)
        compare_runs.print_table(crows, cols)
        print(f"REGRESSION: {changed} (trace,exp) pair(s) changed" if changed
              else "OK: no change vs baseline")
    else:
        print("(no previous run to compare against — this is the baseline)")

    print(f"=== done: {out_dir} ===")


if __name__ == "__main__":
    main()
