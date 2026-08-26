# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure (not the simulator) for running [ChampSim](https://github.com/ChampSim/ChampSim)
trace-driven simulations at scale on a Slurm cluster. It produces traces, generates
jobfiles that sweep (trace × experiment) pairs, fetches compressed traces into
a node-local cache, rolls per-run stats up into a CSV, runs deterministic regressions, and
(via `cluster_run.py`) orchestrates those runs on a remote SSH-only Slurm cluster.

```
tracer/       the two trace PRODUCERS — pintool/ (Intel PIN, for workloads you can
              instrument) and rpoint-cs/ (QEMU snapshot/replay, subsumed repo, for
              workloads you cannot). Mainline carries the universal tools only; the
              SWE-agent capture campaign and its LLM cassettes live on branch
              swe-agent-tracing. Excluded from the cluster rsync.
scripts/      the sweep pipeline: create_jobfile.py → run_champsim.py/fetch_trace.py
              → rollup.py, plus cluster_run.py (remote Slurm orchestrator)
regression/   deterministic regression harness chaining that pipeline
tools/        standalone C++ trace utilities: trace_cutter, trace_sanity_check
tests/        the two assert-based gates (no pytest, no network; cluster is faked)
docs/         cluster-run runbook, handoffs, design specs
```
ChampSim itself, its forks (Hermes/Pythia/…), and the traces all live OUTSIDE this repo,
as sibling checkouts. **Absolute paths in the docs (`/home/rahbera/thesis/…`,
`/home/rahbera/tracezoo/…`) are the lab host's**; in this checkout the siblings are
`../ChampSim` (branch `rbdev`) and `../traces/{v1,v2}`. Verify before copying a path out
of a README.

## Where the details live

Every directory has a README with the full flag tables and worked examples; CLAUDE.md
carries only the cross-cutting architecture. **When you change a flag or a behavior,
update the matching README in the same commit** — the READMEs document flags one by one
and drift silently otherwise.

| Read this | For |
|---|---|
| `README.md` | Repo tour + how the pieces connect. |
| `scripts/README.md` | The tlist/exp/mfile data model and every pipeline script's flags. |
| `regression/README.md` | The exact build + run incantation for a regression. |
| `docs/cluster-run.md` | Remote Slurm runbook, caveats, per-cluster specifics. |
| `tracer/README.md` | Which tracer to use for which workload class. |
| `tracer/pintool/README.md`, `tools/README.md`, `tests/README.md` | Tracer knobs, C++ tool flags, test layout. |
| `tracer/rpoint-cs/README.md` | The QEMU snapshot/replay tracer (subsumed repo; own CLAUDE.md inside). Excluded from the cluster rsync. Mainline = universal tool; SWE-agent campaign + cassettes on branch `swe-agent-tracing`. |

## Commands

There is no linter and no CI; the two test scripts are the only gate.

```bash
# Tests — run both when touching create_jobfile.py / rollup.py / cluster_run.py
python3.12 tests/test_reports.py        # 29 checks
python3.12 tests/test_cluster_run.py    # 60 checks

# Local sweep end to end
python3.12 scripts/create_jobfile.py --exe <champsim-bin> --tlist t.yml --exp e.yml \
    --local --local-parallel 8 -o jobfile.sh
bash jobfile.sh
python3.12 scripts/rollup.py --tlist t.yml --exp e.yml --mfile m.yml -d . -o stats.csv

# Regression (OUTPUT_DIR must be OUTSIDE this repo — runs dump full per-run stats)
regression/run_regression.py <OUTPUT_DIR> --exe … --tlist … --exp … --mfile … [--label x]
regression/compare_runs.py <OLD_RUN_DIR> <NEW_RUN_DIR> [--tol 0.01]

# C++ tools — `env -u …` is required here, see "conda hijacks" below
env -u CXX -u CXXFLAGS -u LDFLAGS make -C tools/trace_cutter
env -u CXX -u CXXFLAGS -u LDFLAGS make -C tools/trace_sanity_check

# Verify a freshly generated trace is usable for branch-predictor work
tools/trace_sanity_check/trace_sanity_check -i <trace>.champsim2.zst -f v2 --check

# Pintool (x86-64 host with an Intel PIN 4.0 kit; PIN is at
# /home/rbera/work/softwares/pin-external-4.0-99633-g5ca9893f2-gcc-linux here)
cd tracer/pintool && env -u CXX -u CC -u CXXFLAGS -u CFLAGS -u CPPFLAGS -u LDFLAGS \
  PIN_ROOT=<pin-kit> ZSTD_HOME=<dir with include/zstd.h + lib/libzstd.a> \
  bash make_tracer.sh

# Full tracer loop, ~1 minute end to end (no instrumented workload needed)
<pin-kit>/pin -t tracer/pintool/obj-intel64/champsim_tracer_mt_roi_v3.so \
  -use_markers 0 -o out -t 200000 -n 1 -- /bin/ls /usr/lib
```

