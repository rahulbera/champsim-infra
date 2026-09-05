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

16. **2026-09-05 21:23Z — DaCapo installed in the guest.** 6.0 GB zip copied over
    slirp under KVM in **28 s** (~214 MB/s), SHA-256 verified *inside* the guest,
    unzipped to 15 GB. Guest disk 24 G used of 61 G.
    Layout gotcha: the launcher jar is **not** inside the extracted directory —
    it unpacks as a sibling, `/home/ubuntu/dacapo-23.11-MR2-chopin.jar`, next to
    `dacapo-23.11-MR2-chopin/{dat,jar,launchers,stats}`. `jar/` holds only the
    agent jars.

17. **2026-09-05 21:26Z — What DaCapo's cassandra actually is.** It starts a real
    Cassandra and drives it with **YCSB Client 0.17.0, CoreWorkload, 100,000
    records, 2,000,000 requests per iteration** at `-s large` — server and client
    in ONE JVM, no cluster, no external process. That is exactly the shape that
    makes it tractable here, and it is the same YCSB/Cassandra pairing the
    literature uses.
    Sizes available for cassandra: `small`, `default`, `large` only (no `huge`).

18. **2026-09-05 21:31Z — The iteration-alignment problem dissolved.** I had
    planned a guest-side watcher to tail DaCapo's output and arm the trigger after
    warmup N. Unnecessary, for two reasons:
    * 2M requests per iteration means an iteration is *long and steady*. The
      capture never needs to finish one under TCG; it only needs the JVM
      mid-stream. So: warm up under KVM at native speed, snapshot mid-iteration,
      restore under TCG, and the remaining requests supply all the window runtime.
    * The plugin's `trigger=` is a **HOST** path, not a guest one. The trigger is
      armed by touching a file on the host, so no guest-side coordination is
      needed at all.
    Dead end paid for on the way: the first run was launched inside an ssh with a
    15-minute timeout, which would have killed the JVM before it could be
    snapshotted. Relaunched detached with `nohup setsid ... < /dev/null &`.
    Related trap, seen twice now: ssh to this guest frequently times out at 120 s
    while **the remote command succeeds** (the 15 GB unzip completed this way).
    Check the artifact; never infer failure from the ssh timeout.

19. **2026-09-05 21:44Z — Snapshot `dc_cass_a` taken at 35% of the request
    stream** (~700,000 of 2,000,000 requests served), JVM RSS 1.6 GB against a
    pinned 1 GB heap. Heap and GC are pinned explicitly
    (`-Xms1g -Xmx1g -XX:+UseG1GC -XX:ParallelGCThreads=2 -XX:ConcGCThreads=1`)
    rather than inherited from ergonomics, so the trace is reproducible and the
    name can state them honestly — default ergonomics would size the heap from
    guest RAM and silently change meaning if the guest were resized.

20. **2026-09-05 21:42Z — Recorded deviation: `-t 1`, where DaCapo's published
    statistics used `-t 32`.** Our whole corpus is single-client-thread (`1t`:
    memtier 1 thread, the MongoDB driver 1 thread), so `-t 1` keeps this trace
    comparable to memcached/Redis/RocksDB/MongoDB. The cost is that our measured
    LLC rate will **not** be directly comparable to DaCapo's published 5719
    misses/M-instr for cassandra. Flagged to the researcher; internal consistency
    chosen over external comparability, and reversible.

