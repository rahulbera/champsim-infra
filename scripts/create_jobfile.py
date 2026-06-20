#!/usr/bin/env python3

import yaml
import argparse
import errno
import json
import re
import shlex
import shutil
import subprocess
import sys
import os
import time

sys.path.append(os.path.dirname(os.path.dirname(__file__)))

# Markers wrapping the machine-readable JSON report on stdout (--report-json -),
# so an orchestrator can recover the report even amid other stdout noise. The
# same markers are used by rollup.py and parsed by cluster_run.py.
INFRA_JSON_BEGIN = "===INFRA-JSON-BEGIN==="
INFRA_JSON_END = "===INFRA-JSON-END==="


class CJError(Exception):
    """A create_jobfile failure carrying a stable error_id for the orchestrator.

    Replaces ad-hoc sys.exit() for the failure modes the orchestrator cares
    about: when --report-json is set, main() turns this into a JSON error
    report; otherwise it prints the message and exits 1 (same as the old
    sys.exit behavior).
    """

    def __init__(self, error_id, message):
        self.error_id = error_id
        self.message = message
        super().__init__(message)


def emit_report(report, dest):
    """Write `report` as JSON to a file, or to stdout (delimited) when dest=='-'."""
    text = json.dumps(report, indent=2)
    if dest == "-":
        print(INFRA_JSON_BEGIN)
        print(text)
        print(INFRA_JSON_END)
    else:
        with open(dest, "w") as f:
            f.write(text + "\n")


class Trace:
    def __init__(self, name, path, version, workload, category, subcategory, checksum=None):
        self.name = name
        self.path = path
        self.version = version
        self.workload = workload
        self.category = category
        self.subcategory = subcategory
        self.checksum = checksum


class Experiment:
    def __init__(self, name, params):
        self.name = name
        self.params = params


def load_yaml(file_path):
    with open(file_path, "r") as file:
        return yaml.safe_load(file)


def replace_variables(value, definitions):
    pattern = r"\$\((.*?)\)"
    matches = re.findall(pattern, value)
    for match in matches:
        if match not in definitions:
            raise CJError("CJ_UNDEFINED_VAR", f"Encountered undefined variable: {match}")
        value = value.replace(f"$({match})", definitions[match])
    return value


def create_traces(data):
    trace_list = []
    for suite, traces in data.items():
        for entry in traces:
            for name, info in entry.items():
                path = info.get("path")
                version = info.get("version", 1)
                workload = info.get("workload")
                category = info.get("category")
                subcategory = info.get("subcategory")
                checksum = info.get("checksum") or None
                trace_list.append(Trace(name, path, version, workload, category, subcategory, checksum))
    return trace_list


def create_experiments(data):
    definitions = {
        list(d.keys())[0]: list(d.values())[0] for d in data.get("definitions", [])
    }
    experiments = []

    for exp in data.get("experiments", []):
        for name, params in exp.items():
            params = replace_variables(params, definitions)

            experiments.append(Experiment(name, params))

    return experiments


def snapshot_exe(exe_path, output_path):
    """Hardlink exe into <output_dir>/bin/<basename>.<UTC-timestamp>; fall back to copy on EXDEV."""
    if not os.path.isfile(exe_path):
        raise CJError("CJ_EXE_NOT_FOUND", f"--snapshot-exe: executable not found: {exe_path}")
    src = os.path.abspath(exe_path)
    bin_dir = os.path.join(os.path.dirname(os.path.abspath(output_path)), "bin")
    os.makedirs(bin_dir, exist_ok=True)
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    dst = os.path.join(bin_dir, f"{os.path.basename(src)}.{ts}")
    try:
        os.link(src, dst)
        kind = "hardlink"
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
        shutil.copy2(src, dst)
        kind = "copy (cross-filesystem)"
    print(f"Snapshotted exe to {dst} ({kind})", file=sys.stderr)
    return dst


def merge_with_dedup(named_groups, kind, source_flag):
    """Concatenate items from multiple files, aborting if a name appears more than once across all inputs."""
    name_to_files = {}
    for path, items in named_groups:
        for item in items:
            name_to_files.setdefault(item.name, []).append(path)
    dups = {name: files for name, files in name_to_files.items() if len(files) > 1}
    if dups:
        lines = [f"Duplicate {kind} name(s) found across {source_flag} files. Please deconflict:"]
        for name, files in sorted(dups.items()):
            lines.append(f"  {name}: appears in {', '.join(files)}")
        raise CJError("CJ_DUPLICATE_NAME", "\n".join(lines))
    return [item for _, items in named_groups for item in items]


