# Memcached re-capture runbook (v2 campaign, 2026-09)

> **Target host:** `rnadig` = `safari-rnadig0.ee.ethz.ch`, reached as
> `ssh -J kratos2 rahbera@safari-rnadig0.ee.ethz.ch`.
> **Why there:** kvmclock-patched QEMU 9.2.4, the memcached guest image, a clean
> toolchain with no conda hijack, 433 GB free on `/mnt/sherlock`, and it is idle.
> Verified inventory in §0.2.
> **Prerequisite reading:** `docs/verification/2026-09-04-memcached-rocksdb-capture-audit.md`
> — why the v1 traces were unusable. Do not start without it.
> **Deliverable:** 10 ChampSim v2 traces — 5 windows × 1 B *usable* instructions
> at each of θ = 0.8 and θ = 0.6, single traced vCPU.
> **Review status:** this document was adversarially reviewed by four independent
> critics (executability, correctness, arithmetic, destructive risk) and rewritten
> against 23 findings. Where a step looks over-specified, it is because the
> unspecified version was shown to fail.

---

## 0. Before you touch anything

### 0.0 Start here — the handoff contract

You are executing this on **rnadig**, and this document plus the repo it lives in
are everything you get. Read §0 and §1 in full before running anything.

**Your job starts** at §0.4 and **ends** when §7 has produced ten validated
`.champsim2.zst` files and §8's tlist is written. **Shipping traces to the
simulation host and running the sweep are NOT yours** — report and stop (§8).

**Bootstrap — this is step one, and it is self-contained.** rnadig authenticates
to GitHub as `rahulbera` (verified 2026-09-04) and can read both branches:

```bash
mkdir -p /mnt/sherlock/rahbera/mc-recapture/{repo,images,traces,logs,out,run,cache}
cd /mnt/sherlock/rahbera/mc-recapture/repo
git clone git@github.com:rahulbera/champsim-infra.git    # https:// also works
cd champsim-infra
# The sampling plugin is NOT on main. Take that one file from the branch:
git fetch origin swe-agent-tracing
git show origin/swe-agent-tracing:tracer/rpoint-cs/plugin/champsim_tracer.c \
    > tracer/rpoint-cs/plugin/champsim_tracer.c
git show origin/swe-agent-tracing:tracer/rpoint-cs/plugin/tests/sampling_test.sh \
    > tracer/rpoint-cs/plugin/tests/sampling_test.sh
chmod +x tracer/rpoint-cs/plugin/tests/sampling_test.sh
git status --short   # expect: champsim_tracer.c MODIFIED, sampling_test.sh UNTRACKED
                     # (the test is new on main). Do NOT commit either.
```

Then read, in this order, before touching anything else:

1. `tracer/rpoint-cs/docs/verification/2026-09-04-memcached-rocksdb-capture-audit.md`
   — why the previous campaign failed. Grade A/B findings are verified; Grade C/D
   are deductions and forecasts.
2. This document's §0.3 (hard rules) and §0.5 (when to stop).
3. §1 (the locked parameters).

**If you read nothing else, these five facts are why the gates exist:**

- The v1 client and store used **disjoint keyspaces** — every `GET` missed and no
  value was ever read. Every mechanical gate passed anyway. That is Gate 3.d.
- The v1 skew constant was **never set**; memtier silently defaulted to θ = 1.0.
  That is Gate 3.b.
- `trace_sanity_check --check` **cannot** detect either defect — it tests
  branch-type invariants only. Passing it means nothing about footprint.
- The plugin's trigger is **one-shot, has no stop**, and fails silently if armed
  before the workload runs.
- The v1 documentation's own numbers were wrong in four places. **Trust the
  counters, not the prose** — including this document's prose.

**Progress and reporting.** Keep a state file and append to it at every phase
boundary and every gate:

```bash
echo "$(date -u +%FT%TZ) <phase> <gate> <PASS|FAIL> <numbers>" >> $MCROOT/logs/PROGRESS.log
```

Report to the user: after Gate 2.c (build done), after Gate 3.e (the go/no-go
`I_req`), after §5.2 (`SLEN`/`SGAP` derived, pilot footprint), after each θ's
Gate 6.a, and at the end. Report immediately on any §0.5 stop condition. A phase
that has to be redone starts from its own section, not from §0.

### 0.1 What this campaign changes, and why

The v1 traces did not exercise the memory system. Three causes, in order of size
(derivations in the audit):

1. **The client and the store never shared a keyspace.** YCSB wrote
   `usertable-user<fnv64>`; memtier read `memtier-<N>`, because `--key-prefix` was
   never passed. Every `GET` missed, so no value was ever read out.
2. **No request pipelining**, so the trace was dominated by the loopback TCP path
   — a 32 % L1I miss rate next to 1.147 LLC MPKI. *(The "~26,000 instructions per
   request" figure used for sizing here is **modelled**, not measured; Gate 3.e
   measures it for real and every prediction in §9 is linear in it.)*
3. **The skew constant was never chosen** — `--key-zipf-exp` absent, so memtier
   defaulted to θ = 1.0.

v2 fixes all three: one driver (memtier for both phases, matching `--key-prefix`),
`--pipeline=16`, and an explicit θ.

### 0.2 Verified inventory on rnadig (checked 2026-09-04)

| Thing | Path / value | State |
|---|---|---|
| Patched QEMU | `~/qemu-custom/bin/qemu-system-x86_64` | 9.2.4, **kvmclock patch present** (verified in `~/softwares/qemu-9.2.4/hw/i386/kvm/clock.c`) |
| QEMU plugin header | `~/qemu-custom/include/qemu-plugin.h` | present — plugin Makefile's default `QEMU_PREFIX` resolves |
| Guest image | `/mnt/sherlock/rahbera/qemu-tracing/images/ubuntu-guest-memcached.qcow2` | 15.66 GB, one snapshot: `memcached_rd95` (8.99 GiB state) |
| Guest credentials | `/mnt/sherlock/rahbera/qemu-tracing/images/user-data.yaml` | user `researcher`, password **`safari123`**, `sudo` NOPASSWD |
| PIN tracer (RocksDB, later) | `~/arishem/champsim/tracer/obj-intel64/champsim_tracer_mt_roi_v3.so` | built |
| v1 simulator + results | `~/arishem/` | the fork that produced every v1 number in §9.1 |
| Host | 12 cores, **31 GB RAM**, KVM present, load 0.01, `tmux` present, second user `zhlang` logged in | idle |
| Disk | `/` 25 GB free (98 %) · `/mnt/sherlock` **433 GB free** (group-writable) | see §0.3 |
| Toolchain | gcc 11.5, Python 3.12.3, glib 2.80, `zstd.h`, `capstone/capstone.h`, `cmake`, `sshpass` | **no conda** (`CC`/`CXX` empty) |
| Network | github reachable | ✓ |

**Not on rnadig:** any ChampSim checkout. `/mnt/sherlock/rahbera/qemu-tracing/`
holds artifacts only.

### 0.2a Already done — §0.0 through §2 were executed on rnadig on 2026-09-04

The bootstrap and the whole build phase have been run and passed. `$MCROOT` exists,
the repo is cloned with the sampling plugin in place, and every binary is built:

| Gate | Result |
|---|---|
| §0.0 bootstrap | clone + both `git show` redirections applied; `sample_len=` ×4 present |
| build (plugin, inspector, filter, converter, trace_sanity_check, trace_cutter) | all clean; capstone is packaged, so the audit's no-root workaround is **not** needed here |
| **2.a** converter golden | `ALL PASS (30/30)` + `PASS 14/14` |
| **2.b** `sampling_test.sh` | **ALL PASS — 10 pass, 0 fail, 1 skip.** Exactly 3 chunks, every window exactly 20,000 instructions, window starts `len+gap` apart, profile mode reports counts and writes nothing, and `gap=0` sampling is **byte-identical to `rotate=`** |
| **2.c** binaries present | clean |

