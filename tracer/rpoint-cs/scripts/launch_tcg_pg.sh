#!/bin/bash
# PostgreSQL / TPC-H guest under KVM.
# -m 12G: savevm serialises every TOUCHED guest page, so guest RAM SIZE caps the
# snapshot cost. 12G leaves room for shared_buffers=2G plus a large page cache
# without the 23.6 GiB snapshots the 24 GB java guest produced.
# `< /dev/null` on the exec: without it a stray Ctrl+D in an attached tmux pane
# kills the guest (it did, at 01:30Z on 2026-09-06).
set -eu
. "$HOME/work/new-tracing/cpustr.sh"
MODE=${MODE:-bare}
SNAP=${SNAP:?set SNAP}
OUT=${OUT:-$HOME/work/new-tracing/traces/pg_profile}
TRIG=${TRIG:-$HOME/work/new-tracing/run/pg_trace_start}
PLUGIN=$HOME/work/new-tracing/champsim-infra/tracer/rpoint-cs/plugin/champsim_tracer.so
mkdir -p "$OUT" "$HOME/work/new-tracing/run"; rm -f "$TRIG"
case "$MODE" in
  bare)    PLUGARG=() ;;
  profile) PLUGARG=(-plugin "$PLUGIN,outdir=$OUT,vcpus=1,trigger=$TRIG,profile=on") ;;
  capture) PLUGARG=(-plugin "$PLUGIN,outdir=$OUT,vcpus=1,sample_len=${SLEN:?},sample_gap=${SGAP:?},sample_count=${SCOUNT:-3},sample_clock=user,trigger=$TRIG,capture_pa=on,values=on") ;;
  *) echo "unknown MODE=$MODE"; exit 1 ;;
esac
cd "$IMAGES"
rm -f "$HOME/work/new-tracing/run/monitor-pg-tcg.sock"
mkdir -p "$HOME/work/new-tracing/run"
QLOG=${QLOG:-$HOME/work/new-tracing/logs/pg-tcg-qemu.log}
exec 2> >(tee -a "$QLOG" >&2)
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name pg-guest-tcg \
  -machine q35,accel=tcg -cpu "$CPUSTR" -smp 4 -m 12G \
  -drive file=pg-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-pg.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2235-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$HOME/work/new-tracing/run/monitor-pg-tcg.sock",server,nowait \
  "${PLUGARG[@]}" -loadvm "$SNAP" \
  -nographic -serial file:"$HOME/work/new-tracing/logs/pg-tcg-console.log" < /dev/null
