#!/usr/bin/env bash
#
# replay_pinned.sh <instance_id> — Pass 3 payload, run INSIDE the guest as root.
#
# Replays the recorded trajectory with NO network, with the agent and every tool
# subprocess pinned to the isolated vCPU. Prints a short serial marker
# immediately before the agent starts so the host can arm the tracing trigger.
#
# Used unchanged for both the sizing (profile) pass and the traced pass -- they
# must be the same execution or the measured instruction total does not describe
# the run being sampled.
#
set -euo pipefail

SWE_TOOLS_DIR=${SWE_TOOLS_DIR:-/opt/swe-agent-tools}
. "$SWE_TOOLS_DIR/lib/common.sh"
load_instance "${1:-}"

API_BASE=http://127.0.0.1:8000/api/paas/v4
TRAJ=/opt/trajectories-replay/$INSTANCE
PIN_CPU=${PIN_CPU:-1}

# SWE-agent kills a tool command after execution_timeout (default 30s) and ends
# the episode after max_consecutive_execution_timeouts (default 3). Both are
# interactive guards, and both are actively harmful here: the replay pins the
# agent and every tool subprocess to ONE vCPU, so a command that took 12s on 32
# cores during recording takes minutes -- and under TCG, hours.
#
# Measured: the redis run recorded 77 steps and replayed only 54, exiting
# `submitted (exit_command_timeout)` with a 609-byte patch instead of the
# correct 1307-byte one. It reported ZERO cassette misses throughout, because
# sequence replay serves recorded responses in order and simply stops early --
# a complete, valid trace of the wrong execution.
#
# The recorded trajectory is fixed, so there is nothing for a timeout to
# protect against. Effectively disabled; override if you need a real bound.
# 30 min per command, not 10 h. The original 30 SECOND default is what
# truncated the redis capture -- it fired mid-workload and produced a complete,
# zero-miss trace of a half-finished run -- so timeouts were disabled outright.
# That traded truncation for indefinite hangs: gin-2121's replay wedged with
# SWE-ReX's shell in do_select on its PTY and would have sat there for ten
# hours holding a slot.
#
# 1800 s is chosen to be far above any real command here (the longest measured
# workload command is a redis test suite in minutes; immutable-js's full jest
# run is 15 s) while still being finite. If a command legitimately needs longer,
# raise it per instance rather than disabling it again.
# 1800 was calibrated against KVM-speed commands. Under TCG the machine is ~50x
# slower, so 1800 s of TCG is roughly 36 SECONDS of real work -- far too tight
# for a maven or cmake build. javaparser-4538 proved it: its profile pass
# completed in 90 min, and its TRACE pass (same trajectory, plus tracing
# instrumentation on top of TCG) died on
#     CommandTimeoutError: timeout after 1800.0 seconds
# followed by "Failed to interrupt session" and a truncated autosubmit.
#
# 7200 keeps the bound FINITE, which is the point -- gin-2121 showed what an
# unbounded replay costs -- while leaving room for a real build. A genuine hang
# now holds a TCG slot for 2 h instead of 30 min, which campaign_watch.sh
# detects long before that from the guest's CPU accrual.
EXEC_TIMEOUT=${EXEC_TIMEOUT:-7200}       # 2 h per command; see the note above
TOTAL_TIMEOUT=${TOTAL_TIMEOUT:-604800}   # 7 d per episode

# NEITHER of the above governs SWE-agent's STATE command, and that is what ends
# episodes under TCG. sweagent/tools/tools.py:345 calls
#     env.communicate(state_command, check="warn")
# with NO timeout argument, so it inherits a hardcoded 25 s default that
# --agent.tools.execution_timeout cannot reach. Three consecutive state-command
# timeouts then end the run ("Exit due to multiple consecutive command
# timeouts") and SWE-agent autosubmits a truncated patch.
#
# Under KVM the state command is trivial. Under TCG the machine is ~50x slower,
# and preactjs__preact-4182 shows the difference exactly: 122 of 122 actions
# replayed in verify (KVM), then 70 and 71 of 122 in profile (TCG), on the same
# trajectory and the same guest image.
#
# check="warn" means a timed-out state command is NOT fatal in itself, and in a
# REPLAY the state it gathers cannot change what happens next: the model's
# responses come from cassettes, so the action sequence is fixed regardless.
# Raising the consecutive limit therefore lets the replay finish without
# changing which actions run -- and it is behaviour-neutral for every capture
# that never times out, which is all of them so far.
# TESTED AND IT DOES NOT HELP -- kept only because it is harmless and the next
# person will otherwise try it too. agents.py has TWO exit paths: line 969
# compares _n_consecutive_timeouts against this setting, but line 1168 is a bare
# `except CommandTimeoutError:` that exits on the FIRST such exception and logs
# "Exiting due to multiple consecutive command timeouts" -- naming a counter it
# never consults. Our failures take that second path, so raising this to 100
# changed preact-4182 not at all: 71 of 122 actions before and after.
#
# The real limit is swe_env.py:197 `def communicate(..., timeout=25, ...)`, a
# function-signature default that tools.py:345 does not override. It has no
# config field, no env var and no CLI flag. Only a code patch reaches it.
MAX_CONSEC_TIMEOUTS=${MAX_CONSEC_TIMEOUTS:-100}

