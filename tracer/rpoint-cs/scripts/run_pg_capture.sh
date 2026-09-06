#!/bin/bash
set -u
W=$HOME/work/new-tracing
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
Q=${Q:?}; SNAP=${SNAP:?}; SGAP=${SGAP:?}; NW=${NW:-3}
{
  rm -rf $W/traces/pg_q$Q; mkdir -p $W/traces/pg_q$Q
  rm -f $W/run/pg_trace_start $W/logs/pg-tcg-qemu.log
  tmux kill-session -t pgtcg 2>/dev/null
  tmux new -d -s pgtcg "MODE=capture SNAP=$SNAP OUT=$W/traces/pg_q$Q TRIG=$W/run/pg_trace_start SLEN=1000000000 SGAP=$SGAP SCOUNT=$NW $W/launch_tcg_pg.sh"
  date -u '+%H:%M:%SZ capture launched'
  sleep 20
  pgrep -f 'qemu-system-x86_64.*pg-guest' >/dev/null || { echo "QEMU DIED:"; tail -5 $W/logs/pg-tcg-qemu.log; exit 1; }
  echo "qemu alive"
  until timeout 40 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ guest up'
  J=$(timeout 60 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 "sudo -u postgres psql -tAd tpch -c \"select pid from pg_stat_activity where query like '%LOOP%' and pid <> pg_backend_pid() limit 1\"" 2>/dev/null | tr -d ' \r')
  M=$(timeout 60 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 "taskset -p $J 2>/dev/null | grep -oE '[0-9a-f]+\$'" 2>/dev/null | tr -d ' \r')
  echo "backend=$J mask=$M"
  sleep 40
  date -u '+%H:%M:%SZ arming capture trigger'; touch $W/run/pg_trace_start
  until [ "$( grep -vc '^#' "$W/traces/pg_q$Q/trace_vcpu1_manifest.txt" 2>/dev/null | head -1 )" -ge "$NW" ] 2>/dev/null; do sleep 30; done
  date -u "+%H:%M:%SZ ALL $NW WINDOWS WRITTEN"
  cat "$W/traces/pg_q$Q/trace_vcpu1_manifest.txt"
  timeout 400 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py $W/run/monitor-pg-tcg.sock "quit" >/dev/null 2>&1
  echo "DONE"
} >> "$W/logs/pg_capture_q$Q.log" 2>&1
