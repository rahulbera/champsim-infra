# SWE-agent capture: results

**Instance:** `prometheus__prometheus-15142` (SWE-bench Multilingual, Go)
**base_commit:** `16bba78f1549cfd7909b61ebd7c55c822c86630b`
**Model:** GLM 5.2 via `https://api.z.ai/api/paas/v4`, temperature 0
**Date:** 2026-08-06

## The recorded trajectory

| | |
|---|---|
| Steps | 147, `exit_status: submitted` |
| Patch | 7763 bytes, modifies `tsdb/head_append.go` (gold patch: 7769 bytes) |
| API calls | 147 (8,493,806 tokens sent / 5,213 received) |
| Cassettes | 147, no `Authorization` header on disk |

Command mix: 38 `export`, 30 `git`, **30 Go toolchain** (`go build ./tsdb/`,
`go test -race`), 23 `grep`, 19 `sed`, 11 editor ops, 6 `python3`, 2 `submit`.

So one trace captures a CPython harness, the Go compiler, the race detector and
coreutils process churn together — a mixed interpreter + compiled-toolchain
profile rather than a pure-interpreter one.

## Replay determinism (enforced, not assumed)

| | recorded | replayed |
|---|---|---|
| Steps | 147 | 147 |
| Identical actions | — | **147 / 147** |
| Patch SHA-256 (first 16) | `4ac1b9cd2e0d0379` | `4ac1b9cd2e0d0379` |
| Cassette misses | — | **0** |

A cassette miss is a hard 500 and fails the run, so "deterministic replay" is a
checked property. `replay misses: 0` also held during the traced pass itself,
so the trace corresponds to this exact execution.

**Sequence matching, not content hashing.** Content hashing was tried first and
failed with 60 misses in 147 calls: an agent's request carries its whole
conversation *including tool output*, and `go test -race` prints elapsed times,
so one timing difference changes that request's hash and every later one. No
amount of key canonicalisation fixes that — the volatile data is in the body.

## The full execution (profile pass)

```
326,925,311,180 instructions
274,105,390,496 user   (83.8%)
 52,819,920,684 kernel (16.2%)
```

Three times larger than the pre-measurement estimate of ~100 B, which is why
the gap is measured rather than hardcoded — a fixed gap would have crowded all
four windows into the first third of the run.

## Capture geometry

4 windows × 300 M instructions (matching the SPEC SimPoint slice length in
`champsim-infra`, so agentic-vs-SPEC comparisons are apples-to-apples).
`sample_gap = 90,968,463,498` user-mode instructions.

| window | stream start | trajectory position | user | kernel | branches |
|---|---|---|---|---|---|
| w0 | 0 | 0% | 80.8% | 19.2% | 18.8% |
| w1 | 106,868,345,320 | 33% | 100.0% | 0.0% | 19.6% |
| w2 | 215,659,336,766 | 67% | 100.0% | 0.0% | 19.8% |
| w3 | 326,271,846,226 | 99.8% | 78.4% | 21.6% | 19.4% |

**The user-mode clock is doing real work.** The configured gap is 90.97 B
*user* instructions; observed *stream* gaps are 106.9 / 108.8 / 110.6 B. That
ratio is the measured 83.8% user fraction — kernel instructions elapsed without
advancing the clock, so windows stayed uniformly spread instead of drifting off
the end of the trajectory.

**Windows 1 and 2 are ~100% user-mode**, almost certainly inside `go build` /
`go test` compilation, while w0 and w3 sit in syscall-heavy exploration and
submission. That phase heterogeneity is why uniform sampling was chosen over
SimPoint: an agent trajectory is a sequence of *distinct* activities, not a
loop nest with recurring phases.

## Validation

Raw capture 30.4 GB → 3.1 GB zstd; converted 2.75 GB across four ChampSim v2
traces.

* **0 decode failures** across all 1.2 B instructions. (For contrast, tracing
  from power-on produced 1,163,614 failures — 5.8% — because early boot runs in
  16/32-bit mode. Zero here confirms the trigger armed inside 64-bit code.)
* **0 idle instructions**: 3 `HLT`s in 300 M, so `trace_filter` had nothing to
  strip. The user-mode sampling clock kept every window on real work — the
  concern it was built for, since a dedicated isolated vCPU idles *more*, not
  less, when the workload blocks.
* **All six acceptance checks pass on every window.**

Branch mix (w3), representative:

| type | share | taken |
|---|---|---|
| CONDITIONAL | 72.65% | 23.96% |
| RETURN | 9.07% | 100% |
| DIRECT_CALL | 8.63% | 100% |
| DIRECT_JUMP | 6.31% | 100% |
| INDIRECT | 2.78% | 100% |
| INDIRECT_CALL | 0.56% | 100% |

Calls (9.19%) balance returns (9.07%), and the conditional share sits in the
60–85% band typical of integer code.

## Configuration to record with the traces

* QEMU 9.2.4, `-accel tcg -cpu max -smp 4 -m 8G`, tracing vCPU 1 only.
* `-cpu qemu64` **does not work**: `sweagent` takes SIGILL while importing,
  because qemu64 is Opteron-era (SSE2 only) and a compiled wheel in its
  dependency tree needs a newer baseline. Never surfaced earlier because all
  prior runs used KVM `-cpu host`, and the Go-only gate builds to the x86-64
  baseline.
