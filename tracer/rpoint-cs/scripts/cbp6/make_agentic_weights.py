#!/usr/bin/env python3
"""make_agentic_weights.py — write <instance>.traces.json weight files for the
agentic captures, so rollup.py can aggregate them the way it does SPEC.

WHY EQUAL WEIGHTS ARE CORRECT HERE, AND WHY THAT IS NOT A SHORTCUT

SPEC SimPoint weights exist because SimPoint picks *representative* slices of
wildly differing importance -- 779.zstd's 0.0665-weight slice must not count as
much as its 0.6408 one. The weights reconstruct whole-program behaviour from an
unequal sample.

The agentic windows are not a SimPoint sample. They are four equally sized
windows placed at uniform intervals on the trajectory's user-instruction clock,
by construction (see capture_agentic.sh: gap = (user - K*N)/(K-1)). A uniform
sample is reconstructed by an unweighted mean, so weight 1/K each IS the
SimPoint-equivalent, not a stand-in for a missing one.

Without these files rollup.py falls back to weight 1.0 and benchmark "unknown",
which collapses every agentic window into one bucket and makes per_benchmark.csv
an unweighted mixture across instances -- silently.

Usage:
  make_agentic_weights.py <champsim_out_dir> <out_dir>
"""
import glob
import json
import os
import re
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)

    # champsim_out/<instance>/<instance>_wNNNNN.champsim2.zst
    by_instance = {}
    for p in glob.glob(os.path.join(src, "*", "*.champsim2.zst")):
        tag = os.path.basename(p)[: -len(".champsim2.zst")]
        m = re.match(r"^(.*)_w\d+$", tag)
        if not m:
            print(f"  [skip] {tag}: not an <instance>_wNNNNN name", file=sys.stderr)
            continue
        by_instance.setdefault(m.group(1), []).append((tag, p))

    if not by_instance:
        sys.exit(f"no <instance>/<tag>.champsim2.zst under {src}")

    total = 0
    for inst, entries in sorted(by_instance.items()):
        entries.sort()
        w = 1.0 / len(entries)
        rows = [{
            "tag": tag,
            "weight": round(w, 6),
            "trace": path,
            "bytes": os.path.getsize(path),
            "rc": 0,
            "check_rc": 0,
            "status": "ok",
            "note": "uniform window on the user-instruction clock; equal weights "
                    "reconstruct the trajectory",
        } for tag, path in entries]
        out = os.path.join(dst, f"{inst}.traces.json")
        with open(out, "w") as f:
            json.dump(rows, f, indent=1)
        print(f"  {inst}: {len(rows)} windows @ {w:.4f} -> {out}")
        total += len(rows)

    print(f"wrote {len(by_instance)} weight file(s), {total} windows")
    # A weight set that does not sum to 1 per instance would silently rescale
    # every per-benchmark figure.
    for inst, entries in by_instance.items():
        s = round(len(entries) * round(1.0 / len(entries), 6), 4)
        if abs(s - 1.0) > 0.01:
            print(f"WARNING: {inst} weights sum to {s}, not 1.0")


if __name__ == "__main__":
    main()
