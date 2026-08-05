# Handoff: make v3 traces usable for branch-predictor research

**Repo to change:** `champsim-infra` (this repo), file
`pintool/champsim_tracer_mt_roi_v3.cpp`.
**Consumer:** ChampSim at `/home/rbera/work/bpeval/ChampSim`, branch `rbdev`.
**Status:** analysis complete and empirically confirmed; implementation not started.
**Written:** 2026-08-05

---

## 1. The problem in one paragraph

Traces produced by the v3 pintool are **unusable for branch-predictor evaluation**.
ChampSim never sees a single conditional branch in them, so every direction predictor
is inert and scores identically. The cause is that the tracer deliberately drops the
flags register, and ChampSim *infers* branch type from register-usage patterns — a
conditional branch that reads no flags is indistinguishable from an unconditional
direct jump, and ChampSim then rewrites its direction to "taken".

This is not a subtle accuracy issue. It silently produces confident, wrong numbers.

---

## 2. Evidence

Measured on `/home/rbera/work/bpeval/traces/v2/723.llvm_r-codegen-232B.champsim2.zst`
(a v3-format trace), with `400.perlbench-41B.champsimtrace.xz` as the v1 control.

| Observation | v3 trace | v1 control |
|---|---|---|
| `REG_FLAGS` (25) in source register fields, 5M records | **0** | 853,522 |
| `REG_FLAGS` (25) in destination register fields | **0** | 1,313,249 |
| Instructions ChampSim classifies `BRANCH_DIRECT_JUMP` | 826,732 | 91,700 |
| …of which the trace itself says **taken** | **49.17%** | **100.00%** |

The last row is the proof. A genuine unconditional direct jump is *always* taken; v1
shows exactly 100%. The v3 bucket sits at 49%, so roughly half of what ChampSim calls
"always-taken direct jumps" are actually **not-taken conditional branches**.

Downstream consequence, measured with ChampSim's four stock predictors (10M warmup,
50M simulation):

| Predictor | v3 trace accuracy | v3 trace MPKI |
|---|---|---|
| bimodal | 89.63% | 21.93 |
| gshare | 89.63% | 21.93 |
| perceptron | 89.63% | 21.93 |
| hashed_perceptron | 89.63% | 21.93 |

Byte-identical across four very different predictors — because none of them is ever
consulted. 87% of that MPKI is `BRANCH_DIRECT_JUMP`. The number measures the BTB.

On the v1 control the same four predictors differ properly (bimodal 10.44 MPKI vs
hashed_perceptron 2.535), confirming the harness is fine and the trace is the problem.

---

## 3. Root cause

`pintool/champsim_tracer_mt_roi_v3.cpp`, in `insert_full_analysis()`:

```cpp
// line 1325-1337  (source registers)
for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); i++) {
  REG reg = INS_RegR(ins, i);
  if (REG_valid(reg) && !REG_is_flags(reg) && !REG_is_seg(reg)) {   // <-- flags dropped
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)RecordRegRead, ...);
  }
}

// line 1338-1350  (destination registers)
for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); i++) {
  REG reg = INS_RegW(ins, i);
  if (REG_valid(reg) && !REG_is_flags(reg) && !REG_is_seg(reg)) {   // <-- flags dropped
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)RecordRegWrite, ...);
  }
}
```

The `!REG_is_flags(reg)` filter is why the flags register never reaches the trace.

### Why that breaks ChampSim

ChampSim classifies branches in `inc/instruction.h:154-191` purely from which registers
an instruction reads and writes:

```cpp
if (!reads_sp && !reads_flags && writes_ip && !reads_other)      -> BRANCH_DIRECT_JUMP
else if (!reads_sp && !reads_ip && !reads_flags && writes_ip && reads_other) -> BRANCH_INDIRECT
else if (!reads_sp && reads_ip && !writes_sp && writes_ip && (reads_flags || reads_other))
                                                                 -> BRANCH_CONDITIONAL
... direct call / indirect call / return ...
else if (writes_ip)                                              -> BRANCH_OTHER
```

A conditional branch writes IP and reads IP; with flags stripped it also reads nothing
else, so it matches the **first** arm and becomes `BRANCH_DIRECT_JUMP`. Line 157 then
does `branch_taken = true`, discarding the real direction from the trace.

