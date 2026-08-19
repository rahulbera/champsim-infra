#!/usr/bin/env bash
#
# record_watchdog.sh <instance_id> <ssh_port> — stop a record pass that has
# stopped making progress.
#
# Recording has no natural bound here: the cost limits are disabled (litellm has
# no pricing for this model) and the execution timeouts are disabled (they
# destroy the replay on one pinned vCPU). So a model that falls into a loop
# spends credits until someone notices. rubocop did exactly that -- 117 calls
# and 3.8M tokens sent, the last ~50 of them writing parse_check72.rb,
# parse_check73.rb, ... with an incrementing counter.
#
# Detects the LOOP rather than the length: prometheus legitimately ran 147
# steps, so a simple cap would either allow the loop or reject a good run. Two
# independent triggers, either of which stops the pass:
#   - repetition: of the last WINDOW actions, more than THRESHOLD collapse to
#     the same shape once digits are stripped
#   - hard ceiling: MAX_CALLS, as a backstop for a loop this misses
#
set -uo pipefail

INSTANCE=${1:?usage: record_watchdog.sh <instance_id> <ssh_port>}
PORT=${2:?usage: record_watchdog.sh <instance_id> <ssh_port>}
WINDOW=${WINDOW:-12}
THRESHOLD=${THRESHOLD:-8}
MAX_CALLS=${MAX_CALLS:-200}
POLL=${POLL:-60}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY=$ROOT/images/id_ed25519
LOG=$ROOT/images/watchdog-$INSTANCE.log

note() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

ssh_g() { ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=8 -i "$KEY" -p "$PORT" ubuntu@127.0.0.1 "$@"; }

note "watching $INSTANCE on :$PORT (window $WINDOW, threshold $THRESHOLD, ceiling $MAX_CALLS)"

while true; do
  sleep "$POLL"
  # No guest, no record pass.
  ssh_g true 2>/dev/null || { note "guest gone; watchdog exiting"; exit 0; }

  verdict=$(ssh_g "sudo python3 - <<'PY' 2>/dev/null
import glob, json, re, collections
fs = glob.glob('/opt/trajectories/**/*.traj', recursive=True)
if not fs:
    print('none 0'); raise SystemExit
t = json.load(open(fs[0]))
st = t.get('trajectory', [])
n = len(st)
recent = [(s.get('action') or '').strip() for s in st[-${WINDOW}:]]
# Collapse digits so parse_check72 / parse_check73 land on one shape.
shapes = [re.sub(r'\d+', '#', a)[:80] for a in recent if a]
top = collections.Counter(shapes).most_common(1)
dup = top[0][1] if top else 0
print(f'{dup} {n}')
PY")
  set -- $verdict
  dup=${1:-0}; n=${2:-0}
  [ "$dup" = "none" ] && continue

  if [ "$n" -ge "$MAX_CALLS" ]; then
    note "STOP: $n steps reached the ceiling of $MAX_CALLS"
  elif [ "$dup" -ge "$THRESHOLD" ]; then
    note "STOP: $dup of the last $WINDOW actions are the same shape at step $n -- looping"
  else
    continue
  fi

  # Stop the agent, not the guest: the partial trajectory and every cassette
  # recorded so far stay on disk and can be inspected.
  ssh_g 'sudo pkill -f "sweagent run" || true' 2>/dev/null
  note "signalled the agent to stop; watchdog exiting"
  exit 2
done
