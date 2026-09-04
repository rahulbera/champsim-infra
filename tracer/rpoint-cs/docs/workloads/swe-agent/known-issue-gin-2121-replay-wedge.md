# Known issue: gin-gonic__gin-2121 cannot complete a replay

**Status:** OPEN. Deferred out of Phase 1 by PI decision, 2026-09-01.
**Instance:** `gin-gonic__gin-2121` — Go, stratification cell Go×T, count-view
leaf 44/55/1, tool fence 18 core-s, runner-up `gin-gonic-t4003`.

Written so this does not have to be rediscovered. Everything below was measured
on 2026-09-01 unless marked otherwise.

---

## 1. The goal

1. Capture ChampSim traces of SWE-agent solving `gin-gonic__gin-2121`, as the
   **Go** representative in Phase 1 of the 36-task campaign.
2. Concretely: replay the intern's banked 39-action trajectory inside our QEMU
   guest, faithfully enough that the trace is of the *recorded* execution.
3. Then profile and trace it at K=5 × 300 M instructions.
4. The instance is not special in itself — it is one of four Go picks — but it
   is the one Phase 1 selected, and its cell has a usable runner-up. So this is
   a **cost** question, not a **coverage** question.

## 2. The key problem

**The replay wedges partway through and cannot be driven to completion.**

### 2.1 The mechanism — confirmed by reproduction

1. SWE-ReX's local deployment executes every agent action by writing the command
   text into **one persistent, interactive, readline-enabled bash on a PTY**
   (`swerex/runtime/local.py:158-164` spawn, `:305` sendline).
2. It detects completion by waiting for a sentinel prompt string
   (`local.py:137`, expect at `:307-311`).
3. `PS2` is forced empty (`local.py:152`, `:163`). So a shell that lands on a
   continuation prompt emits **zero bytes**.
4. The sentinel therefore can never arrive: the session wedges silently, and the
   next command is swallowed as continuation input.

### 2.2 The signature — identical on every attempt

| symptom | value |
|---|---|
| guest load average | 0.00 |
| QEMU CPU accrual | ~13 ticks / 6 s (a working guest is ~650) |
| `sweagent` process state | `Sl`, sleeping, for tens of minutes |
| its `bash` child | `Ss+`, wchan `do_select`, stdin `/dev/pts/0`, **no children** |
| replay proxy misses | **0** |
| responses served vs steps recorded | N vs N−1 |

### 2.3 The trigger is NOT identified

1. The obvious hypothesis — the model emitted unterminated quoting — is
   **refuted**:
   - SWE-agent shlex-quotes tool arguments.
   - SWE-ReX runs `bash -n` on every command *before* sending it
     (`local.py:100-114`, called at `:285`).
   - A lexer sweep over all 2999 bash commands in the 36 picks found **zero**
     statically incomplete commands.
2. gin's swallowed action is **benign**. It stalls after step 13, whose command
   is `cat /testbed/render/reader.go` (43 bytes) — **byte-identical to step 11,
   which had already succeeded in the same shell moments earlier**.
3. So nothing in the failing command explains the failure. The cause is state
   left behind by its predecessor: step 12, a 493-byte `str_replace` carrying
   embedded newlines and tabs.
4. Two candidate mechanisms remain, undecided:
   1. **readline perturbing the line.** TAB is bound to `complete`. Measured:
      `a<TAB>b` arrived at the command as 2 bytes, and gin step 10's
      `str_replace` arrived with every leading Go tab stripped. Replaying step 12
      through a real session produced `syntax error near unexpected token '('`
      and the tool was never invoked.
   2. **exit-code handshake desync.** `local.py:327` (`timeout=1`) and `:340`
      (`timeout=0.1`) are hardcoded and both swallowed by `except Exception` at
      `:345`, which would leave the session one prompt out of phase.

### 2.4 Why this instance and not the others