def wrap_with_orchestrator(champsim_cmd, trace, args):
    """Prefix a raw ChampSim command with the run_champsim.py wrapper so
    the trace gets fetched into a node-local cache first. If the wrapper
    is disabled (--no-wrapper) the command is returned unchanged.
    """
    if not args.wrapper:
        return champsim_cmd
    parts = [args.wrapper]
    if trace.checksum:
        parts.append(f"--trace-checksum={trace.checksum}")
    if args.cache_dir:
        parts.append(f"--cache-dir={args.cache_dir}")
    parts.extend(["--", champsim_cmd])
    return " ".join(parts)


def build_sbatch_argv(args, tag, inner, parsable):
    """Build the sbatch argv for one job, mirroring the jobfile's slurm line.

    Used by --smoke-test-auto-launch to submit each job directly (capturing the
    job id) instead of sourcing the jobfile. With parsable=True, sbatch prints
    just the job id, so we pair it exactly with `tag`.
    """
    argv = ["sbatch", "-p", args.slurm_part, "--mincpus=1", "-c", str(args.ncores)]
    if args.include_list:
        argv.append(f"--nodelist={args.nodename}[{args.include_list}]")
    if args.exclude_list:
        argv.append(f"--exclude={args.nodename}[{args.exclude_list}]")
    if args.extra:
        argv += shlex.split(args.extra)
    if parsable:
        argv.append("--parsable")
    argv += ["-J", tag, "-o", f"{tag}.out", "-e", f"{tag}.err", "--wrap", inner]
    return argv


def submit_all(args, job_units):
    """Submit every (tag, inner) via `sbatch --parsable`, capturing tag->job_id.

    Returns (jobs, failures): jobs is a per-unit list of
    {tag, job_id, submit_rc}; failures collects the ones whose sbatch returned
    non-zero (with a stderr tail for diagnosis).
    """
    jobs, failures = [], []
    for tag, inner in job_units:
        argv = build_sbatch_argv(args, tag, inner, parsable=True)
        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if proc.returncode == 0:
            job_id = (proc.stdout or "").strip().split(";")[0] or None
            jobs.append({"tag": tag, "job_id": job_id, "submit_rc": 0})
            print(f"[submit] {tag} -> job {job_id}", file=sys.stderr)
        else:
            tail = (proc.stderr or "").strip()[-500:]
            jobs.append({"tag": tag, "job_id": None, "submit_rc": proc.returncode})
            failures.append({"tag": tag, "submit_rc": proc.returncode, "stderr_tail": tail})
            print(f"[submit] {tag} FAILED (rc={proc.returncode}): {tail}", file=sys.stderr)
    return jobs, failures


def run_smoke(pair, idx, exe_to_use, args, capture):
    """Run one (trace, exp) pair with reduced warmup/sim as a correctness check.

    capture=False streams the simulator's output to this process's stdout/stderr
    (the original --smoke-test behavior). capture=True buffers combined output
    and returns a tail in the result, so an auto-launch caller can report why a
    smoke run failed without flooding stdout.
    """
    trace, exp = pair
    champsim_cmd = (
        f"{exe_to_use} {exp.params}"
        f" --warmup_instructions={args.smoke_warmup}"
        f" --simulation_instructions={args.smoke_sim}"
        f" --trace_version={trace.version} -traces {trace.path}"
    )
    inner = wrap_with_orchestrator(champsim_cmd, trace, args)
    print(f"[smoke-test] pair #{idx}: trace={trace.name}, exp={exp.name}", file=sys.stderr)
    print(f"[smoke-test] command: {inner}", file=sys.stderr)
    start = time.monotonic()
    if capture:
        proc = subprocess.run(shlex.split(inner), stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)
        rc = proc.returncode
        output = proc.stdout or ""
    else:
        rc = subprocess.run(shlex.split(inner)).returncode
        output = None
    elapsed = time.monotonic() - start
    status = "PASSED" if rc == 0 else "FAILED"
    print(f"[smoke-test] {status} (exit={rc}, elapsed={elapsed:.1f}s)", file=sys.stderr)
    result = {
        "idx": idx, "trace": trace.name, "exp": exp.name,
        "warmup": args.smoke_warmup, "sim": args.smoke_sim,
        "rc": rc, "elapsed_s": round(elapsed, 2), "command": inner,
    }
    if output is not None:
        result["output_tail"] = "".join(output.splitlines(keepends=True)[-40:])
    return result


JOBFILE_PREAMBLE_SLURM = (
    "#!/bin/bash\n"
    "#\n"
    "# This is a jobfile that contains commands to run via slurm.\n"
    "# To launch the jobs, simply source the file as\n"
    "#   source ./<filename>\n"
    "#"
)

JOBFILE_PREAMBLE_LOCAL = (
    "#!/bin/bash\n"
    "#\n"
    "# This is a jobfile that runs ChampSim commands locally on this host.\n"
    "# To launch, simply source the file as\n"
    "#   source ./<filename>\n"
    "# Per-command stdout/stderr are redirected to <trace>_<exp>.out / .err.\n"
    "#"
)


