# Agentic workloads against SPEC CPU 2026

Rolling record of the multi-language agentic capture study. One section per
captured instance, then the head-to-head.

**The question.** The first capture (prometheus, Go) came out
indirect-dominated: 86–88% of mispredictions were indirect in its compute-heavy
windows, against 2–6% for most SPEC benchmarks. But those windows were `go build`
/ `go test` phases, Go leans on interface dispatch, and SPEC 2026 has no Go
benchmark — so the result may measure *the Go toolchain*, not *agency*. Every
capture here exists to separate those.

## Method (identical for every instance)

Five passes, each gated. See `scripts/swe-agent/README.md` for the mechanics.

| pass | what it establishes |
|---|---|
| provision | the repo builds and its tests pass **with no network** (`unshare -n`) |
| record | one real LLM run through a recording proxy; cassettes hold no API key |
| verify | offline replay reproduces the recording **exactly** |
| profile | total instructions executed, measured not assumed |
| trace | 4 × 300 M windows, uniformly spaced on the **user-mode** clock |
| convert | ChampSim v2 + `trace_sanity_check --check` on every window |

300 M matches the SPEC SimPoint slice length in `champsim-infra`, so every
comparison below is at identical geometry.

### Gates that exist because they caught something

- **Instance validity, before any VM time.** With `test_patch` applied, the
  target test must *run and fail* at `base_commit`, then *run and pass* with the
  gold patch. "Exited non-zero" is not evidence: a stale server holding a port,
  a too-long unix socket path, and an unbuildable tree all exit non-zero. A
  Django candidate was rejected this way (it predated the guest's Python), and
  redis was confirmed this way.
- **Replay must reproduce the recording, not merely avoid misses.** Sequence
  replay serves recorded responses in order regardless of request content, so a
  replay that stops early never misses — it just runs out of steps.
  `compare_trajectories.py` checks step count, every action, and the final patch
  SHA. See the redis section for the run this caught.
- **Every gate that counts work must count it.** A test selector matching
  nothing exits 0 having run zero tests; an incremental `make` after a build
  compiles nothing and exits 0. Both are structurally perfect and semantically
  empty.
- **The replay must start from the disk state the recording started from.**
  Replay restores the *provisioned* image and injects the cassettes, not the
  post-record snapshot. This is the one failure no gate can catch: the replay
  originally ran `git clean -xfd`, and `-x` deletes ignored files — the entire
  build tree. The agent's first `make` then became a from-scratch build of the
  project and all its vendored dependencies, where the recording did a one-file
  incremental rebuild.

  The actions are identical either way, because they come from replayed LLM
  responses rather than from observations, so the trajectory comparison reports
  a perfect match. Only the *work* differs — and the work is the entire
  measurement. **A trajectory can match perfectly and still describe a
  completely different amount of computation.**

### Known modelling caveats

- The replay proxy runs on the traced vCPU, so its serving work is in the trace.
  In production the LLM is remote, so this inflates the agent's apparent CPU
  work. Deliberate — the brief lists the proxy as CPU work to capture — but it
  must be stated wherever these traces are reported.
- SWE-agent's per-command timeout is disabled during replay. On one pinned vCPU
  a command that took 12 s on 32 cores takes minutes, and the default 30 s limit
  ends the episode. The recorded trajectory is fixed, so a timeout protects
  against nothing here.
- Solving the task is not evidence of reasoning: several of these fixes were
  published before the model's cutoff and may be memorised. It does not affect
  the microarchitectural measurement — the CPU work is real either way.

---

## Capture 1 — prometheus__prometheus-15142 (Go)

Full detail in `swe-agent-capture-results.md`. Summary: 147 steps, 4 × 300 M
windows, 0 decode failures, all acceptance checks pass.

| window | MPKI | cond | indirect | return | indirect % | IPC |
|---|---|---|---|---|---|---|
| w0 | 8.18 | 4.88 | 1.99 | 0.64 | 24.4% | 1.05 |
| w1 | 3.64 | 0.30 | 3.14 | 0.14 | **86.3%** | 1.85 |
| w2 | 3.63 | 0.25 | 3.19 | 0.14 | **87.7%** | 1.96 |
| w3 | 1.81 | 0.91 | 0.47 | 0.35 | 25.9% | 1.32 |

w1/w2 are the `go build` / `go test` phases; w0 and w3 are syscall-heavy
exploration and submission.

(These figures were recomputed from scratch by `analyze_bp.py` and reproduce the
original ad-hoc analysis to the digit — a cross-check of the rebuilt tooling.)

## Capture 2 — redis__redis-13115 (C)

**The control.** SPEC's `gcc` is the most conditional-dominated benchmark in the
suite. If an agent trace over a C codebase is *still* indirect-dominated, the Go
result was about the agent loop rather than about Go.

| | |
|---|---|
| Bug | `lua_Number` → Redis integer conversion renders `n·1e8` in scientific notation, so `HINCRBY` rejects it |
| Fix | one hunk in `src/script_lua.c` |
| Recorded | 77 steps, `exit_status: submitted`, 78 cassettes |
| Agent patch | **byte-identical to the benchmark's gold patch** (modulo git index hashes) |
| Replay | 77/77 identical actions, patch SHA `246f3af5463922d9` both sides |

Command mix: 16 search, 15 git, 14 edit, 13 read, **10 test-suite runs, 5
builds** — a genuine edit/build/test loop, not pure exploration.

**Why it vendors well.** redis keeps every dependency in `deps/` (jemalloc, lua,
hiredis, linenoise), so there is no package manager in the build and the offline
gate cannot be accidentally satisfied by a live network. The gate rebuilds from
`make distclean` and runs the full 330-test scripting suite with no network.

**The run this caught.** The first replay attempt executed 54 of 77 steps and
produced a 609-byte patch instead of the correct 1307-byte one — while reporting
**zero cassette misses** throughout. SWE-agent's 30 s command timeout kills
redis's TCL harness (16 parallel test clients) on one pinned vCPU, and three
consecutive timeouts end the episode. Without a trajectory comparison this would
have become a complete, valid, fully-validated trace of an execution that never
happened.

<!-- profile/trace/simulation results appended when the chain completes -->

---

## The SPEC baseline (all 32 slices)

TAGE-SC-L 64 KB, 50 M warmup / 200 M sim. Full table in `spec_baseline.csv`.

| | indirect share of mispredictions |
|---|---|
| SPEC, min | 0.0% |
| SPEC, median | **4.0%** |
| SPEC, mean | 14.9% |
| SPEC, upper quartile | 31.2% |
| SPEC, max (`714.cpython_r.sp0`) | **99.8%** |
| agentic (prometheus), median | 56.1% |
| agentic, range | 24.4 – 87.7% |

### This corrects the first report

The initial write-up claimed the agentic profile was the *mirror image* of
"every traditional SPEC workload". That was measured against an 8-slice subset
(stockfish, sqlite, omnetpp, cpython, gcc, llvm, cppcheck) and does not survive
the full suite:

- **9 of 32 SPEC slices are ≥24% indirect** — `727.cppcheck_r.sp1` 56.8%,
  `734.vpr_r.sp1` 37.1%, the `753.ns3_r` cluster 31–32%, `735.gem5_r.sp1`
  31.7%, `710.omnetpp_r.sp2` 28.9%, `708.sqlite_r.sp1` 23.9%.
- **`714.cpython_r.sp0` is 99.8% indirect** — 469,084 indirect mispredictions
  against 691 conditional ones in 200 M instructions. That is *more*
  indirect-dominated than any agentic window captured so far.

The defensible statement is therefore about position in a distribution, not
about kind: agentic windows sit far above the typical SPEC slice (56% vs 4%
median), but they are not categorically unlike SPEC.

### And it points at the mechanism

That 99.8% slice is CPython's computed-goto bytecode dispatch loop: an indirect
jump the predictor cannot learn, with conditionals almost perfectly predicted.
It is precisely the interpreter-dispatch mechanism proposed at the start of this
study — appearing in SPEC's own CPython benchmark rather than in the agent
trace.

This raises the value of the Ruby capture considerably. MRI/YARV uses the same
dispatch structure, so if rubocop lands near `cpython_r.sp0` then the driver is
**the execution model of the language being used**, not agency — and the Go
result was Go's interface dispatch after all.

## Head-to-head

<!-- filled in once two or more agentic captures exist -->
