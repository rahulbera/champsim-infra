#!/bin/bash
set -u
W=$HOME/work/new-tracing
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
SECS=${SECS:-600}
{
  date -u '+%H:%M:%SZ stopping KVM guest'
  timeout 200 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py $W/run/monitor-tomcat.sock "quit" >/dev/null 2>&1
  sleep 6; tmux kill-session -t tomcatvm 2>/dev/null
  rm -rf $W/traces/tomcat_profile; mkdir -p $W/traces/tomcat_profile
  rm -f $W/run/tomcat_trace_start $W/logs/tomcat-tcg-qemu.log
  tmux new -d -s tomcattcg "MODE=profile SNAP=dc_tomcat_a OUT=$W/traces/tomcat_profile TRIG=$W/run/tomcat_trace_start $W/launch_tcg_tomcat.sh"
  date -u '+%H:%M:%SZ TCG profile launched'
  until timeout 40 ssh -n $SSHOPT -p 2231 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 10; done
  date -u '+%H:%M:%SZ TCG guest up'
  echo "pin after restore: $($W/guestpin.sh 2231)"
  sleep 30
  date -u '+%H:%M:%SZ arming trigger'
  touch $W/run/tomcat_trace_start
  sleep 15; grep -a 'ENABLED' $W/logs/tomcat-tcg-qemu.log | tail -1
  date -u "+%H:%M:%SZ profiling ${SECS}s"
  sleep "$SECS"
  date -u '+%H:%M:%SZ stopping'
  timeout 400 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py $W/run/monitor-tomcat-tcg.sock "quit" >/dev/null 2>&1
  sleep 10
  echo "=== TOMCAT PROFILE ==="; grep -a 'PROFILE:' $W/logs/tomcat-tcg-qemu.log | tail -1
  echo "DONE"
} >> "$W/logs/tomcat_profile_run.log" 2>&1
