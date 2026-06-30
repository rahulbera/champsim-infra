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

Edit the two paths at the top of `make_tracer.sh` if your kit/zstd live
elsewhere, then:

```bash
cd pintool
bash make_tracer.sh
# -> obj-intel64/champsim_tracer_mt_roi_v2.so
# -> obj-intel64/champsim_tracer_mt_roi_v3.so
```

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
| `-main_only <0\|1>` | `0` | Trace only the main/root thread. |
| `-zstd_level <1-22>` | `1` | Compression level. **Keep at 1** (≤3) — higher levels bottleneck PIN. |
| `-values <0\|1>` | `1` | Capture load/store values via `PIN_SafeCopy`. `0` zero-fills the value slots (faster). |
| `-exit_on_done <0\|1>` | `0` | Call `PIN_ExitApplication` once every tracing thread hits its quota / ROI-end, so post-ROI work doesn't run under PIN. |
| `-skip_master_tracing <0\|1>` | `0` | **(v3)** Treat the `roi_begin`-firing thread as an orchestrator that opens no trace and isn't counted as a worker. Use when the master only spawns/joins workers. |
| `-trace_only_registered_workers <0\|1>` | `0` | **(v3)** Only threads that called `champsim_register_worker()` may enter TRACING. Keeps background pool threads out. |

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
- **v3** — multi-threaded workloads (e.g. a RocksDB driver). It's a strict
  superset of v2: with every new knob at its default `0`, behavior and output are
  identical to v2. The extra knobs exist to keep an orchestrator thread and
  background pool threads from distorting sampling.

## Trace format note

The record layout is byte-for-byte `input_instr_v2` from
`champsim/inc/instruction.h` (redefined locally so the pintool build doesn't pull
in simulator headers; a `static_assert` guards the 512-byte size). Physical
addresses and the privilege bit are **zero** under PIN — PIN only sees virtual
addresses. Loads capture their value at `IPOINT_BEFORE`, stores at `IPOINT_AFTER`
(no-fall-through stores leave the value zeroed and bump a counter reported in
`Fini`).