## Environment gotchas

- **Python**: needs ≥ 3.9 (`argparse.BooleanOptionalAction`) + `pyyaml`; there is no
  package manager or requirements file. The pipeline scripts shebang plain `python3`,
  but `cluster_run.py`, `regression/*.py` and `tests/*.py` shebang **`python3.12`** — a
  legacy of a host whose `python3` was 3.8. On a host without that binary, invoke them as
  `<interpreter> script.py`. Here both work (`python3` 3.14.4, `python3.12` 3.12.3, pyyaml
  in each).
- **Conda hijacks the C++ builds.** The active conda base env exports
  `CXX=aarch64-conda-linux-gnu-c++` plus x86 `CXXFLAGS`/`LDFLAGS`
  (`CONDA_BUILD_CROSS_COMPILATION=1`), and the tool Makefiles use `CXX ?=` / `CXXFLAGS ?=`
  — so the environment wins and `make` fails with `unknown value 'nocona' for '-march'`.
  Always build with `env -u CXX -u CXXFLAGS -u LDFLAGS make …`; that falls back to system
  `g++` and system zstd, which works.
  **That incantation is only enough for these Makefiles.** Conda points ~30 variables at
  the aarch64 cross-toolchain (`CONDA_TOOLCHAIN_HOST=aarch64-conda-linux-gnu`), including
  `AR`, `RANLIB`, `LD`, `NM`, `STRIP`, `OBJCOPY`, `CPP`, `CC_FOR_BUILD`, `HOST` and
  `host_alias`. Anything with a `./configure` reads those too, so an autotools build still
  cross-compiles: unsetting the usual four and building redis produced aarch64 objects and
  failed at link with `Relocations in generic ELF (EM: 183)` … `file in wrong format`. For
  configure-based builds scrub the environment instead —
  `env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=$HOME …`.
  Note this also drops conda's `tclsh`/`make` from `PATH`, which is usually what you want.
- `ZSTD_HOME` (lab default `/home/rahbera/local`) points at a custom zstd for the tracer
  and `trace_cutter`; unset ⇒ system zstd. `make_tracer.sh` defaults `PIN_ROOT`/`ZSTD_HOME`
  to the lab host's paths but **both are environment-overridable** — pass them rather than
  editing the file. `ZSTD_HOME` needs `include/zstd.h` + `lib/libzstd.a`; symlinks to the
  system zstd work (`/usr` itself does not, its lib path is `lib/x86_64-linux-gnu/`).
- **Conda also breaks the pintool build**, by a second mechanism: PIN derives its compiler
  wrapper from `$CXX` (`PIN_WRAPPER_GCC := $(patsubst %g++,%gcc,$(CXX))`), so a conda `CXX`
  reaches `pin-gcc` and fails on `-m64`. Strip `CC`/`CPPFLAGS` too, not just the three the
  C++ tools need.
- `tools/trace_sanity_check` is self-contained (pipes through the system `zstd`/`xz`/`gzip`
  binaries). It no longer needs `CHAMPSIM_HOME` — the ChampSim file it used to link,
  `src/trace_reader.cc`, was renamed to `src/tracereader.cc` upstream and is no longer a
  drop-in.
