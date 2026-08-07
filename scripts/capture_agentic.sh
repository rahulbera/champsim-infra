#!/usr/bin/env bash
#
# capture_agentic.sh <instance_id> <phase> — HOST-side driver for one capture.
#
# Phases, in order:
#   record   boot KVM (network up), run the agent once against the real LLM,
#            snapshot the image. Needs LLM_API_KEY. Spends credits.
#   verify   boot KVM, replay offline from cassettes; asserts 0 replay misses.
#   profile  boot TCG with profile=on, replay, and read the instruction total.
#   trace    boot TCG with sampling derived from the profile, replay, capture.
#   convert  raw -> ChampSim v2 + validation.
#
# Each phase starts from a known image so a failed phase never contaminates the
# next. `record` works on <inst>.qcow2 and snapshots to <inst>.recorded.qcow2.
# Every REPLAY phase (verify/profile/trace) restores <inst>.provisioned.qcow2 --
# the exact state the recording began in -- and injects the cassettes and the
# recorded trajectory from the host. Restoring the post-record image instead
# would leave the tree already modified and already rebuilt, so the replayed
# build work would not match the recorded build work.
#
set -euo pipefail

INSTANCE=${1:?usage: capture_agentic.sh <instance_id> <phase>}
PHASE=${2:?usage: capture_agentic.sh <instance_id> <phase>}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGES=$ROOT/images
WORK=$IMAGES/guest-$INSTANCE.qcow2
RECORDED=$IMAGES/guest-$INSTANCE.recorded.qcow2
PROVISIONED=$IMAGES/guest-$INSTANCE.provisioned.qcow2
ARTIFACTS=$ROOT/artifacts/$INSTANCE
META=$IMAGES/capture-$INSTANCE.meta
SSH_KEY=$IMAGES/id_ed25519

# ---- per-capture isolation, so several captures can run concurrently --------
#
# Everything that used to be global is now derived from a SLOT: the ssh
# forwards, the plugin's trigger file, the profile output directory and the
# QEMU pidfile. Without this, a second capture's stop_qemu (which matched by
# process NAME) would kill the first capture's guest mid-run, and both would
# fight over ports 2222/2223 and /tmp/swe_roi_trigger.
#
# SLOT is read from the instance descriptor's CAPTURE_SLOT if present, else
# from the environment, else 0. Two captures sharing a slot is a configuration
# error that shows up as a port bind failure, which is the right way round.
SLOT=${CAPTURE_SLOT:-$(grep -h '^CAPTURE_SLOT=' \
        "$ROOT/scripts/swe-agent/instances/$INSTANCE.env" 2>/dev/null \
        | tail -1 | cut -d= -f2)}
SLOT=${SLOT:-0}
KVM_PORT=$((2300 + SLOT * 10))
TCG_PORT=$((2301 + SLOT * 10))
TRIGGER=/tmp/swe_roi_trigger.$INSTANCE
PIDFILE=$IMAGES/.qemu-$INSTANCE.pid
PROFILE_OUT=$IMAGES/profile_out-$INSTANCE

# Capture geometry. 300M matches the SPEC SimPoint slice length used in
# champsim-infra, so agentic-vs-SPEC comparisons are at identical geometry.
WINDOWS=${WINDOWS:-4}
WINDOW_LEN=${WINDOW_LEN:-300000000}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

# A phase that fails mid-workload (a gate refusing the run, say) exits before
# its shutdown_guest and leaves QEMU running, holding the ports and the image.
# The next phase's stop_qemu would clear it, but only after a human works out
# why ssh is answering on the wrong port.
cleanup_on_exit() {
  local rc=$?
  if [ $rc -ne 0 ] && qemu_running; then
    echo "  [cleanup] phase failed; stopping the guest it left running" >&2
    stop_qemu
  fi
  exit $rc
}
trap cleanup_on_exit EXIT

ssh_guest() {  # ssh_guest <port> <cmd...>
  local port=$1; shift
  ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=10000 \
      -i "$SSH_KEY" -p "$port" ubuntu@127.0.0.1 "$@"
}

wait_ssh() {  # wait_ssh <port> <timeout-s>
  local port=$1 limit=${2:-600} t=0
  while [ $t -lt "$limit" ]; do
    ssh_guest "$port" true 2>/dev/null && { echo "  ssh up after ${t}s"; return 0; }
    sleep 5; t=$((t+5))
  done
  return 1
}