21. **2026-09-05 21:49Z — Mistake with a cost, recorded: the guest was massively
    over-provisioned with RAM, and `savevm` paid for it.** The J1 canary snapshot
    was 2.15 GiB and took ~30 s. `dc_cass_a` blew past 20 GB and ran for minutes,
    because `savevm` writes all *touched* guest RAM and the 15 GB DaCapo unzip had
    filled the guest's page cache with it. The workload itself needs ~2-3 GB
    (JVM RSS 1.6 GB against a 1 GB heap); the guest was given **24 GB**.
    Two consequences: the monitor is blocked for the whole write (an `info
    snapshots` query timed out at 115 s and *looked* like a hang), and the TCG
    restore has to read all of it back.
    **Fix for kafka and tomcat: `-m 8G`, and drop the guest page cache
    (`sync; echo 3 > /proc/sys/vm/drop_caches`) immediately before `savevm`.**
    Neither changes the workload — page cache holding a decompressed archive is
    not part of what we are tracing — and together they should cut the snapshot
    by roughly an order of magnitude.
    Note for whoever reads this next: the two background waiters watching the
    savevm were killed mid-flight, which looked alarming. It was harmless —
    `savevm` runs inside QEMU, not in the monitor client, so killing the client
    does not interrupt the write. Confirmed by watching the qcow2 keep growing.

22. **2026-09-05 21:59Z — `dc_cass_a` measured 23.6 GiB**, confirming entry 21's
    diagnosis exactly. Guest RAM 24 GB, of which `free` showed **22,074 MB of
    buff/cache** — almost all of it the decompressed DaCapo archive, none of it
    workload data. The JVM itself was 1,924 MB.

23. **2026-09-05 22:00Z — A second waiter bug of my own, worth recording because
    the failure was invisible.** I watched for savevm completion by polling the
    qcow2 for a *stable file size*. That condition never becomes true: the guest
    is live and Cassandra keeps writing its commitlog and sstables, so the image
    grows forever. The waiter sat in its loop long after savevm had finished.
    What actually settled it was checking QEMU's CPU time in `/proc/PID/stat` —
    ~3.5 cores of guest execution is a *running* VM, not a snapshot write — and
    then simply asking the monitor. **Ask the monitor; do not infer VM state from
    file sizes.**

24. **2026-09-05 22:00Z — Dropped the guest page cache and re-snapshotted as
    `dc_cass_b`.** `sync; echo 3 > /proc/sys/vm/drop_caches` took buff/cache from
    22,074 MB to 241 MB without touching the JVM. Then let Cassandra run a further
    two minutes *before* snapshotting, so the page cache refills with its own
    sstables rather than being cold at restore.
    This is a realism improvement as well as a size one: the old snapshot's page
    cache held a 15 GB unzipped archive, which is not part of the workload and
    would have sat in the traced guest's memory for no reason. Snapshotting
    straight after the drop would have gone too far the other way, leaving the
    restored guest doing cold-start I/O that a warm Cassandra node would not do.
    Worth restoring twice (profile, then capture), so paying this once is cheap.

25. **2026-09-05 22:00Z — Preflight audit launched before the first JVM capture.**
    Four read-only dimensions, each finding adversarially verified: (a) whether the
    plugin handles TB invalidation / re-translation correctly, which no prior
    workload could have exercised because only a JIT rewrites executable code at
    the same guest PC; (b) what `vcpus=` actually selects and whether
    `sample_clock=user` counts on the selected vcpu or globally — if globally, every
    SGAP we derive is wrong by the vcpu count; (c) the exact gap semantics behind
    `SGAP = (user - K*N)/(K-1)`; (d) an audit of the three already-shipped tlists
    against the kratos2 catalogue. Dimension (a) is the one that could produce a
    plausible-looking but wrong trace, silently.

