# Audit: the first Memcached and RocksDB capture campaigns

> **Generated** 2026-09-04.
> **By** Claude Opus 5 (1M context) — `claude-opus-5[1m]` — driving 29 subagents
> on the same model (14 parallel readers, 3 adversarial critics, 10 gap-closing
> investigations, 1 synthesis), followed by a second 9-agent pass (5 analytic
> lenses, 3 refuters, 1 synthesis) on the parameter question.
> **Scope** `champsim-infra` @ `94cb28c`, plus live inspection of the host, of
> `kratos2` and of `rnadig`.
> **Status** Audit record. Written *after* the first campaigns, *before* the
> re-capture. Nothing here has been re-run against a new trace.

## Why this document exists

The first Memcached and RocksDB trace campaigns produced traces that do not
exercise the memory system. The traces are real, the pipeline worked, every
component reported success — and the result was unusable for its purpose. Every
gate in this repo passed.

This is a record of *why*, so the next campaign does not rediscover it. The most
expensive findings are not bugs in the code; they are configurations that are
silently self-consistent and wrong.

---

## Confidence — read this before quoting anything below

Findings are graded. **Do not carry a Grade C or D claim into a paper, a commit
message, or another agent's prompt without re-verifying it.**

| Grade | Meaning | What it took |
|---|---|---|
| **A — verified** | Read in source, or reproduced by execution on this machine | file:line quoted, or a command whose output was observed |
| **B — computed** | Arithmetic from Grade A inputs | the derivation is shown; the inputs are cited |
| **C — deduced** | Follows from Grade A facts, but the consequence was never *observed* | stated as a deduction, with the check that would settle it |
| **D — modelled** | A forward prediction | explicitly unvalidated |

| # | Finding | Grade |
|---|---|---|
| 1 | memtier and YCSB used disjoint keyspaces (both key formats read in source) | **A** |
| 2 | …therefore the traced runs never read the loaded dataset | **C** |
| 3 | `--key-zipf-exp` was never set; memtier defaults it to 1.0 | **A** |
| 4 | The dataset was ~8.1 GB with ≥366 K evictions, not the documented "~6 GB" with zero | **B** |
| 5 | `trace_sanity_check` cannot detect either defect | **A** (reproduced) |
| 6 | The kvmclock patch is absent from the QEMU on this host | **A** |
| 7 | Published Zipf α for memcached-class caches is ~0.9–1.4, not 0.6–0.8 | **A** (primary sources) |
| 8 | The ChampSim DRAM bandwidth histogram cannot move on a single core | **B** |
| 9 | θ is a ~1.4–1.5× lever; instructions-per-request is a ~25× lever | **B** |
| 10 | Instructions-per-request in the old run was 23,000–62,000 | **C** (wide band) |
| 11 | Any predicted MPKI / `unique_ppages` for a future capture | **D** |

**The single most important caveat:** finding #2 — the claim that every `GET`
missed — is a *deduction*. No `get_hits`/`get_misses` counter from the original
traced run survives. It is cheap to falsify: restore the snapshot under KVM, run
the query phase for ten seconds, and read the ratio. Do that before building on
it.

---

## 1. The defect: the client and the store never shared a keyspace

The Memcached campaign loaded data with YCSB and queried it with
`memtier_benchmark`. YCSB's memcached binding writes one item per record under a
key of the form `usertable-user<fnv64>`. The recovered
`~/start_benchmark.sh` — pulled verbatim from
`ubuntu-guest-memcached.qcow2` — never passes `--key-prefix`:

```bash
memtier_benchmark --server=127.0.0.1 --port=11211 --protocol=memcache_text \
    --threads=4 --clients=4 --ratio=1:19 --requests=999999999 \
    --key-maximum=2250000 --key-pattern=Z:Z --data-size=4000 \
    --hide-histogram > /dev/null 2>&1 &
```

memtier therefore used its compiled-in default:

- `memtier_benchmark.cpp:966` — `if (!cfg->key_prefix) cfg->key_prefix = "memtier-";`
- `obj_gen.cpp:447` — `snprintf(m_key_buffer, m_key_buffer_size, "%s%llu", prefix, key_index)`

