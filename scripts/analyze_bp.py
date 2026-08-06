#!/usr/bin/env python3
"""analyze_bp.py — simulate traces and compare misprediction composition.

The headline question for this study is not "how many mispredictions" but
"which KIND". Aggregate MPKI put the first agentic trace squarely inside SPEC's
range while its composition was the mirror image of every SPEC benchmark, so a
tool that reports only totals would have shown nothing.

Uses ChampSim's --json output rather than the text report: the per-branch-type
counts are already structured there, and text parsing of "BRANCH_CONDITIONAL:"
lines would key metrics on a token with a trailing colon.

Usage:
  analyze_bp.py --out results.csv TRACE [TRACE ...]
  analyze_bp.py --out results.csv --spec --agentic-dir DIR
"""
import argparse
import concurrent.futures
import csv
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BIN = "/home/rbera/work/bpeval/ChampSim/bin/cbp_tagescl64"
SPEC_DIR = "/home/rbera/work/bpeval/simpoint/traces"

# The RAS predicts returns by a different mechanism than the indirect target
# predictor, so they are reported apart rather than lumped into "indirect".
GROUPS = {
    "conditional": ["BRANCH_CONDITIONAL"],
    "indirect": ["BRANCH_INDIRECT", "BRANCH_INDIRECT_CALL"],
    "return": ["BRANCH_RETURN"],
    "direct": ["BRANCH_DIRECT_JUMP", "BRANCH_DIRECT_CALL"],
}


def run_one(trace, binary, warmup, sim, keep_json=None):
    name = os.path.basename(trace).replace(".champsim2.zst", "").replace(".zst", "")
    fd, jpath = tempfile.mkstemp(suffix=".json", prefix="bp_")
    os.close(fd)
    cmd = [binary,
           "--warmup-instructions", str(warmup),
           "--simulation-instructions", str(sim),
           "--trace-version", "2", "--hide-heartbeat",
           "--json", jpath, trace]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=14400)
        if p.returncode != 0:
            return {"trace": name, "error": (p.stdout + p.stderr).strip()[-300:]}
        with open(jpath) as f:
            data = json.load(f)
        core = (data[0] if isinstance(data, list) else data)["roi"]["cores"][0]
        if keep_json:
            os.replace(jpath, os.path.join(keep_json, name + ".json"))
            jpath = None   # moved; nothing left to clean up
    except Exception as e:                                  # noqa: BLE001
        return {"trace": name, "error": f"{type(e).__name__}: {e}"}
    finally:
        if jpath and os.path.exists(jpath):
            os.unlink(jpath)

    insns = core["instructions"]
    cycles = core["cycles"]
    mis = core.get("mispredict", {})
    total_mis = sum(mis.values())

    # A run that simulated far fewer instructions than asked hit the end of the
    # trace, and its MPKI is not comparable with the others. Report it rather
    # than silently averaging a short window in with full ones.
    row = {
        "trace": name,
        "instructions": insns,
        "short": "yes" if insns < sim * 0.99 else "",
        "ipc": round(insns / cycles, 4) if cycles else float("nan"),
        "mpki": round(1000.0 * total_mis / insns, 4) if insns else float("nan"),
        "accuracy": round(100.0 * (1 - total_mis / max(1, core.get("branches", 0))), 3)
                    if core.get("branches") else "",
    }
    for g, types in GROUPS.items():
        c = sum(mis.get(t, 0) for t in types)
        row[g + "_mpki"] = round(1000.0 * c / insns, 4) if insns else float("nan")
        row[g + "_pct"] = round(100.0 * c / total_mis, 2) if total_mis else 0.0
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("traces", nargs="*")
    ap.add_argument("--binary", default=DEFAULT_BIN)
    ap.add_argument("--warmup", type=int, default=50_000_000)
    ap.add_argument("--sim", type=int, default=200_000_000)
    ap.add_argument("--out", default="bp_results.csv")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--spec", action="store_true", help="add the SPEC 2026 slices")
    ap.add_argument("--spec-dir", default=SPEC_DIR)
    ap.add_argument("--keep-json", default=None)
    args = ap.parse_args()

    traces = list(args.traces)
    if args.spec:
        traces += sorted(os.path.join(args.spec_dir, f)
                         for f in os.listdir(args.spec_dir)
                         if f.endswith(".champsim2.zst"))
    if not traces:
        sys.exit("no traces given")
    missing = [t for t in traces if not os.path.exists(t)]
    if missing:
        sys.exit("missing traces:\n  " + "\n  ".join(missing))
    if args.keep_json:
        os.makedirs(args.keep_json, exist_ok=True)

    print(f"simulating {len(traces)} traces "
          f"({args.warmup/1e6:.0f}M warmup / {args.sim/1e6:.0f}M sim, {args.jobs} parallel)",
          file=sys.stderr)

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(run_one, t, args.binary, args.warmup, args.sim,
                          args.keep_json): t for t in traces}
        for i, f in enumerate(concurrent.futures.as_completed(futs), 1):
            r = f.result()
            rows.append(r)
            tag = "ERR " if "error" in r else "ok  "
            print(f"  [{i}/{len(traces)}] {tag}{r['trace']}", file=sys.stderr)

    rows.sort(key=lambda r: r["trace"])
    good = [r for r in rows if "error" not in r]
    bad = [r for r in rows if "error" in r]

    fields = ["trace", "instructions", "short", "ipc", "mpki", "accuracy"] + \
             [g + s for g in GROUPS for s in ("_mpki", "_pct")]
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(good)

    hdr = f"{'trace':34s} {'MPKI':>7s} {'cond':>7s} {'indir':>7s} {'ret':>6s} " \
          f"{'dir':>6s} {'ind%':>6s} {'IPC':>6s}"
    print("\n" + hdr)
    print("-" * len(hdr))
    for r in good:
        print(f"{r['trace']:34s} {r['mpki']:7.2f} {r['conditional_mpki']:7.2f} "
              f"{r['indirect_mpki']:7.2f} {r['return_mpki']:6.2f} "
              f"{r['direct_mpki']:6.2f} {r['indirect_pct']:6.1f} {r['ipc']:6.2f}"
              + ("   [SHORT]" if r["short"] else ""))
    if bad:
        print("\nFAILED:")
        for r in bad:
            print(f"  {r['trace']}: {r['error']}")
    print(f"\nwrote {args.out}  ({len(good)} ok, {len(bad)} failed)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
