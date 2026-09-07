#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
BENCH=${BENCH:?}; SNAP=${SNAP:?}; SGAP=${SGAP:?}; NW=${NW:-3}
{
  rm -rf $W/traces/ren_$BENCH; mkdir -p $W/traces/ren_$BENCH
  rm -f $W/run/spark_trace_start $W/logs/spark-tcg-qemu.log
  tmux kill-session -t sparktcg 2>/dev/null
  tmux new -d -s sparktcg "MODE=capture SNAP=$SNAP OUT=$W/traces/ren_$BENCH TRIG=$W/run/spark_trace_start SLEN=1000000000 SGAP=$SGAP SCOUNT=$NW $SROOT/renaissance/launch_tcg_spark.sh"
  date -u '+%H:%M:%SZ capture launched'
  sleep 20
  pgrep -f 'qemu-system-x86_64 -name java8g-guest-tcg' >/dev/null || { echo "QEMU DIED:"; tail -5 $W/logs/spark-tcg-qemu.log; exit 1; }
  echo "qemu alive"
  until timeout 40 ssh -n $SSHOPT -p 2233 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ guest up'
  echo "pin: $($COMMON/guestpin.sh 2233 renaissance)"
  sleep 40
  date -u '+%H:%M:%SZ arming capture trigger'; touch $W/run/spark_trace_start
  until [ "$( grep -vc '^#' "$W/traces/ren_$BENCH/trace_vcpu1_manifest.txt" 2>/dev/null | head -1 )" -ge "$NW" ] 2>/dev/null; do sleep 30; done
  date -u "+%H:%M:%SZ ALL $NW WINDOWS WRITTEN"
  cat "$W/traces/ren_$BENCH/trace_vcpu1_manifest.txt"
  timeout 400 python3 $COMMON/hmp.py $W/run/monitor-spark-tcg.sock "quit" >/dev/null 2>&1
  echo "DONE"
} >> "$W/logs/ren_capture_$BENCH.log" 2>&1
