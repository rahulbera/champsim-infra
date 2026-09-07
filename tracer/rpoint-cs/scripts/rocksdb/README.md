# scripts/rocksdb/

RocksDB v2. Five traces in the catalogue.

| file | stage |
|---|---|
| `boot_rocksdb_kvm.sh` | boot `rocksdb-guest.qcow2` under KVM, install/warm |
| `launch_tcg_rocksdb.sh` | restore under TCG (`MODE=bare|profile|capture`) |
| `convert_one_rocksdb.sh` | filter → convert → sanity-check one window |

All three were called `boot_kvm.sh`, `launch_tcg.sh` and `convert_one.sh` until
2026-09-07 — unnamed because they came first, not because they were generic. They
reference `rocksdb-guest.qcow2` and `traces/rocksdb_v2` throughout. See
`../README.md` for why that was a hazard.

## Why there is a v2

**v1 was cache-resident and did not exercise the memory system.** Its spec's own
success criterion was "block cache hit rate > 90% after warmup" and the flagship
run hit **97.40%** — which is a statement that the workload never reached DRAM.

v2's measured steady state: block-cache hit rate **34.33%** (223,258 hits /
427,102 misses). Trace profile ~43% kernel, ~50% memory ops, ~17.5% branch,
`decode_fail 0`.

## Recorded caveat

`SGAP=2,695,565,031` came from the plugin's exit-time hint, before `sgap.py`
existed. Coverage is **86.35%** of the profiled trajectory rather than ~100%: the
hint cost about 14% of the run. The traces are valid; this is representativeness,
not correctness. Recapture is the researcher's call.

Note also that the traced thread is warmed by three **untraced** sibling threads,
while ChampSim simulates one core.
