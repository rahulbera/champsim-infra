#!/usr/bin/env python3.12
"""In-process tests for cluster_run.py.

The cluster is faked: ssh / ssh_stream / rsync are monkeypatched so the whole
orchestration (bootstrap -> submit -> status -> rollup) runs locally with no
network. Run: python3.12 tests/test_cluster_run.py
"""

import argparse
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, SCRIPTS)
import cluster_run as cr  # noqa: E402
import rollup  # noqa: E402

_checks = {"pass": 0, "fail": 0}


def check(cond, msg):
    if cond:
        _checks["pass"] += 1
    else:
        _checks["fail"] += 1
        print(f"  FAIL: {msg}")


def ns(**kw):
    return argparse.Namespace(**kw)


def wrap_json(obj):
    return f"{cr.INFRA_JSON_BEGIN}\n{json.dumps(obj)}\n{cr.INFRA_JSON_END}\n"


class FakeCluster:
    """Records ssh/rsync calls and returns canned responses by inspecting cmds."""

    def __init__(self):
        self.ssh_calls, self.stream_calls, self.rsync_calls = [], [], []
        self.events = []  # every ssh/stream/rsync call in order, for sequencing checks
        self.staged = {}
        self.build_rc = 0
        self.build_out = ("g++ -O3 ...\n"
                          "Binary: bin/glc-perceptron-no-multi-multi-multi-multi-1core-1ch\n")
        self.cp_rc = 0
        self.cp_out = ""
        self.remote_files = {}  # remote path -> text: fed by uploads to */inputs/, read by fetches
        self.cj_report = None
        self.cj_stdout = None  # raw create_jobfile stdout; overrides cj_report
        self.home = "/cluster/home/rahbera"
        self.rollup_report = None
        self.squeue = ""
        self.sacct = ""

    def _cp(self, rc=0, out="", err=""):
        return subprocess.CompletedProcess(["fake"], rc, out, err)

    def ssh(self, host, cmd):
        self.ssh_calls.append((host, cmd))
        self.events.append(("ssh", cmd))
        if cmd == 'printf %s "$HOME"':
            return self._cp(out=self.home)
        if cmd.startswith("cp -a"):
            return self._cp(rc=self.cp_rc, out=self.cp_out, err="cp: cannot stat" if self.cp_rc else "")
        if "create_jobfile.py" in cmd:
            return self._cp(out=wrap_json(self.cj_report) if self.cj_stdout is None else self.cj_stdout)
        if "rollup.py" in cmd:
            return self._cp(out=wrap_json(self.rollup_report))
        if "squeue" in cmd:
            return self._cp(out=self.squeue)
        if "sacct" in cmd:
            return self._cp(out=self.sacct)
        if "ls -t" in cmd:
            return self._cp(out="glc-perceptron-no-multi-multi-multi-multi-1core-1ch\n")
        # true / mkdir / test -x / anything else: succeed.
        return self._cp()

    def ssh_stream(self, host, cmd):
        self.stream_calls.append((host, cmd))
        self.events.append(("stream", cmd))
        return self.build_rc, self.build_out

    def rsync(self, src, dst, excludes=None, delete=True):
        self.rsync_calls.append((src, dst))
        self.events.append(("rsync", dst))
        srcs = src if isinstance(src, list) else [src]
        if dst.rstrip("/").endswith("/inputs"):
            # an upload of staged (or combine) inputs: capture it for assertions and fetches
            rdir = dst.split(":", 1)[1].rstrip("/")
            files = [s for s in srcs if os.path.isfile(s)]
            files += [os.path.join(s, n) for s in srcs if os.path.isdir(s) for n in sorted(os.listdir(s))]
            self.staged = {os.path.basename(p): open(p).read() for p in files}
            for base, text in self.staged.items():
                self.remote_files[f"{rdir}/{base}"] = text
        elif dst.endswith("stats.csv"):
            with open(dst, "w") as f:
                f.write("TraceName,ExpName,ipc,Filter\ntraceX,exp1,1.5,1\ntraceY,exp1,1.6,1\n")
        elif dst.startswith("/"):
            # a fetch of one remote file to a local path
            path = srcs[0].split(":", 1)[1]
            if path not in self.remote_files:
                return subprocess.CompletedProcess(["rsync"], 23, "", f"rsync: link_stat {path}: No such file")
            with open(dst, "w") as f:
                f.write(self.remote_files[path])
        return subprocess.CompletedProcess(["rsync"], 0, "", "")

    def install(self):
        cr.ssh, cr.ssh_stream, cr.rsync = self.ssh, self.ssh_stream, self.rsync


