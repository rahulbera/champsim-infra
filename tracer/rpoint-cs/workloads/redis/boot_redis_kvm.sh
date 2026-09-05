#!/bin/bash
set -eu
. "$HOME/work/new-tracing/cpustr.sh"
cd "$IMAGES"
rm -f "$HOME/work/new-tracing/run/monitor-redis.sock"
# cores 10-31 for the guest; 0-9 belong to the RocksDB converters
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name redis-guest \
  -machine q35,accel=kvm -cpu "$CPUSTR" -smp 6 -m 12G \
  -drive file=redis-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-trace.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2224-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$HOME/work/new-tracing/run/monitor-redis.sock",server,nowait \
  -nographic -serial null
