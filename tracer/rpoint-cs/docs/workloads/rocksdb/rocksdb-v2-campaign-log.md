# RocksDB v2 Capture Campaign — Running Log

**Status:** IN PROGRESS. This is a raw, append-only trail written as the work
happens, not a finished document. It will be compacted and reorganized into a
coherent runbook once the campaign completes.

**Format:** enumerated entries, each timestamped UTC. Dead ends and corrected
mistakes are recorded deliberately — they are the entries that were lost last
time, and the 2026-09-04 audit's central finding is that the v1 reasoning existed
only in one shell history.

**Machine:** minitron (32 cores, 60 GB RAM, NVMe). Chosen over rnadig because a
deliberately non-cache-resident RocksDB is I/O-bound by construction and
rnadig's `/mnt/sherlock` is a 5400 rpm HDD (`savevm` measured there at
~130 MB/min).

---

1. **2026-09-05 09:36Z — Patched QEMU built on minitron.** QEMU 9.2.4 copied to an
   isolated tree, AVX hflag fix applied at `cpu_post_load` (one occurrence,
   anchor matched once). Configure+build took 27 s on 32 cores, which was fast
   enough to distrust: verified `ccache` absent and `target_i386_machine.c.o`
   timestamped inside the build window, so it was genuinely recompiled.

2. **2026-09-05 09:52Z — `aio=native` unsupported; rebuilt with AIO.** First boot
   failed on `aio=native was specified, but is not supported in this build`.
   Installed `libaio-dev` + `liburing-dev` and rebuilt; chose `aio=io_uring`
   (io_uring 2.5), which is the right backend for an NVMe-backed, I/O-heavy
   guest. *Lesson: build QEMU with the AIO backends before the first boot, not
   after.*

3. **2026-09-05 09:58Z — Bad option probe hung the tool.** Ran
   `qemu-system-x86_64 -drive file=/dev/null,...,aio=X` to test whether a backend
   was accepted; with no other arguments that starts a VM rather than validating
   an option, and it hung for 10 minutes. *Lesson: check build features from
   `config-host.mak` / `meson-log.txt` or `ldd`, never by starting QEMU.*

4. **2026-09-05 10:09Z — Guest built from the local cloud image.** The Ubuntu
   24.04 base (`noble-server-cloudimg-amd64.img`, 596 MB) was already on disk
   from the SWE campaign, so no 5.9 GB image transfer from rnadig was needed. The
   SWE seed authorized a `swe-agent-guest` key I do not hold, so a new
   cloud-init seed was built with my own key plus the RocksDB build
   dependencies baked in.

5. **2026-09-05 10:20Z — DRIVER DEFECT: every record held the same value.** The
   v1 driver fills the value buffer *once* before the load loop and `Put()`s the
   same bytes for all N records. Consequences: (a) Snappy compressed the
   duplication away, so a `-n 20000000 -v 1024` DB was 6.3-9.2 GB instead of
   ~21 GB and DB size was not predictable from `n*v`; (b) with the plugin's
   `values=on`, every captured value would be identical letter soup — a
   degenerate value channel. Patched to derive each record's bytes from a
   xorshift64 seeded by `(seed, record id)`: distinct, deterministic,
   reproducible.

6. **2026-09-05 10:26Z — Value fix verified by measurement.** 200 k x 1024 B =
   204.8 MB logical produced a 252.5 MB DB — a 1.23x *expansion* where v1 saw
   3.06x *compression*. DB size is now predictable: **~1.05 GB per million
   records at v=1024** after compaction.

7. **2026-09-05 10:31Z — 32 M-record DB loaded: 33.5 GB, 413 SSTs.** Load 210 s +
   full CompactRange 110 s on NVMe.

8. **2026-09-05 10:38Z — DRIVER LIMITATION: no attach mode.** The driver refuses
   to open an existing DB (`exists and is non-empty. Use --overwrite to wipe.`)
   and always reloads. That is incompatible with the snapshot workflow, which
   needs load-once / run-as-a-separate-step so a warm guest can be `savevm`'d.
   Added `--attach` (skip load and post-load compaction, reuse the DB).

9. **2026-09-05 10:45Z — THE v1 DEFECT IS FIXED.** Steady state at alpha=0.99 —
   the *most* cache-friendly skew, so the pessimistic case — with `-c 1`,
   `--no-fadvise`, `--no-warmup-scan`, 33.5 GB DB against 15 GB RAM:
   **block-cache hit rate 38.87%** (4 threads) against v1's **97.40%**. Nothing
   exotic: alpha=0.99 is the YCSB standard, 95/5 read/write is a normal KV mix,
   and the pressure comes from the dataset exceeding RAM.

