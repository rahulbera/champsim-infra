#!/usr/bin/env python3.12
"""compare_runs.py OLD_DIR NEW_DIR

Diff two rolled-up regression runs (each dir holds a stats.csv produced by
rollup.py). Rows are keyed on (TraceName, ExpName); every metric column plus the
Filter pass/fail flag is compared. Exits non-zero if anything changed — so it
doubles as a CI gate.

ChampSim is deterministic, so identical binary+config+trace must yield identical
stats; any change is a regression signal. Use --tol for a relative tolerance on
numeric metrics (default: exact match).
"""

import argparse
import csv
import os
import sys

FIXED = ("TraceName", "ExpName")


def load_csv(run_dir):
    """Return (value_columns, {(trace, exp): {col: val}})."""
    path = os.path.join(run_dir, "stats.csv")
    if not os.path.isfile(path):
        sys.exit(f"compare: missing {path}")
    with open(path, newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        rows = {}
        for row in reader:
            d = dict(zip(header, row))
            rows[(d["TraceName"], d["ExpName"])] = d
    value_cols = [c for c in header if c not in FIXED]
    return value_cols, rows


def equal(a, b, tol):
    if a == b:
        return True
    if tol > 0.0:
        try:
            fa, fb = float(a), float(b)
        except ValueError:
            return False
        return abs(fa - fb) <= tol * max(abs(fa), abs(fb), 1e-12)
    return False


def compare(old_dir, new_dir, tol=0.0):
    cols, new = load_csv(new_dir)
    _, old = load_csv(old_dir)
    rows, changed = [], 0
    for key in sorted(set(new) | set(old)):
        n, o = new.get(key), old.get(key)
        if o is None:
            status = "NEW"
        elif n is None:
            status = "REMOVED"; changed += 1
        elif any(not equal(o.get(c, ""), n.get(c, ""), tol) for c in cols):
            status = "CHANGED"; changed += 1
        else:
            status = "same"
        rows.append((key, n, o, status))
    return changed, rows, cols


def _cell(old, new):
    """Render one metric cell as 'new' (unchanged), 'new (Δ±d)' (numeric change),
    'new (was X)' (non-numeric change), 'new (new)', or '(removed; was X)'."""
    if new is None:
        return f"(removed; was {old})"
    if old is None:
        return f"{new} (new)"
    if old == new:
        return f"{new}"
    try:
        d = float(new) - float(old)
        return f"{new} (Δ{d:+g})"
    except ValueError:
        return f"{new} (was {old})"


def print_table(rows, cols):
    """Per-(trace,exp) table; each metric cell shows the new value and, when it
    moved, the delta vs the previous run — so you see exactly how each metric
    changed run-to-run."""
    rendered = []
    for (t, e), n, o, status in rows:
        cells = [_cell(o.get(c) if o else None, n.get(c) if n else None) for c in cols]
        rendered.append((f"{t}/{e}", cells, status))
    kw = max([len("trace/exp")] + [len(r[0]) for r in rendered]) + 2
    cw = [max([len(cols[i])] + [len(r[1][i]) for r in rendered]) + 2
          for i in range(len(cols))]
    print(f"{'trace/exp':<{kw}}" + "".join(f"{cols[i]:<{cw[i]}}" for i in range(len(cols))) + "status")
    for name, cells, status in rendered:
        print(f"{name:<{kw}}" + "".join(f"{cells[i]:<{cw[i]}}" for i in range(len(cols))) + status)


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("old_dir")
    p.add_argument("new_dir")
    p.add_argument("--tol", type=float, default=0.0,
                   help="relative tolerance for numeric metrics (default: exact)")
    args = p.parse_args()

    changed, rows, cols = compare(args.old_dir, args.new_dir, tol=args.tol)
    print_table(rows, cols)
    if changed:
        print(f"REGRESSION: {changed} (trace,exp) pair(s) changed")
        sys.exit(1)
    print("OK: no change vs baseline")


if __name__ == "__main__":
    main()
