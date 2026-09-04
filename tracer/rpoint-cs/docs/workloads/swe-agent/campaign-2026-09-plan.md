# Campaign 2026-09 — scaling to 36 tasks: plan and live status

**Living document — steps and status only.** Statuses are kept current as work
progresses; if one disagrees with reality, reality wins and this file is stale.
Findings, verification evidence and rationale live in the commit messages of the
commits that did the work, not here.

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
| **2** | Trajectory compatibility test | ~5 min | `DONE` — **COMPATIBLE** |
| **3** | Phase 1 — **four** tasks (gin deferred) | ~45 instance-h | `IN PROGRESS` |
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

## Step 1 — recover prometheus, then reclaim

Recovered. `prometheus__prometheus-15142` now has cassettes, a reconstructed and
validated `_order.json`, a full trajectory and a real provisioned image — it is
no longer un-reverifiable.

| # | Target | Status |
|---|---|---|
| 1.1 | Read-only inspect the legacy image for `/opt/cassettes/prometheus__prometheus-15142` (`virt-ls --ro`, or a read-only loopback mount — never a writable attach) | `DONE` |
| 1.2 | If present: extract cassettes **and** the trajectory to `artifacts/prometheus__prometheus-15142/` | `DONE` |
| 1.3 | Validate what was recovered: `len(_order.json) == len(set(keys)) == cassette file count`, and grep for a leaked `authorization` header | `DONE` |
| 1.4 | Outcome: 147 cassettes + 48 MB trajectory recovered; `_order.json` was absent and was rebuilt from response timestamps, validated 146/146 against the trajectory; one superseded retry excluded. The legacy `swe-agent-guest.provisioned.qcow2` proved to BE prometheus's provisioned image and was promoted | `DONE` |
| 1.5 | Free the 25.5 GB of legacy `swe-agent-guest*.qcow2` — needs a read-only `-snapshot` inspection of `swe-agent-guest.qcow2` first, since the third image in that set turned out to be load-bearing | `DEFERRED` |
| 1.6 | **Keep** the 19 GB of `guest-*.provisioned.qcow2` until Phase 1 proves the pipeline | `DONE` |

## Step 2 — trajectory compatibility test

**The campaign-defining unknown.** Everything downstream assumes the intern's
banked trajectories replay under our harness. This is a **verify pass only** —
KVM, offline, no TCG, measured at 2–5.5 min.

Test instance: `immutable-js__immutable-js-2006` — it is in both the old 6 and
the new 36, has a healthy 45-cassette set of our own (45 entries / 45 unique /
45 files), an intact 2.9 GB provisioned image, and four existing traces.

| # | Target | Status |
|---|---|---|
| 2.1 | Read the intern's `immutable-js__immutable-js-2006.min.traj` (139 assistant turns, all carrying `tool_calls`) and confirm its `replay_config` matches our instance's repo and base commit | `DONE` |
| 2.2 | Synthesize cassettes in our proxy's format (`{key, status, headers, body}`) from the assistant turns — the bodies must be well-formed chat-completion responses carrying the recorded `tool_calls` | `DONE` |
| 2.3 | Build `_order.json` and **assert `entries == unique == file count`** before running anything — this is the one-line check that would have caught gson | `DONE` |
| 2.4 | Run the verify pass against the provisioned image with the synthesized cassettes | `DONE` |
| 2.5 | Assert **zero** `REPLAY MISS` | `DONE` |
| 2.6 | Run `compare_trajectories.py` against the intern's own recorded action sequence — **this is the real gate**; zero misses alone proves nothing, because sequence replay serves responses in order and a desynced replay finishes cleanly | `DONE` |
| 2.7 | Verdict → **COMPATIBLE**: 0 misses, 135/135 actions matched, fix applied, in-guest suite green. Two consequences for step 3: descriptors must set `REPO_DIR=/testbed` (trajectories reference it 136×), and trajectories must never be rewritten to suit our paths | `DONE` |

## Step 3 — Phase 1: four tasks (gin-2121 deferred)

Begins once step 2's verdict is known. Language scope is phased by PI
direction: proven languages first at one task each, then depth in those
languages, then C++ and Java last.

