#!/bin/bash
# Boot the Java guest COLD under KVM with 8 GB, for kafka/tomcat.
# -m 8G not 24G: savevm serialises all TOUCHED guest RAM regardless of how much
# the guest is actually using, so the 24 GB guest cost a 23.6 GiB snapshot for a
# workload whose live set is ~2 GB. Guest RAM SIZE is what savevm costs.
set -eu
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
cd "$IMAGES"
rm -f "$W/run/monitor-tomcat.sock"
mkdir -p "$W/run"
QLOG=${QLOG:-$W/logs/tomcat-kvm-qemu.log}
exec 2> >(tee -a "$QLOG" >&2)
exec taskset -c 10-31 "$QEMU_FIXED" \
  -name tomcat-guest \
  -machine q35,accel=kvm -cpu "$CPUSTR" -smp 4 -m 8G \
  -drive file=tomcat-guest.qcow2,if=virtio,format=qcow2,cache=none,aio=io_uring \
  -drive file=seed-java.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2230-:22 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$W/run/monitor-tomcat.sock",server,nowait \
  -nographic -serial file:"$W/logs/tomcat-console.log" < /dev/null
