#!/usr/bin/env bash
#
# run_capture_chain.sh <instance_id> [first_phase] — unattended capture.
#
# Chains profile -> trace -> convert, stopping at the FIRST failure
# rather than carrying a bad artifact forward. Every phase already has its own
# gates; this only sequences them and keeps one log per phase.
#
# The record phase is deliberately NOT in the chain: it spends API credits and
# should be an explicit act.
#
set -uo pipefail

INSTANCE=${1:?usage: run_capture_chain.sh <instance_id> [first_phase]}
FIRST=${2:-profile}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOGDIR=$ROOT/images/chain-$INSTANCE
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
