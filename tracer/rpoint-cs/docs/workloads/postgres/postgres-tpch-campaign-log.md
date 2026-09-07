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

12. **2026-09-06 11:13Z — Q1 PROFILE, and the KVM/TCG I/O prediction CONFIRMED.**
    `PROFILE: 122,849,691,352 instructions (101,347,046,090 user,
    21,502,645,262 kernel)` over 600 s = **204.7 MIPS, 82.50% user**.
    * **Widest trajectory and fastest TCG rate in the whole campaign** — 122.8e9
      against Spark's 111.8e9, and 204.7 MIPS against Spark's 186.4. Both make
      sense for a tight scan-and-aggregate loop over 60M rows: a small hot code
      footprint means very high TCG translation-block reuse.
    * The prediction from entry 10 held. Under KVM, Q1 measured **60.2% CPU /
      24.9% iowait** (pinned). Under TCG the trace is **82.5% user / 17.5%
      kernel** — the I/O wait has effectively vanished, because TCG stretches
      compute ~35x while the disk runs at unchanged wall-clock speed.
      That is the reasoning that justified keeping Q1 *and* weakened my objection
      to Q21, now confirmed by measurement rather than argument.

13. **2026-09-06 11:14Z — A sed bug of mine killed the first Q1 profile launch.**
    Building `launch_tcg_pg.sh` I wrote `sed 's/pg-guest/pg-guest-tcg/'` intending
    to rename only the QEMU `-name` label; it also rewrote the **disk filename**,
    so QEMU died at startup with `Could not open 'pg-guest-tcg.qcow2'`. The no-op
    protective sed I had added ran later in the chain and could not help.
    Cost ~9 minutes; **no data at risk** — QEMU died before opening anything, and
    `tpch_q1_a` with its warm buffer cache was verified intact afterwards.
    Fixed, and added a **fail-fast check** to the driver: 20 s after launch it
    confirms QEMU is running and dumps stderr if not. Without that the failure
    would have sat in an ssh retry loop for 40 minutes, which is exactly what it
    did the first time.

14. **2026-09-06 11:33Z — Q1 captured: 3 windows, 101.29% coverage.**
    `sgap.py --total 122849691352 --user 101347046090 --windows 3`
      -> SGAP = 49,436,071,266, spanning 100.00% of the profile.
    Achieved span 124,432,608,087 of a profiled 122,849,691,352 = **101.29%**.
    Over 100% is not an error: the gap is sized from the profile's 600 s
    trajectory, but the capture is not time-bounded — it runs until 3 windows are
    collected. The capture ran marginally faster (warmer TB cache, less dormant
    overhead), so the third window landed just past where the profile's sample
    ended. The query loops indefinitely, so there is always more workload there.
    Implied user fractions 0.8215 / 0.8070 against a profile 0.8250 — consistent.

15. **2026-09-06 11:43Z — Q1's instruction mix puts it in a NEW part of the
    corpus, which is exactly why the researcher was right to keep it.**
    Early conversion: **branch 15.0-15.5%, mem 49.8-50.8%**, decode_fail 0.
    | workload | branch % | mem % |
    |---|---|---|
    | redis | 14.2 | 52.8 |
    | **postgres Q1** | **~15.3** | **~50.2** |
    | mongodb | 16.2 | 47.1 |
    | kafka | 16.5 | 45.6 |
    | rocksdb | 17.5 | 50.0 |
    | tomcat | 17.6 | 41.8 |
    | cassandra | 17.6 | 40.6 |
    | spark | 17.9 | 42.1 |
    Q1 sits at the **low-branch / high-memory** end, near Redis and RocksDB and
    clearly separated from all four JVMs — the signature of a tight scan-and-
    aggregate loop: few branches per instruction, heavy streaming load traffic.
    I had screened Q1 OUT for "near-zero buffer hits, memory barely involved".
    That was a category error: I was screening for *traffic volume* rather than
    for *coverage of behaviours*, and a corpus with no streaming-scan point is
    poorer for it. The researcher overruled me and the measurement supports them.

16. **2026-09-06 11:54Z — Q9 warm-up started in parallel with Q1's conversion,
    pin RE-APPLIED after the guest reboot.** The guest was shut down for Q1's TCG
    capture, so this is a fresh boot: new postmaster, new backend pid (1084), and
    the pin is pid-bound. Re-applied and verified `mask=2`, 1 thread. Assuming it
    had carried over would have produced an unpinned Q9 trace — the same silent
    failure the preflight audit caught for Cassandra.