[ "$(id -u)" -eq 0 ] || die "must run as root (SWE-agent writes /root/tools)"

say "0. preflight"
git config --global --add safe.directory "$REPO_DIR"
cd "$REPO_DIR"
git checkout --force --quiet "$BASE_COMMIT"
# `git clean -fd`, NOT `-xfd`. The -x also removes IGNORED files, which is the
# entire build output. The recording began with a fully built tree, so wiping it
# turns the agent's first `make` into a from-scratch build of the project and
# all its vendored dependencies where the recording did a one-file incremental
# rebuild. The actions are identical either way, so the trajectory comparison
# cannot see the difference -- but the traced work is off by orders of
# magnitude, and that work is the entire measurement.
git clean -fd --quiet
assert_repo_pristine
n=$(find "$CASS" -name '*.json' 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || die "no cassettes in $CASS -- run the record pass first"
echo "  $n cassettes"

# The isolated CPU must actually be isolated, or the whole capture is noise.
[ "$(cat /sys/devices/system/cpu/isolated)" = "$PIN_CPU" ] || die "cpu $PIN_CPU not isolated"
echo "  cpu $PIN_CPU isolated; taskset sees $(taskset -c "$PIN_CPU" nproc) cpu(s)"

say "1. proxy in REPLAY mode (no network, no key)"
# Pinned to the same CPU as the agent: the proxy's serving work is CPU work
# inside the capture window and belongs in the trace. Logs to /root, not /tmp --
# fs.protected_regular=1 blocks even root from reopening another user's file in
# a sticky directory.
taskset -c "$PIN_CPU" python3 "$SWE_TOOLS_DIR/replay_proxy.py" \
    --mode replay --cassettes "$CASS" --port 8000 \
    > /root/proxy_replay.log 2>&1 &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null || true' EXIT     # by PID, never by pattern
sleep 3
kill -0 $PROXY_PID 2>/dev/null || { cat /root/proxy_replay.log; die "proxy failed"; }
echo "  proxy pid $PROXY_PID pinned to cpu $PIN_CPU"

rm -rf "$TRAJ"; mkdir -p "$TRAJ"

# SWE-agent uploads its tool bundles with shutil.copytree() and no
# dirs_exist_ok, so a second run dies with FileExistsError on /root/tools/...
# Under Docker every run gets a fresh container and this never shows up; under
# the local deployment the previous run's tools persist. Clear them.
rm -rf /root/tools /root/state.json /root/.swe-agent-env
export LITELLM_LOCAL_MODEL_COST_MAP=True

# ---- ROI MARKER -----------------------------------------------------------
# The host tails the serial console for this exact string and arms the tracing
# trigger when it appears. Kept short on purpose: ISA serial is one outb per
# byte, and under TCG every byte is emulated instructions inside the window.
# Write to /dev/console, NOT stdout. This script runs over ssh, so stdout is the
# ssh pipe (and is usually redirected to a log besides) -- it never reaches the
# serial console the host tails.
sleep 2
echo "TRACE_ROI_BEGIN" | tee /dev/console
sleep 2

# --env.repo.reset=False is REQUIRED offline. PreExistingRepoConfig's reset
# sequence starts with `git fetch`, which needs network and fails with exit 128
# ("Failed to clean repository") when there is none. It succeeded during the
# record pass only because the network was up. Step 0 already put the tree at
# base_commit and ran git clean, so SWE-agent's reset is redundant anyway.
say "2. replay (pinned to cpu $PIN_CPU)"
# taskset pins the agent, and fork/exec children INHERIT the affinity, which is
# why the local (non-Docker) deployment was chosen: a Docker daemon would spawn
# tool processes outside this process tree and they would escape the pin.
# SWE-agent's PreExistingRepoConfig treats repo_name as the DIRECTORY the repo
# lives in -- it resolves /<repo_name>. That is NOT what REPO_NAME means in our
# descriptors, where it is the dataset's repo name and stage_instance.py
# hard-fails if it disagrees with the dataset. Passing REPO_NAME sent SWE-agent
# to /gin while the checkout was at /testbed. Derive it from REPO_DIR, the
# actual location; for the August descriptors (REPO_DIR=/gin) this is unchanged.
#
# Computed here, NOT inline in the command below: a comment inside a backslash
# continuation is spliced into the command line and comments out every argument
# after it, which is exactly how repo_name silently went missing once already.
REPO_BASENAME=$(basename "$REPO_DIR")

taskset -c "$PIN_CPU" /opt/venv/bin/sweagent run \
    --agent.model.name="$MODEL" \
    --agent.model.api_base="$API_BASE" \
    --agent.model.api_key=replayed-from-cassettes \
    --agent.model.temperature=0 \
    --agent.model.per_instance_cost_limit=0 \
    --agent.model.total_cost_limit=0 \
    --env.deployment.type=local \
    --env.repo.type=preexisting \
    --env.repo.repo_name="$REPO_BASENAME" \
    --env.repo.base_commit="$BASE_COMMIT" \
    --env.repo.reset=False \
    --agent.tools.execution_timeout="$EXEC_TIMEOUT" \
    --agent.tools.total_execution_timeout="$TOTAL_TIMEOUT" \
    --agent.tools.max_consecutive_execution_timeouts="$MAX_CONSEC_TIMEOUTS" \
    --problem_statement.type=text_file \
    --problem_statement.path="$PROBLEM_STATEMENT" \
    --output_dir="$TRAJ" \
    2>&1 | tee /root/replay_full.log | tail -25
# The FULL log is kept at /root/replay_full.log inside the guest. `tail -25`
# alone discarded the single line recording that a command had been cancelled by
# EXEC_TIMEOUT, which is the difference between a clean replay and a recovered
# one -- redis-12272's cancel had to be inferred from a 31-minute wall clock
# rather than read.

echo "TRACE_ROI_END" | tee /dev/console

say "3. replay integrity"
# A cassette MISS is a hard 500 from the proxy. If any occurred, the agent
# diverged from the recording and this trace does not correspond to the
# trajectory we think it does. This is the single most important gate in the
# pipeline: without it a run with 60 misses still exits 0 and still produces a
# clean, complete, entirely misattributed trace.
misses=$(grep -c "REPLAY MISS" /root/proxy_replay.log || true)
echo "  replay misses: $misses"
[ "$misses" -eq 0 ] || die "agent diverged from the recording -- trace is not trustworthy"

# Zero misses is NOT proof the same execution happened. A replay that stops
# early never misses; it just consumes fewer recorded responses. Compare the
# trajectories themselves.
rep_traj=$(find "$TRAJ" -name '*.traj' | head -1)
rec_traj=$(find "/opt/trajectories/$INSTANCE" -name '*.traj' | head -1)
[ -n "$rep_traj" ] || die "no replay trajectory written"
if [ -n "$rec_traj" ]; then
  # Two comparators, because there are two kinds of recorded trajectory.
  #
  # A trajectory WE recorded has a `trajectory` array whose entries carry
  # SWE-agent's own rendered action strings, and compare_trajectories.py
  # compares those. A FOREIGN trajectory (campaign 2026-09 replays trajectories
  # banked elsewhere) is minified to `history` only -- no `trajectory` array --
  # so compare_trajectories.py would see 0 recorded steps against N replayed
  # ones and kill a perfectly good replay. Reconstructing the rendered strings
  # to satisfy it would be guesswork, and a spurious divergence is worse than no
  # gate: it teaches you to ignore the gate.
  #
  # So dispatch on the shape. verify_foreign_replay.py compares raw tool_calls
  # position by position -- exact, no rendering involved -- and additionally
  # requires the replay to stop exactly at the fed trajectory's first submit.
  if python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('trajectory') else 1)" "$rec_traj" 2>/dev/null; then
    python3 "$SWE_TOOLS_DIR/compare_trajectories.py" "$rec_traj" "$rep_traj" \
      || die "replay is NOT the recorded execution -- do not trace this run"
  else
    echo "  recorded trajectory is minified (no 'trajectory' array) -- using the foreign-replay gate"
    python3 "$SWE_TOOLS_DIR/verify_foreign_replay.py" "$rec_traj" "$rep_traj" \
      || die "replay did not execute the fed actions faithfully -- do not trace this run"
  fi
else
  echo "  [warn] no recorded trajectory on this image to compare against"
fi