26. **2026-09-06 22:06Z — CORRECTION: entry 24's fix did not work, and the
    mechanism I gave for it was wrong.** `dc_cass_b` came out at **23.6 GiB**,
    byte-for-byte the same size class as `dc_cass_a`, despite `free` showing
    buff/cache down from 22,074 MB to 283 MB at snapshot time.
    Why it cannot work: `savevm` serialises **guest RAM as QEMU sees it**, and
    QEMU has no visibility into the guest's notion of "free". Dropping the page
    cache marks pages free *inside the guest*; it does not zero them. QEMU's only
    size optimisation here is skipping zero pages, and these pages still hold the
    old archive bytes, so they are written out in full. Guest RAM *usage* is
    irrelevant — **guest RAM *size* is what savevm costs**, for every page ever
    touched since boot.
    The real fix is therefore the one I should have applied first: **boot the
    guest with less RAM**. `-m 8G` for kafka and tomcat. (Zeroing free memory in
    the guest before snapshotting would also work, since QEMU elides zero pages,
    but that is a workaround for an over-provisioned guest, not a fix.)
    Not redoing cassandra over this: a 23.6 GiB restore off NVMe is ~1-2 minutes,
    we restore twice, and 415 G is free. The cost is real but small, and
    re-running the load and warmup would cost ~30-40 minutes of KVM time.
    `dc_cass_b` is still the snapshot to use — not because it is smaller, but
    because its page cache holds Cassandra's own sstables instead of 15 GB of
    decompressed benchmark archive.

27. **2026-09-06 22:06Z — Reclaimed the superseded snapshot.** `dc_cass_a`
    deleted (23.6 GiB); `j1_canary_a` kept at 2.15 GiB as the reproducible
    artifact behind the J1 result.

28. **2026-09-06 22:14Z — Preflight audit results. Four things matter.**

    **(a) The staleness risk I was most afraid of DOES NOT EXIST.** A JIT is the
    first thing this pipeline has traced that rewrites executable code at the same
    guest PC, and I expected the plugin might emit stale translate-time metadata.
    It cannot. `tb_trans_cb` allocates a fresh `InsnMeta` per instruction *per
    translation* (`champsim_tracer.c:976`) and reads bytes from guest RAM at that
    moment (:985). The decisive guarantee is in QEMU itself, not the plugin:
    `plugin_gen_insn_start` does `g_array_set_size(insn->insn_cbs, 0)` on every
    translation (`accel/tcg/plugin-gen.c:428-430`), discarding the previous
    translation's callback array and its userdata pointers. There is no
    PC-indexed cache or map anywhere in the plugin, filter or converter — branch
    type and register sets are derived offline from each record's own bytes.
    **JIT-rewritten code traces correctly.**

    **(b) A real memory leak, but measured rather than assumed — NOT a blocker.**
    `champsim_tracer.c:976` leaks one 32-byte chunk per instruction per
    translation; nothing frees it and QEMU never will. For a C server the sum is
    bounded by the static text size, which is why four campaigns never hit it. A
    JIT makes it unbounded. But measured live against the running profile pass:
    ~200 MB/h permanent, against 32 GB free with QEMU at 25.4 GB RSS; the TCG code
    buffer self-limits at 1 GiB. A 4-8 h capture leaks ~0.5-1.5 GB. Proceed, watch
    `VmHWM`, fix afterwards with `qemu_plugin_register_flush_cb`.