# QEMU is tracked by PID, never by name. `pkill -x qemu-system-x86` would take
# down every concurrent capture's guest, and `pkill -f qemu` additionally
# matches this script's own shell. The pidfile is the only handle used.
qemu_pid() { [ -f "$PIDFILE" ] && cat "$PIDFILE" 2>/dev/null || true; }
qemu_running() {
  local p; p=$(qemu_pid)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
stop_qemu() {
  local p; p=$(qemu_pid)
  qemu_running || { rm -f "$PIDFILE"; return 0; }
  kill "$p" 2>/dev/null || true
  local t=0; while qemu_running && [ $t -lt 30 ]; do sleep 1; t=$((t+1)); done
  qemu_running && kill -9 "$p" 2>/dev/null || true
  rm -f "$PIDFILE"
  sleep 2
}

shutdown_guest() {  # graceful, so the plugin's atexit writes its manifest
  local port=$1
  ssh_guest "$port" 'sudo systemctl poweroff' 2>/dev/null || true
  local t=0; while qemu_running && [ $t -lt 300 ]; do sleep 2; t=$((t+2)); done
  # `qemu_running && { ... }` as the last statement would return 1 on the
  # SUCCESS path (guest already gone) and, under `set -e`, abort the caller
  # immediately after the workload finished but before its result was saved.
  # That is exactly how the first record pass lost its snapshot.
  if qemu_running; then
    echo "  guest did not power off in ${t}s, forcing"
    stop_qemu
  else
    echo "  guest powered off cleanly after ${t}s"
  fi
}

restore_from_recorded() {
  [ -f "$RECORDED" ] || die "no recorded snapshot at $RECORDED -- run the record phase first"
  stop_qemu
  cp --reflink=auto "$RECORDED" "$WORK"
  echo "  restored $WORK from the recorded snapshot"
}

# Replay restores the PROVISIONED image, not the post-record one, and injects
# the cassettes from the host.
#
# The recording began with a fully built tree (provisioning builds it, and the
# offline gate rebuilds it from distclean). Restoring the post-record snapshot
# and letting replay_pinned.sh run `git clean -xfd` deletes every gitignored
# build artifact, so the agent's first `make` becomes a FULL build of redis,
# jemalloc and lua where the recording did an incremental one-file rebuild.
#
# Identical actions, wildly different work -- and compare_trajectories.py cannot
# see it, because actions come from replayed LLM responses rather than from
# observations. The trace would be a faithful recording of the wrong amount of
# computation. Starting from the same disk state the recording started from is
# the only thing that makes the measurement mean anything.
restore_from_provisioned() {
  [ -f "$PROVISIONED" ] || die "no provisioned image at $PROVISIONED"
  [ -d "$ARTIFACTS/cassettes" ] || die "no host-side cassettes at $ARTIFACTS/cassettes -- run the record phase first"
  stop_qemu
  cp --reflink=auto "$PROVISIONED" "$WORK"
  echo "  restored $WORK from the PROVISIONED image (same state the recording began in)"
}

inject_artifacts() {  # inject_artifacts <port>
  local port=$1
  local rsh="ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $port"
  $rsh ubuntu@127.0.0.1 'sudo mkdir -p /opt/cassettes /opt/trajectories && sudo chown -R ubuntu:ubuntu /opt/cassettes /opt/trajectories' \
    || die "could not prepare guest artifact dirs"
  rsync -a -e "$rsh" "$ARTIFACTS/cassettes/" "ubuntu@127.0.0.1:/opt/cassettes/" \
    || die "could not inject cassettes"
  rsync -a -e "$rsh" "$ARTIFACTS/trajectories/" "ubuntu@127.0.0.1:/opt/trajectories/" \
    || die "could not inject the recorded trajectory"
  local n
  n=$($rsh ubuntu@127.0.0.1 "find /opt/cassettes/$INSTANCE -name '*.json' | wc -l")
  [ "${n:-0}" -gt 0 ] || die "no cassettes landed in the guest"
  echo "  injected $n cassettes and the recorded trajectory"
}

# The snapshot was taken before the record pass and freezes whatever guest-side
# scripts existed then. Re-staging after each restore means a fix to a pass does
# not require re-recording -- otherwise every script change costs an API run.
# Staged ONCE per phase, before the workload starts, so the profile and trace
# passes still execute identical code.
stage_tools() {
  local port=$1
  rsync -a -e "ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $port" \
    --exclude '__pycache__' --exclude 'reference' --exclude 'problem_statements' \
    "$ROOT/scripts/swe-agent/" "ubuntu@127.0.0.1:/opt/swe-agent-tools/" \
    || die "could not stage guest tools"
  rsync -a -e "ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $port" \
    "$ROOT/scripts/swe-agent/problem_statements/" "ubuntu@127.0.0.1:/opt/problem_statements/" \
    || die "could not stage problem statements"
  echo "  staged current guest-side tools"
}

boot_kvm() {  # boot_kvm <serial-log>
  stop_qemu
  ( cd "$IMAGES" && sg kvm -c "IMG=$(basename "$WORK") SSH_PORT=$KVM_PORT \
      nohup bash boot_build.sh > $1 2>&1 & echo \$! > $PIDFILE" )
  sleep 5
  qemu_running || { tail -20 "$1"; die "qemu failed to start"; }
  wait_ssh "$KVM_PORT" 900 || { tail -20 "$1"; die "guest never came up"; }
}

boot_tcg() {  # boot_tcg <outdir> <plugin-extra> <serial-log>
  local outdir=$1 extra=$2 log=$3
  stop_qemu
  rm -f "$TRIGGER"
  ( cd "$IMAGES" && IMG=$(basename "$WORK") SSH_PORT=$TCG_PORT TRIGGER=$TRIGGER \
      nohup bash boot_tcg_trace.sh "$outdir" "$extra" > "$log" 2>&1 & echo $! > "$PIDFILE" )
  sleep 5
  qemu_running || { tail -20 "$log"; die "qemu failed to start under TCG"; }
  # TCG boots are slow; the guest kernel is emulated instruction by instruction.
  wait_ssh "$TCG_PORT" 2400 || { tail -30 "$log"; die "guest never came up under TCG"; }
}

arm_trigger_on_marker() {  # arm_trigger_on_marker <serial-log>
  # The guest prints TRACE_ROI_BEGIN to /dev/console immediately before the
  # agent starts. Watch for it and arm the plugin. Backgrounded so the caller
  # can start the workload; it exits on its own once armed.
  local log=$1
  rm -f "$log.trigger"
  ( t=0
    while [ $t -lt 14400 ]; do
      if grep -q TRACE_ROI_BEGIN "$log" 2>/dev/null; then
        touch "$TRIGGER"
        echo "armed at $(date +%T)" >> "$log.trigger"
        exit 0
      fi
      sleep 1; t=$((t+1))
    done
    echo "NEVER SAW THE MARKER" >> "$log.trigger" ) &
}

case "$PHASE" in

record)
  : "${LLM_API_KEY:?LLM_API_KEY must be set for the record phase}"
  say "RECORD — $INSTANCE (spends API credits)"
  [ -f "$WORK" ] || die "no provisioned image at $WORK"
  boot_kvm "$IMAGES/record-$INSTANCE.boot.log"
  ssh_guest $KVM_PORT "sudo LLM_API_KEY='$LLM_API_KEY' \
      bash /opt/swe-agent-tools/record_trajectory.sh $INSTANCE" 2>&1 | tail -50
  shutdown_guest $KVM_PORT
  cp --reflink=auto "$WORK" "$RECORDED"
  echo "  snapshot -> $RECORDED"
  ;;

