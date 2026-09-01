#!/usr/bin/env python3
"""traj_to_cassettes.py TRAJ OUTDIR — build a replayable cassette set from a
recorded trajectory.

WHY THIS EXISTS. Our replay proxy normally replays cassettes it recorded itself.
But a trajectory recorded elsewhere -- by a collaborator, or by an earlier
campaign whose cassettes were lost -- contains everything the proxy actually
needs, because `--match sequence` serves responses in order and ignores the
request entirely. So a trajectory IS a cassette set, modulo formatting.

This matters for campaign 2026-09: 36 banked `.min.traj` files exist for the
target instances. Replaying them costs no API credits and, more importantly,
preserves the behaviour classification computed FROM those trajectories --
re-recording at temperature 0.6 is stochastic even with an identical model, so
a fresh recording would silently move tasks between cells.

WHAT IT CANNOT DO. It reconstructs the RESPONSES, not the requests. A cassette
set built this way only replays under `--match sequence`; `--match key` would
miss on every exchange. That is fine -- sequence is the default and the only
mode the campaign uses -- but it means the resulting set is not a substitute for
a real recording if you ever need content matching.

THE FAILURE MODE TO RESPECT. Sequence replay desynchronises silently: serve one
response too many or too few and every later exchange answers the wrong
question, with ZERO misses reported. So this script asserts
`len(_order.json) == len(set(order)) == cassette file count` before it finishes,
and you must still run compare_trajectories.py on the result. Zero misses is
necessary and not sufficient -- that is what cost the redis and gson captures.

Accepts either a full `.traj` (system/user/assistant/tool history) or a
minified `.min.traj` (assistant turns only). Only assistant turns become
cassettes, because only they are model responses.
"""
import argparse
import hashlib
import json
import os
import sys


def assistant_turns(traj):
    """The model responses, in order, from either trajectory shape."""
    hist = traj.get("history")
    if not isinstance(hist, list):
        sys.exit("no 'history' array in the trajectory -- not a shape we understand")
    out = []
    for m in hist:
        if isinstance(m, dict) and m.get("role") == "assistant":
            out.append(m)
    return out


def response_body(msg, index, model):
    """One OpenAI-compatible chat-completion response carrying this turn.

    Shape copied from a real recorded cassette so the client sees nothing
    unusual: choices[0].message with content + tool_calls, and a finish_reason
    that matches whether the turn called a tool.
    """
    tool_calls = msg.get("tool_calls") or []
    message = {
        "role": "assistant",
        "content": msg.get("content") or "",
    }
    if tool_calls:
        message["tool_calls"] = tool_calls
    return {
        "choices": [{
            "finish_reason": "tool_calls" if tool_calls else "stop",
            "index": 0,
            "message": message,
        }],
        # `created` is synthetic and monotonic. Nothing in replay reads it, but
        # a plausible ordering keeps the files readable, and mtime-order is the
        # proxy's own fallback when _order.json is missing.
        "created": 1_700_000_000 + index,
        "id": "synthesized-%05d" % index,
        "model": model,
        "object": "chat.completion",
        "request_id": "synthesized-%05d" % index,
        # Token counts are unknown and are NOT invented: a zeroed usage block is
        # honest, a fabricated one would corrupt any later cost accounting.
        "usage": {"completion_tokens": 0, "prompt_tokens": 0, "total_tokens": 0},
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traj", help="recorded .traj or .min.traj")
    ap.add_argument("outdir", help="cassette directory to create")
    ap.add_argument("--model", default="glm-5.2",
                    help="model string to stamp into each response (default glm-5.2)")
    ap.add_argument("--force", action="store_true",
                    help="write into a non-empty outdir (refused otherwise)")
    args = ap.parse_args()

    with open(args.traj) as f:
        traj = json.load(f)

    turns = assistant_turns(traj)
    if not turns:
        sys.exit("no assistant turns found -- nothing to replay")

    # A non-empty target is refused rather than merged. The proxy appends to
    # _order.json and never clears the directory, so mixing two cassette sets
    # produces one manifest describing neither -- exactly how the gson
    # recording was corrupted.
    if os.path.isdir(args.outdir) and os.listdir(args.outdir) and not args.force:
        sys.exit("%s is not empty -- refusing to mix cassette sets (use --force)"
                 % args.outdir)
    os.makedirs(args.outdir, exist_ok=True)

    order = []
    for i, msg in enumerate(turns):
        body = json.dumps(response_body(msg, i, args.model), sort_keys=True)
        # The key only has to be unique and stable. Deriving it from the content
        # plus the index means an identical repeated turn still gets its own
        # cassette -- collapsing duplicates would shorten the sequence and
        # desynchronise everything after it.
        key = hashlib.sha256(("%d\x00%s" % (i, body)).encode("utf-8")).hexdigest()
        doc = {
            "key": key,
            "status": 200,
            "headers": {"Content-Type": "application/json; charset=UTF-8"},
            "body": body,
        }
        with open(os.path.join(args.outdir, key + ".json"), "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
        order.append(key)

    with open(os.path.join(args.outdir, "_order.json"), "w") as f:
        json.dump(order, f, indent=1)

    # The invariant that would have caught gson before it cost a 57-minute
    # record pass and a full verify.
    files = [n for n in os.listdir(args.outdir)
             if n.endswith(".json") and n != "_order.json"]
    if not (len(order) == len(set(order)) == len(files)):
        sys.exit("MANIFEST INCONSISTENT: %d ordered, %d unique, %d files"
                 % (len(order), len(set(order)), len(files)))

    n_tools = sum(1 for m in turns if m.get("tool_calls"))
    print("  %d assistant turns -> %d cassettes (%d carry tool_calls)"
          % (len(turns), len(files), n_tools))
    print("  manifest: %d ordered == %d unique == %d files  OK"
          % (len(order), len(set(order)), len(files)))
    print("  %s" % args.outdir)
    print("  NOTE: replays only under --match sequence, and zero misses is not")
    print("        proof -- run compare_trajectories.py on the result.")


if __name__ == "__main__":
    main()
