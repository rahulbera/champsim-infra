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

# Only real instances count. Inferring them from log FILENAMES picked up
# "gin", "boot" and "rest" from ad-hoc scratch logs and reported them as dead
# captures -- noise that would make the watchdog worth ignoring.
# tr to SPACES: the list is newline-separated out of basename, but is_instance
# matches with *" $1 "* which needs space delimiters -- with newlines only the
# first and last entries could ever match, so the watchdog silently reported an
# empty table while four chains were running.
INSTANCES=$(ls "$ROOT/scripts/swe-agent/instances"/*.env 2>/dev/null \
            | xargs -n1 basename 2>/dev/null | sed 's/\.env$//' | tr '\n' ' ')
is_instance() { case " $INSTANCES " in *" $1 "*) return 0;; *) return 1;; esac; }

printf '%-34s %-10s %8s %9s %10s  %s\n' INSTANCE PHASE PID GUEST-CPU LOG-AGE VERDICT
printf '%.0s-' {1..96}; echo

# One row per running capture_agentic/provision_instance, plus any log that
# looks live but has no process behind it.
seen=""
while read -r pid cmd; do
  [ -n "$pid" ] || continue
  inst=$(echo "$cmd" | grep -oE '[a-z0-9_.-]+__[a-z0-9_.-]+' | head -1)
  { [ -n "$inst" ] && is_instance "$inst"; } || continue
  case "$cmd" in
    *provision_instance*)  phase=provision ;;
    *run_capture_chain*)   phase=chain ;;
    *capture_agentic*)     phase=$(echo "$cmd" | awk '{print $NF}') ;;
    *)                    phase=? ;;
  esac
  # One row per instance, not per process: `timeout` and the script it wraps
  # both match, and two identical rows make the table harder to scan.
  case " $seen " in *" $inst:$phase "*) continue ;; esac
  seen="$seen $inst:$phase"

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

  # The AUTHORITATIVE log is the chain's own, written by run_capture_chain.sh.
  # Globbing /tmp for scratch logs measured the age of whatever ad-hoc file
  # happened to match the instance name and reported healthy captures as
  # "STALLED? log 10m old".
  log="$RPOINT_IMAGES/chain-$inst/chain.log"
  [ -f "$log" ] || log=$(ls -t "$RPOINT_IMAGES/chain-$inst"/*.log 2>/dev/null | head -1)
  age="-"
  [ -n "$log" ] && [ -f "$log" ] && age=$(( ( $(date +%s) - $(stat -c %Y "$log") ) / 60 ))

  verdict=ok
  # A guest that accrued no CPU over the sample window is the gin signature.
  case "$guestcpu" in
    0t) verdict="STALLED? guest idle ${SAMPLE}s" ;;
    gone) verdict="guest vanished mid-phase" ;;
  esac
  # Log age alone is NOT a stall: a TCG profile pass legitimately writes nothing
  # for an hour while the guest burns CPU. Only a quiet log AND an idle guest.
  if [ "$age" != "-" ] && [ "$age" -ge "$STALE" ] && [ "$guestcpu" = "no-guest" ]; then
    verdict="STALLED? no guest and log ${age}m old"
  fi

  printf '%-34s %-10s %8s %9s %10s  %s\n' "$inst" "$phase" "$pid" "$guestcpu" "${age}m" "$verdict"
# run_capture_chain.sh must be matched too. Without it, a chain BETWEEN phases
# (verify finished, profile's guest not yet booted) has no capture_agentic
# process and was reported as having DIED SILENTLY -- a false alarm on a healthy
# run, which is the fastest way to make a watchdog worth ignoring.
# The bracket idiom, NOT `grep -v grep`. A grep pattern like `[r]un_...` cannot
# match grep's own command line, so no self-exclusion filter is needed -- and
# `grep -v grep` was actively harmful here: it drops every line containing the
# substring "grep", which includes every process working on burntsushi__RIPGREP
# -2209. That instance was silently deleted from every listing, and it was
# diagnosed as dead twice on the strength of its absence.
done < <(ps -eo pid,cmd 2>/dev/null \
         | grep -E '[r]un_capture_chain\.sh|[c]apture_agentic\.sh|[p]rovision_instance\.sh')

# Logs whose process is gone: the silent-death case. A log that never reached a
# terminal marker means nobody was told it ended.
for log in "$LOGDIR"/{verify,prov,chain}_*.log; do
  [ -f "$log" ] || continue
  inst=$(basename "$log" | sed -E 's/^(verify|prov|chain)_//; s/\.log$//')
  is_instance "$inst" || continue
  case " $seen " in *" $inst:"*) continue ;; esac
  if grep -qE 'chain complete|PROVISIONED |EXIT=0' "$log" 2>/dev/null; then
    state="done"
  elif grep -qE '\[FAIL\]|EXIT=[1-9]' "$log" 2>/dev/null; then
    state="FAILED (marker present)"
  else
    state="DIED SILENTLY -- no terminal marker, no process"
  fi
  age=$(( ( $(date +%s) - $(stat -c %Y "$log") ) / 60 ))
  printf '%-34s %-10s %8s %9s %10s  %s\n' "$inst" "-" "-" "-" "${age}m" "$state"
done
