#!/usr/bin/env bash
#
# backfill_provenance.sh [--apply] — put software provenance into the metas of
# captures taken BEFORE capture_agentic.sh started doing it.
#
# WHY. Every proposed fix for the two replay defects -- gin's SWE-ReX PTY wedge
# and the 25-second state-command timeout -- is a local patch to SWE-ReX. All
# three write-ups say the same thing: a capture must record WHICH software
# produced it, or a patched and an unpatched trace become indistinguishable
# afterwards. New captures now carry that in capture-<id>.meta. The 30-odd
# already archived do not, and their traces are the baseline every later
# comparison is made against -- so the baseline is exactly what must be
# labelled.
#
# The data already exists: provisioning has always written artifacts/<id>/
# versions.txt. It was simply never copied where a trace consumer would look.
#
# Dry-run by default. It only ever APPENDS to a meta, and skips one that already
# carries the fields, so it is safe to re-run.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/paths.sh"
IMAGES=$RPOINT_IMAGES
ARTIFACTS=${RPOINT_ARTIFACTS:-$ROOT/artifacts}
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

FIELDS='^(swe_agent_commit|swe_agent_describe|swerex_version|swerex_sha256|guest_tools_sha256|swerex_patch|python|kernel)='
done_n=0; skip_n=0; miss_n=0
for meta in "$IMAGES"/capture-*.meta; do
  [ -f "$meta" ] || continue
  inst=$(basename "$meta" .meta); inst=${inst#capture-}
  if grep -qE '^swe_agent_commit=' "$meta" 2>/dev/null; then
    skip_n=$((skip_n + 1)); continue
  fi
  v=$ARTIFACTS/$inst/versions.txt
  if [ ! -f "$v" ]; then
    printf '  NO VERSIONS  %s\n' "$inst"; miss_n=$((miss_n + 1)); continue
  fi
  n=$(grep -cE "$FIELDS" "$v" || true)
  printf '  %-34s %s provenance fields\n' "$inst" "$n"
  if [ "$APPLY" -eq 1 ]; then
    { echo "# --- software provenance, backfilled from artifacts/$inst/versions.txt ---"
      # swerex_sha256 and guest_tools_sha256 post-date these captures, so most
      # will carry only the commit/version fields. Saying so beats an absence
      # that later reads as "unrecorded".
      # Quoted: the meta is SOURCED by the trace phase, so an unquoted
      # `python=Python 3.12.3` becomes an assignment plus a stray command.
      grep -E "$FIELDS" "$v" | sed -E 's/^([a-z_]+)=(.*)$/\1="\2"/'
      grep -qE '^swerex_sha256=' "$v" || echo "# swerex_sha256: not recorded at capture time (field added 2026-09-04)"
    } >> "$meta"
  fi
  done_n=$((done_n + 1))
done
echo
echo "  $done_n to backfill, $skip_n already have it, $miss_n missing versions.txt"
[ "$APPLY" -eq 1 ] && echo "  APPLIED" || echo "  (dry run -- pass --apply)"
