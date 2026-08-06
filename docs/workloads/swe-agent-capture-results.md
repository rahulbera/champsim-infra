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