class ShellCluster(FakeCluster):
    """A FakeCluster whose run-dir mkdir and snapshot commands run in a local sh, on a cluster
    tree under a temp dir (see local_cluster)."""

    def ssh(self, host, cmd):
        if not cmd.startswith(("mkdir", "cp -a")):
            return super().ssh(host, cmd)
        self.ssh_calls.append((host, cmd))
        self.events.append(("ssh", cmd))
        r = subprocess.run(["sh", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return self._cp(r.returncode, r.stdout, r.stderr)


def local_cluster(root, repo, fake, dirs=("config",)):
    """Bootstrap `repo` against a cluster tree under `root`: <root>/Hermes with config/nopref.ini,
    <root>/champsim-infra/scripts and the derived runs base. Returns the sim path."""
    sim = root + "/Hermes"
    os.makedirs(sim + "/config", exist_ok=True)
    open(sim + "/config/nopref.ini", "w").write("x=1\n")
    os.makedirs(root + "/champsim-infra/scripts", exist_ok=True)
    open(root + "/champsim-infra/scripts/create_jobfile.py", "w").write("")
    fake.install()
    cr.cmd_bootstrap(ns(
        repo=repo, remote_sim_path=sim, build_command="true", cluster="fury", clusters=None,
        sim_name="Hermes", remote_python="python3.12", remote_base=None, remote_infra_path=None,
        remote_runs_base=None, slurm_part="compute", ncores="1", nodename="ntl-zeus", extra="",
        include="", exclude="", force=True, no_connectivity_check=True))
    cfg = cr.load_config(repo)
    cfg["snapshot_dirs"] = list(dirs)
    cr.save_config(repo, cfg)
    return sim


def submit_args(repo, t, e, m, label=""):
    return ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None, label=label,
              smoke_idx="0", smoke_warmup="1000", smoke_sim="1000", no_snapshot_exe=False)


def make_inputs(d):
    t = os.path.join(d, "t.yml")
    e = os.path.join(d, "e.yml")
    m = os.path.join(d, "m.yml")
    open(t, "w").write("---\nsuiteA:\n  - traceX: {path: /nfs/x.zst, version: 2}\n")
    # exp references a config INSIDE the sim tree via the placeholder + its own def
    open(e, "w").write("---\ndefinitions:\n"
                       "  - BASE: \"--config=$(SIM_HOME_IN_CLUSTER)/config/nopref.ini\"\n"
                       "experiments:\n  - exp1: \"$(BASE)\"\n")
    open(m, "w").write("---\n- ipc: \"$(Core_0_cumulative_IPC)\"\n")
    return t, e, m


SIM = "/cluster/home/rahbera/Hermes"
INFRA = "/cluster/home/rahbera/champsim-infra"
RUNS = "/cluster/home/rahbera/runs/Hermes"


def ok_cj_report(*job_ids):
    return {"tool": "create_jobfile", "status": "ok", "error_id": None,
            "exe": SIM + "/bin/glc-X", "exe_original": SIM + "/bin/glc-X", "smoke": {"rc": 0},
            "jobs": [{"tag": f"trace{i}_exp1", "job_id": j, "submit_rc": 0}
                     for i, j in enumerate(job_ids)],
            "submit_failures": []}


def make_ledger(batch, snapshot):
    """A complete batch's ledger; snapshot=False is the shape written before snapshots."""
    run_dir = f"{RUNS}/{batch}"
    inputs = {"tlist": [run_dir + "/inputs/t.yml"], "exp": [run_dir + "/inputs/e.yml"],
              "mfile": [run_dir + "/inputs/m.yml"]}
    led = {"batch_id": batch, "cluster": "fury", "submitted_utc": batch, "status": "complete",
           "remote_run_dir": run_dir, "remote_infra_path": INFRA, "remote_python": "python3.12",
           "exe": SIM + "/bin/glc-X", "exe_original": SIM + "/bin/glc-X",
           "build_command": "./build_champsim.sh", "local_inputs": inputs,
           "remote_inputs": inputs, "smoke": {"rc": 0},
           "jobs": [{"tag": "traceX_exp1", "job_id": "1", "state": "COMPLETED"}],
           "stats_csv": None}
    if snapshot:
        led["self_contained"] = True
        led["snapshot"] = {"config": run_dir + "/config", "scripts": run_dir + "/scripts"}
    return led


def save_batch(repo, fake, batch, snapshot, exp="exp1", extra=""):
    """Log a complete batch and put its staged e.yml on the fake cluster, as submit left it."""
    led = make_ledger(batch, snapshot)
    cfgdir = (led["remote_run_dir"] if snapshot else SIM) + "/config"
    fake.remote_files[led["remote_inputs"]["exp"][0]] = (
        f"---\ndefinitions:\n  - BASE: \"--config={cfgdir}/nopref.ini\"\n"
        f"experiments:\n  - {exp}: \"$(BASE){extra}\"\n")
    cr.save_ledger(repo, led)
    return led


# --------------------------------------------------------------------------- #
def test_pure_helpers():
    print("test_pure_helpers")
    check(cr.parse_binary_relpath("x\nBinary: bin/glc-foo\ny") == "bin/glc-foo",
          "parse_binary_relpath")
    check(cr.parse_binary_relpath("no binary here") is None, "parse_binary_relpath none")
    check(cr.extract_infra_json("noise\n" + wrap_json({"a": 1}) + "tail")["a"] == 1,
          "extract_infra_json")
    check(cr.parse_squeue("100|RUNNING\n101|PENDING\n") == {"100": "RUNNING", "101": "PENDING"},
          "parse_squeue")
    sacct = "100|COMPLETED|0:0\n100.batch|COMPLETED|0:0\n101|FAILED|1:0\n"
    check(cr.parse_sacct(sacct) == {"100": "COMPLETED", "101": "FAILED"}, "parse_sacct")
    check(cr.parse_sacct("102|CANCELLED by 5001|0:0\n")["102"] == "CANCELLED", "sacct cancelled")
    for s, term in [("RUNNING", False), ("PENDING", False), ("COMPLETED", True),
                    ("FAILED", True), ("CANCELLED by 5", True), ("", False), ("UNKNOWN", False)]:
        check(cr.is_terminal(s) == term, f"is_terminal({s!r})")
    cfg = cr.derive_defaults({"sim_name": "Hermes", "default_cluster": "fury",
                              "remote_sim_path": "/cluster/home/rahbera/Hermes"})
    check(cfg["remote_base"] == "/cluster/home/rahbera", "derive remote_base")
    check(cfg["remote_infra_path"] == "/cluster/home/rahbera/champsim-infra", "derive infra path")
    check(cfg["remote_runs_base"] == "/cluster/home/rahbera/runs/Hermes", "derive runs base")
    check(cfg["remote_python"] == "python3.12", "derive python")
    check(cfg["snapshot_dirs"] == ["config"], "derive snapshot_dirs")
    cfg = cr.derive_defaults({"sim_name": "S", "default_cluster": "fury", "remote_sim_path": "/c/S",
                              "snapshot_dirs": ["configs/", "configs/run", "data", "configs"]})
    check(cfg["snapshot_dirs"] == ["configs", "data"],
          "snapshot_dirs normalized; a duplicate and an entry under another dropped")
    for bad in ["/c/S/config", "../x", "a//b", "./config", "scripts", "bin/x", "inputs"]:
        try:
            cr.check_snapshot_dirs([bad])
            check(False, f"snapshot_dirs {bad!r} should be refused")
        except cr.ClusterRunError:
            check(True, f"snapshot_dirs {bad!r} refused")


def test_substitution():
    print("test_substitution")
    home = "/cluster/home/rahbera/Hermes"
    new, n = cr.substitute_sim_home(
        "--config=$(SIM_HOME_IN_CLUSTER)/config/x.ini $(BASE) $(SIM_HOME_IN_CLUSTER)/y", home)
    check(n == 2, "counts both occurrences")
    check(new == f"--config={home}/config/x.ini $(BASE) {home}/y", "resolves placeholder, keeps $(BASE)")
    check(cr.substitute_sim_home("no placeholder here", home) == ("no placeholder here", 0),
          "no-op when absent")
    # nested-in-definition case composes with create_jobfile's own resolution
    nested, n2 = cr.substitute_sim_home("CFG: \"$(SIM_HOME_IN_CLUSTER)/config\"", home)
    check(n2 == 1 and nested == f"CFG: \"{home}/config\"", "nested definition resolves")
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "e.yml")
        open(src, "w").write("a $(SIM_HOME_IN_CLUSTER)/c\n")
        dest = os.path.join(d, "out"); os.makedirs(dest)
        total = cr._prepare_inputs([src], home, dest)
        check(total == 1, "_prepare_inputs counts substitutions")
        check(open(os.path.join(dest, "e.yml")).read() == f"a {home}/c\n", "_prepare_inputs writes resolved copy")
        check(open(src).read() == "a $(SIM_HOME_IN_CLUSTER)/c\n", "source file left untouched")