| language | pick | cell | fence | why this one |
|---|---|---|---|---|
| C | `redis__redis-12272` | B | 50 core-s | redis-13115 captured cleanly |
| Rust | `burntsushi__ripgrep-2209` | T | 82 | ripgrep-2576 captured cleanly |
| ~~Go~~ | ~~`gin-gonic__gin-2121`~~ | T | 18 | **DEFERRED 2026-09-01** — replay wedges, truncates at 31/39. See `known-issue-gin-2121-replay-wedge.md`. Go coverage moves to Phase 2 (caddy-4774, prometheus-10720, hugo-12579 remain) |
| Ruby | `rubocop__rubocop-13560` | M | 37 | rubocop-13668 captured cleanly |
| TypeScript | `immutable-js__immutable-js-2006` | T | 655 | proven, **and** the gen-1/gen-2 bridge |

| # | Target | Status |
|---|---|---|
| 3.1 | Write `create_guest_image.sh` — **currently missing entirely**; `provision_instance.sh:69` only dies with "no image at $WORK — create it with qemu-img first" | `DONE` |
| 3.2 | Stage and verify descriptors for the five instances (`stage_instance.py`, then the no-flag verification pass that hard-fails on dataset disagreement) | `DONE` |
| 3.3 | Host pre-flight — **satisfied by the stratification's own evidence**: all 36 picks were selected under a resolution-clean rule requiring the census episode be officially resolved by the SWE-bench harness (`swebench` 5.0.2, dockerized, official F2P+P2P). 32/36 resolved; none of our five is among the four misses | `DONE` |
| 3.4 | Provision all five with today's software, recording `pip freeze` | `TODO` |
| 3.5 | Obtain trajectories per step 2's verdict (reuse or re-record) | `TODO` |
| 3.6 | Verify pass on each — zero misses **and** trajectory match | `TODO` |
| 3.7 | Profile, trace at **K=5**, convert, validate | `TODO` |
| 3.8 | Publish to the LOCAL catalog `tracezoo/champsim/version2.1/agentic/…` and append to its `CHECKSUMS.sha256`, asserting the count exhaustively (every window of every task accounted for, no silent `other`). **The local catalog is now a staging cache, not the endpoint** — 3.10 is the endpoint | `TODO` |
| 3.9 | Establish the new w0 canary band and compare immutable-js against its August traces (the gen-1/gen-2 drift measurement) | `TODO` |
| 3.10 | **Archive the task's traces to kratos2** → `/home/rahbera/tracezoo/champsim/version2.1/agentic/swe-agent-w-swe-bench-multilingual/`. rsync, then **re-hash remotely and compare against the local digest** — the transfer is not done until they match. Append to a remote `CHECKSUMS.sha256` (does not exist yet; create on first archive) | `DONE 2026-09-02` for the first 6 (ripgrep-2209, rubocop-13560, redis-12272, immutable-js-2006, nushell-13831, fastlane-20958): 28/28 windows, 18.12 GB, `ARCHIVE_EXIT=0`; local, remote and manifest digests agree on all 28, verified independently of the script |
| 3.11 | Only after 3.10's remote digest check passes, reclaim the local copy. **The hardlink claim is wrong as stated and was corrected 2026-09-02:** measured over the first 28 windows, 27 have link count 1 (removing the `champsim_out/` name frees the space) and exactly one — the single representative window the catalog keeps per instance — has 2. `archive_to_cluster.sh` now detects and names them instead of asserting it. Keep the `.check.log` siblings: the cluster has the bytes, not the validation evidence | `PARTIAL` — 28 GB of scratch guest images and empty `profile_out-*` reclaimed 2026-09-02 (images/ 174 GB → 145 GB, free 453 → 481 GB); the 18.12 GB of archived traces are verified safe to drop but **kept locally for now**, since the cluster copy would otherwise be the only one |

**Per-task ordering, once a capture finishes:** convert → `trace_sanity_check
--check` on every window (3.7) → local catalog + digest (3.8) → archive to
kratos2 + remote digest comparison (3.10) → reclaim locally (3.11). The local
catalog is a cache between the tracer and the cluster; the cluster is where a
trace durably lives. Nothing is reclaimed on the strength of a transfer having
been *attempted*.

