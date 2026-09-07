#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25"
Q=${Q:?set Q}; SNAP=${SNAP:?set SNAP}; SECS=${SECS:-600}
{
  date -u '+%H:%M:%SZ stopping KVM guest'
  timeout 200 python3 $COMMON/hmp.py $W/run/monitor-pg.sock "quit" >/dev/null 2>&1
  sleep 6; tmux kill-session -t pgvm 2>/dev/null
  rm -rf $W/traces/pg_profile; mkdir -p $W/traces/pg_profile
  rm -f $W/run/pg_trace_start $W/logs/pg-tcg-qemu.log
  tmux new -d -s pgtcg "MODE=profile SNAP=$SNAP OUT=$W/traces/pg_profile TRIG=$W/run/pg_trace_start $SROOT/postgres/launch_tcg_pg.sh"
  date -u '+%H:%M:%SZ TCG profile launched'
  until timeout 40 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 'true' 2>/dev/null; do sleep 12; done
  date -u '+%H:%M:%SZ TCG guest up'
  J=$(timeout 60 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 "sudo -u postgres psql -tAd tpch -c \"select pid from pg_stat_activity where query like '%LOOP%' and pid <> pg_backend_pid() limit 1\"" 2>/dev/null | tr -d ' \r')
  echo "backend after restore=$J mask=$(timeout 60 ssh -n $SSHOPT -p 2235 ubuntu@127.0.0.1 "taskset -p $J 2>/dev/null | grep -oE '[0-9a-f]+\$'" 2>/dev/null)"
  sleep 30
  date -u '+%H:%M:%SZ arming trigger'
  touch $W/run/pg_trace_start
  sleep 15; grep -a 'ENABLED' $W/logs/pg-tcg-qemu.log | tail -1
  date -u "+%H:%M:%SZ profiling ${SECS}s"
  sleep "$SECS"
  date -u '+%H:%M:%SZ stopping'
  timeout 400 python3 $COMMON/hmp.py $W/run/monitor-pg-tcg.sock "quit" >/dev/null 2>&1
  sleep 10
  echo "=== PROFILE Q$Q ==="; grep -a 'PROFILE:' $W/logs/pg-tcg-qemu.log | tail -1
  echo "DONE"
} >> "$W/logs/pg_profile_q$Q.log" 2>&1
