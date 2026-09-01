# paths.sh -- single source of truth for where the large, un-versioned things live.
#
# Guest images, the QEMU tracing plugin and the converter are multi-gigabyte
# build products and deliberately live OUTSIDE this repo. Before this file
# existed, every driver derived them from its own location ($ROOT/images) while
# the boot scripts hardcoded an absolute path -- so a capture launched from the
# checkout resolved image paths in one tree and QEMU opened them in another.
# The drivers then `cd "$IMAGES"` and the boot script's own `cd` silently
# overrode it. Nothing failed loudly; you got a trace of the wrong guest.
#
# Override any of these in the environment to relocate. Defaults are this host's.
#
# NOTE: images/boot_*.sh repeat these defaults inline rather than sourcing this
# file, because they are invoked standalone from an arbitrary cwd. If you change
# a default here, change it there too -- the boot scripts are the other half of
# the contract.

: "${RPOINT_IMAGES:=/home/rbera/work/bpeval/qemu-tracing/images}"
: "${RPOINT_PLUGIN:=/home/rbera/work/bpeval/qemu-tracing/plugin/champsim_tracer.so}"
: "${RPOINT_CONVERTER:=/home/rbera/work/bpeval/qemu-tracing/converter/raw2champsim}"
: "${RPOINT_QEMU:=/home/rbera/qemu-custom/bin/qemu-system-x86_64}"

export RPOINT_IMAGES RPOINT_PLUGIN RPOINT_CONVERTER RPOINT_QEMU