Not in Phase 1: JavaScript and PHP are **unproven** — they have modules but
never produced a trace, and PHP's only attempt (`carbon-3103`) died to an
unidentified external SIGTERM across 4–5 provisioning attempts.

---

### A short trace is not a lost trace (2026-09-02)

`redis__redis-12272`'s trace produced 4 of 5 windows and the trace gate refused
it on the count. The four were converted and kept rather than discarded:

1. The plugin manifest records each as a **complete 300,000,000-instruction
   window** at its intended start (0, 61170567571, 117119665770, 172057209993).
   Nothing is truncated; the run simply ended before the fifth.
2. The replay driving them was **FAITHFUL** — 45/45 actions, 0 misses, no
   cancelled steps, patch 775 B matching the banked reference exactly.
3. The unit of analysis is the **task**, so uneven window counts are harmless by
   construction: this instance contributes a mean over its 3 usable windows
   (w0 being the startup canary) instead of 4.

**The count gate lives only in the trace phase**, not in convert, so converting
a short capture needs no override — just run `convert` directly. Record the real
count as `actual_windows=` in the `.meta`.

**Root cause, and it generalises:** the profile pass that computed
`sample_gap=48 Ginstr` hit the SWE-ReX wedge; the trace pass ran clean. A wedge
changes how much user work a run performs, so the geometry was measured on an
unrepresentative run and then consumed by a representative one. **A wedge during
profile can silently poison the geometry**, and the damage only surfaces two
hours later at the trace gate. Re-profiling on a clean pass would fix it
(~2.5 h TCG); not done.

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

## Writing a gate command: read the trajectory, not the repo layout

Learned the hard way twice on 2026-09-02, both costing a full provisioning run.

1. **fastlane-20958** — I guessed `bundle exec rspec spec/action_spec.rb`.
   fastlane is a monorepo: specs live under `<gem>/spec/`. rspec reported
   "No examples found" and the gate correctly refused.
2. **micropython-13039** — I then read the instance's `FAIL_TO_PASS`
   (`basics/slice_indices.py`) and still guessed the *invocation*:
   `cd ports/unix && ./run-tests`. At this commit the runner is
   `tests/run-tests.py` and needs `MICROPY_MICROPYTHON` pointed at the built
   binary.

**And a fourth, on the same instance again:** set `GATE_TEST_PATTERN`.
`c_make.sh` counts gate tests with that field, defaulting to `^\[ok\]` — which
is redis's tcl harness, not a universal format. micropython's `run-tests.py`
prints `pass  <file>`, so with the default the counter saw **0** and the gate
refused a run in which all 13 PASS_TO_PASS tests had just passed. The field
existed and was documented; I had simply not set it.

**A four-field checklist for every new descriptor**, each item learned by losing
a provisioning run:

| field | source | failure if wrong |
|---|---|---|
| which test matters | the instance's `FAIL_TO_PASS` | gate exercises nothing |
| how it is invoked | the instance's own trajectory | "no such file", "no examples found" |
| which set may be required to pass | `PASS_TO_PASS` | gate rejects the instance for having its own bug |
| how to count what ran | `GATE_TEST_PATTERN` | counter reads 0 on a passing run |

**And a third layer, learned an hour later on the same instance:** the
trajectory gives the *runner and its environment*, but the **test set** must come
from `PASS_TO_PASS`. Gating micropython on the whole `basics` directory ran 514
tests, 508 passed and **6 failed** — including `slice_op`, because that
instance's bug *is* in slicing. A gate demanding a green suite at a base commit
which by construction contains a bug rejects the instance for having the very
defect it was selected for. `PASS_TO_PASS` is the set SWE-bench guarantees passes
at that commit, so it is the only honest choice.

**The rule:** the F2P entry names *which* test matters, but the trajectory shows
*how it is invoked* — and the invocation is the part that keeps being wrong.
Grep the instance's own `.min.traj` for the test command before writing
`GATE_TEST_CMD`:

```bash
python3 - <<'EOF'
import json
d=json.load(open('<replay_trajs>/<instance>.min.traj'))
for m in d['history']:
    for tc in (m.get('tool_calls') or []):
        a=tc['function'].get('arguments','')
        if 'test' in a.lower(): print(a[:160])
EOF
```

