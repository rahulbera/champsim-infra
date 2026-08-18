# Explicit branch type in ChampSim traces — contract, x86-64 implementation, and status

**Scope of this document.** Everything about how this toolkit tells ChampSim what
kind of branch each instruction is: why the old approach was unsound, what the
on-disk contract is, exactly what the x86-64 decoder emits for every instruction
class, how it was verified, and what is still missing on AArch64.

| flow | explicit branch type | flags register | unit-tested | verified end to end |
|---|---|---|---|---|
| **x86-64** (Zydis backend) | ✅ emitted | ✅ recorded | ✅ 30/30 rows, all branch forms | ✅ 30 M-instruction capture + ChampSim |
| **AArch64** (Capstone backend) | ⚠️ emitted, **unverified** | ⚠️ unverified | ⚠️ 14/14 rows, **6 of 10 branch forms** | ❌ none |

> **AArch64 has not received this work.** `raw2champsim.c` writes the
> `reserved[0..2]` bytes for *both* backends, so an AArch64 trace already
> *claims* `TRACE_FEATURE_EXPLICIT_BRANCH_TYPE` and ChampSim will *believe* it.
>
> To be fair to that backend: reading it, it is **structurally immune to all
> three x86 defects**, and already gets right the one case (GPR-testing
> conditionals) where x86 was fabricating a dependency. The gap is
> **verification, not suspected breakage** — no AArch64 capture has ever been
> checked, and four branch forms including unconditional `B` are untested.
> See §10.

Companion documents:

* `../../ChampSim/docs/handoff-v2-explicit-branch-type-traces.md` — the consumer
  side of the same contract.
* `converter/README.md` — record layout, register schemes, backend split.
* `plugin/README.md` — capture knobs.

---

## 1. Why an explicit branch type at all

ChampSim historically did not record branch type in the trace. It **inferred**
it, in `inc/instruction.h`, from which registers a record touches:

```
conditional    : reads_ip && !writes_sp && writes_ip && (reads_flags || reads_other)
direct call    : reads_sp && reads_ip && writes_sp && writes_ip && !reads_flags && !reads_other
indirect call  : reads_sp && reads_ip && writes_sp && writes_ip && !reads_flags && reads_other
indirect jump  : !reads_sp && !reads_ip && !reads_flags && writes_ip && reads_other
return         : reads_sp && !reads_ip && writes_sp && writes_ip
direct jump    : !reads_sp && !reads_flags && writes_ip && !reads_other
```

This is a heuristic over a lossy projection. It is correct only if the producer
populates register slots in exactly the shape the cascade expects, which makes
the *tracer's register-synthesis policy* — not the architecture — the thing that
decides branch type. Three consequences:

1. **A tracer bug becomes a silent semantic error.** If the decoder injects
   FLAGS into an unconditional jump, that jump *becomes* a conditional branch as
   far as every predictor is concerned. Nothing downstream can tell.
2. **Some classes are genuinely unreachable by inference.** `iretq` reads SP and
   writes IP without reading IP — byte-identical, in register terms, to a
   return. No shape-based rule can separate them.
3. **The trace cannot be self-describing.** A consumer has no way to ask "were
   these types measured, or reconstructed?"

The fix is to have the decoder — which already knows the answer exactly, having
just decoded the instruction — simply state it.

### Why not a new trace version?

Deliberately **no `--trace-version` bump.** A version number is *asserted by
whoever names the file*, and can be wrong in a way the bytes cannot contradict.
A feature bit inside each record is *self-describing by the data*. The 512-byte
layout is unchanged and previously-unused reserved bytes are used, so:

* old consumers read the same zeroes they always read;
* new consumers test a bit and know, per record, whether to trust it.

---

## 2. The on-disk contract

Three of the v2 record's eight reserved bytes carry meaning. These mirror
`champsim::TRACE_RESERVED_*` / `TRACE_FEATURE_*` in ChampSim's
`inc/trace_instruction.h`, and are defined identically in
`converter/raw2champsim.c`.

| byte | name | meaning |
|------|------|---------|
| `reserved[0]` | `TRACE_RESERVED_BRANCH_TYPE` | ChampSim's `branch_type` enum **verbatim, 0-based** |
| `reserved[1]` | `TRACE_RESERVED_FEATURES` | feature bitmask (below) |
| `reserved[2]` | `TRACE_RESERVED_TRACER_ID` | which tool produced this record |

