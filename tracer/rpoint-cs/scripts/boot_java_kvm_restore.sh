#!/bin/bash
# Boot the Java guest under KVM, RESTORING a snapshot (so the JVM stays warm).
set -eu
. "$HOME/work/new-tracing/cpustr.sh"
SNAP=${SNAP:?set SNAP}
cd "$IMAGES"
rm -f "$HOME/work/new-tracing/run/monitor-java.sock"
mkdir -p "$HOME/work/new-tracing/run"
QLOG=${QLOG:-$HOME/work/new-tracing/logs/java-kvm-qemu.log}
exec 2> >(tee -a "$QLOG" >&2)
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name java-guest \
  -machine q35,accel=kvm -cpu "$CPUSTR" -smp 4 -m 24G \
  -drive file=java-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-java.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2226-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$HOME/work/new-tracing/run/monitor-java.sock",server,nowait \
  -loadvm "$SNAP" \
  -nographic -serial file:"$HOME/work/new-tracing/logs/java-console.log"
