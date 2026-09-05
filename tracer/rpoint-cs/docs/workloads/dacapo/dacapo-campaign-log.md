# DaCapo (Chopin) + Spark — campaign log

Running log of the Java/big-data tracing effort. Enumerated, timestamped UTC,
appended as things happen, **dead ends included**. The point of this file is
that the recipe should never again exist only on one disk.

**Goal.** Memory-intensive ChampSim v2 traces from JVM workloads, *without*
moving to a deployment nobody would actually run. Spark is the target; the
three large DaCapo Chopin benchmarks (cassandra, kafka, tomcat) are the
validation vehicle — if the pipeline carries a JVM, their traces come nearly
for free on the way.

---

1. **2026-09-05 20:30Z — Scope set with the researcher.**
   Big data (Spark) is the real target. DaCapo Chopin is a *segue*, used to
   prove the pipeline carries a JVM at all and to bank traces cheaply while
   doing so. Only **cassandra, kafka, tomcat** — the rest of Chopin has
   footprints too small to be worth TCG hours, and shipping LLC-resident
   traces would recreate exactly the v1 defect this whole recapture exists to
   fix. **Three windows per benchmark**, not five.
   Agreed amendment: capture **five** windows on the *first* benchmark only,
   to characterise DaCapo's phase behaviour before trusting three. With three
   windows, one outlier is a third of the evidence and the window-spread
   regime check (which caught the memcached theta=0.6 split) loses its power.

2. **2026-09-05 20:35Z — Why this might work now, when it did not before.**
   The researcher's standing blocker was "most big data frameworks are in
   Java, and it breaks pretty quickly inside TCG restore". Two candidate root
   causes, and this campaign has already fixed both for unrelated reasons:
   * **AVX hflag.** `cpu_post_load()` never re-synced `HF_AVX_EN_MASK`; a KVM
     snapshot carries hflags without it (hardware did the CR4/XCR0 writes, not
     QEMU), so a TCG restore ran with AVX off and every VEX instruction raised
     `#UD`. Patched 2026-09-04, `patches/avx-hflag-tcg-restore.patch`.
     A JVM is the worst case for this: HotSpot detects CPU features once at
     startup and bakes AVX into C2-compiled code in its code cache, which it
     **cannot** fall back from the way glibc's ifuncs could. "Breaks pretty
     quickly" is the exact signature.
   * **CPU model mismatch.** If the KVM phase ever ran `-cpu host`, HotSpot
     would JIT for whatever the host exposes and then land on a TCG model that
     does not implement it. `cpustr.sh` now pins `Haswell,...` for *both*
     phases, closing this.
   Neither is proven for the JVM case yet — that is what J1 is for.

3. **2026-09-05 20:36Z — Hazards NOT retired by the above.** Recorded so they
   are not rediscovered: HotSpot's self-modifying code cache through TCG's
   TB invalidation; safepoint polling via guard-page `mprotect`; and the plain
   fact that a 50-100x slowdown fires every watchdog the JVM and Spark own.
   The last one is why Spark will run in **local[N] mode inside one JVM** —
   no driver/executor heartbeat (default 10s), no `spark.network.timeout`
   (120s), no block-manager liveness to miss.

