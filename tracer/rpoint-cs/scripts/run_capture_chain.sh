#!/usr/bin/env bash
#
# run_capture_chain.sh <instance_id> [first_phase] — unattended capture.
#
# Chains verify -> profile -> trace -> convert, stopping at the FIRST failure
# rather than carrying a bad artifact forward. Every phase already has its own
# gates; this only sequences them and keeps one log per phase.
#
# The record phase is deliberately NOT in the chain: it spends API credits and
# should be an explicit act.
#
set -uo pipefail

INSTANCE=${1:?usage: run_capture_chain.sh <instance_id> [first_phase]}

# Default is VERIFY, not profile. It used to be profile, which meant a bare
# invocation skipped the only gate that catches a replay diverging from its
# recording -- and then spent hours of TCG faithfully tracing the wrong
# execution. Verify costs 2-5.5 minutes under KVM. advance_instance.sh runs
# verify itself and then calls this with an explicit "profile", so it does not
# double-run.
FIRST=${2:-verify}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
LOGDIR=$RPOINT_IMAGES/chain-$INSTANCE
mkdir -p "$LOGDIR"

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
note()  { printf '[%s] %s\n' "$(stamp)" "$*" | tee -a "$LOGDIR/chain.log"; }

run_phase() {
  local phase=$1 log=$LOGDIR/$1.log
  note "START  $phase"
  local t0 t1
  t0=$(date +%s)
  if bash "$ROOT/scripts/capture_agentic.sh" "$INSTANCE" "$phase" >"$log" 2>&1; then
    t1=$(date +%s)
    note "OK     $phase  ($(( (t1-t0)/60 )) min)  -> $log"
    return 0
  fi
  t1=$(date +%s)
  note "FAILED $phase  ($(( (t1-t0)/60 )) min)  -> $log"
  tail -25 "$log" | sed 's/^/    /' | tee -a "$LOGDIR/chain.log"
  # Book the failure. Nothing used to call attempts.sh -- every row in the
  # August ledger was written by hand, and the campaign's most instructive
  # failure (gson) was never recorded at all. Default the classification to
  # `instance`: an operator who knows it was an infra bug can re-log it, but
  # the reverse -- a real instance failure quietly booked as infra -- is the
  # direction that buys a bad task a fourth try on API credits.
  bash "$ROOT/scripts/swe-agent/attempts.sh" log "$INSTANCE" instance \
       "chain: $phase failed (see $log)" >/dev/null 2>&1 || true
  # Surface the ceilings in the chain log itself, so an operator reading it sees
  # that a task is out of tries without going to look.
  bash "$ROOT/scripts/swe-agent/attempts.sh" check "$INSTANCE" 2>&1 \
    | sed 's/^/    /' | tee -a "$LOGDIR/chain.log" || true
  return 1
}

note "=== capture chain for $INSTANCE, starting at '$FIRST' ==="

started=0
for phase in verify profile trace convert; do
  [ "$phase" = "$FIRST" ] && started=1
  [ "$started" -eq 1 ] || continue
  run_phase "$phase" || { note "chain aborted at $phase"; exit 1; }
done

# Simulation is deliberately NOT in this chain. Running the traces through
# ChampSim is an experiment ON them, not part of producing them, and that
# tooling now lives in run-assets/ (see run-assets/PROVENANCE.md). The chain
# ends at `convert`, whose own gate -- trace_sanity_check --check on every
# window -- is what establishes a trace is usable.

note "=== chain complete for $INSTANCE ==="
