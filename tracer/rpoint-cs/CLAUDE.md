# CLAUDE.md — QEMU-Based Multi-Threaded Trace Generator for ChampSim

> **This tool is now `tracer/rpoint-cs/` inside champsim-infra** (subsumed from the
> standalone `qemu-tracing` repo, 2026-08-18). Paths below that say
> `~/qemu-tracing/…` mean this directory. Start with [README.md](README.md)
> for the current shape of the tool; the sections below keep the full
> operational detail, some of it from the original Memcached/NUMA phase.
> The SWE-agent capture campaign lives on the `swe-agent-tracing` branch.

## Project Overview

We are building a trace generation pipeline that extracts multi-threaded
instruction traces from real-world workloads (starting with Memcached) to
feed into an extended ChampSim simulator for NUMA memory system research.

The pipeline uses QEMU's TCG (Tiny Code Generator) mode with a custom
plugin to capture per-vCPU instruction traces, including memory access
values. These traces will be converted offline into ChampSim-compatible
format for simulating a multi-socket, multi-node memory architecture.

## Research Goal

Simulate a 2-socket system (2 cores per socket, each socket with its own
DRAM node) to study data sharing patterns across sockets and evaluate
data placement/migration policies. The workload (Memcached under
memtier_benchmark load) has a large data footprint (~6 GB) and 4 worker
threads that share data structures (hash table, slab allocator), creating
realistic cross-socket sharing.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    QEMU VM (5 vCPUs)                     │
│                                                           │
│  vCPU 0-3: Memcached workers (pinned, traced)            │
│  vCPU 4:   memtier_benchmark + OS (pinned, NOT traced)   │
│                                                           │
│  Phase 1 (KVM): Boot, load data, take snapshot           │
│  Phase 2 (TCG+Plugin): Restore snapshot, trace           │
└─────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
  ┌──────────────┐           ┌────────────────────┐
  │ .raw.zst     │           │ Offline Converter   │
  │ per-vCPU     │ ────────► │ (x86 decode,        │
  │ trace files  │           │  register extract,  │
  │              │           │  branch classify)   │
  └──────────────┘           └────────────────────┘
                                       │
                                       ▼
                             ┌────────────────────┐
                             │ ChampSim Traces     │
                             │ (extended format    │
                             │  with values +      │
                             │  privilege bit)     │
                             └────────────────────┘
                                       │
                                       ▼
                             ┌────────────────────┐
                             │ Extended ChampSim   │
                             │ (2 sockets, NUMA)   │
                             └────────────────────┘