def test_bootstrap():
    print("test_bootstrap")
    with tempfile.TemporaryDirectory() as repo:
        os.makedirs(os.path.join(repo, ".git"))  # exercise git-exclude path
        fake = FakeCluster(); fake.install()
        rc = cr.cmd_bootstrap(ns(
            repo=repo, remote_sim_path="/cluster/home/rahbera/Hermes",
            build_command="./build_champsim.sh glc multi multi multi multi 1 1 0",
            cluster="fury", clusters=None, sim_name=None, remote_python="python3.12",
            remote_base=None, remote_infra_path=None, remote_runs_base=None,
            slurm_part="compute", ncores="1", nodename="ntl-zeus", extra="", include="",
            exclude="", force=False, no_connectivity_check=False))
        check(rc == 0, "bootstrap rc")
        cfg = cr.load_config(repo)
        check(cfg["sim_name"] == os.path.basename(repo), "sim_name defaulted")
        check(cfg["remote_infra_path"] == "/cluster/home/rahbera/champsim-infra", "infra path")
        exclude = open(os.path.join(repo, ".git/info/exclude")).read()
        check(".cluster-run/" in exclude.split(), "git exclude written")
        check(any(c[1] == "true" for c in fake.ssh_calls), "connectivity check ran")
        # second bootstrap without --force should error
        try:
            cr.cmd_bootstrap(ns(repo=repo, remote_sim_path="x", build_command="y",
                                cluster="fury", clusters=None, sim_name=None,
                                remote_python="python3.12", remote_base=None,
                                remote_infra_path=None, remote_runs_base=None,
                                slurm_part="compute", ncores="1", nodename="ntl-zeus",
                                extra="", include="", exclude="", force=False,
                                no_connectivity_check=True))
            check(False, "second bootstrap should raise")
        except cr.ClusterRunError:
            check(True, "second bootstrap raised")


def _bootstrap(repo, fake):
    fake.install()
    cr.cmd_bootstrap(ns(
        repo=repo, remote_sim_path="/cluster/home/rahbera/Hermes",
        build_command="./build_champsim.sh glc multi multi multi multi 1 1 0",
        cluster="fury", clusters=["fury", "kratos2"], sim_name="Hermes",
        remote_python="python3.12", remote_base=None, remote_infra_path=None,
        remote_runs_base=None, slurm_part="compute", ncores="1", nodename="ntl-zeus",
        extra="", include="", exclude="", force=True, no_connectivity_check=True))


def test_submit_success():
    print("test_submit_success")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        fake.cj_report = {
            "tool": "create_jobfile", "status": "ok", "error_id": None,
            "exe": "/cluster/home/rahbera/Hermes/bin/glc-X", "exe_original": "/c/Hermes/bin/glc-X",
            "smoke": {"rc": 0, "trace": "traceX", "exp": "exp1"},
            "submitted": True,
            "jobs": [{"tag": "traceX_exp1", "job_id": "5001", "submit_rc": 0},
                     {"tag": "traceY_exp1", "job_id": "5002", "submit_rc": 0}],
            "submit_failures": [],
        }
        rc = cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None,
                              label="popet", smoke_idx="0", smoke_warmup="1000",
                              smoke_sim="1000", no_snapshot_exe=False))
        check(rc == 0, "submit rc")
        ledgers = cr.all_ledgers(repo)
        check(len(ledgers) == 1, "one ledger written")
        L = ledgers[0]
        check(L["batch_id"].endswith("_popet"), "batch id has label")
        check(L["status"] == "submitted", "ledger status submitted")
        check([j["job_id"] for j in L["jobs"]] == ["5001", "5002"], "job ids captured")
        check(all(j["state"] == "PENDING" for j in L["jobs"]), "jobs start PENDING")
        check(L["cluster"] == "fury", "cluster recorded")
        # the create_jobfile invocation used the right gating flags
        cj = [c for _, c in fake.ssh_calls if "create_jobfile.py" in c][0]
        check("--no-trace-cache" in cj, "uses --no-trace-cache")
        check("--smoke-test-auto-launch" in cj, "uses --smoke-test-auto-launch")
        check("--report-json -" in cj, "uses --report-json -")
        check("python3.12" in cj, "uses remote python3.12")
        # both repos were rsynced
        dsts = " ".join(d for _, d in fake.rsync_calls)
        check("Hermes" in dsts and "champsim-infra" in dsts, "rsynced sim + infra")
        # the staged exp file had $(SIM_HOME_IN_CLUSTER) resolved to the cluster sim path
        staged_e = fake.staged.get("e.yml", "")
        check("$(SIM_HOME_IN_CLUSTER)" not in staged_e, "placeholder resolved in staged exp")
        check(f"{L['remote_run_dir']}/config/nopref.ini" in staged_e,
              "placeholder -> remote_sim_path, repointed at the run_dir config snapshot")
        check("$(BASE)" in staged_e, "other $(...) tokens left for create_jobfile")
        check(not any('"$HOME"' in c for _, c in fake.events), "no $HOME lookup without a $HOME or ~ path")


def test_submit_smoke_fail():
    print("test_submit_smoke_fail")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        fake.cj_report = {
            "tool": "create_jobfile", "status": "error", "error_id": "CJ_SMOKE_FAILED",
            "message": "smoke test failed (exit=134); no jobs submitted",
            "smoke": {"rc": 134, "output_tail": "terminate called ... bad_alloc"},
            "submitted": False, "jobs": [], "submit_failures": [],
        }
        try:
            cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None,
                             label="", smoke_idx="0", smoke_warmup="1000",
                             smoke_sim="1000", no_snapshot_exe=False))
            check(False, "submit should raise on smoke fail")
        except cr.ClusterRunError as ex:
            check("CJ_SMOKE_FAILED" in str(ex), "error mentions CJ_SMOKE_FAILED")
            check("bad_alloc" in str(ex), "error includes smoke output tail")
        check(cr.all_ledgers(repo) == [], "no ledger written on smoke fail")


def test_submit_partial():
    print("test_submit_partial")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        # one sbatch succeeded, one failed -> CJ_SUBMIT_FAILED but a real job exists
        fake.cj_report = {
            "tool": "create_jobfile", "status": "error", "error_id": "CJ_SUBMIT_FAILED",
            "message": "1 of 2 sbatch submission(s) failed", "exe": "/c/Hermes/bin/glc-X",
            "exe_original": "/c/Hermes/bin/glc-X", "smoke": {"rc": 0},
            "submitted": True,
            "jobs": [{"tag": "traceX_exp1", "job_id": "9001", "submit_rc": 0},
                     {"tag": "traceY_exp1", "job_id": None, "submit_rc": 1}],
            "submit_failures": [{"tag": "traceY_exp1", "submit_rc": 1, "stderr_tail": "quota exceeded"}],
        }
        rc = cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None,
                              label="", smoke_idx="0", smoke_warmup="1000",
                              smoke_sim="1000", no_snapshot_exe=False))
        check(rc == 1, "partial submit returns 1")
        L = cr.all_ledgers(repo)
        check(len(L) == 1, "ledger written for partial submit (jobs not orphaned)")
        check(L[0]["status"] == "partial", "status partial")
        check([j["job_id"] for j in L[0]["jobs"]] == ["9001"], "only launched job recorded")


