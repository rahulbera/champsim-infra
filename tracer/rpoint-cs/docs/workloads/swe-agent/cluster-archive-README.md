# SWE-agent ChampSim traces — SWE-Bench Multilingual

Trace-driven ChampSim inputs recorded from **SWE-agent solving real SWE-Bench
Multilingual tasks** inside a QEMU guest. They exist to answer one question:
*are current state-of-the-art branch DIRECTION predictors adequate for agentic
workloads?* — so they are meant to be compared against conventional suites such
as SPEC CPU 2026, not used in isolation.

Last updated 2026-09-04. 40 instances, 188 window files, 118.6 GB (107 GiB).

---

## 1. What one file is

```
<instance_id>_w<NNNNN>.champsim2.zst
```

* **ChampSim v2 trace format**, fixed 512-byte records, zstd-compressed.
* One file = one **300,000,000-instruction window** of a single agent run.
* Windows are sampled on the **user-instruction clock** (`sample_clock=user`),
  spaced evenly across the whole recorded trajectory, so `w00000 … w00004` are
  ordered samples through one agent session rather than five separate runs.
* Every **September** file passed `tools/trace_sanity_check --check` at capture
  time, and the archiver refused to upload a window whose check log did not say
  so. The load-bearing assertion is that the conditional-branch taken rate is
  strictly inside (0, 100)%. The August files were placed here by an earlier
  process and that gate cannot be asserted for them retrospectively.

### `w00000` IS NOT A WORKLOAD SAMPLE — it is a canary

The first window catches SWE-agent **starting up** (imports, tool
registration), not the agent working. It reads very differently from the rest:
~8.2 MPKI and ~24% indirect branches, against 86–88% indirect in the compute
windows. It is kept deliberately, as a drift detector across captures.

**For workload analysis use `w00001` onward.** Including `w0` will skew any
aggregate, and it is the single most likely way to misuse this dataset.

## 2. Two generations, and one of them is a control

| suffix | what it is | count |
|---|---|---|
| *(none)* | **agentic** — SWE-agent actually solving the task | 37 instances |
| `.toolchain` | **control** — the same build/test commands with NO agent | 3 instances |

`.toolchain` traces exist to separate "what the agent does" from "what
compiling and testing does". **They are a different population. Never pool them
with the agentic traces.**

There are also two capture generations, distinguishable by date and by
provenance metadata:

* **August 2026** — 8 instances (`ripgrep-2576`, `gin-3820`,
  `prometheus-15142`, `redis-13115`, `rubocop-13668` plus 3 `.toolchain`
  controls). 4 windows each. **No checksum lines and no software provenance**;
  they predate both mechanisms.
* **September 2026** — 32 instances, the main campaign. All carry SHA-256 lines
  in `CHECKSUMS.sha256` and software provenance in their capture metadata.

## 3. Integrity

`../../../CHECKSUMS.sha256` (i.e. `tracezoo/champsim/CHECKSUMS.sha256`) holds
**156 lines, covering the 156 September files only.** Each digest was computed
on the producing host, recomputed on this cluster after transfer, and compared
before the file was considered archived — rsync exiting 0 was not treated as
evidence of arrival.

The 32 August files have **no digests**, because none were recorded when they
were made. Their integrity cannot be established against an original. This is
stated rather than hidden.

```sh
cd <this directory>/../..            # tracezoo/champsim
sha256sum -c CHECKSUMS.sha256        # August files will report as missing entries
```

## 4. `superseded-2026-08-07/`

`immutable-js__immutable-js-2006` is the **only instance id captured in both
generations**, so the September capture would have overwritten the August one
in place. The August copies were moved to `../superseded-2026-08-07/` instead,
with their digests recorded in the README there.

Same instance, same window numbering, **different execution**. Do not put both
in one tlist.

## 5. Which instances, and where they sit in the stratification

The 36 picks were stratified over 9 languages × a behaviour cell
(B/T/M/S — the recorded `label` axis) drawn from SWE-Bench Multilingual.
32 were captured.

| language | captured | cells captured | cells the selection assigned |
|---|---|---|---|
| C | 4/4 | B M S T | B M S T |
| C++ | 4/4 | B B B B | B B B B |
| PHP | 4/4 | B M S T | B M S T |
| Ruby | 4/4 | M T T T | M T T T |
| Rust | 4/4 | B B M T | B B M T |
| TypeScript | 4/4 | S T T T | S T T T |
| Go | 3/4 | B M M | B M M T |
| Java | 3/4 | B M T | B M S T |
| JavaScript | 2/4 | T T | M T T T |

