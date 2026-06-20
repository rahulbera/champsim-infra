#!/usr/bin/env python3.12
"""In-process tests for cluster_run.py.

The cluster is faked: ssh / ssh_stream / rsync are monkeypatched so the whole
orchestration (bootstrap -> submit -> status -> rollup) runs locally with no
network. Run: python3.12 tests/test_cluster_run.py
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, SCRIPTS)
import cluster_run as cr  # noqa: E402

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
        self.staged = {}
        self.build_rc = 0
        self.build_out = ("g++ -O3 ...\n"
                          "Binary: bin/glc-perceptron-no-multi-multi-multi-multi-1core-1ch\n")
        self.cj_report = None
        self.rollup_report = None
        self.squeue = ""
        self.sacct = ""

    def _cp(self, rc=0, out="", err=""):
        return subprocess.CompletedProcess(["fake"], rc, out, err)

    def ssh(self, host, cmd):
        self.ssh_calls.append((host, cmd))
        if "create_jobfile.py" in cmd:
            return self._cp(out=wrap_json(self.cj_report))
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
        return self.build_rc, self.build_out

    def rsync(self, src, dst, excludes=None, delete=True):
        self.rsync_calls.append((src, dst))
        # capture the staged (substituted) input files for assertions
        if isinstance(dst, str) and dst.rstrip("/").endswith("inputs"):
            self.staged = {}
            for p in (src if isinstance(src, list) else [src]):
                try:
                    self.staged[os.path.basename(p)] = open(p).read()
                except OSError:
                    pass
        if isinstance(dst, str) and dst.endswith("stats.csv"):
            with open(dst, "w") as f:
                f.write("TraceName,ExpName,ipc,Filter\ntraceX,exp1,1.5,1\ntraceY,exp1,1.6,1\n")
        return subprocess.CompletedProcess(["rsync"], 0, "", "")

    def install(self):
        cr.ssh, cr.ssh_stream, cr.rsync = self.ssh, self.ssh_stream, self.rsync


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
        check("/cluster/home/rahbera/Hermes/config/nopref.ini" in staged_e,
              "placeholder -> remote_sim_path in staged exp")
        check("$(BASE)" in staged_e, "other $(...) tokens left for create_jobfile")


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


def main():
    for fn in [test_pure_helpers, test_substitution, test_bootstrap, test_submit_success,
               test_submit_smoke_fail, test_submit_partial, test_status_and_rollup]:
        fn()
    print(f"\n{_checks['pass']} passed, {_checks['fail']} failed")
    sys.exit(1 if _checks["fail"] else 0)


if __name__ == "__main__":
    main()
