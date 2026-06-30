# scripts/ — the core run pipeline

The heart of this infra. These scripts take a set of **traces** and a set of
**experiments**, fan out one ChampSim run per `(trace × experiment)` pair,
stage traces into a node-local cache, and roll the per-run stats up into a
single CSV. The same scripts back the `regression/` harness and (over SSH) the
`cluster_run.py` remote orchestrator.

> **Python:** use `python3.12`. This host's `python3` is 3.8, but
> `create_jobfile.py` needs ≥ 3.9 (`argparse.BooleanOptionalAction`) and the
> regression/test scripts shebang `python3.12`. The only third-party dep is
> `pyyaml`.

## The data model: three kinds of YAML

Every script is driven by some combination of these three file types. **All
three merge across multiple files** passed to one flag (so you can compose
suites) and **abort on duplicate/conflicting names**. YAML **must be
space-indented** — PyYAML rejects tabs.

| Kind | Flag | What it holds | Example |
|------|------|---------------|---------|
| **tlist** | `--tlist` | Traces. A top-level suite key → list of `{name: {path, version, workload, category, …, checksum}}`. | `example_tlist.yml` |
| **exp** | `--exp` | Experiments. A `definitions:` block of `$(VAR)` macros + an `experiments:` block where each value is the **full ChampSim flag string**. | `example_exp.yml` |
| **mfile** | `--mfile` | Metrics for rollup. Each entry is `name: "<expr>"`, where the expression references raw ChampSim stat names as `$(STAT_NAME)`. | `example_mfile.yml` |

Two ordering/syntax rules bite if ignored:

- **Flag order in an exp string is significant.** ChampSim applies CLI flags and
  `--config` files left-to-right with last-wins semantics, so a CLI override must
  come *after* any `--config` that sets the same key.
- `$(VAR)` is the substitution syntax everywhere — `definitions:` macros in exp
  files and `$(STAT_NAME)` stat references in mfiles.

The example files (`example_tlist.yml`, `example_exp.yml`, `example_mfile.yml`)
are runnable templates — copy and edit them.

## Scripts

| Script | Role |
|--------|------|
| `create_jobfile.py` | Generates `jobfile.sh` — one tagged command per `(trace × exp)` pair. Slurm (`sbatch --wrap`) by default, or raw local commands with `--local`. |
| `run_champsim.py` | The per-job wrapper that `create_jobfile.py` puts in front of each ChampSim command. Stages the trace into the cache, substitutes the local path, then `exec`s ChampSim. |
| `fetch_trace.py` | The concurrency-safe trace cacher used by `run_champsim.py`. Also a standalone CLI / importable module. |
| `rollup.py` | Scans the per-run `.out`/`.err` files and writes `stats.csv` of your metrics. |
| `tsv_to_tlist.py` | Generates a tlist YAML from a trace-metadata TSV. |
| `cluster_run.py` | Remote Slurm orchestration over SSH (its own runbook — see below). |
| `example_*.yml`, `example_metadata.tsv` | Templates / sample inputs. |

## How the pieces fit

```
tlist + exp ─► create_jobfile.py ─► jobfile.sh
                                       │  (each line is tagged <trace>_<exp>)
                                       ▼
                              run_champsim.py  ──► fetch_trace.py ──► /tmp/trace_cache
                                       │            (flock + atomic rename)
                                       ▼
                                    ChampSim ──► <trace>_<exp>.out / .err
                                       │
tlist + exp + mfile ─► rollup.py ◄─────┘ ──► stats.csv
```

The artifact key `<trace_name>_<exp_name>` is the contract between the writer
(`create_jobfile.py`) and the reader (`rollup.py`). Keep it consistent if you
touch either.

## create_jobfile.py — generate the jobfile

```bash
python3.12 create_jobfile.py \
    --exe   /path/to/champsim_binary \
    --tlist example_tlist.yml \
    --exp   example_exp.yml \
    -o      jobfile.sh
bash jobfile.sh        # launch (sbatch lines, or local commands with --local)
```

Each emitted command writes stdout to `<tag>.out` and stderr to `<tag>.err`.
By default the binary is **snapshotted** (hardlinked into `<output-dir>/bin/`)
so a mid-sweep rebuild can't change which binary queued jobs run.

Key flags (see `--help` for the full list):

