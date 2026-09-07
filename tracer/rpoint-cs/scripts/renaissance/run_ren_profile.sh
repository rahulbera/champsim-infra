#!/bin/bash
# TCG profile for a Renaissance benchmark restored from a KVM snapshot.
# Generic over BENCH; the guest, ports and monitors are the java/spark guest's.
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
BENCH=${BENCH:?set BENCH}; SNAP=${SNAP:?set SNAP}; SECS=${SECS:-600}
{
  date -u '+%H:%M:%SZ stopping KVM guest'
  timeout 200 python3 $COMMON/hmp.py $W/run/monitor-spark.sock "quit" >/dev/null 2>&1
  sleep 6; tmux kill-session -t sparkvm 2>/dev/null
  rm -rf $W/traces/${BENCH}_profile; mkdir -p $W/traces/${BENCH}_profile
  rm -f $W/run/spark_trace_start $W/logs/spark-tcg-qemu.log
  tmux new -d -s sparktcg "MODE=profile SNAP=$SNAP OUT=$W/traces/${BENCH}_profile TRIG=$W/run/spark_trace_start $SROOT/renaissance/launch_tcg_spark.sh"
  date -u '+%H:%M:%SZ TCG profile launched'
  sleep 20
  pgrep -f 'qemu-system-x86_64 -name java8g-guest-tcg' >/dev/null || { echo "QEMU DIED:"; tail -5 $W/logs/spark-tcg-qemu.log; exit 1; }
  until timeout 40 ssh -n $SSHOPT -p 2233 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ TCG guest up'
  echo "pin after restore: $($COMMON/guestpin.sh 2233 renaissance)"
  sleep 30
  date -u '+%H:%M:%SZ arming trigger'
  touch $W/run/spark_trace_start
  sleep 15; grep -a 'ENABLED' $W/logs/spark-tcg-qemu.log | tail -1
  date -u "+%H:%M:%SZ profiling ${SECS}s"
  sleep "$SECS"
  date -u '+%H:%M:%SZ stopping'
  timeout 400 python3 $COMMON/hmp.py $W/run/monitor-spark-tcg.sock "quit" >/dev/null 2>&1
  sleep 10
  echo "=== PROFILE $BENCH ==="; grep -a 'PROFILE:' $W/logs/spark-tcg-qemu.log | tail -1
  echo "DONE"
} >> "$W/logs/ren_profile_$BENCH.log" 2>&1