- **YAML must be space-indented** — PyYAML rejects tabs, so a tab-indented tlist/exp/mfile
  crashes `create_jobfile.py`/`rollup.py`. Convert leading tabs → spaces.

## The core pipeline (scripts/)

The data model is three kinds of YAML, all of which **merge across multiple files passed
to one flag** and **abort on duplicate/conflicting names**:

- **tlist** (`--tlist`): traces. Top-level suite key → list of `{name: {path, version,
  workload, category, subcategory, checksum, ...}}`. Generated from a metadata TSV via
  `tsv_to_tlist.py`.
- **exp** (`--exp`): experiments. `definitions:` (`$(VAR)` macros) + `experiments:` where
  each value is the full ChampSim flag string.
- **mfile** (`--mfile`): metrics for rollup. Each entry is `name: "<expr>"` where the
  expression references raw ChampSim stat names as `$(STAT_NAME)` (e.g.
  `- ipc: "$(Core_0_cumulative_IPC)"`). `rollup.py` extracts those stats and `eval`s the
  expression in a restricted namespace.

Two traps in the exp file:

- **Flag order is significant.** ChampSim applies CLI flags and `--config` files in
  sequence with last-wins semantics, so a CLI override must come AFTER any `--config` that
  sets the same key. `create_jobfile.py` appends `--trace-version=<v> <path>` to the *end*
  of your string, so it must end with a complete flag (and you cannot override
  `trace-version` from the exp file). **That rule is now enforced**: an experiment whose
  last token is a value-taking option is rejected at jobfile generation with
  `CJ_EXP_DANGLING_OPTION`, including one left dangling by the smoke test's
  window-stripping. It is a data-safety guard, not a tidiness one — ChampSim declares
  `--toml`/`--json` as `expected(0,1)`, so a bare one binds the next token as an output
  filename and **truncates that file at startup**, before it checks the trace count. A
  trailing `--toml` in an exp file would zero every trace in the tlist, one job at a
  time; that is how a 2.3 GB trace was destroyed here on 2026-08-26.
  **The trace path is POSITIONAL and the flag is hyphenated** — current ChampSim (CLI11)
  rejects both older spellings outright: `--trace_version=2` and a `-traces` token each
  produce *"The following arguments were not expected"*, i.e. every job fails, not just
  some. `-traces` survives only as the marker `run_champsim.py` uses to find the paths it
  must stage into the node-local cache, and that wrapper strips the token before `exec`.
  `create_jobfile.py` therefore emits it **only when the wrapper is in the command**
  (`trace_arg()`); with `--no-trace-cache` the path is bare.
- **`definitions:` scoping differs between the two consumers.** `create_jobfile.py`
  resolves each exp file against *its own* definitions only; `rollup.py` merges
  definitions across all `--exp` files first. A shared definitions-only file therefore
  works in rollup and fails jobfile generation with `CJ_UNDEFINED_VAR`. **Keep every exp
  file self-contained.**

**`create_jobfile.py`** — emits a `jobfile.sh` you `source`/`bash`. For every
(trace × experiment) pair it writes one command tagged `<trace>_<exp>`, with stdout/stderr
to `<tag>.out`/`<tag>.err`. Two modes: default `sbatch … --wrap=<cmd>` lines (Slurm), or
`--local` raw commands with a `MAX_PARALLEL` throttle (background + `wait -n`). By default
the binary is snapshotted (hardlinked) into `<output>/bin/<exe>.<ts>` so a mid-sweep
rebuild can't change which binary queued jobs run (`--no-snapshot-exe` to opt out).
`--smoke-test` runs one pair locally with tiny warmup/sim counts before the full sweep.

Each emitted command is wrapped by **`run_champsim.py`**, which finds the `-traces` path,
runs it through **`fetch_trace.py`** to stage the trace into a node-local cache
(`/tmp/trace_cache`), substitutes the local path, and `exec`s ChampSim (so the exit code
and streams propagate untouched). Every token after `-traces` is treated as a path
(multi-core runs), and `--trace-checksum` is rejected when there is more than one.
Disable the whole cache with `--no-trace-cache`.

