#!/usr/bin/env bash
#
# recover_profile.sh <instance_id> — salvage a profile pass whose DRIVER died.
#
# A TCG profile pass is 50-290 minutes. If capture_agentic.sh dies while the
# guest is still running -- which happened to burntsushi__ripgrep-2209, whose
# run_capture_chain.sh vanished mid-profile while its guest kept burning 550
# CPU ticks per 5 s -- the work is NOT lost, but nobody collects it:
#
#   * the plugin writes its "PROFILE: N instructions (U user, K kernel)" line
#     at QEMU EXIT, and the exit normally comes from the driver's
#     shutdown_guest. With the driver gone the guest finishes its replay and
#     then sits idle forever, so the line is never written.
#   * even once written, the .meta that the trace phase reads is produced by
#     the driver, not by the guest.
#
# So this does the driver's remaining work: wait for the replay to finish
# (detected by the guest going idle), power the guest off GRACEFULLY so the
# plugin flushes, then parse the boot log and write the .meta -- applying the
# same gates the profile phase applies, because a recovered meta that skipped
# them would be worse than no meta.
#
# It does NOT re-run anything. If the boot log already has a PROFILE line it
# skips straight to parsing.
#
set -euo pipefail

INSTANCE=${1:?usage: recover_profile.sh <instance_id>}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
. "$ROOT/scripts/lib/slots.sh"
IMAGES=$RPOINT_IMAGES

SLOT=${CAPTURE_SLOT:-$(resolve_slot "$INSTANCE" "$ROOT/scripts/swe-agent/instances")} || exit 1
TCG_PORT=$((2301 + SLOT * 10))
LOG=$IMAGES/profile-$INSTANCE.boot.log
META=$IMAGES/capture-$INSTANCE.meta
SSH_KEY=$IMAGES/id_ed25519

WINDOWS=${WINDOWS:-5}
WINDOW_LEN=${WINDOW_LEN:-300000000}
IDLE_TICKS=${IDLE_TICKS:-20}      # below this over the sample window = finished
SAMPLE=${SAMPLE_SECONDS:-10}
MAX_WAIT=${MAX_WAIT:-21600}       # 6 h

die() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }
ok()  { printf '  [ok] %s\n' "$*"; }

[ -f "$LOG" ] || die "no profile boot log at $LOG -- was a profile pass ever started?"

# The trigger gate, exactly as the profile phase applies it. The plugin starts
# DORMANT; an unarmed trigger means it profiled nothing rather than the agent.
grep -q 'armed' "$LOG.trigger" 2>/dev/null \
  || die "the trigger never armed -- this profile does not describe the agent run"

guest_pid() {
  local p cl
  for p in $(pgrep -x qemu-system-x86 2>/dev/null); do
    cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    case "$cl" in *"guest-$INSTANCE.qcow2"*) echo "$p"; return 0 ;; esac
  done
  return 1
}
cpu_ticks() { awk '{ n=NF; print $(n-38) + $(n-37) }' "/proc/$1/stat" 2>/dev/null; }

if ! grep -q 'PROFILE:' "$LOG"; then
  qpid=$(guest_pid) || die "no PROFILE line and no running guest -- nothing to recover"
  echo "  guest pid $qpid still running; waiting for the replay to finish"

  waited=0
  while [ "$waited" -lt "$MAX_WAIT" ]; do
    a=$(cpu_ticks "$qpid") || die "guest vanished while waiting"
    sleep "$SAMPLE"
    b=$(cpu_ticks "$qpid") || die "guest vanished while waiting"
    d=$(( b - a ))
    if [ "$d" -lt "$IDLE_TICKS" ]; then
      ok "guest idle (${d} ticks/${SAMPLE}s) -- the replay has finished"
      break
    fi
    waited=$(( waited + SAMPLE ))
    printf '\r  working: %s ticks/%ss, waited %ss  ' "$d" "$SAMPLE" "$waited"
  done
  echo
  [ "$waited" -lt "$MAX_WAIT" ] || die "guest still busy after ${MAX_WAIT}s -- not powering it off"

  # Graceful poweroff so the plugin's atexit runs. A kill would lose the very
  # number we are here to recover.
  echo "  powering off gracefully so the plugin flushes its total"
  ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -i "$SSH_KEY" -p "$TCG_PORT" ubuntu@127.0.0.1 \
      'sudo systemctl poweroff' 2>/dev/null || true
  t=0
  while guest_pid >/dev/null 2>&1 && [ "$t" -lt 300 ]; do sleep 5; t=$(( t + 5 )); done
  guest_pid >/dev/null 2>&1 && die "guest did not power off in ${t}s -- refusing to kill it and lose the flush"
  ok "guest powered off after ${t}s"
fi

line=$(grep -h 'PROFILE:' "$LOG" | tail -1) || true
[ -n "$line" ] || die "still no PROFILE line in $LOG -- the plugin never reported a total"

total=$(sed -n 's/.*PROFILE: \([0-9]*\) instructions.*/\1/p' <<<"$line")
user=$(sed  -n 's/.*(\([0-9]*\) user.*/\1/p'                 <<<"$line")
kern=$(sed  -n 's/.*user, \([0-9]*\) kernel.*/\1/p'          <<<"$line")
[ -n "$user" ] && [ "$user" -gt 0 ] || die "parsed a zero/absent user total from: $line"

need=$(( WINDOWS * WINDOW_LEN ))
[ "$user" -gt "$need" ] || die "trajectory is only $user user insns; $WINDOWS x $WINDOW_LEN needs $need"
gap=$(( (user - need) / (WINDOWS - 1) ))

[ -f "$META" ] && die "$META already exists -- refusing to overwrite a real profile"
{ echo "instance=$INSTANCE"
  echo "profile_total=$total"
  echo "profile_user=$user"
  echo "profile_kernel=$kern"
  echo "windows=$WINDOWS"
  echo "window_len=$WINDOW_LEN"
  echo "sample_gap=$gap"
  echo "# recovered by recover_profile.sh: the driver died mid-profile and the"
  echo "# guest was powered off by hand so the plugin could flush its total."
} > "$META"
ok "total $total (user $user / kernel $kern)"
ok "gap $gap -> $WINDOWS x $WINDOW_LEN on the user clock"
ok "wrote $META"
echo "  next: run_capture_chain.sh $INSTANCE trace"
