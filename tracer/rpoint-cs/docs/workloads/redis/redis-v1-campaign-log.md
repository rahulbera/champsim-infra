# Redis v1 Capture Campaign — Running Log

**Status:** IN PROGRESS. Append-only trail, enumerated and timestamped UTC, to be
compacted once the campaign completes. Dead ends recorded deliberately.

**Premise:** Redis is memcached's twin — same `memtier_benchmark` driver (a Redis
tool originally), same key patterns, same zipf, same snapshot flow — so the
memcached v2 parameters were expected to transfer. They partly did not, and entry
7 is why.

**Key difference from RocksDB:** Redis is in-memory, so "non-resident" means the
dataset must exceed the **LLC** (2.5+3 MB), not RAM. The lever is memcached's, not
RocksDB's.

---

1. **2026-09-05 12:22Z — Guest built, reusing the RocksDB cloud-init seed.** Fresh
   40 GB overlay on the same Ubuntu 24.04 base, 6 vCPU / 12 GB.

2. **2026-09-05 12:23Z — dpkg lock race.** `apt-get install redis-server` failed
   because cloud-init was still installing the seed's package list and held
   `/var/lib/dpkg/lock-frontend`. My `set -e` plus a redirect to `/dev/null`
   swallowed the error and produced a silent no-op. *Lesson: wait for
   `cloud-init status` to report `done` before touching apt, and never redirect
   the error stream of a step whose failure is silent.*

3. **2026-09-05 12:26Z — Redis 7.0.15 + memtier (commit 5694a3d) installed.**
   Redis config written with `save ""` and `appendonly no` — background RDB forks
   would otherwise inject unrelated work into the traced core. `io-threads 1`,
   pinned to the traced vCPU 1.

4. **2026-09-05 12:26Z — Guest tuned BEFORE preloading.** Redis holds its dataset
   in RAM, so tuning that requires a reboot (isolcpus, THP, ASLR) must happen
   before the load, or the dataset is thrown away. `isolcpus=1,2`.

5. **2026-09-05 12:28Z — Preload verified, the check memcached v1 lacked.**
   1,500,000 keys x 4000 B via `--key-pattern=P:P` (mandatory for full coverage),
   same `--key-prefix` and range as the query phase. Verified in the server's own
   state: `dbsize=1500000` exactly, `memtier-1` and `memtier-1500000` both
   present, `strlen=4000`, `used_memory 5.84G`.

