#!/bin/bash
# Restore the KVM snapshot under TCG with the ChampSim tracer plugin.
# MODE=profile  -> profile=on, writes no trace files, reports total/user/kernel
# MODE=capture  -> windowed sampling
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
MODE=${MODE:-profile}
TAG=${TAG:-rd_v2_a}
OUT=${OUT:-$W/traces/profile}
PLUGIN=$RPCS/plugin/champsim_tracer.so
TRIG=$W/run/trace_start
mkdir -p "$OUT" "$(dirname "$TRIG")"
rm -f "$TRIG"
if [ "$MODE" = profile ]; then
  PARGS="outdir=$OUT,vcpus=1,profile=on"
else
  PARGS="outdir=$OUT,vcpus=1,sample_len=${SLEN},sample_gap=${SGAP},sample_count=${SCOUNT:-5},sample_clock=user,trigger=$TRIG,capture_pa=on,values=on"
fi
cd "$IMAGES"
exec "$QEMU_FIXED" \
  -name rocksdb-guest-tcg \
  -machine q35,accel=tcg -cpu "$CPUSTR" -smp 6 -m 8G \
  -drive file=rocksdb-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-trace.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2223-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$W/run/monitor-tcg.sock",server,nowait \
  -plugin "$PLUGIN,$PARGS" \
  -loadvm "$TAG" \
  -nographic -serial file:"$W/logs/tcg-console.log"
