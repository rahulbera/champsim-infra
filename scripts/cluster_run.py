#!/usr/bin/env python3.12
"""cluster_run.py — drive ChampSim simulations on a remote Slurm cluster.

Claude Code runs only on the local machine (the cluster login node bars AI
agents); everything on the cluster happens over SSH. This orchestrator turns one
local command into the whole loop:

  bootstrap  one-time per simulator repo: record host + remote paths + build cmd
  submit     rsync sim + champsim-infra to the cluster, build over SSH, then
             generate + smoke-test + auto-launch the sbatch jobs (capturing each
             tag -> job_id exactly), and log the batch locally
  status     squeue/sacct over SSH; update the batch ledger
  rollup     run rollup.py on the cluster, fetch stats.csv back, optionally diff
  list       show logged batches and their status

State lives in a gitignored dotfile dir inside the simulator repo:
  <sim-repo>/.cluster-run/config.yml          (per-repo config)
  <sim-repo>/.cluster-run/runs/<batch>.json   (per-batch ledger)
  <sim-repo>/.cluster-run/runs/<batch>/        (fetched stats.csv, etc.)

The heavy lifting reuses create_jobfile.py / rollup.py / compare_runs.py — they
are rsynced to the cluster and invoked there (submit/rollup) or imported locally
(compare). create_jobfile.py / rollup.py emit machine-readable JSON (delimited by
INFRA_JSON markers) that this script parses to learn job ids / failures.
"""

import argparse
import datetime
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

import yaml

# champsim-infra root (this file lives in <root>/scripts/).
INFRA_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INFRA_SCRIPTS = os.path.join(INFRA_ROOT, "scripts")
INFRA_REGRESSION = os.path.join(INFRA_ROOT, "regression")

STATE_DIRNAME = ".cluster-run"
TS_FMT = "%Y%m%dT%H%M%SZ"

# Placeholder the user writes in tlist/exp files for paths that live INSIDE the
# simulator tree (e.g. --config=$(SIM_HOME_IN_CLUSTER)/config/x.ini). The sim
# tree's cluster-absolute location isn't known until rsync, so we resolve this
# token to remote_sim_path when staging the inputs. Other $(...) tokens are left
# for create_jobfile/rollup to resolve from their own `definitions`.
SIM_HOME_PLACEHOLDER = "$(SIM_HOME_IN_CLUSTER)"

# Must match the markers emitted by create_jobfile.py / rollup.py.
INFRA_JSON_BEGIN = "===INFRA-JSON-BEGIN==="
INFRA_JSON_END = "===INFRA-JSON-END==="

# Shared SSH multiplexing so repeated calls reuse one connection.
_CONTROL_PATH = os.path.expanduser("~/.ssh/cm-%r@%h:%p")
SSH_OPTS = ["-o", "ControlMaster=auto", "-o", f"ControlPath={_CONTROL_PATH}",
            "-o", "ControlPersist=60s"]
SSH_E = "ssh " + " ".join(shlex.quote(o) for o in SSH_OPTS)

# Slurm states in which a job is still active (everything else is terminal).
ACTIVE_STATES = {
    "PENDING", "RUNNING", "CONFIGURING", "COMPLETING", "SUSPENDED", "RESIZING",
    "REQUEUED", "REQUEUE_HOLD", "REQUEUE_FED", "RESV_DEL_HOLD", "SIGNALING",
    "STAGE_OUT", "STOPPED", "SPECIAL_EXIT",
}


class ClusterRunError(Exception):
    """A clean, user-facing orchestration failure (no traceback needed)."""


def log(msg):
    print(f"[cluster_run] {msg}", file=sys.stderr)


def q(s):
    return shlex.quote(str(s))


