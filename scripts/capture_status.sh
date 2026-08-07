#!/usr/bin/env bash
# capture_status.sh — one-screen view of every capture, for the hourly report.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGES=$ROOT/images
OUT=$IMAGES/champsim_out

lang_of() {  # instance -> language, from its descriptor's module
  case "$(grep -h '^LANG_MODULE=' "$ROOT/scripts/swe-agent/instances/$1.env" 2>/dev/null | cut -d= -f2)" in
    go)            echo Go ;;
    c_make)        echo C ;;
    rust_cargo)    echo Rust ;;
    ruby_bundler)  echo Ruby ;;
    node_npm)      echo JS ;;
    java_maven)    echo Java ;;
    php_composer)  echo PHP ;;
    *)             echo "?" ;;
  esac
}

# Latest phase, from whichever log is furthest along. Ordered earliest-to-latest
# so a later stage overwrites an earlier one.
phase_of() {
  # Find the logs by CONTENT, not by filename: the log names were chosen ad hoc
  # per launch and do not follow one convention.
  local inst=$1 c=$IMAGES/chain-$1 p=""
  local pl rl
  pl=$(grep -l "PROVISION $inst" /tmp/claude-1000/provision_*.log 2>/dev/null | head -1)
  rl=$(grep -l "RECORD.*$inst" /tmp/claude-1000/record_*.log 2>/dev/null | head -1)
  if [ -n "$pl" ] && [ -f "$pl" ]; then
    grep -q "PROVISIONED $inst" "$pl" 2>/dev/null && p=provisioned || p=provisioning
    grep -q '\[FAIL\]' "$pl" 2>/dev/null && p="provision FAILED"
  fi
  if [ -n "$rl" ] && [ -f "$rl" ]; then
    grep -q 'cassettes recorded' "$rl" 2>/dev/null && p=recorded || p=recording
    grep -q '\[FAIL\]' "$rl" 2>/dev/null && p="record FAILED"
  fi
  # Only OVERRIDE when the later log actually yields a phase. Assigning the
  # result unconditionally blanks a perfectly good earlier phase whenever the
  # pattern misses -- which is how "recording" became an em-dash.
  local q
  if [ -f "$c/advance.log" ]; then
    q=$(grep -oE 'START [a-z]+|OK [a-z]+|FAILED [a-z]+|waiting for a TCG|extracting' "$c/advance.log" 2>/dev/null | tail -1)
    [ -n "$q" ] && p=$q
  fi
  if [ -f "$c/chain.log" ]; then
    q=$(grep -oE 'START +[a-z]+|OK +[a-z]+|FAILED +[a-z]+' "$c/chain.log" 2>/dev/null | tail -1)
    [ -n "$q" ] && p=$q
  fi
  echo "${p:-—}" | tr -s ' ' | cut -c1-16
}

printf '%-32s %-5s %-16s %-9s %s\n' TASK LANG PHASE WINDOWS NOTE
printf '%.0s-' {1..92}; echo

for env in "$ROOT"/scripts/swe-agent/instances/*.env; do
  inst=$(basename "$env" .env)
  # 13680 was abandoned mid-recording (the model looped); keep the descriptor
  # for the record but do not report it as work in flight.
  [ "$inst" = rubocop__rubocop-13680 ] && continue

  pid=$( [ -f "$IMAGES/.qemu-$inst.pid" ] && cat "$IMAGES/.qemu-$inst.pid" 2>/dev/null || true )
  up=""; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && up="guest up"

  nw=$(ls "$OUT/$inst"/*.champsim2.zst 2>/dev/null | wc -l)
  nc=$(find "$ROOT/artifacts/$inst/cassettes" -name '*.json' 2>/dev/null | wc -l)
  note=""
  [ "$nc" -gt 0 ] && note="${nc} cassettes"
  [ -n "$up" ] && note="${note:+$note, }$up"
  [ "$nw" -ge 4 ] && note="${note:+$note, }DONE"

  printf '%-32s %-5s %-16s %-9s %s\n' "$inst" "$(lang_of "$inst")" "$(phase_of "$inst")" "$nw/4" "$note"
done

echo
echo "NON-AGENTIC CONTROLS (toolchain only, no agent)"
for inst in prometheus__prometheus-15142 redis__redis-13115; do
  tag=$inst.toolchain
  nw=$(ls "$OUT/$tag"/*.champsim2.zst 2>/dev/null | wc -l)
  meta=$IMAGES/capture-$tag.meta
  st="—"; [ -f "$meta" ] && st="profiled"
  [ "$nw" -gt 0 ] && st="converting"; [ "$nw" -ge 4 ] && st="DONE"
  printf '  %-40s %-9s %s\n' "$tag" "$nw/4" "$st"
done

echo
nb=$(ls /home/rbera/work/bpeval/cbp6-runs/bin 2>/dev/null | wc -l)
echo "CBP2025 CAMPAIGN: $nb/7 binaries built$([ "$nb" -eq 7 ] && echo ' (verified distinct)')"
echo "RESOURCES: $(pgrep -cx qemu-system-x86 2>/dev/null || echo 0) guests, \
$(free -g | awk 'NR==2{print $3"G/"$2"G"}') mem, \
load$(uptime | sed 's/.*load average://'), \
$(df -h /home | awk 'NR==2{print $4}') disk free"
