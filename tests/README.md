# tests/ — pipeline regression tests

Plain `assert`-based tests for the `scripts/` pipeline. **No pytest, no
network** — the cluster is faked (ssh / rsync monkeypatched) and ChampSim/sbatch
are replaced by stand-ins. Each file is a standalone runnable script with its own
pass/fail tally.

## What's covered

| File | Covers |
|------|--------|
| `test_reports.py` | The `--report-json` / `error_id` additions to `create_jobfile.py` and `rollup.py`, and their **backward compatibility** (default behavior unchanged when the flag is omitted), plus `--snapshot-exe` running a copy of the binary that an in-place write to it can't change. Uses a fake ChampSim binary and a fake `sbatch` on `PATH`. |
| `test_cluster_run.py` | The full `cluster_run.py` orchestration — `bootstrap → submit → status → rollup → combine` — with `ssh` / `ssh_stream` / `rsync` monkeypatched so it runs entirely locally. Also covers exact `tag → job_id` capture, the `$(SIM_HOME_IN_CLUSTER)` substitution, the submit lock and exclusive batch-id claim (with its `submitting` placeholder), and self-contained batches: the `snapshot_dirs` copies and exp repointing, the live-tree refusal of every path spelling, skipped and symlinked snapshot dirs (the mkdir and snapshot shell run in a local `sh`), which `rollup.py` runs, and `combine`'s normalized exp copies (checked against the real `rollup.py` merge) and `--out-name` guard. |

## Running

Use `python3.12` (the scripts under test need ≥ 3.9; these files shebang
`python3.12`). Run from the repo root:

```bash
python3.12 tests/test_reports.py
python3.12 tests/test_cluster_run.py
```

Each script prints any `FAIL:` lines and a final pass/fail count, and exits
non-zero if anything failed — so they drop into a CI gate as-is.

## When to run

Run both (and keep them green) whenever you touch any of:

- `scripts/create_jobfile.py`
- `scripts/rollup.py`
- `scripts/cluster_run.py`

These three scripts have a machine-readable contract (`--report-json`, stable
`error_id`s, the `<trace>_<exp>` artifact keying, the smoke-gate) that
`cluster_run.py` depends on over SSH. The tests exist to stop a refactor from
silently breaking that contract.

## Adding a test

Follow the existing style: a small `check(cond, msg)` helper that bumps a
shared counter, build inputs in a `tempfile` directory, invoke the script under
test (as a subprocess, or imported as a module), and assert on its JSON report /
output files. No shared state between tests, no real cluster.