17. **2026-09-06 12:45Z — a monitoring poll reported `decode_fail=1606302`; it
    was the SIMD counter.** The seventh monitoring defect of this campaign, and
    the same family as the `grep -c` trap. The converter's progress line is

    ```
    [raw2champsim] 560M insns | user 79.6% kern 20.4% | branch 15.4% mem 49.9% \
      | decode_fail 0 memop_overflow 35856 | INT 558393616 FP 82 SIMD 1606302
    ```

    An earlier poll extracted the field correctly with
    `grep -oE 'decode_fail[= ]+[0-9]+' | grep -oE '[0-9]+$'`. Retyping the poll
    by hand I dropped the middle stage, leaving `grep -oE '[0-9]+$'` applied to
    any line *containing* the string `decode_fail` — which returns the last
    number on the line. That is `SIMD`. The value 1,606,302 is w00001's SIMD
    instruction count at 560M, not a decode failure.

    This is the literal ESCALATE condition (`decode_fail non-zero`),
    manufactured on a healthy converter — exactly like the `convert=0` reading
    that produced `convstat.sh`. Verified before escalating: all three windows
    show `decode_fail 0`.

    **Rule, now stated generally: never extract a number without anchoring it to
    its label.** Both defects are the same mistake — a positional extraction
    (`$?`, `[0-9]+$`) standing in for a named one. Added `scripts/dfstat.sh`
    alongside `convstat.sh` and `guestpin.sh`, so the check is a definition
    rather than something retyped per poll. That is the third time this campaign
    has answered a monitoring defect by promoting the check to a script; the
    pattern is now the default response.

18. **2026-09-06 13:18Z — pipelining: the profile is the only stage that must
    run on a quiet machine.** The researcher asked whether the next query could
    be pipelined against the current one's conversion. It can, and I had been
    too conservative: Q9 was warming in parallel, but its profile was queued
    behind Q1's ~2.4 h conversion, leaving the guest idle for ~40 minutes.

    The constraint is narrower than I was treating it. Capture and conversion are
    instruction- and data-bounded, so contention there costs wall-clock and
    nothing else. **The 600 s profile is the only time-bounded stage**: a
    contended profile executes fewer instructions in its fixed window, yielding a
    smaller SGAP, spreading the three windows over a NARROWER slice of the
    query's trajectory. Not wrong -- but not comparable to Q1, profiled idle at
    204.7 MIPS. Comparability across queries is the thing worth protecting.

    Capacity was never the issue: 32 cores at load 4.2, NVMe at 46% util, 43 GB
    RAM free. So rather than wait, fence only the measured window -- `SIGSTOP`
    the three converters for the ~12 minutes around the profile, `SIGCONT`
    after, via a trap so it fires even on failure. `SIGSTOP` is safe on
    `raw2champsim` specifically: a plain read/write filter, no timers, no
    sockets, no guest, no monitor. **This is not a loosening of the
    never-signal-QEMU rule**; a capture is still stopped with a monitor `quit`.
    Written into `scripts/run_pg_snap_profile.sh`'s header so it cannot be
    misread later as general permission to signal things.

    Result: load fell 4.26 -> 1.05 for the measured window, restore took 53 s
    with the disk free, and Q9's capture then ran concurrently with Q1's resumed
    conversion. ~28 minutes recovered, and the same again on Q18 and Q21.

19. **2026-09-06 13:35Z — Q9 profile, and what the fence bought.**
    `PROFILE: 102,794,750,124 instructions (73,027,808,407 user,
    29,766,941,717 kernel)` = 171.3 MIPS, **71.04% user**.

    | query | TCG rate | user % | measured |
    | q1 | 204.7 MIPS | 82.50 | idle machine |
    | q9 | 171.3 MIPS | 71.04 | idle machine (fenced) |

    Both idle, so the 11-point gap is the query. Q9's six-way join over
    lineitem/partsupp/orders/part/supplier/nation touches far more data than
    Q1's single scan, so more of its time is kernel-side page-cache work --
    consistent with the KVM screen (86.4% vs 88.8% CPU-bound). Profiled against
    three running converters, that difference would have been unreadable.

    `sgap.py` gave SGAP 35,448,268,921, spanning 100.00%. The plugin's hint
    would have given 35,013,904,204 -- only 1.2% low here, because Q9's kernel
    fraction is moderate. That is the bug's signature: **the error scales with
    kernel fraction**, which is exactly how it survived four campaigns of
    mostly-user workloads.

