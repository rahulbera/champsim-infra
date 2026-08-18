#!/usr/bin/env python3
"""stage_instance.py — host-side: fetch a SWE-bench instance and stage it.

Writes the problem statement the agent will be given, and VERIFIES the checked-in
instance descriptor against the live dataset. That verification is the point:
repo URL and base_commit are the two facts that, if wrong, produce a complete,
well-formed, entirely misattributed trace. Two research agents once disagreed
about one instance's base_commit, and nothing downstream would have caught it.

Usage:
  stage_instance.py <instance_id> [--dataset SWE-bench/SWE-bench_Multilingual]
                    [--out-dir DIR] [--write-env]

Outputs into --out-dir (default: alongside this script):
  problem_statements/<instance_id>.md   what the agent sees
  reference/<instance_id>.json          gold patch, test patch, F2P/P2P (grading)
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

DATASETS = [
    "SWE-bench/SWE-bench_Multilingual",
    "SWE-bench/SWE-bench_Verified",
]
ROWS_URL = "https://datasets-server.huggingface.co/rows"
HERE = os.path.dirname(os.path.abspath(__file__))


def fetch_rows(dataset, offset, length=100):
    q = urllib.parse.urlencode(
        {"dataset": dataset, "config": "default", "split": "test",
         "offset": offset, "length": length})
    with urllib.request.urlopen(f"{ROWS_URL}?{q}", timeout=120) as r:
        return json.load(r)


def find_instance(instance_id, datasets):
    """Linear scan. The datasets-server has no by-key lookup, and 300-500 rows
    in pages of 100 is a handful of requests -- not worth a local mirror that
    could then go stale against the dataset the numbers are quoted from."""
    for ds in datasets:
        offset, total = 0, None
        while total is None or offset < total:
            page = fetch_rows(ds, offset)
            if "rows" not in page:
                break
            total = page.get("num_rows_total", 0)
            for row in page["rows"]:
                if row["row"]["instance_id"] == instance_id:
                    return ds, row["row"]
            offset += 100
    return None, None


def load_env(path):
    """Parse the shell descriptor well enough to check the load-bearing keys.
    Deliberately not `bash -c source`: this runs on the host against a file
    fetched into a guest, and executing it here would be both unnecessary and
    a way to be surprised."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("instance_id")
    ap.add_argument("--dataset", action="append", default=None)
    ap.add_argument("--out-dir", default=HERE)
    ap.add_argument("--write-env", action="store_true",
                    help="print a starter .env block for a new instance")
    args = ap.parse_args()

    datasets = args.dataset or DATASETS
    ds, row = find_instance(args.instance_id, datasets)
    if row is None:
        sys.exit(f"instance {args.instance_id} not found in {datasets}")
    print(f"found {args.instance_id} in {ds}")

    ps_dir = os.path.join(args.out_dir, "problem_statements")
    ref_dir = os.path.join(args.out_dir, "reference")
    os.makedirs(ps_dir, exist_ok=True)
    os.makedirs(ref_dir, exist_ok=True)

    ps_path = os.path.join(ps_dir, f"{args.instance_id}.md")
    with open(ps_path, "w") as f:
        f.write(row["problem_statement"])
    print(f"  problem statement -> {ps_path} ({len(row['problem_statement'])} bytes)")

    def as_list(v):
        return json.loads(v) if isinstance(v, str) else v

    ref = {
        "instance_id": row["instance_id"],
        "dataset": ds,
        "repo": row["repo"],
        "base_commit": row["base_commit"],
        "patch": row["patch"],
        "test_patch": row["test_patch"],
        "FAIL_TO_PASS": as_list(row["FAIL_TO_PASS"]),
        "PASS_TO_PASS": as_list(row["PASS_TO_PASS"]),
    }
    ref_path = os.path.join(ref_dir, f"{args.instance_id}.json")
    with open(ref_path, "w") as f:
        json.dump(ref, f, indent=2)
    print(f"  reference        -> {ref_path} "
          f"(F2P={len(ref['FAIL_TO_PASS'])} P2P={len(ref['PASS_TO_PASS'])})")

    if args.write_env:
        print("\n--- starter descriptor ---")
        print(f"INSTANCE={row['instance_id']}")
        print(f"REPO_URL=https://github.com/{row['repo']}")
        print(f"REPO_NAME={row['repo'].split('/')[-1]}")
        print(f"REPO_DIR=/{row['repo'].split('/')[-1]}")
        print(f"BASE_COMMIT={row['base_commit']}")
        return

    env_path = os.path.join(args.out_dir, "instances", f"{args.instance_id}.env")
    if not os.path.exists(env_path):
        sys.exit(f"\nNO DESCRIPTOR at {env_path}\n"
                 f"Re-run with --write-env for a starter block.")

    env = load_env(env_path)
    expect_url = f"https://github.com/{row['repo']}"
    problems = []
    if env.get("BASE_COMMIT") != row["base_commit"]:
        problems.append(f"BASE_COMMIT: descriptor {env.get('BASE_COMMIT')} "
                        f"!= dataset {row['base_commit']}")
    if env.get("REPO_URL") != expect_url:
        problems.append(f"REPO_URL: descriptor {env.get('REPO_URL')} != {expect_url}")
    if env.get("REPO_NAME") != row["repo"].split("/")[-1]:
        problems.append(f"REPO_NAME: descriptor {env.get('REPO_NAME')} "
                        f"!= {row['repo'].split('/')[-1]}")
    if problems:
        sys.exit("\nDESCRIPTOR DISAGREES WITH THE DATASET:\n  "
                 + "\n  ".join(problems))
    print(f"  descriptor verified against {ds}: repo, base_commit, name all match")


if __name__ == "__main__":
    main()