The one skip is Task 3, the `sample_clock=user` test, which needs a guest kernel
and initrd the BIOS harness does not have. **Our campaign uses
`sample_clock=user`**, so that path is first exercised for real by §5.1's profile
pass — treat §5.1's output as its verification and check the user/total split looks
sane before sizing anything from it.

**Start at §3.** Re-run §2's gates only if something downstream looks wrong.

### 0.3 Hard rules

- **`source ~/.mcrc` is the first line of every shell on rnadig** — every SSH
  session, every tmux pane, every retry. Nothing here works without it.
- **Never write to `/`.** 25 GB free at 98 %. Everything goes under `$MCROOT`.
  Before §6 and §7, and every 10 minutes during them:
  `avail=$(df --output=avail -k / | tail -1); [ "$avail" -gt 10485760 ] || { echo "/ below 10 GB — STOP"; exit 1; }`
- **The v1 image is the only copy and is not reproducible.** First action of §3:
  ```bash
  ORIG=/mnt/sherlock/rahbera/qemu-tracing/images/ubuntu-guest-memcached.qcow2
  chmod a-w "$ORIG"
  stat -c '%s %Y %a' "$ORIG" > $MCROOT/logs/orig.fingerprint
  ```
  Re-check that fingerprint at the end of every phase.
- **Ban list.** No `qemu-img snapshot -d|-a|-c` on any image at any point. No
  `qemu-img convert|rebase|commit`. Do **not** run `scripts/boot_tcg_trace.sh`,
  `restore_kvm.sh` or `boot_kvm.sh` — they are v1, they target `$HOME` on `/`, and
  `boot_tcg_trace.sh:24` deletes prior traces *before* validating its arguments.
  The only path any `-drive file=` may name is `$MCROOT/images/mc-v2.qcow2`.
- **Do not delete `tracestore/`** (83 GB of abandoned v1 raw) under any
  circumstances in this campaign. If space tightens, stop and report the numbers.
- **Every QEMU launch runs inside tmux.** `-serial mon:stdio` ties the VM to its
  terminal and a capture outlives any SSH session.
  ```bash
  tmux new -d -s mcvm
  tmux send-keys -t mcvm 'source ~/.mcrc; <the qemu command>' Enter
  tmux capture-pane -p -S -3000 -t mcvm > $MCROOT/logs/<phase>.console.log
  ```
  Every `telnet 127.0.0.1 4444` and every host-side gate runs in your *ordinary*
  SSH session — that is the "another terminal" §3.5 means.
- **One VM at a time.** Before any launch:
  ```bash
  qemu_running || { echo 'a QEMU of mine is running — STOP'; exit 1; }
  ss -ltn | grep -E ':(2222|4444|4445|11211)\b' && { echo 'port held — STOP'; exit 1; }
  ```
  A second QEMU whose `hostfwd` bind silently fails leaves your `telnet 4444` and
  `nc 11211` talking to the **old** guest — including §3.5's `savevm`.
  `qemu_running` (defined in §0.4) matches by **executable**, deliberately. Both
  obvious alternatives are broken and were caught on rnadig by running them:
  `pgrep -f qemu-system-x86_64` matches its own command line and fires every time,
  and `pgrep -x qemu-system-x86_64` matches **nothing** — Linux truncates process
  names to 15 characters and that name is 19, so `pgrep` warns and returns empty.
  A guard that silently never fires is worse than one that always does.
- **No `killall`, `pkill` or `sudo` on rnadig itself.** `zhlang` is logged in. If
  you are about to, you are in the wrong shell.
- **`THETA` and `OUTDIR` are set per phase, never inherited.** Before every
  launch: `: "${OUTDIR:?}" "${PLUGIN:?}"; case "$OUTDIR" in $MCROOT/*) ;; *) echo "OUTDIR escapes MCROOT — STOP"; exit 1;; esac`

### 0.4 The environment file — write this immediately after §0.0's clone

```bash
cat > ~/.mcrc <<'EOF'
export MCROOT=/mnt/sherlock/rahbera/mc-recapture
export REPO=$MCROOT/repo/champsim-infra
export PLUGINDIR=$REPO/tracer/rpoint-cs/plugin
export CONVDIR=$REPO/tracer/rpoint-cs/converter
export TOOLS=$REPO/tools/trace_sanity_check
export PLUGIN=$PLUGINDIR/champsim_tracer.so
qemu_running() {   # match by EXECUTABLE — see the note in 0.3
  local QBIN p found=""
  QBIN=$(readlink -f "$HOME/qemu-custom/bin/qemu-system-x86_64")
  for p in /proc/[0-9]*; do
    [ "$(readlink -f "$p/exe" 2>/dev/null)" = "$QBIN" ] && found="$found ${p#/proc/}"
  done
  [ -n "$found" ] && { echo "QEMU running:$found"; return 1; }
  return 0
}
export -f qemu_running
export CPUSTR='Haswell,pmu=on,kvmclock=off,kvmclock-stable-bit=off,kvm-asyncpf=off,kvm-steal-time=off,kvm-pv-eoi=off,kvm-pv-unhalt=off,kvm-poll-control=off,kvm-pv-ipi=off,kvm-pv-sched-yield=off,kvm-pv-tlb-flush=off,kvm-asyncpf-int=off,hle=off,rtm=off,pcid=off,invpcid=off,tsc-deadline=off'
EOF
source ~/.mcrc && cd $MCROOT
```

`pmu=on` is load-bearing: without it the guest has no architectural PMU
(`~/softwares/qemu-9.2.4/target/i386/cpu.c:8431`, and `:6688` zeroes CPUID leaf
0xA), and Gate 3.e's `perf stat` returns `<not supported>`.

### 0.5 When to stop and ask

Not only on gate failure. Stop, report, and wait if **any** of these occur:

- a shell variable would expand empty, or a path lands outside `$MCROOT`;
- a file this runbook references does not exist;
- two sections appear to contradict each other;
- you are about to delete anything under `/mnt/sherlock/rahbera/qemu-tracing/`;
- `/` drops below 10 GB, or `/mnt/sherlock` below 100 GB;
- Gate 3.e returns `I_req > 12,000`;
- a QEMU exits unexpectedly, or `coredumpctl list --since "-1h"` shows a new core.

Do **not** improvise around a locked parameter in §1.

---

## 1. Parameters — the complete v2 configuration

Locked. Do not vary anything not marked *derived*.

### Server (GUEST)

```bash
memcached -m 8192 -t 1 -C -c 1024 \
          -o hashpower=20,no_hashexpand \
          -l 127.0.0.1 -p 11211 -u memcache
```

| Flag | v1 | v2 | Why |
|---|---|---|---|
| `-t` | 4 | **1** | All request work in the single traced stream instead of split four ways. |
| `-o hashpower` | 20 (auto-expanded to 21 mid-load) | **20,no_hashexpand** | At N = 1.5 M, `1.5 × 2²⁰ = 1,572,864 > 1,500,000`, so expansion cannot fire; `no_hashexpand` (`memcached.c:4881`) makes that structural. Chain load factor λ = N/2²⁰ = **1.43**, preserving ~0.7 non-target chain probes per GET — the most reliable irregular-miss source in the design. |
| `-m` | 8192 | **8192** | N = 1.5 M at slab chunk 4544 B needs 6,522 MiB of 8,192 → **zero evictions**. v1 needed 10.22 GB against 8.59 GB and evicted ≥366 K. |
| `-l` | `0.0.0.0` | **`127.0.0.1`** | Nothing outside the guest needs to reach it. See §4 for the consequence. |

### Client — phase 1, preload (KVM, no tracing)

```bash
memtier_benchmark -s 127.0.0.1 -p 11211 -P memcache_text \
  --key-prefix=memtier- --key-minimum=1 --key-maximum=1500000 \
  --key-pattern=P:P --ratio=1:0 --data-size=4000 \
  --threads=4 --clients=1 --pipeline=32 -n allkeys --hide-histogram
```

