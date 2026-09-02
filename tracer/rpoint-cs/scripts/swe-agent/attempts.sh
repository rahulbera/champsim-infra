#!/usr/bin/env bash
#
# attempts.sh — enforce the three-strikes rule on an instance.
#
#   attempts.sh log   <instance> <instance|infra> "<reason>"
#   attempts.sh check <instance>          # exit 1 if it is out of tries
#   attempts.sh report                    # all instances, one line each
#
# THE RULE (set 2026-08-07): an instance gets three tries. If it still does not
# work, drop it and pick another -- SWE-bench Multilingual has 300 instances and
# no shortage of substitutes. The cost of a fourth attempt is always paid in API
# credits and hours, and is almost never recovered.
#
# THE ONE DISTINCTION: only INSTANCE-attributable failures count.
#
#   instance -- the task itself is a bad fit: the model loops, the replay
#               diverges, the repo cannot be built offline, the trajectory is
#               degenerate. Three of these and it is gone.
#   infra    -- MY bug, in code shared by every instance: a wrong grep pattern,
#               a symlink the validator cannot read, a maven scope. Fixing one
#               of those and retrying is not the instance's fault, and burning
#               its budget on my mistakes would drop good tasks for bad reasons.
#
# The distinction is recorded per attempt so the judgement can be audited rather
# than taken on trust -- an infra classification is exactly what a motivated
# reasoner would reach for to buy a fourth try.
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIR=$ROOT/scripts/swe-agent/attempts
LIMIT=${ATTEMPT_LIMIT:-3}
TOTAL_LIMIT=${TOTAL_ATTEMPT_LIMIT:-5}   # any cause, infra included
mkdir -p "$DIR"

cmd=${1:-report}

case "$cmd" in
log)
  inst=${2:?instance}; kind=${3:?instance|infra}; reason=${4:?reason}
  case "$kind" in instance|infra) ;; *) echo "kind must be instance|infra" >&2; exit 2 ;; esac
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$kind" "$reason" >> "$DIR/$inst.log"
  n=$(awk -F'\t' '$2=="instance"' "$DIR/$inst.log" | wc -l)
  echo "  logged ($kind): $reason"
  echo "  $inst has used $n/$LIMIT instance-attributable tries"
  # `[ ] && echo` as the last statement returns 1 on the NORMAL path, which
  # makes the whole script exit non-zero whenever an instance is NOT at the
  # limit. Same shape that once aborted a capture driver right after the
  # workload finished.
  if [ "$n" -ge "$LIMIT" ]; then
    echo "  >>> AT THE LIMIT -- drop it and pick a replacement"
  fi
  ;;
check)
  inst=${2:?instance}
  n=$(awk -F'\t' '$2=="instance"' "$DIR/$inst.log" 2>/dev/null | wc -l)
  total=$(wc -l < "$DIR/$inst.log" 2>/dev/null || echo 0)
  # TWO ceilings, and either stops the task.
  #
  #   LIMIT (3)       instance-attributable failures -- the task is a bad fit.
  #   TOTAL_LIMIT (5) failures of ANY kind, infra included.
  #
  # The second was added by the PI on 2026-09-02 after jekyll-8167 consumed four
  # attempts, every one of them a different bug in my own descriptor and every
  # one understood before the next retry. Understanding a failure is what makes a
  # retry defensible; it is not what makes it free. Four provisioning runs is
  # roughly an hour of machine time, and at some point the honest move is to take
  # the next candidate from the same cell rather than keep paying.
  if [ "$n" -ge "$LIMIT" ]; then
    echo "$inst: $n/$LIMIT INSTANCE failures -- OUT OF TRIES (bad fit; ditch and document)"; exit 1
  fi
  if [ "$total" -ge "${TOTAL_LIMIT:-5}" ]; then
    echo "$inst: $total/${TOTAL_LIMIT:-5} TOTAL attempts ($n instance, $((total-n)) infra)" \
         "-- OUT OF TRIES even though the causes were understood; take the next candidate"; exit 1
  fi
  echo "$inst: $n/$LIMIT instance failures, $total/${TOTAL_LIMIT:-5} total"
  ;;
report)
  printf '%-34s %-9s %-6s %s\n' INSTANCE TRIES INFRA LAST
  printf '%.0s-' {1..92}; echo
  for env in "$ROOT"/scripts/swe-agent/instances/*.env; do
    inst=$(basename "$env" .env)
    f=$DIR/$inst.log
    n=0; i=0; last="-"
    if [ -f "$f" ]; then
      n=$(awk -F'\t' '$2=="instance"' "$f" | wc -l)
      i=$(awk -F'\t' '$2=="infra"'    "$f" | wc -l)
      last=$(tail -1 "$f" | cut -f3 | cut -c1-42)
    fi
    flag=""; [ "$n" -ge "$LIMIT" ] && flag=" <<< DROP"
    printf '%-34s %-9s %-6s %s%s\n' "$inst" "$n/$LIMIT" "$i" "$last" "$flag"
  done
  ;;
*) echo "usage: attempts.sh log|check|report ..." >&2; exit 2 ;;
esac