* Mitigations under `-cpu max`: `spectre_v2: Retpolines; RSB filling` —
  identical to `qemu64`, so the kernel branch mix stays comparable.
  `mitigations=off` was deliberately **not** used: retpolines are
  indirect-branch code, and this is a branch-prediction study.
* Guest: `isolcpus=managed_irq,domain,1 nohz_full=1 rcu_nocbs=1
  irqaffinity=0,2,3 norandmaps transparent_hugepage=never`, ASLR off, swap off.
* Agent and proxy both pinned to vCPU 1 with `taskset`; tool subprocesses
  inherit the affinity through `fork`/`exec`, which is why the non-Docker
  deployment was required.

**Modeling caveat:** the replay proxy runs on the traced vCPU, so its
serving work is in the trace. In production the LLM is remote, so this inflates
the agent's apparent CPU work. Deliberate — the brief lists the proxy as CPU
work to capture — but it must be stated wherever these traces are reported.

---

# First simulation results (TAGE-SC-L 64 KB, 50 M warmup / 200 M sim)

Agentic windows against SPEC CPU 2026 at identical 300 M slice geometry.

| trace | BP acc% | BP MPKI | L1I MPKI | IPC |
|---|---|---|---|---|
| agent w0 | 95.69 | 8.18 | 21.3 | 1.05 |
| agent w1 | 98.08 | 3.65 | 21.1 | 1.85 |
| agent w2 | 98.09 | 3.63 | 21.5 | 1.96 |
| agent w3 | 99.06 | 1.81 | 13.6 | 1.32 |
| 723.llvm | 94.68 | 10.74 | 28.4 | 1.30 |
| 710.omnetpp | 97.09 | 7.04 | 0.04 | 1.05 |
| 706.stockfish | 95.04 | 5.13 | 12.0 | 1.44 |
| 721.gcc | 97.59 | 4.76 | 21.9 | 1.28 |
| 714.cpython | 98.46 | 3.15 | 45.7 | 1.96 |
| 708.sqlite | 98.60 | 2.79 | 13.3 | 1.14 |
| 727.cppcheck | 99.67 | 0.84 | 7.3 | 0.54 |

## Aggregate metrics do NOT distinguish the workload

Agentic branch MPKI (1.8–8.2) sits inside SPEC's range (0.84–10.7), and L1I
MPKI (13.6–21.5) inside SPEC's (0.04–45.7). `llvm` mispredicts more than any
agentic window, and **SPEC's own `cpython` has more than double the L1I
pressure** (45.7 vs 21.5) — which directly undercuts the originally proposed
mechanism that CPython's dispatch loop makes agentic code frontend-hostile.
The interpreter alone is more I-cache hostile than the agent running on it.

## The misprediction COMPOSITION does distinguish it

| trace | conditional | indirect | indirect % of misses |
|---|---|---|---|
| **agent w1** | 0.30 | 2.91 | **86.3%** |
| **agent w2** | 0.25 | 2.95 | **87.7%** |
| agent w0 | 4.88 | 1.61 | 24.4% |
| agent w3 | 0.91 | 0.45 | 25.9% |
| 727.cppcheck | 0.27 | 0.44 | 56.8% |
| 714.cpython | 0.97 | 1.29 | 41.0% |
| 708.sqlite | 2.01 | 0.56 | 23.9% |
| 723.llvm | 7.38 | 0.87 | 9.4% |
| 721.gcc | 4.04 | 0.16 | 5.5% |
| 706.stockfish | 4.87 | 0.21 | 4.2% |
| 710.omnetpp | 6.89 | 0.14 | 2.0% |

In the compute-heavy windows conditional prediction is essentially solved
(0.25–0.30 MPKI) while **indirect branches account for 86–88% of all
mispredictions**. Every traditional SPEC workload is the mirror image.

**Design implication:** for this workload a better conditional predictor buys
almost nothing. The budget belongs in indirect target prediction — ITTAGE,
larger indirect target buffers, return-address handling.

## Caveats, in order of how much they could change the conclusion

1. **The indirect dominance may be Go, not agency.** Windows 1 and 2 are the
   `go build`/`go test` phases, Go leans on interface dispatch, and SPEC 2026
   contains no Go benchmark. This may measure "the Go toolchain is
   indirect-heavy" rather than "agentic workloads are". Distinguishing them
   needs a Python-task agent trace, or a standalone Go compile with no agent.
   **This is the next experiment.**
2. **n = 1 task, 1 model, 4 windows.** No claim of generality.
3. **Phase heterogeneity is large**: indirect share swings 24% → 87% → 26%
   across the trajectory, so a single slice misrepresents the workload badly.
   Supports uniform sampling over SimPoint; also means window count matters.
4. **The replay proxy runs on the traced vCPU**, so its serving work inflates
   apparent CPU cost relative to a deployment with a remote LLM.
5. Only one SPEC slice per benchmark was simulated, so SPEC's own
   intra-benchmark variance is unmeasured and the variance comparison is
   one-sided.
