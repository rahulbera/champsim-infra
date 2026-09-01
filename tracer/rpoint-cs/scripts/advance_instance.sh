#!/usr/bin/env bash
#
# advance_instance.sh <instance_id> [record_log] — carry one instance from a
# finished record pass all the way to a validated ChampSim trace.
#
#   1. wait for the record pass to report success
#   2. pull the cassettes and trajectory out of the guest onto the host
#      (every replay phase restores the PROVISIONED image and injects them)
#   3. verify   — KVM, cheap, runs unthrottled
#   4. profile -> trace -> convert, under a TCG SEMAPHORE
#
# There is no simulate phase: running the traces through ChampSim is an
# experiment ON them, not part of producing them, and that tooling lives in
# run-assets/ (see run_capture_chain.sh, which ends at `convert`).
#
# The semaphore matters, but NOT because a TCG pass saturates the box -- it does
# not. images/boot_tcg_trace.sh boots -smp 4, yet the plugin traces vcpus=1 and
# the guest pins the agent to that one CPU (replay_pinned.sh, taskset -c
# $PIN_CPU with PIN_CPU=1, isolcpus'd). The other three vCPUs have nothing
# runnable and sit in the kernel idle loop; with no idle=poll their QEMU vCPU
# threads block on the emulated HLT rather than spin. zstd compression runs
# inline on the tracing vCPU thread and is single-threaded (ZSTD_createCCtx, no
# nbWorkers). So one pass is roughly ONE busy vCPU thread plus QEMU's IO thread
# -- the cap exists to bound aggregate load and memory (-m 8G each), not because
# each pass eats four cores. Slots are tried non-blockingly in turn, then waited
# on. The 2026-08 campaign in fact sustained 6-way for 169 minutes with no
# per-instance throughput loss (102/111/112 MIPS at increasing occupancy).
#
set -uo pipefail

INSTANCE=${1:?usage: advance_instance.sh <instance_id> [record_log]}
REC_LOG=${2:-/tmp/claude-1000/record_${INSTANCE%%__*}.log}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
IMAGES=$RPOINT_IMAGES
ARTIFACTS=$ROOT/artifacts/$INSTANCE
SSH_KEY=$IMAGES/id_ed25519
LOGDIR=$IMAGES/chain-$INSTANCE
TCG_SLOTS=${TCG_SLOTS:-3}
LOCKDIR=${LOCKDIR:-/tmp/claude-1000/tcg-locks}

mkdir -p "$LOGDIR" "$LOCKDIR"
note() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGDIR/advance.log"; }

SLOT=$(grep -h '^CAPTURE_SLOT=' "$ROOT/scripts/swe-agent/instances/$INSTANCE.env" \
       2>/dev/null | tail -1 | cut -d= -f2)
SLOT=${SLOT:-0}
KVM_PORT=$((2300 + SLOT * 10))

note "=== advancing $INSTANCE (slot $SLOT) ==="

# ---- 1. wait for the record pass -------------------------------------------
note "waiting for the record pass to finish"
while true; do
  if grep -q 'cassettes recorded' "$REC_LOG" 2>/dev/null; then break; fi
  if grep -q '\[FAIL\]' "$REC_LOG" 2>/dev/null; then
    note "record pass FAILED -- not advancing"; tail -15 "$REC_LOG" | sed 's/^/    /'; exit 1
  fi
  sleep 30
done
note "record pass reported success"
grep -E 'cassettes recorded|steps:|exit_status|patch:|commands:' "$REC_LOG" | sed 's/^/    /' | tee -a "$LOGDIR/advance.log"

# ---- 2. pull the artifacts onto the host -----------------------------------
# The guest is still up at this point only if the record phase has not yet
# powered it off; wait for the phase to finish before touching the image.
while pgrep -f "capture_agentic.sh $INSTANCE record" >/dev/null 2>&1; do sleep 10; done
sleep 5

if [ ! -d "$ARTIFACTS/cassettes" ]; then
  note "extracting cassettes and trajectory from the guest"
  ( cd "$IMAGES" && sg kvm -c "IMG=guest-$INSTANCE.qcow2 SSH_PORT=$KVM_PORT \
      PIDFILE=$IMAGES/.qemu-$INSTANCE.pid nohup bash boot_build.sh \
      > $LOGDIR/extract.boot.log 2>&1 &" )
  t=0
  while [ $t -lt 600 ]; do
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -i "$SSH_KEY" -p "$KVM_PORT" ubuntu@127.0.0.1 true 2>/dev/null && break
    sleep 5; t=$((t+5))
  done
  mkdir -p "$ARTIFACTS"
  SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY"
  rsync -a -e "ssh -q $SSHO -p $KVM_PORT" \
        "ubuntu@127.0.0.1:/opt/cassettes/" "$ARTIFACTS/cassettes/" || exit 1
  ssh -q $SSHO -p "$KVM_PORT" ubuntu@127.0.0.1 'sudo chmod -R a+rX /opt/trajectories' 2>/dev/null
  rsync -a -e "ssh -q $SSHO -p $KVM_PORT" \
        "ubuntu@127.0.0.1:/opt/trajectories/" "$ARTIFACTS/trajectories/" || exit 1
  n=$(find "$ARTIFACTS/cassettes" -name '*.json' | wc -l)
  note "pulled $n cassettes and the recorded trajectory to $ARTIFACTS"
  [ "$n" -gt 0 ] || { note "NO cassettes extracted -- stopping"; exit 1; }
  ssh -q $SSHO -p "$KVM_PORT" ubuntu@127.0.0.1 'sudo systemctl poweroff' 2>/dev/null || true
  sleep 25
fi

# A leaked key in a cassette is permanent; these files are committed.
if grep -rqil 'authorization' "$ARTIFACTS/cassettes" 2>/dev/null; then
  note "!! Authorization header found in a cassette -- refusing to continue"; exit 1
fi
note "no Authorization header in any cassette"

# ---- 3. verify (KVM, unthrottled) ------------------------------------------
note "START verify"
if bash "$ROOT/scripts/capture_agentic.sh" "$INSTANCE" verify > "$LOGDIR/verify.log" 2>&1; then
  note "OK verify"
  grep -E 'record:|replay:|identical actions|VERDICT|misses' "$LOGDIR/verify.log" | sed 's/^/    /' | tee -a "$LOGDIR/advance.log"
else
  note "FAILED verify -- not tracing this run"
  tail -20 "$LOGDIR/verify.log" | sed 's/^/    /' | tee -a "$LOGDIR/advance.log"
  exit 1
fi

# ---- 4. TCG phases, throttled ----------------------------------------------
note "waiting for a TCG slot (cap $TCG_SLOTS)"
exec 9>/dev/null
acquired=""
while [ -z "$acquired" ]; do
  for i in $(seq 1 "$TCG_SLOTS"); do
    exec 9>"$LOCKDIR/tcg.$i"
    if flock -n 9; then acquired=$i; break; fi
  done
  [ -z "$acquired" ] && sleep 60
done
note "acquired TCG slot $acquired"

bash "$ROOT/scripts/run_capture_chain.sh" "$INSTANCE" profile
rc=$?
flock -u 9
note "released TCG slot $acquired (chain rc=$rc)"
exit $rc
