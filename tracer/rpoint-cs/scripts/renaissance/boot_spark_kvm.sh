#!/bin/bash
# Boot the Java guest COLD under KVM with 8 GB, for kafka/tomcat.
# -m 12G not 24G: savevm serialises all TOUCHED guest RAM regardless of how much
# the guest is actually using, so the 24 GB guest cost a 23.6 GiB snapshot for a
# workload whose live set is ~2 GB. Guest RAM SIZE is what savevm costs.
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
cd "$IMAGES"
rm -f "$W/run/monitor-spark.sock"
mkdir -p "$W/run"
QLOG=${QLOG:-$W/logs/spark-kvm-qemu.log}
exec 2> >(tee -a "$QLOG" >&2)
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name spark-guest \
  -machine q35,accel=kvm -cpu "$CPUSTR" -smp 4 -m 12G \
  -drive file=spark-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-java.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2232-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$W/run/monitor-spark.sock",server,nowait \
  -nographic -serial file:"$W/logs/spark-console.log" < /dev/null
