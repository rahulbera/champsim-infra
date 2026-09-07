# pintool/ — Intel PIN trace generator

The PIN-based tracer that *produces* ChampSim traces. You attach it to a real
x86-64 workload with `pin -t …`; it records the executed instruction stream
inside a Region of Interest (ROI) and writes a zstd-compressed ChampSim trace
that the simulator (and the rest of this infra) then consumes.

This is the front of the pipeline — everything in `scripts/`, `tools/`, and
`regression/` operates on the traces this directory generates.

## What's in here

| File | What it is |
|------|------------|
| `champsim_markers.h` | Header-only ROI markers. Include it in the workload you want to trace and bracket the hot region with `champsim_roi_begin()` / `champsim_roi_end()`. |
| `champsim_tracer_mt_roi_v2.cpp` | The v2 tracer: emits the extended 512-byte ChampSim record (`input_instr_v2`) — virtual addrs, per-operand access sizes, instruction type, and load/store **values**. |
| `champsim_tracer_mt_roi_v3.cpp` | The v3 tracer: same trace format as v2 (bit-identical output for the same workload), plus knobs needed for **multi-threaded** workloads (master/orchestrator skipping, registered-worker gating). |
| `make_tracer.sh` | Build entry point. Sets `PIN_ROOT` / `ZSTD_HOME`, then builds the v2 and v3 `.so` pintools. |
| `makefile`, `makefile.rules` | PIN's standard tool makefiles. `makefile.rules` adds `$(ZSTD_HOME)/lib/libzstd.a` to the link. **Don't hand-edit `makefile`** (it's PIN boilerplate). |

Build artifacts land in `obj-intel64/` (gitignored).

## Prerequisites

- **Intel PIN 4.0** — `make_tracer.sh` points `PIN_ROOT` at the local PIN 4.0
  kit. The tracer sources were migrated from PIN 3.31 to the PIN 4.0 API
  (namespaced `LEVEL_BASE::REG_RCX`, VSIB gather/scatter handling); build them
  with the matching kit.
- **A zstd build** at `ZSTD_HOME` (default `/home/rahbera/local`) — the tracer
  links `libzstd.a` for online compression.
- Linux, x86-64, GCC/Clang. The markers in `champsim_markers.h` need only a
  C99/C++11 compiler — no PIN required to *compile a workload* against them.

## Build

`PIN_ROOT` and `ZSTD_HOME` are environment-overridable; the defaults in
`make_tracer.sh` are the lab host's paths and will not exist elsewhere.
`ZSTD_HOME` must contain `include/zstd.h` and `lib/libzstd.a` — symlinks to a
system zstd work fine.

```bash
cd tracer/pintool
PIN_ROOT=/path/to/pin-4.0-kit ZSTD_HOME=/path/to/zstd bash make_tracer.sh
# -> obj-intel64/champsim_tracer_mt_roi_v2.so
# -> obj-intel64/champsim_tracer_mt_roi_v3.so
```

Two things bite here:

- **A conda environment breaks the build.** PIN derives its own compiler
  wrapper from `$CXX` (`makefile.unix.config`: `PIN_WRAPPER_GCC := $(patsubst
  %g++,%gcc,$(CXX))`), so a conda `CXX` propagates straight into `pin-gcc` and
  fails with `unrecognized command-line option '-m64'`. Strip the toolchain
  vars: `env -u CXX -u CC -u CXXFLAGS -u CFLAGS -u CPPFLAGS -u LDFLAGS bash
  make_tracer.sh`.
- **`makefile.rules` must name the zstd include path explicitly.** PIN builds
  tools against its own musl CRT, so `/usr/include` is not searched and
  `zstd.h` is invisible even when installed system-wide.

## Step 1 — instrument the workload

Include the header and mark the region you care about. The markers compile to a
"magic NOP" (`xchg %rcx, %rcx` with an opcode in RCX) that the tracer detects;
without PIN they are true no-ops, so an instrumented binary still runs normally.

```c
#include "champsim_markers.h"

int main() {
    load_inputs(...);          // setup — NOT traced

    champsim_roi_begin();      // tracing starts
    run_kernel(...);           // hot region — traced
    champsim_roi_end();        // tracing ends

    write_results(...);        // teardown — NOT traced
}
```

For **multi-threaded** workloads with the **v3** tracer, each foreground worker
thread should additionally call `champsim_register_worker()` once it is pinned
and ready. Combined with `-trace_only_registered_workers 1`, this keeps
background pool threads (RocksDB compaction/flush, OpenMP workers, …) out of the
trace and out of the sampling-timing accounting.

> The marker opcode constants (`CHAMPSIM_ROI_BEGIN=1`, `_END=2`,
> `CHAMPSIM_REGISTER_WORKER=3`) are shared between the header and the tracer
> `.cpp`. If you change them in one place, change them in both.

## Step 2 — run the tracer

```bash
pin -t obj-intel64/champsim_tracer_mt_roi_v3.so \
    -use_markers 1            \
    -o traces/faiss_hnsw      \
    -t 10000000               \
    -n 1                      \
    -- ./your_workload --its --args
```

### Knobs

Pass these after `-t <tool>.so` and before `--`. Defaults in parentheses.

| Knob | Default | Meaning |
|------|---------|---------|
| `-o <base>` | `champsim_mt` | Output base name. Files: `<base>_t<tid>[_master]_s<sid>.champsim2.zst`. |
| `-use_markers <0\|1>` | `0` | `1`: gate tracing on the ROI markers (recommended). `0`: legacy skip-based mode (use `-i`). |
| `-i <N>` | `0` | Initial instructions to skip at thread start (skip-based mode only; ignored when `-use_markers 1`). |
| `-s <N>` | `0` | Instructions to skip *between* sample windows. |
| `-t <N>` | `1000000` | Instructions to trace per sample window. |
| `-n <N>` | `1` | Max sample windows per thread (`0` = unlimited). |
| `-offsets <a,b,c>` | *(unset)* | Collect a region of `-t` instructions at each **absolute** instruction offset, all in **one pass**. Supersedes `-i`/`-s`/`-n`. See below. |
| `-trace_tid <N>` | `-1` | Trace only this **PIN** thread id (`0` = main). `-1` traces every thread. |
| `-main_only <0\|1>` | `0` | Trace only the main/root thread. |
| `-zstd_level <1-22>` | `1` | Compression level. **Keep at 1** (≤3) — higher levels bottleneck PIN. |
| `-values <0\|1>` | `1` | Capture load/store values via `PIN_SafeCopy`. `0` zero-fills the value slots (faster). |
| `-exit_on_done <0\|1>` | `0` | Call `PIN_ExitApplication` once every tracing thread hits its quota / ROI-end, so post-ROI work doesn't run under PIN. |
| `-skip_master_tracing <0\|1>` | `0` | **(v3)** Treat the `roi_begin`-firing thread as an orchestrator that opens no trace and isn't counted as a worker. Use when the master only spawns/joins workers. |
| `-trace_only_registered_workers <0\|1>` | `0` | **(v3)** Only threads that called `champsim_register_worker()` may enter TRACING. Keeps background pool threads out. |

### `-offsets` — collecting SimPoint regions in one pass

A SimPoint run yields several representative regions at arbitrary increasing
offsets. Collecting them with `-i` alone costs **one full process replay per
region**, and the fast-forward — not the recording — dominates: seeking to a
simpoint 2.2 trillion instructions deep takes ~30 minutes, while the 300 M
instructions actually recorded take seconds. `-offsets` turns N seeks-from-zero
into a single monotone sweep.

```bash
pin -t obj-intel64/champsim_tracer_mt_roi_v2.so \
    -use_markers 0 -offsets 1200000000,4500000000,9100000000 \
    -t 300000000 -o spec_bench -- ./workload
# -> spec_bench_t<tid>_s0.champsim2.zst  (region at 1.2 B)
#    spec_bench_t<tid>_s1.champsim2.zst  (region at 4.5 B)
#    spec_bench_t<tid>_s2.champsim2.zst  (region at 9.1 B)
```

Every misuse is rejected at startup, before instrumentation is installed, and
writes no output — a trace of the *wrong* region is indistinguishable from a
correct one once written:

| Rejected | Message |
|---|---|
| Non-numeric / empty token | `malformed list '…'` |
| Not strictly increasing | `-offsets must be strictly increasing` |
| Consecutive offsets closer than `-t` | `regions overlap: …` |
| Combined with `-use_markers 1` | `cannot be combined with -use_markers 1` |
| Combined with `-i` or `-s` | `-offsets supersedes -i` / `-s` |

Note the region count comes from the list, so `-n` is implied and the
`max samples` line in the startup banner is the pre-override value — trust
`max_samples=` on the `Thread start:` line instead.

### `-trace_tid` — picking the thread that does the work

Instruction counters are **per-thread**, so an offset derived from one thread's
profile is meaningless applied to another. When the work happens in a worker
rather than the main thread, pin tracing to it with `-trace_tid <n>`; the
numbering matches SDE's per-thread bbv files (`.T.<n>.bb`). Unlike `-main_only`,
which is hardcoded to the root thread, this selects any single thread.

## Output

Each thread writes its own file:

```
<base>_t<os_tid>_master_s<sid>.champsim2.zst   # master thread — usually discard
<base>_t<os_tid>_s<sid>.champsim2.zst          # worker threads — keep
```

The `.champsim2.zst` suffix marks the 512-byte **v2** record format. Don't feed
these to a ChampSim configured for 64-byte v1 traces.

A per-run summary (instructions traced, dropped store values, scatter/gather
instructions seen, etc.) is printed at exit (`Fini`).

## v2 vs v3 — which to use

- **v2** — single-threaded (or `main_only`) workloads, e.g. a FAISS driver where
  the marker-firing thread *is* the worker.
- **v3** — multi-threaded workloads (e.g. a RocksDB driver). It's effectively a
  superset of v2: with every new knob at its default `0`, single-threaded
  behavior and output are identical to v2. The extra knobs exist to keep an
  orchestrator thread and background pool threads from distorting sampling.

The two tracers are the same code at a fixed line offset, and every record-format
change applies to both — they emit the same `.champsim2.zst` filename, so a fix
landing in only one would split that population into two silently incompatible
classes. (Strictly, the "bit-identical" claim has one exception predating this:
v3 flushes the JIT cache on the first thread's 0→1 tracing transition, which is
reachable only with ≥2 threads in marker mode.)

## Trace format note

The record layout is byte-for-byte `input_instr_v2` from
`champsim/inc/trace_instruction.h` (redefined locally so the pintool build
doesn't pull in simulator headers; a `static_assert` guards the 512-byte size).
Physical addresses and the privilege bit are **zero** under PIN — PIN only sees
virtual addresses. Loads capture their value at `IPOINT_BEFORE`, stores at
`IPOINT_AFTER` (no-fall-through stores leave the value zeroed and bump a counter
reported in `Fini`).

### `reserved[]` — the branch-type contract

Three of the eight `reserved` bytes carry meaning. The layout is unchanged (still
512 bytes), so old traces stay readable — they simply have these bytes zero.

| byte | meaning |
|------|---------|
| `reserved[0]` | `branch_type`, ChampSim's `branch_type` enum **verbatim**: 0 `DIRECT_JUMP`, 1 `INDIRECT`, 2 `CONDITIONAL`, 3 `DIRECT_CALL`, 4 `INDIRECT_CALL`, 5 `RETURN`, 6 `OTHER`, 7 `NOT_BRANCH`. Do not renumber. |
| `reserved[1]` | feature bitmask: `0x01` explicit branch type present, `0x02` flags register recorded. |
| `reserved[2]` | which tracer wrote the record (`2` or `3`) — both emit the same filename, so this is the only provenance a trace carries. |
| `reserved[3..7]` | zero, held for future use. |

A consumer must key off `reserved[1] & 0x01`, **not** off `reserved[0]` being
non-zero: `0` is a perfectly valid branch type (`DIRECT_JUMP`), so a pre-fix
trace of all-zero reserved bytes is indistinguishable from a trace of nothing but
direct jumps. There is deliberately no trace-format version bump — the layout did
not change, and a version asserted on the command line can be wrong in a way the
data cannot.

### Why branch type is recorded rather than inferred

ChampSim used to derive branch type from which registers appear in a record
(`inc/instruction.h`). That makes a *semantic* property depend on an *encoding*
accident — which registers happened to fit in the 2- and 4-slot arrays — and it
failed silently: because the tracers dropped the flags register, every
conditional branch matched the `BRANCH_DIRECT_JUMP` arm and had its direction
overwritten to "taken". ChampSim saw **zero** conditional branches, and all four
stock predictors reported identical MPKI because none was ever consulted. PIN
knows the answer exactly, so it is now written down.

### The flags register

Both tracers record the flags register, as a **source and a destination**. This
is not only for classification (`reserved[0]` handles that now) but for
dependency modelling: ChampSim gates execution on all source registers being
ready and starts the misprediction penalty when the branch completes, so a `jcc`
with no flags source is not gated by the `cmp` that computes its condition — it
resolves too early and misprediction cost comes out too low. Both sides are
required; a register that is read but never written is renamed to an
already-valid physical register and stalls nothing.

`Fini` reports how many register numbers were dropped for lack of a free slot,
split into real registers and flags, so the truncation cost is a measured number
per run rather than an assumption. On a 200k-instruction `/bin/ls` trace it is
270 drops — 0.135% of records.

### `is_branch` covers calls and returns

`is_branch` is set for **every** control transfer, including calls and returns,
which PIN's `INS_IsBranch()` excludes; they are also marked taken, which they
unconditionally are. Previously both fields were zero for calls and returns and
ChampSim papered over it by re-deriving the type itself — but once a consumer
trusts `reserved[0]`, a `BRANCH_DIRECT_CALL` carrying `branch_taken = 0` is
simply a wrong not-taken call.

**This shifts `is_branch` relative to v1 traces**, by roughly the call + return
count. Any tooling that counts branches from `is_branch` will report more than it
used to; count `reserved[0] != NOT_BRANCH` instead.
