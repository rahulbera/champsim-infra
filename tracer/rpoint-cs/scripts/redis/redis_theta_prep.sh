#!/bin/bash
# Under KVM (native speed): restore rd_redis_b, swap the client to theta, verify
# serving, and snapshot under a NEW tag. TCG then only has to capture.
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
. "$COMMON/cpustr.sh"
TH=$1; TAG=$2
cd "$W/images"
rm -f "$W/run/monitor-redis.sock"
tmux kill-session -t redisvm 2>/dev/null || true
tmux new -d -s redisvm "taskset -c 10-31 $QEMU_FIXED -name redis-guest \
  -machine q35,accel=kvm -cpu '$CPUSTR' -smp 6 -m 12G \
  -drive file=redis-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-trace.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2224-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:$W/run/monitor-redis.sock,server,nowait \
  -loadvm rd_redis_b -nographic -serial null"
G="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -i $HOME/.ssh/id_ed25519 -p 2224 ubuntu@127.0.0.1"
for i in $(seq 1 40); do $G true 2>/dev/null && break; sleep 5; done
$G "tmux kill-session -t client 2>/dev/null || true
    for p in \$(pgrep -f memtier_benchmark); do kill \$p 2>/dev/null || true; done
    sleep 3
    tmux new -d -s client 'taskset -c 3,4,5 memtier_benchmark -s 127.0.0.1 -p 6379 -P redis \
      --key-prefix=memtier- --key-minimum=1 --key-maximum=8000000 \
      --key-pattern=Z:Z --key-zipf-exp=$TH --ratio=1:16 --multi-key-get=16 \
      --data-size=512 --pipeline=1 --threads=2 --clients=8 --test-time=100000 --hide-histogram > ~/c_$TH.log 2>&1'"
sleep 45
a=$($G 'redis-cli info stats | awk -F: "/keyspace_hits/{print \$2}" | tr -d "\r"')
sleep 15
b=$($G 'redis-cli info stats | awk -F: "/keyspace_hits/{print \$2}" | tr -d "\r"')
echo "  theta=$TH hits $a -> $b  (delta $((b-a)))"
python3 /tmp/hmp.py "$W/run/monitor-redis.sock" "savevm $TAG" >/dev/null 2>&1
echo "  snapshot $TAG taken"
for p in $(pgrep qemu 2>/dev/null); do cl=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null); case "$cl" in *redis-guest*) kill "$p" ;; esac; done
tmux kill-session -t redisvm 2>/dev/null || true
sleep 5
