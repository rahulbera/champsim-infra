#!/bin/bash
set -eu
. "$HOME/work/new-tracing/cpustr.sh"
MODE=${MODE:-profile}
OUT=${OUT:-$HOME/work/new-tracing/traces/mongo_pilot}
PLUGIN=$HOME/work/new-tracing/champsim-infra/tracer/rpoint-cs/plugin/champsim_tracer.so
TRIG=$HOME/work/new-tracing/run/mongo_trace_start
mkdir -p "$OUT"; rm -f "$TRIG"
if [ "$MODE" = profile ]; then PARGS="outdir=$OUT,vcpus=1,profile=on"
else PARGS="outdir=$OUT,vcpus=1,sample_len=${SLEN},sample_gap=${SGAP},sample_count=${SCOUNT:-5},sample_clock=user,trigger=$TRIG,capture_pa=on,values=on"; fi
cd "$IMAGES"
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name mongo-guest-tcg -machine q35,accel=tcg -cpu "$CPUSTR" -smp 6 -m 12G \
  -drive file=mongo-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-trace.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2227-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$HOME/work/new-tracing/run/monitor-mongo-tcg.sock",server,nowait \
  -plugin "$PLUGIN,$PARGS" -loadvm mg_v1_a \
  -nographic -serial file:"$HOME/work/new-tracing/logs/mongo-tcg-console.log"