# --------------------------------------------------------------------------- #
# Thin I/O wrappers (monkeypatched in tests).                                  #
# --------------------------------------------------------------------------- #
def ssh(host, remote_cmd):
    """Run a command on `host`, capturing stdout/stderr separately."""
    log(f"ssh {host}: {remote_cmd}")
    return subprocess.run(["ssh", *SSH_OPTS, host, remote_cmd],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def ssh_stream(host, remote_cmd):
    """Run a command on `host`, streaming combined output live; return (rc, text)."""
    log(f"ssh {host}: {remote_cmd}")
    proc = subprocess.Popen(["ssh", *SSH_OPTS, host, remote_cmd],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    chunks = []
    for line in proc.stdout:
        sys.stderr.write(line)
        sys.stderr.flush()
        chunks.append(line)
    proc.wait()
    return proc.returncode, "".join(chunks)


def rsync(src, dst, excludes=None, delete=True):
    """rsync src(s) -> dst over the shared SSH connection."""
    srcs = src if isinstance(src, list) else [src]
    argv = ["rsync", "-az", "-e", SSH_E]
    if delete:
        argv.append("--delete")
    for ex in excludes or []:
        argv += ["--exclude", ex]
    argv += srcs + [dst]
    log("rsync " + " ".join(shlex.quote(a) for a in (srcs + [dst])))
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


# --------------------------------------------------------------------------- #
# Repo / config / ledger.                                                      #
# --------------------------------------------------------------------------- #
def git_toplevel(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return None


def get_repo(args):
    start = os.path.abspath(args.repo) if args.repo else os.getcwd()
    if not os.path.isdir(start):
        raise ClusterRunError(f"repo path does not exist: {start}")
    return git_toplevel(start) or start


def state_dir(repo):
    return os.path.join(repo, STATE_DIRNAME)


def config_path(repo):
    return os.path.join(state_dir(repo), "config.yml")


def runs_dir(repo):
    return os.path.join(state_dir(repo), "runs")


def derive_defaults(cfg):
    """Fill in path/python defaults that follow from remote_sim_path + sim_name."""
    cfg.setdefault("remote_python", "python3.12")
    base = cfg.get("remote_base") or os.path.dirname(cfg["remote_sim_path"].rstrip("/"))
    cfg["remote_base"] = base
    cfg.setdefault("remote_infra_path", base + "/champsim-infra")
    cfg.setdefault("remote_runs_base", base + "/runs/" + cfg["sim_name"])
    cfg.setdefault("clusters", [cfg["default_cluster"]])
    cfg.setdefault("rsync_excludes", [".git", STATE_DIRNAME, "bin/"])
    cfg.setdefault("slurm", {})
    s = cfg["slurm"]
    s.setdefault("partition", "compute")
    s.setdefault("ncores", "1")
    s.setdefault("nodename", "ntl-zeus")
    s.setdefault("extra", "")
    s.setdefault("include", "")
    s.setdefault("exclude", "")
    return cfg


def load_config(repo):
    path = config_path(repo)
    if not os.path.isfile(path):
        raise ClusterRunError(
            f"no cluster-run config at {path}; run `cluster_run.py bootstrap` first")
    with open(path) as f:
        return derive_defaults(yaml.safe_load(f))


def save_config(repo, cfg):
    os.makedirs(state_dir(repo), exist_ok=True)
    with open(config_path(repo), "w") as f:
        yaml.safe_dump(cfg, f, sort_keys=False)


def ensure_git_exclude(repo):
    """Add '.cluster-run/' to <repo>/.git/info/exclude (don't touch tracked .gitignore)."""
    git_dir = os.path.join(repo, ".git")
    if not os.path.isdir(git_dir):
        return
    info = os.path.join(git_dir, "info")
    os.makedirs(info, exist_ok=True)
    exclude = os.path.join(info, "exclude")
    line = STATE_DIRNAME + "/"
    existing = ""
    if os.path.isfile(exclude):
        with open(exclude) as f:
            existing = f.read()
    if line not in existing.split():
        with open(exclude, "a") as f:
            if existing and not existing.endswith("\n"):
                f.write("\n")
            f.write(line + "\n")
        log(f"added '{line}' to {exclude}")


def ledger_path(repo, batch_id):
    return os.path.join(runs_dir(repo), batch_id + ".json")


def save_ledger(repo, ledger):
    os.makedirs(runs_dir(repo), exist_ok=True)
    with open(ledger_path(repo, ledger["batch_id"]), "w") as f:
        json.dump(ledger, f, indent=2)


def load_ledger(repo, batch_id):
    path = ledger_path(repo, batch_id)
    if not os.path.isfile(path):
        raise ClusterRunError(f"no batch ledger: {path}")
    with open(path) as f:
        return json.load(f)


def all_ledgers(repo):
    out = []
    for p in sorted(glob.glob(os.path.join(runs_dir(repo), "*.json"))):
        with open(p) as f:
            out.append(json.load(f))
    return out


# --------------------------------------------------------------------------- #
# Pure parsing helpers.                                                        #
# --------------------------------------------------------------------------- #
def extract_infra_json(text):
    """Pull the single delimited JSON object out of captured stdout."""
    if INFRA_JSON_BEGIN not in text or INFRA_JSON_END not in text:
        raise ValueError("no INFRA-JSON report found in output")
    body = text.split(INFRA_JSON_BEGIN, 1)[1].split(INFRA_JSON_END, 1)[0]
    return json.loads(body)


_BINARY_RE = re.compile(r"^Binary:\s*(\S+)\s*$", re.MULTILINE)


def parse_binary_relpath(build_output):
    """Return the last 'Binary: <relpath>' emitted by build_champsim.sh, or None."""
    matches = _BINARY_RE.findall(build_output)
    return matches[-1] if matches else None


def parse_squeue(text):
    """Parse `squeue -h -o '%i|%T'` lines into {job_id: state}."""
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if "|" not in line:
            continue
        jid, state = line.split("|", 1)
        out[jid.strip()] = state.strip().split()[0]
    return out


def parse_sacct(text):
    """Parse `sacct -n -P -o JobID,State,ExitCode` into {job_id: state}.

    Keeps only the main job line (JobID without a '.suffix' like .batch/.extern).
    """
    out = {}
    for line in text.splitlines():
        parts = line.strip().split("|")
        if len(parts) < 2 or not parts[0]:
            continue
        jid = parts[0]
        if "." in jid:
            continue
        out[jid] = parts[1].split()[0] if parts[1] else ""
    return out


def is_terminal(state):
    base = (state or "").split()[0].upper() if state else ""
    if not base or base == "UNKNOWN":
        return False
    return base not in ACTIVE_STATES


def utc_stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime(TS_FMT)


def remote_join(parts):
    return " ".join(q(p) for p in parts)


# --------------------------------------------------------------------------- #
# Subcommands.                                                                 #
# --------------------------------------------------------------------------- #
def cmd_bootstrap(args):
    repo = get_repo(args)
    if os.path.isfile(config_path(repo)) and not args.force:
        raise ClusterRunError(
            f"already bootstrapped ({config_path(repo)}); use --force to overwrite")

    cfg = {
        "sim_name": args.sim_name or os.path.basename(repo),
        "default_cluster": args.cluster or "fury",
        "clusters": args.clusters or [args.cluster or "fury"],
        "remote_python": args.remote_python,
        "remote_sim_path": args.remote_sim_path.rstrip("/"),
        "build_command": args.build_command,
        "slurm": {
            "partition": args.slurm_part, "ncores": str(args.ncores),
            "nodename": args.nodename, "extra": args.extra,
            "include": args.include, "exclude": args.exclude,
        },
    }
    if args.remote_base:
        cfg["remote_base"] = args.remote_base.rstrip("/")
    if args.remote_infra_path:
        cfg["remote_infra_path"] = args.remote_infra_path.rstrip("/")
    if args.remote_runs_base:
        cfg["remote_runs_base"] = args.remote_runs_base.rstrip("/")
    derive_defaults(cfg)

    save_config(repo, cfg)
    ensure_git_exclude(repo)
    log(f"wrote {config_path(repo)}")
    print(yaml.safe_dump(cfg, sort_keys=False).rstrip())

    if not args.no_connectivity_check:
        host = cfg["default_cluster"]
        res = ssh(host, "true")
        if res.returncode == 0:
            log(f"connectivity OK: ssh {host}")
        else:
            log(f"WARNING: ssh {host} failed (rc={res.returncode}): {res.stderr.strip()}")
    return 0


def substitute_sim_home(text, sim_home):
    """Resolve the literal $(SIM_HOME_IN_CLUSTER) token to sim_home.

    Returns (new_text, num_replacements). Pure text replace, so it composes with
    nested definitions (e.g. CFG: "$(SIM_HOME_IN_CLUSTER)/config") and never
    touches the other $(...) tokens create_jobfile/rollup resolve themselves.
    """
    return text.replace(SIM_HOME_PLACEHOLDER, sim_home), text.count(SIM_HOME_PLACEHOLDER)


def _prepare_inputs(flat, sim_home, dest_dir):
    """Write each input file into dest_dir with $(SIM_HOME_IN_CLUSTER) resolved.

    Returns the total number of substitutions across all files.
    """
    total = 0
    for f in flat:
        with open(f) as fh:
            new, n = substitute_sim_home(fh.read(), sim_home)
        total += n
        with open(os.path.join(dest_dir, os.path.basename(f)), "w") as out:
            out.write(new)
    return total


def _stage_inputs(repo, cfg, host, run_dir, args):
    """Stage tlist/exp/mfile into <run_dir>/inputs on the cluster, resolving the
    $(SIM_HOME_IN_CLUSTER) placeholder to the cluster sim path first.

    Substitution happens on temp copies, so the local source files are never
    modified — only the cluster-side copies (used to generate the jobfile) get
    the resolved absolute paths.
    """
    groups = {"tlist": args.tlist, "exp": args.exp, "mfile": args.mfile}
    flat = [f for g in groups.values() for f in g]
    for f in flat:
        if not os.path.isfile(f):
            raise ClusterRunError(f"input file not found: {f}")
    basenames = [os.path.basename(f) for f in flat]
    if len(set(basenames)) != len(basenames):
        raise ClusterRunError(
            "input files have colliding basenames; rename so each tlist/exp/mfile "
            f"is unique: {basenames}")

    inputs_dir = run_dir + "/inputs"
    tmp = tempfile.mkdtemp(prefix="cluster_run_inputs.")
    try:
        n = _prepare_inputs(flat, cfg["remote_sim_path"], tmp)
        if n:
            log(f"resolved {SIM_HOME_PLACEHOLDER} -> {cfg['remote_sim_path']} "
                f"({n} occurrence(s) across staged inputs)")
        srcs = [os.path.join(tmp, b) for b in basenames]
        res = rsync(srcs, f"{host}:{inputs_dir}/", excludes=None, delete=False)
        if res.returncode != 0:
            raise ClusterRunError(f"rsync of input files failed: {res.stderr.strip()}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return {k: [f"{inputs_dir}/{os.path.basename(f)}" for f in v] for k, v in groups.items()}


def cmd_submit(args):
    repo = get_repo(args)
    cfg = load_config(repo)
    host = args.cluster or cfg["default_cluster"]
    slurm = cfg["slurm"]
    batch = utc_stamp() + (f"_{args.label}" if args.label else "")
    run_dir = cfg["remote_runs_base"] + "/" + batch
    log(f"batch {batch} -> {host}:{run_dir}")

    # 1. sync the simulator and champsim-infra to the cluster.
    r = rsync(repo.rstrip("/") + "/", f"{host}:{cfg['remote_sim_path']}/",
              excludes=cfg["rsync_excludes"], delete=True)
    if r.returncode != 0:
        raise ClusterRunError(f"rsync of simulator failed: {r.stderr.strip()}")
    r = rsync(INFRA_ROOT.rstrip("/") + "/", f"{host}:{cfg['remote_infra_path']}/",
              excludes=[".git", "__pycache__", STATE_DIRNAME], delete=True)
    if r.returncode != 0:
        raise ClusterRunError(f"rsync of champsim-infra failed: {r.stderr.strip()}")

    # 2. make the run dir and stage inputs.
    mk = ssh(host, f"mkdir -p {q(run_dir)}/inputs")
    if mk.returncode != 0:
        raise ClusterRunError(f"mkdir {run_dir} failed: {mk.stderr.strip()}")
    remote_inputs = _stage_inputs(repo, cfg, host, run_dir, args)

    # 3. build over SSH and resolve the produced binary.
    rc, build_out = ssh_stream(host, f"cd {q(cfg['remote_sim_path'])} && {cfg['build_command']}")
    if rc != 0:
        raise ClusterRunError(f"build failed (rc={rc}) — see streamed output above")
    relpath = parse_binary_relpath(build_out)
    if relpath:
        exe = cfg["remote_sim_path"] + "/" + relpath.lstrip("./")
    else:
        ls = ssh(host, f"ls -t {q(cfg['remote_sim_path'])}/bin | head -1")
        newest = ls.stdout.strip().splitlines()[0] if ls.stdout.strip() else ""
        if not newest:
            raise ClusterRunError("could not determine built binary (no 'Binary:' line, empty bin/)")
        log(f"no 'Binary:' line; falling back to newest bin/ entry: {newest}")
        exe = cfg["remote_sim_path"] + "/bin/" + newest
    chk = ssh(host, f"test -x {q(exe)}")
    if chk.returncode != 0:
        raise ClusterRunError(f"built binary not found/executable on cluster: {exe}")
    log(f"built binary: {exe}")

    # 4. generate + smoke-gate + auto-launch via create_jobfile.py on the cluster.
    cj = os.path.join(cfg["remote_infra_path"], "scripts", "create_jobfile.py")
    parts = [cfg["remote_python"], cj, "--exe", exe,
             "--tlist", *remote_inputs["tlist"], "--exp", *remote_inputs["exp"],
             "--no-trace-cache", "--smoke-test-auto-launch",
             "--smoke-test-idx", args.smoke_idx,
             "--smoke-warmup", args.smoke_warmup, "--smoke-sim", args.smoke_sim,
             "--report-json", "-", "-o", run_dir + "/jobfile.sh",
             "--slurm-part", slurm["partition"], "--ncores", slurm["ncores"],
             "--nodename", slurm["nodename"]]
    if slurm.get("extra"):
        parts += ["--extra", slurm["extra"]]
    if slurm.get("include"):
        parts += ["--include", slurm["include"]]
    if slurm.get("exclude"):
        parts += ["--exclude", slurm["exclude"]]
    if args.no_snapshot_exe:
        parts += ["--no-snapshot-exe"]

    res = ssh(host, f"cd {q(run_dir)} && {remote_join(parts)}")
    try:
        report = extract_infra_json(res.stdout)
    except ValueError:
        raise ClusterRunError(
            "create_jobfile produced no JSON report (rc="
            f"{res.returncode}). stderr tail:\n{res.stderr[-800:]}")

    # A smoke failure (or any pre-submit error) launches nothing -> hard error, no
    # ledger. A partial submit (some sbatch succeeded, some failed) DID launch real
    # jobs; we must record them so they aren't orphaned, then warn loudly.
    ok = report.get("status") == "ok"
    submitted = [j for j in report.get("jobs", []) if j.get("job_id")]
    if not ok and not (report.get("error_id") == "CJ_SUBMIT_FAILED" and submitted):
        msg = f"submit failed: {report.get('error_id')}: {report.get('message')}"
        smoke = report.get("smoke") or {}
        if smoke.get("output_tail"):
            msg += "\n--- smoke output tail ---\n" + smoke["output_tail"]
        for fail in report.get("submit_failures", []):
            msg += f"\n  sbatch {fail['tag']} rc={fail['submit_rc']}: {fail.get('stderr_tail','')}"
        raise ClusterRunError(msg)

    # 5. log the batch (full success, or partial submit we must not orphan).
    jobs = [{"tag": j["tag"], "job_id": j["job_id"], "state": "PENDING"} for j in submitted]
    ledger = {
        "batch_id": batch, "cluster": host, "submitted_utc": utc_stamp(),
        "status": "submitted" if ok else "partial", "remote_run_dir": run_dir,
        "remote_infra_path": cfg["remote_infra_path"], "remote_python": cfg["remote_python"],
        "exe": report.get("exe"), "exe_original": report.get("exe_original"),
        "build_command": cfg["build_command"],
        "local_inputs": {k: [os.path.abspath(f) for f in v]
                         for k, v in {"tlist": args.tlist, "exp": args.exp, "mfile": args.mfile}.items()},
        "remote_inputs": remote_inputs,
        "smoke": report.get("smoke"),
        "jobs": jobs, "stats_csv": None,
    }
    save_ledger(repo, ledger)
    log(f"logged {len(jobs)} job(s) to {ledger_path(repo, batch)}")
    if ok:
        print(f"Submitted batch {batch}: {len(jobs)} job(s) on {host}")
    else:
        fails = report.get("submit_failures", [])
        print(f"PARTIAL submit for batch {batch}: {len(jobs)} launched, {len(fails)} FAILED on {host}")
        for fail in fails:
            print(f"  FAILED {fail['tag']}: rc={fail['submit_rc']} {fail.get('stderr_tail', '')}")
    for j in jobs:
        print(f"  {j['job_id']}  {j['tag']}")
    return 0 if ok else 1


def _refresh_states(host, jobs):
    """Update job['state'] in-place for one batch's jobs via squeue + sacct."""
    ids = [j["job_id"] for j in jobs if j.get("job_id") and not is_terminal(j.get("state", ""))]
    if not ids:
        return
    idcsv = ",".join(ids)
    states = {}
    sq = ssh(host, f"squeue -j {q(idcsv)} -h -o '%i|%T'")
    if sq.returncode == 0:
        states.update(parse_squeue(sq.stdout))
    missing = [i for i in ids if i not in states]
    if missing:
        sa = ssh(host, f"sacct -j {q(','.join(missing))} -n -P -o JobID,State,ExitCode")
        if sa.returncode == 0:
            states.update(parse_sacct(sa.stdout))
    for j in jobs:
        if j["job_id"] in states:
            j["state"] = states[j["job_id"]]


def _batch_status(jobs):
    if jobs and all(is_terminal(j.get("state", "")) for j in jobs):
        return "complete"
    return "running"


def cmd_status(args):
    repo = get_repo(args)
    if args.batch:
        ledgers = [load_ledger(repo, args.batch)]
    else:
        # Default: every batch not yet rolled up (re-querying a complete batch is
        # free — all its jobs are terminal, so no SSH happens). --all adds rolled-up.
        ledgers = [l for l in all_ledgers(repo)
                   if args.all or l.get("status") != "rolledup"]
    if not ledgers:
        print("No batches to check.")
        return 0

    for ledger in ledgers:
        host = args.cluster or ledger["cluster"]
        _refresh_states(host, ledger["jobs"])
        if ledger.get("status") != "rolledup":
            ledger["status"] = _batch_status(ledger["jobs"])
        save_ledger(repo, ledger)

        counts = {}
        for j in ledger["jobs"]:
            counts[j["state"]] = counts.get(j["state"], 0) + 1
        summary = ", ".join(f"{k}:{v}" for k, v in sorted(counts.items()))
        print(f"{ledger['batch_id']}  [{ledger['status']}]  ({summary})")
        terminal = sum(1 for j in ledger["jobs"] if is_terminal(j.get("state", "")))
        print(f"    {terminal}/{len(ledger['jobs'])} terminal  on {host}")
    return 0


def _print_csv_table(path):
    import csv
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    if not rows:
        return
    w = [max(len(r[i]) for r in rows) + 2 for i in range(len(rows[0]))]
    for r in rows:
        print("".join(c.ljust(w[i]) for i, c in enumerate(r)))


def cmd_rollup(args):
    repo = get_repo(args)
    ledger = load_ledger(repo, args.batch)
    host = args.cluster or ledger["cluster"]

    if not args.force and ledger.get("status") not in ("complete", "rolledup"):
        _refresh_states(host, ledger["jobs"])
        ledger["status"] = _batch_status(ledger["jobs"])
        save_ledger(repo, ledger)
        if ledger["status"] != "complete":
            pending = [j["tag"] for j in ledger["jobs"] if not is_terminal(j.get("state", ""))]
            raise ClusterRunError(
                f"batch {args.batch} not complete ({len(pending)} job(s) still active); "
                "use --force to roll up anyway")

    ri = ledger["remote_inputs"]
    run_dir = ledger["remote_run_dir"]
    cfg = load_config(repo)
    remote_infra = ledger.get("remote_infra_path") or cfg["remote_infra_path"]
    remote_python = ledger.get("remote_python") or cfg["remote_python"]
    ru = os.path.join(remote_infra, "scripts", "rollup.py")
    parts = [remote_python, ru, "--mfile", *ri["mfile"],
             "--tlist", *ri["tlist"], "--exp", *ri["exp"],
             "-d", run_dir, "-o", run_dir + "/stats.csv", "--report-json", "-"]
    res = ssh(host, f"cd {q(run_dir)} && {remote_join(parts)}")
    try:
        report = extract_infra_json(res.stdout)
    except ValueError:
        raise ClusterRunError(
            f"rollup produced no JSON report (rc={res.returncode}). stderr tail:\n{res.stderr[-800:]}")

    local_dir = os.path.join(runs_dir(repo), args.batch)
    os.makedirs(local_dir, exist_ok=True)
    fr = rsync(f"{host}:{run_dir}/stats.csv", local_dir + "/stats.csv", delete=False)
    if fr.returncode != 0:
        raise ClusterRunError(f"failed to fetch stats.csv: {fr.stderr.strip()}")
    local_csv = os.path.join(local_dir, "stats.csv")

    print(f"=== stats ({args.batch}) ===")
    _print_csv_table(local_csv)
    s = report.get("summary", {})
    print(f"rollup: {report.get('status')} — total={s.get('total')} passed={s.get('passed')} "
          f"filtered={s.get('filtered')} failed={s.get('failed')}")
    for run in report.get("runs", []):
        if run["status"] != "ok":
            print(f"  {run['status'].upper():9} {run['trace']}/{run['exp']}: "
                  f"{run['error_id']} ({run['reason']})")

    ledger["status"] = "rolledup"
    ledger["stats_csv"] = local_csv
    save_ledger(repo, ledger)

    if not args.no_compare:
        _maybe_compare(repo, args.batch, local_dir, args.tol)
    return 0


def _maybe_compare(repo, batch_id, new_dir, tol):
    """Diff this batch's stats.csv against the most recent prior batch that has one."""
    prior = [l for l in all_ledgers(repo)
             if l["batch_id"] < batch_id and l.get("stats_csv")
             and os.path.isfile(os.path.join(runs_dir(repo), l["batch_id"], "stats.csv"))]
    if not prior:
        print("(no previous rolled-up batch to compare against)")
        return
    prev = prior[-1]
    old_dir = os.path.join(runs_dir(repo), prev["batch_id"])
    if INFRA_REGRESSION not in sys.path:
        sys.path.insert(0, INFRA_REGRESSION)
    try:
        import compare_runs
    except Exception as e:
        print(f"(skipping compare: {e})")
        return
    print(f"=== compare vs {prev['batch_id']} ===")
    changed, rows, cols = compare_runs.compare(old_dir, new_dir, tol=tol)
    compare_runs.print_table(rows, cols)
    print(f"REGRESSION: {changed} (trace,exp) pair(s) changed" if changed
          else "OK: no change vs previous batch")


def cmd_combine(args):
    repo = get_repo(args)
    batch_ids = [b.strip() for b in args.batches.split(",") if b.strip()]
    if len(batch_ids) < 2:
        raise ClusterRunError("combine needs at least two batches (--batches B1,B2)")
    cfg = load_config(repo)
    ledgers = [load_ledger(repo, b) for b in batch_ids]
    host = args.cluster or ledgers[0]["cluster"]
    clusters = {l["cluster"] for l in ledgers}
    if len(clusters) > 1 and not args.cluster:
        raise ClusterRunError(
            f"batches span multiple clusters {sorted(clusters)}; pass --cluster to pick one")

    # Each batch must be terminal; combining needs its .out files on the cluster.
    for led in ledgers:
        if not args.force and led.get("status") not in ("complete", "rolledup"):
            _refresh_states(host, led["jobs"])
            led["status"] = _batch_status(led["jobs"])
            save_ledger(repo, led)
            if led["status"] != "complete":
                pending = [j["tag"] for j in led["jobs"] if not is_terminal(j.get("state", ""))]
                raise ClusterRunError(
                    f"batch {led['batch_id']} not complete ({len(pending)} job(s) still active); "
                    "use --force to combine anyway")

    # Assemble one rollup.py call over every batch's run dir + merged inputs.
    # rollup.py merges duplicate-but-identical names and aborts on real conflicts.
    run_dirs = [led["remote_run_dir"] for led in ledgers]
    mfiles, tlists, exps = [], [], []
    for led in ledgers:
        ri = led["remote_inputs"]
        mfiles += ri["mfile"]
        tlists += ri["tlist"]
        exps += ri["exp"]

    name = args.out_name or ("combine_" + max(batch_ids))
    remote_combo = cfg["remote_runs_base"] + "/" + name
    out_csv = remote_combo + "/stats.csv"
    remote_infra = ledgers[0].get("remote_infra_path") or cfg["remote_infra_path"]
    remote_python = ledgers[0].get("remote_python") or cfg["remote_python"]
    ru = os.path.join(remote_infra, "scripts", "rollup.py")
    parts = [remote_python, ru, "--mfile", *mfiles,
             "--tlist", *tlists, "--exp", *exps,
             "-d", *run_dirs, "-o", out_csv, "--report-json", "-"]
    res = ssh(host, f"mkdir -p {q(remote_combo)} && {remote_join(parts)}")
    try:
        report = extract_infra_json(res.stdout)
    except ValueError:
        raise ClusterRunError(
            f"combine rollup produced no JSON report (rc={res.returncode}). "
            f"stderr tail:\n{res.stderr[-800:]}")

    local_dir = os.path.join(runs_dir(repo), name)
    os.makedirs(local_dir, exist_ok=True)
    fr = rsync(f"{host}:{out_csv}", local_dir + "/stats.csv", delete=False)
    if fr.returncode != 0:
        raise ClusterRunError(f"failed to fetch stats.csv: {fr.stderr.strip()}")
    local_csv = os.path.join(local_dir, "stats.csv")

    print(f"=== combined stats ({name}: {', '.join(batch_ids)}) ===")
    _print_csv_table(local_csv)
    s = report.get("summary", {})
    print(f"combine: {report.get('status')} — total={s.get('total')} passed={s.get('passed')} "
          f"filtered={s.get('filtered')} failed={s.get('failed')}")
    for run in report.get("runs", []):
        if run["status"] != "ok":
            print(f"  {run['status'].upper():9} {run['trace']}/{run['exp']}: "
                  f"{run['error_id']} ({run['reason']})")
    print(f"combined stats.csv -> {local_csv}")
    return 0


def cmd_list(args):
    repo = get_repo(args)
    if not os.path.isfile(config_path(repo)):
        print(f"Repo {repo} is not bootstrapped for cluster-run.")
        print("Run `cluster_run.py bootstrap --remote-sim-path ... --build-command ...` first.")
        return 0
    cfg = load_config(repo)
    print(f"sim={cfg['sim_name']}  default_cluster={cfg['default_cluster']}  "
          f"remote_sim_path={cfg['remote_sim_path']}")
    ledgers = all_ledgers(repo)
    if not ledgers:
        print("No batches logged yet.")
        return 0
    for l in ledgers:
        njobs = len(l.get("jobs", []))
        print(f"{l['batch_id']:32}  [{l.get('status','?'):9}]  {l.get('cluster','?'):8}  "
              f"{njobs} job(s)  submitted={l.get('submitted_utc','?')}")
    return 0


# --------------------------------------------------------------------------- #
# CLI.                                                                          #
# --------------------------------------------------------------------------- #
def build_parser():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", default=None,
                        help="simulator repo (default: git toplevel of CWD, else CWD)")

    bp = sub.add_parser("bootstrap", parents=[common], help="one-time per-repo setup")
    bp.add_argument("--remote-sim-path", required=True, help="simulator path on the cluster")
    bp.add_argument("--build-command", required=True,
                    help="build command run in the remote sim dir (e.g. './build_champsim.sh glc multi multi multi multi 1 1 0')")
    bp.add_argument("--cluster", default=None, help="default cluster ssh alias (default: fury)")
    bp.add_argument("--clusters", nargs="+", default=None, help="allowed cluster aliases")
    bp.add_argument("--sim-name", default=None, help="name (default: repo dir basename)")
    bp.add_argument("--remote-python", default="python3.12", help="python on the cluster (>=3.9)")
    bp.add_argument("--remote-base", default=None)
    bp.add_argument("--remote-infra-path", default=None)
    bp.add_argument("--remote-runs-base", default=None)
    bp.add_argument("--slurm-part", default="compute")
    bp.add_argument("--ncores", default="1")
    bp.add_argument("--nodename", default="ntl-zeus")
    bp.add_argument("--extra", default="")
    bp.add_argument("--include", default="")
    bp.add_argument("--exclude", default="")
    bp.add_argument("--force", action="store_true", help="overwrite an existing config")
    bp.add_argument("--no-connectivity-check", action="store_true")
    bp.set_defaults(func=cmd_bootstrap)

    sp = sub.add_parser("submit", parents=[common], help="sync, build, smoke-test, launch")
    sp.add_argument("--tlist", nargs="+", required=True)
    sp.add_argument("--exp", nargs="+", required=True)
    sp.add_argument("--mfile", nargs="+", required=True, help="metric file(s) (stored for rollup)")
    sp.add_argument("--cluster", default=None, help="override the default cluster")
    sp.add_argument("--label", default="", help="tag appended to the batch id")
    sp.add_argument("--smoke-idx", default="0", help="(trace x exp) index for the smoke test")
    sp.add_argument("--smoke-warmup", default="1000000")
    sp.add_argument("--smoke-sim", default="1000000")
    sp.add_argument("--no-snapshot-exe", action="store_true")
    sp.set_defaults(func=cmd_submit)

    stp = sub.add_parser("status", parents=[common], help="check job status via squeue/sacct")
    stp.add_argument("--batch", default=None, help="a single batch id (default: all not-yet-rolled-up)")
    stp.add_argument("--all", action="store_true", help="include already-rolled-up batches too")
    stp.add_argument("--cluster", default=None)
    stp.set_defaults(func=cmd_status)

    rp = sub.add_parser("rollup", parents=[common], help="roll up a finished batch")
    rp.add_argument("--batch", required=True)
    rp.add_argument("--cluster", default=None)
    rp.add_argument("--tol", type=float, default=0.0, help="relative tolerance for the compare")
    rp.add_argument("--no-compare", action="store_true")
    rp.add_argument("--force", action="store_true", help="roll up even if jobs are still active")
    rp.set_defaults(func=cmd_rollup)

    cp = sub.add_parser("combine", parents=[common],
                        help="roll up several finished batches into one combined stats.csv")
    cp.add_argument("--batches", required=True,
                    help="comma-separated batch ids to combine (e.g. B1,B2)")
    cp.add_argument("--cluster", default=None)
    cp.add_argument("-o", "--out-name", default=None,
                    help="name for the combined output dir (default: combine_<latest batch id>)")
    cp.add_argument("--force", action="store_true",
                    help="combine even if some jobs are still active")
    cp.set_defaults(func=cmd_combine)

    lp = sub.add_parser("list", parents=[common], help="list logged batches")
    lp.set_defaults(func=cmd_list)
    return p


def main():
    args = build_parser().parse_args()
    try:
        sys.exit(args.func(args))
    except ClusterRunError as e:
        print(f"cluster_run: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
