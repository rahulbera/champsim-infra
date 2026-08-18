#!/usr/bin/env python3
"""compare_agentic_vs_spec.py — the CBP2025 predictors on agentic traces vs SPEC.

Reads the two campaigns' per_trace.csv files and answers one question:

    How much do the CBP2025 submissions buy on a workload whose mispredictions
    are mostly INDIRECT, given that none of them predicts targets?

On SPEC the campaign found direction is 58.4% of the branch headroom, targets
the other 41.6%, and the four predictors capture 8.1-9.7% of the direction
headroom for ~0.8% IPC. The agentic traces are far more indirect-heavy, so the
prediction is that the same predictors buy less, while the perfdir -> perfall
gap widens.

AGGREGATION, per the campaign README §6 -- both traps apply here too:
  - reductions are POOLED (sum the counts, take one ratio), never an arithmetic
    mean of per-trace percentages. A near-zero-MPKI trace scores -286% and can
    invert a ranking.
  - speedup is a geometric mean of strictly positive ratios.
  - headroom capture is pooled and never geomeaned: it is undefined when a
    trace has no headroom.

Groups agentic traces into `agentic` (with the agent) and `toolchain` (the
non-agentic controls, tagged `.toolchain`), because the whole point of those
controls is that they may behave differently.

Usage:
  compare_agentic_vs_spec.py [--agentic DIR] [--spec DIR]
"""
import argparse
import csv
import math
import os
import sys
from collections import defaultdict

ORDER = ["cbp_tagescl64", "cbp_tagescl192", "cbp_ddtage", "cbp_runlts",
         "cbp_runlts_rv", "cbp_perfdir", "cbp_perfall"]
LABEL = {"cbp_tagescl64": "TAGE-SC-L 64KB (baseline)",
         "cbp_tagescl192": "TAGE-SC-L 192KB",
         "cbp_ddtage": "DD-TAGE (Ros)",
         "cbp_runlts": "RUNLTS (no RV)",
         "cbp_runlts_rv": "RUNLTS (load RV)",
         "cbp_perfdir": "Perfect direction",
         "cbp_perfall": "Perfect direction+target"}


def load(path, group_fn):
    """group -> config -> list of row dicts."""
    out = defaultdict(lambda: defaultdict(list))
    if not os.path.exists(path):
        sys.exit(f"missing {path}")
    with open(path) as f:
        for r in csv.DictReader(f):
            g = group_fn(r["trace"])
            if g is None:
                continue
            for k in ("instructions", "cycles", "mpki", "dir_mpki", "cycwpki", "ipc"):
                try:
                    r[k] = float(r[k])
                except (TypeError, ValueError):
                    r[k] = float("nan")
            out[g][r["config"]].append(r)
    return out


