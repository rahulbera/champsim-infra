# tracer/pintool/scripts/

Host-side run recipes that drive a built pintool against RocksDB. They are
recipes, not a pipeline — each one runs a single configuration end to end:
build/load the DB, warm it untraced, then attach PIN and sample.

The RocksDB **driver** they run is workload source and lives in
`tracer/rpoint-cs/workloads/rocksdb/`.

## The scripts

Two generations. The 20 M-record v3 set is the production matrix; the 5 M ones
came first.

| script | records | read % | zipf α | cache | tracer |
|---|---|---|---|---|---|
| `run_prod_v3_n20M_rd95_zipf08.sh` | 20 M | 95 | 0.8 | 16 GB | v3 |
| `run_prod_v3_n20M_rd50_zipf08.sh` | 20 M | 50 | 0.8 | 16 GB | v3 |
| `run_prod_v3_n20M_rd95_zipf06.sh` | 20 M | 95 | 0.6 | 12 GB | v3 |
| `run_prod_v3_n20M_rd50_zipf06.sh` | 20 M | 50 | 0.6 | 12 GB | v3 |
| `run_prod_v3_read95_zipf.sh` | 5 M | 95 | — | 8 GB | v3 |
| `run_prod_v3_read50_zipf.sh` | 5 M | 50 | — | 8 GB | v3 |
| `run_prod_read95_zipf.sh` | 5 M | 95 | — | 8 GB | **v2** |

Common to the 20 M set: 1 KB values, 3 samples/thread of 1e9 instructions,
500 M-instruction inter-sample skip, 20 min untraced warmup, 60 min ROI budget,
4 traced worker threads.

Two chain wrappers run a pair sequentially under one `nohup` (~2.7 h each), so
the rd95 and rd50 halves of a matrix row finish unattended:

| wrapper | runs |
|---|---|
| `run_prod_v3_n20M_chain.sh` | `…rd95_zipf08` then `…rd50_zipf08` |
| `run_prod_v3_n20M_chain_zipf06.sh` | the α=0.6 pair |

## Before running one

Three paths default to the lab host and will not exist elsewhere. The first two
are overridable; the third is edited in the script.

```bash
PIN=<pin-kit>/pin \
TRACER=../pin/obj-intel64/champsim_tracer_mt_roi_v3.so \
bash run_prod_v3_n20M_rd95_zipf08.sh
```

- `PIN` — defaults to a kit under `/home/rahbera/softwares/…`
- `TRACER` — defaults to `/home/rahbera/arishem/champsim/tracer/…`, a path that
  predates this repo layout. Build with `../pin/make_tracer.sh` and point at the
  result.
- `DBDIR` — hardcoded to `/mnt/sherlock/rahbera/workloadzoo/rocksdb-data/${TAG}`.
  The DB is tens of GB; it is not meant to live beside the repo.

Each script `cd`s to its own directory and writes to `traces/${TAG}/`, so output
lands in `tracer/pintool/scripts/traces/` — gitignored.

## Why RocksDB is traced with PIN and not QEMU

It is a standalone C++ program with little kernel-mode work, so QEMU's 50-150×
full-system slowdown buys nothing. The mapping for every workload is in
`tracer/rpoint-cs/docs/workloads/README.md`.

Note the trap that shaped the v2 configuration: RocksDB v1's own success
criterion was a block-cache hit rate above 90%, and it achieved 97.40% — which is
a statement that the workload never reached DRAM. The 20 M-record runs size the
cache at roughly 60-80% of the raw data instead; v2 measured 34.33%. See
`tracer/rpoint-cs/scripts/rocksdb/README.md`.