```

## Host Machine

- **CPU:** Intel i7-8700 (6 cores / 12 threads)
- **RAM:** 32 GB
- **OS:** Ubuntu 24.04 LTS
- **QEMU:** 9.2.4 (built from source with `--enable-kvm --enable-plugins`)
- **QEMU source:** `~/work/softwares/qemu-9.2.4/`
- **QEMU install:** `~/qemu-custom/bin/qemu-system-x86_64`

## Guest VM Configuration

- **OS:** Ubuntu Server 24.04, kernel 6.8.0-107-generic
- **vCPUs:** 5 (`-smp 5`)
- **RAM:** 12 GB (`-m 12G`)
- **Disk:** `~/qemu-tracing/images/ubuntu-guest.qcow2` (qcow2, 40 GB)
- **Networking:** SLIRP user-mode, port forwards: 2222→22 (SSH), 11211→11211 (Memcached)
- **Guest tuning:** ASLR disabled, swap off, THP disabled, unnecessary services disabled

## Workload Setup (Inside Guest)

- **Memcached:** 4 worker threads (`-t 4`), 8 GB memory (`-m 8192`), workers pinned to vCPUs 0-3
- **Data:** ~2.25M records loaded via YCSB, ~6 GB footprint
- **Benchmark:** memtier_benchmark (native C), pinned to vCPU 4
  - Default: `--ratio=1:1` (50/50 GET:SET), `--key-maximum=2250000`, Gaussian distribution
  - Duration set to 86400s (effectively infinite for tracing)
- **Snapshots:**
  - `roi_ready`: Memcached warm with 6 GB data, idle, threads pinned
  - `roi_running`: Same as roi_ready but memtier_benchmark actively sending requests

## Pipeline Stages Completed

### Stage 1: VM Setup ✅
- QEMU installed with KVM
- Guest VM created with cloud-init (headless, no GUI)
- Memcached and memtier_benchmark installed and configured
- YCSB installed (used only for data loading phase)

### Stage 2: Snapshot Creation ✅
- YCSB loads 2.25M records (~6 GB) into Memcached under KVM (fast)
- `roi_ready` snapshot: warm Memcached, idle
- `roi_running` snapshot: warm Memcached + memtier actively running
- Snapshots created under KVM with `-cpu host,-kvmclock`

### Stage 3: TCG Tracing Plugin ✅
- Plugin: `~/qemu-tracing/plugin/champsim_tracer.so`
- Captures: IP, raw instruction bytes, privilege level, memory addresses/sizes/values
- Output: zstd-compressed per-vCPU trace files (`.raw.zst`)
- Value capture via QEMU 9.2 `qemu_plugin_mem_get_value()` API
- Inspector tool: `~/qemu-tracing/plugin/trace_inspector`

### Stage 4: TCG Tracing Run — READY ✅
**kvmclock blocker resolved** — QEMU patched to instantiate the kvmclock device under TCG.

### Stage 5: Extended format, AArch64 capture kit, online rotation ✅
- **Raw format v3** — arch byte, optional per-op physical addresses,
  memory values with an honest `value_cap`. Emitted by the plugin;
  read by `trace_inspector`, `trace_filter`, and `converter/raw2champsim`
  (all whitelist versions `{2,3}`). Spec:
  `docs/superpowers/specs/2026-07-06-aarch64-capture-kit-design.md`.
- **AArch64 capture kit** (`scripts/capture-kit/`) — for a collaborator
  capturing on an AArch64 host: `probe_guest.sh` (in-guest facts) →
  `configure_tracer.sh` (host; emits a ready `run_trace.sh` + a
  `trace_metadata.txt` provenance sidecar). The plugin auto-detects the
  guest arch. Collaborator entry point: `scripts/capture-kit/README.md`.
- **Online raw rotation** (`rotate=N`) — see the Raw Trace Format
  section below; kit defaults it on at 100 M instructions/chunk.
- Converter reads raw v2, v3/x86_64, and v3/aarch64 (PA passed through
  for all). AArch64 (A64) decode is implemented via Capstone 4.0.2 —
  frozen register-ID scheme, LR-based call/return, `ERET`→OTHER, and the
  rest of the conventions are documented in `converter/README.md` and
  `docs/superpowers/specs/2026-07-07-raw2champsim-aarch64-design.md`.
  What remains is the ChampSim **simulator-side** AArch64 configuration
  (cache/uarch params, running the extended simulator on these traces)
  — a separate, later phase.

### Stage 6: Explicit branch type + flags register — **x86-64 only** ✅/⚠️

Traces now **state** each instruction's branch type instead of leaving
ChampSim to infer it from register shape. Three of the v2 record's
reserved bytes carry it: `reserved[0]` = ChampSim's `branch_type` enum
(0-based, `7`=NOT_BRANCH), `reserved[1]` = feature bits (`0x01` explicit
type, `0x02` flags recorded), `reserved[2]` = tracer identity (`4` =
this converter). Layout unchanged at 512 B and **deliberately no
trace-version bump** — a version is asserted by whoever names the file,
a feature bit is self-describing by the data.

**Consumers must key off the feature bit, never off `reserved[0] != 0`**
— `BRANCH_DIRECT_JUMP` is `0`, so a zeroed record is byte-identical to
one describing a direct jump.

Three defects were fixed in `converter/decode_x86.c`, all of which had
been producing structurally perfect records of the wrong class: a
**range check over the alphabetically-ordered `ZydisMnemonic`** (so
`jmp` was CONDITIONAL and `je` was OTHER), `meta.branch_type ==
SHORT|NEAR` **mistaken for "direct"** (so indirect jumps/calls were
unreachable), and **register-slot eviction plus a fabricated FLAGS
source** on `jcxz`/`loop`. Branch direction now comes from the type
rather than from next-IP geometry (`jmp .+0` broke the geometry).

> ### ⚠️ AArch64 has NOT received this work
>
> `raw2champsim.c` writes `reserved[0..2]` for **both** backends, so an
> AArch64 trace already **claims** `TRACE_FEATURE_EXPLICIT_BRANCH_TYPE`
> and ChampSim will believe it. Nothing in the A64 backend was audited,
> tested, or captured for this work.
>
> **The gap is verification, not suspected breakage.** Reading
> `decode_aarch64.c`, it is structurally immune to all three x86 defects
> — it switches explicitly on instruction ID (no range check), gets
> direct-vs-indirect from distinct mnemonics (`B`/`BL` vs `BR`/`BLR`),
> de-duplicates registers in `add_src`/`add_dst`, and adds FLAGS only
> for `B.cond`. That last one is the case (`CBZ`/`CBNZ`/`TBZ`/`TBNZ`
> test a GPR, not NZCV) where the **x86** backend was fabricating a
> dependency edge — A64 had it right all along.
>
> What is actually missing:
> 1. The golden test covers 6 of 10 branch forms — **not** unconditional
>    `B`, `CBNZ`, `TBZ`/`TBNZ`, or `ERET`. Unconditional `B` is the
>    important one: it shares an instruction ID with `B.cond` and is
>    separated only by a Capstone metadata field (`arm64.cc`), so a
>    Capstone behaviour change would silently turn every unconditional
>    branch into a conditional — the x86 `JMP` failure reached by a
>    different road, and nothing tests for it.
> 2. **No AArch64 capture has ever been run through
>    `trace_sanity_check --check`.** The branch mix and taken rates,
>    which are what catch a misclassification in aggregate, are
>    unmeasured.
> 3. `ERET`→`BRANCH_OTHER` (A64) vs `iretq`→`NOT_BRANCH` (x86): both
>    deliberately avoid `BRANCH_RETURN` so neither is wrong, but they
>    are two spellings of one decision. Worth reconciling.
>
> **Treat the feature bits on an AArch64 trace as a claim, not a
> guarantee** — not because it looks wrong, but because nothing has
> confirmed it right. Plan of attack: `docs/branch-type-contract.md` §10.

Full reference — contract, per-instruction classification table,
direction semantics, toolchain, verification methodology and results,
and the AArch64 gap: **`docs/branch-type-contract.md`**.

Verified (x86-64): 30/30 golden unit rows on real `as --64` encodings,
14/14 AArch64 regression guard still passing, and a 30 M-instruction
capture of real emulated execution passing all six acceptance checks
with 0 decode failures — conditionals 43.04% taken, unconditionals
100% taken, calls (24.00%) exactly balancing returns (24.00%).
Re-runnable in ~2 minutes: `scripts/smoke-trace/smoke_trace.sh`.

## Current Blocker: kvmclock Snapshot Incompatibility

> **Historical (x86/Memcached era).** This blocker was resolved (see
> Stage 4) and the section is kept for the debugging pattern it records.
> The AArch64 collaborator captures under a different flow — see
> `scripts/capture-kit/README.md`.

### The Problem

Snapshots taken under KVM contain a `kvmclock` device state section.
When loading under TCG, QEMU can't find a registered handler for
`kvmclock` (the device is only instantiated under KVM) and aborts:

```
qemu-system-x86_64: Unknown savevm section or instance 'kvmclock' 0.
Make sure that your current VM setup matches your saved VM setup,
including any hotplugged devices
qemu-system-x86_64: Error -22 while loading VM state
```

### What We've Already Tried (Failed)

1. **`-cpu host,-kvmclock`**: Prevents exposing kvmclock CPUID feature but
   QEMU's KVM accelerator still registers the kvmclock save handler
   regardless of CPU flags.

2. **Guest kernel cmdline `no-kvmclock clocksource=tsc tsc=reliable`**:
   Changes the guest clocksource but doesn't prevent QEMU from saving
   kvmclock state at the hypervisor level.

3. **Both combined**: Still fails. The kvmclock VMState handler is registered
   by QEMU's KVM code unconditionally when KVM is the accelerator.

### Why Simple "Skip" Won't Work

The snapshot stream format has no per-section length field. Each section's
data is written by `vmstate_save_state()` according to the device's
`VMStateDescription`. Without knowing the VMState format, we can't skip
the correct number of bytes — the stream position would be wrong and
every subsequent section would fail to load.

### The Fix: Patch QEMU to Create kvmclock Under TCG

**Approach:** Modify `hw/i386/kvm/clock.c` to:
1. Create the kvmclock device even when KVM is not the accelerator
2. In `kvmclock_realize()`, skip KVM-specific initialization under TCG

This way, the VMState handler exists under TCG, QEMU reads the kvmclock
data from the snapshot correctly (and discards it), and the rest of the
snapshot loads normally.

**The kvmclock VMState format is simple:**
```c
// Main state: single uint64_t
.fields = (const VMStateField[]) {
    VMSTATE_UINT64(clock, KVMClockState),
    VMSTATE_END_OF_LIST()
},
// Optional subsection: single bool
.subsections = (const VMStateDescription * const []) {
    &kvmclock_reliable_get_clock,  // contains VMSTATE_BOOL
    NULL
}
```

### What Needs to Be Done

1. Find the exact `kvmclock_create()` function in `~/work/softwares/qemu-9.2.4/hw/i386/kvm/clock.c`
   and identify where the `kvm_enabled()` guard prevents device creation under TCG.

2. Find where `kvmclock_create()` is called from (likely `hw/i386/pc.c` or similar
   machine init code).

3. Patch `kvmclock_realize()` to return early (skip KVM init) when `!kvm_enabled()`.

4. Patch the call site or `kvmclock_create()` to remove/relax the `kvm_enabled()` guard.

5. Rebuild QEMU: `cd ~/work/softwares/qemu-9.2.4/build && make -j$(nproc) && make install`

6. Test: Load `roi_running` snapshot under TCG with the tracing plugin.

### Key Source Files

- `~/work/softwares/qemu-9.2.4/hw/i386/kvm/clock.c` — kvmclock device implementation
- `~/work/softwares/qemu-9.2.4/migration/savevm.c` — snapshot loading (error originates here)
- `~/work/softwares/qemu-9.2.4/hw/i386/pc.c` or `~/work/softwares/qemu-9.2.4/hw/i386/x86.c` — likely calls `kvmclock_create()`

### Build Configuration

```bash
cd ~/work/softwares/qemu-9.2.4/build
../configure \
    --target-list=x86_64-softmmu \
    --enable-kvm \
    --enable-plugins \
    --enable-slirp \
    --prefix=$HOME/qemu-custom \
    --disable-docs \
    --disable-werror
