#!/usr/bin/env bash
# capture_status.sh — one-screen view of every capture in flight.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGES=$ROOT/images
KEY=$IMAGES/id_ed25519

printf '%-34s %-6s %-8s %-26s %s\n' INSTANCE SLOT PORT PHASE DETAIL
printf '%.0s-' {1..104}; echo

for env in "$ROOT"/scripts/swe-agent/instances/*.env; do
  inst=$(basename "$env" .env)
  slot=$(grep -h '^CAPTURE_SLOT=' "$env" 2>/dev/null | tail -1 | cut -d= -f2)
  slot=${slot:-0}
  pidf=$IMAGES/.qemu-$inst.pid
  pid=$( [ -f "$pidf" ] && cat "$pidf" 2>/dev/null || true )
  up=no; port=-
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    up=yes
    port=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
           | grep -o 'hostfwd=tcp::[0-9]*' | grep -o '[0-9]*$' | head -1)
  fi

  phase=idle; detail=""
  chain=$IMAGES/chain-$inst
  [ -f "$chain/advance.log" ] && phase=$(grep -oE 'START [a-z]+|OK +[a-z]+|FAILED [a-z]+|waiting for [a-z ]+' \
                                          "$chain/advance.log" 2>/dev/null | tail -1)
  [ -f "$chain/chain.log" ]   && phase=$(grep -oE 'START +[a-z]+|OK +[a-z]+|FAILED +[a-z]+' \
                                          "$chain/chain.log" 2>/dev/null | tail -1)
  [ -f "$ROOT/artifacts/$inst/cassettes" ] 2>/dev/null || true
  nc=$(find "$ROOT/artifacts/$inst/cassettes" -name '*.json' 2>/dev/null | wc -l)
  [ "$nc" -gt 0 ] && detail="${nc} cassettes"
  nw=$(ls "$IMAGES/champsim_out/$inst"/*.champsim2.zst 2>/dev/null | wc -l)
  [ "$nw" -gt 0 ] && detail="$detail, ${nw} windows converted"
  [ "$up" = yes ] && detail="$detail [guest up]"

  printf '%-34s %-6s %-8s %-26s %s\n' "$inst" "$slot" "${port:--}" "${phase:-idle}" "$detail"
done

echo
echo "TCG slots held: $(ls /tmp/claude-1000/tcg-locks 2>/dev/null | wc -l) lockfiles; load:$(uptime | sed 's/.*load average://')"
echo "guests running: $(pgrep -cx qemu-system-x86 2>/dev/null || echo 0)"
