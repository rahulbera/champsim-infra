# Apache Spark — campaign log

Running log of the Spark tracing effort. Enumerated, timestamped UTC, appended as
things happen, **dead ends and my own mistakes included**.

This is the workload the researcher has wanted for a long time and never
attempted, because "most of the big data frameworks are in Java, and it breaks
pretty quickly inside TCG restore". See
`docs/workloads/dacapo/dacapo-campaign-log.md` for how that blocker was retired.

---

1. **2026-09-06 05:11Z — Renaissance verified BEFORE committing to it.**
   Renaissance **0.16.1** (2025-11-10), one self-contained jar (419 MB, 560
   entries), bundling **Apache Spark 3.5.3** (Scala 2.13) with hadoop-client
   3.3.6 under `unique/apache-spark/` — spark-core, spark-sql, spark-mllib and
   every transitive dependency.
   **Eight apache-spark benchmarks**, with the suite's own repetition counts:
   `als` (30), `chi-square` (60), `dec-tree` (40), `gauss-mix` (40),
   `log-regression` (20), `movie-lens` (20), `naive-bayes` (30), `page-rank` (20).
   Decisive for the plan: **no cluster, no HDFS, no Zookeeper, no external
   services.** Spark runs in-process, which removes the entire class of failure I
   flagged as the main TCG risk — driver/executor heartbeats (10 s default),
   `spark.network.timeout` (120 s), block-manager liveness. **A heartbeat that is
   never sent over a socket cannot be missed under a 50-100x slowdown.**