Both failures were logged as **infra**, not instance strikes: a wrong gate in a
descriptor is our bug, and under the house rule the task keeps all three tries.

## Campaign accounting as of 2026-09-04 18:00

32 of the 36 picks are captured, validated and archived. SIX languages are
COMPLETE at all four behaviour cells:

| language | captured | missing |
|---|---|---|
| C | 4/4 | — |
| C++ | 4/4 | — |
| PHP | 4/4 | — (php-cs-fixer-7875 replacing 8064) |
| Ruby | 4/4 | — (faker-2705 replacing jekyll-8167) |
| Rust | 4/4 | — |
| TypeScript | 4/4 | — |
| Go | 3/4 | gin-2121 (T) |
| Java | 3/4 | lombok-3479 (S) |
| JavaScript | 2/4 | preact (M), three.js (T) |

Four slots unfilled, and they are NOT four equivalent problems:

1. `lombok-3479` (Java×S) — blocked on TOOLING. No Ant module, and its tests
   resolve multiple JDK runtimes through custom ivy descriptors. See below.
   This is the only slot lost to our own toolchain rather than to a defect.
2. `gin-2121` (Go×T), `preact-3763` (JS×M), `three.js-26589/27395` (JS×T) — all
   lost to the SWE-ReX PTY wedge, and **all three are now recoverable**:
   `bash --noediting` took preact-3763 from 27/55 wedged to a complete capture
   on 2026-09-04 (verify 55/55, profile, trace 55/55). See
   `known-issue-gin-2121-replay-wedge.md` §5a.

**The open decision is the PI's, not an engineering one.** Filling those three
cells with patched captures makes a two-generation dataset; re-running the other
32 for uniformity costs ~4 h each. Captures now record `swerex_patch` and
`swerex_sha256`, so either choice is auditable after the fact — which was not
true before 2026-09-04 and is why the patch went unapplied for a month.

Two instances were lost to a DIFFERENT defect and are NOT recoverable by that
patch: `preact-4182` and `php-cs-fixer-8064` died on the 25-second
`_state_anthropic` timeout, a wall clock unrelated to readline. Both cells are
nevertheless filled — JS×M is not, but PHP×T is, by 8064's runner-up.

## Disk: what was reclaimed, and what is deliberately NOT (2026-09-04 22:00)

1. Reclaimed 111 GB of scratch guest images with `reclaim_space.sh --apply`
   (free: 234 GB → 345 GB). Safe by construction: every phase recreates the
   working guest from the `.provisioned` image.
2. **The 147 GB of `.provisioned` images are being KEPT, and the reason is the
   pending decision.** If the PI chooses to re-run captures under the patched
   SWE-ReX for a uniform generation, those images are exactly what a re-run
   starts from. Deleting them would add a full re-provision (20-90 min each) to
   all 32 instances and would make the uniform option substantially more
   expensive than it currently is.
3. **The 98 GB of converted traces are also being kept**, though every one is
   archived on kratos2 with digests verified on both sides. There is no disk
   pressure at 345 GB free, and deleting them would leave the cluster copy as
   the only copy. That trade is worth making under pressure and not before.
4. Repo mirrors (7 GB) stay: they are what makes a re-provision possible without
   GitHub, whose clone window was unreliable for most of 2026-09-03/04.

## OPEN: lombok-3479 is blocked on tooling, and it is worse than first estimated

**Revised 2026-09-04 after reading the build.** The earlier note here estimated
"a couple of hours, most of it in making ivy resolve from a warmed cache". That
was too optimistic. Three separate problems:

1. **No ant module exists.** lombok builds with Ant (`build.xml`, no `pom.xml`,
   no `build.gradle`); every module in `lang/` assumes make, cmake, maven,
   composer, bundler, cargo, go or npm.
2. **The build bootstraps a custom ant library over the network.**
   `buildScripts/setup.ant.xml` has an `-ipp.download` target that fetches
   `lib/ivyplusplus.jar` when absent, and the whole build file is declared
   `xmlns:ivy="antlib:com.zwitserloot.ivyplusplus"`. That is warmable at
   provision time, but it is a second fetch path to get right.