make -j$(nproc)
make install
```

Binary installs to: `~/qemu-custom/bin/qemu-system-x86_64`

### Testing the Patch

After rebuilding, test with:

```bash
# Test 1: Does the patched QEMU still boot normally under KVM?
~/qemu-custom/bin/qemu-system-x86_64 \
    -accel kvm -cpu host,-kvmclock -smp 5 -m 12G \
    -drive file=$HOME/qemu-tracing/images/ubuntu-guest.qcow2,format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
    -nographic -serial mon:stdio \
    -loadvm memcached_loaded

# Test 2: Does it load the KVM snapshot under TCG? (THE CRITICAL TEST)
~/qemu-custom/bin/qemu-system-x86_64 \
    -accel tcg,thread=multi -cpu qemu64 -smp 5 -m 12G \
    -drive file=$HOME/qemu-tracing/images/ubuntu-guest.qcow2,format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
    -nographic -serial mon:stdio \
    -loadvm memcached_loaded

# Test 3: Does it load under TCG with the tracing plugin?
~/qemu-custom/bin/qemu-system-x86_64 \
    -accel tcg,thread=multi -cpu qemu64 -smp 5 -m 12G \
    -drive file=$HOME/qemu-tracing/images/ubuntu-guest.qcow2,format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22,hostfwd=tcp::11211-:11211 \
    -nographic -serial mon:stdio \
    -plugin $HOME/qemu-tracing/plugin/champsim_tracer.so,outdir=$HOME/qemu-tracing/traces,vcpus=0-3,limit=1000000 \
    -loadvm memcached_loaded
