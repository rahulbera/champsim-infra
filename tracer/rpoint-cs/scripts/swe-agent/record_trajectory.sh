#!/usr/bin/env bash
#
# record_trajectory.sh <instance_id> — Pass 2, run INSIDE the guest, network UP.
#
# Starts the replay proxy in RECORD mode, runs SWE-agent once against the real
# LLM through it, and leaves a cassette per exchange. After this, every replay
# is offline, free, and byte-identical.
#
# The API key is read from $LLM_API_KEY and is never written to disk: the proxy
# persists only Content-Type from each response.
#
set -euo pipefail

SWE_TOOLS_DIR=${SWE_TOOLS_DIR:-/opt/swe-agent-tools}
. "$SWE_TOOLS_DIR/lib/common.sh"
load_instance "${1:-}"

API_BASE=http://127.0.0.1:8000/api/paas/v4
TRAJ=/opt/trajectories/$INSTANCE

: "${LLM_API_KEY:?LLM_API_KEY must be set (Pass 2 only)}"

# MUST run as root. SWE-agent hardcodes its tool paths -- /root/tools,
# /root/state.json and /root/.swe-agent-env are f-strings in
# sweagent/tools/tools.py, not configuration. That is harmless under Docker,
# where the agent owns the container, but under the LOCAL deployment it means
# the agent process needs a writable /root. Running as root does not weaken the
# isolation: taskset and cgroup cpuset pin root exactly as they pin any user.
[ "$(id -u)" -eq 0 ] || die "must run as root (SWE-agent writes /root/tools); use: sudo -E $0 $INSTANCE"

say "0. preflight"
# The repo is owned by ubuntu but git now runs as root, tripping git's
# dubious-ownership check. It surfaces as "detected dubious ownership", or via
# Go's -buildvcs as "error obtaining VCS status: exit status 128" -- which reads
# like a network fault and is not.
assert_repo_pristine
[ -f "$PROBLEM_STATEMENT" ] || die "no problem statement at $PROBLEM_STATEMENT"

mkdir -p "$CASS" "$TRAJ"
[ -w "$CASS" ] && [ -w "$TRAJ" ] || die "cassette/trajectory dirs not writable"

# Logs go to /root, not /tmp. Ubuntu sets fs.protected_regular=1, which blocks
# even root from opening an existing file owned by another user inside a sticky
# world-writable directory -- so a /tmp log left behind by an earlier non-root
# run makes this fail with a bare "Permission denied" that looks impossible.
say "1. start proxy in RECORD mode"
python3 "$SWE_TOOLS_DIR/replay_proxy.py" \
    --mode record --cassettes "$CASS" --upstream "$UPSTREAM" --port 8000 \
    > /root/proxy_record.log 2>&1 &
PROXY_PID=$!
# Kill by PID, never by pattern: a `pkill -f replay_proxy` also matches the
# shell running THIS script and takes it down with the proxy.
trap 'kill $PROXY_PID 2>/dev/null || true' EXIT
sleep 3
kill -0 $PROXY_PID 2>/dev/null || { cat /root/proxy_record.log; die "proxy failed to start"; }
echo "  proxy pid $PROXY_PID on :8000 -> $UPSTREAM"

# SWE-agent uploads its tool bundles with shutil.copytree() and no
# dirs_exist_ok, so a SECOND record attempt dies with
# FileExistsError: /root/tools/registry. Under Docker every run gets a fresh
# container and this never appears; under the local deployment the previous
# attempt's tools persist -- and any attempt that was interrupted leaves them
# behind. replay_pinned.sh already clears them; recording must too, or a
# retry after an interruption can never succeed.
rm -rf /root/tools /root/state.json /root/.swe-agent-env

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
    --env.repo.repo_name="$REPO_BASENAME" \
    --env.repo.base_commit="$BASE_COMMIT" \
    --agent.tools.execution_timeout="${EXEC_TIMEOUT:-36000}" \
    --agent.tools.total_execution_timeout="${TOTAL_TIMEOUT:-604800}" \
    --problem_statement.type=text_file \
    --problem_statement.path="$PROBLEM_STATEMENT" \
    --output_dir="$TRAJ" \
    2>&1 | tail -40

say "3. results"
n=$(find "$CASS" -name '*.json' | wc -l)
echo "  cassettes recorded: $n"
[ "$n" -gt 0 ] || die "NO CASSETTES — recording failed"
grep -qil "authorization" "$CASS"/*.json && die "API KEY LEAKED INTO CASSETTE"
echo "  no Authorization header in any cassette"

traj=$(find "$TRAJ" -name '*.traj' | head -1)
[ -n "$traj" ] || die "no trajectory written"
# Read the FINAL trajectory, never a partially-written one: an earlier run was
# reported at "28 of 36 steps, 0 Go steps" from a .traj still being appended to,
# and the finished file had 147 steps and 30 Go steps.
python3 - "$traj" <<'PY'
import json, sys, collections
t = json.load(open(sys.argv[1]))
steps = t.get("trajectory", [])
info = t.get("info", {})
print(f"  steps:       {len(steps)}")
print(f"  exit_status: {info.get('exit_status')}")
patch = info.get("submission") or ""
print(f"  patch:       {len(patch)} bytes")
cmds = collections.Counter()
for s in steps:
    a = (s.get("action") or "").strip().split()
    if a:
        cmds[a[0]] += 1
print("  commands:    " + ", ".join(f"{k}:{v}" for k, v in cmds.most_common(8)))
PY
echo "  repo state after run: [$(cd "$REPO_DIR" && git status --porcelain | head -3)]"