**`P:P` is mandatory.** Two mechanisms depend on it:
`memtier_benchmark.cpp:972-973` divides the `-n allkeys` request count among
clients **only** when the pattern string is exactly `"P:P"`; `client.cpp:138-150`
partitions the key *range* across clients only when the SET-side pattern is `'P'`.

With `S:S` the request count is **not** divided, so all four clients issue
1,499,999 SETs each and each walks the whole range from `--key-minimum`: `cmd_set`
comes back 4× (~6.0 M), the preload takes 4× as long, and `--key-maximum` itself is
never written. `P:P` gives 4 × 375,000 disjoint SETs covering 1..1,500,000 exactly
once.

### Client — phase 2, measurement (runs under TCG)

```bash
memtier_benchmark -s 127.0.0.1 -p 11211 -P memcache_text \
  --key-prefix=memtier- --key-minimum=1 --key-maximum=1500000 \
  --key-pattern=Z:Z --key-zipf-exp=${THETA} \
  --ratio=1:16 --multi-key-get=16 --data-size=4000 --pipeline=1 \
  --threads=2 --clients=8 --test-time=100000 --hide-histogram
```

`THETA` ∈ {`0.8`, `0.6`}. Identical prefix and key range in both phases, so SETs
overwrite rather than grow the store and `curr_items` stays pinned at N.

| Flag | v1 | v2 | Why |
|---|---|---|---|
| `--key-prefix` | **unset** (→ `memtier-`) | explicit, both phases | The v1 defect. |
| `--key-zipf-exp` | **unset** (→ 1.0) | `0.8` / `0.6` | θ = 0.8 captures 93 % of the total available miss-rate lift between 0.99 and 0.4 under the Che/LRU correction; 0.6 is the low-skew arm and matches the RocksDB α grid. |
| `--pipeline` | never used (→ 1) | **16** | memcached's `-R` (`memcached.c:255`) defaults to 20, so 16 amortises one event-loop trip without forcing a second. |
| `--threads/--clients` | 4 / 4 | 2 / 8 | Same 16 connections, on 2 memtier vCPUs. |
| `--data-size` | 4000 | **4000** | Keeps `unique_ppages` high and warm-up robust. Above the production mode — see §9.3. |
| `--ratio` | 1:19 | **1:19** | One fewer variable. |

**`--multi-key-get=16` is the single biggest lever in this campaign, and it was
added on measurement, not theory.** Gate 3.e on 2026-09-04 measured, on the warm
guest, instructions per *key lookup*:

| config | I_lookup | lookups/s | avg latency |
|---|---|---|---|
| single-key GET, `--pipeline=16` | 19,196 | 140 K | 1.78 ms |
| **`--multi-key-get=16`, `--pipeline=1`** | **4,463** | 347 K | **0.38 ms** |
| `--multi-key-get=16`, `--pipeline=16` | 4,201 | 401 K | 5.26 ms |
| `--multi-key-get=32`, `--pipeline=16` | — | 772 K | 10.61 ms, no throughput gain |

**4.30× fewer instructions per lookup.** `--pipeline` batches 16 *commands* that
still produce 16 responses, so the per-request fixed cost (~94 % of instructions:
syscall entry/exit, skb alloc, page zeroing, cgroup accounting, TCP transmit) is
paid 16 times. A multiget is **one** command and **one** response: paid once.
This is also the production pattern — batched multigets dominate Atikoglu's
Facebook study — so it moves the trace toward a representative deployment.

**`--pipeline` stays at 1.** Stacking it on multiget buys 6 % and drives average
latency to 5.26 ms (256 keys in flight per connection). No latency-sensitive cache
is operated that way. 32-key multigets are worse still: 10.61 ms for no throughput.
Both were rejected on realism, not on numbers.

**Open question, recorded 2026-09-04 and not yet decided.** `--ratio` is a
*command*-level ratio, so with 16-key multigets the **key-level** write fraction is
1 SET per 16×16 = 256 GETs = **0.4 %**, not the 5 % of v1 and not the ~3 %
(30:1 get:set) of Atikoglu's ETC pool. Restoring 5 % key-level writes would need
`--ratio≈1:1.2`, which floods the run with single-key SETs and throws away most of
the multiget gain. Proceeding at 0.4 % and disclosing it; revisit if the study
needs write traffic. *(An earlier commit message called this move "5.0 % → 5.9 %,
immaterial" — that was the command-level figure and it was wrong.)*

`--ratio` becomes **1:16** so every multiget batch is full — the GET side of
`--ratio` caps `--multi-key-get` (`client.cpp:641-642`), and `1:19` would give
ragged batches of 16 then 3. Write fraction moves 5.0 % → 5.9 %, immaterial.

**Do not use `--randomize`** — seeds from the clock.

### Guest topology

**Use `-smp 7 -m 12G`** — a change from v1's `-smp 5`, not a continuation. The
guest cmdline isolates 1-4, so vCPU 1 (memcached, the only traced vCPU) is shielded
while memtier and housekeeping share 0, 5 and 6 — vCPUs 5-6 do not exist at
`-smp 5`. `memcached_rd95` is never restored, so its topology constrains nothing;
what does is that the `mc_v2_*` snapshot from §3.5 must be restored at exactly
`-smp 7` in §4.

### Plugin

```
-plugin $PLUGIN,outdir=$OUTDIR,vcpus=1,\
        sample_len=$SLEN,sample_gap=$SGAP,sample_count=5,sample_clock=user,\
        trigger=$MCROOT/run/theta$THETA/trace_start,capture_pa=on,values=on
```

`SLEN` and `SGAP` are **derived in §5**. The trigger path is **per phase** — the
plugin `unlink()`s it both at init (`:1360`) and when it fires (`:366`), so a
shared `/tmp/trace_start` means whichever run polls first consumes the arm and the
other produces nothing.

---

## 2. Ship and build

### 2.1 Ship the repo

`main`'s plugin has **no sampling knobs** — `parse_args()` accepts only
`outdir, vcpus, limit, trigger, arch, capture_pa, values, rotate`. Sampling lives
on `origin/swe-agent-tracing` (`ae7daf0`, `f4147f8`, `e008016`). The plugin diff is
**263 insertions in one file and sampling-only**; the 10 deletions are just
`rotate_interval > 0` generalised to `chunking_active()`. Take that one file — do
**not** merge the branch (4,889 files, 1.68 M insertions of LLM cassettes).

**§0.0's bootstrap already did this** — the clone is a committed tree (no
locally-built `.o`, no `converter/zydis/` CMake cache with foreign paths, nothing
stale that would make `make` skip the rebuild Gate 2.a is meant to certify), and
the two `git show` redirections put the sampling plugin in place. Record the
provenance the build stamps into every trace:

```bash
source ~/.mcrc
{ echo "main:     $(git -C $REPO rev-parse --short=12 main)"
  echo "sampling: $(git -C $REPO rev-parse --short=12 origin/swe-agent-tracing) (plugin only)"
} | tee $REPO/PROVENANCE.txt $MCROOT/logs/PROVENANCE.txt
```

**Do not commit the two modified files, and do not merge the branch** (4,889
files, 1.68 M insertions of LLM cassettes).

*Fallback, only if rnadig ever loses GitHub access:* stage a committed tree
elsewhere with `git archive --format=tar HEAD | tar -x -C "$T"`, apply the same two
`git show` redirections into `$T`, then
`rsync -av -e 'ssh -J kratos2' "$T/" rahbera@safari-rnadig0.ee.ethz.ch:$REPO/`.
`rsync` creates only the last path component, so §0.0's `mkdir -p` must have run.

### 2.2 Build (on rnadig)

No conda here, so plain `make` is correct.

```bash
source ~/.mcrc
make -C $PLUGINDIR plugin inspector filter    # the clone has .git, so the
                                              # Makefile stamps CSTF_COMMIT itself
make -C $CONVDIR
make -C $REPO/tools/trace_sanity_check
make -C $REPO/tools/trace_cutter
```

**Gate 2.a — converter golden tests**
```bash
make -C $CONVDIR test        # REQUIRE: ALL PASS (30/30)  and  PASS 14/14
```

