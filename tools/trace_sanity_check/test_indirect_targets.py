#!/usr/bin/env python3
"""test_indirect_targets.py — ground-truth test for --indirect-targets.

Builds a tiny v2 trace whose indirect-target structure is known exactly, runs
the tool, and asserts the reported numbers. Without this the feature would be
judged by whether its output "looks plausible" -- and a target-attribution bug
produces output that looks entirely plausible, because every number is still a
well-formed count in a sensible range.

The cases are chosen to break specific implementations:

  A  monomorphic branch, executed many times  -> 1 target, must not be counted
                                                 once per execution
  B  polymorphic branch, 3 distinct targets   -> 3, not 3*repeats
  C  two BACK-TO-BACK indirect branches       -> the naive "remember one
                                                 pending PC" loop overwrites
                                                 the first before resolving it,
                                                 losing its target entirely
  D  conditional + direct-jump branches       -> must be ignored completely
  E  indirect branch as the FINAL record      -> no successor exists, so its
                                                 target is unknowable; it must
                                                 be excluded and reported, not
                                                 silently attributed to 0x0

Run: python3 test_indirect_targets.py
"""
import os
import re
import struct
import subprocess
import sys
import tempfile

NUM_DST, NUM_SRC, MAX_MEM_VALUE_SIZE = 2, 4, 64
BT_DIRECT_JUMP, BT_INDIRECT, BT_CONDITIONAL = 0, 1, 2
BT_DIRECT_CALL, BT_INDIRECT_CALL, BT_RETURN, BT_NOT_BRANCH = 3, 4, 5, 7
FEAT = 0x01 | 0x02

FMT = "<Q" + "B" * (2 + NUM_DST + NUM_SRC) + "Q" * (2 * NUM_DST + 2 * NUM_SRC) \
      + "B" * (NUM_SRC + NUM_DST) + "BB" + "B" * 8 \
      + "B" * (NUM_SRC * MAX_MEM_VALUE_SIZE) + "B" * (NUM_DST * MAX_MEM_VALUE_SIZE)


def rec(ip, btype):
    is_branch = 0 if btype == BT_NOT_BRANCH else 1
    taken = 1 if is_branch and btype != BT_CONDITIONAL else 0
    vals = [ip, is_branch, taken]
    vals += [0] * NUM_DST + [0] * NUM_SRC              # registers
    vals += [0] * (2 * NUM_DST + 2 * NUM_SRC)          # memory + PA
    vals += [0] * (NUM_SRC + NUM_DST)                  # sizes
    vals += [0, 1]                                     # privilege, instr_type
    vals += [btype, FEAT, 4, 0, 0, 0, 0, 0]            # reserved
    vals += [0] * (NUM_SRC * MAX_MEM_VALUE_SIZE)
    vals += [0] * (NUM_DST * MAX_MEM_VALUE_SIZE)
    b = struct.pack(FMT, *vals)
    assert len(b) == 512, f"record is {len(b)} bytes, expected 512"
    return b


def build():
    """Returns (trace_bytes, expected)."""
    out = []
    A, B, C1, C2, E = 0x1000, 0x2000, 0x3000, 0x3100, 0x9000

    # A: monomorphic, 5 executions, always -> 0x1500
    for _ in range(5):
        out.append(rec(A, BT_INDIRECT))
        out.append(rec(0x1500, BT_NOT_BRANCH))

    # B: polymorphic, 3 distinct targets, 6 executions (each target twice)
    for t in (0x2500, 0x2600, 0x2700) * 2:
        out.append(rec(B, BT_INDIRECT_CALL))
        out.append(rec(t, BT_NOT_BRANCH))

    # C: back-to-back indirect branches. C1 -> C2 (C2 IS C1's target),
    #    then C2 -> 0x3500. Executed twice.
    for _ in range(2):
        out.append(rec(C1, BT_INDIRECT))
        out.append(rec(C2, BT_INDIRECT))
        out.append(rec(0x3500, BT_NOT_BRANCH))

    # D: non-indirect branches, must be ignored entirely
    for _ in range(4):
        out.append(rec(0x4000, BT_CONDITIONAL))
        out.append(rec(0x4008, BT_NOT_BRANCH))
        out.append(rec(0x5000, BT_DIRECT_JUMP))
        out.append(rec(0x5500, BT_NOT_BRANCH))
        out.append(rec(0x6000, BT_RETURN))
        out.append(rec(0x6500, BT_NOT_BRANCH))

    # E: final record is an indirect branch -> target unknowable
    out.append(rec(E, BT_INDIRECT))

    expected = {
        "static_pcs": 4,        # A, B, C1, C2 -- E excluded (no target)
        "dynamic": 5 + 6 + 2 + 2,   # A=5, B=6, C1=2, C2=2  (E excluded)
        "targets": {A: 1, B: 3, C1: 1, C2: 1},
        "mono_pcs": 3,          # A, C1, C2
        "mono_exec": 5 + 2 + 2,
        "poly_exec": 6,
        "dangling": 1,
    }
    return b"".join(out), expected


