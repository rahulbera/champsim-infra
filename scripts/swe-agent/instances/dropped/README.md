# Dropped instances

Kept for the record, not run. `capture_status.sh` reads `instances/*.env`, so
nothing in here appears as work in flight.

## google__gson-2311 (Java / Maven) — dropped 2026-08-07

**What happened.** The replay diverged at step 13 of 89 with **zero cassette
misses**: 76 of 89 actions differed and the replay ran 90 steps against the
record's 89. A sequence desync -- the replay consumed one more response than the
record, so every exchange after step 12 was served the wrong one. The trajectory
gate caught it; without that comparison it would have yielded a clean,
fully-validated trace of an execution that never happened.

**Why Java is a poor fit for this methodology, beyond this instance.** The whole
pipeline rests on "the same inputs produce the same execution". The JVM weakens
that at two levels: HotSpot compiles methods on invocation counters, so *when*
code is JIT'd depends on timing; and GC timing depends on allocation history and
heap state rather than on the input alone. Maven compounds it with heavier and
more environment-dependent control flow than a compiler invocation.

**What is NOT claimed.** The observed cause was an extra API call, not a GC
event. Go and V8 both have garbage collectors and replayed bit-identically here
(147/147 and 45/45 actions), because each tool invocation is a short-lived
process. The argument is therefore not "GC implies nondeterminism" -- it is that
the JVM plus Maven offers more ways for the environment to alter control flow,
and this study should not spend API credits on a language that fights its own
foundation.

**A general limitation this exposed.** Sequence replay assumes the agent makes
the SAME NUMBER of API calls both times. Any environment-driven extra call --
a retry, an error path, a differently-shaped tool result -- shifts every
exchange after it, with no miss to signal it. `compare_trajectories.py` is what
makes that visible.

**Replaced by:** a non-agentic Ruby control, which costs no credits and targets
the mechanism the SPEC baseline actually pointed at (SPEC's own
`714.cpython_r.sp0` is 99.8% indirect -- an interpreter dispatch loop).
