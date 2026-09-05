#!/bin/bash
# Boot the DaCapo/Spark Java guest under KVM (native speed).
# Everything except the capture itself runs under KVM.
set -eu
. "$HOME/work/new-tracing/cpustr.sh"
cd "$IMAGES"
rm -f "$HOME/work/new-tracing/run/monitor-java.sock"
mkdir -p "$HOME/work/new-tracing/run"
# cores 10-31 for the guest; 0-9 belong to the converters
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name java-guest \
  -machine q35,accel=kvm -cpu "$CPUSTR" -smp 4 -m 24G \
  -drive file=java-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-java.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2226-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$HOME/work/new-tracing/run/monitor-java.sock",server,nowait \
  -nographic -serial file:"$HOME/work/new-tracing/logs/java-console.log"
