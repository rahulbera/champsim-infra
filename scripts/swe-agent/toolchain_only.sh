#!/usr/bin/env bash
#
# toolchain_only.sh <instance_id> — the NON-AGENTIC control, run INSIDE the
# guest as root, pinned to the isolated vCPU.
#
# Runs the same build-and-test work the agent drove, with no agent: no LLM, no
# replay proxy, no SWE-agent harness, no Python. Everything else is identical --
# same repo at the same commit, same vCPU, same tracer, same ROI markers.
#
# WHY THIS EXISTS
#
# The first capture came out indirect-dominated in its compute-heavy windows and
# the obvious reading was "agentic workloads stress indirect prediction". But
# those windows were `go build` / `go test` phases, so the result is equally
# consistent with "the Go toolchain stresses indirect prediction" -- a claim
# about compilers, not agents. Every agentic trace contains the toolchain, so no
# amount of agentic traces separates the two.
#
# This does. Trace the toolchain ALONE and subtract:
#   agentic profile == toolchain profile  -> the agent contributes nothing
#                                            distinctive; the finding is about
#                                            compilers
#   agentic profile != toolchain profile  -> the difference IS the agent loop
#
# Determinism comes free here: there is no model in the loop, so the same
# commands run the same way every time. No cassettes, no replay gate.
#
set -euo pipefail

SWE_TOOLS_DIR=${SWE_TOOLS_DIR:-/opt/swe-agent-tools}
. "$SWE_TOOLS_DIR/lib/common.sh"
load_instance "${1:-}"

PIN_CPU=${PIN_CPU:-1}
# How many build+test cycles to run. The window sampler needs enough
# instructions to place its windows across; one cycle is usually too short.
CYCLES=${CYCLES:-6}

[ "$(id -u)" -eq 0 ] || die "must run as root (to match the agentic pass's privileges)"
[ -n "${WORKLOAD_CMD:-}" ] || die "$INSTANCE.env does not set WORKLOAD_CMD"

say "0. preflight"
git config --global --add safe.directory "$REPO_DIR"
cd "$REPO_DIR"
git checkout --force --quiet "$BASE_COMMIT"
# NOT -x: the build tree must survive, exactly as in the agentic pass, or the
# first cycle does a from-scratch build the agentic run never did.
git clean -fd --quiet
assert_repo_pristine
[ "$(cat /sys/devices/system/cpu/isolated)" = "$PIN_CPU" ] || die "cpu $PIN_CPU not isolated"
echo "  cpu $PIN_CPU isolated, $CYCLES cycles of: $WORKLOAD_CMD"

# The agentic pass edits a source file and rebuilds; a pure `make` with nothing
# changed compiles nothing at all and the trace would be of a no-op. Touching
# the file the benchmark's own patch touches reproduces the same incremental
# rebuild the agent triggered.
TOUCH_FILE=${WORKLOAD_TOUCH:-}
[ -z "$TOUCH_FILE" ] || [ -f "$REPO_DIR/$TOUCH_FILE" ] \
  || die "WORKLOAD_TOUCH=$TOUCH_FILE does not exist in the repo"

say "1. marker + workload"
sleep 2
echo "TRACE_ROI_BEGIN" | tee /dev/console
sleep 2

for i in $(seq 1 "$CYCLES"); do
  echo "--- cycle $i/$CYCLES ---"
  [ -z "$TOUCH_FILE" ] || touch "$REPO_DIR/$TOUCH_FILE"
  # Pinned exactly as the agent was; children inherit the affinity.
  # `bash -lc`, not `bash -c`: the language modules put GOENV/CARGO_HOME/
  # BUNDLE_PATH in /etc/profile.d, which a non-login shell never reads. Without
  # this the Go control runs with GOTOOLCHAIN=auto and no module cache, and
  # would try to DOWNLOAD a toolchain with the network down.
  taskset -c "$PIN_CPU" bash -lc "cd $REPO_DIR && $WORKLOAD_CMD" 2>&1 | tail -5
done

echo "TRACE_ROI_END" | tee /dev/console

say "2. done"
echo "  $CYCLES cycles completed"
# The workload must not have left the tree modified, or a rerun differs.
[ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
  || die "workload dirtied the tree: $(cd "$REPO_DIR" && git status --porcelain | head -3)"
echo "  tree clean"
