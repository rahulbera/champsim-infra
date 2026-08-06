# x86-64 flow: explicit branch type — status

**Status:** x86-64 path is fixed, tested, and validated end to end against the
current ChampSim. AArch64 is untouched and deferred.

This toolkit had the same defect as the PIN tracer in `champsim-infra`: the
traces it produced were structurally perfect and semantically wrong for branch
prediction research. The x86 half is now correct and states its branch types
explicitly instead of leaving the consumer to reconstruct them.

Related: `../../ChampSim/docs/handoff-v2-explicit-branch-type-traces.md`
describes the consumer side of the same contract.

---

## 1. What was wrong

Three independent defects in `converter/decode_x86.c`, all of which produced
well-formed records of the wrong instruction class. No self-consistency check
could have caught them; all three were found by differential testing against
real assembler output.

### 1.1 An alphabetically-ordered enum used as an opcode range

```c
if (mnem >= ZYDIS_MNEMONIC_JB && mnem <= ZYDIS_MNEMONIC_JS)
    return BRANCH_CONDITIONAL;
```

`ZydisMnemonic` is ordered **alphabetically**, not by opcode family:

```
JB, JBE, JCXZ, JECXZ, JKNZD, JKZD, JL, JLE, JMP, JNB, ..., JS, JZ
                                        ^^^                    ^^
                                   inside the range      outside the range
```

* `JMP` sorts **inside** `[JB, JS]`, so every unconditional jump was reported
  `CONDITIONAL` — and then had FLAGS force-injected as a source, making it
  indistinguishable from a real conditional branch. The dedicated `JMP` block
  further down the function was dead code.
* `JZ` sorts **after** `JS`, so `je`/`jz` — the most common conditional branch
  in x86 — fell outside the range entirely and was reported `OTHER`.

A predictor fed this trace sees unconditional jumps as conditionals with a 100%
taken rate, and never sees the most common real conditional at all.

### 1.2 Encoding form mistaken for addressing form

```c
if (insn->meta.branch_type == ZYDIS_BRANCH_TYPE_SHORT ||
    insn->meta.branch_type == ZYDIS_BRANCH_TYPE_NEAR)
    return BRANCH_DIRECT_CALL;   /* "will refine below" — there was no below */
```

`SHORT`/`NEAR`/`FAR` describe the **displacement encoding and segment**, not
whether the target is an immediate. `jmp *%rax` and `call *%rax` are both
`NEAR`, so the indirect classes were unreachable for the common register and
memory forms. The indirect-jump and indirect-call predictors never saw a single
one.

Direct vs indirect is now decided by the target operand actually being
`ZYDIS_OPERAND_TYPE_IMMEDIATE`.

### 1.3 Register slots silently evicted, and a fabricated dependency

The record has only 4 source and 2 destination slots, so appending a register
that is already present **evicts a real operand**. Zydis reports RSP as both an
explicit operand of `CALL`/`RET` and as the base of the implicit `[rsp]` memory
operand, and reports RIP as written by a branch before the synthesis step
appended it again — conditional branches were emitting
`destination_registers = {26, 26}`. All appends now go through a de-duplicating
`add_reg()`.

Separately, FLAGS was injected as a source on *every* branch classified
conditional, including `JCXZ`/`JECXZ`/`JRCXZ`/`LOOP`, which branch on RCX and
read no flags at all. That fabricated a `cmp → jcc` dependency edge the hardware
does not have — precisely the edge a register-value-based predictor would then
"learn". `LOOPE`/`LOOPNE` genuinely do read ZF and keep the injection.

---

## 2. The contract: `reserved[0..2]`

Rather than have ChampSim keep inferring branch type from register shape, the
converter now states it. This mirrors `champsim::TRACE_RESERVED_*` /
`TRACE_FEATURE_*` in ChampSim's `inc/trace_instruction.h`.

| byte | meaning |
|------|---------|
| `reserved[0]` | branch type, ChampSim's 0-based enum verbatim (`7` = NOT_BRANCH) |
| `reserved[1]` | feature bits: `0x01` explicit branch type, `0x02` flags recorded |
| `reserved[2]` | tracer identity: `2`/`3` = pintools, **`4` = this QEMU converter** |

The 512-byte layout is unchanged. A consumer predating the contract sees the
same zeroes it always saw.

**Presence is announced by the feature bit, never by `reserved[0] != 0`.**
`BRANCH_DIRECT_JUMP` is `0`, so a zeroed record is byte-identical to one
describing a direct jump. There is deliberately **no trace-version bump**: a
version is asserted by whoever names the file, whereas a feature bit is
self-describing by the data.

