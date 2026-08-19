# Design: explicit branch type + flags register in the ChampSim tracers

**Status:** approved, implementation in progress
**Date:** 2026-08-05
**Repos:** `champsim-infra` (this repo, the change) · `ChampSim` branch `rbdev` (the consumer, sequenced after)
**Supersedes:** `docs/handoff-branch-type-tracing.md` §5.3 (line refs), §5.4 (flag encoding), §6 (flags recommendation). That
document remains the empirical record of *why*; this one is *what we are building*.

---

## 1. Problem

Traces produced by the ChampSim pintools are unusable for branch-predictor research. ChampSim sees zero
conditional branches, so every direction predictor is inert and scores identically — four stock predictors
report byte-identical MPKI (21.93) because none is ever consulted.

Two independent causes, both confirmed by measurement:

1. **The tracers drop the flags register.** `!REG_is_flags(reg)` filters it out of both the source and the
   destination register loops. ChampSim *infers* branch type from register-usage patterns
   (`inc/instruction.h:205-243`), and a conditional branch that reads no flags matches the
   `BRANCH_DIRECT_JUMP` arm, which then overwrites `branch_taken = true` and discards the real direction.
   Proof: the "direct jump" bucket has a **49.17% taken rate** on a v2/v3 trace versus **100.00%** on a v1
   control. A genuine unconditional jump is always taken.

2. **Branch type is inferred at all.** A semantic property (what kind of control transfer is this?) is
   derived from an incidental encoding property (which registers happened to fit in a 2-slot array). Pin
   knows the answer exactly at instrumentation time.

## 2. Goals and non-goals

**Goals.** Produce traces on which ChampSim classifies branches correctly and unambiguously; restore the
`cmp → jcc` dependency edge so misprediction cost is modelled correctly; make register-slot truncation
measured rather than silent.

**Non-goals, explicitly deferred.** Destination register values for the RUNLTS value channel (see §8),
widening `NUM_INSTR_*`, changing `MAX_MEM_VALUE_SIZE`, `-values 0`, and the x86↔AArch64 register-namespace
mapping.

## 3. Scope: both tracers, not just v3

The handoff doc names only `champsim_tracer_mt_roi_v3.cpp`. That is incomplete. **v2 and v3 are the same
tracer at a fixed line offset**, and every region this change touches is byte-identical:

| region | v2 | v3 |
|---|---|---|
| record struct + `static_assert` | 98-123 | 140-165 |
| `classify_instr` | 724-742 | 796-814 |
| `RecordRegRead` / `RecordRegWrite` | 1107-1133 | 1231-1257 |
| `RecordInstrCommit` | 1151-1176 | 1275-1300 |
| `insert_full_analysis` (filter loops, `is_branch`) | 1197-1381 | 1321-1505 |

`!REG_is_flags` sits at **v2:1203 / v2:1216** and **v3:1327 / v3:1340**, textually identical. Both tracers
emit the same `.champsim2.zst` filename, so fixing only v3 would split that population into two
silently-incompatible classification classes and falsify the "strict superset / bit-identical" claim in
`v3:9-10,46-47`, `tracer/pintool/README.md:17,126` and `CLAUDE.md`.

**Both files receive the identical patch.**

## 4. Record format contract

Layout unchanged: 512 bytes, same offsets, `static_assert(sizeof(trace_instr_v2_t) == 512)` untouched. We
populate bytes that were previously always zero.

| byte | field | meaning |
|---|---|---|
| `reserved[0]` | `branch_type` | ChampSim's enum verbatim: 0 `BRANCH_DIRECT_JUMP`, 1 `BRANCH_INDIRECT`, 2 `BRANCH_CONDITIONAL`, 3 `BRANCH_DIRECT_CALL`, 4 `BRANCH_INDIRECT_CALL`, 5 `BRANCH_RETURN`, 6 `BRANCH_OTHER`, 7 `NOT_BRANCH` |
| `reserved[1]` | feature bitmask | `bit0 (0x01)` = explicit branch type present; `bit1 (0x02)` = flags register recorded |
| `reserved[2]` | tracer identity | `2` or `3` — which pintool produced this record |
| `reserved[3..7]` | zero | held for future use |

### 4.1 Why no trace-format version bump

The layout did not change. A version number describes a layout; what changed is the *content* of bytes that
were previously zero. Critically, `--trace-version` is **asserted by the user on the command line**, whereas a
feature bit is **self-describing by the data**. The bug this design fixes was a silent mismatch between what a
trace contained and what the consumer assumed; a CLI-asserted version reproduces that failure mode exactly
(pass `--trace-version 2` on a new trace → silent fallback to inference → four identical predictor results
again).