3. **The tests need MULTIPLE JDK RUNTIMES resolved through ivy.**
   `buildScripts/tests.ant.xml`'s `test.javac8` depends on
   `deps.jdk8-runtime`, and `buildScripts/ivy-repo/` carries custom module
   descriptors for javac6, javac7, javac11, javac13 and javac14. Making that
   resolve offline is the real cost, and it is not a couple of hours.
4. **There is no clean gate even if the build worked.** The junit target runs
   `<test name="lombok.TestJavac" />` — the whole class — and the FAIL_TO_PASS
   is a FIXTURE (`ExtensionMethodOnRecord.java`) driving it, not a test method.
   junit's `<test name=>` is class-level, so the failing case cannot be excluded
   the way every other instance's gate excludes it.
5. **The runner-up does not help**: `projectlombok-t3052` is the same repo and
   the same build system.
6. **Decision: not attempted.** Java ends at three cells. This is the only slot
   lost to TOOLING rather than to a defect in the replay, and it is recorded
   here so it is not mistaken for one.

## NEVER edit a script while a chain is executing it (2026-09-02)

1. Bash reads a running script **by byte offset**, re-reading as it goes. Change
   the file underneath it and it resumes at the wrong place.
2. This is not theoretical. `run_capture_chain.sh` changed at 11:41:59 while
   micropython-13039's chain was inside its 183-minute convert. When convert
   returned, bash resumed mid-file, printed
   `line 64: === capture chain for ... ===: command not found`, fell back into
   the phase loop and started a **second, spurious cycle** — verify, profile,
   and a trace that would have overwritten five already-validated windows at
   ~13:04. The real chain had completed correctly at 12:06.
3. The completed capture was intact and was killed only in its duplicate form;
   nothing was lost. It cost roughly 30 minutes of TCG and 811 MB of raw.
4. The scripts at risk are the LONG-LIVED ones: `run_capture_chain.sh` (hours)
   and `capture_agentic.sh` (a whole phase). Editing `provision_guest.sh` or a
   `lang/` module between runs is safe; editing them mid-provision is not.
5. **Rule: before editing either, check `ps -eo cmd | grep '[r]un_capture_chain'`.
   If any chain is live, defer the edit.** A commit is not an edit — git does not
   rewrite unmodified files — but any Write/sed/python rewrite is.
6. **PENDING FIX** (deliberately not applied yet, because three chains are
   executing the very file it changes): have `run_capture_chain.sh` and
   `capture_agentic.sh` copy themselves to a temp snapshot and re-exec from it,
   passing the script root through the environment since `$0` moves. This is the
   same principle as `create_jobfile.py --no-snapshot-exe` snapshotting the
   simulator binary so a mid-sweep rebuild cannot change what queued jobs run.
   Apply it the next time no chain is running.

## GitHub now refuses git-upload-pack entirely (2026-09-03 04:00)

1. The throttling described below has escalated from "large clones drop
   part-way" to **no clone succeeds at all**, regardless of size.
2. Measured at 04:05:
   1. `git ls-remote` (a GET of `info/refs`) still works;
   2. a **depth-1 clone of octocat/Hello-World** — a few KB — fails with
      `could not read Username` / `the remote end hung up unexpectedly`;
   3. `babel/babel` failed 13 times and `axios/axios`, a small repo, 3 times;
   4. the REST quota is 60/60 and unrelated — it is a different bucket.
3. So the refusal is on the `git-upload-pack` POST from this IP, not on repo
   size and not on quota. It appeared after roughly eight full mirror clones in
   one session.
4. **Cached mirrors are unaffected**, which is why the host-side repo cache
   matters more than it first appeared: it is now the only way to start an
   instance. Seven repos are cached (fmt, gson, core, framework, fluentd,
   preact, SWE-agent).
5. **Working policy while it lasts:** start instances whose repo is ALREADY
   cached rather than waiting. fmt-2457 was started out of trajectory-cost order
   for exactly this reason — it is the most expensive trajectory of the 36, and
   also the only remaining pick that needs no network.
6. A retry loop re-attempts babel and axios every 30 minutes for 12 hours. The
   block is time-based, so this needs patience rather than intervention.

