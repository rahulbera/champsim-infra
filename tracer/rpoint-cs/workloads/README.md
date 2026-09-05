# workloads/ — the capture recipes, in git

The 2026-09-04 audit's central finding was that the v1 campaign's recipe existed
only as shell scripts on one machine: *"none of the 20 M / α=0.8 / α=0.6
iterations were committed to any repo... The spec in git describes a
configuration nobody ran. Commit the run scripts, or the git history documents a
fiction."*

This directory is the answer. Everything needed to reproduce the 2026-09-05
captures lives here: the drivers, the boot and capture scripts, and the shared
CPU-model string that makes a KVM snapshot restorable under TCG.

| | |
|---|---|
| `cpustr.sh` | the TCG-compatible CPU model + patched-QEMU path, sourced by every launcher. A KVM snapshot cannot restore under `-cpu host`. |
| `rocksdb/rocksdb_driver_v2.cpp` | RocksDB driver with **two fixes over v1**: per-record derived values, and `--attach` |
| `mongodb/mongo_driver.c` | MongoDB driver, libmongoc, deliberately mirroring the RocksDB one phase-for-phase |
| `*/boot_*_kvm.sh` | boot the guest under KVM (load, warm, snapshot happen here — never under TCG) |
| `*/launch_tcg_*.sh` | restore the snapshot under TCG with the tracer plugin; `MODE=profile` or `MODE=capture` |
| `*/convert_one_*.sh` | one window: filter → convert → validate → verdict |

**Redis needs no driver** — `memtier_benchmark` drives it natively, which is why
it was the cheapest of the three to stand up.

The two QEMU patches this path requires are in `../patches/`. The campaign
narratives, including every dead end, are in `../docs/workloads/*/`.
