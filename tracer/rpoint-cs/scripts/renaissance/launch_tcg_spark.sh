#!/bin/bash
# Restore the Java guest under TCG.  MODE=bare (J1 gate, no plugin),
# MODE=profile (derive the user/total split), MODE=capture (sampled windows).
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
MODE=${MODE:-bare}
SNAP=${SNAP:?set SNAP to the savevm tag}
OUT=${OUT:-$W/traces/spark_profile}
PLUGIN=$RPCS/plugin/champsim_tracer.so
TRIG=${TRIG:-$W/run/java_trace_start}
mkdir -p "$OUT" "$W/run"; rm -f "$TRIG"
case "$MODE" in
  bare)    PLUGARG=() ;;
  profile) PLUGARG=(-plugin "$PLUGIN,outdir=$OUT,vcpus=1,trigger=$TRIG,profile=on") ;;
  capture) PLUGARG=(-plugin "$PLUGIN,outdir=$OUT,vcpus=1,sample_len=${SLEN:?},sample_gap=${SGAP:?},sample_count=${SCOUNT:-3},sample_clock=user,trigger=$TRIG,capture_pa=on,values=on") ;;
  *) echo "unknown MODE=$MODE"; exit 1 ;;
esac
QLOG=${QLOG:-$W/logs/spark-tcg-qemu.log}
cd "$IMAGES"
# stderr carries the plugin banner and the exit-time PROFILE line; a tmux
# pane dies with QEMU and takes them with it. Keep a file copy.
exec 2> >(tee -a "$QLOG" >&2)
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name java8g-guest-tcg \
  -machine q35,accel=tcg -cpu "$CPUSTR" -smp 4 -m 12G \
  -drive file=spark-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-java.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2233-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$W/run/monitor-spark-tcg.sock",server,nowait \
  "${PLUGARG[@]}" -loadvm "$SNAP" \
  -nographic -serial file:"$W/logs/spark-tcg-console.log" < /dev/null
