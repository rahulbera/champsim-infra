# Capture campaigns 2026-09-04 → 2026-09-07 — distilled findings

Six campaigns, 188 numbered log entries, 59 traces shipped. This document is the
distillate: what a future engineer needs, stated once.

**It is not the record.** The chronological logs remain authoritative and
unedited at `../workloads/*/`*-campaign-log.md*. Per-trace measured numbers live
in `scripts/tlists/*.yml`, beside the traces they describe. This file holds only
what recurs, what was learned, and what went wrong.

Method note: this was distilled by re-reading all six logs and extracting every
finding, defect and measurement, then keeping what appeared in more than one
campaign or carried a transferable rule. Figures are quoted from the logs, not
recomputed.

---

## 1. What was produced

**59 traces, `CHECKSUMS.sha256` at 215**, covering every category of the OSDI'24
CXL-tiering taxonomy (Zhong et al. §3.2).

| category | workload | traces |
|---|---|---|
| database | PostgreSQL TPC-H q1/q9/q18/q21 | 12 |
| big data | Spark page-rank, naive-bayes, dec-tree | 9 |
| KV store | memcached 6, Redis 5, RocksDB 5, MongoDB 5 | 21 |
| JVM service | Cassandra 5, Kafka 3, Tomcat 3 | 11 |
| web | finagle-http 3, finagle-chirper 3 | 6 |

### The corpus's mix envelope

Every trace is 1e9 instructions with `decode_fail 0`. The two corners:

| | user/kern | branch | mem |
|---|---|---|---|
| **dec-tree** (high branch, low mem) | 77/23 | **18.8%** | **41.0%** |
| **PostgreSQL q21** (low branch, high mem) | 52/48 | **12.5%** | **57.7%** |

Everything else falls between. The **reject band** — `branch < 10% AND mem > 70%`
— marks a degenerate bulk-copy regime where a hot set stays cache-resident and
the workload turns into memcpy. Nothing shipped inside it; two configurations
were rejected for landing there (§3.1).

### The widest single-guest spread

PostgreSQL spans **33 points of user fraction from one guest, one database, one
configuration**, by changing only the SQL: q18 93.81%, q1 82.50%, q9 71.04%,
q21 60.90%. Wider than the three DaCapo JVMs managed (37.1 → 66.4). "Database"
is several points in the space, not one.

---

## 2. The one defect that reached shipped artifacts

### The `sample_gap` hint mixes units

**Found:** DaCapo log #29, 2026-09-06 22:14Z. Re-derived independently at #31.
Tooled as `scripts/common/sgap.py` at #38.

The plugin's exit-time hint computes

```
SGAP = (user - K*N) / (K-1)
```

subtracting `K*N` — a window length counted in **all** instructions
(`chunk_insn_count`, `champsim_tracer.c:527`, `:816`; the comment at `:807` says
"Window length always counts EVERY instruction") — from `profile_user_insns`,
which is **user-only** (`:731-734`). The gap itself advances only on user
instructions (`:777-779`, `:839-841`). Only the numerator is wrong; the `K-1`
denominator is right.

**Correct form:**

```
SGAP = (user / (K-1)) * (1 - K*N/total)          # sample_clock=user
SGAP = (total - K*N) / (K-1)                     # sample_clock=all
```

**What it cost.** The shortfall is `K*N*(1-f)/U`, so its damage scales with
**kernel fraction** — and, less obviously, with **trajectory length**, because a
fixed `K*N` is a larger share of a shorter run:

| workload | kernel % | hint covered | with `sgap.py` |
|---|---|---|---|
| Redis | 62.8 | **58.92%** ← shipped | — |
| RocksDB | 43.1 | **86.35%** ← shipped | — |
| Cassandra | 62.9 | 85.75% | 97.84% |
| Kafka | 49.4 | 94.96% | 99.32% |
| Tomcat | 33.6 | 96.70% | 97.64% |
| finagle-http | 31.5 | **96.95%** | 100.00% |
| q21 | 39.1 | 98.14% | 101.93% |
| Spark page-rank | 4.9 | 99.86% | 99.86% |

**finagle-http is the worst case measured despite *less* kernel than q21**,
because its trajectory (45.2e9 instructions in 600 s) is under half q21's. The
bug is not a function of kernel fraction alone.

**What it did NOT do.** From the log: *"The shipped traces are not corrupt —
every window is internally valid, exactly 1e9 instructions, `decode_fail 0`,
geometry exact. What is reduced is ROI **coverage**."* Redis and RocksDB sample a
narrower slice of their trajectory than intended. That is a representativeness
limitation, recorded in their tlists, not a correctness failure.

