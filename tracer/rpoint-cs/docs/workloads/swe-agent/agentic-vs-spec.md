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

### The captures, and why these four

One instance per execution model, because the SPEC baseline suggests the
execution model is what the indirect share tracks.

| capture | language | execution model | what it decides |
|---|---|---|---|
| prometheus | Go | compiled, interface dispatch | the original result |
| redis | C | compiled, direct calls | if this is *also* indirect-heavy, the Go result was about agency |
| rubocop | Ruby | bytecode interpreter (computed goto) | the decisive one — MRI dispatches like CPython, and `cpython_r.sp0` is 99.8% indirect |
| ripgrep | Rust | compiled, monomorphised generics | separates "compiled" from "Go's interface dispatch" |
| immutable-js | JavaScript | V8 JIT, inline caches | a fourth model again |

The JS choice was constrained by mechanics rather than science: babel uses yarn
and vuejs/core uses pnpm (the module needs npm with a lockfile, because
`npm install` rewrites it into the agent's patch while `npm ci` refuses to), and
preact runs its suite in headless Chrome, which is not viable under TCG on one
pinned vCPU.

### Running several captures at once

Everything that was global is keyed on a per-instance `CAPTURE_SLOT`: ssh
forwards, the plugin's trigger file, the profile output directory and the QEMU
pidfile. Before that, `stop_qemu` matched by process NAME, so starting a second
capture would have killed the first one's guest mid-pass. QEMU writes its own
pidfile — deriving it from `$!` through `nohup` inside a subshell yielded the
subshell's pid, so the driver watched a bash that had already exited.

TCG phases run under a semaphore (three at a time); each pins four vCPU threads
flat out. Verify and record are KVM and effectively free.

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

(These figures were recomputed from scratch by `analyze_bp.py` — now in
`run-assets/scripts/` — and reproduce the original ad-hoc analysis to the
digit, a cross-check of the rebuilt tooling.)

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

TAGE-SC-L 64 KB, 50 M warmup / 200 M sim. Full table in `spec_baseline.csv`,
which now lives in `run-assets/docs/workloads/swe-agent/` — it is ChampSim
output rather than capture material, so it left this repo with the rest of
the experiment tooling (see `run-assets/PROVENANCE.md`).

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

## The captures, all six

Branch-type mix under TAGE-SC-L 64 KB, 50 M warmup / 200 M sim. `w0` is the same
harness-startup phase in every capture and is excluded from the compute-window
reading below — see "w0 is a control you get for free".

| capture | lang | w0 | w1 | w2 | w3 |
|---|---|---|---|---|---|
| prometheus | Go | 24.4% | **86.3%** | **87.7%** | 25.9% |
| gin | Go | 24.4% | 25.0% | 16.0% | **55.1%** |
| ripgrep | Rust | 24.1% | **66.4%** | 14.0% | 24.7% |
| rubocop | Ruby | 24.5% | **65.9%** | **59.4%** | **65.0%** |
| immutable-js | JS | 24.4% | 15.6% | 12.6% | 16.2% |
| redis | C | 24.3% | 6.9% | 6.2% | 27.3% |

(indirect share of mispredictions; **bold** = ≥50%)

### Non-agentic controls

The same repo, the same build and test commands, **no agent**. This is the
control the whole study turns on.

| control | lang | w0 | w1 | w2 | w3 |
|---|---|---|---|---|---|
| prometheus | Go | 0.6% | 8.7% | 3.0% | 0.1% |
| redis | C | 3.7% | 0.6% | 2.2% | 24.8% |
| rubocop | Ruby | 21.1% | 30.1% | 49.7% | **67.7%** |

Three different answers, and they are the point:

- **C — the agent adds nothing.** redis is conditional-dominated with or without
  it. Matches SPEC's `gcc`.
- **Ruby — it is the interpreter, not the agent.** The control reaches 67.7%,
  above anything the agentic run produced. MRI's YARV dispatch, exactly as
  `714.cpython_r.sp0` predicted.
- **Go — the agent dominates.** 86–88% agentic against 0.1–8.7% control. Not the
  toolchain. This is the one place agency itself shows up.

**One caveat on the Go control, and it is not small.** The control ran
`go test -c`; the agent ran `go test -race`. The race detector instruments every
memory access and could plausibly account for some of the gap. Re-running the
control with `-race` is the experiment that would close this, and it has not
been run. Until it is, "the agent dominates in Go" is the leading explanation
rather than an established one.

### w0 is a control you get for free

w0 lands at 24.1–24.5% indirect, ~8.2 MPKI and IPC ~1.05 in **all six** agentic
captures across five languages. It is the harness starting up — identical work
every time. Two consequences: it is excluded from every compute-window claim
above, and its reproducibility across six independent capture chains is evidence
the pipeline is deterministic.

The non-agentic controls do *not* share it (0.6–21.1%), which is the expected
result: they run no agent harness.

---

## Head-to-head: the CBP2025 predictors on agentic traces

252 runs = 7 configurations × 36 traces, 50 M warmup / 200 M sim. Zero non-zero
exits; wrapped-trace and missing-metadata gates both 0; `headroom.py` reported no
invariant violations — including the measured `perfall ≤ perfdir ≤ base` cycle
ordering, which SPEC violated on 5 of 32 traces.

**Weighting.** Agentic traces are equally weighted — they come from uniform
sampling on the user-mode clock, not from SimPoint, so there is no weight to
apply. The SPEC column below is therefore also pooled equal-weight over its 32
traces, so the two are computed the same way. This is **not** the campaign's
headline SPEC number, which is SimPoint-weighted over 14 workloads and puts
direction at 58.4% of headroom rather than 67.2%. Quoting the SimPoint figure
against an equal-weighted agentic figure would be comparing two different
estimators.

### Q1 — Where is the headroom?

| population | perfdir | perfall | branch headroom | **direction** | **target** |
|---|---|---|---|---|---|
| SPEC CPU 2026 (32) | 1.0832 | 1.1280 | 11.10% | **67.2%** | 32.8% |
| agentic, with agent (24) | 1.0708 | **1.2322** | **17.46%** | **38.0%** | **62.0%** |
| toolchain control (12) | 1.0383 | 1.1403 | 12.25% | 31.2% | 68.8% |

Headroom is cycle-domain and pooled over the traces present in all three
configurations. Cycles are additive, so a pooled estimator exists; IPC ratios are
not, and the two disagree materially.

**Agentic has 57% more branch headroom than SPEC, and a perfect direction
predictor reaches less of it** (1.0708× vs 1.0832×). The split inverts: on SPEC
direction is two-thirds of the prize, on agentic it is barely a third.

The same inversion appears in the raw misprediction mix, independent of any
timing model:

| | direction share of mispredictions (pooled) | per-trace median | traces where direction is < half |
|---|---|---|---|
| SPEC | 66.4% | 80.7% | 9/32 |
| agentic | 37.7% | 40.4% | **20/24** |
| toolchain control | 32.1% | 37.0% | 10/12 |

### Q2 — Do the SOTA direction predictors capture any of it?

| population | best speedup | best dirMPKI red% | best CycWPKI red% | of direction headroom |
|---|---|---|---|---|
| SPEC | 1.0080 (RUNLTS+RV) | 11.13% | 3.74% | 10.84% |
| agentic | 1.0116 (DD-TAGE) | **17.48%** | **2.28%** | 15.36% |
| toolchain control | 1.0048 (RUNLTS+RV) | 12.40% | 1.93% | 13.23% |

**The sharpest result is the one that looks like good news.** RUNLTS and DD-TAGE
cut direction MPKI by 17.5% on agentic traces — *better* than the 11.1% they
manage on SPEC — and it buys 1.2% IPC. They work better and matter less.
CycWPKI reduction moves the other way (2.28% vs 3.74%), because the wrong-path
cycles are increasingly not direction-induced.

**The championship ordering collapses.** On SPEC the four are cleanly monotone —
192KB 1.0059 → DD-TAGE 1.0074 → RUNLTS 1.0078 → RUNLTS+RV 1.0080, with direction
MPKI reductions 8.54 / 10.04 / 11.06 / 11.13%. On agentic they land within 0.05%
of each other (1.0115 / 1.0116 / 1.0111 / 1.0112), and on direction MPKI **both
RUNLTS variants fall below a merely scaled TAGE-SC-L 192KB** (16.95 / 16.91 vs
17.14%). The CBP2025 winners lose their edge over the baseline they were built to
beat. That is a result about *differentiation*, not just about magnitude.

### What this supports, and what it does not

Supported: **for this workload class, branch prediction research aimed at
direction is aimed at the smaller half of the problem.** Agentic traces have more
branch headroom than SPEC, most of it is target, and the CBP2025 field neither
addresses targets nor separates from each other once you leave SPEC.

Not supported: that this is *about agency*. The toolchain-only control is **also**
target-dominated — more so (68.8% vs 62.0%). What the agent changes is
magnitude — 17.46% vs 12.25% headroom, 1.2322× vs 1.1403× perfall — not the
direction/target split. The defensible claim is about **software-development
tooling as a workload class**, agentic or not, with the agent amplifying an
effect the toolchain already has. Framing it as purely "agentic" would overclaim
against this study's own control.

Every headroom figure is a **lower bound**: these runs use `mispredict_penalty: 1`
and no front-end refill model. That cuts one way. If the headroom looks large
here it is larger on a real machine; if it looks small, that is not evidence it
is small.

Data: `cbp6-agentic/analysis/` (agentic), `cbp6-runs/analysis/` (SPEC).