`is_branch` is now narrowed to 0/1. It is a boolean in the record format, but
was being assigned the decoder's 1..7 type code.

---

## 3. Toolchain

### QEMU — 9.2.4 specifically

The plugin uses `qemu_plugin_mem_get_value()`, which **first appears in QEMU
9.1** and asserts on accesses wider than U128 in 9.2 (`plugins/api.c`). It is
built against plugin API v4. Do not assume a distro QEMU will work — most ship
without `--enable-plugins` at all.

| | |
|---|---|
| Version | **9.2.4** |
| Source | `~/work/softwares/qemu-9.2.4/` |
| Install prefix | `~/qemu-custom/` |
| Binary | `~/qemu-custom/bin/qemu-system-x86_64` |

> The path in `CLAUDE.md` (`~/softwares/qemu-9.2.4/`) is stale; the tree is
> under `~/work/softwares/`.

Built with:

```bash
cd ~/work/softwares/qemu-9.2.4
./configure --prefix=$HOME/qemu-custom --enable-plugins --enable-kvm \
            --target-list=x86_64-softmmu,x86_64-linux-user,aarch64-softmmu,aarch64-linux-user
make -j$(nproc) && make install
```

**The plugin requires system-emulation mode.** It refuses to load under
`qemu-x86_64` (linux-user) — capture must go through `qemu-system-x86_64`.

### Host packages

```bash
sudo apt install libglib2.0-dev libpixman-1-dev libslirp-dev \
                 libzstd-dev libcapstone-dev busybox-static cpio
```

Two environment traps on this host, both of which produce confusing failures:

* **`CC` points at a conda cross-compiler.** `aarch64-conda-linux-gnu-cc` is
  first in `PATH`, so a plain `make` builds the plugin for the wrong
  architecture and fails to find `zstd.h`. Always build with **`make CC=gcc`**.
* **conda's glib is unusable here** — its `glibconfig.h` is aarch64-targeted and
  mismatches `sizeof(size_t)`. The system `libglib2.0-dev` is required.

`libcapstone-dev` is needed for the **x86** flow even though x86 decoding uses
Zydis, because `raw2champsim` links the AArch64 backend unconditionally. Zydis
is fetched and built automatically by the converter's Makefile.

---

## 4. Running the flow

A self-contained reproduction lives in `scripts/smoke-trace/`. It boots a
throwaway kernel + busybox initramfs running a branchy static workload, captures,
converts, and runs the acceptance checks:

```bash
make -C plugin plugin CC=gcc
make -C converter CC=gcc
scripts/smoke-trace/smoke_trace.sh
```

Unlike `scripts/capture-kit/` (full VM disk images), this exists to answer "is
the pipeline still correct?", not to produce research traces.

### Deferred tracing, and its one sharp edge

Tracing from power-on captures BIOS and early kernel boot, which run in 16- and
32-bit modes while the decoder is initialized for 64-bit long mode. Tracing the
first 20M instructions of a boot yields **1,163,614 decode failures (5.8%)** for
exactly this reason. Use `trigger=` to skip boot:

```
-plugin champsim_tracer.so,outdir=DIR,vcpus=0,limit=30000000,trigger=/path/to/flag
```

then `touch /path/to/flag` once the guest is inside the workload.

**The plugin polls for the trigger only while instructions are retiring.** If
the guest finishes before you arm it, the polls simply stop and the run ends
with `Trigger was never activated` — which looks identical to a wrong path or a
permission error. A guest that boots and runs a 40M-iteration workload completes
in ~12s of wall time, so "wait for the workload banner, then sleep 5s" can
easily arm the trigger *after* QEMU has exited. Size the workload so it is still
running. Build the plugin with `-DTRIGGER_DEBUG` to log every poll with a
timestamp and errno; comparing the last poll's timestamp against your `touch`
settles it immediately.

---

## 5. Verification

### Unit tests

| test | result |
|---|---|
| `make -C converter decode_x86_test` — 30 real `as --64` encodings | **30/30** |
| `make -C converter decode_test` — AArch64 regression guard | **14/14** |
| synthetic raw→ChampSim conversion assertions | **ALL PASS** |