verify)
  say "VERIFY — deterministic replay of $INSTANCE"
  restore_from_provisioned
  boot_kvm "$IMAGES/verify-$INSTANCE.boot.log"
  stage_tools $KVM_PORT
  inject_artifacts $KVM_PORT
  ssh_guest $KVM_PORT "sudo bash /opt/swe-agent-tools/replay_pinned.sh $INSTANCE" 2>&1 | tail -30
  shutdown_guest $KVM_PORT
  ;;

profile)
  say "PROFILE — sizing the trajectory for $INSTANCE"
  restore_from_provisioned
  LOG=$IMAGES/profile-$INSTANCE.boot.log
  boot_tcg "$PROFILE_OUT" ",profile=on" "$LOG"
  stage_tools $TCG_PORT
  inject_artifacts $TCG_PORT
  arm_trigger_on_marker "$LOG"
  ssh_guest $TCG_PORT "sudo bash /opt/swe-agent-tools/replay_pinned.sh $INSTANCE" 2>&1 | tail -25
  shutdown_guest $TCG_PORT

  # The plugin starts DORMANT and only counts once the trigger file appears, so
  # an unarmed trigger yields a profile of nothing rather than of the agent run.
  grep -q 'armed' "$LOG.trigger" 2>/dev/null \
    || die "the trigger never armed -- this profile does not describe the agent run"

  line=$(grep -h 'PROFILE:' "$LOG" | tail -1) || true
  [ -n "$line" ] || die "no PROFILE line in $LOG -- the plugin never reported a total"
  total=$(sed -n 's/.*PROFILE: \([0-9]*\) instructions.*/\1/p'   <<<"$line")
  user=$(sed  -n 's/.*(\([0-9]*\) user.*/\1/p'                   <<<"$line")
  kern=$(sed  -n 's/.*user, \([0-9]*\) kernel.*/\1/p'            <<<"$line")
  [ -n "$user" ] && [ "$user" -gt 0 ] || die "parsed a zero/absent user total from: $line"

  need=$((WINDOWS * WINDOW_LEN))
  [ "$user" -gt "$need" ] || die "trajectory is only $user user insns; $WINDOWS x $WINDOW_LEN needs $need"
  gap=$(( (user - need) / (WINDOWS - 1) ))

  { echo "instance=$INSTANCE"
    echo "profile_total=$total"
    echo "profile_user=$user"
    echo "profile_kernel=$kern"
    echo "windows=$WINDOWS"
    echo "window_len=$WINDOW_LEN"
    echo "sample_gap=$gap"; } > "$META"
  echo "  total  $total  (user $user / kernel $kern)"
  echo "  gap    $gap   -> $WINDOWS x $WINDOW_LEN on the user clock"
  echo "  wrote  $META"
  ;;

