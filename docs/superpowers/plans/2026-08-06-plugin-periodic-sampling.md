# Plugin Periodic Sampling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add periodic sampling to the QEMU tracing plugin, so one run captures K windows of N instructions separated by M-instruction gaps, instead of one contiguous trace.

**Architecture:** A per-vCPU state machine inserted into the existing `insn_exec_cb` hot path, between the `limit_reached` check and the rotation check. The skip phase reuses the dormant fast path (counter increment, no record building) so skipped stretches run at ~300 MIPS rather than ~30. Each capture window is emitted through the existing `rotate=` chunk-file and manifest machinery, generalised from "rotation is on" to "chunking is on".

**Tech Stack:** C (QEMU TCG plugin API v4), glib, zstd. Tests are bash scripts driving real QEMU boots, following the existing `plugin/tests/smoke_capture.sh` convention.

## Global Constraints

- Build the plugin with **`make plugin CC=gcc`**. A bare `make` picks up conda's `aarch64-conda-linux-gnu-cc` and fails on `zstd.h: No such file or directory`.
- QEMU is **9.2.4** at `~/qemu-custom/bin/qemu-system-x86_64`; plugin API v4; **system-emulation only** (the plugin refuses to load under `qemu-x86_64`).
- Default behaviour must be **byte-identical** when `sample_len=0`. Existing captures must not change.
- All new knobs are parsed in `parse_args()` with the existing `g_str_has_prefix` pattern, and an unknown knob remains a fatal error.
- Privilege is an **address heuristic**: `vaddr >= kernel_addr_thresh` (`0xFFFF800000000000` on x86-64). It is not the architectural CPL.
- The plugin is at `plugin/champsim_tracer.c`. Line numbers in this plan refer to the state at commit `a2396a8`.

---

## File Structure

| File | Responsibility |
|---|---|
| `plugin/champsim_tracer.c` (modify) | knob parsing, per-vCPU sampler state, the state machine in `insn_exec_cb`, profile-mode reporting |
| `plugin/tests/sampling_test.sh` (create) | all sampling tests: knob reporting, window geometry, user clock, profile mode, and the rotation-equivalence differential |
| `plugin/README.md` (modify) | document the five knobs and the `sample_clock` asymmetry |

---

## Task 1: Knob parsing, validation, and reporting

**Files:**
- Modify: `plugin/champsim_tracer.c` (globals near line 277; `parse_args` near line 847; install banner near line 1159)
- Modify: `plugin/README.md`
- Test: `plugin/tests/sampling_test.sh` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: file-scope globals `sample_len` (`uint64_t`), `sample_gap` (`uint64_t`), `sample_count` (`uint32_t`), `sample_clock_user` (`bool`, default `true`), `profile_mode` (`bool`, default `false`); helper `static bool chunking_active(void)`.

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/sampling_test.sh`:

```bash
#!/bin/bash
# sampling_test.sh — tests for the plugin's periodic sampling knobs.
#
# Uses the BIOS-only boot from smoke_capture.sh: no disk, no OS, ~20s, and
# SeaBIOS alone retires >200k instructions — enough to exercise the sampler.
#
# Usage: sampling_test.sh [workdir]
set -u
WORK="${1:-${TMPDIR:-/tmp}/cstf-sampling}"
QEMU="${QEMU:-$HOME/qemu-custom/bin/qemu-system-x86_64}"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$PLUGIN_DIR/champsim_tracer.so"
FAILS=0