```

**Expected success criteria for Test 2:**
- No "Unknown savevm section" error
- VM resumes (you see console output or can SSH on port 2222)
- Guest is functional (Memcached running, memtier sending requests)

**If additional unknown sections appear** (e.g., `kvm-tpr-opt`, `apic-msi`),
the same approach applies: find the device, make it instantiable under TCG.

## File Locations

```
~/qemu-tracing/
├── images/ubuntu-guest.qcow2          # VM disk + snapshots
├── plugin/
│   ├── champsim_tracer.c              # TCG tracing plugin source
│   ├── champsim_tracer.so             # Compiled plugin
│   ├── build_plugin.sh                # Plugin build script
│   ├── trace_inspector.c              # Trace validation tool source
│   └── trace_inspector                # Compiled inspector
├── traces/                            # Output directory for traces
├── snapshots/roi_ready_metadata.txt
└── scripts/
    ├── boot_kvm.sh                    # Stage 1 KVM boot (4 vCPU)
    ├── boot_kvm_5vcpu.sh              # Stage 2+ KVM boot (5 vCPU)
    └── boot_tcg_trace.sh              # Stage 4 TCG+plugin boot

~/work/softwares/qemu-9.2.4/                # QEMU source tree
~/qemu-custom/                         # QEMU install prefix
```

## Guest-Side Scripts

```
~/run_experiment_v2.sh     # Load data into Memcached + prepare for snapshot
~/start_benchmark.sh       # Launch memtier_benchmark (run after restore)
~/start_memcached_pinned.sh # Start Memcached with thread pinning
```

## Raw Trace Format (v3)

**File:** `.raw.zst` (zstd compressed). Current since the AArch64
capture kit work; full byte-level contract in
`docs/superpowers/specs/2026-07-06-aarch64-capture-kit-design.md`
(§3). Old v2 files remain readable forever — `trace_inspector`,
`trace_filter`, and `converter/raw2champsim` all whitelist versions
`{2, 3}` — but the plugin itself now emits v3 only.

**Header (16 bytes, same size as v2):** magic `CSTF`, version `3`,
vcpu_id, then four individual `uint8_t` fields (not a packed u32,
readers must decode byte-by-byte) replacing v2's reserved word:
`arch` (0=x86_64, 1=aarch64), `flags` (bit0 `has_pa`, bit1
`has_values`), `value_cap` (effective value-capture cap in bytes,
0 if `has_values=0`), `reserved` (0).

**Per instruction (variable length):**
```
[header: 4 bytes]
  bits [3:0]   = vcpu_id (0-15)
  bits [4]     = privilege (0=user, 1=kernel)
  bits [8:5]   = instr_size (1-15)
  bits [11:9]  = num_mem_ops (0-7)

