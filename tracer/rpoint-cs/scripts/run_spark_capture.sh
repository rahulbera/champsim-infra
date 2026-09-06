#!/bin/bash
set -u
W=$HOME/work/new-tracing
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
{
  until timeout 40 ssh -n $SSHOPT -p 2233 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ guest up'
  echo "pin: $($W/guestpin.sh 2233)"
  sleep 40
  date -u '+%H:%M:%SZ arming capture trigger'
  touch "$W/run/spark_trace_start"
  until [ "$( grep -vc "^#" "$W/traces/spark_v1/trace_vcpu1_manifest.txt" 2>/dev/null | head -1 )" -ge 3 ] 2>/dev/null; do sleep 30; done
  date -u '+%H:%M:%SZ ALL 3 WINDOWS WRITTEN'
  cat "$W/traces/spark_v1/trace_vcpu1_manifest.txt"
  timeout 400 python3 "$W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py" "$W/run/monitor-spark-tcg.sock" "quit" >/dev/null 2>&1
  echo "DONE"
} >> "$W/logs/spark_capture_run.log" 2>&1
