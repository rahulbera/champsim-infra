#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"
{
  echo "waiting for >=200 iterations (deep steady state) ..."
  for i in $(seq 1 240); do
    N=$( timeout 40 ssh -n $SSHOPT -p 2232 ubuntu@127.0.0.1 'grep -ac "iteration .* completed" /home/ubuntu/spark_pagerank.log' 2>/dev/null | head -1 )
    case "${N:-x}" in ''|*[!0-9]*) sleep 20; continue;; esac
    [ "$N" -ge 200 ] && { echo "at iteration $N — snapshotting"; break; }
    sleep 20
  done
  echo "pin before snapshot: $($COMMON/guestpin.sh 2232)"
  date -u '+%H:%M:%SZ savevm dc_spark_a start'
  timeout 1700 python3 $COMMON/hmp.py \
      $W/run/monitor-spark.sock "savevm dc_spark_a" >/dev/null 2>&1
  date -u '+%H:%M:%SZ savevm done'
  timeout 200 python3 $COMMON/hmp.py \
      $W/run/monitor-spark.sock "info snapshots" "info status" 2>&1 \
      | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -aE 'TAG|dc_spark|VM status'
  echo "DONE"
} >> "$W/logs/spark_snap_run.log" 2>&1
