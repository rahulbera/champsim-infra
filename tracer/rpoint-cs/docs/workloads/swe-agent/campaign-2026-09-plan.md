# Campaign 2026-09 — scaling to 36 tasks: plan and live status

**Living document.** Statuses below are kept current as work progresses. If a
status here disagrees with reality, reality wins and this file is stale — say so.

**Goal.** Capture ChampSim traces for the 36 SWE-bench Multilingual tasks in the
`ML_iso36` stratification (4 per language × 9 languages), up from the 6
instances captured in August 2026.

**Source of the task list:**
`/home/rbera/work/bpeval/InferSuite/local_agents/ML_typeid/selection_36_count.tsv`
Banked trajectories for all 36:
`/home/rbera/work/bpeval/InferSuite/local_agents/ML_typeid/replay_trajs/*.min.traj`

**Status legend:** `TODO` · `IN PROGRESS` · `DONE` · `BLOCKED` · `SKIPPED` · `FAILED`

---

## Progress summary

| step | what | cost | status |
|---|---|---|---|
| **0** | Hygiene and the load-bearing fixes | ~30 min, no VM | `DONE` (8/8) |
| **1** | Recover prometheus, reclaim | ~15 min | `DONE` — recovery succeeded; reclaim deferred |
| **2** | Trajectory compatibility test | ~5 min | `TODO` |
| **3** | Phase 1 — five tasks, one per proven language | ~45 instance-h | `TODO` |
| ‖ | Determinism check (concurrent with step 3) | ~1.7 h | `TODO` |

Steps 0–2 are the high-value targets: **many step-3 decisions depend on step 2's
verdict**, so they run first and fast.

---

## Step 0 — hygiene and the load-bearing fixes

No VM, no capture path touched. Removes footguns that would otherwise silently
corrupt a Phase-1 run.

| # | Target | Status |
|---|---|---|
| 0.1 | Fix the 8 doc/code disagreements the audit found (code is correct in all 8; see the table at the end of the orientation brief) | `DONE` |
| 0.2 | Retire `docs/superpowers/specs/2026-08-06-swe-agent-tracing-design.md` and `plans/2026-08-06-llm-replay-proxy.md` — mark historical; four sections are superseded while the status line still reads "ready for implementation planning" | `DONE` |
| 0.3 | Move `instances/rubocop__rubocop-13680.env` → `instances/dropped/`, and delete the hardcoded name skip at `capture_status.sh:60` | `DONE` |
| 0.4 | Introduce `RPOINT_IMAGES` and use it at all call sites: `images/boot_tcg_trace.sh:10,18`, `images/boot_build.sh:5`, `images/boot_tcg_gate.sh:7`, `scripts/capture_agentic.sh:27` | `DONE` |
| 0.5 | Assert `CAPTURE_SLOT` is present and unique at descriptor load (`lib/common.sh`) — two `.env` files currently both declare slot 1, and a missing slot makes the arithmetic evaluate silently | `DONE` |
| 0.6 | Record `pip freeze` into `artifacts/<id>/versions.txt` during provisioning; stop discarding the version line through `provision_instance.sh:97`'s `\| tail -40` | `DONE` |
| 0.7 | Parameterise the hardcoded window count for K=5: `capture_status.sh:72,74,89` (`nw/4`) and `reclaim_space.sh:60` (`n >= 4`) | `DONE` |
| 0.8 | Archive the old `attempts/` ledger, start a clean one, and actually call `attempts.sh` from the chain — nothing calls it today | `DONE` |

### Found while doing step 0 (beyond the planned targets)

- **A seventh hardcoded image path.** `run_capture_chain.sh:18` set
  `LOGDIR=$ROOT/images/chain-$INSTANCE`. The audit had found four call sites;
  there were seven — six drivers computing `IMAGES=$ROOT/images` plus this one.
  All now read `RPOINT_IMAGES` from `scripts/lib/paths.sh`.
- **The boot scripts that actually execute are the LIVE tree's copies.** The
  drivers `cd "$IMAGES"` and then run `bash boot_build.sh`, which resolves
  relative to that cwd — so editing only the repo copy changes nothing. The two
  trees must be kept in sync by hand after any edit to `images/boot_*.sh`.
- **The chain skipped its own safety gate.** `FIRST=${2:-profile}` meant a bare
  `run_capture_chain.sh <id>` went straight to profile, skipping verify — so a
  replay that had already diverged from its recording would be faithfully traced
  for hours. Default is now `verify` (2–5.5 min under KVM).
  `advance_instance.sh:113` passes an explicit `profile`, so it does not
  double-run.