1. This is not a general blocker. Of five Phase-1 instances, three replayed
   perfectly first time and a fourth recovered by itself:

   | instance | actions | verify | outcome |
   |---|---|---|---|
   | `burntsushi__ripgrep-2209` | 127/127 | 1 min | FAITHFUL |
   | `rubocop__rubocop-13560` | 192/192 | 2 min | FAITHFUL |
   | `immutable-js__immutable-js-2006` | 139/139 | 4 min | FAITHFUL |
   | `redis__redis-12272` | 45/45 | **31 min** | FAITHFUL — recovered from one wedge |
   | **`gin-gonic__gin-2121`** | **31/39** | — | **DIVERGED, truncated** |

2. `redis` is the instructive contrast. It wedges too, deterministically, at
   step 11 on `tclsh8.6 -c '…'` — `-c` is not a tclsh option, so tclsh drops
   into its interactive REPL reading the session PTY and never exits. But it
   **recovers and completes**. gin does not.
3. **No static predictor separates them.** Three were built and calibrated:
   1. a "risky shapes" scan → fires on **36 of 36** instances, including all
      three that completed;
   2. a PS2-precondition lexer → fires on **0 of 2999** commands;
   3. "commands that block reading the PTY" → catches redis exactly, and is
      **silent on gin**.
4. Conclusion: we cannot know in advance which instances wedge. The strategy is
   detect-and-retry, not screen-and-avoid.

## 3. What we tried, and what happened

### 3.1 The three attempts

| # | Attempt | Result |
|---|---|---|
| 1 | verify, `EXEC_TIMEOUT=36000` (10 h) | Wedged at action 13. Idle 13 min before being noticed; killed. |
| 2 | verify, same settings, operator `timeout 2400` | Wedged at action 13 again. `EXIT=124` at 40 min. |
| 3 | verify, `EXEC_TIMEOUT=1800` (30 min) — **the decisive experiment** | Cleared the first wedge, reached **31 of 39** actions, all 31 matching, patch 447 B. Hit further wedges and stopped short. **VERDICT: DIVERGED — truncated.** |

1. Attempt 3 half-worked: the finite timeout genuinely rescues the session
   (13 → 31 actions).
2. But it cannot rescue it enough. **More time does not help — it produces more
   wedges.**
3. The gate refused the result correctly. A truncated replay with zero misses is
   exactly the failure that cost the August campaign a redis capture.

### 3.2 Unrelated infrastructure bugs hit along the way

Fixed, in gin's ledger, and **not** to be re-diagnosed:

1. The Go offline gate rejected a *committed* `vendor/vendor.json` (it tested
   for the `vendor/` directory rather than `vendor/modules.txt`).
2. `/opt/versions.txt` was written with a plain redirect into a root-owned
   directory, by a script running as `ubuntu`.
3. The venv idempotency guard tested path existence rather than health, so a
   0-byte `sweagent` entry point survived a re-run.
4. `REPO_NAME` was passed as SWE-agent's `--env.repo.repo_name`, which SWE-agent
   treats as the repo *directory* — sending it to `/gin` while the checkout was
   at `/testbed`.

### 3.3 Ruled out, with reasons

