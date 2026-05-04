#!/usr/bin/env python3
"""run_champsim.py — fetch trace(s) into the local cache, then exec ChampSim.

Designed to be a drop-in wrapper inside jobfiles emitted by
create_jobfile.py. The ChampSim CLI itself is unchanged: this script
locates the `-traces <path>` argument, runs that path through the
node-local trace cache (fetch_trace.fetch), substitutes the cached
local path, and execs ChampSim directly. The simulator never knows
anything happened.

Usage:
    run_champsim.py [--trace-checksum SHA] [--cache-dir DIR]
                    -- <champsim binary> <args...> -traces <path>

The `--` separator marks the boundary between this wrapper's flags and
the ChampSim command line. Anything after `--` is passed through to
ChampSim with only the trace path substituted.
"""

import argparse
import os
import sys

# fetch_trace.py lives next to this script; import it as a sibling module
# regardless of where the wrapper is invoked from.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import fetch_trace  # noqa: E402


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

    indices = find_trace_path_indices(cmd)

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

    # exec replaces this Python process — the simulator's stdout/stderr
    # and exit code propagate normally to whoever invoked us (sbatch
    # --wrap, the local jobfile subshell, etc.).
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