A bitmask rather than a boolean because the format will change again — the register-value work in §8 *is* a
genuine layout change and *will* deserve a version number.

Per-record rather than a file header because `trace_cutter` splits traces at 512-byte boundaries with no
header rewriting and ChampSim's reader `memcpy`s arbitrary blocks. Per-file metadata would not survive
chunking; per-record metadata survives arbitrary slicing.

`reserved[2]` exists because both tracers emit identical filenames, so a trace on disk currently carries no
record of which tool produced it — a question that could not be answered about the existing 4.7 GB trace.

### 4.2 Measured cost

Uncompressed: **exactly zero** — the record stays 512 bytes and the record count is unchanged.

Compressed (2M records of `723.llvm_r-codegen-232B.champsim2.zst`, `zstd -1`, the tracer's default level):

| change | Δ compressed |
|---|---|
| `reserved[1]` feature bitmask | +0.45% |
| `reserved[0]` branch type | +0.86% |
| flags on both register sides | ≈ +0.22% |
| **total** | **≈ +1.5%** |

The flags figure is measured against v1 `400.perlbench` with flags (5,475,579 B) versus the same 5M records
with flags stripped (5,414,729 B) = 0.0122 compressed bytes/record, applied to v3's 5.64 bytes/record.

## 5. Tracer changes

Applied identically to `champsim_tracer_mt_roi_v2.cpp` and `champsim_tracer_mt_roi_v3.cpp`.

### 5.1 `classify_branch(INS)`

New instrumentation-time helper beside `classify_instr` (v2:742 / v3:814 — *not* line ~1180 as the handoff
doc states). Returns the `reserved[0]` encoding:

```cpp
static uint8_t classify_branch(INS ins)
{
  if (INS_IsRet(ins))    return BRANCH_RETURN;                                    // 5
  if (INS_IsCall(ins))   return INS_IsDirectCall(ins) ? BRANCH_DIRECT_CALL        // 3
                                                      : BRANCH_INDIRECT_CALL;     // 4
  if (INS_IsBranch(ins)) {
    if (INS_HasFallThrough(ins)) return BRANCH_CONDITIONAL;                       // 2
    return INS_IsDirectBranch(ins) ? BRANCH_DIRECT_JUMP : BRANCH_INDIRECT;        // 0 : 1
  }
  if (INS_IsIndirectControlFlow(ins)) return BRANCH_INDIRECT;                     // 1
  return NOT_BRANCH;                                                              // 7
}
```

Order matters: returns and calls are tested before `INS_IsBranch`, which excludes them in Pin. All ten
predicates the handoff doc flagged as uncertain are confirmed present in the PIN 4.0 kit in use
(`pin-4.0-99633-5ca9893f2`).

Wired in exactly like `itype`: computed once into a local at the top of `insert_full_analysis`, passed as
`IARG_UINT32` to both `RecordInstrCommit` call sites.

### 5.2 `RecordInstrCommit`

Gains a trailing `UINT8 branch_type` parameter; writes `reserved[0]`, `reserved[1]`, `reserved[2]`. Argument
order must match between the `INS_InsertCall` list and the analysis-routine signature — Pin does not
type-check this.

### 5.3 Remove both flags filters

Delete `!REG_is_flags(reg)` from the source loop and the destination loop. `REG_valid` and `!REG_is_seg`
stay. **No reordering** — Pin's enumeration order is preserved, which naturally deprioritises flags when
slots are tight (implicit operands are enumerated last), keeping real register dependencies.

Rationale: once branch type is explicit, the register arrays have exactly one job — the dependency graph.
ChampSim gates execution on `std::all_of(source_registers, isValid)` (`src/ooo_cpu.cc:454`) and starts the
misprediction penalty at `do_complete_execution` (`src/ooo_cpu.cc:623-624`). A `jcc` with no flags source is
not gated by the `cmp` that computes its condition, so it resolves too early and **misprediction cost is
systematically understated** — precisely the quantity branch-predictor research measures.

Both sides are required. A dependency needs a producer *and* a consumer: `rename_src_register` gives an
unwritten architectural register a `valid = true` physical register immediately
(`src/register_allocator.cc:32-40`), so flags-as-source without flags-as-destination creates no stall at all.
Today a `cmp` writes *only* flags, so its `destination_registers` array is entirely empty — 22.57% of v3
records declare zero destinations versus 12.14% on v1.

WAW pressure is not a concern: ChampSim renames destinations (`rename_dest_register`), so renaming absorbs
it exactly as hardware does.

### 5.4 `is_branch` and `branch_taken` for calls and returns — required

Currently `is_branch = INS_IsBranch(ins) ? 1 : 0` (v2:1353 / v3:1477), and Pin's `INS_IsBranch` **excludes
calls and returns**; the else arm hard-codes *both* `is_branch` and `branch_taken` to 0. ChampSim rescues
this today by inferring the type and overwriting `branch_taken = true` itself.

The moment a consumer trusts `reserved[0]`, a `BRANCH_DIRECT_CALL` record carrying `branch_taken = 0`
becomes a wrong not-taken call. So:

```cpp
UINT8 is_branch = (INS_IsBranch(ins) || INS_IsCall(ins) || INS_IsRet(ins)) ? 1 : 0;
```

with `branch_taken = 1` for calls and returns (they are unconditionally taken). This is a consistency
requirement of the explicit-type contract, not an optional extra. It changes `is_branch` semantics relative
to v1 traces — which is exactly what the feature bit in `reserved[1]` exists to signal, and it must be called
out in the commit message because any tooling counting branches from `is_branch` will shift.

### 5.5 Truncation counters

`RecordRegRead` / `RecordRegWrite` scan for the first free slot and fall off the end of the loop when full —
no counter, no log. Add counters split by class (source/destination × flags/real), reported in the existing
`Fini` summary.

This converts handoff §6's open question into a number printed by every trace run. Expected near zero:
90.86% of v3 records have a free destination slot today, and the instructions that would overflow once flags
are added are the rare three-writer forms (`mul`, `div`, `cmpxchg`, `xadd`).

## 6. Prerequisites

Three defects block this work and are fixed as part of it.

1. **`tracer/pintool/makefile.rules` is missing `-I$(ZSTD_HOME)/include`.** Pin's musl CRT hides `/usr/include`, so
   the build fails with `fatal error: zstd.h: No such file or directory` even with a correct `ZSTD_HOME`.
   Fix: `TOOL_CXXFLAGS += -I$(ZSTD_HOME)/include`.
2. **`make_tracer.sh` hardcodes `/home/rahbera/...`**, which does not exist on this host. PIN 4.0 — the same
   kit — is at `/home/rbera/work/softwares/pin-external-4.0-99633-g5ca9893f2-gcc-linux`. Fix: make both
   `PIN_ROOT` and `ZSTD_HOME` environment-overridable with the existing values as defaults.
3. **`tools/trace_sanity_check` cannot build.** It `#include`s `trace_reader.h` and links
   `$(CHAMPSIM_HOME)/src/trace_reader.cc`; ChampSim renamed these to `tracereader`, and the replacement
   `champsim::tracereader` yields fully-constructed `ooo_model_instr`s — not a drop-in for a byte-level tool.
   Fix: drop the ChampSim dependency entirely and decompress by piping through the system `zstd`/`xz`/`gzip`
   binaries selected by file extension. No dev headers required (`lzma.h` and `bzlib.h` are absent on this
   host), nothing to drift, and the reference decompressors are themselves the parity reference.

## 7. Validation

The full loop closes locally in under a minute: build tracer → `pin -t … -use_markers 0 -t 200000 -- /bin/ls`
→ simulate in the prebuilt `rbdev` binary. The bug reproduces on that 200k-record trace
(`BRANCH_CONDITIONAL: 0`), so it is the test fixture — no 4.7 GB regeneration needed to iterate.

### 7.1 Acceptance checks (added to `trace_sanity_check`, `-f v2`)

1. `reserved[1] & 0x01` set on every record; `reserved[0]` takes a spread of values in 0-7, not a constant.
2. `BRANCH_CONDITIONAL` is roughly 60-85% of all branches for integer workloads (v1 perlbench: 76.3%).
   Denominator must be `reserved[0] != NOT_BRANCH`, **not** `is_branch`, because §5.4 changes `is_branch`.
3. **Among `BRANCH_CONDITIONAL` records, the taken rate is strictly between 0 and 1** (typically 45-60%).
   This is the check that would have caught the original bug.
4. Among `{DIRECT_JUMP, INDIRECT, DIRECT_CALL, INDIRECT_CALL, RETURN}`, taken rate is 100%.
5. Every record whose `reserved[0]` is a call or return has `is_branch == 1`.
6. `sizeof(input_instr_v2) == 512` — already enforced by `static_assert`.

The tool exits non-zero when a requested check fails, so it works as a CI gate.

### 7.2 End-to-end differential test

`champsim_bimodal` and `champsim_hashed_perceptron` must report **clearly different** MPKI on the new trace.
Identical to four significant figures means the direction predictor is still not being consulted.

Note this test passes **before** any ChampSim change: restoring flags alone repairs the existing inference
path. Explicit branch type makes the result robust rather than dependent on a register-usage convention.

### 7.3 Regression

`python3.12 tests/test_reports.py` and `tests/test_cluster_run.py` must stay green (29 and 60 checks).

## 8. Consumer contract (ChampSim `rbdev`, sequenced after)

Specified here, implemented once the format is frozen. `rbdev` today has **no** support: nothing reads
`reserved[]`, and `--trace-version` accepts only `{1, 2}`.

- When `reserved[1] & 0x01`, use `reserved[0]` as the branch type and skip the register-pattern cascade at
  `inc/instruction.h:205-243`. Otherwise keep inferring, so old traces behave exactly as today.
- Set `is_branch = (branch_type != NOT_BRANCH)` on that path; do not overwrite `branch_taken` for
  types the trace already reports correctly.
- Existing tests 086 / 087 / 089 must stay green. **087 asserts v1/v2 classification parity**, which holds
  because records without the bit take the unchanged path.
- **Loud guard:** if a branch predictor is active and `bit0` is clear, warn prominently. This converts "four
  predictors print identical plausible numbers" from silent to impossible, and is the highest-value line in
  the effort.

## 9. Deferred: the RUNLTS value channel

Investigated and deliberately deferred. Recorded so the decision is not re-litigated from scratch.

RUNLTS consumes exactly one value: the 64-bit architectural **destination register value** of every
instruction-piece writing a register in [0,64], delivered at the *producer's* execute. It reads **no memory
values** — `notify_agen_complete` is an empty stub. Branch records are therefore the wrong place for it; the
values live on non-branch producer records.

Measured ablation (CBP6's own simulator, 18 traces, from the ChampSim adapter design doc): full values
2.0313 MPKI · load-values-only 2.1134 (+4.04%) · no values 2.1598 (+6.33%). **Load values recover only ~36%
of the loss** — "the signal lives in ALU-computed values, not raw loaded data."

Cost to capture: +1.6% raw for one 8-byte destination value, +3.1% for two — but **≈ +38% to +51%
compressed**, measured by zeroing the first real load value in the existing trace (2.50 compressed bytes per
populated 8-byte value at `zstd -1`, against 0.87 destination registers per instruction, 1.14 with flags).

Deferred because: the study may not stay on ChampSim; archive space is a hard constraint; and the +6.33%
figure has not been reproduced on x86 traces — commit `6eac3175` notes RUNLTS-norv already *beat* a 192 KB
TAGE-SC-L on the two ChampSim traces measured, the opposite of what the ablation predicted.

Three traps recorded for whoever picks this up:

- **Oracle leak.** Values must be delivered at *modelled execute time*, as CBP2025 does. Reading a register
  value from the trace and handing it to the predictor at fetch time leaks the outcome — EFLAGS at an x86
  `je` trivially determines the direction.
- **Namespace mismatch.** `make_reg_digest` hard-partitions r0-31 int / r32-63 FP / r64 flags and gates on
  `dst_reg <= 64`; ChampSim x86 uses truncated Pin `REG` numbers (`REG_FLAGS=25`, `REG_STACK_POINTER=6`,
  `REG_INSTRUCTION_POINTER=26`).
- **Missing hooks.** ChampSim's module interface has `predict_branch`, `last_branch_result`,
  `branch_predictor_final_stats`, `branch_execute_resolve` — none carries a value. Two new hooks are needed.

## 10. Known adjacent issue, not fixed here

`create_jobfile.py:342` emits `--trace_version=N` (underscore); ChampSim `rbdev` accepts only
`--trace-version` (hyphen), `IsMember({1,2})`. Jobfiles from this repo are rejected by that binary. Left
alone deliberately — the underscore spelling is likely required by the Hermes/Pythia forks used on the
cluster, so changing it risks breaking cluster runs. Owner has taken this.

## 11. Files touched

| file | change |
|---|---|
| `tracer/pintool/champsim_tracer_mt_roi_v2.cpp` | §5.1-5.5 |
| `tracer/pintool/champsim_tracer_mt_roi_v3.cpp` | §5.1-5.5, plus stale `v2` self-references at `:96-97,103,1756` |
| `tracer/pintool/makefile.rules` | §6.1 zstd include path |
| `tracer/pintool/make_tracer.sh` | §6.2 environment-overridable paths |
| `tools/trace_sanity_check/trace_sanity_check.cpp` | §6.3 self-contained reader; §7.1 checks |
| `tools/trace_sanity_check/Makefile` | §6.3 drop `CHAMPSIM_HOME` |
| `tracer/pintool/README.md`, `tools/README.md`, `CLAUDE.md` | document the contract; correct the v3-only attribution |
