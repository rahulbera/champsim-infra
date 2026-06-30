# champsim-infra

Infrastructure — **not the simulator** — for generating
[ChampSim](https://github.com/ChampSim/ChampSim) traces and running trace-driven
simulations at scale on a Slurm cluster. It covers the whole loop around the
simulator: generate traces from real workloads, sweep every `(trace ×
experiment)` pair, stage traces into a node-local cache, roll per-run stats up
into a CSV, gate changes with deterministic regressions, and orchestrate all of
that on a remote SSH-only cluster.

ChampSim itself, the Hermes/Pythia/arishem forks, and the traces all live
**outside** this repo (typically siblings under `/home/rahbera/thesis/` and
`/home/rahbera/tracezoo/`). This repo only contains the tooling.

## Repository layout

| Directory | What it is | More |
|-----------|------------|------|
| [`pintool/`](pintool/README.md) | The Intel PIN tracer that **produces** ChampSim traces. Instrument a workload with ROI markers, run it under PIN, get a compressed trace. | [README](pintool/README.md) |
| [`scripts/`](scripts/README.md) | The core run pipeline. The `tlist`/`exp`/`mfile` YAML data model, jobfile generation, the concurrency-safe trace cache, and stats rollup. | [README](scripts/README.md) |
| [`regression/`](regression/README.md) | A thin harness that chains the pipeline into a deterministic, timestamped regression run and diffs it against the previous one (CI-gate friendly). | [README](regression/README.md) |
| [`tools/`](tools/README.md) | Standalone C++ trace utilities: split a big trace into chunks (`trace_cutter`), or walk a trace and print stats (`trace_sanity_check`). | [README](tools/README.md) |
| [`tests/`](tests/README.md) | Plain `assert`-based tests for the pipeline scripts. No pytest, no network — the cluster is faked. | [README](tests/README.md) |
| [`docs/`](docs/cluster-run.md) | Long-form docs. Notably `cluster-run.md`, the runbook for remote Slurm runs. | [cluster-run.md](docs/cluster-run.md) |
| `CLAUDE.md` | Guidance for the Claude Code agent working in this repo (also a useful design overview for humans). | — |

## How it fits together

```
                pintool/  ─────────────────────►  *.champsim2.zst traces
        (instrument a workload, run under PIN)            │
                                                          ▼
   tlist (traces) + exp (experiments) + mfile (metrics)   │  YAML inputs
                          │                               │
                          ▼                               │
            scripts/create_jobfile.py ──► jobfile.sh ─────┤  one run per (trace × exp)
                          │                               │
                          ▼                               ▼
            run_champsim.py + fetch_trace.py ──► ChampSim ──► <trace>_<exp>.out/.err
                          │
                          ▼
              scripts/rollup.py ──► stats.csv
```

- **`regression/`** drives that whole chain end-to-end and adds a determinism
  check (identical binary+config+trace ⇒ identical stats).
- **`scripts/cluster_run.py`** drives the same chain on a remote Slurm cluster
  over SSH (see [`docs/cluster-run.md`](docs/cluster-run.md)).

Start with [`scripts/README.md`](scripts/README.md) — it explains the
`tlist`/`exp`/`mfile` data model that everything else builds on.

## Environment essentials

- **Python:** use `python3.12`. The host `python3` is 3.8, but the scripts need
  ≥ 3.9 (`argparse.BooleanOptionalAction`) and shebang `python3.12`. The only
  third-party Python dependency is `pyyaml`.
- **YAML must be space-indented** — PyYAML rejects tabs.
- **`ZSTD_HOME`** (default `/home/rahbera/local`) points at the zstd build used by
  the tracer and the C++ trace tools.
- **`PIN_ROOT`** (Intel PIN 4.0) is needed to build the `pintool/` tracer.
- Artifact keys are `<trace_name>_<exp_name>` everywhere, and `$(VAR)` is the
  substitution syntax across all the YAML — keep both consistent if you extend
  the tooling.

Each subdirectory's README has the build/run details and the full flag reference
for its tools.