- **Window count is now per-capture, not global.** Reading K from each
  capture's own `.meta` rather than a single constant: the August captures are
  legitimately K=4 and a hardcoded 5 would report every one of them as an
  incomplete `4/5` forever.
- **A bug in my own first fix:** `SLOT=... || die` was placed above `die()`'s
  definition, so a slot failure would have printed "die: command not found"
  instead of the reason. Now a plain `exit 1` after `resolve_slot` has explained
  itself on stderr.

**Done when:** both test gates still pass (`tests/test_reports.py`,
`tests/test_cluster_run.py`), and a dry `capture_status.sh` run reports sanely
with no hardcoded `/4`.

---

## Step 1 — recover prometheus, then reclaim

`prometheus__prometheus-15142`'s cassettes and trajectory exist nowhere on this
host or on any git branch. Its provisioned image is a **33-byte qcow2 header
stub**, not an image. The one remaining hope is the legacy post-record snapshot
`qemu-tracing/images/swe-agent-guest.recorded.qcow2` (13.5 GB, 2026-08-06),
which survives only because `reclaim_space.sh`'s `guest-*.qcow2` glob cannot
match its name.

| # | Target | Status |
|---|---|---|
| 1.1 | Read-only inspect the legacy image for `/opt/cassettes/prometheus__prometheus-15142` (`virt-ls --ro`, or a read-only loopback mount — never a writable attach) | `DONE` |
| 1.2 | If present: extract cassettes **and** the trajectory to `artifacts/prometheus__prometheus-15142/` | `DONE` |
| 1.3 | Validate what was recovered: `len(_order.json) == len(set(keys)) == cassette file count`, and grep for a leaked `authorization` header | `DONE` |
| 1.4 | Record the outcome here either way — if absent, the existing 4 prometheus traces are permanently un-reverifiable and that fact belongs in writing | `DONE` |
| 1.5 | Free the 32 GB of legacy `swe-agent-guest*.qcow2` | `DEFERRED` |
| 1.6 | **Keep** the 19 GB of `guest-*.provisioned.qcow2` until Phase 1 proves the pipeline | `DONE` |

### Outcome — recovered in full, and more than expected (2026-09-01)

Booted `swe-agent-guest.recorded.qcow2` with QEMU `-snapshot`, so every write
went to a throwaway overlay; the backing image was verified byte-identical
afterwards (`md5 94eb6fe51a005a0703831f10df401330`, mtime still 2026-08-06).

**Recovered:** 147 cassettes, the full 48 MB `2ee7bd.traj`, the trajectory logs
and the problem statement, into
`qemu-tracing/artifacts/prometheus__prometheus-15142/`. No leaked `authorization`
header in any cassette.

**The `_order.json` was missing** — the manifest postdates prometheus's Aug-6
recording; the five later instances all have one. It was reconstructed by
sorting cassettes on their response `created` timestamp (147 distinct, ties
broken by response id) and then **validated against the trajectory's own action
sequence: 146/146 positions match, zero divergence**. That is a stronger
guarantee than the original manifest ever carried, since the original was
append-order that nothing ever checked.

**One cassette was superseded and is correctly excluded** from the manifest: a
retry issued 1 second before its replacement, carrying a truncated command
(`git log --oneline -5` against the kept `git log --oneline -5 && echo "---" &&
ls tsdb/`). This is the gson failure mode caught in the wild — 147 cassettes
against 146 real turns. The file is kept on disk, just not in the order.

**And the provisioned image was found.** `swe-agent-guest.provisioned.qcow2`
(6.3 GB) turned out to BE prometheus's provisioned state — `/prometheus` at
`16bba78f1549cfd7909b61ebd7c55c822c86630b`, exactly the descriptor's
`BASE_COMMIT`, with no cassettes or trajectories (clean pre-record state). Its
properly-named counterpart was the 33-byte stub. Promoted to
`guest-prometheus__prometheus-15142.provisioned.qcow2`; the stub is kept as
`.stub-33b` rather than deleted.

**prometheus-15142 is therefore no longer un-reverifiable.** It now has a
provisioned image, cassettes, a validated order and a full trajectory — every
input a verify/profile/trace needs.

### Why 1.5 is deferred, not done

The approval to free 32 GB rested on those three legacy images being
disposable. One of the three was load-bearing, which falsifies the premise for
the other two. `swe-agent-guest.qcow2` (12.9 GB) has not been inspected and may
likewise be someone's working state. ~25 GB remains reclaimable once it is
checked; there is no pressure (456 GB free, Phase 1 needs ~51 GB), so it waits
for a look rather than a guess.

