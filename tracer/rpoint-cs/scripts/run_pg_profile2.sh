#!/bin/bash
set -u
W=$HOME/work/new-tracing
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
Q=${Q:?}; SNAP=${SNAP:?}; SECS=${SECS:-600}
{
  rm -rf $W/traces/pg_profile; mkdir -p $W/traces/pg_profile
  rm -f $W/run/pg_trace_start
  tmux kill-session -t pgtcg 2>/dev/null
  tmux new -d -s pgtcg "MODE=profile SNAP=$SNAP OUT=$W/traces/pg_profile TRIG=$W/run/pg_trace_start $W/launch_tcg_pg.sh"
  date -u '+%H:%M:%SZ TCG profile launched'
  # fail fast and loudly if QEMU dies at startup instead of waiting 40 min on ssh
  sleep 20
  if ! pgrep -f 'qemu-system-x86_64.*pg-guest' >/dev/null; then
    echo "QEMU DIED AT STARTUP:"; tail -5 $W/logs/pg-tcg-qemu.log; exit 1
  fi
  echo "qemu alive"
  until timeout 40 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ TCG guest up'
  J=$(timeout 60 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 "sudo -u postgres psql -tAd tpch -c \"select pid from pg_stat_activity where query like '%LOOP%' and pid <> pg_backend_pid() limit 1\"" 2>/dev/null | tr -d ' \r')
  M=$(timeout 60 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 "taskset -p $J 2>/dev/null | grep -oE '[0-9a-f]+\$'" 2>/dev/null | tr -d ' \r')
  echo "backend after restore=$J mask=$M"
  sleep 30
  date -u '+%H:%M:%SZ arming trigger'; touch $W/run/pg_trace_start
  sleep 15; grep -a 'ENABLED' $W/logs/pg-tcg-qemu.log | tail -1
  date -u "+%H:%M:%SZ profiling ${SECS}s"; sleep "$SECS"
  date -u '+%H:%M:%SZ stopping'
  timeout 400 python3 $W/champsim-infra/tracer/rpoint-cs/scripts/hmp.py $W/run/monitor-pg-tcg.sock "quit" >/dev/null 2>&1
  sleep 10
  echo "=== PROFILE Q$Q ==="; grep -a 'PROFILE:' $W/logs/pg-tcg-qemu.log | tail -1
  echo "DONE"
} >> "$W/logs/pg_profile_q$Q.log" 2>&1
