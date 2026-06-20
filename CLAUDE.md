# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure (not the simulator) for running [ChampSim](https://github.com/ChampSim/ChampSim)
trace-driven simulations at scale on a Slurm cluster. It generates jobfiles that
sweep (trace × experiment) pairs, fetches compressed traces into a node-local
cache, rolls per-run stats up into a CSV, and runs deterministic regressions.
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
`{trace}_{exp}.out/.err` files in a stats dir. Streams each `.out` once pulling
only needed stats, evaluates each metric expression, and writes `stats.csv`
(`TraceName, ExpName, <metrics…>, Filter`). A run is filtered (`Filter=0`) if its
`.err` matches a `FAILURE_KEYWORDS` pattern or files are missing; **if any
experiment for a trace fails, all rows for that trace are filtered**.

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

## Conventions

- Job/stat artifacts are keyed `<trace_name>_<exp_name>` everywhere — this naming
  is the contract between `create_jobfile.py` (writers) and `rollup.py` (readers).
  Keep it consistent if you touch either.
- `$(VAR)` is the substitution syntax across all YAML (definitions in exp files,
  stat names in mfiles).