**Read the two right-hand columns together.** Six languages have all four picks
captured, but only **C and PHP span four distinct cells** — the stratification
deliberately assigned several languages more than one pick in the same cell
(C++ is four B's). "All picks captured" is not "all cells covered", and an
earlier version of this project's notes conflated the two.

### The 32 captured (September)

| instance | language | cell | windows |
|---|---|---|---|
| jqlang__jq-2598 | C | S | 5 |
| micropython__micropython-13039 | C | T | 5 |
| redis__redis-10068 | C | M | 4 |
| redis__redis-12272 | C | B | 4 |
| fmtlib__fmt-2457 | C++ | B | 5 |
| fmtlib__fmt-3750 | C++ | B | 5 |
| fmtlib__fmt-3901 | C++ | B | 5 |
| nlohmann__json-4237 | C++ | B | 5 |
| caddyserver__caddy-4774 | Go | B | 5 |
| gohugoio__hugo-12579 | Go | M | 5 |
| prometheus__prometheus-10720 | Go | M | 5 |
| google__gson-1093 | Java | B | 5 |
| google__gson-2134 | Java | T | 5 |
| javaparser__javaparser-4538 | Java | M | 5 |
| axios__axios-5892 | JavaScript | T | 5 |
| babel__babel-15649 | JavaScript | T | 5 |
| briannesbitt__carbon-2752 | PHP | S | 5 |
| laravel__framework-52684 | PHP | B | 5 |
| php-cs-fixer__php-cs-fixer-7875 | PHP | T | 5 |
| phpoffice__phpspreadsheet-3463 | PHP | M | 5 |
| faker-ruby__faker-2705 | Ruby | T | 5 |
| fastlane__fastlane-20958 | Ruby | T | 5 |
| fluent__fluentd-3328 | Ruby | T | 5 |
| rubocop__rubocop-13560 | Ruby | M | 5 |
| burntsushi__ripgrep-2209 | Rust | T | 5 |
| nushell__nushell-13831 | Rust | B | 5 |
| sharkdp__bat-2835 | Rust | M | 5 |
| tokio-rs__axum-1730 | Rust | B | 5 |
| facebook__docusaurus-10130 | TypeScript | T | 5 |
| facebook__docusaurus-9897 | TypeScript | T | 5 |
| immutable-js__immutable-js-2006 | TypeScript | T | 4 |
| vuejs__core-11870 | TypeScript | S | 4 |

Two are **substitutions** for picks that could not be captured, and inherit the
cell of what they replaced: `faker-ruby__faker-2705` (for `jekyll-8167`) and
`php-cs-fixer__php-cs-fixer-7875` (for `php-cs-fixer-8064`). Both are the
selection's own recorded runner-ups, not free choices.

### Short traces are complete traces

Five instances have **4 windows, not 5**: `immutable-js-2006`, `redis-10068`,
`redis-12272`, `vuejs__core-11870` (and `preact-3763`, not archived). Window
starts are computed from a profiling pass, and a traced run can execute
slightly fewer instructions than the profile measured, so the last window falls
past the end of the run and never fires.

These are **not truncated or damaged**. Each window present is a full
300 M-instruction sample of real work, and the capture metadata records
`actual_windows=4`. Count windows per instance rather than assuming 5.

## 6. Provenance

Every September capture was produced by the same software, verified uniform
across all metas:

```
SWE-agent   3ea751c087f32b16e039a2233dd6eefecef325d5   (v1.1.0-177-g3ea751c0)
swe-rex     1.4.0 (stock, unpatched)
Python      3.12.3
guest       Ubuntu 24.04, single pinned isolated vCPU, QEMU TCG + a tracing plugin
model       GLM-5.2, replayed from recorded cassettes — no live API calls
```

The traces are of a **replay**, not a live agent session. Each was gated on the
replay executing *exactly* the recorded action sequence, in order, with zero
cassette misses; a divergent replay was refused rather than traced. That gate is
why several picks are missing rather than approximated.

The capture metadata (`capture-<id>.meta`, on the producing host) records
`swe_agent_commit`, `swerex_version`, `swerex_sha256` and `guest_tools_sha256`.
The digest matters: a local edit to SWE-ReX changes it while the version string
stays the same.

**No file in this directory was produced with a patched SWE-ReX.** One such
capture exists (`preactjs__preact-3763`, recorded with `bash --noediting`) and
is deliberately held on the producing host, because mixing software generations
here is a decision about the dataset rather than about one instance.

## 7. What is missing, and why

Four of the 36 picks are not here. They are not four instances of the same
problem:

| pick | cell | why |
|---|---|---|
| `projectlombok__lombok-3479` | Java×S | **Tooling.** lombok builds with Ant and resolves multiple JDK runtimes through custom ivy descriptors; no Ant language module exists, and its test target has no way to exclude the failing fixture. The only slot lost to our toolchain rather than to a defect. |
| `gin-gonic__gin-2121` | Go×T | SWE-ReX PTY wedge — **since shown recoverable**. |
| `preactjs__preact-3763` | JS×M | SWE-ReX PTY wedge — **recovered under a patch, held back** (§6). |
| `mrdoob__three.js-26589` + runner-up `-27395` | JS×T | SWE-ReX PTY wedge, both deterministic. |

Two further instances were lost to a **different** defect and replaced by
runner-ups: `preactjs__preact-4182` and `php-cs-fixer__php-cs-fixer-8064` both
truncated under TCG on a hardcoded 25-second timeout in SWE-agent's state
command. That is a wall clock, unrelated to the PTY wedge, and no patch here
addresses it.

Full write-ups, including the measurement that killed the obvious "heredocs
cause the wedge" hypothesis, live in the producing repo under
`tracer/rpoint-cs/docs/workloads/swe-agent/`:
`known-issue-gin-2121-replay-wedge.md`,
`known-issue-preact-3763-replay-wedge.md`,
`known-issue-three.js-26589-replay-wedge.md`,
`known-issue-php-cs-fixer-8064-state-timeout.md`,
and the live plan in `campaign-2026-09-plan.md`.

## 8. Using them

```sh
# one instance, workload windows only (skip the w0 canary)
ls <instance>_w0000[1-4].champsim2.zst

# a tlist entry needs version 2
#   name: { path: <...>.champsim2.zst, version: 2, workload: agentic, ... }
```

Rules of thumb this dataset was built around:

1. **Skip `w0`** unless you are studying harness startup.
2. **Never pool `.toolchain` with agentic traces** — different populations.
3. **The unit of analysis is the task, not the window.** Aggregate windows
   within an instance first, then across instances — the same two-level scheme
   SPEC uses for its slices.
4. **Count windows; do not assume 5.**
5. **Do not mix the August and September generations** without saying so: they
   differ in agent software and, for `immutable-js-2006`, are literally
   different executions of the same task.
