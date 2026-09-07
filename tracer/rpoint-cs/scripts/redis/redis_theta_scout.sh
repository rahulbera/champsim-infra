#!/bin/bash
# One theta: restore rd_redis_b under TCG, restart the client at that theta,
# verify serving, arm, capture a 100M window, quit.
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
TH=$1
OUT=$W/traces/redis_theta_$TH
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f "$W/run/redis_trace_start"
tmux kill-session -t redistcg 2>/dev/null || true
tmux new -d -s redistcg "MODE=capture SLEN=100000000 SGAP=50000000 SCOUNT=1 OUT=$OUT bash $SROOT/redis/launch_tcg_redis.sh > $W/logs/redis-theta-$TH.log 2>&1"
G="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -i $HOME/.ssh/id_ed25519 -p 2225 ubuntu@127.0.0.1"
for i in $(seq 1 20); do $G true 2>/dev/null && break; sleep 10; done
# swap the client to this theta
$G "tmux kill-session -t client 2>/dev/null || true
    for p in \$(pgrep -f memtier_benchmark); do kill \$p 2>/dev/null || true; done
    sleep 3
    tmux new -d -s client 'taskset -c 3,4,5 memtier_benchmark -s 127.0.0.1 -p 6379 -P redis \
      --key-prefix=memtier- --key-minimum=1 --key-maximum=8000000 \
      --key-pattern=Z:Z --key-zipf-exp=$TH --ratio=1:16 --multi-key-get=16 \
      --data-size=512 --pipeline=1 --threads=2 --clients=8 --test-time=100000 --hide-histogram > ~/client_t$TH.log 2>&1'" 2>/dev/null
sleep 60
a=$($G 'redis-cli info stats | awk -F: "/keyspace_hits/{print \$2}" | tr -d "\r"' 2>/dev/null)
sleep 20
b=$($G 'redis-cli info stats | awk -F: "/keyspace_hits/{print \$2}" | tr -d "\r"' 2>/dev/null)
echo "  theta=$TH serving: hits $a -> $b"
touch "$W/run/redis_trace_start"
for i in $(seq 1 30); do
  n=$(grep -c '^[0-9]' "$OUT/trace_vcpu1_manifest.txt" 2>/dev/null || true)
  case "${n:-0}" in ''|0) : ;; *) break ;; esac
  sleep 15
done
python3 /tmp/hmp.py "$W/run/monitor-redis-tcg.sock" "quit" >/dev/null 2>&1 || true
sleep 5
echo "  theta=$TH captured: $(cat $OUT/trace_vcpu1_manifest.txt 2>/dev/null | tail -1)"
