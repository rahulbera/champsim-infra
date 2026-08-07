#!/bin/bash
# Image: IMG=<file>. SSH forward: SSH_PORT=<n>. Trigger file: TRIGGER=<path>.
# All three are per-capture so several captures can run concurrently.
# Pass 3 boot under TCG with the tracing plugin.
#   $1 = outdir   $2 = extra plugin args (e.g. ",profile=on" or sampling knobs)
# -cpu qemu64 must match the flakiness-gate run: CPUID drives the guest kernel's
# spectre-mitigation selection, which changes the kernel branch mix.
set -u
OUT="$1"; EXTRA="${2:-}"
cd /home/rbera/work/bpeval/qemu-tracing/images
mkdir -p "$OUT"; rm -f "$OUT"/trace_vcpu*.raw.zst "$OUT"/*manifest.txt
exec /home/rbera/qemu-custom/bin/qemu-system-x86_64 \
  -accel tcg -cpu max -smp 4 -m 8G \
  -drive file=${IMG:-swe-agent-guest.qcow2},format=qcow2,if=virtio,cache=unsafe \
  -nic user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT:-2223}-:22 \
  ${PIDFILE:+-pidfile "$PIDFILE"} \
  -nographic -no-reboot -serial mon:stdio \
  -plugin "/home/rbera/work/bpeval/qemu-tracing/plugin/champsim_tracer.so,outdir=$OUT,vcpus=1,trigger=${TRIGGER:-/tmp/swe_roi_trigger}$EXTRA"
