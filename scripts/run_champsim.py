#!/usr/bin/env python3
"""run_champsim.py — fetch trace(s) into the local cache, then run ChampSim.

Designed to be a drop-in wrapper inside jobfiles emitted by
create_jobfile.py. The ChampSim CLI itself is unchanged: this script
locates the `-traces <path>` argument, runs that path through the
node-local trace cache (fetch_trace.fetch), substitutes the cached
local path, and runs ChampSim as its child. The simulator never knows
anything happened.

Under Slurm, a SIGTERM that reaches a still-RUNNING job (a Spot reclaim or
node shutdown) requeues the job: Slurm records that kill as a finished job,
so `sbatch --requeue` alone never brings it back.

Usage:
    run_champsim.py [--trace-checksum SHA] [--cache-dir DIR]
                    -- <champsim binary> <args...> -traces <path>

The `--` separator marks the boundary between this wrapper's flags and
the ChampSim command line. Anything after `--` is passed through to
ChampSim with only the trace path substituted.
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys

# fetch_trace.py lives next to this script; import it as a sibling module
# regardless of where the wrapper is invoked from.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import fetch_trace  # noqa: E402

SCONTROL = shutil.which("scontrol") or "/opt/slurm/bin/scontrol"


def split_argv(argv):
    """Return (own_args, champsim_cmd) split at the first '--'."""
    if "--" not in argv:
        sys.exit("run_champsim: missing '--' separator before champsim "
                 "command (usage: run_champsim.py [opts] -- <champsim cmd>)")
    i = argv.index("--")
    return argv[:i], argv[i + 1:]


def find_trace_path_indices(cmd):
    """Return the indices of every path argument that follows '-traces'.

    ChampSim's CLI treats every token after '-traces' as a trace path
    (one per simulated core). We collect them all so multi-core jobs can
    be cached too — though only single-trace caching with checksum
    verification is supported in this wrapper today.
    """
    if "-traces" not in cmd:
        sys.exit("run_champsim: '-traces' not found in champsim command")
    start = cmd.index("-traces") + 1
    if start >= len(cmd):
        sys.exit("run_champsim: '-traces' has no path argument")
    return list(range(start, len(cmd)))


def slurm_job_state(job_id):
    """Return the job's Slurm state, or None if scontrol cannot tell."""
    try:
        out = subprocess.run([SCONTROL, "show", "job", "-o", job_id],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"\bJobState=(\S+)", out)
    return m.group(1) if m else None


def requeue_on_sigterm(get_child):
    """Install a SIGTERM handler that requeues a RUNNING Slurm job, then exits.

    scancel and time limits set the job CANCELLED/TIMEOUT (shown as
    COMPLETING) before signalling it, so only kills from outside Slurm
    requeue.
    """
    def on_term(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        job = os.environ.get("SLURM_JOB_ID")
        if job:
            state = slurm_job_state(job)
            if state in (None, "RUNNING"):
                try:
                    rc = subprocess.run([SCONTROL, "requeue", job], timeout=30).returncode
                except (OSError, subprocess.SubprocessError) as e:
                    rc = e
                print(f"run_champsim: SIGTERM while job {job} was {state}; requeue: {rc}",
                      file=sys.stderr, flush=True)
        child = get_child()
        if child is not None and child.poll() is None:
            child.terminate()
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, on_term)


def main():
    own, cmd = split_argv(sys.argv[1:])

    p = argparse.ArgumentParser(prog="run_champsim.py", add_help=False)
    p.add_argument("--trace-checksum", default=None,
                   help="expected SHA-256 of the trace (only valid when "
                        "the champsim command has a single trace path)")
    p.add_argument("--cache-dir", default=fetch_trace.CACHE_DIR_DEFAULT,
                   help="local cache directory")
    p.add_argument("-h", "--help", action="store_true")
    args = p.parse_args(own)

    if args.help:
        print(__doc__)
        sys.exit(0)

    if not cmd:
        sys.exit("run_champsim: no champsim command after '--'")

    child = None
    requeue_on_sigterm(lambda: child)

    indices = find_trace_path_indices(cmd)
    marker_idx = cmd.index("-traces")

    # A single checksum can't apply to N different traces; rather than
    # silently ignore it, force the caller to be explicit.
    if args.trace_checksum and len(indices) > 1:
        sys.exit("run_champsim: --trace-checksum is unsupported when "
                 f"-traces has multiple paths (got {len(indices)})")

    for n, idx in enumerate(indices):
        src = cmd[idx]
        sha = args.trace_checksum if n == 0 else None
        try:
            local = fetch_trace.fetch(
                src, checksum=sha, cache_dir=args.cache_dir,
            )
        except Exception as e:
            print(f"run_champsim: fetch failed for {src}: {e}",
                  file=sys.stderr)
            sys.exit(1)
        cmd[idx] = local

    # '-traces' is OUR marker, not ChampSim's. Current ChampSim (CLI11) takes
    # the trace paths POSITIONALLY and rejects the token outright:
    #     The following arguments were not expected: -traces
    # so it must be dropped before running it. Keeping it as the wrapper's marker
    # means create_jobfile.py has one thing to emit whether or not the cache is
    # in play, and this is the single place that knows the simulator's syntax.
    cmd = [tok for i, tok in enumerate(cmd) if not (tok == "-traces" and i == marker_idx)]

    # The simulator inherits stdout/stderr; a child rather than exec so the
    # SIGTERM handler above outlives the Python process image.
    child = subprocess.Popen(cmd)
    rc = child.wait()
    if rc < 0:
        # Die by the child's signal, so callers see the status exec gave them.
        signal.signal(-rc, signal.SIG_DFL)
        os.kill(os.getpid(), -rc)
    sys.exit(rc)


if __name__ == "__main__":
    main()
