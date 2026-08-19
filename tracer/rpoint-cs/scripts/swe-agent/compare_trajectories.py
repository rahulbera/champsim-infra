#!/usr/bin/env python3
"""compare_trajectories.py RECORDED REPLAYED — assert a replay reproduced a run.

`replay misses: 0` is necessary but NOT sufficient, and trusting it cost a full
capture. Sequence replay serves recorded responses in order regardless of
request content, so a replay that stops EARLY never misses -- it just runs out
of steps. The redis capture recorded 77 steps and replayed 54, exiting on a
command timeout with a 609-byte patch instead of the correct 1307-byte one, and
reported zero misses the whole way.

What actually establishes "same execution":
  same number of steps, the same action at every step, and the same final patch.

Exit 0 only if all three hold.
"""
import hashlib
import json
import sys


def load(path):
    with open(path) as f:
        t = json.load(f)
    return t.get("trajectory", []), t.get("info", {})


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rec, ri = load(sys.argv[1])
    rep, pi = load(sys.argv[2])

    rec_patch = ri.get("submission") or ""
    rep_patch = pi.get("submission") or ""
    rec_sha = hashlib.sha256(rec_patch.encode()).hexdigest()
    rep_sha = hashlib.sha256(rep_patch.encode()).hexdigest()

    print(f"  record: {len(rec):4d} steps  exit={ri.get('exit_status')!r}  "
          f"patch={len(rec_patch)}B sha={rec_sha[:16]}")
    print(f"  replay: {len(rep):4d} steps  exit={pi.get('exit_status')!r}  "
          f"patch={len(rep_patch)}B sha={rep_sha[:16]}")

    n = min(len(rec), len(rep))
    same = sum(1 for a, b in zip(rec, rep)
               if (a.get("action") or "") == (b.get("action") or ""))
    print(f"  identical actions: {same} / {n}")

    problems = []
    if len(rec) != len(rep):
        problems.append(f"step count differs ({len(rec)} vs {len(rep)})")
    if same != n:
        for k in range(n):
            if (rec[k].get("action") or "") != (rep[k].get("action") or ""):
                print(f"  FIRST DIVERGENCE at step {k}:")
                print(f"    record: {(rec[k].get('action') or '')[:200]!r}")
                print(f"    replay: {(rep[k].get('action') or '')[:200]!r}")
                break
        problems.append(f"{n - same} of {n} actions differ")
    if rec_sha != rep_sha:
        problems.append("final patch differs")

    # The question is whether the replay IS the recorded execution -- not
    # whether the recording was ideal. A recording that ended abnormally is a
    # legitimate, if less tidy, workload; what invalidates a trace is the two
    # sides ending DIFFERENTLY. So compare the exit statuses for equality and
    # only note an abnormal-but-matching one.
    rec_st, rep_st = str(ri.get("exit_status") or ""), str(pi.get("exit_status") or "")
    if rec_st != rep_st:
        problems.append(f"exit_status differs: record {rec_st!r} vs replay {rep_st!r}")
    elif "(" in rec_st:
        print(f"  NOTE: both sides ended abnormally with {rec_st!r} -- reproduced "
              f"faithfully, but the trajectory is shorter than the agent intended")

    if problems:
        print("  VERDICT: DIVERGED")
        for p in problems:
            print(f"    - {p}")
        return 1
    print("  VERDICT: IDENTICAL — the replay is the recorded execution")
    return 0


if __name__ == "__main__":
    sys.exit(main())