Feature bits (`reserved[1]`):

| bit | name | meaning |
|-----|------|---------|
| `0x01` | `TRACE_FEATURE_EXPLICIT_BRANCH_TYPE` | `reserved[0]` is authoritative |
| `0x02` | `TRACE_FEATURE_FLAGS_REGISTER` | the flags register is recorded on both producer and consumer sides |

Tracer identities (`reserved[2]`):

| value | tool |
|-------|------|
| `2` | champsim-infra pintool, v2 |
| `3` | champsim-infra pintool, v3 |
| **`4`** | **this QEMU raw→ChampSim converter** |

Branch type values (`reserved[0]`) — ChampSim's enum:

| value | name |
|-------|------|
| 0 | `BRANCH_DIRECT_JUMP` |
| 1 | `BRANCH_INDIRECT` |
| 2 | `BRANCH_CONDITIONAL` |
| 3 | `BRANCH_DIRECT_CALL` |
| 4 | `BRANCH_INDIRECT_CALL` |
| 5 | `BRANCH_RETURN` |
| 6 | `BRANCH_OTHER` |
| 7 | `NOT_BRANCH` |

### Three rules consumers must follow

1. **Key off the feature bit, never off `reserved[0] != 0`.**
   `BRANCH_DIRECT_JUMP` is `0`. A record with all-zero reserved bytes is
   byte-identical to one describing a direct jump, so "non-zero" cannot mean
   "present".

2. **The bit is per-record.** The converter sets it on *every* record including
   decode failures, precisely so a consumer testing it per record never silently
   falls back to inference for a subset of the stream. If you see the bit clear
   on any record, that record is not covered.

3. **`NOT_BRANCH` is `7`, not `0`.** The internal decoder API uses a *1-based*
   code where `0` means "not a branch" (`decoded_regs_t::is_branch`); the
   converter subtracts 1 when writing `reserved[0]`. Do not confuse the two.

### `is_branch` is a boolean

The record's `is_branch` field is `0`/`1`. It previously received the decoder's
1..7 type code — harmless where consumers test truthiness, wrong for any
consumer testing `== 1`. The type now travels in `reserved[0]` and `is_branch`
is narrowed to a genuine boolean.

---

## 3. What was wrong in the x86-64 decoder

Three independent defects in `converter/decode_x86.c`. All three produced
**structurally perfect records of the wrong instruction class** — well-formed,
self-consistent, and semantically wrong. This is the recurring theme of the
whole effort: no self-consistency check found any of them; every one was found
by differential testing against an independent oracle.

### 3.1 An alphabetically-ordered enum used as an opcode range

```c
/* WRONG */
if (mnem >= ZYDIS_MNEMONIC_JB && mnem <= ZYDIS_MNEMONIC_JS)
    return BRANCH_CONDITIONAL;
```

`ZydisMnemonic` is ordered **alphabetically**, not by opcode family:

```
… JB, JBE, JCXZ, JECXZ, JKNZD, JKZD, JL, JLE, JMP, JNB, JNBE, … JS, JZ …
                                              ^^^                    ^^
                                         inside the range      outside the range
```

* **`JMP` sorts inside `[JB, JS]`.** Every unconditional jump was classified
  `CONDITIONAL`, and then had FLAGS force-injected as a source by the
  "conditional branches need FLAGS" step — making it indistinguishable from a
  real conditional branch. The dedicated `if (mnem == ZYDIS_MNEMONIC_JMP)` block
  further down the function was dead code.
* **`JZ` sorts after `JS`.** `je`/`jz` — the single most common conditional
  branch in x86 — fell outside the range entirely and was classified
  `BRANCH_OTHER`.

A predictor fed such a trace sees unconditional jumps as conditionals pinned at
100% taken, and never sees the most common real conditional at all.

**Fixed** by enumerating the Jcc forms explicitly. Zydis normalises the aliases
(`JA`→`JNBE`, `JAE`→`JNB`, `JE`→`JZ`, `JNE`→`JNZ`, `JG`→`JNLE`, `JGE`→`JNL`,
`JNA`→`JBE`, `JNAE`→`JB`, `JNG`→`JLE`, `JNGE`→`JL`), so the explicit list is
complete for x86-64.

### 3.2 Encoding form mistaken for addressing form

