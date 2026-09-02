#!/usr/bin/env bash
#
# provision_instance.sh <instance_id> — HOST side: bring a fresh guest up to
# the state the record pass expects, and snapshot it.
#
#   1. boot the cloud image under KVM with the cloud-init seed
#   2. wait for cloud-init, then REBOOT (isolcpus only takes effect next boot)
#   3. stage the guest-side tools and the problem statement
#   4. run provision_guest.sh (toolchain, checkout, offline gate)
#   5. snapshot to <instance>.provisioned.qcow2
#
# Kept separate from capture_agentic.sh deliberately: this runs while other
# captures are mid-flight, and editing a script bash is currently executing is
# a good way to corrupt a multi-hour run.
#
set -euo pipefail

INSTANCE=${1:?usage: provision_instance.sh <instance_id>}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
IMAGES=$RPOINT_IMAGES
WORK=$IMAGES/guest-$INSTANCE.qcow2
PROVISIONED=$IMAGES/guest-$INSTANCE.provisioned.qcow2
SSH_KEY=$IMAGES/id_ed25519
PIDFILE=$IMAGES/.qemu-$INSTANCE.pid
LOG=$IMAGES/provision-$INSTANCE.boot.log

SLOT=${CAPTURE_SLOT:-$(grep -h '^CAPTURE_SLOT=' \
        "$ROOT/scripts/swe-agent/instances/$INSTANCE.env" 2>/dev/null \
        | tail -1 | cut -d= -f2)}
SLOT=${SLOT:-0}
PORT=$((2300 + SLOT * 10))

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

ssh_g() { ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=10000 \
              -i "$SSH_KEY" -p "$PORT" ubuntu@127.0.0.1 "$@"; }
rsh_opt="ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $PORT"