**Gate 2.b — the plugin actually has sampling**
```bash
bash $PLUGINDIR/tests/sampling_test.sh $MCROOT/logs/sampling_test
# BIOS-only boot, ~20 s, no disk. REQUIRE all checks PASS, including
#   "rotate= together with sample_len= is rejected"
```
`Unknown argument: sample_len=` means you shipped `main`'s plugin — go to §2.1.

**Gate 2.c — everything exists**
```bash
for f in $PLUGIN $PLUGINDIR/trace_filter $PLUGINDIR/trace_inspector \
         $CONVDIR/raw2champsim $TOOLS/trace_sanity_check \
         $REPO/tools/trace_cutter/trace_cutter; do
  [ -x "$f" ] || echo "MISSING $f"
done                          # REQUIRE: no output
```

---

## 3. Guest v2 provisioning (KVM — fast)

### 3.1 Protect the original, work on a copy

```bash
# HOST
source ~/.mcrc
ORIG=/mnt/sherlock/rahbera/qemu-tracing/images/ubuntu-guest-memcached.qcow2
chmod a-w "$ORIG"; stat -c '%s %Y %a' "$ORIG" > $MCROOT/logs/orig.fingerprint
qemu_running || { echo 'shut the running QEMU down before copying — STOP'; exit 1; }
[ -e $MCROOT/images/mc-v2.qcow2 ] && { echo 'copy exists — STOP and ask'; exit 1; }
cp "$ORIG" $MCROOT/images/mc-v2.qcow2 || { echo 'copy failed'; exit 1; }
[ "$(stat -c %s "$ORIG")" = "$(stat -c %s $MCROOT/images/mc-v2.qcow2)" ] || { echo 'size mismatch'; exit 1; }
qemu-img check $MCROOT/images/mc-v2.qcow2
qemu-img snapshot -l $MCROOT/images/mc-v2.qcow2      # expect: memcached_rd95
```

Retrying §3.1 after §3.5 has succeeded would discard `mc-v2.qcow2` **and** the
`mc_v2_*` snapshot behind it — hence the existence check.

### 3.2 Boot under KVM (HOST, in tmux)

Boot normally — **not** `-loadvm`. A fresh boot avoids inheriting v1's memcached
process and its YCSB data.

```bash
tmux new -d -s mcvm
tmux send-keys -t mcvm 'source ~/.mcrc; ~/qemu-custom/bin/qemu-system-x86_64 \
  -accel kvm -cpu $CPUSTR \
  -smp 7 -m 12G \
  -drive file=$MCROOT/images/mc-v2.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nographic -serial mon:stdio \
  -monitor telnet:127.0.0.1:4444,server,nowait \
  -qmp tcp:127.0.0.1:4445,server,nowait' Enter
```

`$CPUSTR` is used **verbatim in §3.2 and §4**. The eleven paravirt/kvmclock
disables and the `Haswell` model are what keep the snapshot restorable under TCG;
the `kvm-*` properties are plain CPUID bits, accepted and inert under TCG, so one
string serves both phases and the CPUID the guest sees does not change across the
restore. `pmu=on` is what makes Gate 3.e work.

Both forwards bind **loopback only** — `net/slirp.c` defaults `hostfwd` to
`INADDR_ANY`, and rnadig is on the department network with a guest whose password
is documented.

> Leaving the monitor: `Ctrl+]` then `quit` at the `telnet>` prompt. Typing `quit`
> at the `(qemu)` prompt **kills the VM**.

### 3.3 Guest access and gates

Credentials: user `researcher`, password **`safari123`**, `sudo` NOPASSWD.
Authoritative source is `user-data.yaml` on rnadig. **Do not use the
`research123` in `memcached-stage1.md` — that documents a different image.**

Install a key **now**, before §3.5: §4's `ssh` is non-interactive and the
`authorized_keys` entry must be inside the snapshot.

```bash
# HOST
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
sshpass -p safari123 ssh-copy-id -p 2222 -o StrictHostKeyChecking=accept-new researcher@localhost
ssh -p 2222 -o BatchMode=yes researcher@localhost true && echo 'key auth OK'
```

From here every guest command is written as
`ssh -p 2222 -o BatchMode=yes researcher@localhost '<cmd>'`, and every block is
tagged `# HOST:` or `# GUEST:`. Never mix the two in one block.

**Gate 3.a — environment still tuned, and the PMU is live**
```bash
# GUEST
ssh -p 2222 -o BatchMode=yes researcher@localhost '
  grep -o -E "isolcpus=[^ ]*|nohz_full=[^ ]*|no-kvmclock|clocksource=[^ ]*" /proc/cmdline
  cat /sys/kernel/mm/transparent_hugepage/enabled
  cat /proc/sys/kernel/randomize_va_space
  swapon --show | wc -l
  perf stat -e instructions -- true 2>&1 | grep -c "not supported"'
# REQUIRE: isolcpus=1-4 present; THP shows [never]; randomize_va_space 0;
#          swapon line count 0; "not supported" count 0.
# A non-zero PMU count means you booted without pmu=on — kill the VM and re-do §3.2.
```

**Gate 3.b — memtier supports what v2 needs**
```bash
# GUEST
ssh -p 2222 -o BatchMode=yes researcher@localhost '
  memtier_benchmark --version
  strings $(command -v memtier_benchmark) | grep -m1 "key-pattern must be in the format"
  memtier_benchmark --key-zipf-exp=0 2>&1 | grep -q "key-zipf-exp must be within interval"; echo "zipf_ok=$?"'
# REQUIRE: the accepted pattern set includes Z, and zipf_ok=0.
#   memtier_benchmark.cpp:1729 validates (0,5) EXCLUSIVE, so a SUPPORTED flag
#   rejects 0 with that exact message. Do NOT test the exit code — an unknown
#   option also exits 2 (memtier_benchmark.cpp:2427 -> usage() -> exit(2)).
```
If it fails, build memtier in the guest (github is reachable through user-mode
NAT) and re-run the gate:
`git clone https://github.com/RedisLabs/memtier_benchmark.git && cd memtier_benchmark && autoreconf -ivf && ./configure && make -j4 && sudo make install`

### 3.4 Start the v2 server and preload

```bash
# GUEST
sudo pkill -u memcache -x memcached 2>/dev/null; sleep 1
sudo memcached -m 8192 -t 1 -C -c 1024 -o hashpower=20,no_hashexpand \
     -l 127.0.0.1 -p 11211 -u memcache &
sleep 2
MCPID=$(pgrep -u memcache -x memcached)
sudo taskset -acp 1 $MCPID          # -a = ALL threads, not just the main one
for T in $(sudo ls /proc/$MCPID/task/); do printf 'tid %s: ' "$T"; sudo taskset -cp "$T"; done
# REQUIRE: every line ends "current affinity list: 1"
```

**`-a` is load-bearing.** With `-t 1` the request-serving thread is a *separate*
pthread from the pid (`memcached.c:6127` → `thread.c:381`); pinning only the main
thread leaves the worker free to run on vCPU 0/5/6, and `vcpus=1` would trace an
idle core — the v1 failure class, exactly.

Then the phase-1 preload, pinned away from vCPU 1:

```bash
# GUEST
taskset -c 5,6 memtier_benchmark -s 127.0.0.1 -p 11211 -P memcache_text \
  --key-prefix=memtier- --key-minimum=1 --key-maximum=1500000 \
  --key-pattern=P:P --ratio=1:0 --data-size=4000 \
  --threads=4 --clients=1 --pipeline=32 -n allkeys --hide-histogram
```

