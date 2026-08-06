#!/usr/bin/env bash
#
# replay_pinned.sh — Pass 3 payload, run INSIDE the guest as root.
#
# Replays the recorded trajectory with NO network, with the agent and every
# tool subprocess pinned to the isolated vCPU. Prints a short serial marker
# immediately before the agent starts so the host can arm the tracing trigger.
#
# Usage: replay_pinned.sh            # normal traced run
#        replay_pinned.sh --profile  # same execution, used for the sizing pass
#
set -euo pipefail

INSTANCE=prometheus__prometheus-15142
REPO_NAME=prometheus
BASE_COMMIT=16bba78f1549cfd7909b61ebd7c55c822c86630b
MODEL=openai/glm-5.2
API_BASE=http://127.0.0.1:8000/api/paas/v4
CASS=/opt/cassettes/$INSTANCE
TRAJ=/opt/trajectories-replay
PIN_CPU=1

[ "$(id -u)" -eq 0 ] || { echo "must run as root (SWE-agent writes /root/tools)"; exit 1; }

say() { printf '\n=== %s ===\n' "$*"; }

say "0. preflight"
git config --global --add safe.directory "/$REPO_NAME"
cd "/$REPO_NAME"
git checkout --force --quiet "$BASE_COMMIT"
git clean -xfd --quiet
[ -z "$(git status --porcelain)" ] || { echo "tree dirty"; exit 1; }
n=$(ls "$CASS"/*.json 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "no cassettes in $CASS -- run the record pass first"; exit 1; }
echo "  repo clean at $(git rev-parse --short=12 HEAD), $n cassettes"

# The isolated CPU must actually be isolated, or the whole capture is noise.
[ "$(cat /sys/devices/system/cpu/isolated)" = "$PIN_CPU" ] || { echo "cpu $PIN_CPU not isolated"; exit 1; }
echo "  cpu $PIN_CPU isolated; taskset sees $(taskset -c $PIN_CPU nproc) cpu(s)"

say "1. proxy in REPLAY mode (no network, no key)"
# Pinned to the same CPU as the agent: the brief lists the proxy's serving work
# as CPU work to capture. Logs to /root, not /tmp -- fs.protected_regular=1
# blocks even root from reopening another user's file in a sticky directory.
taskset -c "$PIN_CPU" python3 /opt/swe-agent-tools/replay_proxy.py \
    --mode replay --cassettes "$CASS" --port 8000 \
    > /root/proxy_replay.log 2>&1 &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null || true' EXIT     # by PID, never by pattern
sleep 3
kill -0 $PROXY_PID 2>/dev/null || { echo "proxy failed"; cat /root/proxy_replay.log; exit 1; }
echo "  proxy pid $PROXY_PID pinned to cpu $PIN_CPU"

rm -rf "$TRAJ"; mkdir -p "$TRAJ"

# SWE-agent uploads its tool bundles with shutil.copytree() and no
# dirs_exist_ok, so a second run dies with FileExistsError on /root/tools/...
# Under Docker every run gets a fresh container and this never shows up; under
# the local deployment the previous run's tools persist. Clear them.
rm -rf /root/tools /root/state.json /root/.swe-agent-env
export LITELLM_LOCAL_MODEL_COST_MAP=True

# ---- ROI MARKER -----------------------------------------------------------
# The host tails the serial console for this exact string and touches the
# tracing trigger when it appears. Kept short on purpose: ISA serial is one
# outb per byte, and under TCG every byte is emulated instructions inside the
# capture window.
sleep 2
echo "TRACE_ROI_BEGIN"
sleep 2

# --env.repo.reset=False is REQUIRED offline. PreExistingRepoConfig's reset
# sequence starts with `git fetch`, which needs network and fails with exit 128
# ("Failed to clean repository") when there is none. It succeeded during the
# record pass only because the network was up. Step 0 above already put the tree
# at base_commit and ran git clean, so SWE-agent's reset is redundant anyway.
say "2. replay (pinned to cpu $PIN_CPU)"
# taskset pins the agent, and fork/exec children INHERIT the affinity, which is
# why the local (non-Docker) deployment was chosen: a Docker daemon would spawn
# tool processes outside this process tree and they would escape the pin.
taskset -c "$PIN_CPU" /opt/venv/bin/sweagent run \
    --agent.model.name="$MODEL" \
    --agent.model.api_base="$API_BASE" \
    --agent.model.api_key=replayed-from-cassettes \
    --agent.model.temperature=0 \
    --agent.model.per_instance_cost_limit=0 \
    --agent.model.total_cost_limit=0 \
    --env.deployment.type=local \
    --env.repo.type=preexisting \
    --env.repo.repo_name="$REPO_NAME" \
    --env.repo.base_commit="$BASE_COMMIT" \
    --env.repo.reset=False \
    --problem_statement.type=text_file \
    --problem_statement.path=/opt/problem_statement.md \
    --output_dir="$TRAJ" \
    2>&1 | tail -25

echo "TRACE_ROI_END"

say "3. replay integrity"
# A cassette MISS is a hard 500 from the proxy. If any occurred, the agent
# diverged from the recording and this trace does not correspond to the
# trajectory we think it does.
misses=$(grep -c "REPLAY MISS" /root/proxy_replay.log || true)
echo "  replay misses: $misses"
[ "$misses" -eq 0 ] || { echo "  !! agent diverged from the recording -- trace is not trustworthy"; exit 1; }
echo "  trajectory: $(find "$TRAJ" -name '*.traj' | head -1)"