```c
/* WRONG */
if (insn->meta.branch_type == ZYDIS_BRANCH_TYPE_SHORT ||
    insn->meta.branch_type == ZYDIS_BRANCH_TYPE_NEAR)
    return BRANCH_DIRECT_CALL;   /* "will refine below" — there was no below */
```

`SHORT`/`NEAR`/`FAR` describe the **displacement encoding and segment**, not
whether the target is an immediate. `jmp *%rax` and `call *%rax` are both
`NEAR`, so `BRANCH_INDIRECT` and `BRANCH_INDIRECT_CALL` were unreachable for the
common register and memory forms. The indirect-jump and indirect-call predictors
never saw a single one, and the return-address stack saw calls it should not
have.

**Fixed** by deciding on the target operand: a direct branch has an
`ZYDIS_OPERAND_TYPE_IMMEDIATE` target; register and memory targets are indirect.

### 3.3 Register slots silently evicted, and a fabricated dependency

The record has only **4 source and 2 destination slots**, so appending a
register already present does not merely duplicate — it **evicts a real
operand**. Duplicates arose naturally:

* Zydis reports RSP as an explicit operand of `CALL`/`RET` *and* as the base of
  the implicit `[rsp]` memory operand;
* Zydis reports RIP as written by a branch, and the synthesis step appended it
  again — conditional branches were emitting `destination_registers = {26, 26}`,
  consuming both destination slots with the same register.

**Fixed** with a de-duplicating `add_reg()` used by every append path.

Separately, FLAGS was injected as a source on *every* branch classified
conditional — including `JCXZ`/`JECXZ`/`JRCXZ`/`LOOP`, which branch on RCX and
read no flags whatsoever. That **fabricated a `cmp → jcc` dependency edge the
hardware does not have** — exactly the edge a register-value-based predictor
would then "learn" from. `LOOPE`/`LOOPNE` genuinely do read ZF and keep the
injection.

---

## 4. Classification reference (x86-64)

What `decode_x86.c` emits today, verified row by row by
`converter/tests/decode_x86_test.c` against real `as --64` + `objdump -d`
encodings. Register IDs: `6`=RSP, `25`=FLAGS, `26`=RIP.

| instruction | type | FLAGS src | IP src | notes |
|---|---|---|---|---|
| `je jne ja jbe jg jl js jp jo` (all Jcc) | CONDITIONAL | ✅ | ✅ | |
| `jrcxz` `jecxz` `jcxz` | CONDITIONAL | ❌ | ✅ | branches on RCX; **no** FLAGS |
| `loop` | CONDITIONAL | ❌ | ✅ | decrements RCX; **no** FLAGS |
| `loope` `loopne` | CONDITIONAL | ✅ | ✅ | also reads ZF |
| `jmp rel8/rel32` | DIRECT_JUMP | ❌ | (present) | Zydis reports RIP as read of an IP-relative target |
| `jmp *%rax` / `jmp *(%rax)` | INDIRECT | ❌ | ❌ | IP **must** be absent |
| `call rel32` | DIRECT_CALL | ❌ | ✅ | RSP read+written |
| `call *%rax` / `call *(%rax)` | INDIRECT_CALL | ❌ | ✅ | RSP read+written |
| `ret` / `ret $8` / `lretq` | RETURN | ❌ | ❌ | IP **must** be absent |
| `syscall` `int3` `int $n` `iretq` | NOT_BRANCH | — | — | see below |
| `cmp` `add` (arithmetic) | NOT_BRANCH | — | ❌ | **write** FLAGS (dst) |

### IP-source policy

IP is synthesised as a source for **conditionals and calls only** (types 2/3/4).
This exists so the *inference fallback* still agrees with the explicit type if
the feature bit is ever lost: the cascade distinguishes indirect jumps and
returns partly by IP being **absent**, so synthesising it there would break
them. IP is appended **last**, so under source-slot pressure it is dropped
before FLAGS — which carries the real `cmp → jcc` dependency edge.

Direct jumps are a don't-care rather than a withhold: Zydis already reports RIP
as a read operand of a rel-encoded jump. Harmless — with neither FLAGS nor
another source it cannot be mistaken for a conditional, and the cascade still
lands on direct jump.

### Traps and system transfers