qemu_pid()     { [ -f "$PIDFILE" ] && cat "$PIDFILE" 2>/dev/null || true; }
qemu_running() { local p; p=$(qemu_pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
stop_qemu() {
  local p; p=$(qemu_pid)
  qemu_running || { rm -f "$PIDFILE"; return 0; }
  kill "$p" 2>/dev/null || true
  local t=0; while qemu_running && [ $t -lt 30 ]; do sleep 1; t=$((t+1)); done
  qemu_running && kill -9 "$p" 2>/dev/null || true
  rm -f "$PIDFILE"; sleep 2
}
trap 'rc=$?; [ $rc -ne 0 ] && qemu_running && stop_qemu; exit $rc' EXIT

boot() {
  rm -f "$PIDFILE"
  ( cd "$IMAGES" && sg kvm -c "IMG=$(basename "$WORK") SSH_PORT=$PORT \
      PIDFILE=$PIDFILE nohup bash boot_build.sh >> $LOG 2>&1 &" )
  local t=0
  while [ $t -lt 30 ]; do qemu_running && break; sleep 1; t=$((t+1)); done
  qemu_running || { tail -20 "$LOG"; die "qemu never wrote its pidfile"; }
  t=0
  while [ $t -lt 900 ]; do
    ssh_g true 2>/dev/null && { echo "  ssh up on :$PORT after ${t}s"; return 0; }
    sleep 5; t=$((t+5))
  done
  tail -20 "$LOG"; die "guest never came up"
}

[ -f "$WORK" ] || die "no image at $WORK -- create it with qemu-img first"
say "PROVISION $INSTANCE (slot $SLOT, ssh :$PORT)"
: > "$LOG"

boot
say "cloud-init"
ssh_g 'cloud-init status --wait >/dev/null 2>&1 || true; cloud-init status' | sed 's/^/  /'

# The GRUB drop-in that sets isolcpus is written by cloud-init, so the CURRENT
# boot never has it. Without the reboot, replay_pinned.sh refuses to run
# ("cpu 1 not isolated") after provisioning has already succeeded.
say "reboot for isolcpus"
ssh_g 'sudo reboot' 2>/dev/null || true
sleep 20
t=0; while [ $t -lt 300 ]; do ssh_g true 2>/dev/null && break; sleep 5; t=$((t+5)); done
ssh_g 'echo "  isolated=[$(cat /sys/devices/system/cpu/isolated)] nproc=$(nproc)"'
[ "$(ssh_g 'cat /sys/devices/system/cpu/isolated')" = "1" ] \
  || die "cpu 1 is not isolated after reboot -- check /etc/default/grub.d/99-tracing.cfg"

say "stage guest tools"
ssh_g 'sudo mkdir -p /opt/swe-agent-tools /opt/problem_statements && sudo chown -R ubuntu:ubuntu /opt/swe-agent-tools /opt/problem_statements'
rsync -a -e "$rsh_opt" --exclude '__pycache__' --exclude reference --exclude problem_statements \
      "$ROOT/scripts/swe-agent/" "ubuntu@127.0.0.1:/opt/swe-agent-tools/"
rsync -a -e "$rsh_opt" "$ROOT/scripts/swe-agent/problem_statements/" \
      "ubuntu@127.0.0.1:/opt/problem_statements/"
echo "  staged"

# The guest CANNOT clone from GitHub reliably. Two independent problems stack:
# GitHub throttles git from this host, and the guest reaches the network through
# QEMU's user-mode (SLIRP) stack, which drops larger clones outright -- fluentd
# failed 5 of 5 attempts in-guest on 2026-09-02 while the identical clone
# succeeded from the host. So the host clones ONCE into a bare mirror and every
# guest clones from a local path. GitHub leaves the provisioning path entirely,
# which also makes provisioning repeatable and much faster on re-runs.
REPO_URL=$(grep -h '^REPO_URL=' "$ROOT/scripts/swe-agent/instances/$INSTANCE.env" \
           | tail -1 | cut -d= -f2-)
REPO_NAME=$(grep -h '^REPO_NAME=' "$ROOT/scripts/swe-agent/instances/$INSTANCE.env" \
            | tail -1 | cut -d= -f2-)
if [ -n "$REPO_URL" ] && [ -n "$REPO_NAME" ]; then
  say "repo mirror for $REPO_NAME"
  CACHE=$IMAGES/repo-cache
  mkdir -p "$CACHE"
  if [ ! -d "$CACHE/$REPO_NAME.git" ]; then
    tries=0
    # protocol v1: GitHub's v2 handshake fails from this host (see the note in
    # provision_guest.sh). --mirror so every ref the agent might touch is here.
    until git -c protocol.version=1 clone --mirror -q "$REPO_URL" "$CACHE/$REPO_NAME.git"; do
      tries=$((tries + 1))
      [ "$tries" -lt 5 ] || die "could not mirror $REPO_URL after 5 attempts"
      echo "  mirror attempt $tries failed; retrying in $((tries * 20))s"
      rm -rf "$CACHE/$REPO_NAME.git"; sleep $((tries * 20))
    done
    echo "  mirrored -> $CACHE/$REPO_NAME.git ($(du -sh "$CACHE/$REPO_NAME.git" | cut -f1))"
  else
    echo "  reusing $CACHE/$REPO_NAME.git ($(du -sh "$CACHE/$REPO_NAME.git" | cut -f1))"
  fi
  ssh_g 'sudo mkdir -p /opt/repo-cache && sudo chown -R ubuntu:ubuntu /opt/repo-cache'
  rsync -a -e "$rsh_opt" "$CACHE/$REPO_NAME.git" "ubuntu@127.0.0.1:/opt/repo-cache/"
  echo "  staged into the guest at /opt/repo-cache/$REPO_NAME.git"
fi

say "run provision_guest.sh"
ssh_g "bash /opt/swe-agent-tools/provision_guest.sh $INSTANCE" 2>&1 | tail -40

say "pull installed versions"
# Must happen BEFORE the poweroff below -- the guest is unreachable after it.
mkdir -p "$ROOT/artifacts/$INSTANCE"
if rsync -a -e "$rsh_opt" "ubuntu@127.0.0.1:/opt/versions.txt" \
         "$ROOT/artifacts/$INSTANCE/versions.txt" 2>/dev/null; then
  echo "  -> artifacts/$INSTANCE/versions.txt ($(grep -c . "$ROOT/artifacts/$INSTANCE/versions.txt") lines)"
  grep -E '^(swe_agent_commit|python)=' "$ROOT/artifacts/$INSTANCE/versions.txt" | sed 's/^/    /'
else
  echo "  [warn] could not retrieve /opt/versions.txt -- this capture's software generation is UNRECORDED"
fi

say "snapshot"
ssh_g 'sudo systemctl poweroff' 2>/dev/null || true
t=0; while qemu_running && [ $t -lt 300 ]; do sleep 2; t=$((t+2)); done
qemu_running && stop_qemu
rm -f "$PIDFILE"
cp --reflink=auto "$WORK" "$PROVISIONED"
echo "  -> $PROVISIONED ($(du -h "$PROVISIONED" | cut -f1))"
say "PROVISIONED $INSTANCE"
