# Pipeline Stages Summary

## Stage 1: VM Setup ✅ COMPLETE

**Goal:** QEMU VM with Memcached + YCSB + memtier_benchmark installed.

**Key decisions made:**
- Used Ubuntu Server 24.04 cloud image (headless, no GUI installer needed)
- Memcached instead of Redis (natively multi-threaded workers)
- memtier_benchmark for run phase (native C, instant startup vs Java YCSB)
- YCSB kept only for data loading phase

**Guest tuning applied:**
- ASLR disabled (`kernel.randomize_va_space=0`)
- Swap disabled
- Transparent Huge Pages disabled
- Unnecessary services disabled (snapd, unattended-upgrades, etc.)

## Stage 2: Snapshot Creation ✅ COMPLETE

**Goal:** Golden VM snapshots at the beginning of the region of interest.

**Key decisions made:**
- 5 vCPUs: 4 for Memcached workers (pinned), 1 for benchmark + OS
- YCSB loads 2.25M records (~6 GB) under KVM (fast)
- Two snapshots: `roi_ready` (idle) and `roi_running` (benchmark active)
- `roi_running` eliminates human timing dependency — benchmark already running
- Snapshots taken with `-cpu host,-kvmclock` (attempted fix, insufficient)

**Data footprint:** 2,250,000 records × 10 fields × 400 bytes ≈ 6 GB

## Stage 3: TCG Tracing Plugin ✅ COMPLETE

**Goal:** QEMU TCG plugin that dumps raw instruction traces with memory values.

**Key decisions made:**
- Two-stage architecture: lean online capture + rich offline conversion
- Online captures only runtime-observable info (IP, bytes, privilege, mem addr/size/value)
- Offline derives registers, branch info, ChampSim format (not yet written)
- zstd streaming compression at level 1 (reduces I/O, net performance win)
- Memory values via QEMU 9.2 `qemu_plugin_mem_get_value()` (up to 128-bit)
- Privilege inferred from IP (>= 0xFFFF800000000000 = kernel)
- Per-vCPU state, no locking, 16 MB uncompressed buffers

**Plugin features:**
- Configurable vCPU selection (`vcpus=0-3`)
- Configurable instruction limit per vCPU (`limit=200000000`)
- Configurable output directory (`outdir=/path`)
- Format version 2 (with values)
- File magic: `CSTF`

**Tools built:**
- `champsim_tracer.so` — the tracing plugin
- `trace_inspector` — validates and inspects raw traces (supports .raw and .raw.zst)

## Stage 4: TCG Tracing Run ✅ COMPLETE

**Goal:** Load snapshot under TCG with plugin, generate traces.

**The kvmclock blocker was resolved.** QEMU was patched to instantiate the
`kvmclock` device under TCG so the VMState handler exists and the snapshot
section loads; `docs/pipeline/kvmclock-patch-details.md` is the full writeup,
and `CLAUDE.md` records it as resolved. Read that document as *how the fix
works*, not as an open problem.

*Historical note — the original blocker text:* "KVM snapshot contains `kvmclock`
device state that TCG can't load." Kept because the analysis of the snapshot
stream format is still the reference for any similar section mismatch.

**Two boot paths now exist**, and they differ in whether they use a snapshot:

- `scripts/boot_tcg_trace.sh` — the snapshot path (`-loadvm <checkpoint>`), used
  by the Memcached/ScyllaDB workloads. This is the path the kvmclock patch
  unblocked.
- `images/boot_tcg_trace.sh` — the SWE-agent path: **no snapshot at all**. It
  boots the provisioned qcow2 disk directly under TCG (`-accel tcg -cpu max
  -smp 4 -m 8G`, plugin at `vcpus=1`), which sidesteps KVM→TCG device-state
  mismatch entirely at the cost of a slow emulated boot.

## Stage 5: Offline Converter ✅ COMPLETE

**Goal:** Convert raw traces (.raw.zst) to extended ChampSim trace format.

Shipped as `converter/`:

- `raw2champsim.c` — the driver; reads raw v2, v3/x86_64 and v3/aarch64.
- `decode_x86.c` — x86-64 decoder: registers, branch identification, explicit
  branch type. Pinned by `tests/decode_x86_test.c` (30 rows of real `as --64`
  encodings).
- `decode_aarch64.c` — A64 decode via Capstone 4.0.2, with its own golden test.
- Branch taken/not-taken derived from the IP sequence; register-ID mapping
  frozen and documented in `converter/README.md`.
- Privilege bit and memory values carried through; kernel/idle filtering is a
  separate pass (`plugin/trace_filter`).

The branch-type half of the output is specified by
`docs/branch-type-contract.md`.

## Stage 6: ChampSim Integration — NOT PURSUED IN THIS REPO

**Original goal:** feed generated traces into an *extended* ChampSim for NUMA
simulation — extended trace reader, 4-core/2-socket configuration, vCPU→socket
mapping, NUMA-aware memory nodes.

**That is not what happened, and this stage will not be completed here.** The
NUMA framing belongs to the original Memcached study; the traces this repo now
produces are consumed by **stock ChampSim v2** via `champsim-infra`, and running
experiments on traces is explicitly out of this repo's scope (see the "Scope"
section of the top-level `README.md` — that tooling lives in
`/home/rbera/work/bpeval/run-assets/`). `run_capture_chain.sh` therefore ends at
`convert`.

The AArch64 simulator-side configuration (cache/uarch params for A64 traces)
remains genuinely unstarted, and is likewise a downstream repo's job.
