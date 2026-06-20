# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure (not the simulator) for running [ChampSim](https://github.com/ChampSim/ChampSim)
trace-driven simulations at scale on a Slurm cluster. It generates jobfiles that
sweep (trace × experiment) pairs, fetches compressed traces into a node-local
cache, rolls per-run stats up into a CSV, runs deterministic regressions, and
(via `cluster_run.py`) orchestrates those runs on a remote SSH-only Slurm cluster.
ChampSim itself, the Hermes fork, and the traces all live OUTSIDE this repo
(typically siblings under `/home/rahbera/thesis/` and `/home/rahbera/tracezoo/`).

## Environment gotchas

- **Python version**: `create_jobfile.py` uses `argparse.BooleanOptionalAction`
  (needs Python ≥ 3.9). This host's `python3` is **3.8** — use `python3.12`. The
  regression scripts shebang `python3.12` and refuse to run on < 3.9.
- No package manager / requirements file; the only third-party Python dep is
  `pyyaml`. C++ tools are built with per-tool Makefiles, not a top-level build.
- `ZSTD_HOME` (default `/home/rahbera/local`) points at a custom zstd build used
  by the tracer and trace tools. `PIN_ROOT` is needed to build the pintool.
- **YAML must be space-indented** — PyYAML rejects tabs, so a tab-indented
  tlist/exp/mfile crashes `create_jobfile.py`/`rollup.py`. Convert leading tabs → spaces.

## The core pipeline (scripts/)

The data model is three kinds of YAML, all of which **merge across multiple
files passed to one flag** and **abort on duplicate/conflicting names**:

- **tlist** (`--tlist`): traces. Top-level suite key → list of `{name: {path,
  version, workload, category, subcategory, checksum, ...}}`. Generated from a
  metadata TSV via `tsv_to_tlist.py`.
- **exp** (`--exp`): experiments. `definitions:` (`$(VAR)` macros) + `experiments:`
  where each value is the full ChampSim flag string. **Flag order is significant** —
  ChampSim applies CLI flags and `--config` files in sequence with last-wins
  semantics, so a CLI override must come AFTER any `--config` that sets the same key.
- **mfile** (`--mfile`): metrics for rollup. Each entry is `name: "<expr>"` where
  the expression references raw ChampSim stat names as `$(STAT_NAME)` (e.g.
  `- ipc: "$(Core_0_cumulative_IPC)"`). `rollup.py` extracts those stats and
  `eval`s the expression in a restricted namespace.

**`create_jobfile.py`** — emits a `jobfile.sh` you `source`/`bash`. For every
(trace × experiment) pair it writes one command tagged `<trace>_<exp>`, with
stdout/stderr to `<tag>.out`/`<tag>.err`. Two modes:
- default: `sbatch ... --wrap=<cmd>` lines (Slurm).
- `--local`: raw commands with a `MAX_PARALLEL` throttle (background + `wait -n`).

Each emitted command is wrapped by **`run_champsim.py`** (the orchestrator),
which finds the `-traces` path, runs it through **`fetch_trace.py`** to stage the
trace into a node-local cache (`/tmp/trace_cache`), substitutes the local path,
and `exec`s ChampSim. Disable with `--no-trace-cache`. By default the binary is
snapshotted (hardlinked) into `<output>/bin/<exe>.<ts>` so a mid-sweep rebuild
can't change which binary queued jobs run (`--no-snapshot-exe` to opt out).
`--smoke-test` runs one pair locally with tiny warmup/sim counts to sanity-check
before launching the full sweep.

**`fetch_trace.py`** — the concurrency-critical piece. 16–32 array jobs landing
on a node all want the same trace, so it takes a per-trace `flock` and publishes
via tempfile + atomic `rename(2)`; readers see no entry or a complete one, never
a torn copy. Optional SHA-256 checksum verification; cache key is the path
basename. Importable (`fetch_trace.fetch(...)`) or a standalone CLI.

**`rollup.py`** — fan-out (`ProcessPoolExecutor`, one task per trace) over the
`{trace}_{exp}.out/.err` files in the stats dir(s). `-d` takes **one or more**
directories, searched in order with first-`{trace}_{exp}.out`-match-wins, so a
single rollup can span multiple batch output dirs. Streams each `.out` once pulling
only needed stats, evaluates each metric expression, and writes `stats.csv`
(`TraceName, ExpName, <metrics…>, Filter`). A run is filtered (`Filter=0`) if its
`.err` matches a `FAILURE_KEYWORDS` pattern or files are missing; **if any
experiment for a trace fails, all rows for that trace are filtered** — and with
multiple `-d` dirs this `trace_failed` rule spans them, keeping a combined table
apples-to-apples per trace.

## Regression harness (regression/)