**Note:** prometheus-15142 is *not* in the new 36 (the Go picks are caddy-4774,
gin-2121, prometheus-10720, hugo-12579). This recovery protects the *existing*
traces, not the new campaign.

---

## Step 2 — trajectory compatibility test

**The campaign-defining unknown.** Everything downstream assumes the intern's
banked trajectories replay under our harness. This is a **verify pass only** —
KVM, offline, no TCG, measured at 2–5.5 min.

Test instance: `immutable-js__immutable-js-2006` — it is in both the old 6 and
the new 36, has a healthy 45-cassette set of our own (45 entries / 45 unique /
45 files), an intact 2.9 GB provisioned image, and four existing traces.

| # | Target | Status |
|---|---|---|
| 2.1 | Read the intern's `immutable-js__immutable-js-2006.min.traj` (139 assistant turns, all carrying `tool_calls`) and confirm its `replay_config` matches our instance's repo and base commit | `TODO` |
| 2.2 | Synthesize cassettes in our proxy's format (`{key, status, headers, body}`) from the assistant turns — the bodies must be well-formed chat-completion responses carrying the recorded `tool_calls` | `TODO` |
| 2.3 | Build `_order.json` and **assert `entries == unique == file count`** before running anything — this is the one-line check that would have caught gson | `TODO` |
| 2.4 | Run the verify pass against the provisioned image with the synthesized cassettes | `TODO` |
| 2.5 | Assert **zero** `REPLAY MISS` | `TODO` |
| 2.6 | Run `compare_trajectories.py` against the intern's own recorded action sequence — **this is the real gate**; zero misses alone proves nothing, because sequence replay serves responses in order and a desynced replay finishes cleanly | `TODO` |
| 2.7 | Record the verdict below and its consequence for step 3 | `TODO` |

### Verdict (fill in)

- **Outcome:** _pending_
- **Consequence:** one of —
  - *Compatible* → reuse all 36 banked trajectories. No API key needed, no
    credits spent, and the intern's B/T/S/M cell labels stay valid because they
    were computed from exactly these trajectories.
  - *Needs the full conversation* → ask the intern to re-export the 36 without
    minification (they have the machinery); the `.min.traj` keeps only assistant
    turns, observations are stripped.
  - *Incompatible* → **re-record live** (PI decision, 2026-09-01: this is not a
    blocker, budget is sufficient). Requires the **OpenRouter** key — ask for it
    then; never the old GLM key. Consequence to flag: a fresh recording is a
    fresh trajectory (sampling at temp 0.6 is stochastic even with an identical
    model and provider), so cell labels must be recomputed by re-running the
    intern's classifier over our trajectories.

---

## Step 3 — Phase 1: five tasks, one per proven language

Begins once step 2's verdict is known. Language scope is phased by PI
direction: proven languages first at one task each, then depth in those
languages, then C++ and Java last.

| language | pick | cell | fence | why this one |
|---|---|---|---|---|
| C | `redis__redis-12272` | B | 50 core-s | redis-13115 captured cleanly |
| Rust | `burntsushi__ripgrep-2209` | T | 82 | ripgrep-2576 captured cleanly |
| Go | `gin-gonic__gin-2121` | T | 18 | gin-3820 captured; smallest fence in the set |
| Ruby | `rubocop__rubocop-13560` | M | 37 | rubocop-13668 captured cleanly |
| TypeScript | `immutable-js__immutable-js-2006` | T | 655 | proven, **and** the gen-1/gen-2 bridge |

| # | Target | Status |
|---|---|---|
| 3.1 | Write `create_guest_image.sh` — **currently missing entirely**; `provision_instance.sh:69` only dies with "no image at $WORK — create it with qemu-img first" | `TODO` |
| 3.2 | Stage and verify descriptors for the five instances (`stage_instance.py`, then the no-flag verification pass that hard-fails on dataset disagreement) | `TODO` |
| 3.3 | Host pre-flight each: F2P test runs and fails at base commit; runs and passes with the gold patch | `TODO` |
| 3.4 | Provision all five with today's software, recording `pip freeze` | `TODO` |
| 3.5 | Obtain trajectories per step 2's verdict (reuse or re-record) | `TODO` |
| 3.6 | Verify pass on each — zero misses **and** trajectory match | `TODO` |
| 3.7 | Profile, trace at **K=5**, convert, validate | `TODO` |
| 3.8 | Publish to `tracezoo/champsim/version2.1/agentic/…`, append to `CHECKSUMS.sha256`, with an exhaustive count assertion | `TODO` |
| 3.9 | Establish the new w0 canary band and compare immutable-js against its August traces (the gen-1/gen-2 drift measurement) | `TODO` |