**`fetch_trace.py`** — the concurrency-critical piece. 16–32 array jobs landing on a node
all want the same trace, so it takes a per-trace `flock` and publishes via tempfile +
atomic `rename(2)`; readers see no entry or a complete one, never a torn copy. Optional
SHA-256 checksum verification; cache key is the path basename. Importable
(`fetch_trace.fetch(...)`) or a standalone CLI.

**`rollup.py`** — fan-out (`ProcessPoolExecutor`, one task per trace) over the
`{trace}_{exp}.out/.err` files in the stats dir(s). `-d` takes **one or more** directories,
searched in order with first-`{trace}_{exp}.out`-match-wins, so a single rollup can span
multiple batch output dirs. Streams each `.out` once pulling only the needed stats and
writes `stats.csv` (`TraceName, ExpName, <metrics…>, Filter`). Cell conventions:

- `Filter=0` — this run failed (`.err` matched a `FAILURE_KEYWORDS` pattern, or files are
  missing) **or** a sibling experiment for the same trace did. That `trace_failed` rule
  spans all `-d` dirs, keeping a combined table apples-to-apples per trace.
- `0` in a metric cell — a placeholder: the run failed, or the stat was absent from the
  `.out`. Only `Filter` distinguishes it from a genuine measured 0.
- `NaN` — a real but non-finite value (a nan/inf stat, or a divide-by-zero metric); kept
  visible rather than collapsed to 0.

## Regression harness (regression/)

`run_regression.py OUTPUT_DIR --exe ... --tlist ... --exp ... --mfile ...` chains the
above: build a `--local` jobfile → run it → `rollup.py` → auto-diff against the most recent
previous run. Each run lands in `OUTPUT_DIR/hermes_regression/<UTC-ts>[_label]/` with the
snapshotted binary, jobfile, per-run out/err, `stats.csv`, and `meta.json` (binary md5,
fork git commit, inputs). **`OUTPUT_DIR` must live outside this repo** so large dumps are
never committed.

The premise is determinism: identical binary+config+trace ⇒ identical stats, so
`compare_runs.py OLD NEW` flags *any* change (keyed on (trace, exp), exits non-zero — CI-gate
friendly; `--tol` allows relative tolerance).

## Remote cluster runs (cluster-run)

`scripts/cluster_run.py` runs sims on an **SSH-only** Slurm cluster from the local machine
(the cluster login node bars AI agents). Subcommands: `bootstrap | submit | status |
rollup | combine | list`. `submit` rsyncs the sim **and this repo** to the cluster, builds
over SSH, smoke-gates on the login node, then launches the sbatch jobs. Per-repo state
(config + per-batch job ledger) lives in `<sim-repo>/.cluster-run/` (gitignored). Driven by
the global `cluster-run` skill. **Full runbook + caveats: `docs/cluster-run.md`.**

- It invokes `create_jobfile.py` / `rollup.py` **on the cluster** over SSH, so both gained
  machine-readable output behind flags (defaults unchanged): `--report-json <path|->` and
  `create_jobfile.py --smoke-test-auto-launch` (smoke-gate, then submit each sbatch
  capturing exact `tag→job_id`).
- `--stats-toml` (on `submit`, forwarded to `create_jobfile.py`) makes each job also write
  ChampSim's TOML statistics document to `<tag>.toml` beside `<tag>.out`.
  `cbp6-runs/rollup.py` **prefers** it: exact integer operands instead of the plain text's
  4-significant-figure rates, per-branch-type mispredict COUNTS rather than pre-divided
  MPKI, and the per-cache `<type>_hit`/`<type>_miss` counters the text exposes only as a
  formatted table (this is where L1I MPKI comes from). It is an overlay, not a
  replacement: `conditional branches`, `direction mispredicts` and the register-value
  channel are printed to stdout by the CBP6 adapter and have no TOML key, so the `.out` is
  still parsed for those, and a run without a `.toml` rolls up exactly as before.
- `$(SIM_HOME_IN_CLUSTER)` in a tlist/exp resolves to the cluster sim path at submit time
  (for `--config` paths that live inside the rsynced sim tree).
