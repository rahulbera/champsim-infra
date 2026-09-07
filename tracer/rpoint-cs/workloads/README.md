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
| `rocksdb/rocksdb_driver_v2.cpp` | RocksDB driver with **two fixes over v1**: per-record derived values, and `--attach` |
| `rocksdb/{Makefile,zipfian.h}` | its build and Zipfian generator |
| `mongodb/mongo_driver.c` | MongoDB driver, libmongoc, deliberately mirroring the RocksDB one phase-for-phase |
| `dacapo/{AvxCanary,VecCheck}.java` | the J1 gate: proof a JVM with C2-compiled AVX2/FMA survives a KVM→TCG restore |
| `dacapo/{meta-data,user-data}-java` | cloud-init seed for the Java guest |

## Scope, as of 2026-09-07

**This directory holds what runs INSIDE the guest, and how the guest is built.**
Host-side orchestration — `boot_*_kvm.sh`, `launch_tcg_*.sh`, `convert_one_*.sh`,
`cpustr.sh` — moved to `../scripts/<workload>/`, where the equivalents for every
later campaign already lived.

That split is the reconciliation of two answers to the same question. This
directory was created on 2026-09-05 in response to the audit quoted above; the
later campaigns (DaCapo, Spark, PostgreSQL, Renaissance) committed their recipes
to `../scripts/` instead, and for two days the same seven files existed in both
places, byte-identical and free to diverge. They now exist once, in
`../scripts/`, split from these by layer rather than by workload name.

The nine RocksDB `run_prod_*.sh` also left, to `tracer/pintool/scripts/`: they
drive the **PIN** tracer, not this one, and had no business inside the QEMU
tracer's directory.

**Redis needs no driver** — `memtier_benchmark` drives it natively, which is why
it was the cheapest of the three to stand up.

The two QEMU patches this path requires are in `../patches/`. The campaign
narratives, including every dead end, are in `../docs/workloads/*/`.