def parse_args():
    parser = argparse.ArgumentParser(
        usage="%(prog)s --exe <executable> --exp <exp file> --tlist <trace list>"
    )
    parser.add_argument('--exe', required=True, help='Executable')
    parser.add_argument("--tlist", required=True, nargs='+', help="Path(s) to one or more trace list YAML files. Traces are concatenated; duplicate trace names across files cause an error.")
    parser.add_argument("--exp", required=True, nargs='+', help="Path(s) to one or more experiment YAML files. Definitions are scoped per file (self-contained); experiments are concatenated; duplicate experiment names across files cause an error.")
    parser.add_argument("--slurm-part", required=False, default="compute", help="Slurm partition to run on")
    parser.add_argument('--ncores', default='1', help='Number of cores needed for each slurm job')
    parser.add_argument('--exclude', dest='exclude_list', default=None, help='Node exclude list')
    parser.add_argument('--include', dest='include_list', default=None, help='Node include list')
    parser.add_argument('--nodename', default="ntl-zeus", help='Machine name of the compute nodes')
    parser.add_argument('--extra', default=None, help='Extra slurm arguments')
    parser.add_argument('--output', '-o', default='jobfile.sh', help='Output jobfile path (default: jobfile.sh in CWD)')
    parser.add_argument('--smoke-test', action='store_true', help='After writing the jobfile, run one ChampSim command locally with reduced warmup/sim instructions to verify correctness')
    parser.add_argument('--smoke-test-auto-launch', action='store_true', help='Run the smoke test, and ONLY if it passes, submit every sbatch job directly (capturing each tag->job_id). On smoke failure, submit nothing and exit non-zero. Slurm mode only (incompatible with --local).')
    parser.add_argument('--smoke-test-idx', type=int, default=0, help='Index into the (trace x experiment) pair list to use for --smoke-test (default: 0)')
    parser.add_argument('--smoke-warmup', type=int, default=1_000_000, help='Warmup instructions used during --smoke-test (default: 1M)')
    parser.add_argument('--smoke-sim', type=int, default=1_000_000, help='Simulation instructions used during --smoke-test (default: 1M)')
    parser.add_argument('--report-json', default=None, metavar='PATH', help="Emit a machine-readable JSON report (stable error_id + per-job status) to PATH, or to stdout (delimited) when PATH is '-'. Default behavior is unchanged when omitted.")
    parser.add_argument('--local', action='store_true', help='Emit raw ChampSim commands instead of sbatch lines, so the jobfile runs locally on this host')
    parser.add_argument('--local-parallel', type=int, default=1, help='Max number of local commands to run in parallel when --local is set (default: 1)')
    parser.add_argument('--snapshot-exe', action=argparse.BooleanOptionalAction, default=True, help='Hardlink the executable to <output-dir>/bin/<basename>.<UTC-timestamp> and reference that snapshot in the jobfile, so all jobs use the same binary even if the original is rebuilt before they finish queuing. Default: on (use --no-snapshot-exe to disable).')
    parser.add_argument('--wrapper', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'run_champsim.py'), help='Path to the orchestrator script that fetches traces into a node-local cache before launching ChampSim. Default: run_champsim.py next to this script.')
    parser.add_argument('--no-trace-cache', dest='wrapper', action='store_const', const=None, help='Skip the trace cache: each job reads its trace directly from NFS (or wherever --tlist points), exactly as before fetch_trace existed. Use when you do not want fetch_trace involved at all.')
    parser.add_argument('--trace-cache-dir', dest='cache_dir', default=None, help='Forwarded to run_champsim.py as --cache-dir (override the wrapper default).')
    return parser.parse_args()


