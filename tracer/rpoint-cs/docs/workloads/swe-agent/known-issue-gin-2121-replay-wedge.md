# Known issue: gin-gonic__gin-2121 cannot complete a replay

**Status:** OPEN. Deferred out of Phase 1 by PI decision, 2026-09-01.
**Instance:** `gin-gonic__gin-2121` — Go, stratification cell Go×T, count-view
leaf 44/55/1, tool fence 18 core-s, runner-up `gin-gonic-t4003`.

Written so this does not have to be rediscovered. Everything below was measured
on 2026-09-01 unless marked otherwise.

---

## 1. The goal

Capture ChampSim traces of SWE-agent solving `gin-gonic__gin-2121`, as the **Go**
representative in Phase 1 of the 36-task campaign. Concretely: replay the
intern's banked 39-action trajectory inside our QEMU guest, faithfully enough
that the trace is of the *recorded* execution, then profile and trace it at
K=5 × 300 M instructions.

The instance is not special or optional in itself — it is one of four Go picks —
but it is the one Phase 1 selected, and its cell has a usable runner-up, so
this is a *cost* question rather than a *coverage* question.

## 2. The key problem

**The replay wedges partway through and cannot be driven to completion.**

The mechanism is confirmed by reproduction. SWE-ReX's local deployment executes
every agent action by writing the command text into **one persistent,
interactive, readline-enabled bash on a PTY** (`swerex/runtime/local.py:158-164`
spawn, `:305` sendline) and detects completion by waiting for a sentinel prompt
(`local.py:137`, expect at `:307-311`). `PS2` is forced empty (`local.py:152`,
`:163`), so a shell that lands on a continuation prompt emits **zero bytes** —
the sentinel can never arrive, the session wedges silently, and the next command
is swallowed as continuation input.

Observed signature, identical on every attempt:

| symptom | value |
|---|---|
| guest load average | 0.00 |
| QEMU CPU accrual | ~13 ticks / 6 s (a working guest is ~650) |
| `sweagent` process state | `Sl`, sleeping, for tens of minutes |
| its `bash` child | `Ss+`, wchan `do_select`, stdin `/dev/pts/0`, **no children** |
| replay proxy misses | **0** |
| responses served vs steps recorded | N vs N−1 |

**The trigger for gin is NOT identified.** The obvious hypothesis — the model
emitted unterminated quoting — is *refuted*: SWE-agent shlex-quotes tool
arguments, SWE-ReX runs `bash -n` on every command before sending it
(`local.py:100-114`, called at `:285`), and a lexer sweep over all 2999 bash
commands in the 36 picks found **zero** statically incomplete commands.

Worse, gin's swallowed action is *benign*. It stalls after step 13, whose
command is `cat /testbed/render/reader.go` (43 bytes) — **byte-identical to
step 11, which had already succeeded in the same shell moments earlier**.
Nothing in the failing command explains the failure; the cause is state left
behind by its predecessor, step 12, a 493-byte `str_replace` carrying embedded
newlines and tabs.

Two candidate mechanisms remain, undecided:
- **readline perturbing the line.** TAB is bound to `complete`; measured,
  `a<TAB>b` arrived at the command as 2 bytes, and gin step 10's `str_replace`
  arrived with every leading Go tab stripped. Replaying step 12 through a real
  session produced `syntax error near unexpected token '('` and the tool was
  never invoked.
- **exit-code handshake desync.** `local.py:327` (`timeout=1`) and `:340`
  (`timeout=0.1`) are hardcoded and both swallowed by `except Exception` at
  `:345`, which would leave the session one prompt out of phase.

### Why this instance and not others

This is not a general blocker. Of the five Phase-1 instances, three replayed
perfectly on the first attempt and a fourth recovered by itself:

| instance | actions | verify | outcome |
|---|---|---|---|
| `burntsushi__ripgrep-2209` | 127/127 | 1 min | FAITHFUL |
| `rubocop__rubocop-13560` | 192/192 | 2 min | FAITHFUL |
| `immutable-js__immutable-js-2006` | 139/139 | 4 min | FAITHFUL |
| `redis__redis-12272` | 45/45 | **31 min** | FAITHFUL — recovered from one wedge |
| **`gin-gonic__gin-2121`** | **31/39** | — | **DIVERGED, truncated** |

`redis` matters here as the contrast: it wedges too (deterministically, at
step 11, on `tclsh8.6 -c '…'` — `-c` is not a tclsh option, so tclsh drops into
its interactive REPL reading the session PTY and never exits), but it *recovers*
and completes. gin does not.

**No static predictor separates them.** Three were built and calibrated:
a "risky shapes" scan fires on 36 of 36 instances including all three that
completed; a PS2-precondition lexer fires on 0 of 2999 commands; the only
precise predictor (commands that block reading the PTY) catches redis exactly
and is **silent on gin**. We cannot know in advance which instances wedge.

## 3. What we tried, and what happened

| # | Attempt | Result |
|---|---|---|
| 1 | verify with `EXEC_TIMEOUT=36000` (10 h) | Wedged at action 13. Sat idle 13 min before being noticed; killed. |
| 2 | verify, same settings, operator `timeout 2400` | Wedged at action 13 again. `EXIT=124` at 40 min. |
| 3 | verify with `EXEC_TIMEOUT=1800` (30 min) — **the decisive experiment** | Cleared the first wedge and reached **31 of 39** actions, all 31 matching identically, patch 447 B. Hit further wedges and stopped short. **VERDICT: DIVERGED — truncated.** |

