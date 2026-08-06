#!/usr/bin/env bash
#
# record_trajectory.sh — Pass 2, run INSIDE the guest with network UP.
#
# Starts the replay proxy in RECORD mode, runs SWE-agent once against the real
# LLM through it, and leaves a cassette per exchange. After this, every replay
# is offline, free, and byte-identical.
#
# The API key is read from $LLM_API_KEY and is never written to disk: the proxy
# persists only Content-Type from each response.
#
set -euo pipefail

INSTANCE=prometheus__prometheus-15142
REPO_NAME=prometheus
BASE_COMMIT=16bba78f1549cfd7909b61ebd7c55c822c86630b
MODEL=openai/glm-5.2                       # litellm: openai-compatible provider
UPSTREAM=https://api.z.ai                  # ORIGIN only -- the proxy passes the
                                           # request path through verbatim
API_BASE=http://127.0.0.1:8000/api/paas/v4
CASS=/opt/cassettes/$INSTANCE
TRAJ=/opt/trajectories

: "${LLM_API_KEY:?LLM_API_KEY must be set (Pass 2 only)}"

say() { printf '\n=== %s ===\n' "$*"; }

say "0. preflight"
cd "/$REPO_NAME"
[ "$(git rev-parse HEAD)" = "$BASE_COMMIT" ] || { echo "HEAD != base_commit"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "tree dirty before recording"; exit 1; }
echo "  repo clean at $(git rev-parse --short=12 HEAD)"

mkdir -p "$CASS" "$TRAJ"

say "1. start proxy in RECORD mode"
python3 /opt/swe-agent-tools/replay_proxy.py \
    --mode record --cassettes "$CASS" --upstream "$UPSTREAM" --port 8000 \
    > /tmp/proxy_record.log 2>&1 &
PROXY_PID=$!
# Kill by PID, never by pattern: a `pkill -f replay_proxy` also matches the
# shell running THIS script and takes it down with the proxy.
trap 'kill $PROXY_PID 2>/dev/null || true' EXIT
sleep 3
kill -0 $PROXY_PID 2>/dev/null || { echo "proxy failed to start"; cat /tmp/proxy_record.log; exit 1; }
echo "  proxy pid $PROXY_PID on :8000 -> $UPSTREAM"

say "2. run SWE-agent (this spends API credits)"
# LITELLM_LOCAL_MODEL_COST_MAP keeps litellm from fetching its cost map over the
# network; the cost limits are disabled because litellm has no pricing entry for
# glm-5.2 and would otherwise refuse to run.
export LITELLM_LOCAL_MODEL_COST_MAP=True
/opt/venv/bin/sweagent run \
    --agent.model.name="$MODEL" \
    --agent.model.api_base="$API_BASE" \
    --agent.model.api_key=proxy-injects-the-real-key \
    --agent.model.temperature=0 \
    --agent.model.per_instance_cost_limit=0 \
    --agent.model.total_cost_limit=0 \
    --env.deployment.type=local \
    --env.repo.type=preexisting \
    --env.repo.repo_name="$REPO_NAME" \
    --env.repo.base_commit="$BASE_COMMIT" \
    --problem_statement.type=text_file \
    --problem_statement.path=/opt/problem_statement.md \
    --output_dir="$TRAJ" \
    2>&1 | tail -40

say "3. results"
n=$(ls "$CASS"/*.json 2>/dev/null | wc -l)
echo "  cassettes recorded: $n"
[ "$n" -gt 0 ] || { echo "  NO CASSETTES — recording failed"; exit 1; }
grep -qil "authorization" "$CASS"/*.json && { echo "  !! API KEY LEAKED INTO CASSETTE"; exit 1; }
echo "  no Authorization header in any cassette"
find "$TRAJ" -name '*.traj' | head -3 | sed 's/^/  traj: /'
echo "  repo state after run: [$(cd /$REPO_NAME && git status --porcelain | head -3)]"
