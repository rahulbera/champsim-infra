#!/bin/bash
set -u
W=$HOME/work/new-tracing
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
SECS=${SECS:-600}
{
  date -u '+%H:%M:%SZ stopping KVM guest'
  timeout 200 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py $W/run/monitor-spark.sock "quit" >/dev/null 2>&1
  sleep 6; tmux kill-session -t sparkvm 2>/dev/null
  rm -rf $W/traces/spark_profile; mkdir -p $W/traces/spark_profile
  rm -f $W/run/spark_trace_start $W/logs/spark-tcg-qemu.log
  tmux new -d -s sparktcg "MODE=profile SNAP=dc_spark_a OUT=$W/traces/spark_profile TRIG=$W/run/spark_trace_start $W/launch_tcg_spark.sh"
  date -u '+%H:%M:%SZ TCG profile launched'
  until timeout 40 ssh -n $SSHOPT -p 2233 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 10; done
  date -u '+%H:%M:%SZ TCG guest up'
  echo "pin after restore: $($W/guestpin.sh 2233)"
  sleep 30
  date -u '+%H:%M:%SZ arming trigger'
  touch $W/run/spark_trace_start
  sleep 15; grep -a 'ENABLED' $W/logs/spark-tcg-qemu.log | tail -1
  date -u "+%H:%M:%SZ profiling ${SECS}s"
  sleep "$SECS"
  date -u '+%H:%M:%SZ stopping'
  timeout 400 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py $W/run/monitor-spark-tcg.sock "quit" >/dev/null 2>&1
  sleep 10
  echo "=== SPARK PROFILE ==="; grep -a 'PROFILE:' $W/logs/spark-tcg-qemu.log | tail -1
  echo "DONE"
} >> "$W/logs/spark_profile_run.log" 2>&1