def test_status_and_rollup():
    print("test_status_and_rollup")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        fake.cj_report = {
            "tool": "create_jobfile", "status": "ok", "exe": "/c/Hermes/bin/glc-X",
            "exe_original": "/c/Hermes/bin/glc-X", "smoke": {"rc": 0},
            "jobs": [{"tag": "traceX_exp1", "job_id": "100", "submit_rc": 0},
                     {"tag": "traceY_exp1", "job_id": "101", "submit_rc": 0}],
            "submit_failures": [],
        }
        cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None, label="",
                         smoke_idx="0", smoke_warmup="1000", smoke_sim="1000",
                         no_snapshot_exe=False))
        batch = cr.all_ledgers(repo)[0]["batch_id"]

        # status: 100 running, 101 already done (not in squeue -> sacct)
        fake.squeue = "100|RUNNING\n"
        fake.sacct = "101|COMPLETED|0:0\n101.batch|COMPLETED|0:0\n"
        cr.cmd_status(ns(repo=repo, batch=batch, all=False, cluster=None))
        L = cr.load_ledger(repo, batch)
        states = {j["job_id"]: j["state"] for j in L["jobs"]}
        check(states == {"100": "RUNNING", "101": "COMPLETED"}, "status merged squeue+sacct")
        check(L["status"] == "running", "batch still running (one active)")

        # rollup should refuse while a job is active (no --force)
        try:
            cr.cmd_rollup(ns(repo=repo, batch=batch, cluster=None, tol=0.0,
                             no_compare=True, force=False))
            check(False, "rollup should refuse incomplete batch")
        except cr.ClusterRunError as ex:
            check("not complete" in str(ex), "rollup refuses incomplete")

        # now everything terminal
        fake.squeue = ""
        fake.sacct = "100|COMPLETED|0:0\n101|COMPLETED|0:0\n"
        cr.cmd_status(ns(repo=repo, batch=batch, all=False, cluster=None))
        check(cr.load_ledger(repo, batch)["status"] == "complete", "batch complete")

        # rollup
        fake.rollup_report = {
            "tool": "rollup", "status": "ok",
            "summary": {"total": 2, "passed": 2, "filtered": 0, "failed": 0},
            "runs": [{"trace": "traceX", "exp": "exp1", "status": "ok",
                      "error_id": "RU_OK", "reason": ""}],
        }
        rc = cr.cmd_rollup(ns(repo=repo, batch=batch, cluster=None, tol=0.0,
                              no_compare=False, force=False))
        check(rc == 0, "rollup rc")
        L = cr.load_ledger(repo, batch)
        check(L["status"] == "rolledup", "ledger rolledup")
        local_csv = os.path.join(cr.runs_dir(repo), batch, "stats.csv")
        check(os.path.isfile(local_csv), "stats.csv fetched locally")
        check(L["stats_csv"] == local_csv, "ledger records stats_csv")
        run_dir = L["remote_run_dir"]
        ru = [c for _, c in fake.ssh_calls if "rollup.py" in c][-1]
        check(f"python3.12 {run_dir}/scripts/rollup.py " in ru,
              "self-contained batch rolls up with its own rollup.py")
        check(f"--mfile {run_dir}/inputs/m.yml" in ru, "with the batch's own inputs")


def test_live_tree_helpers():
    print("test_live_tree_helpers")
    sim, run = "/c/Hermes", "/c/runs/Hermes/B1"
    text = ("--config=/c/Hermes/config/a.ini\n"
            "CFG: \"/c/Hermes/config\"\n"
            "--config=/c/Hermes/configs/b.ini\n"
            "--config=/c/Hermes2/config/c.ini\n")
    new, n = cr.rewrite_config_paths(text, sim, run)
    check(n == 2, "repoints config files and the bare config dir")
    check(new.splitlines()[:2] == ["--config=/c/runs/Hermes/B1/config/a.ini",
                                   "CFG: \"/c/runs/Hermes/B1/config\""],
          "config paths -> run_dir snapshot")
    check(new.splitlines()[2:] == text.splitlines()[2:], "sibling dir / sibling tree not repointed")
    check([i for i, _ in cr.live_tree_refs(new, sim, run)] == [3],
          "a sibling configs/ still reads the live tree; a sibling tree does not")
    nested = sim + "/runs/B1"
    check(cr.live_tree_refs(f"--config={nested}/config/a.ini", sim, nested) == [],
          "run dir nested inside the sim tree is not live")
    far = "--config=/scratch/c/Hermes/config/a.ini --w=/scratch/c/Hermes/data/w.bin\n"
    check(cr.rewrite_config_paths(far, sim, run) == (far, 0),
          "a longer path that merely ends with the sim path is not repointed")
    check([i for i, _ in cr.live_tree_refs(far, sim, run)] == [1],
          "but refused: it may be another spelling of the live tree, e.g. a mount alias")
    new, n = cr.rewrite_config_paths(text, sim, run, ["configs"])
    check(n == 1 and new.splitlines()[2] == "--config=/c/runs/Hermes/B1/configs/b.ini"
          and new.splitlines()[:2] == text.splitlines()[:2], "snapshot_dirs picks the repointed dirs")
    back, n = cr.swap_dirs(cr.rewrite_config_paths(text, sim, run)[0], run, sim, ["config"])
    check((back, n) == (text, 2), "swap_dirs maps a snapshot back to the sim tree")


def test_submit_self_contained():
    print("test_submit_self_contained")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        _, e, m = make_inputs(repo)
        # a tlist path under the sim's config/ stays as written: only exps are repointed
        t = os.path.join(repo, "t.yml")
        open(t, "w").write("---\nsuiteA:\n"
                           "  - traceX: {path: $(SIM_HOME_IN_CLUSTER)/config/x.zst, version: 2}\n")
        e_src = open(e).read()
        fake.cj_report = ok_cj_report("7001")
        rc = cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None,
                              label="", smoke_idx="0", smoke_warmup="1000",
                              smoke_sim="1000", no_snapshot_exe=False))
        check(rc == 0, "submit rc")
        L = cr.all_ledgers(repo)[0]
        run_dir = L["remote_run_dir"]
        check(L["self_contained"] is True, "ledger marks the batch self-contained")
        check(L["snapshot"] == {"config": run_dir + "/config", "scripts": run_dir + "/scripts"},
              "ledger records where the snapshot lives")

        cmds = [c for _, c in fake.events]

        def first(sub):
            return next((i for i, c in enumerate(cmds) if sub in c), -1)
        build = first("build_champsim.sh")
        cp_config = first(f"cp -a {SIM}/config {run_dir}/config")
        cp_scripts = first(f"cp -a {INFRA}/scripts {run_dir}/scripts")
        cj = first("create_jobfile.py")
        check(-1 < build < cp_config and build < cp_scripts, "snapshot copies issued after the build")
        check(-1 < cp_config < cj and -1 < cp_scripts < cj,
              "snapshot copies issued before create_jobfile")
        check(f"{run_dir}/scripts/create_jobfile.py" in cmds[cj], "create_jobfile runs from run_dir/scripts")
        check(first(f"{INFRA}/scripts/create_jobfile.py") == -1, "live infra create_jobfile never run")

        staged_e = fake.staged.get("e.yml", "")
        check(f"--config={run_dir}/config/nopref.ini" in staged_e, "staged exp --config -> run_dir snapshot")
        check(SIM not in staged_e, "staged exp no longer names the live sim tree")
        check(f"path: {SIM}/config/x.zst" in fake.staged.get("t.yml", ""), "tlist paths not rewritten")
        check(open(e).read() == e_src, "local exp source untouched")


