#!/bin/bash
# PostgreSQL / TPC-H guest under KVM.
# -m 12G: savevm serialises every TOUCHED guest page, so guest RAM SIZE caps the
# snapshot cost. 12G leaves room for shared_buffers=2G plus a large page cache
# without the 23.6 GiB snapshots the 24 GB java guest produced.
# `< /dev/null` on the exec: without it a stray Ctrl+D in an attached tmux pane
# kills the guest (it did, at 01:30Z on 2026-09-06).
set -eu
. "$HOME/work/new-tracing/cpustr.sh"
cd "$IMAGES"
rm -f "$HOME/work/new-tracing/run/monitor-pg.sock"
mkdir -p "$HOME/work/new-tracing/run"
QLOG=${QLOG:-$HOME/work/new-tracing/logs/pg-kvm-qemu.log}
exec 2> >(tee -a "$QLOG" >&2)
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name pg-guest \
  -machine q35,accel=kvm -cpu "$CPUSTR" -smp 4 -m 12G \
  -drive file=pg-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-pg.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2234-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$HOME/work/new-tracing/run/monitor-pg.sock",server,nowait \
  -nographic -serial file:"$HOME/work/new-tracing/logs/pg-console.log" < /dev/null
