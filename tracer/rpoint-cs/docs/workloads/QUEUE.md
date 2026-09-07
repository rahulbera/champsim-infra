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

`scripts/` has been reorganised per workload, mirroring this directory
(`docs/workloads/`), with `renaissance/` as the parent and `spark/` as one
benchmark under it. Two consumers of that structure still need updating.

## 1. Mirror the new hierarchy in `docs/workloads/`

`docs/workloads/` currently has `spark/` and `renaissance/` as siblings, which
splits one guest and one harness jar across two directories. `scripts/` now
nests them. Bring the docs into line:

```
docs/workloads/renaissance/
    (guest + harness notes, currently split across spark/ and renaissance/)
    spark/              <- spark-campaign-log.md, spark-v1-manifest.txt
    naivebayes/  dectree/  finagle-http/  finagle-chirper/
                        <- the four renaissance-*-manifest.txt files
```

Cheap and self-contained: these are markdown and manifest files with no
cross-references outside `docs/`. Check the tlist header comments afterwards,
since several point at `docs/workloads/<x>/` paths.

## 2. Regroup the kratos2 catalogue

Currently `version2.1/` has `spark/` (page-rank + naive-bayes + dec-tree) and
`finagle/` (the two web workloads), which groups by *what shipped when* rather
than by what the workloads are.

**This is far cheaper than it looks, and the reason is worth stating: the
catalogue records BARE BASENAMES.** Verified 2026-09-07 —
`CHECKSUMS.sha256` lines are `<sha256>  <basename>` with no directory
component, so **moving a trace between directories does not invalidate the
catalogue at all**. What actually has to change:

- the per-directory `*.sha256` files move with their traces;
- the `path:` field in `scripts/tlists/*.yml` (14 files, 59 entries).

`CHECKSUMS.sha256` itself needs no edit. Re-run the audit afterwards
(`ok=N mismatch=0 missing=0`) to confirm nothing was lost in the move.

Proposed target, matching scripts/ and docs/:

```
version2.1/renaissance/spark/            spark3.5.3_..._pagerank_...
version2.1/renaissance/naivebayes/       spark3.5.3_..._naivebayes_...
version2.1/renaissance/dectree/          spark3.5.3_..._dectree_...
version2.1/renaissance/finagle-http/     finagle24.2.0_..._finaglehttp_...
version2.1/renaissance/finagle-chirper/  finagle24.2.0_..._finaglechirper_...
```

Open question for the researcher: whether `version2.1/dacapo/{cassandra,kafka,
tomcat}` should be regrouped the same way — they are currently flat siblings
too. Not proposed here because nothing about them is misleading as-is.