20. **2026-09-06 13:59Z — Q9 capture, 3/3 windows, 99.73% coverage.**
    Windows at 0 / 54,689,421,023 / 101,513,826,678; span 102,513,826,678 of
    102,794,750,124 profiled. Q1 came in at 101.29% from the other side of 100%.

    `trace_filter` removed **0.0%** from every Q9 window. PostgreSQL under a
    server-side DO-LOOP never idles, so there is no idle-loop noise to strip --
    the exact opposite of Tomcat, the only workload in the corpus that genuinely
    idles and legitimately loses 0.6-0.9% per window. Worth recording because
    that Tomcat number is what forced the ship gate down from a mis-generalised
    99.99% to 99%.

    The filter also showed Q9's user fraction varying **82.3% / 55.3% / 54.3%**
    across the three chunks, against Q1's steady 73-80%. The join moves through
    genuinely different phases (hash build, probe, aggregate); spreading windows
    across the whole trajectory is what captures that.

21. **2026-09-06 14:43Z — Q1 SHIPPED. CHECKSUMS 191 -> 194.**
    All three verified with `sha256sum -c` ON kratos2 before registering; bare
    basenames; manifest preserved to `docs/workloads/postgres/`; tlist
    `scripts/tlists/postgres_tpch_q1.yml` written (9 tlists, 38 names, 0
    duplicates); then and only then reclaimed 5.9 GB raw + 5.8 GB converted.

    Final mix, decode_fail 0, 1,000,000,000 insns each:
    w00000 72.8/27.2 user/kern 15.0% branch 50.8% mem; w00001 79.8/20.2 15.4%
    49.9%; w00002 76.9/23.1 15.3% 50.2%. Branch spread 0.4 pt, memory spread
    0.9 pt -- **the tightest in the corpus**, which is what a pure sequential
    scan should look like: the same loop over different data. Spark page-rank,
    by contrast, spread 4.8 pt across its iterations.

22. **2026-09-06 14:17Z — an eighth monitoring defect, caught before use:
    `bash -n` reports "syntax OK" on a zero-byte file.** Building `ship_pg.sh`
    from `ship_spark.sh` with `sed`, one expression used `|` as both the
    delimiter and a literal alternation. `sed` aborted at parse time -- but `>`
    had already truncated the output file, so `ship_pg.sh` was 0 bytes, and
    `bash -n` on an empty file exits 0. The verdict "syntax OK" was true and
    meaningless.

    Same family as the `grep -c` and `decode_fail` traps: **a check that passes
    on nothing.** Caught only because the follow-up `grep` for `DEST=` printed
    no lines. Rebuilt in Python and verified 3,491 bytes with the right `DEST`,
    `STAGE` and log path before running. Nothing shipped from the empty file.
    Rule to carry forward: after generating a file, assert on its SIZE and on a
    known-present string, never on a syntax check alone.

23. **2026-09-06 14:43Z – 2026-09-07 01:03Z — the database category, complete.**
    Q1, Q9, Q18, Q21 shipped in that order; CHECKSUMS 191 -> 209.

    | query | user % | TCG rate | branch | mem | coverage |
    |---|---|---|---|---|---|
    | q18 | 93.81 | 255.7 MIPS | 15.2-15.5 | 48.7-49.6 | 101.41% |
    | q1  | 82.50 | 204.7 MIPS | 15.0-15.4 | 49.9-50.8 | 101.29% |
    | q9  | 71.04 | 171.3 MIPS | 12.9-15.8 | 47.3-56.7 |  99.73% |
    | q21 | 60.90 | 172.2 MIPS | 12.5-12.7 | 56.0-57.7 | 101.93% |

    **A 33-point user-fraction range out of one guest, one database, one
    configuration — by changing only the SQL.** Wider than the three DaCapo JVMs
    managed (37.1 -> 66.4) and achieved without any deployment-realism
    compromise. That is the strongest argument for treating "database" as
    several points in the space rather than one.

    Two queries turned out to be corpus extremes:
    - **Q9** is the only workload here whose windows split into two REGIMES
      rather than a gradient: w00000/w00001 at 55% user / 12.9% branch / 56.6%
      mem, w00002 at 82% user / 15.8% / 47.3% with 4x the SIMD. Hash-build and
      probe versus aggregate, visible in the trace.
    - **Q21** is the most kernel-heavy (w00001 at 52.0% kernel, the first
      majority-kernel trace in the corpus) and the most memory-biased. Both are
      outside the reject band on both axes and were accepted deliberately; the
      tlists say so explicitly rather than leaving it to be rediscovered.

