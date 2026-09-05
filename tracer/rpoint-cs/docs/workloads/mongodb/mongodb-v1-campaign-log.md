# MongoDB v1 Capture Campaign — Running Log

**Status:** IN PROGRESS. Append-only, enumerated, timestamped UTC. Dead ends
recorded deliberately. Compact into a runbook only when the campaign closes.

**Why MongoDB is the hardest of the three.** It is the *union* of the two shapes
already traced: WiredTiger has an internal cache (like RocksDB's block cache)
**and** there is a network layer (like Redis/memcached). So both levers apply and
both failure modes are reachable — cache-residency (RocksDB v1, 97.40% hit) and
the bulk-copy regime (Redis at 4000 B values, memcached theta=0.6).

---

1. **2026-09-05 16:40Z — Guest built; cloud-init raced properly this time.** Fresh
   150 GB overlay on the shared Ubuntu 24.04 base, 6 vCPU / 12 GB, cores 10-31 so
   the Redis converters on 0-9 are undisturbed. Waited for `cloud-init status` to
   report `done` before touching apt — the dpkg-lock trap that produced a silent
   no-op on the Redis guest.

2. **2026-09-05 16:45Z — MongoDB is not in Ubuntu 24.04.** The server package was
   dropped over the SSPL licence, so it comes from MongoDB's own apt repo
   (`repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0`). Installed **mongod
   8.0.29**, plus `libmongoc-1.0` / `libbson-1.0` **1.26.0** for the driver.

3. **2026-09-05 16:50Z — Driver: adapted, not invented.** Rejected YCSB, the
   standard MongoDB driver, because it is Java: a JVM client *inside a TCG guest*
   risks becoming the bottleneck and starving the traced server — the idle-core
   failure class. Instead wrote `mongo_driver.c` against libmongoc, mirroring
   `rocksdb_driver_v2.cpp` phase-for-phase: same CLI shape, same `zipfian.h`, same
   warmup/ROI split, same `--cpus` pinning, same `champsim_roi_begin/end()`
   markers, same `--attach`. Keeps the three campaigns methodologically
   comparable and gives a light C client instead of a JVM.

4. **2026-09-05 16:52Z — Both RocksDB driver fixes carried forward by design.**
   Values are derived per record from a `(seed, id)` xorshift (so dataset size is
   predictable and the captured value channel is not degenerate), and `--attach`
   reuses an existing collection so the load-once / snapshot / restore-under-TCG
   workflow is possible.

5. **2026-09-05 16:55Z — Build friction, both trivial.** `-lm` was missing
   (`zipfian_zeta` uses `pow`), and one misleading-indentation warning. No
   libmongoc API surprises.

6. **2026-09-05 16:58Z — mongod pinned ENTIRELY to the traced vCPU.** MongoDB is
   genuinely multi-threaded (47 threads at rest: WT eviction, checkpointing,
   TTL monitors). Following the researcher's guidance to map the whole workload
   onto one core, `taskset -c 1 mongod` puts eviction and checkpoint work *in the
   trace* rather than leaving it as invisible sibling work that ChampSim would
   never see — the same reasoning that made single-threaded RocksDB more correct
   than 4 threads, not merely simpler.

7. **2026-09-05 17:00Z — Smoke test passed first try.** 100 k docs x 1024 B:
   loaded in 0.8 s, ROI ran, 13,624 reads with **100% found** (no keyspace
   mismatch). Storage **956 bytes per document**; `dataSize` 105.8 MB against
   102.4 MB logical (1.03x), so sizing is predictable rather than
   compression-dependent — the per-record-value fix working as intended.
   WT cache hit rate **99.81%** (228,864 requested, 426 read in): fully
   cache-resident, which is the RocksDB-v1 shape and exactly what must be broken.

8. **2026-09-05 17:02Z — Sizing for non-residency.** 11 GB guest RAM, WT cache
   pinned to 1 GB (default would be ~50% of RAM = 5.5 GB), leaving ~9 GB of page
   cache. At 956 B/doc, **40 M docs = ~38 GB**, a 3.5x dataset-to-RAM ratio
   (RocksDB v2 ran 2.2x). Load launched.

9. **2026-09-05 16:52Z — Load: 40 M docs, 598 s.** `storageSize` 43,367,505,920 B
   (42 GB on disk) against 11 GB guest RAM — a **3.9x** dataset-to-RAM ratio
   (RocksDB v2 ran 2.2x). Load rate ~70-125 k docs/s via bulk inserts of 1000.

10. **2026-09-05 17:00Z — RESIDENCY BROKEN: WT cache hit ~43.5%.** The WiredTiger
    counters are CUMULATIVE since mongod start, so they must be differenced:
    across the probe, `pages requested from cache` rose 147,282,127 ->
    150,575,007 (+3,292,880) while `pages read into cache` rose 7,426 ->
    1,868,364 (+1,860,938), giving a hit rate of **43.5%** (miss 56.5%). The
    smoke test on a 100 MB dataset measured **99.81%**, so the lever works.
    Comparable to RocksDB v2's 34.33%. Throughput 3,876 ops/s — an order of
    magnitude below Redis, as expected when ~76% of reads leave the page cache.
    *Trap: reporting the raw cumulative counters would have shown a 98.8% "hit
    rate" that is an artifact of the bulk load, not the query phase.*

11. **2026-09-05 19:03Z — Snapshot `mg_v1_a`**: 11.8 GiB, VM_CLOCK 34:39, 150 s.
    Larger and slower than the others because the guest has 12 GB of RAM largely
    filled with page cache over a 42 GB dataset.

12. **2026-09-05 17:07Z — KVM->TCG restore clean on a third workload.** Guest came
    up at `uptime = 32 minutes`, matching the snapshot clock; mongod alive on
    vCPU 1 with 49 threads. Both QEMU patches (kvmclock, AVX hflag) have now held
    across memcached, RocksDB, Redis and MongoDB.

13. **2026-09-05 17:08Z — The plugin trigger is independent of the driver's ROI
    markers.** At snapshot time the driver was still inside its 240 s untraced
    warmup, and under TCG that warmup takes far longer in real time — so the
    guest resumed still in "warmup". This does not matter: the QEMU plugin starts
    on the *trigger file*, and warmup and ROI run the identical Zipfian loop. The
    `champsim_roi_begin/end()` markers only matter for the PIN path.

14. **2026-09-05 17:12Z — PILOT PASSES ON THE FIRST ATTEMPT.** 200 M window:
    **user 49.3% / kern 50.7% / branch 15.3% / mem 50.0%, decode_fail 0.**

    | workload | branch | mem |
    |---|---|---|
    | memcached theta=0.8 | 19.0% | 40% |
    | RocksDB v2 | 17.5% | 50% |
    | **MongoDB v1** | **15.3%** | **50.0%** |
    | Redis theta=0.8 | 14.2% | 53% |
    | *rejected* (Redis 4 KB, Redis theta=0.99, memcached theta=0.6) | 7.7% | 71-76% |

    The near-even user/kernel split sits between RocksDB's user-leaning 57/43 and
    Redis's kernel-leaning 37/63 — what a workload that is *both* a storage engine
    and a network service should look like.

    **MongoDB is the only one of the three that cost no rejected pilot, and the
    reason is that it inherited the other two campaigns' levers up front:** WT
    cache pinned to 1 GB instead of the ~5.5 GB default came from RocksDB; 1 KB
    documents instead of 4 KB came from Redis. Both were set before the first
    capture rather than discovered after one.

15. **2026-09-05 17:23Z — Profile and full capture.** Profile: 46,036,539,554
    instructions (68.0% user), so `SGAP = (31,304,410,582 - 5e9)/4 =
    6,576,102,645`. Note the profile reports 68% user where the pilot *trace*
    measured 49.3%: the profile spans the TCG restore and settle as well as steady
    operation, so it is a different phase mix. It does not affect sizing — the gap
    is counted in user instructions either way — but two unexplained numbers in a
    log are worse than one explained one.

16. **2026-09-05 17:42Z — Five windows captured, each exactly 1e9.** Gaps
    9.60-9.75e9 total instructions for a 6.576e9 user gap, implying **67.8% user**
    against the profile's 68.0% — the sampling clock tracked again.

17. **2026-09-05 17:45Z — THE WINDOW-SPREAD GATE NEEDED CORRECTING, and MongoDB
    is what corrected it.** comp_bytes spread came out at **19.61% of mean**
    (3.65 GB down to 2.98 GB) — four times my 5% threshold and not far off the
    ~29% of the memcached theta=0.6 windows that were discarded. Rather than
    reject, I converted the first 10 M of the largest and smallest windows and
    compared:

    | window | size | user | branch | mem |
    |---|---|---|---|---|
    | w00000 (largest) | 3.65 GB | 53.1% | 16.1% | 47.9% |
    | w00004 (smallest) | 2.98 GB | 54.0% | 15.3% | 50.1% |

    Under one point apart on user and branch, two on memory — **the same regime,
    differing only in compressibility.** Most likely different portions of the
    40 M-key space plus WiredTiger checkpoints landing in some windows and not
    others.

    **Corrected rule: window-size spread is a SCREEN, not a verdict.** memcached
    theta=0.6's 29% spread was disqualifying because it came WITH a mix difference
    (86% kern / 76% mem against 51% / 40%); MongoDB's 19.6% comes with no mix
    difference at all. Spread > 5% means *check the extreme windows' mix*; reject
    only if the mix diverges too. Applying the flat threshold would have discarded
    a good capture — the same error in the opposite direction to the one that let
    theta=0.6 through in the first place.
