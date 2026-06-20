#!/usr/bin/env python3.12
"""Repeatable tests for the create_jobfile.py / rollup.py JSON-report additions
and their backward compatibility. Cluster-free: a fake champsim binary and a fake
sbatch (on PATH) stand in for the real tools.

Run: python3.12 tests/test_reports.py
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
CREATE_JOBFILE = os.path.join(SCRIPTS, "create_jobfile.py")
ROLLUP = os.path.join(SCRIPTS, "rollup.py")
PY = "python3.12"

_checks = {"pass": 0, "fail": 0}


def check(cond, msg):
    if cond:
        _checks["pass"] += 1
    else:
        _checks["fail"] += 1
        print(f"  FAIL: {msg}")


def infra_json(stdout):
    b = stdout.split("===INFRA-JSON-BEGIN===", 1)[1].split("===INFRA-JSON-END===", 1)[0]
    return json.loads(b)


def write(path, text, mode=0o644):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def make_fixtures(d):
    write(os.path.join(d, "champsim_ok"),
          "#!/bin/bash\necho 'Core_0_cumulative_IPC 1.234'\nexit 0\n", 0o755)
    write(os.path.join(d, "champsim_bad"),
          "#!/bin/bash\necho \"terminate called ... std::bad_alloc\" >&2\nexit 134\n", 0o755)
    bind = os.path.join(d, "bin")
    os.makedirs(bind, exist_ok=True)
    # fake sbatch: with --parsable, print an incrementing job id.
    write(os.path.join(bind, "sbatch"),
          "#!/bin/bash\n"
          "cnt=\"$TMPDIR/.sbcount\"\n"
          "n=$(cat \"$cnt\" 2>/dev/null || echo 7000); n=$((n+1)); echo \"$n\" > \"$cnt\"\n"
          "for a in \"$@\"; do [ \"$a\" = \"--parsable\" ] && echo \"$n\" && exit 0; done\n"
          "echo \"Submitted batch job $n\"; exit 0\n", 0o755)
    write(os.path.join(d, "t.yml"),
          "---\nsuiteA:\n  - traceX: {path: /nfs/x.zst, version: 2}\n"
          "  - traceY: {path: /nfs/y.zst, version: 2}\n")
    write(os.path.join(d, "e.yml"),
          "---\ndefinitions:\n  - BASE: \"--config base.ini\"\nexperiments:\n  - exp1: \"$(BASE)\"\n")
    return bind


def run_cj(d, env, extra):
    cmd = [PY, CREATE_JOBFILE, "--no-snapshot-exe", "--no-trace-cache",
           "--tlist", os.path.join(d, "t.yml"), "--exp", os.path.join(d, "e.yml"),
           "-o", os.path.join(d, "jf.sh")] + extra
    return subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def test_create_jobfile_autolaunch():
    print("test_create_jobfile_autolaunch")
    with tempfile.TemporaryDirectory() as d:
        bind = make_fixtures(d)
        env = dict(os.environ, PATH=bind + os.pathsep + os.environ["PATH"], TMPDIR=d)

        # smoke passes -> both jobs submitted, exact tag->job_id
        r = run_cj(d, env, ["--exe", os.path.join(d, "champsim_ok"),
                            "--smoke-test-auto-launch", "--smoke-warmup", "1000",
                            "--smoke-sim", "1000", "--report-json", "-"])
        check(r.returncode == 0, "autolaunch rc 0 on smoke pass")
        rep = infra_json(r.stdout)
        check(rep["status"] == "ok", "status ok")
        check([j["tag"] for j in rep["jobs"]] == ["traceX_exp1", "traceY_exp1"], "tags in order")
        check(all(j["job_id"] for j in rep["jobs"]), "every job got an id")
        check(len({j["job_id"] for j in rep["jobs"]}) == 2, "distinct job ids")

        # smoke fails -> no submission, CJ_SMOKE_FAILED
        os.remove(os.path.join(d, ".sbcount"))
        r = run_cj(d, env, ["--exe", os.path.join(d, "champsim_bad"),
                            "--smoke-test-auto-launch", "--smoke-warmup", "1000",
                            "--smoke-sim", "1000", "--report-json", "-"])
        check(r.returncode == 1, "autolaunch rc 1 on smoke fail")
        rep = infra_json(r.stdout)
        check(rep["error_id"] == "CJ_SMOKE_FAILED", "error_id CJ_SMOKE_FAILED")
        check(rep["submitted"] is False and rep["jobs"] == [], "nothing submitted")
        check("bad_alloc" in rep["smoke"]["output_tail"], "smoke tail captured")
        check(not os.path.isfile(os.path.join(d, ".sbcount")), "sbatch never ran")


def test_create_jobfile_backward_compat():
    print("test_create_jobfile_backward_compat")
    with tempfile.TemporaryDirectory() as d:
        make_fixtures(d)
        env = dict(os.environ, TMPDIR=d)
        # --local path, exactly as regression/run_regression.py drives it.
        r = run_cj(d, env, ["--exe", "/bin/echo", "--local", "--local-parallel", "2"])
        check(r.returncode == 0, "local-mode rc 0")
        jf = open(os.path.join(d, "jf.sh")).read()
        check("MAX_PARALLEL=2" in jf, "local jobfile has MAX_PARALLEL")
        check(jf.count("[run]") == 2, "2 traces x 1 exp -> 2 local job lines")
        check("Wrote jobfile to" in r.stderr, "writes jobfile message to stderr")
        # default mode emits NO json without --report-json
        check("INFRA-JSON" not in r.stdout, "no JSON unless --report-json")


def test_rollup_reports():
    print("test_rollup_reports")
    with tempfile.TemporaryDirectory() as d:
        s = os.path.join(d, "stats"); os.makedirs(s)
        write(os.path.join(s, "traceX_exp1.out"), "Core_0_cumulative_IPC 1.50\n")
        write(os.path.join(s, "traceX_exp1.err"), "")
        write(os.path.join(s, "traceY_exp1.out"), "partial\n")
        write(os.path.join(s, "traceY_exp1.err"), "Caught signal: Segmentation fault\n")
        write(os.path.join(d, "m.yml"), "---\n- ipc: \"$(Core_0_cumulative_IPC)\"\n")
        write(os.path.join(d, "t.yml"),
              "---\nsuiteA:\n  - traceX: {path: /x, version: 2}\n  - traceY: {path: /y, version: 2}\n")
        write(os.path.join(d, "e.yml"), "---\nexperiments:\n  - exp1: \"--c\"\n")
        out = os.path.join(d, "stats.csv")

        base = [PY, ROLLUP, "--mfile", os.path.join(d, "m.yml"),
                "--tlist", os.path.join(d, "t.yml"), "--exp", os.path.join(d, "e.yml"),
                "-d", s, "-o", out]

        # default mode: summary on stdout, stats.csv written
        r = subprocess.run(base, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(r.returncode == 0, "rollup rc 0")
        check("Wrote 2 rows" in r.stdout, "default summary on stdout")
        csv = open(out).read()
        check("traceX,exp1,1.5,1" in csv, "passing row kept")
        check("traceY,exp1,,0" in csv, "failing row zeroed")

        # report-json mode: structured statuses, summary moved off stdout
        r = subprocess.run(base + ["--report-json", "-"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        rep = infra_json(r.stdout)
        check(rep["status"] == "partial", "rollup status partial")
        byk = {(x["trace"], x["exp"]): x for x in rep["runs"]}
        check(byk[("traceX", "exp1")]["status"] == "ok", "traceX ok")
        check(byk[("traceY", "exp1")]["error_id"] == "RU_FAILURE_KEYWORD:segmentation fault",
              "traceY keyword error id")
        check("Wrote 2 rows" in r.stderr, "summary moved to stderr in json mode")
        check("Wrote 2 rows" not in r.stdout, "stdout clean of summary in json mode")


def main():
    test_create_jobfile_autolaunch()
    test_create_jobfile_backward_compat()
    test_rollup_reports()
    print(f"\n{_checks['pass']} passed, {_checks['fail']} failed")
    sys.exit(1 if _checks["fail"] else 0)


if __name__ == "__main__":
    main()