24. **2026-09-06 19:34Z – 2026-09-07 02:34Z — Renaissance round 2: four
    workloads, all four the researcher asked for.** CHECKSUMS 209 -> 215.

    | workload | user % | TCG rate | branch | mem | live set |
    |---|---|---|---|---|---|
    | naive-bayes | 95.01 | 179.1 MIPS | 16.7 | 51.4 | 1.35 GB |
    | dec-tree | 94.47 | 173.1 MIPS | 18.6 | 41.3 | -- |
    | finagle-chirper | 82.12 | 100.5 MIPS | 18.6 | 41.6 | 18.8 MB |
    | finagle-http | 68.49 | **75.4 MIPS** | 18.3 | 41.2 | 14.1 MB |

    **The Spark ML pair proved the hypothesis they were chosen to test.**
    page-rank is the only one of Renaissance's eight apache-spark benchmarks on
    the raw RDD API; these two run DataFrames through Catalyst and Tungsten
    whole-stage codegen. All three are ~95% user and 170-190 MIPS, so they are
    indistinguishable on privilege split -- the difference is entirely mix, and
    it is stark: **naive-bayes emits ~54 M SIMD instructions per billion, 5.4% of
    the whole stream**, 2.8x dec-tree, 6x Q18, 20x Q1. Tungsten's generated
    sparse-vector code JITing into wide vector loops.

    **finagle-http is the slowest workload this project has ever traced** at
    75.4 MIPS -- below Tomcat (76.6) and Cassandra (84.5), a third of Q18. Two of
    its three windows are majority-kernel. Client and server share one JVM over
    TCP loopback; every request crosses the kernel twice and TCG cannot
    accelerate a syscall.

    The two finagle workloads differ by ~9 points of kernel fraction while their
    branch/memory mixes are nearly identical (18.3 vs 18.6% branch, 41.2 vs
    41.6% mem). The Netty stack dominates the user-mode shape regardless of the
    service above it, so the pair isolates kernel involvement with user code held
    roughly constant. Recorded because it is a useful property, not an accident.

    **The waiver was load-bearing.** Judged on memory intensity both finagle
    workloads would have been screened out, and they carry the corpus's ONLY
    high-branch + kernel-heavy traces. The researcher's call:
    *"they may or may not be interesting from memory perspective. But that's
    fine. These traces may come in handy for new studies."*

25. **The sample_gap bug, now with five measured points across a 33-point
    kernel range.** Every capture in this campaign computed the gap with
    `scripts/sgap.py` and recorded what the plugin's hint would have produced:

    | workload | kernel % | hint would cover |
    |---|---|---|
    | q18 | 6.19 | 99.87% |
    | naive-bayes | 4.99 | 99.85% |
    | dec-tree | 5.53 | 99.83% |
    | q9 | 28.96 | 98.81% |
    | q21 | 39.10 | 98.14% |
    | **finagle-http** | **31.51** | **96.95%** |

    The error tracks kernel fraction, as derived. finagle-http is the worst case
    measured anywhere in this project -- and note it is worse than Q21 despite a
    lower kernel fraction, because the shortfall is K*N*(1-f)/U and its
    trajectory is less than half Q21's, so the fixed 3e9 of window is a much
    larger share of it. **The bug is not a function of kernel fraction alone;
    short trajectories amplify it.** That is the refinement this campaign adds.

26. **2026-09-07 — pipelining, in numbers.** The insight that the 600 s profile
    is the ONLY time-bounded stage (entry 18) held for all eight remaining
    workloads. Every profile ran on a machine fenced to load ~1.1 by pausing the
    converters; peak concurrency otherwise reached **13 filter/convert processes
    across four workloads** at load 14.9 on 32 cores, with captures and ships
    overlapping freely. Zero pipeline defects throughout.
