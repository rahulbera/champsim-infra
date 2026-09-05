#!/bin/bash
# Restore the Java guest under TCG.  MODE=bare (J1 gate, no plugin),
# MODE=profile (derive the user/total split), MODE=capture (sampled windows).
set -eu
. "$HOME/work/new-tracing/cpustr.sh"
MODE=${MODE:-bare}
SNAP=${SNAP:?set SNAP to the savevm tag}
OUT=${OUT:-$HOME/work/new-tracing/traces/java_profile}
PLUGIN=$HOME/work/new-tracing/champsim-infra/tracer/rpoint-cs/plugin/champsim_tracer.so
TRIG=${TRIG:-$HOME/work/new-tracing/run/java_trace_start}
mkdir -p "$OUT" "$HOME/work/new-tracing/run"; rm -f "$TRIG"
case "$MODE" in
  bare)    PLUGARG=() ;;
  profile) PLUGARG=(-plugin "$PLUGIN,outdir=$OUT,vcpus=1,profile=on") ;;
  capture) PLUGARG=(-plugin "$PLUGIN,outdir=$OUT,vcpus=1,sample_len=${SLEN:?},sample_gap=${SGAP:?},sample_count=${SCOUNT:-3},sample_clock=user,trigger=$TRIG,capture_pa=on,values=on") ;;
  *) echo "unknown MODE=$MODE"; exit 1 ;;
esac
cd "$IMAGES"
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name java-guest-tcg \
  -machine q35,accel=tcg -cpu "$CPUSTR" -smp 4 -m 24G \
  -drive file=java-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-java.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2227-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$HOME/work/new-tracing/run/monitor-java-tcg.sock",server,nowait \
  "${PLUGARG[@]}" -loadvm "$SNAP" \
  -nographic -serial file:"$HOME/work/new-tracing/logs/java-tcg-console.log"
