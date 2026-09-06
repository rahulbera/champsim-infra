# PostgreSQL / TPC-H — campaign log

Running log of the database-category effort. Enumerated, timestamped UTC,
appended as things happen, **dead ends and my own mistakes included**.

**Why this workload.** It is the last uncovered category in the OSDI'24 CXL
paper's taxonomy (§3.2: "Database: TPC-C on Silo and TPC-H on PostgreSQL").
Verified against the catalogue before starting rather than assumed: `postgres`,
`tpch` and `tpcc` all returned 0 rows in CHECKSUMS.sha256, while `ml/` and
`gap/` directories already exist.

**Why TPC-H on PostgreSQL and not TPC-C on Silo.** Silo is a 2013 research
prototype; tracing it would characterise a research artifact rather than a
deployed database. The standing constraint is memory intensity *without* an
unrealistic deployment. If OLTP is wanted later, TPC-C on PostgreSQL (BenchBase
or HammerDB) is the realistic route.

---

1. **2026-09-06 08:37Z — Guest built.** Fresh from the noble cloud image rather
   than an overlay on `java-guest.qcow2` — no reason to drag 24 GB of JDK and
   DaCapo into a PostgreSQL trace, and it leaves that backing chain free for the
   deferred snapshot reclaim. **`-m 12G`** (snapshot cost tracks touched guest
   pages; the 24 GB java guest cost 23.6 GiB per snapshot), 120 GB virtual disk,
   `< /dev/null` on the QEMU exec **by construction** — the second guest this
   campaign has launched already carrying that fix rather than needing it
   retrofitted after a Ctrl+D killed something.
   **PostgreSQL 16.15** (Ubuntu 24.04's stock package — a real deployment, not a
   hand-built server).

2. **2026-09-06 08:40Z — Configuration, with the one deliberate deviation.**
   `shared_buffers = 2GB` (the standard 25%-of-RAM rule), `effective_cache_size
   = 8GB`, `work_mem = 64MB`, `maintenance_work_mem = 1GB`.
   **`max_parallel_workers_per_gather = 0`** — the researcher's call, confirmed
   explicitly. 0 means the backend itself is the only executor; 1 would give
   leader + one worker. This matches the `1t` convention across the whole corpus.
   Recorded as a deviation because a real analytics deployment *would* use
   parallel query; rollback is one config line and a reload if it proves
   pathological under TCG.
   `work_mem = 64MB` is worth its own note: the stock 4 MB would push every
   TPC-H hash join and sort to spill to disk, turning a memory workload into an
   I/O one. 64 MB is normal analytics tuning and keeps the hash tables in DRAM
   where the traffic belongs. That is a lever, so it is stated rather than buried.

3. **2026-09-06 08:46Z — SF=10 generated and loaded.** 10.38 GB of `.tbl`,
   loaded in 218 s for lineitem. Every table at the exact TPC-H reference row
   count: lineitem 59,986,052, orders 15,000,000, partsupp 8,000,000,
   part 2,000,000, customer 1,500,000, supplier 100,000, nation 25, region 5.
   **Database 14 GB against 2 GB shared_buffers — a 7x overcommit.** No query
   can run cache-resident, which is the structural guarantee this campaign
   exists to enforce, established *before* spending any TCG time.

4. **2026-09-06 08:52Z — FOUR tpch-kit portability defects, each failing
   differently. Recorded because one of them looked like success.**
   * **`dss.ri` created NOTHING.** It targets a `TPCD` schema and uses DB2 syntax
     (`ADD FOREIGN KEY <name> (...)` rather than PostgreSQL's
     `ADD CONSTRAINT <name> FOREIGN KEY (...)`), so it fails at the first ALTER
     and every statement after is a no-op cascade. My own wrapper printed
     "keys done" and moved on. Caught only by querying `pg_constraint` and
     `pg_indexes` directly: **0 and 0**. Verify the artifact, never the log line.
   * **Trailing `|` on every data line** — dbgen's format. `COPY` reads it as a
     phantom extra column. Handled with `COPY ... FROM PROGRAM 'sed'` so the
     stream is fixed in flight rather than rewriting 10 GB on disk.
   * **`limit -1;` footer** emitted by qgen when a query has no LIMIT. Invalid
     in PostgreSQL.
   * **DB2 interval precision** (`interval '90' day (3)`) and a `;` terminating
     the template *before* qgen appends `limit N;`, splitting one statement into
     two. Q1 failed on the first, Q18 and Q21 on the second.
   All four fixed in `mkqueries.sh`, with the reasoning in the script.

5. **2026-09-06 08:52Z — Primary keys added, foreign keys deliberately not.**
   8 PKs, `rc=0`, all 8 indexes verified present by name. PKs create the indexes
   the planner actually uses and the spec requires them. FKs do not influence
   PostgreSQL's TPC-H plan selection and validating them against 60M lineitem
   rows costs minutes of scanning for no change in memory behaviour — skipped
   deliberately and stated, not silently omitted. Researcher confirmed.