**Why it survived four campaigns.** Spark page-rank, at 95.09% user, would have
shown the hint covering 99.86% — indistinguishable from correct. From the Spark
log: *"Had Spark been the first workload traced, the formula would have looked
correct to any amount of scrutiny."* The decisive cross-check came from the Redis
manifest instead: stride-minus-window was 1,787,936,203 **total** instructions for
a configured gap of 672,909,054 — a ratio of 0.3764 against a measured user
fraction of 0.3723. The gap was user-clocked while the window was not.

**Rule adopted:** encode the correction as a tool carrying its own derivation and
both counterexamples (`scripts/common/sgap.py`), not as a note someone must
remember to read.

---

## 3. Where measurement overturned a prediction

Five times an analytical judgement was wrong and a cheap measurement corrected
it. This is the most transferable material in the logs.

### 3.1 Screening on footprint is backwards

DaCapo #14. The proposed screen was heap footprint. DaCapo's own shipped
`stats-nominal.yml`, ranked by LLC misses per M instructions, said the opposite:

| rank | benchmark | LLC/Mi | min heap |
|---|---|---|---|
| 1 | h2o | 8506 | 2543 MB |
| 2 | **kafka** | 6819 | 345 MB |
| 3 | **cassandra** | 5719 | 174 MB |
| 4 | **tomcat** | 5119 | 35 MB |
| 16 | batik | 1872 | 1759 MB |
| 19 | biojava | 1427 | 1027 MB |

The researcher's picks were ranks 2, 3 and 4 of 22; the >1 GB-heap benchmarks sat
in the bottom third. *"A large live heap traversed with good locality generates
**less** LLC traffic than a small heap churned hard."* Cassandra's 174 MB min heap
conceals 4.79 GB of total allocation.

**Rule:** screen on measured miss rate and IPC, never on residency proxies. Min
heap answers "can it run", not "does it miss".

### 3.2 More skew made the trace *less* useful

Redis. At theta=0.99 with `--multi-key-get=16 --data-size=4000`, the pilot
measured **73.9% kernel / 73.5% memory / 7.7% branch** — inside the reject band.
Each request moved 64 KB; the workload had become memcpy. Shipped at
**theta=0.80, 512 B**: 59.3% / 52.9% / 14.2%.

MongoDB at the *same* theta=0.99 is fine: 15.5–17.7% branch / 44.4–48.3% mem. The
reject band screens a workload **and its configuration**, not skew as such — the
difference is WiredTiger's B-tree traversal and document decoding keeping real
control flow in the trace.

The 4000 B value size was inherited from memcached without re-testing. **A
parameter that was right for one workload is a hypothesis for the next.**

### 3.3 A success criterion that guaranteed failure

RocksDB v1's stated success criterion was *"block cache hit rate > 90% after
warmup"*, and it achieved **97.40%** — which is a statement that the workload
never reached DRAM. v2 sized the cache against the data instead and measured
**34.33%** (223,258 hits / 427,102 misses).

**Rule:** for memory-system traces, a high cache hit rate is a failure signal.

v1 had a second, independent failure of the same family, cited in the v2 log as
the class it guards against: **it traced an idle core.** That is the one failure
mode in this project's history that produced traces measuring the wrong thing.
Both v1 failures are why v2 proves the pinned worker's `utime` is advancing
*before* arming the trigger, rather than assuming it.

### 3.4 The I/O prediction, and the boundary it did not cross

PostgreSQL. Q18 was recommended for rejection on 4.06M temp reads. Asked to
measure rather than argue, `perf` showed Q18 **87.6% CPU-bound / 2.8% iowait** —
the *most* compute-bound of the four. It became the fastest workload in the
corpus (255.7 MIPS, 93.81% user).

The related error, logged as *"argued a point twice from a measurement that does
not cross the KVM/TCG boundary"*: **I/O fractions measured under KVM overstate
what a TCG trace sees.** TCG stretches compute ~35× (85 MIPS vs ~3 GIPS) while
disk stays at wall-clock speed, so a query 25% iowait under KVM is well under 1%
under TCG. Tomcat — the only workload that genuinely idles — lost just 0.6–0.9%
per window to idle-loop filtering. PostgreSQL under a server-side `DO` loop lost
**0.0%**.

### 3.5 An explanation invented rather than measured

DaCapo: *"Kernel-share explanation for Cassandra was a guess dressed as an
explanation, and the measurement contradicted it."* Recorded because the failure
mode is offering a mechanism with the confidence of a measurement.

---

## 4. Load-bearing properties of the pipeline

Each of these is required for a capture to mean anything. All appear in 4+ logs.

### 4.1 Two QEMU patches, neither optional

`patches/kvmclock-tcg-restore.patch` makes a KVM snapshot **loadable** under TCG.
`patches/avx-hflag-tcg-restore.patch` stops the guest **dying ~12 s later**:
`HF_AVX_EN_MASK` is never reconstructed on restore, so AVX is disabled and every
VEX instruction raises `#UD`. It is intermittent, which is why v1 never hit it.