so the client drove `memtier-1 … memtier-2250000` against a store keyed
`usertable-user<fnv64>`. **The two keyspaces are disjoint.**

The consequence, if the deduction holds: every `GET` missed, and the only live
data in the traced window was whatever the 5 % `SET` stream created — a
Zipf-θ-1.0 concentration over freshly written keys. That predicts a working set
of tens of megabytes against a nominal 8 GB store, and the measured
`unique_ppages = 15,958` (62.3 MiB) matches.

### Why nothing caught it

- memtier's output went to `/dev/null`. A rejected flag or a 100 % miss rate is
  invisible.
- memcached reports a `GET` miss as success at the protocol level. `cmd_get`
  rises either way, and the Stage-4 check is exactly `cmd_get`/`cmd_set`
  *increasing*.
- A `GET` miss still hashes the key, probes the bucket and walks the full chain —
  `assoc.c assoc_find` is identical for hit and miss. The workload looked busy.
- `trace_sanity_check --check` passed. It has no footprint or skew gate (§5).

**The lesson is general: a two-tool pipeline where one tool writes and another
reads must assert that they agree, in the tool's own counters, not in the
narrative.** The check costs one line:

```bash
printf 'stats\r\n' | nc -q1 127.0.0.1 11211 | grep -E 'STAT get_(hits|misses) '
# require  delta get_hits / (delta get_hits + delta get_misses) > 0.99
```

---

## 2. The skew constant was never chosen

`--key-zipf-exp` appears nowhere in any script or document. memtier defaults it
to **1.0** (`memtier_benchmark.cpp:5086-5090`; the valid interval is `(0,5)`
*exclusive*, so `0` cannot be used to mean "unset"). Every trace labelled
`zipfian` in the catalogue was captured at θ = 1.0 by omission.

`Z:Z` genuinely is Zipfian — that part of the record is honest. The "Gaussian"
claim in `memcached-stage2.md:566` comes from an **unfilled metadata template**
(its neighbouring lines read `Date: [fill in]`), and a 5-second pre-snapshot
sanity check that used `G:G`. Neither describes a traced run. That template line
propagated into `champsim-infra/CLAUDE.md`.

**Lesson: an unfilled template is worse than no document.** It is
indistinguishable from a record, and it outlives the person who knows it is
blank.

---

## 3. The dataset was never the size the documents claim

`RECORD_COUNT=2250000` with `FIELD_COUNT=10`, `FIELD_LENGTH=400` is annotated
`# ~6 GB data footprint` in `memcached-stage2.md:182`, and "~6 GB" appears in
four places. The arithmetic (Grade B, from YCSB's binding issuing one `add()`
per record — not per field):

| Quantity | Value |
|---|---|
| JSON value after framing and escapes | 4,225 B |
| qualified key `usertable-user<fnv64>` | 33 B |
| `ITEM_ntotal` = 48 + 34 + 4,227 | 4,309 B |
| slab class 18 chunk (growth factor 1.25) | 4,544 B |
| slab memory for 2.25 M items | 10.22 GB |
| `-m 8192` cap | 8.59 GB |
| **items that actually fit** | **1,884,160 (83.7 %)** |
| **minimum evictions during load** | **≥ 365,840** |

The real resident set was ~8.1 GB with ~366 K evictions — against a Stage-2
checklist item that reads "Zero evictions during loading". The "~6 GB" traces to
a stage-1 *suggestion* of 1.5 M records (1.5 M × 4000 B = 6.0 GB exactly) that
was never recomputed when the count rose to 2.25 M.

Separately, `-o hashpower=20` gives 2²⁰ buckets and memcached auto-expands at
`curr_items > 1.5 × hashsize` = 1,572,864, so the hash table rehashed mid-load.
Size it as `ceil(log2(N/1.5))`, or pin it with `no_hashexpand`.

> The "5 GB database" in the project's oral history is **RocksDB's** figure
> (`rocksdb-tracing-task.md:564`, "5 M × 1 KB records (~5 GB uncompressed)"), not
> Memcached's. The two got conflated.