# Boot SeaBIOS with the given extra plugin args. Writes $1/plugin_stderr.log.
run_bios() {
  local out="$1"; shift
  local extra="$1"
  mkdir -p "$out"; rm -f "$out"/trace_vcpu*.raw.zst "$out"/*manifest.txt
  timeout 40 "$QEMU" \
    -accel tcg -display none -nodefaults -machine pc -m 256 \
    -plugin "$PLUGIN,outdir=$out,vcpus=0$extra" \
    2> "$out/plugin_stderr.log"
  return 0
}

check() { # check <description> <condition-rc>
  if [ "$2" -eq 0 ]; then echo "  PASS: $1"; else echo "  FAIL: $1"; FAILS=$((FAILS+1)); fi
}

echo "== Task 1: knob parsing and validation =="

run_bios "$WORK/t1a" ",limit=200000,sample_len=50000,sample_gap=20000,sample_count=3"
grep -q "Sampling: 3 windows x 50000 insns, gap 20000, clock=user" "$WORK/t1a/plugin_stderr.log"
check "knobs are parsed and reported in the banner" $?

run_bios "$WORK/t1b" ",limit=200000,sample_len=50000,rotate=1000"
grep -q "rotate= and sample_len= are mutually exclusive" "$WORK/t1b/plugin_stderr.log"
check "rotate= together with sample_len= is rejected" $?

run_bios "$WORK/t1c" ",limit=200000,sample_len=50000,sample_clock=bogus"
grep -q "sample_clock= must be user|all" "$WORK/t1c/plugin_stderr.log"
check "invalid sample_clock= value is rejected" $?

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS FAILURE(S)"; exit 1
```

```bash
chmod +x plugin/tests/sampling_test.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `plugin/tests/sampling_test.sh`
Expected: three FAIL lines — the plugin currently rejects `sample_len=` as an unknown argument, so none of the expected strings appear.

- [ ] **Step 3: Add the globals**

In `plugin/champsim_tracer.c`, immediately after `static uint64_t rotate_interval = 0;` (line 277):

```c
/* Periodic sampling. Inert while sample_len == 0 (default), which keeps
 * every existing capture byte-identical. */
static uint64_t sample_len = 0;        /* instructions per capture window */
static uint64_t sample_gap = 0;        /* instructions skipped between windows */
static uint32_t sample_count = 0;      /* windows to capture; 0 = unlimited */
static bool sample_clock_user = true;  /* gap/window-start gated on user mode */
static bool profile_mode = false;      /* count only, write nothing */

/* Chunked output is used by BOTH rotation and sampling: each sampling window
 * is emitted as its own chunk, reusing the rotate= naming and manifest. */
static bool chunking_active(void)
{
    return rotate_interval > 0 || sample_len > 0;
}
```

- [ ] **Step 4: Parse the knobs**

In `parse_args()`, after the `rotate=` branch (line 933-936), add:

```c
        else if (g_str_has_prefix(arg, "sample_len="))
        {
            sample_len = strtoull(arg + 11, NULL, 10);
        }
        else if (g_str_has_prefix(arg, "sample_gap="))
        {
            sample_gap = strtoull(arg + 11, NULL, 10);
        }
        else if (g_str_has_prefix(arg, "sample_count="))
        {
            sample_count = (uint32_t)strtoul(arg + 13, NULL, 10);
        }
        else if (g_str_has_prefix(arg, "sample_clock="))
        {
            const char *v = arg + 13;
            if (!strcmp(v, "user"))      sample_clock_user = true;
            else if (!strcmp(v, "all"))  sample_clock_user = false;
            else
            {
                fprintf(stderr, "[%s] sample_clock= must be user|all\n", PLUGIN_NAME);
                return false;
            }
        }
        else if (g_str_has_prefix(arg, "profile="))
        {
            if (!parse_onoff(arg + 8, &profile_mode))
            {
                fprintf(stderr, "[%s] profile= must be on|off|1|0\n", PLUGIN_NAME);
                return false;
            }
        }
```

- [ ] **Step 5: Reject the mutually exclusive combination**

At the end of `parse_args()`, immediately before the final `return true;`:

```c
    /* Both features emit chunk files and a manifest; running them together
     * would interleave two different chunking schedules into one namespace. */
    if (rotate_interval > 0 && sample_len > 0)
    {
        fprintf(stderr,
                "[%s] rotate= and sample_len= are mutually exclusive\n",
                PLUGIN_NAME);
        return false;
    }
```

- [ ] **Step 6: Report the configuration**

In `qemu_plugin_install`, after the `rotate_interval > 0` reporting block (near line 1159):

```c
    if (sample_len > 0)
    {
        if (sample_count > 0)
            fprintf(stderr,
                    "[%s] Sampling: %u windows x %" PRIu64 " insns, gap %"
                    PRIu64 ", clock=%s\n",
                    PLUGIN_NAME, sample_count, sample_len, sample_gap,
                    sample_clock_user ? "user" : "all");
        else
            fprintf(stderr,
                    "[%s] Sampling: unlimited windows x %" PRIu64
                    " insns, gap %" PRIu64 ", clock=%s\n",
                    PLUGIN_NAME, sample_len, sample_gap,
                    sample_clock_user ? "user" : "all");
    }
    if (profile_mode)
    {
        fprintf(stderr, "[%s] PROFILE MODE: counting only, no records written\n",
                PLUGIN_NAME);
    }
```

- [ ] **Step 7: Build and run the test**

Run: `make -C plugin plugin CC=gcc && plugin/tests/sampling_test.sh`
Expected: `ALL PASS` (3 checks).

- [ ] **Step 8: Document the knobs**

In `plugin/README.md`, add to the knob table after the `rotate=` row:

```markdown
| `sample_len=<N>` | integer | `0` = off | capture N instructions, then skip `sample_gap`, and repeat. Each window is its own chunk file. Mutually exclusive with `rotate=` |
| `sample_gap=<M>` | integer | `0` | instructions skipped between capture windows |
| `sample_count=<K>` | integer | `0` = unlimited | stop after K windows |
| `sample_clock=` | `user` \| `all` | `user` | which instructions advance the **gap** and gate the **window start**. Window *length* always counts every instruction — see below |
| `profile=` | `on` \| `off` | `off` | count instructions and report totals without writing any records; used to measure a trajectory before choosing `sample_gap` |
```

Then add this subsection below the table:

```markdown
### `sample_clock` is deliberately asymmetric

| phase | `sample_clock=user` | `sample_clock=all` |
|---|---|---|
| gap (`sample_gap`) | advances on user-mode instructions only | advances on every instruction |
| window start | begins at the first user-mode instruction after the gap | begins immediately |
| window length (`sample_len`) | **every** instruction counts | every instruction counts |

A window is therefore always exactly `sample_len` records. If the user-mode
clock also governed window length, a window would hold `sample_len` user
instructions *plus* however many kernel instructions interleaved — no longer a
fixed-size slice, and not comparable against a fixed-size slice from another
workload.

What the user clock buys is that a TCG idle stretch neither consumes the gap nor
starts a window. Note "user" here is an **address** test (`vaddr >=
0xFFFF800000000000` on x86-64), not the architectural CPL.
```

- [ ] **Step 9: Commit**

```bash
git add plugin/champsim_tracer.c plugin/README.md plugin/tests/sampling_test.sh
git commit -m "plugin: parse and validate periodic-sampling knobs

Adds sample_len/sample_gap/sample_count/sample_clock/profile, rejects
rotate= together with sample_len= (both own the chunk-file namespace), and
reports the configuration at install time. No behavioural change yet:
sample_len=0 is the default and every existing capture is byte-identical."
```

---

## Task 2: The per-vCPU sampler state machine

**Files:**
- Modify: `plugin/champsim_tracer.c` (`VcpuState` near line 262; `open_chunk` line 567; `close_chunk` line 629; `insn_exec_cb` lines 663-730)
- Test: `plugin/tests/sampling_test.sh`

**Interfaces:**
- Consumes: `sample_len`, `sample_gap`, `sample_count`, `chunking_active()` from Task 1.
- Produces: `VcpuState` fields `sample_skipping` (`bool`), `sample_phase_insns` (`uint64_t`), `sample_windows_done` (`uint32_t`), `sample_finished` (`bool`).

- [ ] **Step 1: Write the failing test**

Append to `plugin/tests/sampling_test.sh`, before the final summary block:

```bash
echo "== Task 2: window geometry =="

# 3 windows of 20k, gap 10k = 80k instructions total. SeaBIOS retires >200k,
# so this fits with margin; 50k/20k windows would not.
run_bios "$WORK/t2a" ",sample_len=20000,sample_gap=10000,sample_count=3,sample_clock=all"

n_chunks=$(ls "$WORK/t2a"/trace_vcpu0_c*.raw.zst 2>/dev/null | wc -l)
[ "$n_chunks" -eq 3 ]
check "exactly 3 chunk files produced (got $n_chunks)" $?

# Manifest columns: index file start_insn insn_count compressed_bytes
MAN="$WORK/t2a/trace_vcpu0_manifest.txt"
[ -f "$MAN" ]
check "manifest written" $?

bad=$(awk '$4 != 20000 {print}' "$MAN" | wc -l)
[ "$bad" -eq 0 ]
check "every window holds exactly 20000 instructions ($bad bad rows)" $?

# Window k starts at k*(len+gap) = k*30000, where k is the chunk index (col 1).
bad=$(awk '$3 != $1*30000 {print}' "$MAN" | wc -l)
[ "$bad" -eq 0 ]
check "window start offsets are len+gap apart ($bad bad rows)" $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `plugin/tests/sampling_test.sh`
Expected: Task 1 checks PASS; Task 2 checks FAIL — no chunk files are produced, because sampling is parsed but not implemented.

- [ ] **Step 3: Add the per-vCPU state**

In `VcpuState`, after the rotation block ending `FILE *manifest_fp;`:

```c
    /* Periodic sampling — inert while sample_len==0 */
    bool     sample_skipping;      /* true = in the gap between windows */
    uint64_t sample_phase_insns;   /* instructions counted in the current phase */
    uint32_t sample_windows_done;  /* completed capture windows */
    bool     sample_finished;      /* sample_count reached; stop this vCPU */
```

- [ ] **Step 4: Generalise chunking from rotation to "rotation or sampling"**

In `open_chunk()` (line 584) and `close_chunk()` (line 648), replace the
`rotate_interval > 0` test with `chunking_active()`:

```c
    /* open_chunk(), line ~584 */
    if (chunking_active())

    /* close_chunk(), line ~648 */
    if (chunking_active() && vs->manifest_fp && vs->chunk_insn_count > 0)
```

- [ ] **Step 5: Implement the state machine**

In `insn_exec_cb`, insert this block immediately after the `vs->limit_reached` early return (line 665-668) and **before** `finalize_pending_insn(vs)`:

```c
    /* ---- Periodic sampling -------------------------------------------
     *
     * Placed before finalize_pending_insn() so the skip phase is exactly as
     * cheap as the dormant phase: one counter increment, no record building.
     *
     * The capture->skip transition MUST finalize first. finalize_pending_insn()
     * is what clears has_pending, and mem_cb() gates on that flag -- without
     * this, memory operations belonging to SKIPPED instructions would attach
     * themselves to the last CAPTURED instruction and silently corrupt its
     * operand list. */
    if (sample_len > 0)
    {
        if (vs->sample_finished)
        {
            return;
        }

        if (vs->sample_skipping)
        {
            InsnMeta *m = (InsnMeta *)userdata;
            bool is_user = (m->vaddr < kernel_addr_thresh);

            /* Flush the last captured instruction once, on entry to the gap.
             * This is the has_pending/mem_cb hazard: without it, the memory
             * operands of SKIPPED instructions attach to the last CAPTURED
             * instruction. Idempotent -- a no-op once has_pending is false. */
            finalize_pending_insn(vs);

            if (!sample_clock_user || is_user)
            {
                vs->sample_phase_insns++;
            }
            if (vs->sample_phase_insns < sample_gap)
            {
                return;
            }
            /* Gap complete. With the user clock the next window must BEGIN on a
             * user-mode instruction, so a TCG idle stretch never starts one. */
            if (sample_clock_user && !is_user)
            {
                return;
            }

            vs->sample_skipping    = false;
            vs->sample_phase_insns = 0;
            vs->chunk_index++;
            if (!open_chunk(vs))
            {
                vs->chunk_insn_count = 0;
                vs->limit_reached    = true;
                return;
            }
            /* Fall through: record THIS instruction as the window's first. */
        }
    }
```

Then, immediately after the existing `finalize_pending_insn(vs);` call, add the
window-completion check.

**This must not `return` on the boundary.** Each callback finalizes the
*previous* instruction and stores the *current* one as pending at the end of the
function. Returning here would mean the current instruction is neither recorded
nor counted toward the gap — one instruction silently dropped per boundary, and
`sample_gap=0` would then *not* reproduce `rotate=` (Task 5 would fail). Instead
the boundary consumes the current instruction into the gap explicitly, which
makes `sample_gap=0` degenerate to rotation with no special case:

```c
    /* Window length always counts EVERY instruction, so a window is exactly
     * sample_len records regardless of sample_clock. */
    if (sample_len > 0 && !vs->sample_skipping && vs->chunk_insn_count >= sample_len)
    {
        close_chunk(vs);
        vs->sample_windows_done++;
        vs->sample_phase_insns = 0;

        if (sample_count > 0 && vs->sample_windows_done >= sample_count)
        {
            vs->sample_finished = true;
            vs->limit_reached   = true;   /* reuse existing stop/flush machinery */
            return;
        }

        vs->sample_skipping = true;

        /* Account for the CURRENT instruction here rather than dropping it. */
        InsnMeta *mb    = (InsnMeta *)userdata;
        bool      is_u  = (mb->vaddr < kernel_addr_thresh);
        if (!sample_clock_user || is_u)
        {
            vs->sample_phase_insns++;
        }
        if (vs->sample_phase_insns < sample_gap)
        {
            return;                       /* consumed by the gap */
        }
        if (sample_clock_user && !is_u)
        {
            return;                       /* wait for a user-mode instruction */
        }

        /* Gap already satisfied (the sample_gap==0 case): reopen immediately
         * and fall through, so this instruction lands in the next window --
         * exactly what rotate= does at a chunk boundary. */
        vs->sample_skipping    = false;
        vs->sample_phase_insns = 0;
        vs->chunk_index++;
        if (!open_chunk(vs))
        {
            vs->chunk_insn_count = 0;
            vs->limit_reached    = true;
            return;
        }
    }
```

- [ ] **Step 6: Run the test**

Run: `make -C plugin plugin CC=gcc && plugin/tests/sampling_test.sh`
Expected: `ALL PASS` (7 checks).

- [ ] **Step 7: Verify the default path is untouched**

Run: `plugin/tests/smoke_capture.sh /tmp/cstf-regress`
Expected: `OK: /tmp/cstf-regress/trace_vcpu0.raw.zst (<size> bytes)` — a single
plain-named file, proving `sample_len=0` still produces un-chunked output.

- [ ] **Step 8: Commit**

```bash
git add plugin/champsim_tracer.c plugin/tests/sampling_test.sh
git commit -m "plugin: per-vCPU periodic sampling state machine

Captures sample_len instructions, skips sample_gap, repeats for
sample_count windows, emitting each window as its own chunk through the
existing rotate= chunk/manifest machinery (generalised to chunking_active()).

The skip phase sits before finalize_pending_insn() so it costs one counter
increment, matching the dormant phase. The capture->skip transition finalizes
first: finalize_pending_insn() is what clears has_pending and mem_cb() gates
on it, so skipping without finalizing would attach skipped instructions'
memory operands to the last captured instruction."
```

---

## Task 3: The user-mode sampling clock

**Files:**
- Modify: `plugin/tests/sampling_test.sh`
- Depends on the guest built by `scripts/smoke-trace/smoke_trace.sh` (a real kernel plus user workload; the BIOS boot cannot exercise this, because SeaBIOS runs entirely at low addresses and so reads as 100% "user" under the VA heuristic).

**Interfaces:**
- Consumes: `sample_clock_user` (Task 1) and the state machine (Task 2). No new production code — Task 2 already implements both clocks; this task proves the difference.

- [ ] **Step 1: Write the failing test**

Append to `plugin/tests/sampling_test.sh` before the summary block:

```bash
echo "== Task 3: user-mode sampling clock =="

# Needs a guest with a real user/kernel split. Reuse the smoke-trace guest.
GUEST_KERNEL="${GUEST_KERNEL:-}"
GUEST_INITRD="${GUEST_INITRD:-}"
if [ -z "$GUEST_KERNEL" ] || [ ! -f "$GUEST_KERNEL" ]; then
  echo "  SKIP: set GUEST_KERNEL and GUEST_INITRD (see scripts/smoke-trace/) to run this"
else
  run_guest() { # run_guest <outdir> <extra-plugin-args>
    local out="$1"; local extra="$2"
    mkdir -p "$out"; rm -f "$out"/trace_vcpu*.raw.zst "$out"/*manifest.txt
    timeout 300 "$QEMU" -accel tcg -cpu qemu64 -smp 1 -m 1G \
      -kernel "$GUEST_KERNEL" -initrd "$GUEST_INITRD" \
      -append "console=ttyS0 quiet" -nographic -no-reboot \
      -plugin "$PLUGIN,outdir=$out,vcpus=0$extra" > "$out/boot.log" 2>&1
    return 0
  }

  # Kernel-mode instructions must NOT advance the gap under sample_clock=user,
  # so a user-clock run reaches its windows LATER in the instruction stream
  # than an all-clock run with the same gap.
  run_guest "$WORK/t3u" ",sample_len=200000,sample_gap=2000000,sample_count=2,sample_clock=user"
  run_guest "$WORK/t3a" ",sample_len=200000,sample_gap=2000000,sample_count=2,sample_clock=all"

  start_u=$(awk 'NR==2 {print $3}' "$WORK/t3u/trace_vcpu0_manifest.txt")
  start_a=$(awk 'NR==2 {print $3}' "$WORK/t3a/trace_vcpu0_manifest.txt")
  [ -n "$start_u" ] && [ -n "$start_a" ] && [ "$start_u" -gt "$start_a" ]
  check "user clock reaches window 2 later than all clock ($start_u > $start_a)" $?

  # Window length is clock-independent: exactly sample_len either way.
  bad=$(cat "$WORK/t3u/trace_vcpu0_manifest.txt" "$WORK/t3a/trace_vcpu0_manifest.txt" \
        | awk '$4 != 200000 {print}' | wc -l)
  [ "$bad" -eq 0 ]
  check "window length is exactly sample_len under both clocks ($bad bad rows)" $?
fi
```

- [ ] **Step 2: Build the guest assets the test needs**

Run: `scripts/smoke-trace/smoke_trace.sh /tmp/cstf-guest`
This builds `/tmp/cstf-guest/vmlinuz` and `/tmp/cstf-guest/initramfs.gz`. Then:

```bash
export GUEST_KERNEL=/tmp/cstf-guest/vmlinuz
export GUEST_INITRD=/tmp/cstf-guest/initramfs.gz
```

- [ ] **Step 3: Run the test**

Run: `plugin/tests/sampling_test.sh`
Expected: `ALL PASS` (9 checks). If Task 2's clock handling is wrong — for
example if the user clock is applied to window *length* — the second check fails
with rows whose `insn_count != 200000`.

- [ ] **Step 4: Commit**

```bash
git add plugin/tests/sampling_test.sh
git commit -m "plugin: test the user-mode sampling clock against a real guest

The BIOS-only smoke boot cannot exercise this: SeaBIOS runs entirely at low
addresses, so the VA-based privilege heuristic reads it as 100% user and both
clocks behave identically. This uses the smoke-trace guest, which has a real
user/kernel split, and asserts the two properties that matter: kernel
instructions do not advance the gap, and window length is clock-independent."
```

---

## Task 4: `profile=on`

**Files:**
- Modify: `plugin/champsim_tracer.c` (`insn_exec_cb`; `plugin_atexit` near line 931)
- Test: `plugin/tests/sampling_test.sh`

**Interfaces:**
- Consumes: `profile_mode` (Task 1).
- Produces: file-scope counters `profile_total_insns` (`uint64_t`), `profile_user_insns` (`uint64_t`).

- [ ] **Step 1: Write the failing test**

Append to `plugin/tests/sampling_test.sh` before the summary block:

```bash
echo "== Task 4: profile mode =="

run_bios "$WORK/t4" ",limit=0,profile=on"

grep -qE "PROFILE: [0-9]+ instructions \([0-9]+ user, [0-9]+ kernel\)" "$WORK/t4/plugin_stderr.log"
check "profile mode reports total/user/kernel counts" $?

n_files=$(ls "$WORK/t4"/trace_vcpu0*.raw.zst 2>/dev/null | wc -l)
[ "$n_files" -eq 0 ]
check "profile mode writes no trace files (got $n_files)" $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `plugin/tests/sampling_test.sh`
Expected: both Task 4 checks FAIL — no `PROFILE:` line, and a trace file is written.

- [ ] **Step 3: Add the counters**

Next to the sampling globals from Task 1:

```c
/* profile=on counters (global: the profile pass measures the whole ROI) */
static uint64_t profile_total_insns = 0;
static uint64_t profile_user_insns  = 0;
```

- [ ] **Step 4: Count and return early**

In `insn_exec_cb`, immediately after the dormant/trigger block (i.e. after the
`if (!tracing_enabled) { ... return; }` closing brace) and **before**
`VcpuState *vs = &vcpu_state[vcpu_index];`:

```c
    /* Profile mode: count only. Returning here means no VcpuState is touched,
     * no chunk is opened, and no file is created -- so a profile pass costs the
     * same as the dormant phase and leaves no artifacts to clean up. */
    if (profile_mode)
    {
        InsnMeta *m = (InsnMeta *)userdata;
        profile_total_insns++;
        if (m->vaddr < kernel_addr_thresh)
        {
            profile_user_insns++;
        }
        return;
    }
```

- [ ] **Step 5: Report at exit**

In `plugin_atexit`, immediately after the `Finalizing traces...` line:

```c
    if (profile_mode)
    {
        fprintf(stderr,
                "[%s] PROFILE: %" PRIu64 " instructions (%" PRIu64 " user, %"
                PRIu64 " kernel)\n",
                PLUGIN_NAME, profile_total_insns, profile_user_insns,
                profile_total_insns - profile_user_insns);
        fprintf(stderr,
                "[%s] For K windows of N insns: sample_gap = (user - K*N)/(K-1)\n",
                PLUGIN_NAME);
    }
```

- [ ] **Step 6: Run the test**

Run: `make -C plugin plugin CC=gcc && plugin/tests/sampling_test.sh`
Expected: `ALL PASS` (11 checks).

- [ ] **Step 7: Commit**

```bash
git add plugin/champsim_tracer.c plugin/tests/sampling_test.sh
git commit -m "plugin: add profile=on to size a trajectory before sampling

Counts total and user-mode instructions after the trigger and writes no
records, so spacing K windows evenly across an unknown-length workload takes
one cheap dormant-speed pass. Returns before any VcpuState is touched, so no
chunk is opened and no file is created."
```

---

## Task 5: Rotation-equivalence differential

**Files:**
- Modify: `plugin/tests/sampling_test.sh`

**Interfaces:**
- Consumes: everything from Tasks 1-4. No new production code.

This is the highest-value test in the plan. Every defect in the preceding
branch-type work produced structurally valid, semantically wrong output that
self-consistency checks could not see; only differential tests against an
independent oracle caught them. `rotate=` is that independent oracle here.

**The property:** sampling with `sample_gap=0` and `sample_clock=all` is
*definitionally* the same schedule as `rotate=`. Any off-by-one in the window
boundary — the exact class of bug that caused the 1.56× skip-counter error in the
pintool — makes the two disagree byte-for-byte.

- [ ] **Step 1: Write the failing test**

Append to `plugin/tests/sampling_test.sh` before the summary block:

```bash
echo "== Task 5: sampling with gap=0 must equal rotation =="

run_bios "$WORK/t5s" ",limit=100000,sample_len=50000,sample_gap=0,sample_count=2,sample_clock=all"
run_bios "$WORK/t5r" ",limit=100000,rotate=50000"

same=0
for k in 00000 00001; do
  a="$WORK/t5s/trace_vcpu0_c$k.raw.zst"
  b="$WORK/t5r/trace_vcpu0_c$k.raw.zst"
  if [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"; then :; else same=1; fi
done
[ "$same" -eq 0 ]
check "gap=0 sampling is byte-identical to rotate= for every chunk" $?
```

- [ ] **Step 2: Run the test**

Run: `plugin/tests/sampling_test.sh`
Expected: `ALL PASS` (12 checks).

If this check fails, the window boundary is off by one instruction relative to
rotation. Diagnose by comparing the manifests:
`diff <(cat "$WORK/t5s"/trace_vcpu0_manifest.txt) <(cat "$WORK/t5r"/trace_vcpu0_manifest.txt)` —
the `start_insn` and `insn_count` columns localise it immediately.

- [ ] **Step 3: Wire the tests into the Makefile**

In `plugin/Makefile`, add to `.PHONY` and append a target:

```makefile
.PHONY: test
test: plugin
	tests/smoke_capture.sh $${TMPDIR:-/tmp}/cstf-smoke
	tests/sampling_test.sh $${TMPDIR:-/tmp}/cstf-sampling
```

- [ ] **Step 4: Run the full suite**

Run: `make -C plugin test CC=gcc`
Expected: `OK: ...` from the smoke test, then `ALL PASS` from the sampling tests.

- [ ] **Step 5: Commit**

```bash
git add plugin/tests/sampling_test.sh plugin/Makefile
git commit -m "plugin: differential test — gap=0 sampling must equal rotation

Sampling with sample_gap=0 and sample_clock=all is definitionally the same
schedule as rotate=, so the two must produce byte-identical chunks. This is
the test that catches an off-by-one at the window boundary, which is the
class of bug that produced the 1.56x pintool skip-counter error and which no
self-consistency check can see.

Also adds `make test` to run both plugin test scripts."
```

---

## Self-Review

**Spec coverage.** §6 of the spec defines five knobs — all parsed in Task 1;
the `DORMANT → CAPTURING ⇄ SKIPPING → DONE` machine — Task 2; the asymmetric
`sample_clock` — implemented in Task 2, proven in Task 3; chunk-per-window
reusing `rotate=` naming and manifest — Task 2 Step 4; `rotate=`/`sample_len=`
mutual exclusion — Task 1 Step 5; `profile=on` and the spacing formula — Task 4;
the `finalize_pending_insn`/`mem_cb` hazard — Task 2 Step 5. The differential
cross-check required by spec §11.3 is Task 5. Spec §11.4 (extending
`scripts/smoke-trace/` with sampling knobs) is deliberately deferred to the
capture-pipeline plan, since it is a consumer of this feature rather than part
of it.

**Type consistency.** `sample_len`/`sample_gap` are `uint64_t`, `sample_count` is
`uint32_t` (matching `chunk_index`), `sample_clock_user`/`profile_mode` are
`bool`. `chunking_active()` is used identically in `open_chunk` and
`close_chunk`. The `VcpuState` fields added in Task 2 are the only ones
referenced by the state machine.

**Placeholder scan.** No TBDs; every code step carries the actual code, and every
test step names the exact command and expected output.

---

## Not in this plan

These are the remaining spec deliverables, each of which will get its own plan
because each produces working, testable software on its own:

1. **Replay proxy** — record/replay HTTP server plus cassette-key canonicalisation tests (spec §9, §11.1).
2. **Guest build/record/trace scripts** — Passes 1-3, guest tuning, ROI arming (spec §5, §7, §8). *Needs the task selection and the API key.*
3. **Conversion and validation driver** — `trace_filter` → `raw2champsim` → `trace_sanity_check` per window, plus idle-fraction reporting (spec §10).
