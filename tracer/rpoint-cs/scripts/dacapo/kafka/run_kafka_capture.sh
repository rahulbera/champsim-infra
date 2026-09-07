#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
{
  until timeout 40 ssh -n $SSHOPT -p 2229 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ guest up'
  timeout 110 ssh -n $SSHOPT -p 2229 ubuntu@127.0.0.1 'J=1102; echo "aff=$(taskset -p $J 2>/dev/null|grep -oE "[0-9a-f]+$") threads=$(ls /proc/$J/task|wc -l) unpinned=$(for t in /proc/$J/task/*; do tid=${t##*/}; taskset -p $tid 2>/dev/null|grep -oE "[0-9a-f]+$"; done|grep -vc "^2$")"' 2>&1 | grep -vi '^warning'
  sleep 40
  date -u '+%H:%M:%SZ arming capture trigger'
  touch "$W/run/kafka_trace_start"
  # wait for all three manifest rows
  until [ "$(grep -vc '^#' "$W/traces/kafka_v1/trace_vcpu1_manifest.txt" 2>/dev/null)" -ge 3 ]; do sleep 30; done
  date -u '+%H:%M:%SZ ALL 3 WINDOWS WRITTEN'
  cat "$W/traces/kafka_v1/trace_vcpu1_manifest.txt"
  timeout 400 python3 "$COMMON/hmp.py" "$W/run/monitor-java8g-tcg.sock" "quit" >/dev/null 2>&1
  echo "DONE"
} >> "$W/logs/kafka_capture_run.log" 2>&1