`syscall`, `int3`, `int $n`, `iretq` classify **NOT_BRANCH**, because Zydis
reports `meta.branch_type == NONE` for them. This is deliberate and matches the
champsim-infra pintool (PIN's `INS_IsBranch` is false for syscall/int), so the
two tracers agree.

**`iretq` is the interesting one.** It reads SP and writes IP without reading IP
— precisely ChampSim's inference signature for a `RETURN`. Under the
inference-only path, every `iretq` in a kernel trace silently pushed a bogus pop
onto the return-address stack. Declaring it `NOT_BRANCH` is strictly better than
inferring a return that no call ever pushed. §9 quantifies this.

---

## 5. Branch direction (`branch_taken`)

**Direction is only a question for conditional branches.** Every other control
transfer is taken by definition.

The converter has no direction signal from QEMU — the plugin API exposes none —
so it derives direction from a one-record lookahead:

```
taken  ==  next_ip != ip + instr_size
```

That is the right rule for a conditional and the **wrong rule for everything
else**, because the geometry is not always faithful to the semantics:

> `jmp .+0` (`e9 00 00 00 00`) targets its own fall-through address. The Linux
> kernel leaves these behind after alternatives / return-thunk patching. One
> appeared in an 8 M-instruction capture and failed the "unconditional transfers
> are 100% taken" acceptance check at 610707 of 610708.

A not-taken direct jump is not a thing; neither is a not-taken call or return.
And once `reserved[0]` is trusted, such a record is indistinguishable downstream
from a genuinely not-taken branch. So **the type decides**, and the lookahead
only settles the cases that are genuinely unknown:

| type | direction |
|---|---|
| DIRECT_JUMP, INDIRECT, DIRECT_CALL, INDIRECT_CALL, RETURN | always `1` |
| CONDITIONAL, OTHER | lookahead |

### End of file / end of chunk

The final record has no successor. Unconditional transfers are marked taken (the
same rule as above); a trailing **conditional** is genuinely unknowable and is
**dropped**, with a note on stderr, rather than guessed — a fabricated direction
is indistinguishable from a real one downstream. One instruction per file is a
rounding error; a silently wrong one is not. With `rotate=N` this boundary
recurs once per chunk.

---

## 6. Toolchain

### QEMU — 9.2.4 specifically

| | |
|---|---|
| Version | **9.2.4** |
| Source | `~/work/softwares/qemu-9.2.4/` |
| Install prefix | `~/qemu-custom/` |
| Binary | `~/qemu-custom/bin/qemu-system-x86_64` |
| Plugin API | v4 |

The plugin uses `qemu_plugin_mem_get_value()`, which **first appears in QEMU
9.1** and `g_assert_not_reached()`s (a hard VM abort) on accesses wider than
U128 in 9.2 — hence `VALUE_API_CAP = 16`. Do not assume a distro QEMU works;
most ship without `--enable-plugins` at all.

```bash
cd ~/work/softwares/qemu-9.2.4
./configure --prefix=$HOME/qemu-custom --enable-plugins --enable-kvm \
            --target-list=x86_64-softmmu,x86_64-linux-user,aarch64-softmmu,aarch64-linux-user
make -j$(nproc) && make install
```

**The plugin requires system-emulation mode.** It refuses to load under
`qemu-x86_64` (linux-user) with "requires system emulation mode" — capture must
go through `qemu-system-x86_64`.

### Host packages

```bash
sudo apt install libglib2.0-dev libpixman-1-dev libslirp-dev \
                 libzstd-dev libcapstone-dev busybox-static cpio
```

Zydis is fetched and built automatically by `converter/Makefile`.

`libcapstone-dev` is required for the **x86** flow even though x86 decoding uses
Zydis, because `raw2champsim` links the AArch64 backend unconditionally. Making
that backend optional would drop the dependency.

### Two conda traps on this host

Both produce failures that look like something else entirely:

* **`CC` resolves to `aarch64-conda-linux-gnu-cc`.** A plain `make` builds the
  plugin with a cross-compiler for the wrong architecture, and fails with
  `zstd.h: No such file or directory` — because the cross-compiler has its own
  sysroot, not because zstd is missing. **Always build with `make CC=gcc`.**
* **conda's glib is unusable here.** Its `glibconfig.h` is aarch64-targeted and
  mismatches `sizeof(size_t)`. The system `libglib2.0-dev` is required.

---

## 7. Running the flow

```bash
make -C plugin plugin CC=gcc      # note CC=gcc
make -C converter CC=gcc
scripts/smoke-trace/smoke_trace.sh
```

`scripts/smoke-trace/` boots a throwaway kernel + busybox initramfs running a
branchy static workload, captures with `trigger=`, converts, and runs the
acceptance checks — a couple of minutes end to end. It exists to answer "is the
pipeline still correct?", not to produce research traces; `scripts/capture-kit/`
drives full VM disk images for that.

Manual capture:

```bash
~/qemu-custom/bin/qemu-system-x86_64 -accel tcg -cpu qemu64 -smp 1 -m 1G \
  -kernel <bzImage> -initrd <initramfs> -append "console=ttyS0 quiet" \
  -nographic -no-reboot \
  -plugin ~/…/champsim_tracer.so,outdir=DIR,vcpus=0,limit=30000000,trigger=/tmp/go
# …then, once the guest is inside the workload:
touch /tmp/go

raw2champsim DIR/trace_vcpu0.raw.zst out.champsim2.zst
```

### Always skip boot

Tracing from power-on captures BIOS and early kernel boot, which execute in 16-
and 32-bit modes while the decoder is initialised for 64-bit long mode. Tracing
the first 20 M instructions of a boot yields **1,163,614 decode failures
(5.8%)** for exactly this reason. Tracing the workload instead yields **zero**.
Use `trigger=`.

### The trigger's one sharp edge

**The plugin polls for the trigger file only while instructions are retiring.**
If the guest finishes its workload before you arm the trigger, the polls simply
stop and the run ends with `Trigger was never activated` — a symptom identical
to a wrong path or a permission error.

This is not hypothetical. A guest that boots and runs a 40 M-iteration workload
completes in **~12 s of wall time**, so a driver that waits for the workload's
banner and then sleeps 5 s can easily arm the trigger *after* QEMU has exited.
The fix is to size the guest workload so it is still running — not to change the
trigger.

Build the plugin with **`-DTRIGGER_DEBUG`** to log every poll with a timestamp,
call number and `errno`. Comparing the last poll's timestamp against your
`touch` settles the question immediately. Compiled out by default.

---

## 8. Verification methodology

Every defect in this effort produced output that was structurally valid and
semantically wrong. Self-consistency checks caught **none** of them.
Differential tests against an independent oracle caught **all** of them. The
verification is built on that principle.

### Layer 1 — golden unit tests (oracle: the ISA)

`converter/tests/decode_x86_test.c`, run by `make -C converter decode_x86_test`.

30 rows, every byte sequence real `as --64` + `objdump -d` output rather than
hand-guessed. Expectations are **the x86-64 architecture, not current
behaviour** — the table is an oracle, so a failing row means fix the decoder,
not the table. Beyond per-row type/FLAGS/IP expectations, four invariants apply
to every row:

* decode succeeds;
* no duplicate register in either list (a repeat evicts a slot);
* every branch writes IP;
* the classes whose inference fallback requires an absent IP source
  (indirect jump, return) do not carry one.

The AArch64 golden test (`make -C converter decode_test`, 14 rows) is kept
passing as a regression guard.

### Layer 2 — synthetic raw→ChampSim conversion

Builds a raw v3 trace from real encodings where each branch's direction is known
by construction, runs the converter, and asserts the emitted records: type,
direction, feature bits, tracer id, and the specific `cmp` writes FLAGS → `jcc`
reads FLAGS dependency edge that motivated the work.

### Layer 3 — real emulated execution

A 30 M-instruction capture of actual guest execution, checked in full by
`trace_sanity_check --check` (champsim-infra).

### Layer 4 — the consumer

Run under ChampSim with four predictors, plus an explicit-vs-inferred
differential (§9).

---

## 9. Verification results

### Unit tests

| test | result |
|---|---|
| x86-64 golden table, 30 real encodings | **30/30** |
| AArch64 golden table (regression guard) | **14/14** |
| synthetic raw→ChampSim assertions | **ALL PASS** |

### 30 M instructions of real emulated execution

Captured with `trigger=` after skipping 3.99 B instructions of boot:

```
Total instructions:  30,000,000     Decode failures: 0
User mode:           95.2%          Kernel mode:     4.8%
Branches:            4,475,638 (14.9%)
Mem instructions:    4,758,974 (15.9%)
```

| branch type | count | share of branches | taken |
|---|---|---|---|
| DIRECT_JUMP | 141,874 | 3.17% | 100.00% |
| CONDITIONAL | 2,185,488 | 48.83% | **43.04%** |
| DIRECT_CALL | 45,530 | 1.02% | 100.00% |
| INDIRECT_CALL | 1,028,704 | 22.98% | 100.00% |
| RETURN | 1,074,042 | 24.00% | 100.00% |

All six acceptance checks pass over all 30 M records:

```
[PASS] explicit branch type on every record       30000000 of 30000000
[PASS] branch type spans multiple values          6 distinct values
[PASS] conditional taken rate strictly in (0,100) 43.04% taken
[PASS] unconditional transfers are 100% taken     2290150 of 2290150
[PASS] calls and returns have is_branch=1         0 violations
[PASS] flags register present on both sides       src 13.84%, dst 41.87%
```

Two of these are load-bearing:

* **Conditionals at 43.04% taken** — strictly inside (0,100). The original PIN
  bug surfaced as a direct-jump class sitting at 49.17% taken; a class pinned at
  0% or 100% means direction is being fabricated.
* **Calls (1.02% + 22.98% = 24.00%) exactly balance returns (24.00%)** — a
  structural invariant that cannot hold by accident.

The high indirect-call share is the workload (a function-pointer table), not a
defect; it also depresses the conditional share below the 60–85% typical of
integer workloads.

### Consumed by ChampSim

```
champsim_bimodal             73.95%   MPKI 38.86
champsim_gshare              73.93%   MPKI 38.89
champsim_hashed_perceptron   76.86%   MPKI 34.53
cbp_tagescl64                76.89%   MPKI 34.48
```

Predictors differentiate in the expected order. Run with `--trace-version 2`.

### Explicit vs inferred — does the contract do anything?

The same 4 M-record slice was run twice, the second with `reserved[1]` zeroed to
force ChampSim back onto inference. ChampSim emits its *"carries no explicit
branch type"* warning on the stripped slice **only**, confirming the feature bit
is detected and consumed.

Replaying ChampSim's own cascade over 6 M records, the two channels disagree on
**75 records — all of them `NOT_BRANCH` inferred as `RETURN`**. These are the
kernel's `iretq` (§4). Each pushed a bogus pop onto the return-address stack:

```
return MPKI:   0.1017 (explicit)   vs   0.119 (inferred)     ~17% worse
```

**Stated plainly:** on this workload the *large* corrections come from the
decoder fixes in §3, which repair the register shapes inference reads — so both
channels improved together. The `reserved[0]` channel's distinct contributions
are (a) making the type authoritative rather than reconstructed, so a future
register-synthesis change cannot silently alter branch semantics, and (b)
eliminating the `iretq` case, which no shape-based heuristic can get right.

---

## 10. AArch64 — what is missing

**Deliberately out of scope for this work, and not safe to assume correct.**

### What already applies

The `reserved[0..2]` writes live in `raw2champsim.c`, which is
architecture-agnostic — it writes them from whatever `decoded_regs_t::is_branch`
the selected backend returned. So an AArch64 trace produced today **already
claims** `TRACE_FEATURE_EXPLICIT_BRANCH_TYPE | TRACE_FEATURE_FLAGS_REGISTER`,
and ChampSim will trust `reserved[0]` accordingly.

The §5 direction rules are also arch-agnostic and already apply.

### What is already sound

Reading `decode_aarch64.c`, the A64 backend is **structurally immune to all
three x86 defects**, and was already more precise than x86 on one of them. None
of this is luck — A64 is simply a more regular target:

| x86 defect (§3) | A64 status |
|---|---|
| alphabetical enum used as a range (§3.1) | **N/A** — `classify_arm64_branch()` is an explicit `switch` on instruction ID |
| encoding form mistaken for addressing form (§3.2) | **N/A** — direct vs indirect is intrinsic to the mnemonic (`B`/`BL` vs `BR`/`BLR`) |
| duplicate registers evicting slots (§3.3) | **already handled** — `add_src()`/`add_dst()` de-duplicate, exactly like the `add_reg()` this work added to x86 |
| FLAGS fabricated on GPR-testing conditionals (§3.3) | **already correct** — FLAGS is added only for `B.cond`; `CBZ`/`CBNZ`/`TBZ`/`TBNZ` test a GPR and carry no FLAGS source |

That last row is worth emphasising: the A64 backend got right, from the start,
the precise case (`jcxz`/`loop`) where the x86 backend was fabricating a
dependency edge.

### What is genuinely unverified

**1. Test coverage is partial.** `tests/decode_aarch64_test.c` (14 rows) covers
`RET`, `BL`, `BLR`, `BR`, `B.eq`, `CBZ` — but **not** unconditional `B`,
`CBNZ`, `TBZ`/`TBNZ`, or `ERET`.

The missing `B` row matters most, because it is the one classification that does
**not** come from the opcode:

```c
case ARM64_INS_B:
  return (insn->detail->arm64.cc == ARM64_CC_AL ||
          insn->detail->arm64.cc == ARM64_CC_INVALID) ? 1 : 3;
```

`B` and `B.cond` share an instruction ID and are separated by a Capstone
**metadata field**. That is the same *class* of dependency as the x86 bugs — a
classification resting on a library's interpretation rather than on the
instruction itself. If a Capstone version reported `cc` differently for
unconditional `B`, every unconditional branch would silently become
`CONDITIONAL` — precisely the x86 `JMP` failure (§3.1), reached by a different
road, and nothing currently tests for it.

**2. No end-to-end AArch64 capture has been validated.** The x86 claims rest on
30 M instructions of real emulated execution checked by `trace_sanity_check
--check` (§9). Nothing equivalent has been run for A64, so the branch *mix* and
the taken rates — the checks that actually catch a misclassification in
aggregate — are unmeasured.

**3. `ERET` and `iretq` are handled differently.** A64 classifies `ERET` (and
`SVC`/`HVC`/`SMC`/`BRK`/`HLT`/`DCPS`/`DRPS`) as `BRANCH_OTHER`; x86 classifies
`iretq` as `NOT_BRANCH` (§4). Both deliberately keep these out of
`BRANCH_RETURN` to avoid polluting the return-address stack, so **neither is
wrong and the intent is identical** — but a cross-arch consumer sees two
spellings of the same decision. Worth reconciling for consistency, not a
correctness bug.

### What to do

The specific Zydis bugs do **not** transfer, and the structural ones cannot. The
work is verification, not repair:

1. Extend `converter/tests/decode_aarch64_test.c` to cover unconditional `B`,
   `CBNZ`, `TBZ`/`TBNZ` and `ERET`, using real `aarch64-linux-gnu-as` encodings,
   and assert the same four per-row invariants the x86 table does (§8). The
   unconditional-`B` row is the highest-value single addition in this document.
2. Capture on an AArch64 guest (`scripts/capture-kit/`) and run
   `trace_sanity_check --check` over the converted trace. The conditional taken
   rate landing strictly inside (0,100) is the single most load-bearing check;
   calls balancing returns is the second.
3. Run the explicit-vs-inferred differential (§9) to see which classes the two
   channels disagree on. On x86 this surfaced the `iretq` case in one pass.
4. Optionally reconcile `ERET` with the `iretq` decision.

Until steps 1–2 are done, treat the feature bits on an AArch64 trace as **a
claim, not a guarantee** — not because the backend looks wrong, but because
nothing has confirmed it right.

---

## 11. Known limitations (x86-64)

* **Decode failures assert `NOT_BRANCH`** with the feature bit still set. No
  information is lost in practice (a record with no registers also infers to
  not-a-branch), but it is an assertion rather than an admission of ignorance.
  Zero on 64-bit user code; see §7 for 16/32-bit boot code.
* **Conditional direction can be wrong across an interrupt.** The lookahead sees
  the handler's IP as "not the fall-through", so a not-taken conditional
  interrupted immediately after retiring is recorded as taken. Inherent to the
  raw format — QEMU exposes no direction — and it applies to any system-mode
  capture with timer interrupts (4.8% of the reference trace is kernel).
* **One record per file/chunk boundary** is dropped when it is a trailing
  conditional (§5).
* **ChampSim's BTB warns** `target of return is a lower address than the
  corresponding call`. Expected for a capture that starts mid-execution (early
  returns have no matching call) and interleaves kernel entry/exit.
* **The x86 build requires capstone** purely because the AArch64 backend is
  linked unconditionally (§6).
* **`memop overflow`** — instructions with more memory operands than the record
  has slots are counted and reported (1,110 in 30 M). Pre-existing behaviour,
  unchanged by this work.