6. **2026-09-05 12:29Z — Gate 3.e PASSES: 8,532 instructions per key lookup**
   (memcached's hard stop is 12,000), hit ratio 1.0000 with `keyspace_misses:0`.

7. **2026-09-05 12:47Z — THE MEMCACHED PARAMETERS DO NOT TRANSFER.** A 200 M
   pilot, converted and inspected before committing to a full capture, produced
   **73.9% kernel / 73.5% memory ops / 7.7% branches** — statistically the same
   degenerate bulk-copy profile as the memcached theta=0.6 windows rejected the
   same morning (86% / 76% / 7.2-7.4%), and nothing like accepted memcached
   theta=0.8 (54-61% / 40% / 19%).

   **Diagnosis.** `perf stat -p <redis pid>` reported 68.2% kernel *natively*,
   counting only Redis's own instructions. The trace captures everything on
   vCPU 1 including softirq and the TCP path, which `perf -p` excludes. With
   `--multi-key-get=16 --data-size=4000` each request moves **64 KB** through the
   network stack, and Redis's per-key logic is leaner than memcached's
   (8,532 instructions/lookup), so the copy swamps it.

   **Not an overload artifact.** The TCG profile showed 80.1% kernel against
   68.2% native — a ~12-point tracer inflation, real but modest, unlike
   theta=0.6's collapse. The degenerate mix is intrinsic to this *parameter
   choice*, not to the tracer.

   **Fix:** 4000-byte values were inherited from memcached, where that size was
   chosen for slab-class behaviour. Redis is typically used for small values.
   `--data-size=512` cuts copy-per-key 8x while leaving Redis's per-key work
   unchanged; `--key-maximum` raised to 8,000,000 to hold dataset size roughly
   constant (~4.1 GB).

   **Cost of catching it here:** ~15 minutes for the pilot, against a 5x1e9
   capture plus hours of conversion.

8. **2026-09-05 13:02Z — Generalised gate adopted for all future captures.**
   Run a short pilot (200 M instructions is enough), convert it, and read
   `branch %` and `mem %` BEFORE committing to a full capture. Reject bands, from
   three independent observations across two workloads: **branch < 10% together
   with mem > 70% means a bulk-copy regime** that will post high MPKI while being
   trivially prefetchable. Healthy so far: memcached theta=0.8 and RocksDB v2 at
   17.5-19% branch, 40-50% mem.

9. **2026-09-05 13:16Z — Re-preload at 512 B verified.** 8,000,000 keys x 512 B,
   `dbsize=8000000` exactly, `strlen=512`, `used_memory 5.41G` — dataset size
   held essentially constant against the 4000 B run's 5.84 GB, so value size is
   the only variable that changed.

10. **2026-09-05 13:25Z — THE 512 B FIX WORKS.** Second 200 M pilot:

    | | kernel | memory | branch |
    |---|---|---|---|
    | pilot 1, 4000 B | 73.9% | 73.5% | **7.7%** REJECT |
    | pilot 2, 512 B | **59.3%** | **52.9%** | **14.2%** PASS |
    | memcached theta=0.8 (accepted) | 54-61% | 40% | 19% |

    Kernel share now inside memcached's accepted range and both reject criteria
    cleared. Value size, not skew or concurrency, was the whole problem.

11. **2026-09-05 13:20Z — DEAD END: swapping the client inside a TCG guest is far
    too slow.** The first theta-scout script restored the snapshot under TCG and
    then restarted memtier *inside* the TCG guest at each theta. Under 50-150x
    slowdown, memtier startup plus 16-connection setup plus reaching steady state
    never completed inside the 540 s budget; the plugin logged
    `WARNING: Trigger was never activated! ... Skipped 1703555261 instructions
    while dormant` and produced 29-byte manifests with no data. *Rule: everything
    except the capture itself belongs under KVM at native speed. Restore -> swap
    client -> verify -> savevm under KVM; TCG only ever restores and records.*
    Rewritten that way, each theta costs ~6 minutes instead of failing.

12. **2026-09-05 13:22Z — My own output filter hid the failure twice.** Both the
    scout loop and the rewritten prep script appeared to produce "no output"
    because I piped them through `grep -vE 'Warning|^$'` while `set -e` aborted
    early on a failing ssh. *Rule: never filter the output of a script whose
    failure mode is silence; check the exit status or log to a file.*

13. **2026-09-05 13:42Z — theta=0.99 captured for comparison.** Same 200 M window,
    same dataset, only `--key-zipf-exp` changed. First signal is in the raw size
    before any conversion: **652.8 MB at theta=0.99 vs 829.9 MB at theta=0.8** for
    identical instruction counts — 21% less entropy, consistent with a more
    concentrated access pattern touching less distinct data. That is the direction
    the arithmetic predicted, and it is the tension worth flagging: higher theta
    is more realistic but more LLC-resident, and LLC-residency is the exact v1
    defect. Deciding on measured footprint (unique 4 KB pages, data-footprint MB),
    not on raw size or on my estimate.

14. **2026-09-05 13:52Z — Snapshot tag discipline held.** Four snapshots now exist
    on the Redis image (`rd_redis_a` 4000 B, `rd_redis_b` 512 B, `rt099`
    theta=0.99). Each capture got a NEW tag; `savevm` deletes-then-writes on a
    reused tag, so reusing one would have destroyed a good snapshot.

15. **2026-09-05 14:43Z — Full theta=0.8 capture.** Profile pass gave
    20,659,920,896 instructions (37.2% user), so `sample_gap = (7,691,636,216 -
    5e9)/4 = 672,909,054`. Five windows, each exactly 1,000,000,000 instructions,
    20 GB raw. Observed gaps 1.788/1.788/1.798/1.798e9 total instructions imply
    **37.63% user** against the profile's 37.2% — the sampling clock tracked to
    within half a point, as it did for RocksDB.

16. **2026-09-05 15:15Z — Regime gate: spread 4.90%, right at the threshold.**
    comp_bytes ranged 4,136,225,120 to 4,344,437,665 (4.90% of mean) against
    RocksDB's <1%. Judged acceptable on *shape* rather than magnitude: the series
    is a monotonic drift (4136 -> 4151 -> 4319 -> 4293 -> 4344) across 13e9
    instructions of a live server, not the bimodal split that exposed memcached
    theta=0.6 (one window 29% smaller than its siblings). Confirmed by the
    instruction mix at the first 10 M of conversion: 14.1-14.4% branch,
    52.3-53.3% mem across all five windows — tight and clear of the reject band.
    *Lesson: window-size spread is a cheap early screen, but its SHAPE decides;
    a drift and a split need different responses.*

17. **2026-09-05 16:30Z — TRAP: `ssh -n` and heredocs are mutually exclusive.**
    Having correctly learned that a NESTED ssh inside a `bash -s` heredoc eats the
    remaining script from stdin (entry: use `-n` there), I then applied `-n` to
    the OUTER ssh that was *receiving* a heredoc. `-n` redirects stdin from
    /dev/null, so the heredoc was discarded and the command produced no output at
    all — the same silent-no-op signature as the bug it was meant to prevent.
    **Correct rule: `-n` on ssh calls made INSIDE a piped script; never on the ssh
    that is being fed the script.**

18. **2026-09-05 20:45Z — Conversion complete: five OK.** All five
    windows exactly 1,000,000,000 instructions, `decode_fail 0`. Final mixes
    14.0-14.4% branch / 52.3-53.3% memory ops, 39-41% user / 59-61% kernel.
    Compression 124-129:1 (~4.0-4.1 bytes/instr). Well clear of the reject band
    (branch < 10% AND mem > 70%). Window spread on instruction count 0% — all
    five hit the 1e9 target exactly.

19. **2026-09-05 20:45Z — Bug caught in the ship script before it ran.**
    I had written the catalogue rows as `version2.1/redis/<name>`. The existing
    167 rows use **bare basenames**. Had it run, the catalogue would have carried
    two incompatible row formats and `sha256sum -c` from the champsim/ root
    would have silently stopped matching for every prior entry. Verified the
    format against the memcached and RocksDB rows first; fixed before execution.

20. **2026-09-05 21:33Z — SHIPPED AND REGISTERED.** Order held exactly:
    rename -> re-verify under the new names (5/5, 1e9 each) -> hash locally ->
    rsync to kratos2 -> `sha256sum -c` **on kratos2** (5/5 OK, the gate) ->
    append to CHECKSUMS.sha256 (**167 -> 172**) -> only then delete.
    Independent post-check on kratos2: 172 lines, 5 redis rows, **0 duplicate
    basenames**, 5 files, 16 GB.

21. **2026-09-05 21:35Z — Provenance preserved before reclamation.**
    The sampling manifest and the checksum list were copied into the repo
    (`redis-v1-t08-manifest.txt`, `redis-v1-t08-checksums.sha256`) *before*
    the raws were deleted. The manifest shows five windows evenly spaced at a
    ~2.788e9 instruction stride, each exactly 1e9 — no gap structure of the kind
    that exposed the memcached theta=0.6 regime split. That file is the only
    remaining evidence of how the windows were positioned; deleting it with the
    raws would have repeated the audit's central failure.

22. **2026-09-05 21:36Z — Reclaimed 59 GB on minitron** (380G -> 439G):
    5 converted traces (19 GB), 5 raws + manifest (20 GB), `redis-guest.qcow2`
    (21 GB, carrying snapshots rd_redis_a / rd_redis_b / rt099). All five traces
    verified on kratos2 and registered before anything was deleted.

23. **2026-09-05 21:37Z — tlist written**: `scripts/tlists/redis_v1.yml`,
    built from the catalogue's CHECKSUMS rows (not local copies), 5 entries,
    validates as YAML, no tabs, and all five checksums cross-checked against the
    catalogue — 0 mismatches.