6. **2026-09-06 09:00Z — Five queries generated and validated against the live
   database.** Planner costs: **Q18 4.35M > Q1 3.95M > Q21 3.60M > Q6 2.48M ~
   Q9 2.47M**. Q6 (pure scan aggregate) and Q21 (correlated subquery) were added
   beyond the original Q1/Q9/Q18 to widen the screen.
   Cost is a planner estimate, not memory behaviour. The screening runs decide,
   and they are being **held until Spark's converters clear** so the timings are
   not taken against a contended disk — measuring on a busy machine and then
   choosing a capture target from those numbers would be exactly the kind of
   contaminated evidence this campaign has been careful to avoid.

7. **2026-09-06 09:50Z — Screening on measured buffer behaviour, and a REVERSAL.**
   Five queries, warm run then measured run, `EXPLAIN (ANALYZE, BUFFERS)`:
   | query | exec | shared_hit | shared_read | temp_read | plan nodes |
   |---|---|---|---|---|---|
   | Q1 | 31.6 s | 6,856 | 3.37M | 0 | 5 |
   | Q6 | 3.3 s | 4,688 | 2.25M | 0 | 1 |
   | Q9 | 38.7 s | 121.2M | 13.8M | 311k | 12 |
   | Q18 | 51.7 s | 309k | 19.8M | 4.06M | 11 |
   | Q21 | 46.7 s | 24.5M | 16.7M | 0 | 15 |
   I initially recommended Q21+Q9 and rejected Q18 for its 4.06M temp reads, and
   rejected Q1/Q6 as "pure scans, memory barely involved".
   **The researcher pushed back on both counts and was right on both.** Q1 is a
   legitimate and distinct behaviour — a corpus without a streaming-scan point is
   poorer for it; I had been screening for "high traffic" rather than for
   *coverage of behaviours*. And on Q18 the researcher asked for a measurement
   rather than accepting my inference from block counts.

8. **2026-09-06 09:55Z — `track_io_timing` is NOT USABLE on this guest, and the
   reason is a consequence of our own design.** `pg_test_timing` measures
   **7,270 ns per call**; the only clocksources available are `hpet` and
   `acpi_pm`, no TSC. That is downstream of `kvmclock=off` in `cpustr.sh`, which
   is load-bearing for KVM->TCG snapshot restore and will not be changed.
   PostgreSQL takes two timing calls per block read, so Q18's ~20M reads would
   add ~290 s of instrumentation to a 51 s query — the measurement would be
   dominated by the act of measuring. Measured this before trusting it.
   Substituted a two-sample `/proc/stat` method on an otherwise-idle guest.

9. **2026-09-06 09:50Z — The I/O measurement REVERSED my recommendation.**
   Normalised to one core (PostgreSQL single-threaded here):
   | query | wall | CPU-busy | iowait |
   |---|---|---|---|
   | Q1 | 34.4 s | 88.8% | 2.1% |
   | Q6 | 14.6 s | 52.0% | 7.5% |
   | Q9 | 34.6 s | 86.4% | 2.2% |
   | **Q18** | 51.1 s | **87.6%** | 2.8% |
   | **Q21** | 46.3 s | **51.2%** | 8.3% |
   **Q18 is compute-bound**, not I/O-bound — its spill is absorbed by the OS page
   cache (12 GB RAM against a 14 GB database), so blocks move without the process
   blocking. **Q21 is the most I/O-bound of the four** — the one I had
   recommended. My inference from `temp_read` was simply wrong: spilled blocks
   say data moved, not that anyone waited.

10. **2026-09-06 10:12Z — And a correction to entry 9's practical weight: KVM
    I/O fractions OVERSTATE what the TCG trace will see.** Re-measured Q1 pinned
    on a free disk: 60.2% busy / 24.9% iowait, against 88.8%/2.1% unpinned during
    screening. But TCG runs compute ~35x slower (85 MIPS vs ~3 GIPS native) while
    disk I/O stays at wall-clock speed, so an I/O fraction measured under KVM
    shrinks by roughly that factor under TCG.
    Consequence: my objection to Q21 ("half the window would be idle-loop that
    gets filtered") is much weaker than I stated — under TCG that becomes
    negligible, for the same reason Tomcat's genuine idling only cost 0.6-0.9%.
    Recorded because I argued the point twice before working out that the
    measurement I was arguing from does not transfer across the KVM/TCG boundary.
    **Order confirmed with the researcher: Q1, Q9, Q18, then Q21.**

11. **2026-09-06 10:05Z — Query driven by a server-side PL/pgSQL LOOP, not a
    shell loop.** The CPU pin is pid-bound; a shell loop over `psql` spawns a new
    backend every ~35 s, so the pin would be lost each iteration and `vcpus=1`
    would trace an unpinned process — the exact failure the preflight audit
    caught for Cassandra. A `DO $$ LOOP PERFORM count(*) FROM (<query>) $$` keeps
    ONE backend for the whole run. Verified: backend 8014, `mask=2`, 1 thread,
    0 unpinned, busy-tick delta cpu1=831 vs cpu0=9.
