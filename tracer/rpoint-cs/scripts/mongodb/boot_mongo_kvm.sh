#!/bin/bash
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
cd "$IMAGES"
rm -f "$W/run/monitor-mongo.sock"
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name mongo-guest -machine q35,accel=kvm -cpu "$CPUSTR" -smp 6 -m 12G \
  -drive file=mongo-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-trace.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2226-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$W/run/monitor-mongo.sock",server,nowait \
  -nographic -serial null