def geomean(xs):
    xs = [x for x in xs if x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")


def pooled_rate(rows, key):
    """Counts per 1K instructions, pooled: sum(count) / sum(insns) * 1000.
    mpki is already per-1K, so recover the count as mpki*insns/1000."""
    num = sum(r[key] * r["instructions"] / 1000.0 for r in rows)
    den = sum(r["instructions"] for r in rows)
    return 1000.0 * num / den if den else float("nan")


def report(name, by_config):
    base = by_config.get("cbp_tagescl64")
    if not base:
        print(f"  (no baseline runs for {name})")
        return None
    bkey = {r["trace"]: r for r in base}
    print(f"\n=== {name} ({len(base)} traces) ===")
    print(f"{'configuration':28s} {'speedup':>8s} {'bMPKI':>7s} {'dirMPKI':>8s} "
          f"{'CycWPKI':>9s} {'bMPKI red%':>11s} {'dir red%':>9s} {'CycW red%':>10s}")
    print("-" * 98)
    out = {}
    # Baseline rates are loop-invariant; computing them once also keeps the
    # denominator identical across configurations, which is what makes the
    # reduction columns comparable to each other at all.
    bm, bd, bc = (pooled_rate(base, k) for k in ("mpki", "dir_mpki", "cycwpki"))
    for cfg in ORDER:
        rows = by_config.get(cfg)
        if not rows:
            continue
        # Speedup: geomean of per-trace ratios against the same trace's baseline.
        sp = geomean([(r["ipc"] / bkey[r["trace"]]["ipc"])
                      for r in rows if r["trace"] in bkey and bkey[r["trace"]]["ipc"] > 0])
        m, d, c = (pooled_rate(rows, k) for k in ("mpki", "dir_mpki", "cycwpki"))
        mred = 100.0 * (bm - m) / bm if bm else float("nan")
        dred = 100.0 * (bd - d) / bd if bd else float("nan")
        cred = 100.0 * (bc - c) / bc if bc else float("nan")
        print(f"{LABEL.get(cfg, cfg):28s} {sp:8.4f} {m:7.2f} {d:8.3f} {c:9.2f} "
              f"{mred:11.2f} {dred:9.2f} {cred:10.2f}")
        out[cfg] = dict(speedup=sp, mpki=m, dir_mpki=d, cycwpki=c,
                        mred=mred, dred=dred, cred=cred,
                        cyc={r["trace"]: r["cycles"] for r in rows})
    return out


def headroom_split(r):
    """(total branch headroom as % of baseline cycles, direction's share of it).

    Cycle domain, pooled -- cycles are additive so a pooled estimator exists;
    IPC ratios are not, and headroom.py's docstring records that the two
    disagree materially.

    Summed over the traces present in ALL THREE configurations. Summing each
    configuration's own trace list instead would compare different populations
    the moment a sweep is partial or one run fails, and the resulting ratio
    looks entirely reasonable -- there is nothing in the number to reveal that
    the numerator and denominator cover different traces.
    """
    cfgs = ("cbp_tagescl64", "cbp_perfdir", "cbp_perfall")
    if not all(c in r for c in cfgs):
        return float("nan"), float("nan")
    common = set.intersection(*(set(r[c]["cyc"]) for c in cfgs))
    if not common:
        return float("nan"), float("nan")
    b, pd, pa = (sum(r[c]["cyc"][t] for t in common) for c in cfgs)
    all_head, dir_head = b - pa, b - pd
    if b <= 0 or all_head <= 0:
        return float("nan"), float("nan")
    return 100.0 * all_head / b, 100.0 * dir_head / all_head


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agentic", default="/home/rbera/work/bpeval/cbp6-agentic/analysis/per_trace.csv")
    ap.add_argument("--spec", default="/home/rbera/work/bpeval/cbp6-runs/analysis/per_trace.csv")
    a = ap.parse_args()

    spec = load(a.spec, lambda t: "SPEC CPU 2026")
    ag = load(a.agentic, lambda t: "agentic (toolchain only)" if ".toolchain" in t
                                   else "agentic (with agent)")

    res = {}
    for name, d in list(spec.items()) + list(ag.items()):
        r = report(name, d)
        if r:
            res[name] = r

    print("\n\n=== Q1: HEADROOM — what is left on the table, and who can reach it ===")
    print(f"{'population':28s} {'perfdir':>9s} {'perfall':>9s} "
          f"{'branch headroom':>16s} {'DIRECTION share':>16s} {'TARGET share':>13s}")
    print("-" * 96)
    for name, r in res.items():
        pd = r.get("cbp_perfdir", {}).get("speedup", float("nan"))
        pa = r.get("cbp_perfall", {}).get("speedup", float("nan"))
        head, dshare = headroom_split(r)
        print(f"{name:28s} {pd:9.4f} {pa:9.4f} {head:15.2f}% {dshare:15.1f}% "
              f"{100 - dshare:12.1f}%")

    print("\n=== Q2: do the SOTA DIRECTION predictors get any of it? ===")
    print(f"{'population':28s} {'best speedup':>13s} {'best dirMPKI red%':>18s} "
          f"{'best CycWPKI red%':>18s} {'of dir headroom':>16s}")
    print("-" * 97)
    for name, r in res.items():
        real = [c for c in ("cbp_tagescl192", "cbp_ddtage", "cbp_runlts", "cbp_runlts_rv") if c in r]
        if not real:
            continue
        bs = max(r[c]["speedup"] for c in real)
        bd = max(r[c]["dred"] for c in real)
        bc = max(r[c]["cred"] for c in real)
        # Capture: fraction of the DIRECTION ceiling's cycle saving actually
        # realised. Pooled and never geomeaned -- it is undefined for a trace
        # with no headroom, which is not a rare edge case here.
        cap = float("nan")
        if "cbp_tagescl64" in r and "cbp_perfdir" in r:
            best = max(real, key=lambda c: r[c]["speedup"])
            common = set(r["cbp_tagescl64"]["cyc"]) & set(r["cbp_perfdir"]["cyc"]) & set(r[best]["cyc"])
            if common:
                b = sum(r["cbp_tagescl64"]["cyc"][t] for t in common)
                den = b - sum(r["cbp_perfdir"]["cyc"][t] for t in common)
                if den > 0:
                    cap = 100.0 * (b - sum(r[best]["cyc"][t] for t in common)) / den
        print(f"{name:28s} {bs:13.4f} {bd:17.2f}% {bc:17.2f}% {cap:15.2f}%")

    print("\nperfdir = perfect DIRECTION, the ceiling any CBP2025 entry could reach.")
    print("perfall = perfect direction AND target. The gap between them is headroom")
    print("no direction predictor can touch -- it is target prediction, which no")
    print("CBP2025 submission addresses. A wider gap means the championship's whole")
    print("problem statement matters less for that workload.")
    print("\nCAVEAT, and it cuts one way: these runs use mispredict_penalty=1 and no")
    print("front-end refill model, so every headroom figure above is a LOWER bound")
    print("on a real machine's. If the headroom already looks large here, it is")
    print("larger in reality; if it looks small, that is not evidence it is small.")


if __name__ == "__main__":
    sys.exit(main())
