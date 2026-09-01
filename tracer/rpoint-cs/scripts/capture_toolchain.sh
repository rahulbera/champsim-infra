#!/usr/bin/env bash
#
# capture_toolchain.sh <instance_id> <phase> — HOST driver for the NON-AGENTIC
# control. Phases: profile | trace | convert.
#
# Same guest, same commit, same pinned vCPU, same tracer, same 4x300M geometry
# as the agentic capture -- only the payload differs: toolchain_only.sh runs the
# build and test commands directly, with no agent, no LLM and no proxy.
#
# There is no record or verify phase because there is no model in the loop:
# the workload is deterministic by construction, so there is nothing to record
# and nothing that could diverge.
#
# Kept separate from capture_agentic.sh rather than added as a phase, because
# that script is usually mid-run when this one is written or launched, and
# editing a file bash is executing can corrupt a multi-hour pass.
#
set -euo pipefail

INSTANCE=${1:?usage: capture_toolchain.sh <instance_id> <phase>}
PHASE=${2:?usage: capture_toolchain.sh <instance_id> <phase>}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
IMAGES=$RPOINT_IMAGES
TAG=$INSTANCE.toolchain
WORK=$IMAGES/guest-$TAG.qcow2
PROVISIONED=$IMAGES/guest-$INSTANCE.provisioned.qcow2
META=$IMAGES/capture-$TAG.meta
SSH_KEY=$IMAGES/id_ed25519

# Its own slot, so it never collides with the agentic capture of the same
# instance -- they may well run at the same time. Offset +10, not +5: agentic
# slots now run 0..9, so +5 would have put the rubocop control (1+5=6) on jq's
# slot and the gin control (4+5=9) on prometheus's. Controls occupy 10..19.
SLOT=${CAPTURE_SLOT:-$(( $(grep -h '^CAPTURE_SLOT=' \
        "$ROOT/scripts/swe-agent/instances/$INSTANCE.env" 2>/dev/null \
        | tail -1 | cut -d= -f2) + 10 ))}
TCG_PORT=$((2301 + SLOT * 10))
TRIGGER=/tmp/swe_roi_trigger.$TAG
PIDFILE=$IMAGES/.qemu-$TAG.pid
PROFILE_OUT=$IMAGES/profile_out-$TAG
WINDOWS=${WINDOWS:-4}
WINDOW_LEN=${WINDOW_LEN:-300000000}
CYCLES=${CYCLES:-6}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

ssh_g() { ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=10000 \
              -i "$SSH_KEY" -p "$TCG_PORT" ubuntu@127.0.0.1 "$@"; }

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

shutdown_guest() {
  ssh_g 'sudo systemctl poweroff' 2>/dev/null || true
  local t=0; while qemu_running && [ $t -lt 300 ]; do sleep 2; t=$((t+2)); done
  if qemu_running; then echo "  forcing guest down after ${t}s"; stop_qemu
  else echo "  guest powered off cleanly after ${t}s"; fi
}

boot_tcg() {  # boot_tcg <outdir> <plugin-extra> <serial-log>
  local outdir=$1 extra=$2 log=$3
  stop_qemu; rm -f "$TRIGGER" "$log.trigger"
  [ -f "$PROVISIONED" ] || die "no provisioned image at $PROVISIONED"
  cp --reflink=auto "$PROVISIONED" "$WORK"
  ( cd "$IMAGES" && IMG=$(basename "$WORK") SSH_PORT=$TCG_PORT TRIGGER=$TRIGGER \
      PIDFILE=$PIDFILE nohup bash boot_tcg_trace.sh "$outdir" "$extra" > "$log" 2>&1 & )
  local t=0; while [ $t -lt 30 ]; do qemu_running && break; sleep 1; t=$((t+1)); done
  qemu_running || { tail -20 "$log"; die "qemu never wrote its pidfile"; }
  t=0
  while [ $t -lt 2400 ]; do
    ssh_g true 2>/dev/null && { echo "  ssh up on :$TCG_PORT after ${t}s"; break; }
    sleep 5; t=$((t+5))
  done
  ssh_g true 2>/dev/null || { tail -30 "$log"; die "guest never came up under TCG"; }

  # /opt is root-owned, and an older provisioned snapshot may predate the tools
  # directory entirely -- rsync then fails with a bare "mkdir ... Permission
  # denied" that reads like a broken key.
  ssh_g 'sudo mkdir -p /opt/swe-agent-tools /opt/problem_statements && sudo chown -R ubuntu:ubuntu /opt/swe-agent-tools /opt/problem_statements' \
    || die "could not prepare the guest tools directory"
  rsync -a -e "ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $TCG_PORT" \
    --exclude '__pycache__' --exclude reference --exclude problem_statements \
    "$ROOT/scripts/swe-agent/" "ubuntu@127.0.0.1:/opt/swe-agent-tools/" || die "could not stage tools"
  echo "  staged guest tools"

  ( t=0
    while [ $t -lt 14400 ]; do
      if grep -q TRACE_ROI_BEGIN "$log" 2>/dev/null; then
        touch "$TRIGGER"; echo "armed at $(date +%T)" >> "$log.trigger"; exit 0
      fi
      sleep 1; t=$((t+1))
    done
    echo "NEVER SAW THE MARKER" >> "$log.trigger" ) &
}

