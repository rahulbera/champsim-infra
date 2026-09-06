#!/bin/bash
set -u
W=$HOME/work/new-tracing
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"
{
  # wait until we are mid-iteration (20-80%), not at a boundary, so the snapshot
  # sits in steady state rather than in DaCapo's per-iteration bookkeeping
  echo "waiting for a mid-iteration point..."
  for i in $(seq 1 120); do
    P=$(timeout 40 ssh -n $SSHOPT -p 2230 ubuntu@127.0.0.1 'tail -c 200 /home/ubuntu/tomcat.log' 2>/dev/null \
        | grep -oE '[0-9]+%' | tail -1 | tr -d '%')
    case "${P:-x}" in ''|*[!0-9]*) sleep 20; continue;; esac
    if [ "$P" -ge 20 ] && [ "$P" -le 80 ]; then echo "at ${P}% of an iteration — snapshotting"; break; fi
    sleep 20
  done
  # verify the pin one last time before committing the snapshot
  echo "pin: $($W/guestpin.sh 2230)"
  date -u '+%H:%M:%SZ savevm dc_tomcat_a start'
  timeout 1700 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py \
      $W/run/monitor-tomcat.sock "savevm dc_tomcat_a" >/dev/null 2>&1
  date -u '+%H:%M:%SZ savevm done'
  timeout 200 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py \
      $W/run/monitor-tomcat.sock "info snapshots" "info status" 2>&1 \
      | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -aE 'TAG|dc_tomcat|VM status'
  echo "DONE"
} >> "$W/logs/tomcat_snap_run.log" 2>&1