**Gate 3.c — the load is exactly what was asked for**
```bash
# GUEST
printf 'stats\r\n' | nc -q1 127.0.0.1 11211 | \
  grep -E 'STAT (curr_items|cmd_set|evictions|bytes|hash_power_level|hash_is_expanding) '
printf 'get memtier-1\r\n' | nc -q1 127.0.0.1 11211 | head -1
```
| Counter | Required | If it differs |
|---|---|---|
| `curr_items` | **1500000** | preload did not cover the range — check `P:P` and `-n allkeys` |
| `cmd_set` | **1500000 immediately after the preload, and CUMULATIVE thereafter** | ≈ 4× *right after the preload* means `S:S` was used. On any re-run it is legitimately far higher (Gates 3.d/3.e write too). What proves overwrite-not-growth is `curr_items` pinned at N with `bytes` unchanged and `evictions`/`reclaimed`/`expired_unfetched` all 0 — check those, not `cmd_set`. |
| `evictions` | **0** | `-m` too small — stop and report |
| `hash_power_level` | **20** | expansion fired; `no_hashexpand` missing |
| `hash_is_expanding` | **0** | same |
| `bytes` | **≈ 6.10e9** | this accumulates `ITEM_ntotal` (4,066 B; `items.c:505`), **not** the slab chunk (4,544 B). ~6.82e9 means you are measuring the wrong thing. |
| `get memtier-1` | `VALUE memtier-1 0 4000` | — |

**Gate 3.d — THE keyspace gate.** The check that would have caught v1.
```bash
# GUEST
before=$(printf 'stats\r\n'|nc -q1 127.0.0.1 11211|awk '/STAT get_hits /{h=$3}/STAT get_misses /{m=$3}END{print h" "m}')
taskset -c 5,6 memtier_benchmark -s 127.0.0.1 -p 11211 -P memcache_text \
  --key-prefix=memtier- --key-minimum=1 --key-maximum=1500000 \
  --key-pattern=Z:Z --key-zipf-exp=0.8 --ratio=1:16 --multi-key-get=16 \
  --data-size=4000 --pipeline=1 --threads=2 --clients=8 --test-time=10 --hide-histogram
after=$(printf 'stats\r\n'|nc -q1 127.0.0.1 11211|awk '/STAT get_hits /{h=$3}/STAT get_misses /{m=$3}END{print h" "m}')
echo "before=$before after=$after"
# REQUIRE: delta get_hits / (delta get_hits + delta get_misses) > 0.99
# The v1 configuration scores 0.00. NOTHING downstream is meaningful if this fails.
```

**Gate 3.e — instructions per request: the go/no-go.** Every number in §9 is
linear in this, and nobody measured it for v1.
```bash
# GUEST — with the phase-2 client running in the background
G0=$(printf 'stats\r\n'|nc -q1 127.0.0.1 11211|awk '/STAT cmd_get /{g=$3}/STAT cmd_set /{s=$3}END{print g+s}')
sudo perf stat -e instructions -p $(pgrep -u memcache -x memcached) -- sleep 30 2>&1 | awk '/instructions/{print $1}'
G1=$(printf 'stats\r\n'|nc -q1 127.0.0.1 11211|awk '/STAT cmd_get /{g=$3}/STAT cmd_set /{s=$3}END{print g+s}')
# I_req = instructions / (G1 - G0).  Run at --pipeline=1 AND --pipeline=16.
```
Measure **instructions per KEY LOOKUP**, not per request — with multiget they
differ by 16×, and misses scale with lookups. Use `get_hits + get_misses` as the
denominator (per-key; `cmd_get` is not).

| `I_lookup` | Action |
|---|---|
| ≤ 6,000 | **proceed**; §9 predictions stand (measured 4,463 on 2026-09-04) |
| 6,000 – 12,000 | proceed, and divide every predicted MPKI and `unique_ppages` in §9.1 by `I_lookup/4463` before comparing |
| **> 12,000** | **STOP and report.** Do not vary §1's locked parameters to chase it. |

If PMU virtualisation is unavailable at all, derive `I_req` from a TCG
`profile=on` pass (§5.1) divided by the `cmd_get + cmd_set` delta over the same
interval — same quantity, no PMU.

**Gate 3.f — the traced worker is busy**
```bash
# GUEST
A=$(awk '{print $14+$15}' /proc/$(pgrep -u memcache -x memcached)/stat); sleep 10
B=$(awk '{print $14+$15}' /proc/$(pgrep -u memcache -x memcached)/stat)
echo "cpu% = $(( (B-A)*100/1000 ))"      # USER_HZ=100 -> 1000 ticks in 10 s = 100 %
# REQUIRE: > 80
```

### 3.4a Write the phase-2 runner (GUEST — must be inside the snapshot)

§4 restores from a qcow2 internal snapshot, so anything written to the guest
filesystem **after** §3.5 does not exist in any restored VM.

```bash
# GUEST
cat > ~/start_v2.sh <<'EOF'
#!/bin/bash
# usage: start_v2.sh <theta>
set -u
THETA="$1"
exec memtier_benchmark -s 127.0.0.1 -p 11211 -P memcache_text \
  --key-prefix=memtier- --key-minimum=1 --key-maximum=1500000 \
  --key-pattern=Z:Z --key-zipf-exp="$THETA" \
  --ratio=1:16 --multi-key-get=16 --data-size=4000 --pipeline=1 \
  --threads=2 --clients=8 --test-time=100000 --hide-histogram
EOF
chmod +x ~/start_v2.sh
taskset -c 5,6 ~/start_v2.sh 0.8 >/tmp/mt_smoke.log 2>&1 &
sleep 5; pkill -u "$(id -un)" -x memtier_benchma   # NOT ...benchmark — see 3.5
grep -qi 'error' /tmp/mt_smoke.log && echo 'start_v2.sh rejected its arguments — STOP'
```

**Gate 3.g** — `ls -l ~/start_v2.sh` shows mode `+x`. It is inside the snapshot or
it does not exist in §4.

### 3.5 Snapshot

Leave memcached warm and **idle** — no client running — so every restore starts
from the same deterministic state. Gate 3.g and the §3.3 key install must both be
done first.

```bash
# GUEST
# "memtier_benchmark" is 17 chars; Linux truncates comm to 15, so `pkill -x
# memtier_benchmark` matches NOTHING and silently leaves the client running --
# you would then snapshot a RUNNING client and lose the determinism the whole
# design rests on. Match the truncated comm, and VERIFY.
pkill -u "$(id -un)" -x memtier_benchma
sleep 2
pgrep -u "$(id -un)" -x memtier_benchma && { echo "client still running — STOP, do not snapshot"; exit 1; }
echo "client stopped; safe to snapshot"
```
```bash
# HOST — ordinary SSH session, NOT the tmux pane running QEMU
df --output=avail -BG /mnt/sherlock | tail -1     # REQUIRE: > 50G
telnet 127.0.0.1 4444
(qemu) savevm mc_v2_a       # NEVER reuse a tag: hmp_savevm passes overwrite=true,
                            # which DELETES the existing snapshot BEFORE writing the
                            # new one. On a retry use mc_v2_b, then mc_v2_c.