[IP: 8 bytes]
[instruction bytes: instr_size bytes]
[memory ops × num_mem_ops:]
  VA:      8 bytes
  PA:      8 bytes (ONLY present when file header flags.has_pa=1;
           per-file all-or-nothing; failed hwaddr lookups write 0)
  size:    1 byte
  opflags: 1 byte (bit0 write, bit1 has_value, bit2 pa_valid,
           bit3 pa_is_io — bits 2-3 meaningful only when has_pa=1)
  value:   size bytes (only if has_value; only ever set when
           size <= value_cap)
```

**`value_cap`:** today's plugins write `value_cap = 16` because
`qemu_plugin_mem_get_value()` tops out at U128 (16 bytes) and asserts
(VM abort) on wider accesses — that hard API cap is why `value_cap` is
tracked separately from the format's 64-byte value-buffer ceiling
(`MAX_VALUE_SIZE`), which exists so a future wider QEMU API needs no
format or reader change.

New plugin knobs beyond v2's `outdir=`/`vcpus=`/`limit=`/`trigger=`:
`arch=auto|x86_64|aarch64` (default `auto`, resolved from the QEMU
target), `capture_pa=on|off` (default `on`), `values=on|off` (default
`on`). Full knob and format reference: `plugin/README.md`.

**Online rotation (`rotate=N`, optional, default off).** The plugin
can also chunk its own output as it captures: with `rotate=N` (N>0), it
closes the current per-vCPU chunk and opens a fresh one every N traced
instructions on that vCPU, counted independently per vCPU. Chunk files
are named `trace_vcpu<V>_c<KKKKK>.raw.zst` (`_c` = contiguous chunk,
0-indexed, zero-padded to 5 digits) instead of the plain
`trace_vcpu<V>.raw.zst` used when rotation is off, and each traced vCPU
gets a companion `trace_vcpu<V>_manifest.txt` recording every non-empty
chunk's start instruction, instruction count, and exact compressed
size. Every chunk is a standalone v3 file — no changes needed in
`trace_inspector`, `trace_filter`, or `converter/raw2champsim`. This
exists for the AArch64 capture kit's very large captures (the kit
defaults it on, at 100 M instructions/chunk); the plugin's own default
stays off so existing single-file x86_64 usage is unaffected. Full
naming/manifest details and the two bounded stateful-consumer caveats
(idle-filter reset and last-instruction `branch_taken` at chunk
boundaries): `plugin/README.md`.

## ChampSim Trace Format (Output)

> Historical note: this section used to describe vanilla ChampSim's 64-byte
> `input_instr` as a *target*, with the converter "not yet written". Both are
> long since done — the converter is `converter/raw2champsim` and the output is
> the **512-byte `input_instr_v2`** record.

`.champsim2.zst`, 512 bytes per instruction, three blocks:

- **Block 1** (64 B) — vanilla ChampSim layout: IP, `is_branch`/`branch_taken`,
  4 source + 2 destination register IDs, 4 source + 2 destination memory
  virtual addresses.
- **Block 2** (64 B) — v2 additions: source/destination **physical** addresses,
  per-operand access sizes, privilege bit, instruction type (INT/FP/SIMD), and
  8 reserved bytes — three of which now carry the branch-type contract below.
- **Block 3** (384 B) — memory values: up to 64 B per source memory op × 4, and
  per destination memory op × 2.

### Reserved bytes: the explicit branch-type contract

| byte | meaning |
|---|---|
| `reserved[0]` | ChampSim `branch_type` enum, **0-based** (`0`=DIRECT_JUMP … `7`=NOT_BRANCH) |
| `reserved[1]` | feature bits: `0x01` explicit branch type, `0x02` flags register recorded |
| `reserved[2]` | tracer identity: `2`/`3` = champsim-infra pintools, **`4` = this converter** |

**Key off the feature bit, never off `reserved[0] != 0`** — `0` is a valid
`BRANCH_DIRECT_JUMP`, so a zeroed record is byte-identical to one describing a
direct jump. The bit is set per record (including decode failures), so a
consumer testing it per record never silently falls back to inference for part
of a stream.

`is_branch` is a **boolean** (0/1). The 1..7 type code lives in `reserved[0]`.

Direction is taken from the **type**, not from next-IP geometry: unconditional
transfers are taken by definition; only conditionals use the lookahead. Full
rationale, per-instruction classification table, and the x86/AArch64 status
split: **`docs/branch-type-contract.md`**.

ChampSim must be invoked with `--trace-version 2` for these traces.

## Build gotchas on this host

Both of these fail in ways that point at the wrong culprit:

- **`CC` resolves to `aarch64-conda-linux-gnu-cc`.** A plain `make` builds the
  plugin with a cross-compiler for the wrong architecture and dies on
  `zstd.h: No such file or directory` — because the cross-compiler has its own
  sysroot, not because zstd is missing. **Always `make CC=gcc`.**
- **conda's glib is unusable here** — its `glibconfig.h` is aarch64-targeted and
  mismatches `sizeof(size_t)`. The system `libglib2.0-dev` is required.

The **plugin only loads in system-emulation mode**; it refuses to run under
`qemu-x86_64` (linux-user).