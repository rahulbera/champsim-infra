#!/bin/bash
# Image: IMG=<file>. SSH forward: SSH_PORT=<n>. Trigger file: TRIGGER=<path>.
# All three are per-capture so several captures can run concurrently.
# Build-pass boot: KVM, network UP, seed attached. NOT the traced configuration.
cd "${RPOINT_IMAGES:-/home/rbera/work/bpeval/qemu-tracing/images}"
exec "${RPOINT_QEMU:-/home/rbera/qemu-custom/bin/qemu-system-x86_64}" \
  -accel kvm -cpu host -smp 4 -m 8G \
  -drive file=${IMG:-swe-agent-guest.qcow2},format=qcow2,if=virtio \
  -drive file=seed.iso,format=raw,if=virtio,readonly=on \
  -nic user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT:-2222}-:22 \
  ${PIDFILE:+-pidfile "$PIDFILE"} \
  -nographic -serial mon:stdio
