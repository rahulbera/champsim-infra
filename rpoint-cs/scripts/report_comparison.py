#!/usr/bin/env python3
"""report_comparison.py — agentic traces against SPEC, by misprediction mix.

Takes one or more CSVs written by analyze_bp.py and groups the rows into
agentic captures (by instance) and SPEC benchmarks, then reports the split that
actually distinguishes them.

The framing matters. Aggregate MPKI does NOT separate agentic work from SPEC --
the first capture landed inside SPEC's range on every headline number. What
separated them was composition: which kind of branch the mispredictions were.
So the table leads with the conditional/indirect split and the indirect share,
and the aggregate is shown for context rather than as the finding.

Usage:
  report_comparison.py results1.csv [results2.csv ...] [--markdown]
"""
import argparse
import csv
import os
import re
import sys

SPEC_RE = re.compile(r"^\d{3}\.")


def classify(name):
    if SPEC_RE.match(name):
        return "SPEC"
    if name.startswith("swe_agent_"):
        return "agentic: prometheus (Go)"
    # Converted agentic traces are named <instance>_w<NNNNN>.
    m = re.match(r"^([a-z0-9_]+__[a-z0-9.-]+)_w\d+$", name)
    if m:
        return f"agentic: {m.group(1)}"
    return "other"


def load(paths):
    rows = []
    for p in paths:
        if not os.path.exists(p):
            print(f"  [warn] missing {p}", file=sys.stderr)
            continue
        with open(p) as f:
            for r in csv.DictReader(f):
                for k in ("ipc", "mpki", "conditional_mpki", "indirect_mpki",
                          "return_mpki", "direct_mpki", "indirect_pct"):
                    try:
                        r[k] = float(r[k])
                    except (TypeError, ValueError, KeyError):
                        r[k] = float("nan")
                r["group"] = classify(r["trace"])
                rows.append(r)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+")
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args()

    rows = load(args.csvs)
    if not rows:
        sys.exit("no rows loaded")

    groups = {}
    for r in rows:
        groups.setdefault(r["group"], []).append(r)
    # Agentic groups first, SPEC last, so the comparison reads in that order.
    order = sorted(groups, key=lambda g: (g == "SPEC", g == "other", g))

    if args.markdown:
        print("| trace | MPKI | cond | indirect | return | indirect % | IPC |")
        print("|---|---|---|---|---|---|---|")
        for g in order:
            print(f"| **{g}** | | | | | | |")
            for r in sorted(groups[g], key=lambda x: x["trace"]):
                short = " ⚠" if r.get("short") else ""
                print(f"| {r['trace']}{short} | {r['mpki']:.2f} | "
                      f"{r['conditional_mpki']:.2f} | {r['indirect_mpki']:.2f} | "
                      f"{r['return_mpki']:.2f} | {r['indirect_pct']:.1f}% | "
                      f"{r['ipc']:.2f} |")
    else:
        hdr = (f"{'trace':38s} {'MPKI':>7s} {'cond':>7s} {'indir':>7s} "
               f"{'ret':>6s} {'ind%':>6s} {'IPC':>6s}")
        for g in order:
            print(f"\n=== {g} ===")
            print(hdr)
            print("-" * len(hdr))
            for r in sorted(groups[g], key=lambda x: x["trace"]):
                print(f"{r['trace']:38s} {r['mpki']:7.2f} "
                      f"{r['conditional_mpki']:7.2f} {r['indirect_mpki']:7.2f} "
                      f"{r['return_mpki']:6.2f} {r['indirect_pct']:6.1f} "
                      f"{r['ipc']:6.2f}"
                      + ("   [SHORT]" if r.get("short") else ""))

    print("\n=== group summary (median) ===")
    print(f"{'group':32s} {'n':>3s} {'MPKI':>7s} {'cond':>7s} {'indir':>7s} {'ind%':>7s}")
    print("-" * 68)

    def med(vals):
        v = sorted(x for x in vals if x == x)          # drop NaN
        if not v:
            return float("nan")
        n = len(v)
        return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2

    for g in order:
        rs = groups[g]
        print(f"{g:32s} {len(rs):3d} "
              f"{med(r['mpki'] for r in rs):7.2f} "
              f"{med(r['conditional_mpki'] for r in rs):7.2f} "
              f"{med(r['indirect_mpki'] for r in rs):7.2f} "
              f"{med(r['indirect_pct'] for r in rs):6.1f}%")

    print("\nindirect % = (INDIRECT + INDIRECT_CALL) / all mispredictions.")
    print("Returns are excluded from that share: the RAS is a separate predictor,")
    print("and merging them hides which mechanism is actually failing.")


if __name__ == "__main__":
    sys.exit(main())