def _run(args):
    if args.local_parallel < 1:
        raise CJError("CJ_BAD_ARGS", f"--local-parallel must be >= 1 (got {args.local_parallel})")
    if args.smoke_test_auto_launch and args.local:
        raise CJError("CJ_BAD_ARGS", "--smoke-test-auto-launch submits sbatch jobs and cannot be combined with --local")

    exe_to_use = snapshot_exe(args.exe, args.output) if args.snapshot_exe else args.exe

    trace_groups = [(p, create_traces(load_yaml(p))) for p in args.tlist]
    exp_groups = [(p, create_experiments(load_yaml(p))) for p in args.exp]

    traces = merge_with_dedup(trace_groups, "trace", "--tlist")
    experiments = merge_with_dedup(exp_groups, "experiment", "--exp")

    exclude_nodes_list = f"{args.nodename}[{args.exclude_list}]" if args.exclude_list else ""
    include_nodes_list = f"{args.nodename}[{args.include_list}]" if args.include_list else ""

    slurm_preamble = f"sbatch -p {args.slurm_part} --mincpus=1 -c {args.ncores}"
    if args.include_list:
        slurm_preamble += f" --nodelist={include_nodes_list}"
    if args.exclude_list:
        slurm_preamble += f" --exclude={exclude_nodes_list}"
    if args.extra:
        slurm_preamble += f" {args.extra}"

    preamble = JOBFILE_PREAMBLE_LOCAL if args.local else JOBFILE_PREAMBLE_SLURM

    job_units = []  # (tag, inner) per job, slurm mode only — reused by auto-launch
    with open(args.output, "w") as out:
        print(preamble, file=out)
        print("# Traces:", file=out)
        for trace in traces:
            print("#\t{}".format(trace.name), file=out)
        print("#\n#\n#", file=out)
        print("# Experiments:", file=out)
        for exp in experiments:
            print("#\t{}: params={}".format(exp.name, exp.params), file=out)
        print("#\n#\n#", file=out)

        if args.local:
            print(f"\nMAX_PARALLEL={args.local_parallel}\n", file=out)

        for trace in traces:
            for exp in experiments:
                tag = f"{trace.name}_{exp.name}"
                champsim_cmd = f"{exe_to_use} {exp.params} --trace_version={trace.version} -traces {trace.path}"
                inner = wrap_with_orchestrator(champsim_cmd, trace, args)

                if args.local:
                    print(
                        f'(echo "[run] {tag}"; {inner} > {tag}.out 2> {tag}.err) &\n'
                        f'[ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ] && wait -n',
                        file=out,
                    )
                else:
                    slurm_cmd = (
                        f"{slurm_preamble}"
                        f" -J {tag}"
                        f" -o {tag}.out"
                        f" -e {tag}.err"
                    )
                    print(f"{slurm_cmd} --wrap={shlex.quote(inner)}", file=out)
                    job_units.append((tag, inner))

        if args.local:
            print("\nwait", file=out)

    print(f"Wrote jobfile to {args.output}", file=sys.stderr)

    report = {
        "tool": "create_jobfile",
        "status": "ok",
        "error_id": None,
        "message": None,
        "exe": exe_to_use,
        "exe_original": os.path.abspath(args.exe),
        "jobfile": os.path.abspath(args.output),
        "mode": "local" if args.local else "slurm",
        "num_traces": len(traces),
        "num_experiments": len(experiments),
        "num_pairs": len(traces) * len(experiments),
        "smoke": None,
        "submitted": False,
        "jobs": [],
        "submit_failures": [],
    }

    if not (args.smoke_test or args.smoke_test_auto_launch):
        if args.report_json:
            emit_report(report, args.report_json)
        return 0

    # Both smoke modes need a valid pair to run.
    pairs = [(t, e) for t in traces for e in experiments]
    if not pairs:
        raise CJError("CJ_NO_PAIRS", "--smoke-test: no (trace, experiment) pairs to run.")
    if not (0 <= args.smoke_test_idx < len(pairs)):
        raise CJError("CJ_BAD_ARGS",
                      f"--smoke-test-idx {args.smoke_test_idx} out of range [0, {len(pairs)})")

    if args.smoke_test_auto_launch:
        smoke = run_smoke(pairs[args.smoke_test_idx], args.smoke_test_idx, exe_to_use, args, capture=True)
        report["smoke"] = smoke
        if smoke["rc"] != 0:
            report["status"] = "error"
            report["error_id"] = "CJ_SMOKE_FAILED"
            report["message"] = f"smoke test failed (exit={smoke['rc']}); no jobs submitted"
            if args.report_json:
                emit_report(report, args.report_json)
            return 1
        jobs, failures = submit_all(args, job_units)
        report["submitted"] = True
        report["jobs"] = jobs
        report["submit_failures"] = failures
        if failures:
            report["status"] = "error"
            report["error_id"] = "CJ_SUBMIT_FAILED"
            report["message"] = f"{len(failures)} of {len(job_units)} sbatch submission(s) failed"
        if args.report_json:
            emit_report(report, args.report_json)
        return 1 if failures else 0

    # Plain --smoke-test: stream output, exit with the smoke rc (original behavior).
    smoke = run_smoke(pairs[args.smoke_test_idx], args.smoke_test_idx, exe_to_use, args, capture=False)
    report["smoke"] = smoke
    if smoke["rc"] != 0:
        report["status"] = "error"
        report["error_id"] = "CJ_SMOKE_FAILED"
        report["message"] = f"smoke test failed (exit={smoke['rc']})"
    if args.report_json:
        emit_report(report, args.report_json)
    return smoke["rc"]


def main():
    args = parse_args()
    try:
        sys.exit(_run(args))
    except CJError as e:
        if args.report_json:
            emit_report(
                {"tool": "create_jobfile", "status": "error",
                 "error_id": e.error_id, "message": e.message},
                args.report_json,
            )
        print(e.message, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
