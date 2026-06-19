# Hermes regression harness

A thin orchestrator around the existing `create_jobfile.py` + `rollup.py` tooling
that runs Hermes over a trace suite and a set of experiments, snapshots the
binary and all stats into a timestamped directory, rolls up target metrics, and
diffs against the most recent previous run.

It tracks whatever metrics the metric file defines — by default:

- `Core_0_cumulative_IPC`
- `Core_0_offchip_pred_precision`
- `Core_0_offchip_pred_recall`

Hermes should **not** regress on these while the off-chip predictor stays in
`core` mode (i.e. through the uncore-relocation refactor, until the uncore path
is intentionally enabled). ChampSim is deterministic, so identical
binary+config+trace must give identical stats; any change is flagged.

## Requirements

Run under **Python ≥ 3.9** (`create_jobfile.py` uses `argparse.BooleanOptionalAction`).
This host's `python3` is 3.8, so use `python3.12` — the executable shebangs already
point there, so `./run_regression.py ...` just works.

## Usage

```bash
# 1. (re)build Hermes — the run snapshots whatever binary you point --exe at
cd /home/rahbera/thesis/Hermes && ./build_champsim.sh glc multi multi multi multi 1 1 0

# 2. run the regression (OUTPUT_DIR is required; keep it OUTSIDE this repo)
cd /home/rahbera/thesis/champsim-infra/regression
./run_regression.py /home/rahbera/thesis/runs \
    --exe   /home/rahbera/thesis/Hermes/bin/glc-perceptron-no-multi-multi-multi-multi-1core-1ch \
    --tlist suites/test_suite.tlist.yml \
    --exp   suites/regression.exp.yml \
    --mfile suites/regression.mfile.yml \
    --label core-popet
```

Like `create_jobfile.py`, you choose the binary (`--exe`), trace list(s)
(`--tlist`), experiment file(s) (`--exp`) and metric file(s) (`--mfile`); all
accept multiple files. Each run writes
`OUTPUT_DIR/hermes_regression/<UTC-ts>[_label]/`:

| file | what |
|------|------|
| `bin/<exe>.<ts>` | snapshot of the binary (so a rebuild mid-run can't change it) |
| `jobfile.sh` | the generated local jobfile |
| `<trace>_<exp>.out` / `.err` | full per-run stats |
| `stats.csv` | rolled-up metrics (`TraceName, ExpName, <metrics…>, Filter`) |
| `meta.json` | exe + snapshot md5, Hermes commit, input files, parallelism |

After running, it auto-compares `stats.csv` against the most recent previous run
in the same `OUTPUT_DIR` and prints a per-(trace,exp) diff.

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `--exe` | _(required)_ | ChampSim binary under test |
| `--tlist` / `--exp` / `--mfile` | _(required)_ | trace / experiment / metric YAML(s) |
| `--label` | _(none)_ | tag appended to the run dir |
| `--local-parallel` | `cpu_count` | max ChampSim runs in parallel |
| `--no-snapshot-exe` | snapshot on | run the binary in place instead of snapshotting |

## Extending

- **More traces**: add entries to a `*.tlist.yml` (or pass several `--tlist`).
- **More experiments** (e.g. core XPT, or the uncore variants with
  `--offchip_pred_location=uncore`): add lines to `suites/regression.exp.yml`.
  Every (trace × experiment) pair is run and rolled up.
- **More tracked stats**: add `name: "$(STAT)"` lines to the metric file.

## Comparing two arbitrary runs

```bash
./compare_runs.py OUTPUT_DIR/hermes_regression/<old> OUTPUT_DIR/hermes_regression/<new>
```

Compares every metric column plus the `Filter` (pass/fail) flag, keyed on
(trace, exp). Exits non-zero if anything changed (CI-gate friendly); `--tol`
allows a relative tolerance on numeric metrics.

Results live under the user-supplied `OUTPUT_DIR` (outside this repo), so the
timestamped dirs persist on disk without bloating git history.