`run_regression.py OUTPUT_DIR --exe ... --tlist ... --exp ... --mfile ...` chains
the above: build a `--local` jobfile → run it → `rollup.py` → auto-diff against
the most recent previous run. Each run lands in
`OUTPUT_DIR/hermes_regression/<UTC-ts>[_label]/` with the snapshotted binary,
jobfile, per-run out/err, `stats.csv`, and `meta.json` (binary md5, Hermes git
commit, inputs). **`OUTPUT_DIR` must live outside this repo** so large dumps are
never committed.

The premise is determinism: identical binary+config+trace ⇒ identical stats, so
`compare_runs.py OLD NEW` flags *any* change (keyed on (trace, exp), exits
non-zero — CI-gate friendly; `--tol` allows relative tolerance). See
`regression/README.md` for the exact Hermes build + run incantation.

## Remote cluster runs (cluster-run)

`scripts/cluster_run.py` runs sims on an **SSH-only** Slurm cluster from the local
machine (the cluster login node bars AI agents). Subcommands: `bootstrap | submit |
status | rollup | combine | list`. `submit` rsyncs the sim **and this repo** to the
cluster, builds over SSH, smoke-gates on the login node, then launches the sbatch
jobs. Per-repo state (config + per-batch job ledger) lives in
`<sim-repo>/.cluster-run/` (gitignored). Driven by the global `cluster-run` skill.
**Full runbook + caveats: `docs/cluster-run.md`.**

- It invokes `create_jobfile.py` / `rollup.py` **on the cluster** over SSH, so both
  gained machine-readable output behind flags (defaults unchanged): `--report-json
  <path|->` (JSON delimited by `===INFRA-JSON-BEGIN/END===`, stable `error_id`s) and
  `create_jobfile.py --smoke-test-auto-launch` (smoke-gate, then submit each sbatch
  capturing exact `tag→job_id`).
- `$(SIM_HOME_IN_CLUSTER)` in a tlist/exp resolves to the cluster sim path at submit
  time (for `--config` paths that live inside the rsynced sim tree).
- `combine --batches A,B[,…]` merges several **finished** batches into one table for
  incremental experiments (batch B adds an experiment without re-running A's): it
  feeds every batch's `remote_run_dir` to one `rollup.py -d …` and concatenates their
  exp/tlist/mfiles, writing a `combine_<name>/stats.csv` (no ledger, no diff). Only
  `submit` rsyncs this repo; `status`/`rollup`/`combine` assume the **remote infra is
  current**, so after editing a remote-executed script (`rollup.py`, …) you must rsync
  it (or run a `submit`) before `rollup`/`combine`, else the cluster runs the stale copy.
- **Pre-flight a new cluster** (`sinfo`, remote `python3 -c 'import yaml'`): the
  config defaults (`compute`, `python3.12`) are often wrong — kratos2 uses `cpu_part`
  + `python3.10`. SSH/rsync need network (run the orchestrator with the Bash sandbox
  disabled, or prime `ssh <cluster> true`).

## Trace generation & tooling

- **pintool/** — Intel PIN tracer emitting v2/v3 ChampSim traces. ROI is bracketed
  by "magic NOP" markers (`xchg %rcx, %rcx` with an opcode in RCX) defined in
  `champsim_markers.h`; instrument a workload by including that header and calling
  `champsim_roi_begin()`/`champsim_roi_end()` (and, for v3, `champsim_register_worker()`
  to whitelist foreground threads). Build with `bash make_tracer.sh` (needs
  `PIN_ROOT`, `ZSTD_HOME`). The markers are true no-ops without PIN.
- **tools/trace_cutter/** — splits a zstd v2 trace (fixed 512-byte records) into
  N-instruction `.zst` chunks. `make` (honours `ZSTD_HOME`).
- **tools/trace_sanity_check/** — walks a `.gz`/`.xz`/`.zst` trace and prints
  aggregate stats. Links `champsim/src/trace_reader.cc` directly for byte-for-byte
  parity with the simulator, so `make` needs `CHAMPSIM_HOME` (default `../../../champsim`).

## Tests

`python3.12 tests/test_cluster_run.py` and `tests/test_reports.py` — plain
assert-based (no pytest; cluster faked, no network). They cover the
`--report-json`/`error_id` and smoke-gate additions, exact job-id capture, the
`$(SIM_HOME_IN_CLUSTER)` substitution, and the status/rollup lifecycle. Keep them
green when touching `create_jobfile.py` / `rollup.py` / `cluster_run.py`.

## Conventions

- Job/stat artifacts are keyed `<trace_name>_<exp_name>` everywhere — this naming
  is the contract between `create_jobfile.py` (writers) and `rollup.py` (readers).
  Keep it consistent if you touch either.
- `$(VAR)` is the substitution syntax across all YAML (definitions in exp files,
  stat names in mfiles).
