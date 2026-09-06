#!/bin/bash
set -u
W=$HOME/work/new-tracing
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
{
  until timeout 40 ssh -n $SSHOPT -p 2231 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ guest up'
  echo "pin: $($W/guestpin.sh 2231)"
  sleep 40
  date -u '+%H:%M:%SZ arming capture trigger'
  touch "$W/run/tomcat_trace_start"
  until [ "$(grep -vc '^#' "$W/traces/tomcat_v1/trace_vcpu1_manifest.txt" 2>/dev/null)" -ge 3 ]; do sleep 30; done
  date -u '+%H:%M:%SZ ALL 3 WINDOWS WRITTEN'
  cat "$W/traces/tomcat_v1/trace_vcpu1_manifest.txt"
  timeout 400 python3 "$W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py" "$W/run/monitor-tomcat-tcg.sock" "quit" >/dev/null 2>&1
  sleep 8
  date -u '+%H:%M:%SZ launching conversion'
  tmux new -d -s tomcatconv "printf '%s\n' 00000 00001 00002 | xargs -P 3 -n 1 $W/convert_one_tomcat.sh 2>&1 | tee $W/logs/convert.tomcat_v1.log"
  echo "DONE"
} >> "$W/logs/tomcat_capture_run.log" 2>&1
