#!/usr/bin/env bash
#
# campaign_watch.sh — one-shot liveness check over every in-flight capture.
#
# WHY THIS EXISTS. Long phases fail in three ways, and only one of them
# announces itself:
#
#   1. The process exits non-zero. Loud, and already handled.
#   2. The process exits SILENTLY -- redis-12272's provisioner died leaving no
#      [FAIL] marker at all, and nothing noticed until a human looked.
#   3. The process HANGS. gin-2121's replay wedged with SWE-ReX's shell in
#      do_select on its PTY. Guest load 0.00, zero cassette misses, everything
#      "running". It sat that way for 13 minutes, then 40 on the retry, and an
#      is-the-process-alive check would have called it healthy the whole time.
#
# So this tests LIVENESS, not existence. The decisive signal is the guest's own
# CPU accumulation: a QEMU process doing real work accrues utime+stime, and an
# idle one does not. That is measured from /proc on the host and needs no ssh,
# which matters because a wedged guest may not answer ssh either.
#
# Read-only. It reports; it never kills anything. Deciding to kill a stalled
# capture is a judgement about hours of work and belongs to a human or to the
# agent driving the campaign, not to a cron job.
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"

SAMPLE=${SAMPLE_SECONDS:-6}       # CPU sampling window
STALE=${STALE_MINUTES:-10}        # a log untouched this long is suspicious
LOGDIR=${WATCH_LOGDIR:-/tmp}

cpu_ticks() {  # cpu_ticks <pid> -> utime+stime, or empty if gone
  local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  # Fields 14,15 after the comm field, which may itself contain spaces.
  echo "$s" | awk '{ n=NF; print $(n-38) + $(n-37) }' 2>/dev/null
}

printf '%-34s %-10s %8s %9s %10s  %s\n' INSTANCE PHASE PID GUEST-CPU LOG-AGE VERDICT
printf '%.0s-' {1..96}; echo

# One row per running capture_agentic/provision_instance, plus any log that
# looks live but has no process behind it.
seen=""
while read -r pid cmd; do
  [ -n "$pid" ] || continue
  inst=$(echo "$cmd" | grep -oE '[a-z0-9_.-]+__[a-z0-9_.-]+' | head -1)
  [ -n "$inst" ] || continue
  case "$cmd" in
    *provision_instance*) phase=provision ;;
    *capture_agentic*)    phase=$(echo "$cmd" | awk '{print $NF}') ;;
    *)                    phase=? ;;
  esac
  seen="$seen $inst"

  # The guest for this instance, matched on the qcow2 name in QEMU's argv.
  qpid=""
  for p in $(pgrep -x qemu-system-x86 2>/dev/null); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "guest-$inst" && { qpid=$p; break; }
  done

  guestcpu="no-guest"
  if [ -n "$qpid" ]; then
    a=$(cpu_ticks "$qpid"); sleep "$SAMPLE"; b=$(cpu_ticks "$qpid")
    if [ -n "$a" ] && [ -n "$b" ]; then
      d=$(( b - a ))
      guestcpu="${d}t"
    else
      guestcpu="gone"
    fi
  fi

  log=$(ls -t "$LOGDIR"/{verify,prov,trace,profile}_*"$inst"* 2>/dev/null | head -1)
  age="-"
  [ -n "$log" ] && age=$(( ( $(date +%s) - $(stat -c %Y "$log") ) / 60 ))

  verdict=ok
  # A guest that accrued no CPU over the sample window is the gin signature.
  case "$guestcpu" in
    0t) verdict="STALLED? guest idle ${SAMPLE}s" ;;
    gone) verdict="guest vanished mid-phase" ;;
  esac
  [ "$age" != "-" ] && [ "$age" -ge "$STALE" ] && verdict="STALLED? log ${age}m old"

  printf '%-34s %-10s %8s %9s %10s  %s\n' "$inst" "$phase" "$pid" "$guestcpu" "${age}m" "$verdict"
done < <(ps -eo pid,cmd 2>/dev/null | grep -E 'capture_agentic\.sh|provision_instance\.sh' | grep -v grep)

# Logs whose process is gone: the silent-death case. A log that never reached a
# terminal marker means nobody was told it ended.
for log in "$LOGDIR"/{verify,prov}_*.log; do
  [ -f "$log" ] || continue
  inst=$(basename "$log" | sed -E 's/^(verify|prov)_//; s/\.log$//')
  case " $seen " in *" $inst "*) continue ;; esac
  if grep -qE 'PROVISIONED |VERDICT: (FAITHFUL|IDENTICAL)|EXIT=0' "$log" 2>/dev/null; then
    state="done"
  elif grep -qE '\[FAIL\]|EXIT=[1-9]' "$log" 2>/dev/null; then
    state="FAILED (marker present)"
  else
    state="DIED SILENTLY -- no terminal marker, no process"
  fi
  age=$(( ( $(date +%s) - $(stat -c %Y "$log") ) / 60 ))
  printf '%-34s %-10s %8s %9s %10s  %s\n' "$inst" "-" "-" "-" "${age}m" "$state"
done