run_payload() {
  ssh_g "sudo CYCLES=$CYCLES bash /opt/swe-agent-tools/toolchain_only.sh $INSTANCE" 2>&1 | tail -20
}

case "$PHASE" in
profile)
  say "TOOLCHAIN PROFILE — $INSTANCE (no agent), slot $SLOT"
  LOG=$IMAGES/profile-$TAG.boot.log
  boot_tcg "$PROFILE_OUT" ",profile=on" "$LOG"
  run_payload
  shutdown_guest
  grep -q armed "$LOG.trigger" 2>/dev/null || die "trigger never armed"
  line=$(grep -h 'PROFILE:' "$LOG" | tail -1) || true
  [ -n "$line" ] || die "no PROFILE line -- the plugin reported no total"
  total=$(sed -n 's/.*PROFILE: \([0-9]*\) instructions.*/\1/p' <<<"$line")
  user=$(sed  -n 's/.*(\([0-9]*\) user.*/\1/p'                 <<<"$line")
  kern=$(sed  -n 's/.*user, \([0-9]*\) kernel.*/\1/p'          <<<"$line")
  [ -n "$user" ] && [ "$user" -gt 0 ] || die "parsed a zero user total from: $line"
  need=$((WINDOWS * WINDOW_LEN))
  [ "$user" -gt "$need" ] \
    || die "only $user user insns; $WINDOWS x $WINDOW_LEN needs $need -- raise CYCLES"
  gap=$(( (user - need) / (WINDOWS - 1) ))
  { echo "instance=$INSTANCE"; echo "variant=toolchain"; echo "cycles=$CYCLES"
    echo "profile_total=$total"; echo "profile_user=$user"; echo "profile_kernel=$kern"
    echo "windows=$WINDOWS"; echo "window_len=$WINDOW_LEN"; echo "sample_gap=$gap"; } > "$META"
  echo "  total $total (user $user / kernel $kern); gap $gap"
  ;;

trace)
  say "TOOLCHAIN TRACE — $INSTANCE (no agent)"
  [ -f "$META" ] || die "no $META -- run the profile phase first"
  # shellcheck disable=SC1090
  . "$META"
  OUT=$IMAGES/trace_out-$TAG; rm -rf "$OUT"; mkdir -p "$OUT"
  LOG=$IMAGES/trace-$TAG.boot.log
  boot_tcg "$OUT" ",sample_len=$window_len,sample_gap=$sample_gap,sample_count=$windows,sample_clock=user" "$LOG"
  run_payload
  shutdown_guest
  grep -q armed "$LOG.trigger" 2>/dev/null || die "trigger never armed -- no window captured"
  n=$(find "$OUT" -name 'trace_vcpu*_c*.raw.zst' | wc -l)
  echo "  chunks: $n"
  [ "$n" -eq "$windows" ] || die "expected $windows chunks, got $n"
  cat "$OUT"/*manifest.txt 2>/dev/null | sed 's/^/  /'
  ;;

convert)
  say "TOOLCHAIN CONVERT — $INSTANCE"
  OUT=$IMAGES/trace_out-$TAG
  DST=$IMAGES/champsim_out/$TAG; mkdir -p "$DST"
  export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/home/rbera/local/lib
  SANITY=${SANITY:-/home/rbera/work/bpeval/champsim-infra/tools/trace_sanity_check/trace_sanity_check}
  shopt -s nullglob
  raws=("$OUT"/trace_vcpu*_c*.raw.zst)
  [ ${#raws[@]} -gt 0 ] || die "no raw chunks in $OUT"
  fail=0
  for raw in "${raws[@]}"; do
    idx=$(sed -n 's/.*_c\([0-9]*\)\.raw\.zst/\1/p' <<<"$raw")
    dst=$DST/${TAG}_w${idx}.champsim2.zst
    echo "  $(basename "$raw") -> $(basename "$dst")"
    "$RPOINT_CONVERTER" "$raw" "$dst" 2>&1 \
      | grep -iE 'instruction|user|kernel|branch|decode fail' | sed 's/^/    /'
    if [ -x "$SANITY" ]; then
      "$SANITY" -i "$dst" -f v2 --check > "$dst.check.log" 2>&1 \
        && echo "    [ok] sanity --check passed" \
        || { echo "    [FAIL] sanity --check"; tail -10 "$dst.check.log" | sed 's/^/      /'; fail=1; }
    fi
  done
  ls -la "$DST"/*.champsim2.zst
  [ "$fail" -eq 0 ] || die "a window failed validation"
  # Reclaim the raw chunks -- ONLY after every window converted AND validated.
  # Deleting them before validation would trade a disk saving for a multi-hour
  # TCG re-trace, since the raw stream is the only thing a re-convert can read.
  freed=$(du -sh "$OUT" 2>/dev/null | cut -f1)
  rm -rf "$OUT"
  echo "  reclaimed $freed of raw chunks ($OUT)"
  ;;
*) die "unknown phase '$PHASE' (profile|trace|convert)" ;;
esac