2. **2026-09-06 05:21Z — Spark guest staged on its own COW overlay.**
   `spark-guest.qcow2`, 196 KiB on creation, backed by `java-guest.qcow2` so the
   Cassandra/Kafka/Tomcat snapshots stay untouched and independent. **12 GB**
   (more than Tomcat's 8 for MLlib intermediates, far short of the 24 GB that made
   Cassandra's snapshot cost 23.6 GiB). Up in **21 s**, JDK 21.0.12, 38 G free.
   The `< /dev/null` stdin guard was inherited by construction rather than
   retrofitted — the first guest this campaign has launched that was born with it.

3. **2026-09-06 05:22Z — Renaissance jar into the guest**, 419 MB in 2 s,
   SHA-256 `bcf6662...044bc` verified identical on host and guest.

4. **2026-09-06 05:25Z — SPARK RUNS. First Spark execution on this pipeline.**
   `java -Xms4g -Xmx4g -XX:+UseG1GC -jar renaissance-mit-0.16.1.jar -r 3 page-rank`
   completed all three iterations inside the guest, **0 errors**.
   Iteration times **6665 -> 3264 -> 3037 ms** (JIT warming), and
   **heap 1.8 GB -> ~149 MB per GC** — heavy allocation churn against a small live
   set, the same profile that made Cassandra memory-interesting despite a 174 MB
   minheap. Exactly the shape the LLC-rate screen was adopted to catch, and
   exactly what a heap-size screen would have mis-ranked.

5. **2026-09-06 05:31Z — Two consequences for the capture design, from that
   measurement rather than from assumption.**
   * At ~3 s/iteration under KVM, `-r 3` is far too short to snapshot mid-stream.
     Use a high repetition count (the suite's own default for page-rank is 20) so
     there is genuine steady-state runtime to sit inside.
   * The GC cycle is ~1.8 GB per iteration. Windows must be placed so they do not
     all land in the same phase of that cycle — which is what the corrected
     `sgap.py` spacing is for, and why Cassandra's five windows sampled user
     fractions from 0.308 to 0.488 instead of clustering.

6. **2026-09-06 05:45Z — Screened two Spark candidates on measurement, not
   reputation.** Both ran clean under JDK 21 in the guest, 0 errors.
   | benchmark | iter 0 | steady iter | GC churn/iter | live set after GC |
   |---|---|---|---|---|
   | page-rank | 6665 ms | ~3040 ms | 1.8 GB | ~149 MB |
   | als | 7767 ms | ~2270 ms | 1.97 GB | ~65 MB |
   Both show the profile that matters here: **~2 GB allocated and collected per
   iteration against a live set of tens of MB.** Extreme allocation churn with
   tiny residency — the shape a heap-size screen ranks as trivial and that in
   fact generates heavy memory traffic. Same reason Cassandra proved
   memory-interesting on a 174 MB minheap (entry 14 of the DaCapo log).
   **Choosing `page-rank` first**: its live set is ~2.3x larger (149 MB vs 65 MB)
   and it is RDD-based iterative graph work, so there is genuine pointer chasing
   over a *persisted* structure rather than mostly-transient MLlib intermediates.
   Better locality-stress candidate on the evidence, not on the name.
   `als` is kept as the second candidate rather than discarded.

7. **2026-09-06 05:45Z — ssh timeout trap, again, behaving exactly as logged.**
   The `als` launch returned exit 143 (120 s ssh timeout) while the benchmark ran
   to completion. Checked the artifact instead of inferring failure, per the
   runbook. Recording the recurrence because it is now the fourth time tonight and
   it has never once meant what it looked like.

8. **2026-09-06 05:53Z — Spark warm-up running and PINNED. 268 threads.**
   `java -Djava.security.manager=allow -Xms4g -Xmx4g -XX:+UseG1GC
    -XX:ParallelGCThreads=2 -XX:ConcGCThreads=1
    -jar renaissance-mit-0.16.1.jar -r 400 page-rank`
   `-r 400` deliberately: at the measured ~3 s/iteration under KVM (entry 4), a
   short run gives no steady state to snapshot inside. 400 repetitions is ~20
   minutes of KVM runtime and leaves the JVM in a genuinely settled regime.
   Pinned immediately: **268 threads, all mask `2`, zero unpinned**, 25 iterations
   done, 0 errors.
   **268 threads is the largest of any workload in this campaign** — Cassandra 88,
   Kafka 101, Tomcat 26. Spark's local-mode executor pools. That makes the pin
   *more* load-bearing here than anywhere else: unpinned, a `vcpus=1` trace would
   have sampled roughly 1/268th of the interesting work, interleaved with whatever
   else the scheduler put on that core, and it would have looked like a plausible
   Spark trace. This is the failure the preflight audit caught for Cassandra
   (DaCapo log entry 30) and it would have been far worse here.

9. **2026-09-06 05:53Z — ssh 120 s timeout on the launch, fifth occurrence
   tonight, command succeeded again.** Verified by artifact. Noting the count
   because the pattern is now unambiguous: on this setup an ssh that launches a
   detached JVM will essentially always report failure and essentially never mean
   it. Any future automation here must check the artifact, never the exit code.

10. **2026-09-06 06:11Z — Fourth monitoring false alarm of the night, same shape
    as the other three.** `guestpin.sh` reported **"NO JVM"** for the Spark run.
    The JVM was fine (iterations climbing 58 -> 102, 0 errors); the script
    hardcoded `dacapo-23.11-MR2-chopin.jar` in its `pgrep -f` pattern and Spark
    runs the *Renaissance* jar. Generalised to match both harnesses and to take a
    pattern argument.
    Re-checked after the fix: `pid=2357 mask=2 threads=239 unpinned=0`.
    (Thread count drifts 268 -> 239 between samples: Spark's local-mode executor
    pools grow and shrink with the stage. Not a leak, and not the pin failing.)

11. **2026-09-06 06:11Z — The pattern across all four is worth stating once.**
    Tonight's monitoring defects, in order: `pgrep -f` matching bash wrappers and
    reporting mask `f`; a process counter that knew only `raw2champsim` and read a
    healthy sanity-check stage as "0 converters" (the brief's literal ESCALATE
    condition); `grep -c || echo 0` emitting "0\n0" — a trap written verbatim in
    the runbook — twice; and now a pin-checker hardcoded to one jar name.
    **Every one was a check written for one specific case and then reused on a
    slightly different one.** Three of the four manufactured a failure on a
    healthy system.
    Scoreboard for the night: **the capture pipeline has produced zero bad
    traces; my instruments have produced four bad readings.** The corrective is
    not more care in the moment — I had the runbook open — it is that a check
    used more than once becomes a script with an argument, which is what
    `guestpin.sh` and `convstat.sh` now are.

12. **2026-09-06 06:34Z — `dc_spark_a` snapshot: 6.03 GiB in 28 s**, taken at
    **iteration 200 of 400** with the pin re-verified immediately before
    (`pid=2357 mask=2 threads=243 unpinned=0`).
    The ≥200-iteration gate was deliberately deeper than the mid-iteration rule
    used for the DaCapo benchmarks: Spark's JIT surface is much larger (Scala
    closures, Catalyst-generated code, Tungsten codegen), so "visibly stable
    timing" at 146 iterations is suggestive but half the run is cheap insurance.
    Snapshot cost tracks the model from DaCapo entry 64 — 12 GB guest, 6.03 GiB
    written, i.e. about half the RAM touched.

13. **2026-09-06 06:42Z — SPARK PROFILING UNDER TCG.** First big-data framework
    this pipeline has ever profiled. Restored from `dc_spark_a`, trigger armed at
    06:42:54Z, `Tracing is now ENABLED (skipped 12,030,000,000 instructions
    during dormant phase)`.
    That dormant figure is worth comparing: cassandra 1.84e9, tomcat 4.01e9,
    kafka 12.66e9, **spark 12.03e9**. Spark and Kafka are the two that rebuild
    substantial service machinery on restore — Spark's SparkContext, block
    manager, scheduler and executor pools; Kafka's Zookeeper + broker + Trogdor.
    All of it excluded from both passes by the `trigger=` fix (DaCapo entry 33),
    which matters most exactly here: a 12e9-instruction transient counted in the
    profile but skipped in the capture would have mis-sized the gap badly.

14. **2026-09-06 07:01Z — SPARK PROFILE: 95.09% user. A qualitatively different
    workload from everything else in the corpus.**
    `PROFILE: 111,822,210,176 instructions (106,329,990,230 user,
    5,492,219,946 kernel)` over 600 s = **186.4 MIPS**.
    | workload | user % | TCG rate |
    |---|---|---|
    | redis | 37.2 | — |
    | cassandra | 37.1 | 84.5 MIPS |
    | kafka | 50.6 | 96.8 MIPS |
    | tomcat | 66.4 | 76.6 MIPS |
    | **spark page-rank** | **95.1** | **186.4 MIPS** |
    Essentially pure user-mode compute. Consistent with the design: Spark in
    local mode iterates RDDs entirely in-JVM, with no socket traffic and no
    per-request syscalls, so the kernel barely features — and TCG runs user code
    fast when it is not crossing into the kernel, which explains the 2.2x rate
    over Cassandra.
    Trajectory **111.8e9 instructions, 1.88x Cassandra's 59.4e9** — the widest
    sampling ground in the campaign.

15. **2026-09-06 07:01Z — Spark is the workload that would NEVER have exposed the
    SGAP bug, which explains how it survived four campaigns.**
    `sgap.py --total 111822210176 --user 106329990230 --windows 3`
      -> **SGAP = 51,738,668,582**, spanning **100.00%**.
      Plugin hint 51,664,995,115 -> **99.86%**. A 0.14% error.
    The shortfall is `K*N*(1-f)/U`, so it scales with the KERNEL fraction:
    | workload | user f | hint would cover |
    |---|---|---|
    | redis | 0.372 | 58.9% |
    | rocksdb | 0.569 | 86.4% |
    | cassandra | 0.371 | 85.8% |
    | tomcat | 0.664 | 96.7% |
    | **spark** | **0.951** | **99.86%** |
    Had Spark been the first workload traced, the formula would have looked
    correct to any amount of scrutiny short of deriving it. The bug's damage is a
    pure function of the workload, not of the code — which is exactly the class of
    defect that hides in a pipeline for years.

16. **2026-09-06 07:01Z — Spark capture launched**, 3 windows x 1e9,
    SGAP=51,738,668,582, restored from `dc_spark_a`, pin re-verified after
    restore. Driver detached.

17. **2026-09-06 07:11Z — I wrote the `grep -c || echo 0` bug AGAIN, forty
    minutes after logging an entry warning about it.**
    `run_spark_capture.sh` line 12:
    `until [ "$(grep -vc '^#' manifest 2>/dev/null || echo 0)" -ge 3 ]`.
    When the manifest exists with only its comment line, `grep -vc` prints "0"
    and exits 1, `|| echo 0` fires, the substitution is `"0\n0"`, and the test is
    a shell error. Fifth occurrence tonight (DaCapo entries 59, 67, 73 and the
    tomcat ship driver twice).
    The running instance is noisy but **functionally correct**, verified rather
    than assumed: at 3 rows `grep -vc` prints "3" and exits 0, so `||` never
    fires and the loop breaks. Left running rather than restarted mid-capture.
    File fixed for the repo.
    **The honest conclusion is not "be more careful".** I had the runbook open,
    I had written the warning myself, and I still reached for the same idiom
    because it *reads* correct. The idiom is the hazard. The durable fix is that
    counting lines in a maybe-empty, maybe-absent file is a named helper with one
    definition, not something retyped per driver — the same conclusion as
    `guestpin.sh` and `convstat.sh`, arrived at a third time.
    Worth stating for the record: **five monitoring/control defects tonight,
    zero pipeline defects.** Every trace produced has passed decode_fail 0,
    exact-geometry and reject-band checks. The instruments have been the weak
    point all night, not the machinery they watch.
