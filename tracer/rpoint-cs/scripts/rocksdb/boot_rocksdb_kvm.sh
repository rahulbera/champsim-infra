#!/bin/bash
# Boot the RocksDB guest under KVM with a TCG-compatible CPU model.
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
cd "$IMAGES"
rm -f "$MON"
exec "$QEMU_FIXED" \
  -name rocksdb-guest \
  -machine q35,accel=kvm -cpu "$CPUSTR" -smp 6 -m 8G \
  -drive file=rocksdb-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-trace.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$MON",server,nowait \
  -nographic -serial null
