#!/usr/bin/env bash
#
# reclaim_space.sh [--apply] — free disk from finished captures.
#
# Dry-run by default. Nothing is deleted unless --apply is given, because a
# wrong deletion here costs a multi-hour TCG re-trace or an API-credit re-record,
# not a re-download.
#
# WHAT IS SAFE TO DELETE, AND WHY
#
#   trace_out-<tag>/        raw chunks. Reclaimable ONLY once every window has
#                           converted AND validated -- the raw stream is the only
#                           input a re-convert can read.
#   profile_out-<tag>/      profile mode writes no records; these are empty.
#   guest-<inst>.qcow2      the working copy. Every phase recreates it from the
#                           provisioned image, so it is pure scratch.
#   guest-<inst>.recorded   the post-record snapshot. Safe ONLY once the
#                           cassettes and trajectory are on the host under
#                           artifacts/<inst>/ -- those cost API credits and
#                           cannot be regenerated identically.
#
# WHAT IS NEVER DELETED
#
#   guest-<inst>.provisioned.qcow2   every replay phase restores from it; losing
#                                    it means re-provisioning from scratch.
#   champsim_out/                    the converted traces. The whole point.
#   artifacts/                       cassettes and trajectories. Paid for once.
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
IMAGES=$RPOINT_IMAGES

# Expected windows per capture. Campaign 2026-09 captures K=5 and analyses
# w1..w4, keeping w0 as a drift canary (it is harness startup, not workload).
# This was hardcoded as 4 in several places, which would report every K=5
# capture as "5/4" and never reach DONE.
WINDOWS=${WINDOWS:-5}
OUT=$IMAGES/champsim_out
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

total=0
say() { printf '%s\n' "$*"; }
kb()  { du -sk "$1" 2>/dev/null | cut -f1; }

drop() {  # drop <path> <why>
  [ -e "$1" ] || return 0
  local k; k=$(kb "$1"); total=$((total + k))
  if [ "$APPLY" -eq 1 ]; then
    rm -rf "$1"; printf '  freed  %6.1f GB  %-52s %s\n' "$(echo "$k/1048576"|bc -l)" "$(basename "$1")" "$2"
  else
    printf '  would  %6.1f GB  %-52s %s\n' "$(echo "$k/1048576"|bc -l)" "$(basename "$1")" "$2"
  fi
}

validated() {  # validated <tag> -> number of windows that passed --check
  grep -l 'all acceptance checks passed' "$OUT/$1"/*.check.log 2>/dev/null | wc -l
}

say "=== raw chunks from fully validated captures ==="
for d in "$IMAGES"/trace_out-*; do
  [ -d "$d" ] || continue
  tag=$(basename "$d" | sed 's/^trace_out-//')
  n=$(validated "$tag")
  if [ "$n" -ge "$WINDOWS" ]; then
    drop "$d" "($n/$WINDOWS windows validated)"
  else
    printf '  KEEP   %6s      %-52s (only %s/%s validated -- raw is the only re-convert source)\n' "" "$(basename "$d")" "$n" "$WINDOWS"
  fi
done
# The legacy unsuffixed dir belongs to the first prometheus capture, long since
# converted and validated under its canonical name.
[ "$(validated prometheus__prometheus-15142)" -ge "$WINDOWS" ] && drop "$IMAGES/trace_out" "(first prometheus capture, validated)"
for d in "$IMAGES"/profile_out*; do drop "$d" "(profile mode writes no records)"; done

say ""
say "=== scratch guest images ==="
for w in "$IMAGES"/guest-*.qcow2; do
  [ -f "$w" ] || continue
  b=$(basename "$w")
  case "$b" in *.provisioned.qcow2) continue ;; esac
  inst=${b#guest-}; inst=${inst%.qcow2}; inst=${inst%.recorded}; inst=${inst%.toolchain}
  # Never touch an instance whose guest is running or that is still in flight.
  pid=$( [ -f "$IMAGES/.qemu-$inst.pid" ] && cat "$IMAGES/.qemu-$inst.pid" 2>/dev/null || true )
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf '  KEEP   %6s      %-52s (guest running)\n' "" "$b"; continue
  fi
  case "$b" in
    *.recorded.qcow2)
      if [ -d "$ROOT/artifacts/$inst/cassettes" ]; then
        drop "$w" "(cassettes safe on the host)"
      else
        printf '  KEEP   %6s      %-52s (cassettes NOT yet extracted)\n' "" "$b"
      fi ;;
    *) drop "$w" "(scratch; recreated from the provisioned image)" ;;
  esac
done

say ""
printf 'TOTAL %s: %.1f GB\n' "$([ "$APPLY" -eq 1 ] && echo freed || echo reclaimable)" "$(echo "$total/1048576"|bc -l)"
[ "$APPLY" -eq 1 ] || say "(dry run -- pass --apply to delete)"
df -h /home | tail -1
