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

# --- snapshot guard --------------------------------------------------------
# Bash reads a running script BY BYTE OFFSET, re-reading as it executes. Change
# the file underneath a live chain and it resumes at the wrong place.
#
# On 2026-09-02 that turned three COMPLETED chains into spurious second cycles.
# micropython-13039, docusaurus-10130 and hugo-12579 each finished convert with
# all five windows validated, then printed
#     line 64: === capture chain for ... ===: command not found
# fell back into the phase loop, and began re-tracing -- on a path that ends in
# a convert that would overwrite the very windows they had just validated. The
# edit that did it was a one-line comment change made hours after those chains
# started.
#
# So a chain now runs from an immutable copy of the whole scripts/ tree, taken
# at start. This covers capture_agentic.sh too, which runs for an entire phase
# and is invoked through $ROOT below.
#
# RPOINT_ARTIFACTS is pinned to the REAL repo on the way in: cassettes and
# trajectories cost API credits and cannot be regenerated identically, so they
# must never be read from -- or written to -- a throwaway copy.
if [ -z "${RPOINT_CHAIN_SNAPSHOT:-}" ]; then
  _src=$(cd "$(dirname "$0")/.." && pwd)
  _snap=$(mktemp -d "${TMPDIR:-/tmp}/rpoint-chain.XXXXXXXX") || exit 1
  cp -a "$_src/scripts" "$_snap/scripts" \
    || { printf '  [FAIL] could not snapshot scripts/ to %s\n' "$_snap" >&2; rm -rf "$_snap"; exit 1; }
  export RPOINT_CHAIN_SNAPSHOT=$_snap
  : "${RPOINT_ARTIFACTS:=$_src/artifacts}"
  # The attempts LEDGER must also live in the real repo. Written through $ROOT
  # it landed in the snapshot and was deleted with it -- every chain-phase
  # failure would have been silently discarded, which is exactly the record the
  # three-strikes rule is decided from.
  export RPOINT_REPO_ROOT=$_src
  export RPOINT_ARTIFACTS
  bash "$_snap/scripts/run_capture_chain.sh" "$@"
  _rc=$?
  rm -rf "$_snap"
  exit $_rc
fi

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
  bash "${RPOINT_REPO_ROOT:-$ROOT}/scripts/swe-agent/attempts.sh" log "$INSTANCE" instance \
       "chain: $phase failed (see $log)" >/dev/null 2>&1 || true
  # Surface the ceilings in the chain log itself, so an operator reading it sees
  # that a task is out of tries without going to look.
  bash "${RPOINT_REPO_ROOT:-$ROOT}/scripts/swe-agent/attempts.sh" check "$INSTANCE" 2>&1 \
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
