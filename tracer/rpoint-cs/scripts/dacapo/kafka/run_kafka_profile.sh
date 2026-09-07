#!/bin/bash
# Arm the trigger, profile for a measured span, stop QEMU cleanly, print PROFILE.
# Detached via nohup/setsid so it survives the orchestrator losing its task slot.
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
SECS=${SECS:-600}
{
  date -u '+%H:%M:%SZ settling'
  sleep 30
  date -u '+%H:%M:%SZ arming trigger'
  touch "$W/run/kafka_trace_start"
  sleep 15
  grep -a 'ENABLED' "$W/logs/java8g-tcg-qemu.log" | tail -1
  date -u "+%H:%M:%SZ profiling for ${SECS}s"
  sleep "$SECS"
  date -u '+%H:%M:%SZ stopping'
  for p in $(pgrep -u "$(id -un)" . 2>/dev/null); do
    case "$(readlink /proc/$p/exe 2>/dev/null)" in
      *qemu-system-x86_64) tr '\0' ' ' < /proc/$p/cmdline | grep -q java8g && grep VmHWM /proc/$p/status ;;
    esac
  done
  timeout 400 python3 "$COMMON/hmp.py" "$W/run/monitor-java8g-tcg.sock" "quit" >/dev/null 2>&1
  sleep 10
  echo "=== KAFKA PROFILE ==="
  grep -a 'PROFILE:' "$W/logs/java8g-tcg-qemu.log" | tail -2
  echo "DONE"
} >> "$W/logs/kafka_profile_run.log" 2>&1
