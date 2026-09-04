# Known issue: mrdoob__three.js-26589 cannot complete a replay

**Status:** DITCHED at 2 of 3 attempts, 2026-09-04. Replaced by its recorded
runner-up `mrdoob__three.js-27395`.
**Instance:** `mrdoob__three.js-26589` — JavaScript, cell T.

**This is the gin-2121 SWE-ReX PTY wedge, third confirmed instance.** Read
`known-issue-gin-2121-replay-wedge.md` first. This file records only what
three.js adds.

---

## 1. The goal

1. Capture ChampSim traces of SWE-agent solving `three.js-26589`, JavaScript's
   fourth and last pick.
2. Replay the banked 129-action trajectory faithfully enough that the trace is
   of the *recorded* execution.
3. JavaScript already has two captures (babel-15649, axios-5892), so this is a
   coverage question for the cell, not for the language.

## 2. The key problem

**The replay wedges during verify and never resumes.**

| symptom | measured |
|---|---|
| time in verify | 56 and 58 min (verify is normally 1-6 min) |
| guest CPU | 56 and 14 ticks / 20 s (a working replay is 600-2000) |
| guest load average | 0.00 |
| `sweagent` state | `Sl`, sleeping |
| its bash child | `Ss+` on the PTY |
| replayed actions | wedged mid-trajectory, never reaches the gate |

That is the signature table in gin's write-up, line for line.

### 2.1 What three.js adds: the Bashlex errors are NOT the cause

1. The log carries **24** occurrences of
   `🦖 ERROR Bashlex fail: here-document at line 0 delimited by end-of-file
   (wanted "'PYEOF'")`, from the agent's multi-line python heredocs.
2. **The replay recovered from all 24 and kept going.** They are loud, they look
   causal, and they are not. Anyone debugging this will find them first and
   should not stop there.
3. The wedge happens *after* one of them, on the action that follows -- which is
   consistent with gin's conclusion that the damage is done by a PREDECESSOR
   leaving the session out of phase, not by the command that stalls.

### 2.2 It is DETERMINISTIC here

1. Both attempts wedged at the **same action**, with the **same 24** Bashlex
   errors preceding it, and the same 0.00 load.
2. This differs from `redis-12272`, which wedged and recovered, and matches
   `gin-2121`, which never did.
3. That determinism is why this was ditched at 2 attempts rather than 3: a third
   run reproduces a known result and costs a TCG slot for two hours.

## 3. What we tried

| # | Attempt | Result |
|---|---|---|
| 1 | verify, default settings | Wedged after 56 min. Killed; in-guest log (12,582 lines) pulled to the host first. |
| 2 | verify, unchanged | Wedged identically after 58 min. |

No configuration was changed between them, deliberately: the point of attempt 2
was to establish whether the wedge is deterministic, and it is.

## 4. What could solve it, and at what cost

Unchanged from gin's section 4 -- the options are the same because the defect is
the same. In cost order:

1. **Take the runner-up.** `mrdoob__three.js-27395`, same cell, same repo, so
   the mirror, module and gate shape all carry over. **This is what was chosen.**
2. **`bash --noediting` in the session shell**, gin's cheapest untried
   experiment. three.js is a *worse* reproducer than preact-3763 for this: its
   wedge takes ~56 minutes to manifest where preact's takes 1-3.
3. **Patch SWE-ReX.** Changes the software under trace; the provenance gap in
   gin's §4.1.3 must be closed first.

## 5. Tally of this defect

| instance | phase | machine | deterministic? |
|---|---|---|---|
| `gin-gonic__gin-2121` | verify | KVM | yes |
| `preactjs__preact-3763` | verify | KVM | yes |
| `redis__redis-12272` | verify | KVM | no -- recovered |
| `mrdoob__three.js-26589` | verify | KVM | yes |

Four of the campaign's instances have hit it; three were unrecoverable. It is
not rare, and it is not correlated with language: Go, JavaScript twice, and C.

**Related:** `known-issue-gin-2121-replay-wedge.md`,
`known-issue-preact-3763-replay-wedge.md`, `campaign-2026-09-plan.md`.