1. **Upgrading SWE-agent or SWE-ReX buys nothing.**
   - Our pin `3ea751c` *is* SWE-agent main HEAD (ahead 0, behind 0).
   - `swe-rex` 1.4.0 is the newest release.
   - The 21 commits on swe-rex main change `local.py` by +10/−8 and **none touch
     the PTY session path**; the one hang fix (`c0a1b43fb`) adds
     `stdin=DEVNULL` to the *non-PTY* endpoint.
   - Upstream has merged nothing to SWE-agent main since 2026-07-16, and a hang
     PR in this very code path (#270) has been open since 2025-10-10.
2. **Docker deployment does not fix it and breaks the measurement.**
   - It runs the identical `LocalRuntime` PTY session (`server.py:32`).
   - It removes the container's processes from `sweagent`'s process tree, which
     is the only reason our `taskset` CPU pin holds.
   - Every trace cut that way would be incomparable with the instances already
     captured.
3. **Lowering `EXEC_TIMEOUT` toward the recording's 30 s** reintroduces the
   exact truncation that destroyed an August redis capture: a complete,
   zero-miss trace of a half-finished run (`replay_pinned.sh:24-47`).
4. **A grep-based pre-flight screen** produces 55 false alarms across 10
   instances (53 apostrophes inside quoted heredoc bodies, 2 inside `#`
   comments); the honest version finds zero. It would create false confidence
   about the 31 untried picks.

## 4. What could solve it, and at what cost

Ordered by cost. **None has been attempted.**

### 4.1 Option A — patch SWE-ReX in the guest (most likely to work)

1. Candidate changes, in descending confidence:
   1. Wrap each command as `{ cmd ; } < /dev/null`, so a tool that reads stdin
      cannot consume the session PTY. **Kills the redis class with certainty**;
      unproven against gin.
   2. Disable readline in the session shell (`bash --noediting`, or unbind TAB),
      so completion cannot eat or transform the line. Directly targets the
      measured tab-stripping.
   3. Raise `BashInterruptAction.timeout` from 0.2 s and loosen the hardcoded
      1 s / 0.1 s exit-code expects, so the handshake cannot desync.
2. **Cost:** ~1 hour of work. Staging is free — `capture_agentic.sh:198-208`
   rsyncs `scripts/swe-agent/` into every guest before every phase. One verify
   per instance to re-validate (1–4 min each on KVM).
3. **Risk, and it is the real cost:** this changes the **software under trace**.
   SWE-agent's own library code executes inside the ROI, so a patched SWE-ReX is
   a different workload.
   1. Applying it to gin alone creates a two-generation campaign.
   2. Applying it to all 36 means re-running the three instances already
      verified clean.
   3. There is **no provenance channel** for it today: `versions.txt` is written
      at provision time only, and `capture-<id>.meta` carries no software
      fields. A patched capture would be indistinguishable from an unpatched one
      after the fact. **Close that gap before applying any patch.**

### 4.2 Option B — swap for the runner-up, `gin-gonic-t4003`

1. **Cost:** the highest of any option — new descriptor, cassettes, guest image,
   full provisioning, a ~9 h chain, plus a documented stratification revision.
2. **Risk:** measurably *worse* exposure. The alternate carries strictly more of
   every risk marker than gin-2121 (more bash actions, more with embedded
   newlines, more that force SWE-ReX's own "somewhat brittle" fallback path).
   We would spend nine hours to land on a likelier failure.
3. Go coverage does not depend on it: the campaign has three other Go picks
   (`caddy-4774`, `prometheus-10720`, `hugo-12579`), and Phase 1 needs only one
   representative per language.

### 4.3 Option C — accept 4 of 5 and report it

1. **Cost:** zero. Phase 1 loses its Go representative; Phase 2 carries Go with
   one of the other three picks.
2. **Risk:** none to correctness. The gate did its job — it refused a truncated
   replay rather than producing a trace of a half-finished run.
3. **This is what was chosen on 2026-09-01.**

## 5a. RESOLVED 2026-09-04: readline was the cause

**The experiment in §5.1 was run and it worked.**

1. Vehicle: `preactjs__preact-3763`, chosen because it wedges in 1-3 minutes.
2. Change: SWE-ReX's session shell spawned as `bash --noediting`
   (`swerex/runtime/local.py:158`, opt-in via `SWEREX_PATCH=noediting`).
3. Result, through the WHOLE chain rather than just verify:

   | phase | machine | before (x3 runs) | with `--noediting` |
   |---|---|---|---|
   | verify | KVM | 27 of 55, wedged | **55 of 55 FAITHFUL**, 1 min |
   | profile | TCG | never reached | **OK**, 56 min |
   | trace | TCG | never reached | **55 of 55 FAITHFUL**, 58 min |
   | convert | host | never reached | 4 of 5 windows, `actual_windows=4` |

   So the fix holds under TCG as well as KVM, and an instance that had been
   DITCHED as unreplayable produced a complete capture. That is a stronger
   result than "the wedge went away in a short KVM run".

4. So the mechanism is §2.4.1 -- **readline perturbing the line** -- not the
   exit-code handshake desync of §2.4.2. The measured tab-stripping was the real
   signal after all.
5. This does NOT explain the OTHER defect. preact-4182 and php-cs-fixer-8064
   died on the 25-second `_state_anthropic` timeout, which is a wall clock and
   has nothing to do with readline. `--noediting` will not help those.
6. **What it could recover:** the three cells lost to the wedge -- Go x T
   (gin-2121), JavaScript x M (preact-3763) and JavaScript x T
   (three.js-26589/27395).
7. **What it costs, and this is a PI decision, not an engineering one:** a
   patched capture is a DIFFERENT SOFTWARE GENERATION from the 31 already
   archived. Filling those three cells patched creates a two-generation dataset;
   making it uniform means re-running 31 captures at roughly four hours each.
   The captures are now self-describing either way -- `swerex_patch` and
   `swerex_sha256` are recorded in `capture-<id>.meta` -- so the two generations
   are distinguishable after the fact, which they would not have been before
   2026-09-04.

## 5b. It GENERALISES: gin clears too (2026-09-04)

One instance recovering is a mechanism; two in different languages is a fix.
gin-2121 -- this document's own instance, the original reproducer -- was re-run
with `--noediting`:

    replay misses    : 0
    fed actions      : 39      submits at [28, 30, 31, 36, 38]
    replayed actions : 31, ending ON the submit at index 30
    identical actions: 31 / 31, no cancelled steps
    replay patch     : 1750 bytes
    VERDICT          : FAITHFUL

**Read the action count carefully, because it is a trap.** §3.1 attempt 3 also
reached "31 of 39". That run was TRUNCATED -- it stopped mid-trajectory without
reaching a submit and produced a 447-byte patch. This run reaches the same index
and ENDS ON A SUBMIT with a 1750-byte patch, nearly four times larger. Same
number, opposite meaning: one is a replay that died, the other is a replay that
finished. The remaining 8 recorded actions are the original agent continuing
past its own submit, which the foreign-replay gate treats as complete.

So the wedge is fixed in both instances tested, across two languages, one of
which never recovered in three prior attempts.

**Recoverable cells:** Go×T (this instance), JavaScript×M (preact-3763, already
captured under the patch) and JavaScript×T (three.js-26589/27395, untested but
the same defect).

**Not recoverable by this patch:** preact-4182 and php-cs-fixer-8064, which died
on the 25-second `_state_anthropic` timeout. That is a wall clock and has
nothing to do with readline; see §6 of the preact write-up.

## 5. If we resume

1. **Cheapest first experiment, before any patching:** run gin's verify with
   `bash --noediting` in the session shell.
   - One line of harness change, one KVM verify, a few minutes.
   - It targets the only mechanism with positive evidence (the measured
     readline tab-stripping on gin's own step 10).
   - If the replay reaches 39/39, the cause is readline and option A.1.2 is the
     fix.
2. **If that fails,** apply A.1.1 (`< /dev/null`) and re-run. It is certain to
   fix the redis class and may fix gin if a tool is consuming the PTY.
3. **Before adopting either as campaign policy,** add software provenance to
   `capture-<id>.meta` so a patched capture is distinguishable from an unpatched
   one. Without it the two generations become unresolvable after the fact — the
   same class of problem as the unpinned venv that motivated recording
   `pip freeze` in the first place.

**Related:** `docs/workloads/swe-agent/campaign-2026-09-plan.md` (decisions and
status); full root-cause brief in the session scratchpad
(`swerex-stall-brief.md`).