- `combine --batches A,B[,…]` merges several **finished** batches into one table for
  incremental experiments (batch B adds an experiment without re-running A's): it feeds
  every batch's `remote_run_dir` to one `rollup.py -d …` and concatenates their
  exp/tlist/mfiles, writing a `combine_<name>/stats.csv` (no ledger, no diff). Only
  `submit` rsyncs this repo; `status`/`rollup`/`combine` assume the **remote infra is
  current**, so after editing a remote-executed script (`rollup.py`, …) you must rsync it
  (or run a `submit`) before `rollup`/`combine`, else the cluster runs the stale copy.
- **Pre-flight a new cluster** (`sinfo`, remote `python3 -c 'import yaml'`): the config
  defaults (`compute`, `python3.12`) are often wrong — kratos2 uses `cpu_part` +
  `python3.10`. SSH/rsync need network (run the orchestrator with the Bash sandbox
  disabled, or prime `ssh <cluster> true`).

## Trace generation & tooling

- **tracer/pintool/** — Intel PIN 4.0 tracer emitting v2/v3 ChampSim traces (both write the same
  512-byte `input_instr_v2` record; v3 adds multi-threaded gating). ROI is bracketed by
  "magic NOP" markers (`xchg %rcx, %rcx` with an opcode in RCX) defined in
  `champsim_markers.h`; the opcode constants are duplicated between that header and the
  tracer `.cpp` — change both together. Markers are true no-ops without PIN, so an
  instrumented workload still runs normally.
- **The two tracers are the same code at a fixed line offset** (v3 = v2 + ~124 lines in the
  regions that matter), and they emit the same `.champsim2.zst` filename. **Any
  record-format change must land in both**, or that filename covers two silently
  incompatible classes of trace. Diff the regions before assuming they have diverged.
- **Branch-type contract** (`docs/superpowers/specs/2026-08-05-branch-type-and-flags-tracing-design.md`):
  `reserved[0]` = ChampSim's `branch_type` enum, `reserved[1]` = feature bitmask
  (`0x01` explicit branch type, `0x02` flags recorded), `reserved[2]` = tracer identity.
  Layout is unchanged at 512 B and there is deliberately **no trace-version bump** — a
  version asserted on the CLI can be wrong in a way the data cannot. Consumers must key off
  `reserved[1] & 0x01`, never off `reserved[0] != 0` (`0` is a valid `DIRECT_JUMP`).
  `is_branch` now includes calls and returns, so count `reserved[0] != NOT_BRANCH` instead.
  The flags register is recorded on both the source and destination side — either both or
  neither, since a read-but-never-written register stalls nothing.
  Deferred here, with measurements: destination register values for the RUNLTS value
  channel (§9 of that design doc). Don't re-derive that analysis.
- **tools/trace_cutter/** — splits a zstd v2 trace (fixed 512-byte records) into
  N-instruction `.zst` chunks.
- **tools/trace_sanity_check/** — walks a `.gz`/`.xz`/`.zst` trace and prints aggregate
  stats; self-contained (shells out to the reference decompressors). `--check` enforces the
  branch-type invariants and exits 2 on failure — run it on every freshly generated trace.
  The load-bearing one is the conditional taken rate being strictly inside (0, 100)%.

## Conventions & contracts

These are load-bearing across process boundaries (jobfile ↔ rollup, local ↔ cluster over
SSH) and are asserted by `tests/`. Don't rename them casually:

- Job/stat artifacts are keyed `<trace_name>_<exp_name>` everywhere — the contract between
  `create_jobfile.py` (writer) and `rollup.py` (reader).
- `$(VAR)` is the substitution syntax across all YAML (definitions in exp files, stat names
  in mfiles).
- Stable `error_id`s: `CJ_*` from `create_jobfile.py`, `RU_*` from `rollup.py`.
  `cluster_run.py` branches on them.
- `--report-json -` wraps its JSON in `===INFRA-JSON-BEGIN===` / `===INFRA-JSON-END===`
  (defined identically in both scripts) so an orchestrator can recover it from noisy
  stdout. Adding `--report-json` must never change default stdout behavior.
</content>
</invoke>
