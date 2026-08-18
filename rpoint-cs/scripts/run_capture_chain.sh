#!/usr/bin/env bash
#
# run_capture_chain.sh <instance_id> [first_phase] — unattended capture.
#
# Chains profile -> trace -> convert -> simulate, stopping at the FIRST failure
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

# ---- simulate ------------------------------------------------------------
DST=$ROOT/images/champsim_out/$INSTANCE
note "START  simulate"
shopt -s nullglob
traces=("$DST"/*.champsim2.zst)
if [ ${#traces[@]} -eq 0 ]; then
  note "FAILED simulate: no converted traces in $DST"
  exit 1
fi
if python3 "$ROOT/scripts/analyze_bp.py" --jobs 4 \
     --out "$LOGDIR/bp_$INSTANCE.csv" \
     --keep-json "$LOGDIR/json" \
     "${traces[@]}" >"$LOGDIR/simulate.log" 2>&1; then
  note "OK     simulate -> $LOGDIR/bp_$INSTANCE.csv"
  sed -n '/^trace /,$p' "$LOGDIR/simulate.log" | tee -a "$LOGDIR/chain.log"
else
  note "FAILED simulate -> $LOGDIR/simulate.log"
  tail -20 "$LOGDIR/simulate.log" | sed 's/^/    /' | tee -a "$LOGDIR/chain.log"
  exit 1
fi

note "=== chain complete for $INSTANCE ==="