def test_submit_refuses_live_tree():
    print("test_submit_refuses_live_tree")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        e_src = ("---\nexperiments:\n"
                 "  - exp1: \"--config=$(SIM_HOME_IN_CLUSTER)/config/nopref.ini\"\n"
                 "  - exp2: \"--weights=$(SIM_HOME_IN_CLUSTER)/data/w.bin\"\n")
        open(e, "w").write(e_src)
        try:
            cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None,
                             label="", smoke_idx="0", smoke_warmup="1000",
                             smoke_sim="1000", no_snapshot_exe=False))
            check(False, "submit should refuse an exp that reads the live sim tree")
        except cr.ClusterRunError as ex:
            check(f"{e}:4:" in str(ex) and f"{SIM}/data/w.bin" in str(ex),
                  "error lists the offending occurrence with file and line")
            check("nopref.ini" not in str(ex), "repointed --config line not listed")
            check("Write each path inside it as $(SIM_HOME_IN_CLUSTER)/<dir>/" in str(ex),
                  "refusal suggests the $(SIM_HOME_IN_CLUSTER) spelling")
        check(fake.events == [], "refused before any remote work")
        check(open(e).read() == e_src, "local exp source untouched")
        check(cr.all_ledgers(repo) == [], "no ledger on refusal")


def test_submit_configs_dir():
    print("test_submit_configs_dir")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        cfg = cr.load_config(repo)
        cfg["snapshot_dirs"] = ["configs", "data"]  # a ChampSim tree: runtime TOMLs in configs/
        cr.save_config(repo, cfg)
        t, e, m = make_inputs(repo)
        open(e, "w").write("---\nexperiments:\n"
                           "  - exp1: \"--config $(SIM_HOME_IN_CLUSTER)/configs/champsim_config.toml\"\n")
        fake.cj_report = ok_cj_report("8201")
        fake.cp_out = cr.SNAPSHOT_SKIP + "data\n"  # this cluster's sim tree has no data/
        args = ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None, label="",
                  smoke_idx="0", smoke_warmup="1000", smoke_sim="1000", no_snapshot_exe=False)
        rc = cr.cmd_submit(args)
        check(rc == 0, "submit rc")
        L = cr.all_ledgers(repo)[0]
        run_dir = L["remote_run_dir"]
        check(f"--config {run_dir}/configs/champsim_config.toml" in fake.staged.get("e.yml", ""),
              "configs/ path repointed at the run_dir snapshot")
        cp = next(c for _, c in fake.ssh_calls if c.startswith("cp -a"))
        check(f"cp -a {SIM}/configs {run_dir}/configs" in cp and f"{SIM}/config " not in cp,
              "snapshot copies configs/, not config/")
        check(L["snapshot"] == {"configs": run_dir + "/configs", "scripts": run_dir + "/scripts"},
              "a listed dir missing on the cluster is skipped and left out of the ledger")

        # config/ is not listed here, so an exp reading it is refused
        open(e, "w").write("---\nexperiments:\n"
                           "  - exp1: \"--config=$(SIM_HOME_IN_CLUSTER)/config/x.ini\"\n")
        fake.events.clear()
        args.label = "refused"  # a new batch id: the first submit's may be from this same second
        try:
            cr.cmd_submit(args)
            check(False, "submit should refuse a config/ path outside snapshot_dirs")
        except cr.ClusterRunError as ex:
            check(f"{SIM}/config/x.ini" in str(ex) and "snapshot_dirs" in str(ex),
                  "refusal names the path and points at snapshot_dirs")
        check(fake.events == [], "refused before any remote work")


def test_submit_snapshot_fail():
    print("test_submit_snapshot_fail")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        fake.cj_report = ok_cj_report("8001")
        fake.cp_rc = 1
        try:
            cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None,
                             label="", smoke_idx="0", smoke_warmup="1000",
                             smoke_sim="1000", no_snapshot_exe=False))
            check(False, "submit should fail when the snapshot copy fails")
        except cr.ClusterRunError as ex:
            check("snapshot" in str(ex) and "cannot stat" in str(ex), "error names the failed snapshot")
        check(not any("create_jobfile.py" in c for _, c in fake.ssh_calls),
              "no create_jobfile (so no jobs) after a failed snapshot")
        check(cr.all_ledgers(repo) == [], "no ledger on snapshot failure")


def test_submit_no_snapshot_exe():
    print("test_submit_no_snapshot_exe")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        fake.cj_report = ok_cj_report("8101")
        cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[e], mfile=[m], cluster=None,
                         label="", smoke_idx="0", smoke_warmup="1000",
                         smoke_sim="1000", no_snapshot_exe=True))
        L = cr.all_ledgers(repo)[0]
        cj = [c for _, c in fake.ssh_calls if "create_jobfile.py" in c][0]
        check("--no-snapshot-exe" in cj, "--no-snapshot-exe forwarded")
        check(L["self_contained"] is False, "live binary -> ledger not self-contained")
        check(L["snapshot"]["scripts"] == L["remote_run_dir"] + "/scripts",
              "config + scripts still snapshotted")


def test_rollup_pre_snapshot_ledger():
    print("test_rollup_pre_snapshot_ledger")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        batch = "20260101T000000Z_old"
        cr.save_ledger(repo, make_ledger(batch, snapshot=False))
        fake.rollup_report = {"tool": "rollup", "status": "ok", "summary": {}, "runs": []}
        rc = cr.cmd_rollup(ns(repo=repo, batch=batch, cluster=None, tol=0.0,
                              no_compare=True, force=False))
        check(rc == 0, "rollup rc")
        ru = [c for _, c in fake.ssh_calls if "rollup.py" in c][0]
        check(f"python3.12 {INFRA}/scripts/rollup.py " in ru,
              "pre-snapshot ledger rolls up via the live infra")
        check(f"--mfile {RUNS}/{batch}/inputs/m.yml" in ru, "with the batch's own inputs")


def test_combine_rollup_script():
    print("test_combine_rollup_script")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        fake.rollup_report = {"tool": "rollup", "status": "ok", "summary": {}, "runs": []}
        old, new = "20260101T000000Z_a", "20260102T000000Z_b"

        # newest batch has a snapshot -> its rollup.py, though --batches lists it last
        save_batch(repo, fake, old, snapshot=False)
        save_batch(repo, fake, new, snapshot=True)
        cr.cmd_combine(ns(repo=repo, batches=f"{old},{new}", cluster=None,
                          out_name=None, force=False))
        ru = [c for _, c in fake.ssh_calls if "rollup.py" in c][-1]
        check(f"python3.12 {RUNS}/{new}/scripts/rollup.py " in ru,
              "combine uses the newest batch's snapshot")
        check(f"-d {RUNS}/{old} {RUNS}/{new} -o" in ru, "combine still spans both run dirs")
        combo = f"{RUNS}/combine_{new}/inputs"
        check(f"--exp {combo}/{old}__e.yml {combo}/{new}__e.yml -d" in ru,
              "combine merges per-batch exp copies, in --batches order")

        # newest batch has no snapshot -> live infra, though an older one has one
        save_batch(repo, fake, old, snapshot=True)
        save_batch(repo, fake, new, snapshot=False)
        cr.cmd_combine(ns(repo=repo, batches=f"{new},{old}", cluster=None,
                          out_name=None, force=False))
        ru = [c for _, c in fake.ssh_calls if "rollup.py" in c][-1]
        check(f"python3.12 {INFRA}/scripts/rollup.py " in ru, "combine falls back to the live infra")