## GitHub is throttling git from this host (2026-09-02)

1. Two distinct failures, both reported as `could not read Username for
   'https://github.com'`, which is neither an auth nor a rate-limit problem:
   1. **protocol v2 handshake fails outright** (`expected flush after ref
      listing`). `protocol.version=0` and `=1` clone the same URL in the same
      second. Pinned to v1 in `/etc/gitconfig` by `provision_guest.sh`.
   2. **larger clones drop part-way** (`the remote end hung up unexpectedly`),
      intermittently. fluentd-3328 failed once and succeeded on the very next
      attempt with no other change.
2. Evidence it is not auth or quota: curl GET of `info/refs` and POST of
   `git-upload-pack` both return HTTP 200 with a valid v2 ref listing, the API
   reports 60/60 requests remaining, there is no credential helper and no
   `GITHUB_TOKEN`, and it reproduces with the Bash sandbox disabled.
3. The clone is now retried up to 5 times with linear backoff, removing the
   partial checkout between tries (git refuses to clone into a non-empty
   directory, so a leftover turns one flake into a hard failure).
4. This had already cost jekyll-8167 its fifth and final attempt, 60 seconds in,
   before any of the real work ran.

## House rule: three strikes, and only if we understand them

Set by the PI, 2026-09-02.

0. **Hard ceiling: five attempts of ANY kind, infra included** (PI, 2026-09-02).
   Understanding a failure is what makes a retry defensible; it is not what makes
   it free. jekyll-8167 consumed four attempts, each a different bug in my own
   descriptor and each understood before the next retry — and four provisioning
   runs is about an hour of machine time. At five, take the next candidate from
   the same cell regardless of how well the cause is understood. Enforced by
   `attempts.sh check`, which now reports both ceilings.
1. **Retry a failing task at most three times** — and only while we can say
   *why* it failed. A retry justified by "let's see if it works this time" is
   not a retry, it is a coin flip with a nine-hour stake.
2. **After the second failure, the reason must be understood** before a third
   attempt. If the first two failures have different causes and both are
   diagnosed, a third try is legitimate.
3. **If it fails a third time and we understand it less than when we started,
   ditch the task.** Document what was tried in a
   `known-issue-<instance>-*.md`, following the format used for
   `known-issue-gin-2121-replay-wedge.md`: goal, key problem, what was tried and
   failed, what might fix it and at what cost.
4. **Then move to a new candidate** from the same stratification cell, or the
   same language if the cell has no alternate. The campaign has slack: only one
   representative per language is needed per phase.
5. **Infrastructure failures do not count against a task.** A bug in our
   scripts is our strike, not the instance's — this is the existing
   instance-vs-infra split in `attempts.sh`, which warns in its own header that
   "an infra classification is exactly what a motivated reasoner would reach
   for". Classify honestly or the count is worthless.

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
| 11 | **Guest images stay one-per-task; no backing-chain restructuring** | PI call 2026-09-01: the layering change is unproven here and a botched base costs more than it saves. It would also add a second guest-image generation variable alongside the one decision 6 already tracks. Measured saving was ~45 GiB against archiving's ~110 GiB, so it was never the dominant lever. Two findings kept for later: `reclaim_space.sh` would classify a shared base as scratch and delete it (its glob is `guest-*.qcow2` with a fall-through to `rm -rf`), and a guest-side cache purge would cut ~23% off every overlay for four lines of shell. |
| 13 | **Phase 2 begins per language as Phase 1 completes** | Rust first: `nushell__nushell-13831` (cell B, 75 turns) after `ripgrep-2209` finished. A different behaviour cell from the Phase-1 pick, so it adds coverage. |
| 12 | **Local gem5 checkpoints deleted; kratos2 is the archive** | 98 GB reclaimed 2026-09-01. Verified file-level (1900/1900 by path+size) before deleting. Restore instructions: `tracezoo/gem5/README.md`. |
| 10 | **Archive each task's traces to kratos2 as it validates** | Verified 2026-09-01: the path holds the 36 previous traces, byte-identical to ours, with 126 TB free. Per task, with a remote digest check before the local copy is considered reclaimable. |

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