---

## 4. RocksDB: the in-repo spec is two generations behind what was run

`docs/workloads/rocksdb/rocksdb-tracing-task.md` is a pre-implementation task
brief. The driver that actually ran lives outside this repo
(`rnadig:/mnt/sherlock/rahbera/workloadzoo/rocksdb-driver/`) and differs from the
spec: `-c` defaults to 8 GB not 4, and two flags the spec never mentions govern
the ROI — `--warmup-secs` and `--roi-secs`. **The ROI is bounded by wall clock,
not by `-o`**; `-o` is a soft cap and the timer trips first.

Five campaigns ran, of which the spec documents one:

| Tag | Records | α | Cache | Warmup / ROI | Traces | Block-cache HR |
|---|---|---|---|---|---|---|
| read95_zipf0.99 | 5 M | 0.99 | 8 GB | 600 / 2700 s | 12 | **97.40 %** |
| read50_zipf0.99 | 5 M | 0.99 | 8 GB | 600 / 2700 s | 11 | — |
| n20M rd95 zipf0.8 | 20 M | 0.8 | 16 GB | 1200 / 3600 s | 11 | 89.59 % |
| n20M rd50 zipf0.8 | 20 M | 0.8 | 16 GB | 1200 / 3600 s | 8 | 66.64 % |
| n20M rd95 zipf0.6 | 20 M | 0.6 | 12 GB | 1200 / 3600 s | **8, never catalogued** | 72.65 % |

A 97.4 % block-cache hit rate is the defect stated in the workload's own units:
the spec's success criterion was "block cache hit rate > 90 % after warmup", and
a warmup phase exists specifically to *achieve* that. **The design intent was a
cache-resident workload.** That is defensible for studying block-cache code
paths, and fatal for studying the memory hierarchy.

The α = 0.8 run's own header predicted a 2–3× MPKI lift and realised 1.4×
(1.6 → 2.1–2.4). **Predictions in this domain have overshot reality; treat
Grade D numbers accordingly.**

**Lesson: none of the 20 M / α=0.8 / α=0.6 iterations were committed to any
repo.** They exist only as shell scripts on one machine. The spec in git
describes a configuration nobody ran. Commit the run scripts, or the git history
documents a fiction.

---

## 5. What this repo could not measure — and still cannot

`trace_sanity_check` reports load footprint (unique 4 KiB pages touched by loads,
VA and PA, and the resulting MB) plus instruction-side footprint. That is real
and useful. Four gaps, each **reproduced by running the tool on purpose-built
traces**:

- **Stores contribute nothing.** The store path increments counters only; the
  address never enters any set, and `destination_memory_pa` is never read. A
  trace with 781 MB of store-only footprint reported its load footprint
  unchanged.
- **No 64 B data-line footprint.** `BLOCK_SHIFT` is applied only to the IP. Two
  traces over the same 40,000 pages — one touching a single line per page
  (2.44 MB of real line footprint), one touching all 64 (156 MB) — reported
  **identical** `data footprint 156.25 MB`.
- **No skew metric of any kind.** No reuse distance, no per-line counter, no
  top-N hot set. A trace with 95 % of accesses inside 1 MB and a uniform trace
  over the same pages produced **byte-identical** reports.
- **`--check` is footprint-blind.** All six gates are branch-type invariants. A
  1 MB-footprint trace passes all six.

Also: `--no-unique` deletes every footprint number, and `tools/README.md:65`
shows it in the example invocation. Never inherit that for a verification run.

**So the pipeline can certify that a trace is well-formed and that its branch
fields are honest, and cannot certify that it is worth simulating.** Closing that
is one streaming pass over the existing reader: line-granular sets fed from both
source *and* destination addresses; a bounded hot-line histogram reporting the
access fraction covered by the top N lines with N = the target LLC's line count;
and a fixed-capacity LRU sized to that LLC, simulated inline.

Until that exists, the cheapest real gate is a 100 M-instruction pilot chunk:

```bash
trace_sanity_check -i <chunk>.champsim2.zst -f v2 | sed -n '/Load footprint/,+3p;/avg load ops/p'
# the old memcached traces yield ~3,200 unique 4 KB pages per 100 M instructions
```

---

## 6. Corrections to received wisdom

Recorded because each was believed, acted on, and is wrong. Re-deriving them
costs hours.

**The published Zipf α for memcached-class caches is higher than folklore says.**
CacheLib (OSDI '20, §3.1): *"most prior measurements indicate 0.9 < α ≤ 1"*, and
Lookaside is *"Zipfian with alpha close to 1"*. Twitter (OSDI '20, §4.5): *"most
of the alpha values are in the range from 1 to 2.5"*, with a read-heavy median of
1.4 and a write-heavy median of 0.9. **Atikoglu et al. (SIGMETRICS '12) fit no
popularity distribution at all** — it is routinely cited for one it does not
contain. The α ≈ 0.6–0.8 band that gets quoted for KV caches comes from CDN and
graph-edge workloads. A low α is defensible as a *stress* point; it is not the
production-representative one.

**The ChampSim DRAM bandwidth-level histogram is not a success criterion.**
`lnc.toml` sets no `pmem.channel_width`, so ChampSim's default 8 B applies:
5600 MT/s × 8 B = **44.8 GB/s** on one channel. A single simulated core cannot
move that histogram at any reachable MPKI — 50 % utilisation would need ~729
MPKI, above x86's ~370 MPKI ceiling at 0.37 memory ops per instruction. The old
trace's "99.90 % in the lowest bucket" is an artifact of single-core simulation,
not evidence of an idle workload. Judge on LLC MPKI, LLC miss ratio,
`unique_ppages`, STLB MPKI and average miss latency.

**Static top-k Zipf coverage overstates an LRU cache's hit rate.** Use the
Che/characteristic-time fixed point. At N = 1.5 M, k = 692 items resident in
3 MiB: static coverage says 46 % hit at θ = 0.99, the Che fixed point says 34 %.
The error compounds when you then compute a "lift" ratio.

**Database size is a weak lever on in-window footprint.** ChampSim consumes a
fixed 600 M instructions, and distinct keys touched in that window asymptote to
the *request count*, not to N. At ~138 K requests and θ = 0.8: N = 1 M → 89 K
distinct keys, N = 2 M → 97 K, N = 6 M → 104 K. **Sextupling the database buys
17 %.** Choose N for the hash chain load factor `λ = N/2^hashpower` and for guest
RAM — not for coverage. What moves in-window footprint is requests per
instruction and reuse distance.

**Physical addresses are a tracer-choice consequence, not a knob.** The pintool
zeroes `physical_address` and the privilege bit (`tracer/pintool/README.md:200`).
Every RocksDB trace in the catalogue has all-zero PA fields. If a study needs
real PAs, RocksDB has to move to the QEMU path at ~30× the capture cost.

---

## 7. memtier and memcached flag traps

All Grade A, read in source. Each one fails silently.

- **A preload covers `1..N` exactly once only with `--key-pattern=P:P`.** Two
  independent mechanisms, both keyed on `P`, and both silent when it is absent:
  `memtier_benchmark.cpp:972-973` divides the `-n allkeys` request count among
  clients **only** when `strcmp(cfg->key_pattern, "P:P") == 0`; and
  `client.cpp:138-150` partitions the key *range* across clients only when the
  SET-side pattern is `'P'`. With `S:S` every client restarts at
  `--key-minimum`, so most of the keyspace is never written while the run
  reports success.
- **`--multi-key-get` is capped by the `GET` side of `--ratio`**
  (`client.cpp:641-642`: `keys_count = ratio.b - m_get_ratio_count`, then clamped
  to `multi_key_get`). `--ratio=1:19 --multi-key-get=16` yields ragged batches of
  16 then 3. Pair them: `--ratio=1:16 --multi-key-get=16`.
- **`--key-zipf-exp` is validated on `(0,5)` exclusive** (`memtier_benchmark.cpp:1729`),
  so `--key-zipf-exp=0` must exit non-zero. That is the one-line test that the
  flag is not being silently ignored by an older build.
- **memtier's Zipfian is unscrambled** — `obj_gen.cpp` returns low indices as the
  hot keys, contiguous in index space. The RocksDB/`scylla_bench` generator is
  FNV-1a **scrambled**. At equal nominal α the two produce different spatial
  reference streams; disclose it, or match them, before plotting the two
  campaigns on one axis. (At large value sizes the difference vanishes at page
  granularity, and ChampSim shuffles physical frames by default anyway —
  `vmem.cc`, seed 1 — so it matters only for small items.)
- **`--randomize` seeds from the clock** and destroys reproducibility.
- **memcached's `-R` (`settings.reqs_per_event`) defaults to 20**
  (`memcached.c:255`) — the ceiling on commands served per event-loop trip per
  connection, and therefore the natural ceiling on a useful `--pipeline` depth.
- **`do_item_bump` is wholly guarded by `ITEM_ACTIVE`** under the default
  segmented LRU, so a twice-hit item costs no extra pointer writes on subsequent
  hits. The common "3 random writes per LRU bump" assumption is wrong.

---

## 8. Capture and simulation traps

Carried forward from the pipeline docs and confirmed during the audit.

- **The trigger is one-shot with no stop, and can silently never fire.** The
  plugin polls only while a *traced* vCPU retires instructions. If the workload
  ends first you get `WARNING: Trigger was never activated!`, indistinguishable
  from a wrong path. Build with `-DTRIGGER_DEBUG` to disambiguate.
- **`scripts/boot_tcg_trace.sh:24` deletes prior traces** before validating its
  arguments. Re-running it "just to check something" destroys the last capture.
- **Hitting `limit=` does not stop QEMU**, and there is no live completion
  signal. Watch file sizes, not stderr.
- **`vcpus=` must match where the workload threads are pinned.** The scripts say
  `vcpus=1-4`; the memcached prose says `vcpus=0-3`. Getting it wrong traces the
  client and the idle OS — and, like §1, it looks like success.
- **TCG traces are ~80 % kernel-mode where ~50 % is real work**, because `HLT` is
  emulated in software. `trace_filter` removes it; budget the captured
  instruction count for the ~30 % it strips.
- **Trace wraparound is silent.** A trace shorter than warmup + simulation
  replays and prints `*** Reached end of trace`. Gate on it:
  `grep -rl 'Reached end of trace' results/ | wc -l` must be 0.
- **The cluster tlists are tab-indented and PyYAML rejects them** — verified:
  `ScannerError: found character '\t' that cannot start any token`. They cannot
  be fed to `create_jobfile.py`/`rollup.py` without conversion.
- **The kvmclock patch is absent from `~/qemu-custom` on this host.**
  `hw/i386/kvm/clock.c:226` still `error_setg`s under `!kvm_enabled()`, `:335`
  still asserts, the file was never edited, and the installed binary still
  contains the string `kvmclock device requires KVM`. A KVM `savevm` will not
  `-loadvm` under TCG here until QEMU is patched and rebuilt. The claim that this
  blocker is resolved is not supported by anything on this machine.
- **Conda breaks every C and C++ build** with an aarch64 cross-toolchain and x86
  `CFLAGS`. The converter and the pintool need the full six-variable scrub
  (`CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS`), not the three the C++ tools need.
- **`libcapstone-dev` is required even for a pure x86 flow**, because
  `converter/Makefile:38` links `decode_aarch64.o` unconditionally. Without root:
  `apt-get download libcapstone-dev libcapstone4`, `dpkg-deb -x` into a prefix,
  hand-write a `capstone.pc` (`PKG_CONFIG_SYSROOT_DIR` does *not* work — it is
  off by one level), build with `PKG_CONFIG_PATH` pointing at it. Verified: full
  build, `ALL PASS (30/30)` and `PASS 14/14`.
- **`converter/tests/props.py` and `mix_stats.py` are stale** — both read the
  branch type from byte 8, which was narrowed to a boolean. Three of `props.py`'s
  five invariants and all three of `mix_stats.py`'s balance checks now pass
  vacuously. Use `trace_sanity_check --check`.
- **Conversion is ~40 min per 500 M instructions**, single-threaded and
  compression-bound — not the "runs for minutes" in `converter/README.md:124`.
  Parallelise across `rotate=` chunks.
- **A less-skewed trace compresses worse.** Address entropy is what zstd was
  exploiting. Budget ≥ 7 B/instruction converted, above the 6.6–6.9 the old
  memcached traces cost.

---

## 9. Where the first campaign's artifacts live

Not in this repo, and not on the machine this audit ran on.

| Asset | Location |
|---|---|
| memcached traces (24, 150 GB) | `kratos2:~/tracezoo/champsim/version2/memcached/` |
| RocksDB traces (42, 141 GB) | `kratos2:~/tracezoo/champsim/version2/rocksdb/` |
| The simulation results (`stats.csv`, 96 rows) | `rnadig:~/arishem/runs/stats.csv` |
| memcached guest image + snapshot `memcached_rd95` | `rnadig:/mnt/sherlock/rahbera/qemu-tracing/images/` |
| RocksDB driver + 11 run scripts | `rnadig:/mnt/sherlock/rahbera/workloadzoo/rocksdb-driver/` |
| Never-converted `rd05_wr95` raw (86 GB) | `rnadig:.../qemu-tracing/tracestore/memcached/` |
| Never-catalogued α=0.6 traces (8, 35.5 GB) | `rnadig:.../rocksdb-driver/traces/…zipf0.6…/` |

`/mnt/sherlock` is local disk on `rnadig`, reachable as
`ssh -J kratos2 rahbera@safari-rnadig0.ee.ethz.ch` — it is **not** present on
`kratos2` itself.

The measured baseline the next campaign must beat, from one rd95 trace at
100 M warmup + 500 M simulation on the arishem/Hermes ChampSim (**192 KB L1D** —
not the 48 KB L0D of `lnc.toml`, so not directly comparable):

```
L1D  186,640,305 access / 1,901,362 miss = 1.02 %      <- the hot set fit in L1
L1I   78,335,235 access / 25,223,523 miss = 32.20 %    <- instruction-bound
LLC      938,177 access — 1.88 accesses per kilo-instruction
LLC total MPKI 1.147, average miss latency 109.18
unique_ppages 15,958 (62.3 MiB)
IPC 0.35208
```

For scale, FAISS `msturing10m_ivf1024flat` in the same window: **31.1 LLC load
MPKI, 247,753 `unique_ppages`.**

---

## 10. Method, and how to re-run this

Two workflows, both fully parallel, on `claude-opus-5[1m]`:

1. **Scout** — 14 readers, one per area (pipeline docs, each workload, plugin,
   converter, capture scripts, specs, pintool, sweep infra, trace tools, host
   environment, git history, plus a cross-cutting footprint/skew sweep) → 3
   adversarial critics (unread-file completeness, executability, contradiction
   and risk) → 10 gap-closing investigations → 1 synthesis. 5.5 M tokens.
2. **Parameter analysis** — 5 independent lenses (cache mathematics, production
   literature, memcached internals from source, instruction-window budget,
   capture feasibility) → 3 refuters instructed to default to "refuted"
   (arithmetic, mechanism, realism and experimental design) → 1 synthesis.
   1.5 M tokens.

**The refutation pass changed the answer**, which is the argument for keeping it.
It caught the static-coverage-vs-LRU error, the fabricated α = 0.6–0.8 literature
band, the DRAM-histogram criterion, and the fact that four of five lenses named
instructions-per-request as their biggest risk and then presented θ as the
decision anyway.

**What would make the next audit better:** every finding here that is Grade C
exists because a counter was not recorded at capture time. Record
`get_hits`/`get_misses`, `curr_items`, `evictions`, `cmd_get`/`cmd_set` and the
full client command line into the capture metadata, and most of §1 and §3 become
Grade A observations instead of reconstructions.
