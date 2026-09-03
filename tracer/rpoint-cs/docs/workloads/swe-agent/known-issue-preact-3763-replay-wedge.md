# Known issue: preactjs__preact-3763 cannot complete a replay

**Status:** DITCHED at 3/3 attempts, 2026-09-02. Replaced by its recorded
runner-up `preactjs__preact-4182` (same cell).
**Instance:** `preactjs__preact-3763` — JavaScript, mechanism N, cell
JavaScript×M (n=2, median fence 60), runner-up `preactjs-t4182`.

> **CORRECTION, 2026-09-03.** This file first attributed the failure to gin's
> SWE-ReX PTY wedge. That was reasoning from a shared symptom — a pexpect
> timeout waiting for `SHELLPS1PREFIX` — and it was wrong about the mechanism.
> The full logs from `preactjs__preact-4182` identify the actual defect, which is
> in SWE-agent, not SWE-ReX, and is described in §6. The pexpect traceback is how
> the state command's timeout *surfaces*, not why the episode ends.

**Related to `gin-gonic__gin-2121`** — see
`known-issue-gin-2121-replay-wedge.md`. Read that first; this file records only
what preact ADDS, which is a great deal, because preact is a far better
reproducer than gin ever was.

---

## 1. The goal

1. Capture ChampSim traces of SWE-agent solving `preactjs__preact-3763`, as
   JavaScript's Phase 2 pick (cell M, a different behaviour cell from
   Phase 1's).
2. Concretely: replay the intern's banked 55-action trajectory inside our QEMU
   guest faithfully enough that the trace is of the *recorded* execution.
3. The instance is not special. Its cell has a usable runner-up in the same
   repo, so this is a cost question, not a coverage one.

## 2. The key problem

**The replay wedges at action 28 of 55 and cannot be driven past it.**

### 2.1 It is the gin wedge, now confirmed twice

1. Same mechanism, now with a full traceback rather than an inference:

   ```
   pexpect.exceptions.TIMEOUT: Timeout exceeded.
   searcher: searcher_re: 0: re.compile('SHELLPS1PREFIX')
   buffer (last 100 chars): 'el.config.js  jsx-runtime/  test-utils/\r\n
                             benches/  karma.conf.js  \r\n'
   ```

2. SWE-ReX waits for its sentinel prompt on the persistent PTY session and it
   never arrives. The buffer still holds the tail of an EARLIER `ls` — the
   session is out of phase, exactly the state gin's write-up predicted but
   could not show.
3. The failure then escalates through SWE-agent's state command, not through an
   agent action: `CommandTimeoutError: timeout after 25.0 seconds while running
   command '_state_anthropic'`, three times consecutively, then
   `Exit due to multiple consecutive command timeouts` and an autosubmit.

### 2.2 The signature

| symptom | value |
|---|---|
| fed actions | 55 |
| replayed actions | **27, on all three attempts** |
| identical actions | 27 / 27 |
| cassette misses | **0** |
| cancelled steps | none — a clean replay, just a short one |
| replay patch | 1248 bytes, sha 9e41d0c95d017b95 |
| verdict | DIVERGED — truncated |

Deterministic to the action. This is not host load, and not a flake.

### 2.3 What preact adds over gin

1. **The wedge is not unique to gin.** One instance was a curiosity; two
   confirm a defect in SWE-ReX's session handling that any instance can hit.
2. **The stale-buffer evidence is direct.** gin's mechanism was reconstructed
   from `do_select` and an empty PS2; here the pexpect buffer literally shows
   the previous command's output still unconsumed.
3. **The action that wedges is benign again, and differently so.** gin stalled
   on a `cat` byte-identical to one that had already succeeded. preact stalls on
   `cd /testbed && sed -n '112,118p' src/diff/index.js | cat -A`. Nothing in
   either command explains the failure; in both cases the damage was done by a
   PREDECESSOR that left the session out of phase.
4. **preact is much cheaper to reproduce.** Its verify is a 1-3 minute KVM run,
   where gin's took 13-40 minutes to wedge. If the fix in gin's §5 is ever
   attempted, THIS is the instance to attempt it on.

### 2.4 Why the state command is the thing that dies

1. `sweagent/tools/tools.py:345` runs `env.communicate(state_command,
   check="warn")` with **no timeout argument**, so it inherits the environment's
   default of 25 s. Our `--agent.tools.execution_timeout=1800` does not apply to
   it: that setting governs agent commands only.
2. `ToolConfig.max_consecutive_execution_timeouts` defaults to 3, so three
   state-command timeouts end the episode.
3. So the 30-minute per-command timeout we tuned for redis is irrelevant here.
   The episode dies on a 25-second limit we never chose and cannot reach from
   the CLI.

## 3. What we tried, and what happened

| # | Attempt | Result |
|---|---|---|
| 1 | verify, default settings | DIVERGED, 27/55. Full log discarded with the guest. |
| 2 | verify, after adding host-side log capture | DIVERGED, 27/55. **Log still not captured** — `set -euo pipefail` plus an EXIT trap tore the guest down at the failing pipeline, before the fetch. |
| 3 | verify, after scoping errexit around that pipeline | DIVERGED, 27/55, **log captured (279 KB)** — which is what identified the wedge. |

