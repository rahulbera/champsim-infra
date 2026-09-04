# Known issue: php-cs-fixer-8064 truncates under TCG

**Status:** DITCHED 2026-09-04. Replaced by its recorded runner-up
`php-cs-fixer__php-cs-fixer-7875`.
**Instance:** `php-cs-fixer__php-cs-fixer-8064` — PHP, cell T, pick #23 of 36.

**This is the `preactjs__preact-4182` defect**, not the gin PTY wedge. See
`known-issue-preact-3763-replay-wedge.md` §6 for the mechanism; this file records
what php-cs-fixer adds.

---

## 1. The goal

1. Capture ChampSim traces of SWE-agent solving `php-cs-fixer-8064`, PHP's cell-T
   pick and the last of PHP's four cells.
2. PHP already has laravel-52684 (B), phpspreadsheet-3463 (M) and carbon-2752
   (S), all captured and archived, so this is the one cell standing between PHP
   and completion.

## 2. The key problem

**The replay completes under KVM and truncates under TCG.**

| phase | machine | result |
|---|---|---|
| verify | KVM | **PASSED in 6 minutes** |
| profile (attempt 1) | TCG | DIVERGED, 110 of 141 actions |
| profile (attempt 2) | TCG | DIVERGED, **110 of 141 actions** |

1. All 110 replayed actions were byte-identical to the recording, with zero
   cassette misses and no cancelled steps. The replay is faithful as far as it
   goes; it simply stops.
2. The exit is
   `swerex.exceptions.CommandTimeoutError: timeout after 25.0 seconds while
   running command '_state_anthropic'`, followed by
   `Exit due to multiple consecutive command timeouts` and an autosubmit.
3. **That 25 s is not ours and cannot be configured.** `swe_env.py:197` declares
   `communicate(..., timeout: int|float = 25, ...)` and `tools.py:345` calls it
   without passing one. `--agent.tools.execution_timeout=7200` governs AGENT
   commands only. Raising `max_consecutive_execution_timeouts` was tried on
   preact-4182 and does nothing, because the exit path is a bare
   `except CommandTimeoutError` at `agents.py:1168` that never consults it.

## 3. What php-cs-fixer adds over preact-4182

1. **It is deterministic here.** preact-4182 truncated at 70 then 71 of 122 --
   a wall-clock race with visible variance. php-cs-fixer truncated at 110 of 141
   BOTH times, to the action. So the same root cause presents as a race in one
   instance and as a fixed point in another, presumably depending on how close
   the offending state command sits to the 25 s line.
2. That determinism is why it was ditched after two distinct runs rather than
   three: the third would land on 110 again.
3. **The ledger reads 3/3 but only two runs happened** -- the automatic
   `chain: profile failed` entry and a manual annotation describe the same
   attempt. Recorded here so the count is not mistaken for evidence.

## 4. What could solve it, and at what cost

1. **Take the runner-up.** `php-cs-fixer-7875`, same repo and cell, so the
   mirror, module and gate shape carry over. **Chosen.** It is not a fix: if its
   trajectory has a state command near the same threshold it will do the same
   thing.
2. **Patch `tools.py:345` to pass a timeout.** One line, and it is the actual
   fix. Cost is the documented one: it changes the software under trace, and
   `capture-<id>.meta` still carries no software provenance, so a patched
   capture would be indistinguishable from an unpatched one afterwards. Close
   that gap first (gin §4.1.3).
3. **Run TCG phases with less concurrent load.** Attempt 2 ran at 1300+ guest
   ticks against ~720 for attempt 1 -- noticeably more host CPU per guest -- and
   truncated at the identical action anyway. So load is not the lever here.

## 5. Tally of this defect

| instance | KVM verify | TCG result | shape |
|---|---|---|---|
| `preactjs__preact-4182` | 122/122 | 70, then 71 of 122 | race |
| `php-cs-fixer__php-cs-fixer-8064` | passed | 110, then 110 of 141 | deterministic |

Two instances, both lost. Unlike the PTY wedge this one has a known one-line
fix, gated only on adding provenance to the capture metadata.

**Related:** `known-issue-preact-3763-replay-wedge.md`,
`known-issue-gin-2121-replay-wedge.md`, `campaign-2026-09-plan.md`.