4. **2026-09-05 20:37Z — DaCapo release selected: 23.11-MR2-chopin.**
   From the release notes: all benchmarks compatible with **Java 11-21**
   (cassandra and h2o "require defaults to be overridden via runtime
   properties" — to be resolved at J2). Six benchmarks have >1 GB heap
   footprints. Sizes are `small`/`default`/`large`/`huge`, with `huge`
   explicitly scaling to "consume significant memory" — the sanctioned lever
   for footprint, rather than a config we invented to inflate MPKI.
   `-t` fixes the absolute external thread count (our `1t` convention);
   `-n` sets iterations; `-w` is a watchdog that must **not** be armed short
   under TCG.
   Useful discovery: the suite **ships per-benchmark nominal statistics**
   (`stats/`), including heap footprint and LLC data. Screening can start from
   their numbers instead of burning TCG hours discovering footprints.

5. **2026-09-05 20:38Z — Java guest defined.** Ubuntu 24.04 noble cloud image
   (same base as memcached/RocksDB/Redis/MongoDB, so `ubu24.04` in the trace
   name stays honest), `openjdk-21-jdk-headless` — JDK 21 is the top of
   DaCapo's supported range and Ubuntu 24.04's default.
   `images/user-data-java`, `images/meta-data-java`, `images/seed-java.iso`.
   THP is set to `never`, consistent with the other guests — and, separately,
   that is the setting real Cassandra deployments are told to use, so it costs
   nothing in realism here.
   Deliberately a **fresh** guest rather than the Redis one: it wants a JDK,
   more RAM and a different disk layout, and starting clean beats mutating a
   snapshot with Redis and memtier baked in. The Redis guest is reclaimed on
   schedule.

6. **2026-09-05 20:39Z — J1 canary written** (`java/AvxCanary.java`).
   Deliberately gets C2 to vectorise a hot FMA loop, prints
   `CANARY ready-for-snapshot`, then heartbeats once a second forever.
   Snapshot it mid-flight under KVM, restore under TCG: a continuing heartbeat
   means JIT-compiled vector code crossed the boundary. If the AVX bug were
   still live the JVM would die *immediately* on restore, not gradually — so
   the signal is unambiguous either way.

7. **2026-09-05 20:40Z — Open design question, parked for J2.** The plugin's
   `vcpus=` knob takes a **vcpu range, not a count** (`parse_vcpus`, default
   `0-3`); every trace so far used `vcpus=1`, i.e. "trace vcpu 1". For a
   single-threaded server that is a clean slice. A JVM is genuinely
   multi-threaded (GC threads, JIT compiler threads), so tracing one vcpu
   captures whatever the guest scheduler happened to put there. That may well
   be the right thing for a single-core trace, but it needs a deliberate
   decision and a recorded rationale rather than inheritance from the KV-store
   runs. Mitigation to evaluate: pin GC threads explicitly
   (`-XX:ParallelGCThreads`, `-XX:ConcGCThreads`) so the mix is reproducible.

8. **2026-09-05 20:43Z — Java guest built and up.** `java-guest.qcow2`, 64 GiB
   virtual on the shared `noble-server-cloudimg-amd64.img` backing file (same
   pattern as the Redis and MongoDB guests — **the base image must never be
   reclaimed while any guest lives**). 4 vcpu, 24 GiB. cloud-init clean;
   OpenJDK **21.0.12+8-1-24.04-Ubuntu**.
   Guest CPU reports `Haswell` with `avx avx2 fma sse4_2`, and HotSpot picks
   **`UseAVX=2`, `UseFMA=true`, `UseG1GC`** by ergonomics. That is the precise
   precondition for the old failure: C2 will emit VEX-encoded AVX2 FMA into the
   code cache, which HotSpot cannot fall back from.

9. **2026-09-05 20:45Z — `hmp.py` rescued from `/tmp` into the repo**
   (`scripts/hmp.py`). It drove every `savevm` in all four completed campaigns
   while existing only at `/tmp/hmp.py` — the audit's central finding,
   reproduced live. Per-command timeout raised 280s -> 1800s, because `savevm`
   on a large guest writes all of guest RAM before returning and a short
   timeout there is indistinguishable from a hung monitor.
   Dead end on the way: `nc -U` without `-q` never returns on a QEMU monitor
   socket; two invocations hung for the full 120s before I went looking for
   how the earlier campaigns had actually done it. They had a tool; I should
   have looked first.

10. **2026-09-05 20:50Z — Snapshot `j1_canary_a` taken.** VM_SIZE 2.15 GiB,
    guest clock 08:09.355. The canary was mid-flight and warm (405 heartbeats,
    C2 long since compiled) at snapshot time, which is the whole point — a
    cold JVM would not have exercised the failure.

11. **2026-09-05 20:51Z — J1 PASSES. The JVM survives KVM -> TCG restore.**
    Restored under `accel=tcg` with the AVX-patched QEMU and **no plugin**.
    Guest came up, no panic, empty console. `java` pid 2988 restored intact.
    Heartbeat count read back as **399**, correctly rolled back from the 405
    seen just before `quit` — proof we resumed the snapshot rather than a live
    continuation. It then **advanced: 399 -> 445 -> 483** over the next 90s.
    This retires the researcher's standing blocker ("most big data frameworks
    are in Java, and it breaks pretty quickly inside TCG restore"). The most
    likely cause was the AVX hflag bug, and it is fixed.
    Caveat recorded honestly: the canary's heartbeat proves **liveness**, not
    numerical correctness — its `sum` saturated to `Long.MAX_VALUE`, so it
    could not have detected silently-wrong vector results. The observed bug
    mode is `#UD` (a fault, not wrong answers), so liveness is the right
    primary signal, but the gap is real and is closed separately by
    `java/VecCheck.java`.

12. **2026-09-05 20:53Z — `javac` ran to completion inside the TCG guest.**
    Incidental but meaningful: that is a second, independent, heavily
    JIT-dependent JVM workload completing under TCG, not just surviving.

13. **2026-09-05 20:54Z — J1 correctness closed.** `java/VecCheck.java` computes
    one reduction twice inside the restored TCG guest: once in a shape C2
    auto-vectorises (VEX/AVX2 + FMA) and once through a loop-carried
    dependence that forbids SIMD, then compares the arrays element by element.
    **PASS** — the paths agree, 200 rounds, 2.7s. So the restored JVM is not
    merely alive, it computes correctly with vector code. J1 is fully closed.

14. **2026-09-05 20:56Z — The footprint screen I proposed was WRONG, and
    DaCapo's own measurements say so.** This is the important entry.
    I had argued for screening benchmarks on heap footprint, expecting the
    Chopin large-heap additions to pass and the classic small ones to be
    LLC-resident. The suite ships measured `stats-nominal.yml` data; ranking
    all 22 benchmarks by **ULL (LLC misses per M instructions)** gives:

    | rank | bench | LLC/Mi | DTLB/Mi | DC/Ki | IPCx100 | %kern | minheap(large) |
    |---|---|---|---|---|---|---|---|
    | 1 | h2o | 8506 | 499 | 23 | 89 | 4 | 2543 MB |
    | 2 | **kafka** | 6819 | 230 | 27 | 127 | 25 | 345 MB |
    | 3 | **cassandra** | 5719 | 576 | 24 | 108 | 11 | 174 MB |
    | 4 | **tomcat** | 5119 | 519 | 18 | 102 | 19 | 35 MB |
    | 5 | xalan | 5045 | 441 | 20 | 98 | 14 | 13 MB |
    | ... | | | | | | | |
    | 16 | batik | 1872 | 50 | 4 | 228 | 0 | 1759 MB |
    | 17 | graphchi | 1746 | 45 | 3 | 234 | 1 | 1183 MB |
    | 19 | biojava | 1427 | 30 | 2 | 476 | 1 | 1027 MB |

    **Heap footprint anti-correlates with LLC miss rate here.** The three
    benchmarks the researcher picked — kafka, cassandra, tomcat — are ranks
    **2, 3 and 4 of 22**, with the lowest IPCs and (cassandra, tomcat) the
    highest DTLB pressure in the suite. The >1 GB-heap benchmarks I would have
    steered toward (batik, graphchi, biojava) sit in the bottom third: a large
    live heap traversed with good locality generates *less* LLC traffic than a
    small heap churned hard. Cassandra's 174 MB min heap conceals **4.79 GB of
    total allocation** (memory turnover GTO=34) — the traffic is in the churn,
    not the residency.
    **Rule for this campaign: screen on measured LLC miss rate and IPC, never
    on heap size.** Minheap answers "can it run", not "does it miss".

15. **2026-09-05 20:56Z — h2o noted as the one benchmark that outranks all
    three** (LLC/Mi 8506, rank 1/22, 2543 MB heap). It is DaCapo's machine-
    learning workload, so it would also fill the paper's ML category. Not in
    scope per the researcher's instruction to stop at three; recorded so the
    option is not lost.