(qemu) info snapshots       # REQUIRE: the tag is listed with a non-zero VM state
#   Ctrl+]  then  quit
```
```bash
# HOST
echo mc_v2_a > $MCROOT/logs/snapshot.tag        # §4 reads this
qemu-img snapshot -l $MCROOT/images/mc-v2.qcow2
```

Delete a superseded tag only after its replacement has been listed **and**
successfully `-loadvm`'d once. **One snapshot serves both θ** — θ is a runtime
memtier flag. Then stop the guest per §4.1.

---

## 4. The TCG restore pattern

Used by §5.1, §5.2 and §6. `EXTRA` carries the phase-specific plugin arguments.

```bash
# HOST
source ~/.mcrc
: "${OUTDIR:?}" "${PLUGIN:?}" "${TRIGGER:?}" "${EXTRA:?}"
case "$OUTDIR" in $MCROOT/*) ;; *) echo "OUTDIR escapes MCROOT — STOP"; exit 1;; esac
mkdir -p "$OUTDIR" "$(dirname "$TRIGGER")"
TAG=$(cat $MCROOT/logs/snapshot.tag)
tmux new -d -s mcvm
tmux send-keys -t mcvm "source ~/.mcrc; ~/qemu-custom/bin/qemu-system-x86_64 \
  -accel tcg,thread=multi -cpu \$CPUSTR \
  -smp 7 -m 12G \
  -drive file=\$MCROOT/images/mc-v2.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nographic -serial mon:stdio \
  -monitor telnet:127.0.0.1:4444,server,nowait \
  -plugin \$PLUGIN,outdir=$OUTDIR$EXTRA \
  -loadvm $TAG" Enter
```

```bash
# 0. wait for the guest. Under TCG the SSH handshake alone can take minutes.
for i in $(seq 1 60); do
  ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new researcher@localhost true 2>/dev/null && break
  echo "waiting for guest ($i/60)"; sleep 20
done
ssh -p 2222 -o BatchMode=yes researcher@localhost true || { echo 'guest never came back — STOP'; exit 1; }

# 1. start the measurement client. $THETA expands on the HOST, inside double quotes.
: "${THETA:?set THETA to 0.8 or 0.6}"
ssh -p 2222 -o BatchMode=yes researcher@localhost \
    "nohup taskset -c 5,6 ~/start_v2.sh $THETA >/home/researcher/mt_$THETA.log 2>&1 </dev/null &"

# 2. confirm the server is serving BEFORE arming (guest-side probe over SSH)
mcstat() { ssh -p 2222 -o BatchMode=yes researcher@localhost \
             "printf 'stats\r\n' | nc -q1 127.0.0.1 11211" | grep -E 'STAT (cmd_get|cmd_set) '; }
mcstat; sleep 5; mcstat        # REQUIRE: both counters RISING

# 3. arm
touch "$TRIGGER"
```

**Every `nc 127.0.0.1 11211` in this runbook is a guest-side command.** §1 locks
`-l 127.0.0.1`, and a `hostfwd=tcp::11211` forward would reach `10.0.2.15:11211`
where nothing listens — which is why there is no 11211 forward here and the probe
is tunnelled over SSH.

**The trigger is one-shot, has no stop, and is polled only while a *traced* vCPU
retires instructions.** Arming before step 2 passes yields a silent no-op ending in
`WARNING: Trigger was never activated!` hours later.

### 4.1 Stopping a run (shared by §3.5, §5.1, §5.2, §6)

```bash
# HOST — ordinary SSH session, NOT the tmux pane running QEMU
telnet 127.0.0.1 4444
(qemu) system_powerdown     # ACPI shutdown: guest halts, QEMU exits, atexit runs
#   Ctrl+]  then  quit
tmux capture-pane -p -S -3000 -t mcvm > $MCROOT/logs/<phase>.console.log
```

**Never type `quit` at the `(qemu)` prompt to end a capture.** It kills QEMU
immediately, `plugin_atexit` (`:1167`) does not run, the PROFILE line is never
printed and the last chunk gets no manifest row. If `system_powerdown` has not
taken within ~5 minutes under TCG, fall back to
`ssh -p 2222 -o BatchMode=yes researcher@localhost 'sudo poweroff'`.

---

## 5. Sizing: the profile and pilot passes

`sample_len` counts **every** instruction; `sample_gap` counts **user-mode**
instructions only (`sample_clock=user`). That asymmetry stops a TCG idle stretch
from consuming the gap or starting a window — but it means "1 B trace + 1 B skip"
is not a 1:1 duty cycle. Both numbers below are derived.

### 5.1 Profile pass — measure the user fraction (~10 min)

```bash
# HOST
export OUTDIR=$MCROOT/traces/profile TRIGGER=$MCROOT/run/profile/trace_start
EXTRA=",vcpus=1,trigger=$TRIGGER,profile=on"
```
Run §4, arm, let it run **5 minutes**, then stop per §4.1. Read the console log:

```
[champsim_tracer] PROFILE: <total> instructions (<user> user, <kernel> kernel)
```
```bash
TOT=<total>; USR=<user>
export SGAP=$(python3 -c "print(int(1e9*$USR/$TOT))")
echo "USER_FRAC=$(python3 -c "print($USR/$TOT)")  SGAP=$SGAP"
echo "export SGAP=$SGAP" >> ~/.mcrc
```

**Ignore the `sample_gap = (user - K*N)/(K-1)` hint the plugin prints at exit.**
It sizes a gap to spread K windows over a *finite* trajectory; memcached's loop is
unbounded, so use the fixed ~1 B-total gap above.

### 5.2 Pilot — measure the idle fraction and validate (~15 min)

```bash
# HOST
export OUTDIR=$MCROOT/traces/pilot TRIGGER=$MCROOT/run/pilot/trace_start
EXTRA=",vcpus=1,sample_len=200000000,sample_count=1,sample_clock=user,trigger=$TRIGGER"
```

**Gate 5.a — idle fraction**
```bash
"$PLUGINDIR/trace_filter" --stats-only "$OUTDIR/trace_vcpu1_c00000.raw.zst" 2>&1 \
  | tee $MCROOT/logs/pilot.filter.log | grep 'Idle insns removed'
# e.g.  Idle insns removed:  61234567 (30.6% of input, 38.1% of input kernel)
# REQUIRE: the FIRST percentage ("of input") < 40.0
IDLE=$(awk '/Idle insns removed/{gsub(/[(%]/,"",$5); print $5/100}' $MCROOT/logs/pilot.filter.log)
export SLEN=$(python3 -c "print(int(1e9/(1-$IDLE)))")
echo "IDLE_FRAC=$IDLE  SLEN=$SLEN"     # at 30 % idle -> SLEN ~= 1.43e9
echo "export SLEN=$SLEN" >> ~/.mcrc
```

**This campaign sizes for 1 B *usable*, i.e. `SLEN = 1e9/(1-IDLE_FRAC)`.** Sizing
for 1 B *captured* leaves 600 M with zero margin at the gate's 40 % idle limit and
the trace wraps silently in simulation. Do not vary this.

**Gate 5.b — the data is actually moving**
```bash
"$PLUGINDIR/trace_filter" "$OUTDIR/trace_vcpu1_c00000.raw.zst" $MCROOT/out/pilot.filt.raw.zst
"$CONVDIR/raw2champsim" $MCROOT/out/pilot.filt.raw.zst $MCROOT/out/pilot.champsim2.zst \
    2>&1 | tee $MCROOT/logs/pilot.convert.log
grep 'Decode failures' $MCROOT/logs/pilot.convert.log        # REQUIRE: 0
"$TOOLS/trace_sanity_check" -i $MCROOT/out/pilot.champsim2.zst -f v2 --check
"$TOOLS/trace_sanity_check" -i $MCROOT/out/pilot.champsim2.zst -f v2 | \
  sed -n '/Load footprint/,+3p;/avg load ops/p'
```
| Metric (per ~140 M filtered instructions) | Require | v1 |
|---|---|---|
| `Decode failures` (from **raw2champsim**, not the sanity checker) | 0 | — |
| `--check` | all six gates pass, exit 0 | passed for v1 too — **not** a footprint gate |
| unique 4 KB pages | **> 35,000** | ~4,500 |
| data footprint | **> 136 MB** (the tool prints MiB, mislabelled MB) | ~17 MB |
| avg load ops / inst | 0.25 – 0.40 | — |

Thresholds are quoted per ~140 M filtered instructions (200 M × 0.7). If the
pilot's actual filtered count differs, scale by `actual/140e6` — at the gate's
40 % idle limit that is 120 M, i.e. ~30,000 pages and ~117 MB.

If pages come back near 5,000, the GETs are still not moving data — return to
Gate 3.d.

---

## 6. Capture

**θ = 0.8 first**, validated end to end through §8 before spending on θ = 0.6.

```bash
# HOST
source ~/.mcrc
export THETA=0.8                       # second pass: export THETA=0.6
export OUTDIR=$MCROOT/traces/theta$THETA
export TRIGGER=$MCROOT/run/theta$THETA/trace_start
mkdir -p "$OUTDIR" "$(dirname "$TRIGGER")"
[ -z "$(ls -A "$OUTDIR")" ] || { echo "OUTDIR not empty — a previous capture is there. STOP and ask."; exit 1; }
EXTRA=",vcpus=1,sample_len=$SLEN,sample_gap=$SGAP,sample_count=5,sample_clock=user,trigger=$TRIGGER,capture_pa=on,values=on"
```

Run §4. Both `fopen(…, "wb")` (`:626`) and the manifest `fopen(…, "w")` (`:1467`)
**truncate**, and chunk 0 opens at vcpu_init before the trigger fires — so merely
starting QEMU against a populated `OUTDIR` zeroes the first chunk. Hence the
emptiness check.

**Progress** (double quotes: `watch` spawns `sh -c` and does not inherit
unexported variables):
```bash
watch -n 30 "ls -l '$OUTDIR'; echo; cat '$OUTDIR/trace_vcpu1_manifest.txt'"
```

**Gate 6.a — five complete windows, cross-checked against the filesystem**
```bash
cat $OUTDIR/trace_vcpu1_manifest.txt
awk 'NR>1{print $2, $5}' $OUTDIR/trace_vcpu1_manifest.txt | while read f b; do
  a=$(stat -c %s "$OUTDIR/$f"); [ "$a" = "$b" ] || echo "MISMATCH $f manifest=$b actual=$a"
done
# REQUIRE: 5 rows, every insn_count == $SLEN, start_insn strictly increasing,
#          and no MISMATCH line.
```
The manifest row is written from a compressor-side counter and `close_chunk` never
checks `fclose`, so under ENOSPC a row can claim a complete chunk that is not one —
the size cross-check is what makes this gate mean something.

Expect ~5.6 bytes/instruction raw (measured from v1's `tracestore`: 22.3 GB per
4 B instructions), so ~8 GB per window at `SLEN` = 1.43e9. Stop the guest per §4.1.

---

## 7. Filter, convert, validate

Nothing is deleted until it has passed. Raws are **quarantined**, not removed.

```bash
# HOST
source ~/.mcrc; export THETA=0.8; export OUTDIR=$MCROOT/traces/theta$THETA
mkdir -p $MCROOT/logs $MCROOT/out "$OUTDIR/keep"
cat > $MCROOT/convert_one.sh <<'EOF'
#!/bin/bash
source ~/.mcrc; set -u
THETA=$1; k=$2
OUTDIR=$MCROOT/traces/theta$THETA
R=$OUTDIR/trace_vcpu1_c$k.raw.zst
N=memcached_v2_theta${THETA}_rd95_mget16_w$k
F=$OUTDIR/$N.filt.raw.zst ; C=$MCROOT/out/$N.champsim2.zst
[ -s "$R" ] || { echo "MISSING $R — STOP"; exit 1; }
[ -e "$C" ] && { echo "$C already exists — STOP and ask"; exit 1; }
"$PLUGINDIR/trace_filter" "$R" "$F" || { echo "FILTER FAIL $N — raw KEPT"; exit 1; }
"$CONVDIR/raw2champsim" "$F" "$C" 2>&1 | tee "$MCROOT/logs/$N.convert.log"
conv=${PIPESTATUS[0]}
grep -qE 'Decode failures: +0$' "$MCROOT/logs/$N.convert.log"; dec=$?
"$TOOLS/trace_sanity_check" -i "$C" -f v2 --check; chk=$?
ins=$("$TOOLS/trace_sanity_check" -i "$C" -f v2 | awk '/total instructions/{print $NF}')
if [ "$conv" -eq 0 ] && [ "$dec" -eq 0 ] && [ "$chk" -eq 0 ] && [ "${ins:-0}" -gt 600000000 ]; then
  mv "$R" "$OUTDIR/keep/"; rm -f "$F"; echo "OK $N ($ins insns)"
else
  echo "FAIL $N (conv=$conv decode=$dec check=$chk insns=${ins:-0}) — raw KEPT at $R"
fi
EOF
chmod +x $MCROOT/convert_one.sh
printf '%s %s\n' $THETA 00000 $THETA 00001 $THETA 00002 $THETA 00003 $THETA 00004 \
  | xargs -P 5 -n 2 $MCROOT/convert_one.sh
```

**5-way** because there are exactly 5 windows per θ, and §6 sequences θ = 0.8 fully
before θ = 0.6 — not because of memory. Measured peaks per job: `zstd -19`
228 MB, `trace_sanity_check` 45 MB on a 300 M-instruction trace with 540 K unique
PCs (they run sequentially inside a job, so the job peak is ~300 MB). Five jobs is
~1.5 GB against 28 GB available. Budget **~2.1 h per θ**.

`Decode failures` is printed by `raw2champsim` (`raw2champsim.c:881`) on stdout,
**not** by `trace_sanity_check` — hence the tee'd log. A truncated input still
writes a valid, shorter output with `exit_status = 1`, which is why the gate tests
the exit code and the instruction count, not the file's existence.

**Delete `$OUTDIR/keep/*` only once Gate 8.a reports 0 wraparounds for this θ.**
The quarantine costs ~40 GB against 433 GB free. If disk ever forces an earlier
delete, that is a stop-and-ask.

---

## 8. Register and simulate

**§8 does not run on rnadig, and the executing agent's job ends here.** Write the
tlist, report, and stop. Shipping traces and launching the sweep are the user's
call — the destination path, the trace catalogue's layout and the simulator choice
are all decisions this runbook does not make for you.

What to hand back: the ten paths under `$MCROOT/out/`, their per-window instruction
counts and footprints from §7, `$MCROOT/logs/PROGRESS.log`, `PROVENANCE.txt`, and
the `I_req` from Gate 3.e (because §9.1 must be rescaled by it).

When the user approves, the ship step is:

```bash
# on rnadig — only after the user names the destination
rsync -av $MCROOT/out/*.champsim2.zst kratos2:<tracezoo>/memcached_v2/
```

If any simulation is ever run on rnadig it **must** pass `--no-trace-cache` (or
`--cache-dir $MCROOT/cache`): the default stages traces into `/tmp/trace_cache`
(`fetch_trace.py:32`), and `/tmp` on rnadig is on `/`, which has 25 GB free.

Create a **new** file `$MCROOT/out/memcached_v2.tlist.yml`, space-indented. Do not
edit, reformat or convert any existing cluster tlist — pass yours alongside them,
both flags merge across files.

```yaml
memcached_v2:
  memcached_v2_theta0.8_rd95_mget16_w00000:
    path: <tracezoo>/memcached_v2/memcached_v2_theta0.8_rd95_mget16_w00000.champsim2.zst
    version: 2
    workload: memcached
    category: kvstore
    subcategory: theta0.8
  # ... nine more
```

**State which simulator you are using** — `rollup.py` matches on the first
whitespace token of each line, so a wrong name silently rolls up as the `0`
placeholder rather than failing:

- **arishem/Hermes ChampSim** (produced every v1 number in §9.1; on rnadig at
  `~/arishem/`): flat `Core_0_*` names, and the only simulator here that emits
  `unique_ppages`. Its L1D is **192 KB**, not `lnc.toml`'s 48 KB L0D. Use
  `Core_0_cumulative_IPC`, not `Core_0_IPC`.
- **ChampSim2** (what `lnc.toml` configures): emits `cpu0 cumulative IPC: …` and
  has **no** `unique_ppages` stat at all — it would have to be added first.

Simulate at 100 M warmup + 500 M simulation. The experiment string must carry
`--config <sim>/configs/lnc.toml` and **must end in a complete flag**: a bare
`--toml`/`--json` binds the next token as an output filename and truncates it at
startup (a 2.3 GB trace was destroyed that way on 2026-08-26).
`create_jobfile.py` rejects this as `CJ_EXP_DANGLING_OPTION` — fix the exp file,
do not work around it.

**Gate 8.0 — the mfile names resolve.** Run ONE trace first, then
`grep -cE '^(Core_0_|cpu0 )' <tag>.out`. A count of 0 means you named the wrong
simulator's stats and every cell will be a placeholder.

**Gate 8.a — no wraparound.**
`grep -rl 'Reached end of trace' <results>/ | wc -l` must be **0**.

---

## 9. Acceptance

### 9.1 Against the v1 baseline

v1 numbers come from the arishem/Hermes fork with a **192 KB L1D**; `lnc.toml`
models a 48 KB L0D, so the L1D row is directional only.

| Metric | v1 | v2 predicted | Range |
|---|---|---|---|
| L1D miss rate | 1.02 % | **8 %** | 5–12 % |
| LLC total MPKI | 1.147 | **12** | 6–18 |
| — of which irregular | ~1.1 | ~1.3 | 0.8–2.0 |
| LLC accesses / kilo-instr | 1.88 | 15 | 8–22 |
| `unique_ppages` | 15,958 (62.3 MiB) | **190,000** (745 MiB) | 120 K–240 K |
| L1I miss rate | 32.20 % | **13 %** | 10–20 % |
| IPC | 0.352 | 0.25 | 0.20–0.35 |

FAISS `msturing10m_ivf1024flat` sits at 31.1 LLC load MPKI and 247,753
`unique_ppages` in the same window, for scale.

**Now measurement-backed, not modelled.** The table assumed 4,350 instructions per
lookup; Gate 3.e measured **4,463** on the warm guest on 2026-09-04 with the §1
configuration (`--multi-key-get=16`, `--pipeline=1`) — within 3 %, so these figures
stand as written rather than needing a rescale. They remain forecasts of
*simulation* output, which nothing has yet run; treat the first converted window's
`trace_sanity_check` footprint (Gate 5.b) as the first real check on them.

For the record, the same gate measured **19,196** instructions per lookup for
single-key GETs — the configuration this campaign started from, and the reason the
first attempt would have produced ~2.9 MPKI instead of ~12.

### 9.2 Two criteria that will NOT work

- **The DRAM bandwidth-level histogram will still sit ~99.9 % in the lowest
  bucket, and that is not a defect.** `lnc.toml` sets no `pmem.channel_width`, so
  ChampSim's default 8 B applies: 5600 MT/s × 8 B = 44.8 GB/s. One simulated core
  cannot move it at any reachable MPKI.
- **`trace_sanity_check --check` cannot certify this campaign** — six branch-type
  gates; a 1 MB-footprint trace passes all six.

### 9.3 Disclose in any write-up

`--data-size=4000` is well above the production mode (Atikoglu ETC ~186 B, Twitter
median ~230 B, CacheLib Lookaside ~100 B). Roughly 90 % of the resulting miss
traffic is `+64`-stride sequential value read-out inside `copy_from_iter`, which a
next-line prefetcher would erase — report *irregular* MPKI as a separate column.
θ = 0.8 is slightly below the published band for memcached-class caches (CacheLib:
"most prior measurements indicate 0.9 < α ≤ 1"); θ = 0.6 is a stress point, not a
realism claim.

---

## 10. Budget

Per θ, at `SLEN` = 1.43e9:

| Phase | Cost |
|---|---|
| capture (5 windows + 4 gaps) | ~1–2 h |
| raw on disk | ~8 GB/window → ~40 GB per θ, quarantined until Gate 8.a |
| filter + convert | ~2.1 h per θ, 5-way parallel (~4.2 h for both θ) |
| converted output | ~7 GB/window (1.0e9 filtered × the audit's ≥7 B/instr) → **~70 GB for all ten** |
| working image (`mc-v2.qcow2` + `mc_v2_a` state) | ~25–28 GB, one-time |
| at IDLE_FRAC = 0.40 (Gate 5.a's limit) | SLEN = 1.67e9 → 9.3 GB/window, 46.5 GB per θ |

Against 433 GB free on `/mnt/sherlock`. Peak per θ ≈ 28 GB image + 40 GB raw +
35 GB converted ≈ **105 GB**. Pre-flight gates: 150 GB free before §6, 100 GB
before §7, re-checked between windows. **Do not delete `tracestore/`.**

### RAM — measured, not assumed

rnadig has 31 GB total, ~28 GB available. The two peaks **never overlap**: §6
finishes and the guest is shut down (§4.1) before §7 starts.

| Phase | Consumer | Peak RSS |
|---|---|---|
| §3, §5, §6 | QEMU, `-m 12G` | **~9–10 GB realistic, 12 GB ceiling.** QEMU allocates guest RAM lazily, so RSS tracks what the guest *touches*: ~6.5 GB of memcached slab after the preload, plus guest kernel and page cache. Measured analogue on the local host: a TCG QEMU at `-m 8G`, 40 min in, had `VmHWM` **3.58 GB** because its guest never touched more. |
| §3, §5, §6 | TCG translation buffer + plugin | ~1 GB + ~30 MB (16 MB/vCPU buffer, one traced vCPU, zstd-1 context 16 MB) |
| §7 | `raw2champsim` (zstd-19) | **228 MB** measured |
| §7 | `trace_sanity_check` | **45 MB** measured on 300 M instructions / 540 K unique PCs; scales with unique pages and PCs, so budget ~100 MB at this campaign's larger footprint |
| §7 | five parallel jobs | **~1.5 GB total** |

Worst case is the capture phase at ~13.5 GB, i.e. roughly 2× headroom. **RAM is not
a binding constraint on this campaign; disk and core count are.** The residual risk
is the other logged-in user starting something, not the arithmetic — check
`free -g` before each long phase.

---

## 11. Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `WARNING: Trigger was never activated!` | armed before the workload ran, or the traced vCPU retired nothing | re-run §4 step 2 until `cmd_get` rises, then arm; rebuild with `-DTRIGGER_DEBUG` if ambiguous |
| `Unknown argument: sample_len=` | `main`'s plugin shipped | §2.1 |
| Gate 3.d ratio ≈ 0 | prefix or key range differs between phases | both commands must carry identical `--key-prefix`, `--key-minimum`, `--key-maximum` |
| `cmd_set` ≈ 4 × N after preload (`curr_items` ≈ N) | `S:S` instead of `P:P` | §1 phase 1 |
| `hash_is_expanding 1` | `no_hashexpand` missing | restart the server with it and re-preload |
| worker not pinned / traces look idle | `taskset` without `-a` pinned only the main thread | §3.4 |
| `perf` prints `<not supported>` | booted without `pmu=on` | §3.2 with `$CPUSTR` |
| Windows shorter than `SLEN` | guest died mid-run | check the manifest; a partial final row means the guest went down |
| Filtered window < 600 M | idle fraction above the pilot's | raise `SLEN` and recapture; do not ship a short trace |
| `Reached end of trace` in results | trace shorter than warmup + sim | as above |
| Every rollup cell is `0` | wrong simulator's stat names | Gate 8.0 |
| Host memory pressure during §7 | **not** the conversion — it peaks at ~300 MB/job. Check whether the other logged-in user started something, or whether a QEMU from §6 is still alive | `free -g`, `qemu_running` |
| A new core dump appears | QEMU crashed; `core_pattern` pipes to systemd-coredump on `/` | report it and its size; do not delete it |
| Anything writes to `/` | wrong path | stop — `/` has 25 GB |

---

## 12. What is deliberately NOT in this campaign

- **No θ = 0.99 control.** With the keyspace fix, `-t 1`, pipelining and θ all
  changing at once, the θ = 0.8 vs 0.6 delta is clean but the v1→v2 delta is not
  attributable to any single change. The v1 traces on `kratos2` are a θ ≈ 1.0
  anchor, just a confounded one. Accepted deliberately.
- **No `--pipeline=1` arm.** Pipelining is the largest single lever and is
  unvalidated in this pipeline; a P=1 arm at the same θ would isolate it for one
  extra capture slot.
- **No V = 512 arm.** It would land near 2–4 total MPKI but ~55 % irregular rather
  than ~10 %. Worth adding if the target turns out to be prefetching rather than
  DRAM and TLB exposure.
- **RocksDB.** Separate campaign, PIN not QEMU, driver already built at
  `/mnt/sherlock/rahbera/workloadzoo/rocksdb-driver/`. Its equivalent levers are
  `-c` (block cache) relative to DB size and `use_direct_reads`, not θ.