def test_combine_normalizes_exps():
    print("test_combine_normalizes_exps")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        fake.rollup_report = {"tool": "rollup", "status": "ok", "summary": {}, "runs": []}
        t, e, m = make_inputs(repo)
        e2 = os.path.join(repo, "e2.yml")  # batch b adds exp2, repeating BASE as it must
        open(e2, "w").write(open(e).read().replace("exp1", "exp2"))
        for label, exp, jid in [("a", e, "9101"), ("b", e2, "9102")]:
            fake.cj_report = ok_cj_report(jid)
            cr.cmd_submit(ns(repo=repo, tlist=[t], exp=[exp], mfile=[m], cluster=None,
                             label=label, smoke_idx="0", smoke_warmup="1000",
                             smoke_sim="1000", no_snapshot_exe=False))
        a, b = (next(l["batch_id"] for l in cr.all_ledgers(repo) if l["batch_id"].endswith(s))
                for s in ("_a", "_b"))
        old = save_batch(repo, fake, "20260101T000000Z_old", snapshot=False)["batch_id"]
        clash = save_batch(repo, fake, "20260101T000000Z_clash", snapshot=True,
                           exp="exp2", extra=" --knob=1")["batch_id"]

        def staged(ids):
            led = {l["batch_id"]: l for l in cr.all_ledgers(repo)}
            return [led[i]["remote_inputs"]["exp"][0] for i in ids]

        def merged(paths):
            """The real rollup merge of these fake-cluster files: {exp: params}, or its abort."""
            local = []
            for i, p in enumerate(paths):
                local.append(os.path.join(repo, f"merge{i}_{os.path.basename(p)}"))
                with open(local[-1], "w") as f:
                    f.write(fake.remote_files.get(p, ""))
            try:
                return {x.name: x.params for x in rollup.create_experiments(local)}
            except SystemExit as ex:
                return str(ex)

        def combine(ids, name):
            cr.cmd_combine(ns(repo=repo, batches=",".join(ids), cluster=None,
                              out_name=name, force=True))
            copies = [f"{RUNS}/{name}/inputs/{i}__{os.path.basename(p)}"
                      for i, p in zip(ids, staged(ids))]
            ru = [c for _, c in fake.ssh_calls if "rollup.py" in c][-1]
            check("--exp " + " ".join(copies) + " -d" in ru, f"{name}: rollup reads the copies")
            return copies

        want = f"--config={SIM}/config/nopref.ini"
        for ids, what in [((a, b), "new_new"), ((old, b), "old_new")]:
            check("Conflict: definition 'BASE'" in str(merged(staged(ids))),
                  f"{what}: the staged exps themselves conflict")
            got = merged(combine(ids, "combine_" + what))
            check(got == {"exp1": want, "exp2": want},
                  f"{what}: the normalized copies merge under the real rollup: {got}")
        got = merged(combine((b, clash), "combine_clash"))
        check("Conflict: experiment 'exp2'" in str(got),
              f"a real conflict still aborts the real rollup: {got}")


def test_path_spellings():
    print("test_path_spellings")
    sim, run, home = "/c/Hermes", "/c/runs/Hermes/B1", "/c"
    cases = [  # (exp text, paths repointed, refused)
        ("--config=/c/Hermes/config/a.ini", 1, False),
        # the sim path as the tail of a longer path (a mount alias, //, a glued prefix): refused
        ("--config=/x/c/Hermes/config/a.ini", 0, True),
        ("--w=//c/Hermes/data/w.bin", 0, True),
        ("-w/c/Hermes/data/w.bin", 0, True),
        ("--config=a@/c/Hermes/config/a.ini", 0, True),
        # '+', '~' and '@' continue a name: another dir of the tree, or a sibling tree
        ("--config=/c/Hermes/config+old/a.ini", 0, True),
        ("--config=/c/Hermes/config~/a.ini", 0, True),
        ("--config=/c/Hermes/config@2/a.ini", 0, True),
        ("--config=/c/Hermes+2/config/a.ini", 0, False),
        ("--config=/c/Hermes@2/config/a.ini", 0, False),
        ("--config=/c/Hermes~/config/a.ini", 0, False),
        # spellings that resolve to the live tree: refused, never repointed
        ("--config=/c//Hermes/config/a.ini", 0, True),
        ("--config=/c/./Hermes/config/a.ini", 0, True),
        ("--config=/c/runs/../Hermes/config/a.ini", 0, True),
        ("--config=../../../Hermes/config/a.ini", 0, True),  # from the run dir, the jobs' cwd
        ("--config=$HOME/Hermes/config/a.ini", 0, True),
        ("--config=${HOME}/Hermes/config/a.ini", 0, True),
        ("--config ~/Hermes/config/a.ini", 0, True),
        ("--config=/c/Hermes/config/../data/w.bin", 0, True),
        ("--config=/c/Hermes/config//a.ini", 0, True),
        # ... and ones that resolve elsewhere
        ("--config=/c/runs//Hermes/B1/config/a.ini", 0, False),
        ("--config=$HOME/other/a.ini", 0, False),
        ("--config=$HOMEDIR/Hermes/config/a.ini", 0, False),
    ]
    for line, n, refused in cases:
        new, got = cr.rewrite_config_paths(line, sim, run, ["config"])
        refs = cr.live_tree_refs(new, sim, run, home)
        check((got, bool(refs)) == (n, refused),
              f"{line}: want repointed={n} refused={refused}, got {got} {refs}")
    refs = cr.live_tree_refs("--config=/c//Hermes/config/a.ini", sim, run, home)
    check(bool(refs) and refs[0][1].endswith("(/c//Hermes/config/a.ini resolves to /c/Hermes/config/a.ini)"),
          f"the refusal shows what a spelling resolves to: {refs}")