The AVX patch is why JVM workloads exist in this corpus at all. The J1 gate
(DaCapo #11–13) proved it: snapshot `j1_canary_a` restored under TCG, heartbeat
read back **399**, correctly rolled back from the 405 seen before `quit` — a real
resume, not a live continuation — then advanced 399 → 445 → 483. Numerical
correctness was closed separately by `VecCheck`, comparing an auto-vectorised
reduction against a loop-carried scalar one: **PASS, 200 rounds**.

RocksDB logged that *"the kvmclock patch existed on exactly one machine, in a non-git
directory"*, and a campaign failed because only one of the two was applied.

### 4.2 `vcpus=` is an index range, not a workload selector

DaCapo #30. `vcpus=1` selects vCPU 1 of 4; nothing pinned the JVM to it. Measured
live: java pid 2178 had affinity mask `f`, **89 threads spread 23/27/21/18 across
all four vCPUs**. The capture *"would have looked like a plausible Cassandra trace
and been a scheduler artifact"*.

The fix is **not** to widen `vcpus=` — each vCPU runs an independent sampling
state machine with its own manifest, so four vCPUs give four unaligned window
sequences, and the plugin has no atomics under MTTCG. Instead pin the whole
workload onto the traced vCPU: `taskset -acp 1 <pid>`. **The `-a` is
load-bearing** — without it only the main thread moves. Cost: throughput drops
~4×, *"the honest cost of a single-core slice and not a defect"*.

Thread counts pinned: Spark 268, naive-bayes 291, Kafka 101, Cassandra 88,
finagle-chirper 72, finagle-http 47, Tomcat 26.

**The pin is pid-bound.** It survives `savevm`/`-loadvm` but *not* a guest
restart — which is why PostgreSQL drives its query from a server-side PL/pgSQL
`LOOP`: a shell loop over `psql` spawns a fresh backend every ~35 s and silently
loses the pin.

Verifying a pin: `/proc/<tid>/stat` field 39 is **stale for sleeping threads**.
Measure advancing `utime` instead (RocksDB sampled 12 s apart: 10309 → 10563
ticks).

### 4.3 `savevm` costs touched guest RAM, not live set

Cassandra with 24 GB guest RAM produced a **23.6 GiB snapshot** for a workload
whose live set was ~2 GB. Dropping the guest page cache does **not** help — freed
pages are not zeroed, and QEMU serialises RAM as it sees it. The fix is `-m 12G`.
Guest RAM **size** is what a snapshot costs.

### 4.4 The profile is the only time-bounded stage

Capture and conversion are instruction- and data-bounded, so contention costs
wall-clock only. A contended 600 s profile executes fewer instructions, yielding a
smaller SGAP and a narrower slice — making user fractions **incomparable across
workloads**. `run_*_snap_profile.sh` therefore pauses running converters
(`SIGSTOP`) for the measured window, restoring them via a trap.

Safe on `raw2champsim` specifically: a plain read/write filter, no timers,
sockets, guest or monitor. **Not permission to signal QEMU** — a capture is
stopped with a monitor `quit`, never a signal.

### 4.5 Ship order

hash locally → rsync → **`sha256sum -c` on the remote** → append to CHECKSUMS →
and only then, separately, reclaim.

The catalogue records **bare basenames**, so a trace can be moved between
directories without invalidating it. `EXPECT` is a line-count precondition that
makes a concurrent ship abort rather than interleave.

---

## 5. Recurring defect classes

49 defects across six campaigns. **None corrupted trace data.** They cluster into
six shapes, and the repetition is the point — several were re-committed after
being logged.

### 5.1 Checks that pass on nothing

The largest class, and the most dangerous, because the check *reports success*.

- `grep -c` prints `0` **and exits 1**, so `grep -c … || echo 0` emits `0\n0` and
  numeric tests on it become shell errors. Written **twice in one night**, the
  second time *forty minutes after logging a warning about it*.
- `bash -n` reports **"syntax OK" on a zero-byte file**. A `sed` had aborted on a
  parse error after `>` truncated the target; the syntax check passed on the
  empty result.
- A poll reported `decode_fail=1606302` — actually the **SIMD counter**, from an
  unanchored `[0-9]+$` on a line ending `… SIMD 1606302`. This manufactured the
  brief's ESCALATE condition on a healthy converter.
- A converter counter tallied only `raw2champsim` and read a healthy
  sanity-check stage as `convert=0` — again the ESCALATE condition.
- `dss.ri` (tpch-kit) **ran to completion and created zero constraints**, DB2
  syntax against a `TPCD` schema. Caught only by querying `pg_constraint`
  directly: 0 rows.
- A dpkg-lock race against cloud-init, under `set -e` plus a `/dev/null`
  redirect, produced a **silent no-op install**.
- *(2026-09-07, verifying the catalogue regroup)* A path-existence check
  reported `ok=58 missing=0` against **59** paths: the input file had no trailing
  newline, so `while read` dropped the last line. The check reported success on
  98% of its input and would have done so on any fraction. Guard with
  `[ -n "$p" ] || continue` and ensure the trailing newline. Logged here because
  it was hit *while verifying a change made because of this document* — the class
  is not one you outgrow by knowing about it.

**Rule: never extract a number without anchoring it to its label, and never let a
check pass on nothing.** Assert on size and on a known-present string, not on a
syntax check alone. Each of these became a script — `convstat.sh`, `guestpin.sh`,
`dfstat.sh` — so the check is a definition rather than something retyped.

### 5.2 Process matching that matches the wrong thing

At least four occurrences, explicitly called *"third occurrence of this bug
class"* by the third:

- `pgrep` truncates comparisons at **15 characters** and picked the wrong pid.
- `pgrep -f … | head -1` matched a **bash wrapper**, falsely reporting a pin lost.
- `guestpin.sh` hardcoded a jar name in its pattern and reported "NO JVM" on a
  healthy Spark run.
- `pkill -f renaissance-mit` matched **its own command line** and killed the shell
  that was about to launch the JVM.

**Rule:** match on the executable (`/proc/PID/exe`, `pkill -x`), never on a
substring that your own command also contains.

### 5.3 Timeouts that misreport success

`ssh` to a guest times out at 120 s **while the remote command succeeds**,
returning exit 143. Logged as the *"fourth and fifth occurrence"*. **Check the
artifact, never the exit code.** Related: long-running guest work must not be
launched inside a timeout-bounded ssh.

### 5.4 Gates calibrated on the wrong workload

- The ship gate required ≥ 999,900,000 insns — a 0.01% tolerance generalised from
  MongoDB. Tomcat is the only workload that genuinely idles, so `trace_filter`
  legitimately strips 0.6–0.9%. **A valid Tomcat ship aborted on the gate, not a
  defect.** Recalibrated to 99%.
- A flat 5% window-spread threshold *"would have discarded a good capture"*.

**Rule:** a threshold derived from one workload is a hypothesis about the next.

### 5.5 Output that disappears

- The first `PROFILE` line was **lost**: QEMU's stderr went only to a tmux pane
  that dies with the process. Fixed with `exec 2> >(tee -a "$QLOG" >&2)`.
- A tmux attach **killed the Tomcat guest** — every launch script let QEMU
  inherit the pane's stdin. Fixed with `< /dev/null` in all seven scripts.
- Self-inflicted output filtering *"hid the same failure twice"*.

### 5.6 Waiting for a condition that cannot occur

A `savevm`-completion waiter polled for a **stable qcow2 file size** — a
condition that never becomes true while a live guest writes. Ask the monitor
instead. Related: probing a QEMU build feature *by starting QEMU* hung for ten
minutes, and `nc -U` without `-q` hangs on a monitor socket when `hmp.py` already
existed and was not looked for.

---

## 6. Open items

| item | status |
|---|---|
| **Redis (58.92%) and RocksDB (86.35%) coverage** | Traces valid; narrower sampling than intended (§2). Recapture is a representativeness decision, not a correctness fix. |
| **h2o** | DaCapo rank-1 by LLC misses/M-instr (8506); would fill the ML category. Never requested, recorded so it is not lost. |
| **`db-shootout`, `als`, `movie-lens`, `log-regression`** | Renaissance benchmarks screened but not captured; rationale in `scripts/renaissance/README.md`. |
| **Docs and catalogue hierarchy** | **Done 2026-09-07.** `scripts/`, `docs/workloads/` and the kratos2 `version2.1/` catalogue all nest per workload, with `renaissance/` as parent. `CHECKSUMS.sha256` needed no edit (bare basenames); audited after: paths `ok=59 missing=0`, moved traces `ok=26 mismatch=0`. |

---

## 7. What this says about the pipeline

**Zero of the 49 defects corrupted trace data.** Every shipped trace is exactly
1e9 instructions with `decode_fail 0`, verified by `trace_sanity_check --check`
before shipping and re-verified under its shipped name, then re-hashed on the
remote after transfer. A final independent audit re-checksummed all 24 traces
from the last two campaigns against the catalogue: `ok=24 mismatch=0 missing=0`.

The defects were in **tooling, monitoring and methodology** — the layer around
the pipeline. One (§2) reached shipped artifacts and narrowed their coverage
without making them wrong.

The pattern worth carrying: the failures that cost the most were not crashes.
They were **checks that reported success** — a gate that passed on an empty file,
a counter that read the wrong column, a constraint script that created nothing
and said nothing. A pipeline that fails loudly is cheap. This one mostly did, and
the exceptions are catalogued above.
