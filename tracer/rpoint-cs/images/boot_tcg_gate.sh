#!/bin/bash
# Image: IMG=<file>. SSH forward: SSH_PORT=<n>. Trigger file: TRIGGER=<path>.
# All three are per-capture so several captures can run concurrently.
# TCG boot for the flakiness gate. Same CPU model we will use for the traced
# pass, so the guest kernel picks the same mitigations and the branch mix in
# kernel code is comparable.
cd "${RPOINT_IMAGES:-/home/rbera/work/bpeval/qemu-tracing/images}"
exec "${RPOINT_QEMU:-/home/rbera/qemu-custom/bin/qemu-system-x86_64}" \
  -accel tcg -cpu qemu64 -smp 4 -m 8G \
  -drive file=${IMG:-swe-agent-guest.qcow2},format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT:-2223}-:22 \
  ${PIDFILE:+-pidfile "$PIDFILE"} \
  -nographic -no-reboot -serial mon:stdio
