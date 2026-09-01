#!/usr/bin/env bash
#
# create_guest_image.sh <instance_id> — make the working qcow2 for one instance.
#
# This step had no script. provision_instance.sh:70 simply died with
#   "no image at $WORK -- create it with qemu-img first"
# and the incantation lived in somebody's shell history, which is why the August
# provisioning times (102-178 s) are too fast to be cold runs: images were almost
# certainly hand-copied from an already-provisioned sibling, undocumented. That
# is exactly the kind of silent variation that makes two captures incomparable.
#
# The image is a qcow2 OVERLAY on the shared Ubuntu cloud image, not a copy: the
# per-instance file holds only the delta (toolchain, repo, dependency cache,
# SWE-agent, venv), measured at 1.9-2.9 GB against a 0.58 GB shared base.
#
# The backing file is recorded as a BARE BASENAME, not an absolute path, so the
# whole images directory can be relocated as a unit and every chain still
# resolves. That is why qemu-img runs with cwd set to the images directory.
# Never pass an absolute -b path here.
#
set -euo pipefail

INSTANCE=${1:?usage: create_guest_image.sh <instance_id> [--force]}
FORCE=${2:-}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
IMAGES=$RPOINT_IMAGES

BASE=${BASE_IMAGE:-noble-server-cloudimg-amd64.img}
SEED=${SEED_ISO:-seed.iso}
SIZE=${GUEST_SIZE:-60G}
WORK=$IMAGES/guest-$INSTANCE.qcow2

die() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }
ok()  { printf '  [ok] %s\n' "$*"; }

[ -d "$IMAGES" ] || die "no images directory at $IMAGES (set RPOINT_IMAGES)"
[ -f "$IMAGES/$BASE" ] || die "no base image at $IMAGES/$BASE"
[ -r "$IMAGES/$BASE" ] || die "base image $BASE is not readable"

# The seed carries the ssh key, the tracevm user and -- load-bearing -- the GRUB
# drop-in that sets isolcpus. Without it the guest boots but provisioning fails
# later at the isolation assertion, having wasted a full boot.
[ -f "$IMAGES/$SEED" ] || die "no cloud-init seed at $IMAGES/$SEED"

# Refuse to clobber. A half-provisioned image looks exactly like a fresh one
# from the outside, and silently reusing one is how a capture ends up measuring
# a guest whose repo was already built.
if [ -f "$WORK" ] && [ "$FORCE" != "--force" ]; then
  die "$WORK already exists -- delete it or pass --force if you really mean to start over"
fi
rm -f "$WORK"

# Relative backing name: cwd must be the images directory. See the header.
( cd "$IMAGES" && qemu-img create -q -f qcow2 \
      -b "$BASE" -F qcow2 "guest-$INSTANCE.qcow2" "$SIZE" )

[ -f "$WORK" ] || die "qemu-img reported success but produced no image"

# A backing chain that does not resolve is the failure mode that hurts later,
# not now: qemu-img info returns 0 with a plausible-looking path even when the
# base is missing. Only --backing-chain actually walks it.
qemu-img info --backing-chain "$WORK" >/dev/null 2>&1 \
  || die "backing chain does not resolve -- is $BASE present and readable?"

ok "created $WORK"
printf '       virtual %s, overlay on %s (%s actual)\n' \
    "$SIZE" "$BASE" "$(du -h "$WORK" | cut -f1)"
printf '       next: provision_instance.sh %s\n' "$INSTANCE"