trace)
  say "TRACE — $WINDOWS x $WINDOW_LEN windows of $INSTANCE"
  [ -f "$META" ] || die "no $META -- run the profile phase first"
  # shellcheck disable=SC1090
  . "$META"
  restore_from_provisioned
  OUT=$IMAGES/trace_out-$INSTANCE
  rm -rf "$OUT"; mkdir -p "$OUT"
  LOG=$IMAGES/trace-$INSTANCE.boot.log
  boot_tcg "$OUT" \
    ",sample_len=$window_len,sample_gap=$sample_gap,sample_count=$windows,sample_clock=user" \
    "$LOG"
  stage_tools $TCG_PORT
  inject_artifacts $TCG_PORT
  arm_trigger_on_marker "$LOG"
  ssh_guest $TCG_PORT "sudo bash /opt/swe-agent-tools/replay_pinned.sh $INSTANCE" 2>&1 | tail -25
  shutdown_guest $TCG_PORT

  grep -q 'armed' "$LOG.trigger" 2>/dev/null || die "the trigger never armed -- no window was captured"
  n=$(find "$OUT" -name 'trace_vcpu*_c*.raw.zst' | wc -l)
  echo "  chunks: $n"
  [ "$n" -eq "$windows" ] || die "expected $windows chunks, got $n"
  cat "$OUT"/*manifest.txt 2>/dev/null | sed 's/^/  /'
  ;;

convert)
  say "CONVERT + VALIDATE — $INSTANCE"
  OUT=$IMAGES/trace_out-$INSTANCE
  DST=$IMAGES/champsim_out/$INSTANCE
  mkdir -p "$DST"
  # raw2champsim links capstone (for the AArch64 decoder) and the build here
  # resolves it from a user prefix rather than a system path.
  export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/home/rbera/local/lib
  SANITY=${SANITY:-/home/rbera/work/bpeval/champsim-infra/tools/trace_sanity_check/trace_sanity_check}

  shopt -s nullglob
  raws=("$OUT"/trace_vcpu*_c*.raw.zst)
  [ ${#raws[@]} -gt 0 ] || die "no raw chunks in $OUT"
  fail=0
  for raw in "${raws[@]}"; do
    idx=$(sed -n 's/.*_c\([0-9]*\)\.raw\.zst/\1/p' <<<"$raw")
    dst=$DST/${INSTANCE}_w${idx}.champsim2.zst
    echo "  $(basename "$raw") -> $(basename "$dst")"
    # CLI is positional: raw2champsim [-v] [-n COUNT] <in.raw.zst> [out.zst]
    "$ROOT/converter/raw2champsim" "$raw" "$dst" 2>&1 \
      | grep -iE 'instruction|user|kernel|branch|decode fail|Type ' | sed 's/^/    /'

    # Validation is a gate, not a report. --check enforces the branch-type
    # invariants and exits 2 on failure; the load-bearing one is the conditional
    # taken rate being strictly inside (0,100)%, which is what catches a trace
    # whose branch metadata is structurally present but meaningless.
    if [ -x "$SANITY" ]; then
      if "$SANITY" -i "$dst" -f v2 --check > "$dst.check.log" 2>&1; then
        echo "    [ok] sanity --check passed"
      else
        echo "    [FAIL] sanity --check failed:"; tail -12 "$dst.check.log" | sed 's/^/      /'
        fail=1
      fi
    else
      echo "    [warn] no trace_sanity_check at $SANITY -- NOT validated"
      fail=1
    fi
  done
  ls -la "$DST"/*.champsim2.zst
  [ "$fail" -eq 0 ] || die "one or more windows failed validation"
  echo "  all $((${#raws[@]})) windows converted and validated"
  ;;

*) die "unknown phase '$PHASE' (record|verify|profile|trace|convert)" ;;
esac