def main():
    tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "trace_sanity_check")
    if not os.path.exists(tool):
        sys.exit("build trace_sanity_check first")
    blob, exp = build()
    fails = []

    with tempfile.TemporaryDirectory() as d:
        raw = os.path.join(d, "t.champsim2")
        open(raw, "wb").write(blob)
        subprocess.run(["zstd", "-q", "-f", raw, "-o", raw + ".zst"], check=True)
        csv = os.path.join(d, "per_pc.csv")
        p = subprocess.run([tool, "-i", raw + ".zst", "-f", "v2",
                            "--indirect-targets", "--indirect-csv", csv,
                            "--heartbeat", "0"],
                           capture_output=True, text=True)
        out = p.stdout

        def grab(pat, cast=float):
            m = re.search(pat, out)
            return cast(m.group(1)) if m else None

        checks = [
            ("static PCs", grab(r"indirect branch PCs \(static\)\s+(\d+)", int), exp["static_pcs"]),
            ("dynamic executions", grab(r"indirect executions \(dynamic\)\s+(\d+)", int), exp["dynamic"]),
            ("mean targets/PC", grab(r"mean per PC \(static\)\s+([\d.]+)"),
             round(sum(exp["targets"].values()) / exp["static_pcs"], 2)),
            ("max targets", grab(r"most polymorphic PC\s+(\d+)", int), max(exp["targets"].values())),
            ("monomorphic % of PCs", grab(r"MONOMORPHIC.*?([\d.]+)% of PCs"),
             round(100 * exp["mono_pcs"] / exp["static_pcs"], 2)),
            ("monomorphic % of exec", grab(r"MONOMORPHIC.*?PCs,\s+([\d.]+)% of executions"),
             round(100 * exp["mono_exec"] / exp["dynamic"], 2)),
            ("polymorphic % of exec", grab(r"POLYMORPHIC.*?PCs,\s+([\d.]+)% of executions"),
             round(100 * exp["poly_exec"] / exp["dynamic"], 2)),
            ("dangling reported", grab(r"note: (\d+) indirect branch", int), exp["dangling"]),
        ]
        # Exec-weighted mean: sum(targets*exec)/sum(exec)
        wexp = sum(exp["targets"][pc] * e for pc, e in
                   ((0x1000, 5), (0x2000, 6), (0x3000, 2), (0x3100, 2))) / exp["dynamic"]
        checks.append(("exec-weighted mean targets",
                       grab(r"exec-weighted mean\s+([\d.]+)"), round(wexp, 2)))

        for name, got, want in checks:
            if got is None:
                fails.append(f"{name}: NOT FOUND in output")
            elif abs(got - want) > 0.011:
                fails.append(f"{name}: got {got}, expected {want}")
            else:
                print(f"  [ok] {name}: {got}")

        # The per-PC CSV must agree with the report, target for target.
        rows = {}
        for line in open(csv).read().splitlines()[1:]:
            pc, ex, nt = line.split(",")
            rows[int(pc, 16)] = (int(ex), int(nt))
        for pc, nt in exp["targets"].items():
            if pc not in rows:
                fails.append(f"csv: PC 0x{pc:x} missing")
            elif rows[pc][1] != nt:
                fails.append(f"csv: PC 0x{pc:x} has {rows[pc][1]} targets, expected {nt}")
        if not fails:
            print(f"  [ok] per-PC CSV agrees on all {len(exp['targets'])} PCs")

        # C1 must have exactly one target and it must be C2 -- the back-to-back
        # case. If the loop overwrote its pending PC, C1 is absent entirely.
        if 0x3000 not in rows:
            fails.append("back-to-back: C1 (0x3000) absent -- pending PC was overwritten")

    if fails:
        print("\nFAILED:")
        for f in fails:
            print("  " + f)
        return 1
    print("\nall indirect-target checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
