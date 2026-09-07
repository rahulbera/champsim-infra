# scripts/

Host-side drivers for the QEMU snapshot/replay tracing pipeline, organised
**per workload**, mirroring `docs/workloads/`.

Every script that produced a trace in the kratos2 catalogue is kept here, even
where several are near-identical. That is deliberate: a catalogued trace should
be traceable to the exact file that made it, and each `convert_one_*` carries
the measured provenance for its workload in its header ("fields MEASURED, not
assumed"). Fifteen near-duplicate converters are a cheap price for that.

## Layout

```
common/        shared by everything: lib.sh, cpustr.sh, hmp.py, sgap.py,
               ship_trace.sh, convstat.sh, guestpin.sh, dfstat.sh,
               build_qemu_avxfix.sh
scylladb/      the original ubuntu-guest trio (7 vCPU, shard-per-core)
rocksdb/       boot/launch/convert for rocksdb-guest
redis/         + redis_theta_{prep,scout}.sh (the zipf-theta scouting pair)
mongodb/
dacapo/        ship_dacapo.sh, shared by all three
  cassandra/   java-guest
  kafka/       kafka-guest  (boot_java8g_*)
  tomcat/      tomcat-guest
renaissance/   boot_spark_kvm.sh + launch_tcg_spark.sh + run_ren_*.sh
  spark/         page-rank
  naivebayes/    dec-tree/    finagle-http/    finagle-chirper/
postgres/      TPC-H q1, q9, q18, q21
capture-kit/   AArch64 collaborators (self-contained, unchanged)
smoke-trace/   two-minute end-to-end pipeline check (self-contained, unchanged)
```

`renaissance/` is the parent because all five benchmarks share one guest and one
harness jar; Spark page-rank is a Renaissance benchmark like the others. See
`renaissance/README.md`.

## Path resolution — `common/lib.sh`

Every script resolves its own location and finds the rest of the tree from
there, so **the checkout is self-contained and relocatable**. Each begins:

```sh
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
```

and then has `SROOT` (this tree), `COMMON`, `RPCS` (`tracer/rpoint-cs`, for
`plugin/` and `converter/`), `REPO` (`champsim-infra`, for `tools/`), plus
`CPUSTR`/`QEMU_FIXED`/`IMAGES`/`MON` from `cpustr.sh`.

`W` is the **data** root — `traces/`, `logs/`, `run/`, `out/`, `images/` — which
deliberately lives outside the repo. It defaults to `$HOME/work/new-tracing` and
is overridable: `W=/scratch/foo bash postgres/run_pg_capture.sh`.

The `SROOT` walk is depth-independent on purpose, so a script can move between
`postgres/` and `dacapo/tomcat/` without its references breaking.

**Why this exists:** during the campaigns these scripts lived flat in the working
directory and referred to each other by absolute path. The committed copies
inherited those references, so the repo could not run itself — 26 scripts called
back into `$HOME/work/new-tracing`, and `cpustr.sh`, which carries the
load-bearing `kvmclock=off` CPU model, had never been committed at all.

## Two name collisions the flat layout was hiding

Both were found while reorganising, and both would have caused silent damage:

- **`boot_kvm.sh` was two unrelated scripts.** The committed copy booted
  `ubuntu-guest.qcow2` with 7 vCPUs (ScyllaDB, shard-per-core); the working copy
  booted `rocksdb-guest.qcow2` with 6. Syncing either direction would have
  destroyed the other. They are now `scylladb/boot_scylla_kvm.sh` and
  `rocksdb/boot_rocksdb_kvm.sh`.
- **`boot_kvm.sh`, `launch_tcg.sh`, `convert_one.sh` were not generic.** All
  three referenced `rocksdb-guest.qcow2` / `traces/rocksdb_v2`; they were
  unnamed only because they came first. Filed as "common" they would have been a
  standing trap — someone editing `launch_tcg.sh` expecting a generic driver
  would have silently reconfigured RocksDB. Renamed with explicit suffixes.

Also: the committed `run_tomcat_ship.sh` still had the `grep -c … || echo 0`
trap (which prints `0\n0` and makes numeric tests a shell error); the working
copy had the fix. The fixed copy is the one carried forward.

## Shipping

`common/ship_trace.sh` is the current driver, parameterised over
`DEST`/`BENCH`/`NEW`/`NWIN`/`EXPECT`. It superseded the four per-workload
`ship_*.sh` during the PostgreSQL campaign and shipped everything from Q1
onward. The originals (`redis/ship_redis.sh`, `mongodb/ship_mongo.sh`,
`dacapo/ship_dacapo.sh`, `renaissance/spark/ship_spark.sh`) are kept as the
historical record of how their traces were shipped; they hardcode what
`ship_trace.sh` parameterises.

The ship order is non-negotiable and every variant implements it:
hash locally → rsync → **`sha256sum -c` ON kratos2** → append to CHECKSUMS
(bare basenames, guarded by an `EXPECT` line-count precondition) → and only then,
as a separate deliberate step, reclaim.