ChampSim's special register numbers are fixed in `inc/trace_instruction.h:25-27`:
`REG_STACK_POINTER = 6`, `REG_FLAGS = 25`, `REG_INSTRUCTION_POINTER = 26`. These are
Pin `REG` enum values truncated to `unsigned char`.

---

## 4. Goal

Produce v3 traces on which ChampSim classifies branches **correctly and unambiguously**,
so that branch predictors (including the CBP2025 predictors being ported in the ChampSim
repo) can be evaluated.

The preferred solution is to stop inferring branch type at all and record it explicitly,
because inference is fragile: it depends on an x86 register-usage convention leaking
through the tracer, and it has already failed silently once.

---

## 5. The change: record branch type explicitly

### 5.1 There is already space in the record — no size change needed

`trace_instr_v2_t` (line 141-165 of the tracer; mirrored as `input_instr_v2` in
ChampSim's `inc/trace_instruction.h`) is 512 bytes and contains:

```cpp
uint8_t  privilege;
uint8_t  instr_type;
uint8_t  reserved[8];      // offset 120..127 — currently always zero, never written
```

`reserved` is confirmed unwritten (`grep reserved` finds only the declaration and a
comment at line 1290 noting it is left zero). **Use `reserved[0]` as `branch_type`.**
The record stays 512 bytes, so existing readers keep working and old traces remain
parseable — they simply carry `branch_type == 0`.

> Note `0` is a meaningful value in ChampSim's enum (`BRANCH_DIRECT_JUMP`). See §5.4
> for how the consumer distinguishes "old trace" from "genuine direct jump".

### 5.2 Encoding

Use ChampSim's `branch_type` enum verbatim (`inc/instruction.h:34-43`):

| Value | Name |
|---|---|
| 0 | `BRANCH_DIRECT_JUMP` |
| 1 | `BRANCH_INDIRECT` |
| 2 | `BRANCH_CONDITIONAL` |
| 3 | `BRANCH_DIRECT_CALL` |
| 4 | `BRANCH_INDIRECT_CALL` |
| 5 | `BRANCH_RETURN` |
| 6 | `BRANCH_OTHER` |
| 7 | `NOT_BRANCH` |

### 5.3 How to derive it in Pin

Pin can answer this exactly — no inference required. Add a helper next to
`classify_instr()` (which already exists at ~line 1180 and does the analogous job for
`instr_type`), and pass its result through `RecordInstrCommit` the same way `itype` is:

```cpp
static uint8_t classify_branch(INS ins)
{
  if (INS_IsRet(ins))
    return 5;                                     // BRANCH_RETURN
  if (INS_IsCall(ins))
    return INS_IsDirectCall(ins) ? 3 : 4;         // DIRECT_CALL / INDIRECT_CALL
  if (INS_IsBranch(ins)) {
    if (INS_HasFallThrough(ins))
      return 2;                                   // BRANCH_CONDITIONAL
    return INS_IsDirectBranch(ins) ? 0 : 1;       // DIRECT_JUMP / INDIRECT
  }
  if (INS_IsIndirectControlFlow(ins))
    return 1;                                     // e.g. indirect jmp not caught above
  return 7;                                       // NOT_BRANCH
}
```

Verify the exact predicate names against the **PIN 4.0** headers in use
(`PIN_ROOT=/home/rahbera/softwares/pin-external-4.0-99633-g5ca9893f2-gcc-linux`); the
`INS_IsDirectBranch` / `INS_IsDirectCall` spellings have shifted across PIN versions.
`INS_IsBranchOrCall` may be a useful cross-check.

Wire it in exactly like `instr_type`:

- `RecordInstrCommit()` (line ~1277) already takes `UINT8 instr_type`; add a
  `UINT8 branch_type` parameter and store `ts->curr_instr.reserved[0] = branch_type;`.
- The two `INS_InsertCall(..., (AFUNPTR)RecordInstrCommit, ...)` sites (~line 1479 and
  ~line 1492) each pass one more `IARG_UINT32, (UINT32)classify_branch(ins)`.

Argument order must match between the `InsertCall` list and the analysis-routine
signature; Pin does not type-check this.

### 5.4 Marking the record as carrying an explicit type

Because `branch_type == 0` is also a valid value, add a one-byte format flag so the
consumer can tell an updated trace from an old one. Use `reserved[1]`:

```cpp
ts->curr_instr.reserved[0] = branch_type;
ts->curr_instr.reserved[1] = 1;   // TRACE_FEATURE_EXPLICIT_BRANCH_TYPE
```

ChampSim then uses the explicit type when `reserved[1] != 0`, and falls back to the
existing register-based inference otherwise. Old traces keep working unchanged.

### 5.5 Also fix `is_branch` for calls and returns

`is_branch` is currently set from `INS_IsBranch(ins)` alone (line 1477), and Pin's
`INS_IsBranch` **excludes calls and returns**. ChampSim recovers them via inference
today; with explicit types it should not have to.

Set `is_branch = 1` for any control-transfer instruction:

```cpp
UINT8 is_branch = (INS_IsBranch(ins) || INS_IsCall(ins) || INS_IsRet(ins)) ? 1 : 0;
```

Keep `branch_taken` semantics as they are (`IARG_BRANCH_TAKEN`); calls and returns are
unconditionally taken.

> This changes `is_branch` relative to v1 traces. That is intended and is why the
> feature flag in §5.4 matters — but flag the change in the commit message, because any
> tooling that counts branches from `is_branch` will shift.

---

## 6. Should flags be re-added as well?

**Separate decision, and the answer is probably no.** Two competing considerations:

**Against re-adding flags:**
- Register slots are scarce: `NUM_INSTR_DESTINATIONS = 2`, `NUM_INSTR_SOURCES = 4`.
  Nearly every arithmetic x86 instruction writes flags, so re-adding them consumes one
  of the two destination slots almost universally, evicting real register dependencies.
- v3's `RecordRegRead` / `RecordRegWrite` (lines 1231-1257) **silently drop** a register
  when the array is full — they scan for a free slot and return. So the eviction is
  invisible.
- Once branch type is explicit, flags serve no classification purpose.

**For re-adding flags:**
- v1 traces contain them, so dependency modelling (and therefore IPC) is not directly
  comparable between v1 and v3 traces without them.
- ChampSim's `do_stack_pointer_folding()` (`src/ooo_cpu.cc:110-127`) consults
  `REG_FLAGS` when deciding whether a stack-pointer write is foldable.

**Recommendation:** implement §5 first and re-measure. If v1↔v3 IPC parity turns out to
matter for the study, revisit flags as a follow-up, and if you do re-add them, measure
how often a register gets dropped for lack of a slot before and after.

Do **not** treat this as a blocker for §5.

---

## 7. A related bug worth checking (not in this tracer)

ChampSim's own upstream pintool, `ChampSim/tracer/pin/champsim_tracer.cpp:130-136`, has
an out-of-bounds write:

```cpp
auto set_end   = std::find(begin, end, 0);      // == end when the set is full
auto found_reg = std::find(begin, set_end, r);
*found_reg = r;                                 // set full + r absent -> *end = r
```

When an instruction has more than 2 destination or 4 source registers, this writes one
past the array — a third destination register lands in `source_registers[0]`, and a
fifth source register lands in the low byte of `destination_memory[0]`.

**v3 does not have this bug** (it drops instead of overflowing), so nothing to fix here.
It is recorded because the v1 traces were produced with that tool, and the v1 numbers in
§2 come from it. A scan for the signature (`0 < destination_memory[0] < 256`) found
**zero** hits on `400.perlbench`, so those v1 traces appear unaffected in practice —
but re-check if v1 traces are regenerated.

---

## 8. Build, run, and validate

### Build

```bash
cd /home/rbera/work/bpeval/champsim-infra/pintool
bash make_tracer.sh          # needs PIN_ROOT and ZSTD_HOME; see pintool/README.md
# -> obj-intel64/champsim_tracer_mt_roi_v3.so
```

Paths at the top of `make_tracer.sh` point at `/home/rahbera/...` and may need
adjusting on this machine.

### Generate a short trace

Follow `pintool/README.md` (instrument workload with ROI markers, run under PIN). A few
million instructions is plenty to validate — do **not** regenerate the full trace set
until the acceptance checks below pass.

### Acceptance checks

A ready-made checker lives at
`/tmp/claude-1000/-home-rbera-work-bpeval-ChampSim/c4c794da-c8c5-49b6-8270-aecbda83561a/scratchpad/verify_flags.cc`
(scratch, may be gone — it is ~100 lines and trivial to rewrite from this spec). It
reads fixed-stride records from stdin and reports the register histogram plus the
taken-rate of the classifier's first arm. `tools/trace_sanity_check/` in this repo is
the maintained equivalent and is the better place to add these checks permanently.

The new trace must satisfy all of:

1. **Branch type is populated.** `reserved[1] == 1` on every record, and `reserved[0]`
   takes values across 0–7 rather than being constant.
2. **Conditional branches exist and are plausible.** `BRANCH_CONDITIONAL` should be
   roughly 60–85% of all branches for typical integer workloads (v1 perlbench: 76.3%,
   v1 xz: 86.1%).
3. **Direction is preserved.** Among records with `branch_type == BRANCH_CONDITIONAL`,
   the `branch_taken` rate must be strictly between 0 and 1 — around 45–60% typically.
   **This is the check that would have caught the current bug.**
4. **Unconditional branches are all taken.** Among `branch_type` in
   {`DIRECT_JUMP`, `INDIRECT`, `DIRECT_CALL`, `INDIRECT_CALL`, `RETURN`},
   `branch_taken` must be 100%.
5. **Calls and returns are flagged.** With §5.5 applied, every record whose
   `branch_type` is a call or return must have `is_branch == 1`.
6. **Record size unchanged.** `sizeof(trace_instr_v2_t) == 512`; the existing
   `static_assert` at line 164 enforces this — do not let it be relaxed.

### End-to-end check in ChampSim

The decisive test is that different predictors produce *different* results:

```bash
cd /home/rbera/work/bpeval/ChampSim     # branch rbdev
./config.sh <config selecting bimodal>            && make -j24
./config.sh <config selecting hashed_perceptron>  && make -j24
./bin/<exe> --trace-version 2 -w 10000000 -i 50000000 <new-trace>
```

`bimodal` and `hashed_perceptron` must report **clearly different** MPKI. If they match
to four significant figures, the direction predictor is still not being consulted.

---

## 9. What the ChampSim side will do (not your task)

For coordination only — the ChampSim repo is being changed in parallel on branch `rbdev`:

- `inc/trace_instruction.h` already defines `input_instr_v2` with the same 512-byte
  layout including `reserved[8]`.
- `ooo_model_instr`'s constructor (`inc/instruction.h:132-192`) will be taught to use
  the explicit `branch_type` when `reserved[1] != 0`, and keep the existing inference
  otherwise.
- ChampSim already reads `.zst` v2/v3 traces via `--trace-version 2`.

**The contract you must hold to** is exactly §5.2 (enum values), §5.4 (feature flag in
`reserved[1]`), and §6 (record stays 512 bytes). Anything else is your call.

---

## 10. Summary of edits

| File | Change |
|---|---|
| `pintool/champsim_tracer_mt_roi_v3.cpp` ~1180 | add `classify_branch(INS)` helper (§5.3) |
| same, ~1277 | `RecordInstrCommit()` takes `branch_type`; writes `reserved[0]`, `reserved[1] = 1` |
| same, ~1477 | `is_branch` includes calls and returns (§5.5) |
| same, ~1479 & ~1492 | both `InsertCall` sites pass the new argument |
| `tools/trace_sanity_check/` | add acceptance checks 1–5 from §8 |
| `pintool/README.md` | document `reserved[0..1]`, and that branch type is now explicit |

Do **not** change: the 512-byte record size, the `NUM_INSTR_*` constants, or the
existing `instr_type` / `privilege` fields.

## 11. One open question for the requester

`privilege` is hardcoded to `0` at line 1288 with the comment "PIN is user-mode", so the
field currently carries no information. If kernel/user distinction is wanted later, that
is a separate change and probably needs a different tracing approach.
