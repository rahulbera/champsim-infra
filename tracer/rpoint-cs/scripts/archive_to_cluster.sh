#!/usr/bin/env bash
#
# archive_to_cluster.sh <instance_id>... — copy validated traces to kratos2 and
# PROVE they arrived intact.
#
# The cluster is where a trace durably lives; the local catalog is a staging
# cache between the tracer and it (126 TB free there against ~450 GB here).
#
# THE TRANSFER IS NOT DONE WHEN RSYNC EXITS. A trace that arrives truncated is
# indistinguishable from one that arrived whole until something reads it, and
# this campaign has already lost a 2.3 GB trace to a silent truncation. So every
# file is re-hashed ON THE CLUSTER and compared against the local digest before
# it counts, and nothing is reported reclaimable until that comparison passes.
#
# Read-only with respect to local traces: this script never deletes anything.
# Reclaiming is a separate, deliberate act -- see the note it prints at the end.
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"

REMOTE=${REMOTE_HOST:-kratos2}
RDIR=${REMOTE_DIR:-/home/rahbera/tracezoo/champsim/version2.1/agentic/swe-agent-w-swe-bench-multilingual}
RSUMS=${REMOTE_SUMS:-/home/rahbera/tracezoo/champsim/CHECKSUMS.sha256}
SRC=$RPOINT_IMAGES/champsim_out

say() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf '  [ok] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*" >&2; }

[ $# -gt 0 ] || { echo "usage: archive_to_cluster.sh <instance_id>..." >&2; exit 2; }

ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE" true 2>/dev/null \
  || { bad "cannot reach $REMOTE (needs network; run with the sandbox disabled)"; exit 1; }
ssh -o BatchMode=yes "$REMOTE" "mkdir -p '$RDIR'" || { bad "cannot create $RDIR"; exit 1; }

rc=0
for INSTANCE in "$@"; do
  say "ARCHIVE $INSTANCE"
  d=$SRC/$INSTANCE
  [ -d "$d" ] || { bad "no converted traces at $d"; rc=1; continue; }

  # Only archive what passed validation. An unvalidated trace is not a trace we
  # are willing to stand behind, and the cluster is not a place to park doubt.
  files=()
  for f in "$d"/*.champsim2.zst; do
    [ -f "$f" ] || continue
    if grep -q 'all acceptance checks passed' "$f.check.log" 2>/dev/null; then
      files+=("$f")
    else
      bad "$(basename "$f") has no passing check.log -- skipped"
      rc=1
    fi
  done
  [ ${#files[@]} -gt 0 ] || { bad "nothing validated to archive for $INSTANCE"; rc=1; continue; }
  echo "  ${#files[@]} validated window(s), $(du -ch "${files[@]}" | tail -1 | cut -f1)"

  # Local digests first: the reference everything else is compared against.
  declare -A want=()
  for f in "${files[@]}"; do
    want["$(basename "$f")"]=$(sha256sum "$f" | cut -d' ' -f1)
  done

  echo "  transferring..."
  rsync -a --partial --inplace --info=progress2 "${files[@]}" "$REMOTE:$RDIR/" 2>&1 \
    | tail -1 | sed 's/^/    /'
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then bad "rsync failed for $INSTANCE"; rc=1; continue; fi

  # THE GATE: re-hash on the cluster. rsync exiting 0 is not evidence the bytes
  # on the far side are the bytes we sent.
  echo "  verifying on $REMOTE..."
  names=$(printf '%s\n' "${!want[@]}" | tr '\n' ' ')
  remote=$(ssh -o BatchMode=yes "$REMOTE" "cd '$RDIR' && sha256sum $names 2>/dev/null")
  fail=0
  while read -r h n; do
    [ -n "$n" ] || continue
    if [ "${want[$n]:-}" = "$h" ]; then
      printf '    %s  %s\n' "OK  " "$n"
    else
      printf '    %s  %s (local %s remote %s)\n' "DIFF" "$n" "${want[$n]:0:12}" "${h:0:12}"
      fail=1
    fi
  done <<<"$remote"
  got=$(grep -c . <<<"$remote")
  [ "$got" -eq "${#want[@]}" ] || { bad "$got of ${#want[@]} files present remotely"; fail=1; }

  if [ "$fail" -ne 0 ]; then
    bad "$INSTANCE NOT archived cleanly -- local copy stays, do not reclaim"
    rc=1
    continue
  fi

  # Only now record it. The remote manifest did not exist before this campaign;
  # create-or-append, and never duplicate a line for the same file.
  for n in "${!want[@]}"; do
    ssh -o BatchMode=yes "$REMOTE" \
      "grep -q ' $n\$' '$RSUMS' 2>/dev/null || echo '${want[$n]}  $n' >> '$RSUMS'"
  done
  ok "$INSTANCE archived and verified; digests appended to $(basename "$RSUMS")"
  echo "  reclaimable locally: $(du -ch "${files[@]}" | tail -1 | cut -f1)"
  echo "     NOTE: the traces are HARDLINKED between champsim_out/<instance>/ and"
  echo "     the tracezoo catalog. Removing one name frees nothing; both must go."
done
exit $rc
