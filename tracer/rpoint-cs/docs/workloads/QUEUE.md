# Capture queue — agreed, not yet started

Standing constraint (researcher, verbatim): *"we want to capture
memory-intensive traces from these workloads, but NOT at a cost of an
unrealistic deployment scenario."*

## In flight

**PostgreSQL / TPC-H SF=10** — the database category of the OSDI'24 taxonomy.
Order fixed by the researcher: **Q1, Q9, Q18, Q21** (Q21 last priority).
3 windows each. See `postgres/postgres-tpch-campaign-log.md`.

## Agreed 2026-09-06, in order, to start after TPC-H

### 1. Spark round 2 — `naive-bayes`, then `dec-tree`

Renaissance 0.16.1 `apache-spark` group has **eight** benchmarks; the v1
campaign captured only `page-rank`. The gap this fills is not "another
algorithm" — it is **the other half of Spark's execution engine**:

- `page-rank` is the *only* one of the eight that uses the raw **RDD API**.
  It traced as JVM-object pointer-chasing over a heap graph: 95.09% user,
  186.4 MIPS, the most compute-pure workload in the corpus.
- The other seven run **Spark ML on DataFrames → Catalyst → Tungsten
  whole-stage codegen**, which generates Java source at runtime, compiles it
  with Janino (`janino-3.1.9.jar` is in the module's dependency set), and
  operates on packed off-heap `UnsafeRow` buffers. Sequential scans over
  unsafe rows plus runtime code generation and re-JIT — a different access
  pattern, not a different algorithm.

Chosen, with their default sizing read from `benchmarks.properties`:

| bench | why | sizing |
|---|---|---|
| `naive-bayes` | largest input by construction; only one defaulting to every core; long sequential sparse scans | `copy_count=8000`, `spark_thread_limit=$cpu.count` |
| `dec-tree` | irregular histogram aggregation, much branchier control flow | `copy_count=100`, `spark_thread_limit=6` |

Not chosen (recorded so the reasoning is not re-derived): `log-regression`
(copy_count=400, 20 iterations over a cached DataFrame — a resident,
repeatedly-rescanned working set, the strongest runner-up); `movie-lens`
(real `ratings.csv`, 12-config ALS sweep, shuffle-heavy); `als`; `gauss-mix`
(dense BLAS); `chi-square` (1.5M points, 4 threads — smallest).

**Unmeasured.** The table above is configuration, not behaviour. Screen each
under KVM first — peak RSS plus CPU-bound fraction from two `/proc/stat`
samples — the same screen used on the TPC-H queries.

Each Spark workload keeps `java-guest.qcow2` in use, so the deferred ~31 GiB
snapshot reclaim (`dc_cass_c`, `dc_kafka_a`) stays deferred. 454G free — no
pressure.

### 2. Renaissance web group — `finagle-http`, `finagle-chirper`

Requested by the researcher on 2026-09-06, with an **explicit change to the
acceptance criterion**:

> "The finagle workloads are more interesting from control-flow perspective:
> they may or may not be interesting from memory perspective. But that's fine.
> These traces may come in handy for new studies."

So these two are accepted **on control-flow grounds alone**. Do not screen them
out for a small footprint, and do not treat a low memory fraction as a defect.
The deployment-realism half of the standing constraint still applies; the
memory-intensity half is waived for these two, by the researcher's decision.

Practical consequence: the reject band (`branch < 10% AND mem > 70%`) is a
memory-side screen and a branch-heavy workload cannot trip it, so no conflict.
Expect the opposite end of the corpus from Spark `page-rank` and PostgreSQL Q1.

Sizing: `finagle-http` rep=12 ("many small HTTP requests to a Finagle HTTP
server"), `finagle-chirper` rep=90 ("simulates a microblogging service").
Both are in the `web,twitter-finagle` group and share the java guest.

## Recorded, not scheduled

- **h2o** — DaCapo Chopin's rank-1 by LLC misses per M-instr (8506); would fill
  the ML category. Never requested; recorded so it is not lost.
- **`db-shootout`** — Renaissance `database` group (Chronicle Map, MapDB, H2
  MVStore). Overlaps the KV-store category already covered by memcached,
  Redis, RocksDB and MongoDB.
- **Redis (58.92%) and RocksDB (86.35%) trajectory coverage** — both used the
  plugin's buggy exit-time gap hint before `sgap.py` existed. The traces are
  VALID; this is representativeness, not correctness. Recapture is the
  researcher's call.

---

# Follow-ups agreed 2026-09-07 (post-campaign reorganisation)

`scripts/`, `docs/workloads/` and the kratos2 catalogue now all agree: per
workload, with `renaissance/` as parent and `spark/` a benchmark under it.
Both items below are done; kept for the record of what was changed and why.

## 1. Mirror the new hierarchy in `docs/workloads/` — **DONE 2026-09-07**

`docs/workloads/renaissance/` now nests `spark/`, `naivebayes/`, `dectree/`,
`finagle-http/` and `finagle-chirper/`, matching `scripts/renaissance/`.
The manifests moved with their benchmarks and lost their redundant
`renaissance-` prefix. One trap worth recording: the campaign-log headers use
`../../verification/…`, so moving `spark-campaign-log.md` one level deeper
required re-pointing it to `../../../verification/…`.

## 2. Regroup the kratos2 catalogue — **DONE 2026-09-07**

`version2.1/` now nests by benchmark, matching `scripts/` and `docs/workloads/`:

```
dacapo/{cassandra,kafka,tomcat}/                            11 traces
renaissance/{spark,naivebayes,dectree,
             finagle-http,finagle-chirper}/                 15 traces
memcached/ mongodb/ postgres/ redis/ rocksdb/               unchanged
```

The prediction held: **`CHECKSUMS.sha256` needed no edit**, 215 lines before and
after, because it records bare basenames — a trace's directory is not part of its
identity. The six per-directory `.sha256` files moved with their traces; six
tlists were repointed.

`mv` within one NFS filesystem is a rename, so the moves were instant and no data
was copied. Audited afterwards anyway, because "should be safe" is a prediction:

```
tlist paths resolve      ok=59 missing=0
re-checksum moved traces ok=26 mismatch=0 not-catalogued=0
CHECKSUMS.sha256         215 lines, untouched
```

One process note. The first path check reported `ok=58 missing=0` against 59
paths: the path file had no trailing newline, so `while read` silently dropped
the last one — and would have reported success either way. Same class as the
defects in `../../verification/2026-09-07-capture-campaigns-findings.md` §5.1,
hit while verifying a move made because of that document. The audit script now
carries `[ -n "$p" ] || continue` and writes a trailing newline.

The open question about `dacapo/` was answered yes and done in the same pass:
once `renaissance/` nested, `dacapo/` was the only place the three trees
disagreed.