Not in Phase 1: JavaScript and PHP are **unproven** — they have modules but
never produced a trace, and PHP's only attempt (`carbon-3103`) died to an
unidentified external SIGTERM across 4–5 provisioning attempts.

---

## ‖ Determinism check (concurrent with step 3)

**No instance has ever been captured twice.** Every determinism claim in the
existing write-ups rests on w0 agreeing across six *different* tasks, which
shows the venv was constant, not that the pipeline reproduces.

| # | Target | Status |
|---|---|---|
| D.1 | Run two independent profile passes on `gin-gonic__gin-3820` from the same provisioned image with the same 31 cassettes | `TODO` |
| D.2 | Compare `profile_total`, user and kernel instruction counts between the two | `TODO` |
| D.3 | Record the divergence; if it is large, Phase 1 needs repeats and that is a design input, not a footnote | `TODO` |

Runs in a spare slot at 6-way, so it costs no wall clock. gin is chosen because
its profile pass was 50 min against immutable-js's 194 min — same question,
a quarter of the cost.

---

## Decisions of record (2026-09-01)

| # | Decision | Consequence |
|---|---|---|
| 1 | **Unit of analysis = task/instance** (36 samples) | Agentic aggregation becomes two-level like SPEC — windows within task, then across tasks. `campaign_stats.py` and `compare_agentic_vs_spec.py` are flat over traces today and must change. |
| 2 | **Phased languages** — proven first, then depth, then C++/Java | Phase 1 is 5 tasks. C++ needs a new CMake/CTest module; Java's exclusion is methodological and must be re-litigated explicitly. |
| 3 | **K=5; analyse w1–w4; w0 is a drift canary** | w0 is harness startup (24.1–24.5% indirect vs 86–88% in compute windows), identical across tasks. Capturing it 36× would drag every aggregate toward the startup signature. Marginal TCG cost ≈ 10 s; the real cost is convert time and ~610 MB/task. |
| 4 | **No controls in this campaign** | Revisit later. Also dissolves the `CAPTURE_SLOT` collision, which came from controls deriving `SLOT+10`. |
| 5 | **`RPOINT_IMAGES` env var; image data stays put** | 73 GB of qcow2 and build products stay outside git. |
| 6 | **Pin to today's software, record it, bridge via immutable-js** | Old 24 = generation 1, new = generation 2, with one task spanning both. |
| 7 | **Automate only the load-bearing gaps** | `create_guest_image.sh`, slot uniqueness, catalog publish, tlist generation. Descriptor writing stays manual for five instances. |
| 8 | **Local, 6-way; storage is the binding constraint** | ~223 GB for 36 tasks against 456 GB free. Release the TCG slot before convert (convert launches no QEMU; gin held a slot 5.0 h with TCG done after 1.8 h). |
| 9 | **Recover prometheus cassettes, then free 32 GB** | Keep the 19 GB of provisioned images until Phase 1 proves out. |

**Standing constraints**

- **API key:** OpenRouter, serving GLM-5.2 from Z.ai. **Never the old GLM key**
  (cost-center assignment). Ask for it only when a step actually needs it.
- **Trace accounting:** every trace counted, and counted in its correct
  category. No silent `other` bucket; assert bucket sizes sum to the input
  count. `.toolchain` is never agentic.
- **Aggregation:** geomean for ratios, arithmetic mean for percentages. Agentic
  traces carry no SimPoint weights — they are uniform samples on the guest
  user-mode clock.

---

## Deferred, explicitly

- Controls (`.toolchain`) — dropped for now, revisit after Phase 1.
- The `go test -race` control experiment named in `agentic-vs-spec.md:246-251`.
- C++ CMake/CTest language module; Java re-admission.
- `706.stockfish_r.sp0` — intact copy at
  `kratos2:/home/rahbera/tracezoo/champsim/version2.1/spec26/`; fetch and verify
  against `CHECKSUMS.sha256` when the SPEC baseline is next needed. Local SPEC is
  31 slices, not 32, and `rollup.py` does not renormalise.
- Cluster offload to kratos2 — architecturally sound but nothing is installed
  there, and the login node is a 2017 Xeon against a local Zen 5.
