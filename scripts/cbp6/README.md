# scripts/cbp6/ — running the CBP2025 predictor campaign on agentic traces

The campaign itself lives in `/home/rbera/work/bpeval/cbp6-runs`, which is **not
under version control** — hence these copies. Deploy with:

```bash
cp scripts/cbp6/*.sh scripts/cbp6/*.py /home/rbera/work/bpeval/cbp6-runs/
```

Read `cbp6-runs/README.md` first; it is the authority on the campaign and its
traps. These three scripts only extend it to a new trace set.

| Script | Purpose |
|---|---|
| `rebuild_bin.sh` | Rebuild the 7 binaries per its §4, in a scrubbed environment. |
| `make_agentic_weights.py` | Write `<instance>.traces.json` so the roll-up can weight agentic windows. |
| `run_agentic_sweep.sh` | Validate → sweep → gate → roll up, end to end. |

## Why this comparison

The SPEC campaign found that **direction is 58.4% of the branch headroom and
targets are the other 41.6%**, and that no CBP2025 submission addresses targets.
It also found the four predictors capture only 8.1–9.7% of the direction
headroom, worth ~0.8% IPC.

The agentic traces are **86–88% indirect** in their compute-heavy windows. So the
prediction is that these predictors buy even less there, while the
`perfdir` → `perfall` oracle gap widens sharply. That is the point: not that the
CBP2025 work is poor, but that **direction prediction is the wrong lever for this
workload class**, and this measures by how much.

## Three things that must not be skipped

- **`rebuild_bin.sh` ends by asserting `cbp_runlts != cbp_runlts_rv`.** If the
  `CHAMPSIM_TRACE_MEMORY_VALUES` flag is dropped, the two binaries are identical
  and the sweep reproduces "load values do not help" for entirely the wrong
  reason. The `make clean` between builds is load-bearing for the same reason:
  the flag changes `ooo_model_instr`'s size in every translation unit, so mixing
  objects is an ODR violation that yields wrong statistics rather than a link
  error.
- **Both trace validators run before the sweep.** A previous generation of these
  v2 traces omitted the flags register; ChampSim then saw *zero* conditional
  branches and all four predictors returned an identical 21.93 MPKI — which reads
  as a result, not as a bug. The fall-through check is independent of the
  simulator and is what the perfect-predictor oracle silently depends on.
- **Equal weights for agentic windows are correct, not a shortcut.** SimPoint
  weights reconstruct a program from an *unequal* sample; the agentic windows are
  uniformly spaced on the user-instruction clock by construction, so 1/K each is
  the equivalent reconstruction. Without a weights file the roll-up silently
  collapses every window into one `unknown` bucket.

## Aggregation

Do not arithmetic-mean per-trace percentage reductions (near-zero-MPKI traces
score −286% and can invert a ranking) and do not geomean headroom capture (it is
undefined when a trace has no headroom — `714.cpython_r`'s direction MPKI is
already 0.001). Pool counts, then take one ratio. `rollup.py` labels which is
which.