| Flag | Default | Meaning |
|------|---------|---------|
| `--exe` | _(required)_ | ChampSim binary to run. |
| `--tlist` / `--exp` | _(required)_ | One or more trace / experiment YAMLs (merged). |
| `-o`, `--output` | `jobfile.sh` | Output jobfile path. |
| `--local` | off | Emit raw local commands instead of `sbatch` lines. |
| `--local-parallel N` | `1` | Max local commands in flight (`--local` mode). |
| `--slurm-part` / `--ncores` / `--nodename` / `--include` / `--exclude` / `--extra` | `compute` / `1` / `ntl-zeus` / … | Slurm placement knobs. |
| `--snapshot-exe` / `--no-snapshot-exe` | snapshot on | Hardlink the binary into `<out>/bin/<exe>.<ts>` and run that. |
| `--no-trace-cache` | cache on | Skip `fetch_trace`; read traces directly from NFS. |
| `--trace-cache-dir DIR` | `/tmp/trace_cache` | Override the node-local cache dir. |
| `--smoke-test` | off | Run one pair locally with tiny warmup/sim counts to sanity-check before the full sweep. |
| `--smoke-warmup` / `--smoke-sim` / `--smoke-test-idx` | `1M` / `1M` / `0` | Smoke-test instruction counts and which pair to use. |
| `--report-json PATH` | off | Emit a machine-readable JSON report (stable `error_id`s) to a file or `-` for stdout. Used by `cluster_run.py`. |

`--smoke-test-auto-launch` (Slurm only) runs the smoke test and, **only if it
passes**, submits every `sbatch` job itself, capturing each `tag → job_id`.

## run_champsim.py + fetch_trace.py — the trace cache

`create_jobfile.py` wraps every ChampSim command in `run_champsim.py`. It finds
the `-traces <path>` argument, runs it through `fetch_trace.fetch(...)` to stage
the trace into a node-local cache (`/tmp/trace_cache`), substitutes the cached
path, and `exec`s ChampSim. The simulator never knows it happened.

`fetch_trace.py` is the concurrency-critical piece: 16–32 array jobs landing on a
node all want the same trace, so it takes a **per-trace `flock`** and publishes
via tempfile + atomic `rename(2)` — readers see no entry or a complete one, never
a torn copy. Optional SHA-256 verification; the cache key is the path basename.

```bash
# standalone use (prints the local cached path):
python3.12 fetch_trace.py --path /nfs/…/trace.champsim2.zst [--checksum <sha256>]
```

## rollup.py — collect the stats

```bash
python3.12 rollup.py \
    --tlist example_tlist.yml \
    --exp   example_exp.yml \
    --mfile example_mfile.yml \
    -d      ./           \      # dir(s) holding the <trace>_<exp>.out/.err files
    -o      stats.csv
```

`stats.csv` columns are `TraceName, ExpName, <metrics…>, Filter`. A run is
**filtered** (`Filter=0`) if its `.err` matches a failure keyword
(segfault, abort, assertion, OOM, …) or files are missing. Note: **if any
experiment for a trace fails, all rows for that trace are filtered**, so the
table stays apples-to-apples per trace.

`-d` takes **one or more** dirs, searched in order (first `<trace>_<exp>.out`
match wins), so a single rollup can span several batch output dirs; the
`trace_failed` rule spans them too.

## tsv_to_tlist.py — make a tlist from a TSV

```bash
python3.12 tsv_to_tlist.py --tsv metadata.tsv --out my_suite.tlist.yml --group spec26
```

The TSV needs at least `name, path, version, workload, weight, category, tag`
columns. See `example_metadata.tsv`.

## cluster_run.py — remote Slurm runs

Runs the above pipeline on an **SSH-only** Slurm cluster (`bootstrap | submit |
status | rollup | combine | list`). It has its own full runbook —
see **[`../docs/cluster-run.md`](../docs/cluster-run.md)** and the `cluster-run`
skill. Don't drive it by hand from this README.

## Tests

`../tests/` covers the `--report-json` / `error_id` plumbing, the smoke-gate, and
the cluster lifecycle. Run them (and keep them green) when you touch
`create_jobfile.py`, `rollup.py`, or `cluster_run.py` — see
[`../tests/README.md`](../tests/README.md).