def test_submit_refuses_spellings():
    print("test_submit_refuses_spellings")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        home = ("ssh", 'printf %s "$HOME"')
        want = f"resolves to {SIM}/config/nopref.ini"
        cases = [  # (exp body, $HOME read, the refusal shows)
            ('experiments:\n  - exp1: "--config=$HOME/Hermes/config/nopref.ini"\n', True, want),
            ('experiments:\n  - exp1: "--config ~/Hermes/config/nopref.ini"\n', True, want),
            ('experiments:\n  - exp1: "--config=/cluster/home/rahbera/runs/../Hermes/config/nopref.ini"\n',
             False, want),
            # a path split across definitions: a trailing slash doubles one; a clean split names the tree
            ('definitions:\n  - ROOT: "/cluster/home/rahbera/"\n'
             'experiments:\n  - exp1: "--config=$(ROOT)/Hermes/config/nopref.ini"\n', False, want),
            ('definitions:\n  - ROOT: "/cluster/home/rahbera"\n'
             'experiments:\n  - exp1: "--config=$(ROOT)/Hermes/config/nopref.ini"\n', False,
             f"experiment 'exp1': --config={SIM}/config/nopref.ini"),
        ]
        fake.cj_report = ok_cj_report("6501")  # a submit that isn't refused then fails its check cleanly
        for i, (body, looked_up, shows) in enumerate(cases):
            open(e, "w").write("---\n" + body)
            fake.events.clear()
            try:
                cr.cmd_submit(submit_args(repo, t, e, m, f"s{i}"))
                check(False, f"submit should refuse {body!r}")
            except cr.ClusterRunError as ex:
                check(shows in str(ex), f"refusal shows {shows!r}: {ex}")
            check(fake.events == ([home] if looked_up else []),
                  f"{body!r}: refused before any change on the cluster ($HOME read: {looked_up})")
            check(cr.all_ledgers(repo) == [], "no ledger on refusal")


def test_submit_lock():
    print("test_submit_lock")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        lock = os.path.join(cr.state_dir(repo), "submit.lock")

        def held():
            with open(lock, "a") as fh:
                try:
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return False
                except BlockingIOError:
                    return True

        during, base_ssh = [], fake.ssh

        def ssh(host, cmd):
            if "create_jobfile.py" in cmd:
                during.append(held())
            return base_ssh(host, cmd)
        cr.ssh = ssh

        fake.cj_report = ok_cj_report("6001")
        cr.cmd_submit(submit_args(repo, t, e, m, "a"))
        check(during == [True], "the lock is held while create_jobfile runs")
        check(not held(), "and released when submit returns")
        fake.cj_report = {"tool": "create_jobfile", "status": "error", "error_id": "CJ_SMOKE_FAILED",
                          "message": "smoke test failed", "smoke": {"rc": 1}, "jobs": []}
        try:
            cr.cmd_submit(submit_args(repo, t, e, m, "b"))
        except cr.ClusterRunError:
            pass
        check(not held(), "and when submit fails")

        # A submit that finds the lock held waits, before it picks a batch id.
        fake.cj_report = ok_cj_report("6002")
        logs, stamps, errs = [], [], []
        real_log, real_stamp = cr.log, cr.utc_stamp
        cr.log, cr.utc_stamp = logs.append, lambda: stamps.append(1) or real_stamp()
        events = len(fake.events)

        def submit():
            try:
                cr.cmd_submit(submit_args(repo, t, e, m, "c"))
            except BaseException as ex:  # noqa: BLE001
                errs.append(ex)
        th = threading.Thread(target=submit, daemon=True)
        holder = open(lock, "a")
        try:
            fcntl.flock(holder, fcntl.LOCK_EX)
            th.start()
            deadline = time.monotonic() + 10
            while not any("waiting" in x for x in logs) and time.monotonic() < deadline:
                time.sleep(0.01)
            time.sleep(0.2)
            check(any("waiting for another submit" in x for x in logs), "a blocked submit says it is waiting")
            check(stamps == [] and len(fake.events) == events, "and picks no batch id and does no remote work")
            fcntl.flock(holder, fcntl.LOCK_UN)
            th.join(10)
        finally:
            holder.close()
            cr.log, cr.utc_stamp = real_log, real_stamp
        check(not th.is_alive() and not errs, f"it proceeds once the lock is free: {errs}")
        check(any(l["batch_id"].endswith("_c") for l in cr.all_ledgers(repo)), "and logs its batch")


def test_submit_batch_id_claim():
    print("test_submit_batch_id_claim")
    stamp, real_stamp = "20260910T120000Z", cr.utc_stamp
    cr.utc_stamp = lambda: stamp  # every submit below starts in the same UTC second
    try:
        with tempfile.TemporaryDirectory() as repo:
            fake = FakeCluster()
            _bootstrap(repo, fake)
            t, e, m = make_inputs(repo)
            claimed, base_ssh = [], fake.ssh

            def ssh(host, cmd):
                if "create_jobfile.py" in cmd:
                    claimed.append(cr.load_ledger(repo, stamp)["status"])
                return base_ssh(host, cmd)
            cr.ssh = ssh
            fake.cj_report = ok_cj_report("111")
            cr.cmd_submit(submit_args(repo, t, e, m))
            check(claimed == [cr.SUBMITTING], "the ledger is claimed, as a placeholder, before create_jobfile runs")
            check([c for _, c in fake.ssh_calls if c.startswith("mkdir")]
                  == [f"mkdir -p {RUNS} && mkdir {RUNS}/{stamp} {RUNS}/{stamp}/inputs"],
                  "only the runs base gets mkdir -p")
            events = len(fake.events)
            fake.cj_report = ok_cj_report("222")
            try:
                cr.cmd_submit(submit_args(repo, t, e, m))
                check(False, "a second submit with the same batch id should be refused")
            except cr.ClusterRunError as ex:
                check(f"batch {stamp} is already taken" in str(ex), "the refusal names the batch id")
            check(len(fake.events) == events, "refused before any remote work")
            check([j["job_id"] for l in cr.all_ledgers(repo) for j in l["jobs"]] == ["111"],
                  "the first submit's job ids survive")

        # Two checkouts sharing one cluster tree: the plain mkdir of the run dir is the claim there.
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as a, \
                tempfile.TemporaryDirectory() as b:
            fake = ShellCluster()
            local_cluster(root, a, fake)
            local_cluster(root, b, fake)
            fake.cj_report = ok_cj_report("333")
            cr.cmd_submit(submit_args(a, *make_inputs(a)))
            events = len(fake.events)
            try:
                cr.cmd_submit(submit_args(b, *make_inputs(b)))
                check(False, "the second checkout's submit should fail on the taken run dir")
            except cr.ClusterRunError as ex:
                check(f"another submit took batch id {stamp}" in str(ex), f"says the batch id is taken: {ex}")
            later = fake.events[events:]
            check(len(later) == 1 and later[0][1].startswith("mkdir"), f"before copying anything: {later}")
            check(cr.all_ledgers(b) == [], "and drops its placeholder: nothing was queued")
            check([j["job_id"] for l in cr.all_ledgers(a) for j in l["jobs"]] == ["333"],
                  "the first checkout's batch is intact")
    finally:
        cr.utc_stamp = real_stamp


