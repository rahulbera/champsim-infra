# tracer/pintool/

The Intel PIN tracer, split into what builds the tool and what runs workloads
under it.

| directory | what's in it |
|---|---|
| `pin/` | the pintool itself: `champsim_tracer_mt_roi_v{2,3}.cpp`, `champsim_markers.h`, the build (`makefile`, `makefile.rules`, `make_tracer.sh`) and the tracer reference. **Start at `pin/README.md`** for the knobs, the record format and the ROI marker contract. |
| `scripts/` | host-side run recipes that drive a built pintool against a workload. Currently the nine RocksDB production runs (`run_prod_*.sh`). |

## Which tracer am I looking at?

This repo has **two** trace producers and they are easy to confuse:

- **`tracer/pintool/`** (here) — Intel PIN. For standalone C++ programs with no
  significant kernel-mode work: FAISS, DLRM, RocksDB. ROI is bracketed by "magic
  NOP" markers from `pin/champsim_markers.h`.
- **`tracer/rpoint-cs/`** — QEMU snapshot/replay, full-system. For anything whose
  kernel time matters or that cannot be instrumented: memcached, Redis, MongoDB,
  the DaCapo/Renaissance JVMs, PostgreSQL.

Both emit the same 512-byte `input_instr_v2` record, so a trace's filename does
not tell you which produced it. `tracer/README.md` has the mapping;
`tracer/rpoint-cs/docs/workloads/README.md` states it per workload.

## Building

```bash
cd tracer/pintool/pin
env -u CXX -u CC -u CXXFLAGS -u CFLAGS -u CPPFLAGS -u LDFLAGS \
  PIN_ROOT=<pin-kit> ZSTD_HOME=<dir with include/zstd.h + lib/libzstd.a> \
  bash make_tracer.sh
```

The `env -u` is not optional: conda exports a cross-toolchain `CXX`, and PIN
derives its compiler wrapper from `$CXX`
(`PIN_WRAPPER_GCC := $(patsubst %g++,%gcc,$(CXX))`), so a conda `CXX` reaches
`pin-gcc` and fails on `-m64`. See CLAUDE.md, "Environment gotchas".

`make_tracer.sh` lives in `pin/` rather than `scripts/` because it builds the
tool: it runs `make obj-intel64/…` relative to its own directory and depends on
`makefile.rules` beside it.

## `scripts/` — a note on the RocksDB runs

`scripts/run_prod_*.sh` default to
`TRACER=/home/rahbera/arishem/champsim/tracer/obj-intel64/champsim_tracer_mt_roi_v3.so`,
a path on the lab host that does not exist on every machine. It is overridable:

```bash
TRACER=$PWD/../pin/obj-intel64/champsim_tracer_mt_roi_v3.so bash scripts/run_prod_v3_n20M_rd95_zipf08.sh
```

They lived under `tracer/rpoint-cs/workloads/rocksdb/` until 2026-09-07, beside
the RocksDB *driver* they run — which put PIN scripts inside the QEMU tracer's
directory. The driver sources stay there (they are guest-side workload code);
these are host-side PIN recipes and belong here.