29. **2026-09-06 22:14Z — (c) THE SGAP FORMULA MIXES UNITS, and it has already
    affected two shipped trace sets.** This is the important one.
    `SGAP = (user - K*N)/(K-1)` subtracts `K*N` — a window length counted in **all**
    instructions (`chunk_insn_count`, :527, ":816", comment at :807: "Window length
    always counts EVERY instruction") — from `profile_user_insns`, a **user-only**
    counter (:731-734). The gap itself advances only on user instructions
    (:777-779, :839-841). Only the numerator mixes units; the `K-1` denominator is
    right. Consequence: the windows always cover LESS of the run than intended, and
    cluster toward its beginning. Never more.
    Checked against both finished campaigns, and they bracket a 20-point range of
    user fraction, which rules out coincidence:
    * **Redis**: T=20,659,920,896, U=7,691,636,216 (f=0.372), SGAP=672,909,054 ->
      windows span 12.17e9 = **58.9%** of the trajectory (model predicts 59.2%).
    * **RocksDB**: T=27,757,267,052, U=15,782,260,124 (f=0.569), SGAP=2,695,565,031
      -> span 23.97e9 = **86.4%** (model predicts 86.3%).
    **The shipped traces are not corrupt** — every window is internally valid,
    exactly 1e9 instructions, decode_fail 0, geometry exact. What is reduced is ROI
    *coverage*: they sample the leading 59% / 86% rather than the whole run.
    Correct form, from the two numbers the PROFILE line already prints:
        **SGAP = (user / (K-1)) * (1 - K*N/total)**
    which reproduces the full span for both campaigns exactly. Clock-aware: under
    `sample_clock=all` the right gap is `(total - K*N)/(K-1)`.
    Galling detail: `memcached-recapture-runbook.md:792` already says *"Ignore the
    `sample_gap = (user - K*N)/(K-1)` hint the plugin prints at exit"* and uses a
    ratio form instead. The runbook attributed it to memcached's unbounded loop
    rather than to a unit error, so the two later finite-trajectory campaigns
    applied the hint literally anyway. **A warning without its reason did not
    survive contact with the next campaign.**

30. **2026-09-06 22:14Z — (d) THE CASSANDRA CAPTURE WOULD HAVE BEEN NEARLY
    MEANINGLESS, and this is the finding that paid for the audit.**
    `vcpus=1` selects **vCPU index 1 of 4**, and *nothing pins the JVM to it*.
    Verified live in the running guest: java pid 2178 has affinity mask `f` (all
    four vCPUs), **89 threads distributed 23/27/21/18 across CPUs 0/1/2/3**, no
    `taskset`, no `numactl`, and `/proc/cmdline` carries no `isolcpus`.
    So the trace would have been "whatever CFS happened to schedule on vCPU 1" —
    roughly a quarter of the JVM's threads, arbitrarily interleaved, plus unrelated
    guest work. It would have looked like a plausible Cassandra trace and been a
    scheduler artifact.
    Every prior campaign in this corpus mapped the *whole* traced workload onto the
    traced vCPU — memcached (`taskset -acp 1` plus a per-thread affinity assertion,
    and `isolcpus=1,2`), Redis (`isolcpus=1,2`), RocksDB, MongoDB. The MongoDB log
    states the reason explicitly: pinning puts eviction and checkpoint work *in the
    trace* instead of leaving it as invisible sibling work ChampSim never sees.
    I inherited `vcpus=1` from `launch_tcg_redis.sh` without inheriting the pinning
    that makes it mean something. Entry 7 parked this as an open question on
    2026-09-05 20:40Z and I had not closed it before starting the capture path.
    **Fix, and do NOT widen `vcpus=`** (each vCPU runs an independent sampling
    state machine with its own manifest, so four vCPUs give four unaligned window
    sequences, not one 4-core interval; and the plugin has no atomics under MTTCG):
    keep `vcpus=1` and `-smp 4`, and pin the JVM to guest CPU 1 after restore with
    `sudo taskset -acp <javapid>` — **the `-a` is load-bearing**, without it only
    the main thread moves and the workers run elsewhere, so `vcpus=1` would trace
    an idle core.
    `dc_cass_b` was snapshotted with the JVM unpinned, so the pin has to be applied
    and then re-snapshotted, or re-applied after every restore.

31. **2026-09-06 22:21Z — SGAP finding independently re-derived from our own
    artifacts, not taken on trust.** Using the saved Redis manifest and the
    PROFILE numbers in the Redis log: observed span 12,172,565,711 = **58.92%** of
    T=20,659,920,896; the model predicts 59.20%. The decisive cross-check is the
    gap unit: the manifest's stride minus the window is 1,787,936,203 *total*
    instructions for a configured gap of 672,909,054, a ratio of **0.3764**
    against a measured user fraction of **0.3723** — i.e. the gap really is
    user-clocked while the window is not, exactly as claimed. Correct SGAP for
    that run would have been 1,457,537,220, **2.17x** what was used.

32. **2026-09-06 22:22Z — Lost the first PROFILE line, my error, and fixed the
    cause.** The 12-minute profile pass ran to completion, but the plugin emits
    its PROFILE line to **QEMU's stderr at exit**, and I had QEMU's stderr going
    only to a tmux pane — which dies with the process. `tmux capture-pane` after
    `quit` returned nothing. This is the "do not filter the output of a script
    whose failure mode is silence" rule wearing a different hat: I had not
    filtered it, I had merely failed to *persist* it.
    Fixed in `scripts/launch_tcg_java.sh`: `exec 2> >(tee -a "$QLOG" >&2)`, so
    stderr goes to `logs/java-tcg-qemu.log` as well as the pane.
    Cheap loss — that pass has to be redone anyway, because it profiled an
    UNPINNED JVM (entry 30) and its user fraction would not have described the
    workload we are about to trace.

33. **2026-09-06 22:22Z — Second deviation from house procedure fixed.** The
    profile invocation omitted `trigger=`, while the capture invocation had it.
    Since `tracing_enabled` defaults true and is cleared only by `trigger=`, the
    profile pass counted from the first instruction after `-loadvm` while the
    capture pass counts only from the trigger — so the two passes measured
    different spans, and the post-restore TCG retranslation transient landed in
    one and not the other. The memcached runbook carries `trigger=` in both
    (`memcached-recapture-runbook.md:778`); the java script had drifted.
    Now `vcpus=1,trigger=$TRIG,profile=on`. **Runbook rule: assert the profile and
    capture invocations carry the same `vcpus=` AND the same `trigger=`, rather
    than trusting two adjacent script lines to stay in sync.**

34. **2026-09-06 22:22Z — MongoDB v1 conversion complete: five OK.**
    Mix check on w00004, which had been flagged for running a different profile:
    the five windows read (user/kern/branch/mem)
    w00000 51.7/48.3/15.5/48.3, w00001 54.8/45.2/16.0/48.2,
    w00003 55.4/44.6/16.0/48.2, w00002 56.7/43.3/16.8/46.6,
    w00004 56.1/43.9/17.7/44.4.
    That is a **smooth gradient, not a bimodal split** — branch rises and memory
    falls monotonically across the ordering, with w00004 only 0.9 pt of branch and
    2.2 pt of memory beyond w00002. Nothing resembling the memcached theta=0.6
    regime split (86% kernel / 76% mem / 7% branch against a completely different
    profile), and no window anywhere near the reject band. **All five kept.**
    One honest note: w00003 converted to 999,985,056 instructions rather than
    exactly 1e9 — 14,944 short, 0.0015%, the residue of idle-loop filtering. The
    ship gate was relaxed from `== 1e9` to `>= 999,900,000` deliberately and this
    is recorded rather than silently rounded.

35. **2026-09-06 22:26Z — Pinning applied and PROVEN, not assumed.**
    Restored `dc_cass_b` under KVM (new `scripts/boot_java_kvm_restore.sh`, which
    boots with `-loadvm` so the JVM stays warm rather than starting cold).
    Before: java pid 2178, **89 threads**, affinity mask `f`, last-run CPUs
    cpu0:23 cpu1:17 cpu2:17 cpu3:18 — i.e. tracing vCPU 1 would have captured
    roughly 17/89 of the workload's threads, interleaved with whatever else the
    guest scheduled there.
    `sudo taskset -acp 1 2178` -> **all 89 threads report mask `2`** (CPU 1 only),
    zero exceptions.
    A trap inside the verification, worth recording: field 39 of `/proc/<tid>/stat`
    is the *last* CPU a thread ran on, and it is **stale for sleeping threads**.
    Immediately after pinning it still read cpu0:14 cpu1:45 cpu2:9 cpu3:6, which
    looks like the pin failed. It had not. The decisive measurement is a busy-tick
    delta from `/proc/stat`: over 20 s, **cpu1 took 1,925 ticks of a possible
    2,000 (96%), cpu0/cpu2/cpu3 took 1, 1, 0**. Check utilisation, not the
    `processor` field.
    Snapshotted as `dc_cass_c` so the pin is carried by the snapshot and does not
    have to be re-applied on every restore (guest affinity is guest kernel state
    and `savevm` serialises it).
    Consequence for the trace: the whole of Cassandra + YCSB + G1 + JIT now runs
    on the single traced vCPU, which is what makes `1t` and "single-core trace"
    mean the same thing here as they do for memcached, Redis, RocksDB and MongoDB.
    Throughput drops roughly 4x, which is the honest cost of a single-core slice
    and not a defect.

36. **2026-09-06 22:36Z — `dc_cass_c` written, `dc_cass_b` deleted.** The pin is
    carried by the snapshot: after restore under TCG the JVM reports
    `affinity=2`, 88 threads, **zero** not bound to cpu1. (88 rather than 89 —
    one thread exited across the boundary, which is normal JVM behaviour.)
    So guest affinity does survive `savevm`/`-loadvm`, as expected, and the pin
    does not need re-applying per restore.

37. **2026-09-06 22:36Z — Both script fixes confirmed working in the live run.**
    The plugin now reports `Trigger: WAITING ... Tracing is DORMANT` on the
    profile pass, so profile and capture measure the same span and the
    post-restore TCG retranslation transient is excluded from both. And QEMU's
    stderr is landing in `logs/java-tcg-qemu.log`, so the exit-time PROFILE line
    can no longer die with the tmux pane.

38. **2026-09-06 22:33Z — `scripts/sgap.py` written, so the correction from
    entry 29 is encoded once instead of redone by hand each campaign.**
    It carries the derivation, the unit argument, and both measured
    counterexamples *in the file*, deliberately: the memcached runbook already
    warned "ignore the hint the plugin prints at exit" but recorded only the
    symptom, not the reason, and the next two campaigns used the hint anyway.
    A warning without its reason did not survive contact with the next campaign.
    Self-check: fed the Redis and RocksDB PROFILE numbers, it reproduces the two
    hint values that were actually used (672,909,054 -> 59.20% span;
    2,695,565,031 -> 86.33%) against observed 58.92% / 86.35%, and gives corrected
    gaps that span 100.00% of both runs.

39. **2026-09-06 22:50Z — Cassandra PROFILE (pinned, trigger-gated).**
    `PROFILE: 59,398,369,721 instructions (22,061,233,774 user, 37,337,135,947
    kernel)` over 703 s of traced execution.
    * **user fraction 37.14%** — kernel-heavy, and close to Redis's 37-41%.
      Not what I would have guessed for a JVM. The likely source is YCSB talking
      to Cassandra over loopback (syscall-heavy) plus TCG idle-loop churn on the
      traced vCPU whenever the JVM blocks: under TCG the idle loop is *emulated*,
      not halted, so it burns real instructions (see
      `docs/pipeline/task-tcg-idle-loop-filtering.md`). `trace_filter` strips that
      afterwards, which is why the converted window counts come in a hair under
      1e9.
    * **84.5 MIPS** on the pinned single vCPU under TCG — far better than the
      ~20 MIPS I had estimated from the dormant-phase counter. The two reconcile:
      the dormant phase counted 1.84e9 instructions, which at 84.5 MIPS is 21.8 s,
      matching the ~20 s between the guest becoming responsive and the trigger
      being armed. The estimate was wrong because I had guessed the dormant
      duration, not because the rates disagree.
    * T = 59.4e9 is the **widest trajectory in the campaign** — 2.9x Redis's
      20.66e9 and 2.1x RocksDB's 27.76e9.

40. **2026-09-06 22:51Z — Capture launched with the CORRECTED gap.**
    `sgap.py --total 59398369721 --user 22061233774 --windows 5 --len 1e9`
      -> **SGAP = 5,051,044,149**, spanning **100.00%** of the profiled run.
      The plugin's own exit hint would have been 4,265,308,444, spanning
      **85.75%** — i.e. this capture would have quietly lost the last ~14% of the
      trajectory, in the same way Redis lost 41% and RocksDB 14%.
    Running: `sample_len=1e9, sample_gap=5051044149, sample_count=5,
    sample_clock=user, capture_pa=on, values=on, vcpus=1`, restored from
    `dc_cass_c` (JVM pinned to the traced vCPU).
    Expected wall-clock: gaps are 4 x 5.051e9 *user* instructions = ~13.6e9 total
    each at 84.5 MIPS (~644 s), plus 5e9 instructions of window at the slower
    record-writing rate — order of 15-25 minutes, not hours, because the plugin
    only pays the write cost inside windows.

41. **2026-09-06 23:08Z — FIRST JVM TRACE CAPTURED. Five windows, and the gap
    correction is visible in the result.**
    Manifest (all-instruction stream positions):
    ```
    0  start           0   1,000,000,000
    1  start 14,676,048,464   1,000,000,000
    2  start 28,360,562,939   1,000,000,000
    3  start 39,708,300,222   1,000,000,000
    4  start 57,112,456,348   1,000,000,000
    ```
    Span 58,112,456,348 against a profiled 59,398,369,721 = **97.84% trajectory
    coverage**, against **58.92% (Redis)** and **86.35% (RocksDB)** under the
    plugin's own hint. Raw 4.31/3.62/4.19/3.23/4.39 GB.
    The strides are deliberately uneven (13.68e9 - 17.40e9 in all-instruction
    terms) because the gap is user-clocked and the JVM's instantaneous user
    fraction swings between **0.308 and 0.488** against a profile average of
    0.371 — GC and compilation phases against steady request serving. That
    variation is the workload, not an error, and it is exactly why the gap must
    be derived from a measured ratio rather than assumed.
    QEMU was stopped with a monitor `quit`, never a signal: the audit confirmed a
    SIGKILL loses the in-flight chunk and leaves an unterminated zstd frame.

42. **2026-09-06 23:11Z — CORRECTION to entry 39: the kernel share is NOT TCG
    idle-loop noise.** I had attributed part of Cassandra's 63% kernel fraction to
    the emulated idle loop. `trace_filter` reports **`filtered=0 (0.0%)`** on all
    five windows — there is no idle-loop content to remove. The kernel time is
    genuine: YCSB and Cassandra talking over loopback is syscall-heavy, plus GC
    and page-fault work. The windows' own user fractions read 44.0-49.0%, higher
    than the 37.14% whole-trajectory profile average, consistent with windows
    landing on request-serving rather than on the quieter phases.
    Worth stating plainly because the earlier claim was a guess dressed as an
    explanation, and the measurement disagrees with it.

43. **2026-09-06 23:10Z — Trace name fields all MEASURED, not assumed** — the
    lesson from Redis's wrong `rd94`. Read out of the shipped benchmark itself:
    * `cassandra5.1pre` <- `jar/cassandra/cassandra-1ba458c-pre-5.1.jar`
    * `100Kx1KB` <- `dat/cassandra/ycsb/workload-large` `recordcount=100000`,
      CoreWorkload default 10 fields x 100 B = 1 KB
    * `rd50wr50` <- `readproportion=0.5`, `updateproportion=0.5`, scan/insert 0
    * `zipf0.99` <- `requestdistribution=zipfian`, YCSB default constant 0.99
    * `jdk21g1gc1G` <- OpenJDK 21.0.12, `-XX:+UseG1GC`, `-Xms1g -Xmx1g` pinned
      explicitly rather than left to ergonomics
    Note the corpus consequence: at **rd50wr50** this is by far the most
    write-heavy workload in the set (memcached/Redis rd99wr01, RocksDB/MongoDB
    rd95wr05), which is real diversity rather than a fifth read-mostly KV store.
