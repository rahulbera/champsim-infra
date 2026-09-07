# scripts/renaissance/spark/

Renaissance `page-rank` — the Spark big-data workload. Three traces.

Uses the shared guest and TCG launcher from `../`. The scripts here are the
page-rank-specific drivers, which predate the generic `../run_ren_*.sh`.

| file | stage |
|---|---|
| `run_spark_snap.sh` | wait for deep steady state (>=200 iterations), then `savevm` |
| `run_spark_profile.sh`, `run_spark_capture.sh` | profile and capture |
| `convert_one_spark.sh` | one window through the converter chain |
| `run_spark_ship.sh`, `ship_spark.sh` | ship (superseded by `common/ship_trace.sh`) |

## Why page-rank, and why it is different from its siblings

Chosen over `als` on **measured live set**: 149 MB vs 65 MB after GC, and RDD
iteration chases pointers over a *persisted* structure rather than transient MLlib
intermediates. Screened on behaviour, not on name.

It is also the **only one of Renaissance's eight `apache-spark` benchmarks that uses
the raw RDD API**. The other four traced here (`../naivebayes`, `../dectree`, and
the two finagle workloads) go through DataFrames → Catalyst → Tungsten codegen.
That difference is the whole reason round 2 was worth capturing — see `../README.md`.

## Measured

**268 JVM threads** — the largest of any workload in this corpus (cassandra 88,
kafka 101, tomcat 26) — all pinned to the traced vCPU, 0 unpinned, verified before
the snapshot and after the TCG restore.

3 windows x 1e9 spanning **99.86%**. Profile: 111,822,210,176 instructions,
**95.09% user**, 186.4 MIPS — the most user-heavy workload in the corpus.

```
w00000 79.2/20.8 user/kern, 18.1% branch, 40.4% mem
w00001 80.8/19.2, 17.1%, 40.6%
w00002 79.3/20.7, 18.5%, 45.2%
```

The 4.8-point memory spread was the widest measured until PostgreSQL q9 — it is
PageRank's iteration structure showing up as genuinely different memory behaviour
between windows 51.7e9 instructions apart.

## Recorded deviation

Spark runs in **local mode**, one JVM, no cluster. The traces contain Tungsten's
memory management, the shuffle machinery with disk spill, columnar batches and G1 —
but **not** network shuffle serialisation over TCP. Deliberate: a distributed Spark
under a ~35x TCG slowdown blows through every timeout it owns (executor heartbeat
10 s, `spark.network.timeout` 120 s, block-manager liveness). A heartbeat never sent
over a socket cannot be missed.

## Why this workload explains the sample_gap bug's survival

The hint's shortfall is `K*N*(1-f)/U`, so it scales with **kernel** fraction. At
95% user the broken hint would have covered 99.86% — indistinguishable from
correct. Redis, at ~39% user, lost 41% of its run to the same bug.