The x86 table is an oracle, not a snapshot: expectations are the x86-64
architecture, not current behaviour. It pins both regressions above, the
count-register conditionals that must *not* read FLAGS, and four per-row
invariants (decode succeeds; no duplicate register; every branch writes IP; the
classes whose inference fallback requires an absent IP source don't carry one).

### End-to-end, 30M instructions of real emulated execution

Captured with `trigger=` after skipping 3.99B instructions of boot:

```
Total instructions:  30,000,000     Decode failures: 0
User mode:           95.2%          Kernel mode:     4.8%
Branches:            4,475,638 (14.9%)
```

| branch type | share of branches | taken |
|---|---|---|
| DIRECT_JUMP | 3.17% | 100.00% |
| CONDITIONAL | 48.83% | **43.04%** |
| DIRECT_CALL | 1.02% | 100.00% |
| INDIRECT_CALL | 22.98% | 100.00% |
| RETURN | 24.00% | 100.00% |

All six acceptance checks in `trace_sanity_check --check` pass over all 30M
records. Two are load-bearing:

* **Conditionals are 43.04% taken** — strictly inside (0,100). The original PIN
  bug showed up as a direct jump class that was 49.17% taken; a class pinned at
  0% or 100% means the direction is being fabricated.
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

Predictors differentiate in the expected order. (Run with `--trace-version 2`.)

### Explicit vs inferred — does the contract actually do anything?

The same 4M-record slice was run twice, once with `reserved[1]` zeroed to force
ChampSim back onto register-shape inference. ChampSim emits its
"carries no explicit branch type" warning on the stripped slice only, confirming
the feature bit is detected and consumed.

Replaying ChampSim's own cascade over 6M records, the two channels disagree on
**75 records — all of them `NOT_BRANCH` inferred as `RETURN`**. These are the
kernel's `iretq`: it reads SP and writes IP without reading IP, which is exactly
ChampSim's signature for a return, so every one pushed a bogus pop onto the
return-address stack. Measurably:

```
return MPKI:  0.1017 (explicit)   vs   0.119 (inferred)
```

Worth stating plainly: on this workload the *large* corrections come from the
decoder fixes in §1, which repair the register shapes that inference reads, so
both channels improved together. The `reserved[0]` channel's distinct
contribution is making the type authoritative rather than reconstructed — and
eliminating the `iretq` case, which no register-shape heuristic can get right.

---

## 6. Known limitations

* **Decode failures assert `NOT_BRANCH`** with the feature bit still set. No
  information is lost (a record with no registers also infers to not-a-branch),
  but it is an assertion rather than an admission of ignorance. Zero on 64-bit
  user code; see §4 for 16/32-bit boot code.
* **`branch_taken` for conditionals is derived by one-record lookahead**
  (`next_ip != ip + size`). If an interrupt lands immediately after a not-taken
  conditional, the next IP is the handler and the branch is recorded as taken.
  Inherent to the raw format — QEMU's plugin API exposes no direction directly —
  and it applies to any system-mode capture with timer interrupts (4.8% of the
  trace above is kernel).

  Unconditional transfers no longer use the lookahead at all; they are taken by
  definition. This was not always so, and the geometry is genuinely unfaithful:
  `jmp .+0` (`e9 00 00 00 00`) targets its own fall-through address, so the
  lookahead called it *not taken*. The Linux kernel leaves these behind after
  alternatives/return-thunk patching — one appeared in an 8M-instruction
  capture and failed the "unconditional transfers are 100% taken" acceptance
  check. A not-taken direct jump (or call, or return) is not a thing, and
  downstream it is indistinguishable from a real not-taken branch.
* **The final record of each file/chunk has no successor.** Unconditional
  transfers are marked taken (true by definition); a trailing conditional is
  **dropped** rather than guessed. With `rotate=N` this recurs once per chunk.
* **ChampSim's BTB warns** `target of return is a lower address than the
  corresponding call` on these traces. Expected for a capture that starts
  mid-execution (early returns have no matching call) and interleaves kernel
  entry/exit.
* **The x86 build requires capstone** purely because the AArch64 backend is
  linked unconditionally. Making it optional would drop the dependency.

---

## 7. AArch64

Deliberately untouched, per scope. `decode_aarch64.c` still classifies branches
its own way and its golden test (14/14) is unaffected by this work. Before
AArch64 traces can carry the same guarantee, it needs the equivalent audit —
the Capstone group/operand APIs differ from Zydis's, so **the specific bugs
above do not transfer, but the class of bug does.** The `reserved[0..2]` writes
in `raw2champsim.c` are arch-independent and already apply to both backends, so
what remains is verifying that the AArch64 decoder's type codes are correct.
