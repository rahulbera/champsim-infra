# Archived ledger — August 2026 campaign

The attempt log for the 6-instance campaign that produced the original 24
with-agent traces. Archived on 2026-09-01 when the 36-task campaign began.

**Read these as incomplete.** The audit that opened the new campaign found:

- **`google__gson-2311` has no entry at all**, despite a 57-minute record pass
  and a full verify that diverged at step 13 of 89. The most instructive
  failure of the campaign is the one the ledger does not mention.
- **Timestamps cluster at hourly report times**, i.e. rows were written
  retrospectively rather than at the moment of failure.
- **`jqlang__jq-2839`'s watchdog fired at step 52 on 2026-08-07** while the
  ledger books that event as `infra`. If they are the same event, jq's real
  count is 2 instance strikes, not 1.
- 11 of 14 rows are classified `infra`. `attempts.sh` warns in its own header
  that "an infra classification is exactly what a motivated reasoner would
  reach for" to buy a fourth try. Treat the ratio with suspicion.

Nothing ever called `attempts.sh` — every row here was written by hand.