Attempt 3 is the important one and it half-worked: the finite timeout genuinely
rescues the session (13 → 31 actions), it just cannot rescue it enough. **More
time does not help — it produces more wedges.**

Separately, four *infrastructure* bugs were hit and fixed while getting gin this
far. They are unrelated to the wedge but are in gin's ledger and should not be
re-diagnosed: the Go offline gate rejecting a committed `vendor/vendor.json`;
`/opt/versions.txt` written with a plain redirect into a root-owned directory;
a venv idempotency guard that tested path existence rather than health; and
`REPO_NAME` passed as SWE-agent's `--env.repo.repo_name`, which SWE-agent treats
as the repo *directory*.

### Ruled out, with reasons

- **Upgrading SWE-agent or SWE-ReX buys nothing.** Our pin `3ea751c` *is*
  SWE-agent main HEAD (ahead 0, behind 0); `swe-rex` 1.4.0 is the newest
  release; the 21 commits on swe-rex main change `local.py` by +10/−8 and
  **none touch the PTY session path**. The one hang fix (`c0a1b43fb`) adds
  `stdin=DEVNULL` to the *non-PTY* endpoint. Upstream has merged nothing to
  SWE-agent main since 2026-07-16, and a hang PR in this very code path (#270)
  has been open since 2025-10-10.
- **Docker deployment does not fix it and breaks the measurement.** It runs the
  identical `LocalRuntime` PTY session (`server.py:32`), and it removes the
  container's processes from `sweagent`'s process tree — which is the only
  reason our `taskset` CPU pin holds. Every trace cut that way would be
  incomparable with the instances already captured.
- **Lowering `EXEC_TIMEOUT` toward the recording's 30 s** reintroduces the exact
  truncation that destroyed an August redis capture: a complete, zero-miss trace
  of a half-finished run (`replay_pinned.sh:24-47`).
- **A grep-based pre-flight screen** produces 55 false alarms across 10
  instances (53 apostrophes inside quoted heredoc bodies, 2 inside `#`
  comments); the honest version finds zero. It would create false confidence
  about the 31 untried picks.

## 4. What could solve it, and at what cost

Ordered by cost. None has been attempted.

### A. Patch SWE-ReX in the guest — most likely to work

Three candidate changes, in descending confidence:

1. Wrap each command as `{ cmd ; } < /dev/null` so a tool that reads stdin
   cannot consume the session PTY. **Kills the redis class with certainty**;
   unproven against gin.
2. Disable readline in the session shell (`bash --noediting`, or unbind TAB), so
   completion cannot eat or transform the line. Directly targets the measured
   tab-stripping.
3. Raise `BashInterruptAction.timeout` from 0.2 s and loosen the hardcoded
   1 s / 0.1 s exit-code expects, so the handshake does not desync.

**Cost:** ~1 hour of work; staging is free, since `capture_agentic.sh:198-208`
rsyncs `scripts/swe-agent/` into every guest before every phase. One verify per
instance to re-validate (1–4 min each on KVM).

**Risk, and it is the real cost:** this changes the **software under trace**.
SWE-agent's own library code executes inside the ROI, so a patched SWE-ReX is a
different workload. Applying it to gin alone creates a two-generation campaign;
applying it to all 36 means re-running the three instances already verified
clean. There is also no provenance channel for it today — `versions.txt` is
written at provision time only, and `capture-<id>.meta` carries no software
fields — so a patched capture would be indistinguishable from an unpatched one
after the fact. **That gap should be closed before any patch is applied.**

### B. Swap for the runner-up, `gin-gonic-t4003`

**Cost:** the highest of any option — new descriptor, cassettes, guest image,
full provisioning, and a ~9 h chain, plus a documented stratification revision.

**Risk:** measurably *worse* exposure. The alternate carries strictly more of
every risk marker than gin-2121 (more bash actions, more with embedded
newlines, more that force SWE-ReX's own "somewhat brittle" fallback path). We
would spend nine hours to land on a likelier failure.

Go coverage does not depend on it: the campaign has three other Go picks
(`caddy-4774`, `prometheus-10720`, `hugo-12579`), and Phase 1 needs only one
representative per language.

### C. Accept 4 of 5 and report it

**Cost:** zero. Phase 1 loses its Go representative; Phase 2 can carry Go with
one of the other three picks.

**Risk:** none to correctness. The gate did its job — it refused a truncated
replay rather than producing a trace of a half-finished run, which is precisely
the failure that cost the August campaign a capture.

**This is what was chosen on 2026-09-01.**

## 5. If we resume

Cheapest first experiment, before any patching: **run gin's verify with
`bash --noediting`** in the session shell. It is a one-line change to the
harness, it directly targets the only mechanism with positive evidence (the
measured tab-stripping), and it costs one KVM verify — a few minutes. If the
replay reaches 39/39, the cause is readline and patch A#2 is the fix.

If that fails, apply A#1 (`< /dev/null`) and re-run: it is certain to fix the
redis class and may fix gin if a tool is consuming the PTY.

Before applying either as campaign policy, add software provenance to
`capture-<id>.meta` so a patched capture is distinguishable from an unpatched
one. Without that, the two generations become unresolvable after the fact — the
same class of problem as the unpinned venv that motivated recording
`pip freeze` in the first place.

**Related:** `docs/workloads/swe-agent/campaign-2026-09-plan.md` (decisions and
status), and the full root-cause brief in the session scratchpad
(`swerex-stall-brief.md`).