10. **2026-09-05 10:52Z — `--roi-secs` is a WALL-CLOCK budget.** Default 240 s.
    Under TCG's 50-150x slowdown that would trace a sliver of the workload and
    give no warning. Neutralised by running the ROI effectively unbounded
    (200000 s) and letting the plugin's *instruction-bounded* sampling define
    the windows — the same fix memcached used with `--test-time=100000`.

11. **2026-09-05 10:58Z — `pgrep` 15-char truncation, third occurrence.**
    `rocksdb_driver_v2` is 17 characters, so `pgrep -x` matches nothing;
    `pgrep -f` then matched the tmux wrapper as well and `-n` picked the wrong
    pid, producing `Problems finding threads of monitor`. Same class of bug as
    `memtier_benchmark` (17 chars) in the memcached campaign. *Rule: resolve
    processes by `readlink /proc/PID/exe`, never by name or cmdline pattern.*

12. **2026-09-05 11:05Z — Tracer decision settled by measurement, against my
    prediction.** I predicted that fixing cache-residency would push RocksDB into
    the kernel and rule PIN out. Measured with `perf stat`: **84.6% user / 15.4%
    kernel** at 4 threads — the repo's documented PIN mapping was correct and my
    reasoning-by-analogy from memcached was wrong. Single-threaded, however, it
    is **69.0% user / 31.0% kernel**, because one thread warms the 1 GB block
    cache alone so misses per operation rise. Researcher chose QEMU anyway, to
    keep one trace family (kernel + real physical addresses) comparable with the
    memcached v2 six.

13. **2026-09-05 11:20Z — Single core chosen over 4 threads, and it is more
    correct, not just simpler.** With `-t 4` the traced core's block cache is
    warmed by three *untraced* sibling threads; ChampSim simulates one core and
    would never see those fills, so the simulated miss rate would be
    systematically optimistic — the trace would carry the benefit of work absent
    from the trace. Mapping the whole workload onto one core removes that.
    Single-core steady state: **34.33% block-cache hit** (hit 223,258 / miss
    427,102), 100% key hit rate, 32,358 ops/s.

14. **2026-09-05 11:10Z — PLUGIN SAMPLING WAS NOT ON `main`.** The plugin's
    `sample_len=/sample_gap=/sample_count=/sample_clock=/profile=` feature —
    which the entire memcached v2 campaign depends on — was committed on
    `swe-agent-tracing` and never merged. rnadig hid this: same git HEAD
    (`124ce3b`), but `champsim_tracer.c` was 50,619 bytes there against 40,182 on
    main, because the branch version had been copied into main's working tree as
    uncommitted edits. Anyone cloning main and following the runbook would build
    a plugin that silently rejects the knobs the runbook passes. Brought across
    and pushed as **`b5c3d29`**; the repo's own Gate 2.b (`sampling_test.sh`) ran
    outside rnadig for the first time and reported ALL PASS.

15. **2026-09-05 11:41Z — Snapshot `rd_v2_a` taken.** 7.89 GiB, VM_CLOCK 52:46,
    38 s, with the workload warm and mid-ROI.

16. **2026-09-05 11:43Z — TCG restore failed: `Unknown savevm section or instance
    'kvmclock' 0`.** A KVM snapshot carries a `kvmclock` device section that has
    no VMState handler under TCG. `CPUSTR` sets `kvmclock=off` as a *CPU
    feature*, which does not stop QEMU instantiating the *device*. `docs/README.md`
    says this path needs **two** patches and I had applied only the AVX one.

17. **2026-09-05 11:45Z — The kvmclock patch existed on exactly one machine, in a
    non-git directory.** rnadig's `~/softwares/qemu-9.2.4` (an unpacked tarball,
    not a repo) carried it. The repo documents the *approach* in
    `kvmclock-patch-details.md` but not the diff. It touches **three** files, not
    one — `hw/i386/kvm/clock.c` plus the `if (kvm_enabled())` guard around
    `kvmclock_create()` in **both** `pc_q35.c` and `pc_piix.c`; patching only
    `clock.c` would not have created the device under TCG. Captured as
    `kvmclock-tcg-restore.patch` so it stops being a one-machine artifact.

18. **2026-09-05 11:47Z — KVM to TCG restore works; both patches proven
    functionally.** Guest resumed under TCG reporting `uptime = 52 minutes`,
    matching the snapshot's VM_CLOCK — a genuine restore, not a reboot. No
    kvmclock error, and no `#UD` storm or panic, which is the AVX patch's
    functional proof that disassembly could not provide.

19. **2026-09-05 11:51Z — Profile pass (TCG, no records written).**
    **27,757,267,052 instructions = 15,782,260,124 user + 11,975,006,928
    kernel**, i.e. **56.8% user / 43.2% kernel** on the traced vCPU over ~5.5 min,
    at ~84 Minsn/s. Higher kernel share than the 31% `perf` measured, as expected:
    `perf -p` counts only the driver process, while the plugin counts everything
    executing on vCPU 1 including interrupt and softirq work.

