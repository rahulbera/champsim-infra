#!/usr/bin/env python3
"""verify_foreign_replay.py FED_TRAJ REPLAYED_TRAJ [--patch-from PREDS.jsonl --instance ID]

Gate a replay driven by a trajectory recorded SOMEWHERE ELSE.

WHY NOT compare_trajectories.py. That tool compares `trajectory[k].action` --
SWE-agent's own rendered command line for each step ("cd /testbed && make", or
"str_replace_editor view /testbed/src/Seq.js"). It is the right gate when we
recorded and replayed with the same harness, because both sides render actions
identically.

A foreign trajectory does not have that field. A `.min.traj` carries the raw
`tool_calls` the model emitted and nothing else, and reconstructing SWE-agent's
rendering from them is guesswork -- a rendering difference would show up as a
spurious divergence, which is worse than no gate at all because it trains you to
ignore the gate.

So this compares what we can compare EXACTLY: the tool call at each position,
normalised as sorted JSON. That is the same thing the cassettes carry, so a
match means "the replay executed exactly the actions we fed it, in order",
which is precisely the property sequence replay can violate.

WHAT THIS DOES NOT PROVE. Identical actions over a different starting tree do
wildly different work, and no trajectory comparison can see that -- actions come
from replayed model responses, not from observations. The starting state is
guaranteed elsewhere: every replay phase restores the provisioned image. Check
the patch too (--patch-from), because a matching action sequence that produces a
DIFFERENT patch means the environment diverged even though the script did not.

EXPECTED SHORTFALL. Our SWE-agent ends the episode at the FIRST submit. Foreign
trajectories routinely contain several (their harness continued past it), so the
replay legitimately stops early. That is not a truncation: this tool computes
where the first submit falls and requires the replay to reach exactly there.
A replay that stops ANYWHERE ELSE is a failure -- which is how the redis capture
should have been caught, having stopped at 54 of 77 with zero cassette misses.
"""
import argparse
import hashlib
import json
import sys


def tool_calls(msg):
    return msg.get("tool_calls") or []


def norm(tc):
    """Position-comparable form of one tool call: name + arguments, key-sorted."""
    fn = tc.get("function", {})
    return json.dumps({"name": fn.get("name"), "arguments": fn.get("arguments")},
                      sort_keys=True)


def assistant_actions(traj):
    """[(normalised call, tool name)] for every assistant turn, in order."""
    out = []
    for m in traj.get("history", []):
        if not isinstance(m, dict) or m.get("role") != "assistant":
            continue
        for tc in tool_calls(m)[:1]:      # one action per turn, as SWE-agent does
            out.append((norm(tc), tc.get("function", {}).get("name")))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fed"); ap.add_argument("replayed")
    ap.add_argument("--patch-from", help="preds jsonl with the reference model_patch")
    ap.add_argument("--instance")
    args = ap.parse_args()

    fed = assistant_actions(json.load(open(args.fed)))
    rep_doc = json.load(open(args.replayed))
    rep = assistant_actions(rep_doc)

    # Where our harness must stop: the first submit in what we fed.
    first_submit = next((i for i, (_, n) in enumerate(fed) if n == "submit"), None)
    expected = first_submit if first_submit is not None else len(fed)

    print(f"  fed actions      : {len(fed)}")
    print(f"  first submit at  : {first_submit}")
    print(f"  expected replay  : {expected}")
    print(f"  replayed actions : {len(rep)}")

    problems = []
    if len(rep) != expected:
        problems.append(f"replay ran {len(rep)} actions, expected exactly {expected}")

    n = min(len(fed), len(rep))
    same = sum(1 for i in range(n) if fed[i][0] == rep[i][0])
    print(f"  identical actions: {same} / {n}")
    if same != n:
        for i in range(n):
            if fed[i][0] != rep[i][0]:
                print(f"  FIRST DIVERGENCE at {i}:")
                print(f"    fed     : {fed[i][0][:200]}")
                print(f"    replayed: {rep[i][0][:200]}")
                break
        problems.append(f"{n - same} of {n} actions differ")

    # The patch is the independent check: same actions, different patch means the
    # tree the actions ran against was not the tree they were recorded against.
    info = rep_doc.get("info") or {}
    got = info.get("submission") or ""
    print(f"  replay patch     : {len(got)} bytes"
          f"{'  sha=' + hashlib.sha256(got.encode()).hexdigest()[:16] if got else ''}")
    if args.patch_from and args.instance:
        want = ""
        for line in open(args.patch_from):
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("instance_id") == args.instance:
                want = row.get("model_patch") or ""
                break
        if not want:
            print(f"  reference patch  : none banked for {args.instance} — not checked")
        else:
            gs = hashlib.sha256(got.encode()).hexdigest()
            ws = hashlib.sha256(want.encode()).hexdigest()
            print(f"  reference patch  : {len(want)} bytes  sha={ws[:16]}")
            if gs != ws:
                # Reported, not fatal: their patch is the end of a run that
                # continued past the first submit, so a difference is expected
                # when the trajectory has several. It is still worth seeing.
                print("  NOTE: patch differs from the banked reference. Expected when the "
                      "foreign trajectory submits more than once; investigate if it does not.")

    if problems:
        print("  VERDICT: DIVERGED")
        for p in problems:
            print(f"    - {p}")
        return 1
    print("  VERDICT: FAITHFUL — the replay executed exactly the fed actions, in order")
    return 0


if __name__ == "__main__":
    sys.exit(main())