def test_submit_no_report():
    print("test_submit_no_report")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        t, e, m = make_inputs(repo)
        fake.cj_stdout = "[submit] traceX_exp1 -> job 7101\n"  # the connection dropped before the report
        try:
            cr.cmd_submit(submit_args(repo, t, e, m, "lost"))
            check(False, "submit should fail without create_jobfile's report")
        except cr.ClusterRunError as ex:
            check("MAY have queued jobs" in str(ex), "says the batch may have queued jobs")
        L = cr.all_ledgers(repo)
        check(len(L) == 1 and L[0]["status"] == cr.SUBMITTING and L[0]["jobs"] == [],
              "keeps the claimed placeholder, so the batch id isn't reused")
        batch = L[0]["batch_id"]
        cr.cmd_status(ns(repo=repo, batch=None, all=False, cluster=None))
        check(cr.load_ledger(repo, batch) == L[0] and not any("squeue" in c for _, c in fake.ssh_calls),
              "status lists the placeholder and leaves it unchanged")
        for verb, a in [(cr.cmd_rollup, ns(repo=repo, batch=batch, cluster=None, tol=0.0,
                                           no_compare=True, force=True)),
                        (cr.cmd_combine, ns(repo=repo, batches=f"{batch},{batch}", cluster=None,
                                            out_name="combined", force=True))]:
            try:
                verb(a)
                check(False, f"{verb.__name__} should refuse a placeholder")
            except cr.ClusterRunError as ex:
                check("no recorded jobs" in str(ex), f"{verb.__name__} refuses the placeholder")


def test_submit_skipped_dir_referenced():
    print("test_submit_skipped_dir_referenced")
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as repo:
        fake = ShellCluster()
        local_cluster(root, repo, fake, dirs=["config", "data"])  # this cluster's sim tree has no data/
        t, e, m = make_inputs(repo)
        open(e, "w").write("---\ndefinitions:\n"
                           "  - W: \"--weights=$(SIM_HOME_IN_CLUSTER)/data/w.bin\"\n"
                           "experiments:\n  - exp0: \"--config=$(SIM_HOME_IN_CLUSTER)/config/nopref.ini\"\n"
                           "  - exp1: \"$(W)\"\n")
        fake.cj_report = ok_cj_report("6301")
        try:
            cr.cmd_submit(submit_args(repo, t, e, m, "a"))
            check(False, "submit should fail when an exp reads a skipped snapshot_dirs entry")
        except cr.ClusterRunError as ex:
            check("snapshot_dirs entry 'data'" in str(ex) and f"{e} now read" in str(ex),
                  f"names the skipped dir and the exp repointed into it: {ex}")
        check(not any("create_jobfile.py" in c for _, c in fake.ssh_calls), "fails before create_jobfile")
        check(cr.all_ledgers(repo) == [], "no ledger")
        open(e, "w").write("---\nexperiments:\n  - exp0: \"--config=$(SIM_HOME_IN_CLUSTER)/config/nopref.ini\"\n")
        check(cr.cmd_submit(submit_args(repo, t, e, m, "b")) == 0, "a missing dir no exp reads is skipped")
        check(sorted(cr.all_ledgers(repo)[0]["snapshot"]) == ["config", "scripts"], "and left out of the ledger")


def test_submit_snapshot_symlinks():
    print("test_submit_snapshot_symlinks")
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as repo:
        fake = ShellCluster()
        sim = local_cluster(root, repo, fake)
        t, e, m = make_inputs(repo)
        os.makedirs(sim + "/shared")
        open(sim + "/shared/common.ini", "w").write("v1\n")
        os.symlink("nopref.ini", sim + "/config/rel.ini")                   # resolves inside the copy
        os.symlink(sim + "/shared/common.ini", sim + "/config/common.ini")  # resolves to the live tree
        fake.cj_report = ok_cj_report("6401")
        try:
            cr.cmd_submit(submit_args(repo, t, e, m, "a"))
            check(False, "submit should fail on a snapshot symlink out of the run dir")
        except cr.ClusterRunError as ex:
            real = os.path.realpath(sim + "/shared/common.ini")
            check(f"/config/common.ini -> {real}" in str(ex) and "rel.ini" not in str(ex),
                  f"names the link that leaves the run dir, not the one inside it: {ex}")
        check(not any("create_jobfile.py" in c for _, c in fake.ssh_calls), "fails before create_jobfile")
        check(cr.all_ledgers(repo) == [], "no ledger")

        os.remove(sim + "/config/common.ini")
        check(cr.cmd_submit(submit_args(repo, t, e, m, "b")) == 0, "a link inside the copied dir passes")
        run_dir = cr.all_ledgers(repo)[0]["remote_run_dir"]
        check(os.readlink(run_dir + "/config/rel.ini") == "nopref.ini", "and is copied as a link")

        os.makedirs(root + "/elsewhere")
        os.symlink(root + "/elsewhere", sim + "/data")  # a snapshot_dirs entry that is itself a link out
        cfg = cr.load_config(repo)
        cfg["snapshot_dirs"] = ["config", "data"]
        cr.save_config(repo, cfg)
        try:
            cr.cmd_submit(submit_args(repo, t, e, m, "c"))
            check(False, "submit should fail when a snapshot dir is a link out of the run dir")
        except cr.ClusterRunError as ex:
            check(f"/data -> {os.path.realpath(root + '/elsewhere')}" in str(ex), f"names the linked dir: {ex}")


def test_combine_refuses_batch_id_name():
    print("test_combine_refuses_batch_id_name")
    with tempfile.TemporaryDirectory() as repo:
        fake = FakeCluster()
        _bootstrap(repo, fake)
        a = save_batch(repo, fake, "20260101T000000Z_a", snapshot=True)["batch_id"]
        b = save_batch(repo, fake, "20260102T000000Z_b", snapshot=True)["batch_id"]
        files = dict(fake.remote_files)
        fake.rollup_report = {"tool": "rollup", "status": "ok", "summary": {}, "runs": []}
        try:
            cr.cmd_combine(ns(repo=repo, batches=f"{a},{b}", cluster=None, out_name=b, force=True))
            check(False, "combine should refuse an --out-name that is a batch id")
        except cr.ClusterRunError as ex:
            check(f"--out-name {b} is a batch id" in str(ex), "the refusal names the batch id")
        check(fake.events == [] and fake.remote_files == files, "refused before touching that batch's inputs")
        check(not os.path.exists(os.path.join(cr.runs_dir(repo), b, "stats.csv")), "or its local stats.csv")


def main():
    for fn in [test_pure_helpers, test_substitution, test_live_tree_helpers, test_path_spellings,
               test_bootstrap, test_submit_success, test_submit_smoke_fail, test_submit_partial,
               test_submit_self_contained, test_submit_refuses_live_tree,
               test_submit_refuses_spellings, test_submit_configs_dir, test_submit_snapshot_fail,
               test_submit_no_snapshot_exe, test_submit_lock, test_submit_batch_id_claim,
               test_submit_no_report, test_submit_skipped_dir_referenced,
               test_submit_snapshot_symlinks, test_status_and_rollup,
               test_rollup_pre_snapshot_ledger, test_combine_rollup_script,
               test_combine_normalizes_exps, test_combine_refuses_batch_id_name]:
        fn()
    print(f"\n{_checks['pass']} passed, {_checks['fail']} failed")
    sys.exit(1 if _checks["fail"] else 0)


if __name__ == "__main__":
    main()