1. Attempts 1 and 2 produced no new information; attempt 3 produced all of it.
2. The two infrastructure bugs found on the way (log not kept; log-keeping
   defeated by errexit ordering) are fixed and are not preact-specific.

## 4. What could solve it, and at what cost

Ordered by cost. **None has been attempted.** All are shared with gin.

### 4.1 Option A — raise `max_consecutive_execution_timeouts`

1. Pure CLI config, no code change: `--agent.tools.max_consecutive_execution_timeouts=N`.
2. **Cost:** minutes.
3. **Risk:** it does not fix the wedge, it only refuses to give up on it. If the
   session is genuinely out of phase, further commands are swallowed and the
   replay diverges anyway — with a *longer* trace of a wrong execution, which is
   worse than a clean refusal.

### 4.2 Option B — the fixes in gin's §5 (`bash --noediting`, `< /dev/null`)

1. Now testable in 1-3 minutes per iteration instead of 13-40.
2. **Cost:** ~1 hour, plus one verify per already-captured instance to
   re-validate.
3. **Risk:** unchanged from gin's write-up and it is the real cost — it changes
   the software under trace, and there is still **no provenance channel** for
   it in `capture-<id>.meta`. Close that gap first.

### 4.3 Option C — take the runner-up

1. **Cost:** one full chain, ~2-9 h. The mirror, language module and gate
   pattern are all already in place because it is the same repo.
2. **Risk:** low, and unlike gin's alternate there is no evidence the runner-up
   is riskier than the original.
3. **This is what was chosen on 2026-09-02.** `preactjs__preact-4182`, same
   cell M, 125 KB trajectory.

## 5. If we resume

1. Use **preact-3763, not gin-2121**, as the reproducer. Same defect, ~10x
   faster iteration, and a clean deterministic stopping point at action 28.
2. The first experiment is still gin's: `bash --noediting` in the session shell.
3. Before adopting any patch as campaign policy, add software provenance to
   `capture-<id>.meta` so a patched capture is distinguishable from an
   unpatched one.

**Related:** `known-issue-gin-2121-replay-wedge.md`,
`campaign-2026-09-plan.md`.


## 6. The actual root cause (2026-09-03)

Established from `images/replay_full-preactjs__preact-4182.log`, once the host
started keeping that log at all.

1. **Both instances die on SWE-agent's STATE command, not on an agent action:**

   ```
   swerex.exceptions.CommandTimeoutError: timeout after 25.0 seconds
     while running command '_state_anthropic'
   ```

2. **The 25 s is a Python function-signature default and is unreachable from
   configuration.** `sweagent/environment/swe_env.py:197` declares
   `def communicate(self, input, timeout: int|float = 25, ...)`, and
   `sweagent/tools/tools.py:345` calls it as
   `env.communicate(state_command, check="warn")` — passing no timeout. There is
   no config field, no environment variable and no CLI flag for it.
   `--agent.tools.execution_timeout=1800` governs AGENT commands only.

3. **`max_consecutive_execution_timeouts` does not apply, and the log message
   says otherwise.** There are two exit paths in `agents.py`:
   - line 969: increments `_n_consecutive_timeouts`, compares it against
     `max_consecutive_execution_timeouts`, and logs *"Exiting agent due to too
     many consecutive execution timeouts"*;
   - line 1168: a bare `except CommandTimeoutError:` that exits on the FIRST
     such exception to reach it, and logs *"Exiting due to multiple consecutive
     command timeouts"*.

   Our logs show the SECOND message. Raising the limit to 100 was tried on
   preact-4182 and changed nothing — 71 of 122 actions both before and after —
   because that path never consults it. **The message names a counter it does
   not use.**

4. **The two instances hit it for different reasons, and the distinction
   matters:**

   | instance | phase that fails | KVM result | reading |
   |---|---|---|---|
   | preact-3763 | verify (KVM) | 27/55 | the session really is stuck; 25 s is ample on KVM for a trivial state command |
   | preact-4182 | profile (TCG) | **122/122 FAITHFUL** | not stuck — TCG is ~50x slower and the state command simply exceeds 25 s |

   preact-4182 replaying perfectly under KVM and truncating only under TCG is
   what separates the two. 3763 is a wedge; 4182 is a wall clock.

5. **Consequence for the campaign.** Any instance whose state command takes more
   than ~0.5 s of KVM time will fail under TCG, silently, as a truncated replay
   the gate then refuses. Sixteen captures have passed, so it is not common —
   but it is not preact-specific either, and it cannot be tuned around.

6. **The only fixes left are code changes in the guest**, i.e. patching
   SWE-agent to pass a timeout at tools.py:345. That changes the software under
   trace, and the provenance gap in gin's §4.1.3 still applies: close it before
   applying any patch.
