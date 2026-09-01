#!/usr/bin/env bash
#
# provision_guest.sh <instance_id> — Pass 1 provisioning, run INSIDE the guest.
#
# Installs the language toolchain, the repo checkout at the benchmark's
# base_commit, a fully populated offline dependency cache, and SWE-agent.
#
# Idempotent: safe to re-run. Every step that could silently produce a wrong
# result ends in an assertion, because the failure modes here do not announce
# themselves -- they show up hours later as a corrupt trace.
#
set -euo pipefail

SWE_TOOLS_DIR=${SWE_TOOLS_DIR:-/opt/swe-agent-tools}
. "$SWE_TOOLS_DIR/lib/common.sh"
load_instance "${1:-}"

say "instance $INSTANCE ($LANG_MODULE)"
echo "  repo   $REPO_URL -> $REPO_DIR"
echo "  commit $BASE_COMMIT"

# ---------------------------------------------------------------------------
lang_toolchain

# ---------------------------------------------------------------------------
say "checkout at ${BASE_COMMIT:0:12}"
# A FULL clone on purpose. Blobless/shallow clones save a few hundred MB but
# break `git log -p`, `git show <old-sha>` and `git blame` offline, and
# SWE-agent routinely runs git history commands while exploring.
if [ ! -d "$REPO_DIR/.git" ]; then
  sudo mkdir -p "$REPO_DIR"
  sudo chown ubuntu:ubuntu "$REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"
git config --global --add safe.directory "$REPO_DIR"
git fetch --all --tags --quiet || true
git checkout --quiet --force "$BASE_COMMIT"
git clean -xfd --quiet
[ "$(git rev-parse HEAD)" = "$BASE_COMMIT" ] || die "HEAD is $(git rev-parse HEAD), expected $BASE_COMMIT"
ok "HEAD = $(git rev-parse --short=12 HEAD)"

# Some projects vendor a dependency as a git submodule (jq/oniguruma), which a
# plain clone+checkout leaves empty. The build then fails in a way that reads
# like a missing system library. Runs BEFORE the dependency step, and the tree
# must still be clean afterwards -- submodule state lives in .git, not the tree.
if [ -n "${POST_CHECKOUT_CMD:-}" ]; then
  say "post-checkout: $POST_CHECKOUT_CMD"
  eval "$POST_CHECKOUT_CMD" >/tmp/provision_postcheckout.log 2>&1 \
    || { tail -20 /tmp/provision_postcheckout.log; die "post-checkout command failed"; }
  [ -z "$(git status --porcelain)" ] \
    || die "post-checkout dirtied the tree: $(git status --porcelain | head -3)"
  ok "done, tree still clean"
fi

# The agent must start from a pristine tree, or its final `git diff` carries
# unrelated noise and SWE-bench grading fails confusingly.
[ -z "$(git status --porcelain)" ] || die "tree dirty before provisioning finished"
ok "tree clean"

# ---------------------------------------------------------------------------
lang_deps

# ---------------------------------------------------------------------------
say "OFFLINE GATE (the real test of the dependency cache)"
# The dependency step having succeeded proves nothing: it ran WITH network, so a
# missing dependency is fetched on demand and never noticed. This is the only
# check that fails here rather than mid-trace, where it surfaces as a hang on
# DNS inside the capture window.
lang_offline_gate
lang_clean_check

# ---------------------------------------------------------------------------
say "SWE-agent"
if [ ! -d /opt/swe-agent ]; then
  sudo git clone https://github.com/SWE-agent/SWE-agent.git /opt/swe-agent
  sudo chown -R ubuntu:ubuntu /opt/swe-agent
fi
# /opt is root-owned, so `python3 -m venv /opt/venv` fails as ubuntu. It must be
# created and handed over FIRST. (An earlier version wrote `|| true` here, which
# turned that failure into a confusing "no such file: /opt/venv/bin/pip" three
# lines later -- never suppress an error you have not understood.)
if [ ! -x /opt/venv/bin/python ]; then
  sudo mkdir -p /opt/venv
  sudo chown ubuntu:ubuntu /opt/venv
  python3 -m venv /opt/venv
fi
[ -x /opt/venv/bin/pip ] || die "venv creation failed: no /opt/venv/bin/pip"
/opt/venv/bin/pip install --quiet --upgrade pip
/opt/venv/bin/pip install --quiet -e /opt/swe-agent
/opt/venv/bin/sweagent --help >/dev/null 2>&1 || die "sweagent CLI not working"
ok "sweagent installed: $(/opt/venv/bin/python -c 'import sweagent; print(sweagent.__version__)' 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
say "record installed versions"
# SWE-agent is cloned UNPINNED and `pip install -e` resolves ~22 unbounded
# dependency floors, so what is installed is whatever PyPI served that day.
# Nothing used to record it: the provisioning output was piped through
# `| tail -40` on the host and the version line was discarded. The August
# captures agreed on their w0 signature because they were all provisioned
# inside a 20-hour window, not because anything enforced it -- and w0 measures
# precisely this import graph. Without this file there is no way to tell which
# software generation a trace belongs to.
{
  echo "# captured at provisioning time; consumed by the host into artifacts/<id>/"
  echo "instance=$INSTANCE"
  echo "swe_agent_commit=$(git -C /opt/swe-agent rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "swe_agent_describe=$(git -C /opt/swe-agent describe --always --tags --dirty 2>/dev/null || echo unknown)"
  echo "python=$(/opt/venv/bin/python --version 2>&1)"
  echo "kernel=$(uname -r)"
  echo "# --- pip freeze ---"
  /opt/venv/bin/pip freeze 2>/dev/null
} > /opt/versions.txt
ok "$(grep -c . /opt/versions.txt) lines -> /opt/versions.txt"

# ---------------------------------------------------------------------------
say "problem statement"
[ -f "$PROBLEM_STATEMENT" ] || die "missing $PROBLEM_STATEMENT -- stage it from the host first"
ok "$(wc -c <"$PROBLEM_STATEMENT") bytes at $PROBLEM_STATEMENT"

say "PROVISIONING COMPLETE"
echo "  instance:  $INSTANCE"
echo "  repo:      $REPO_DIR @ $(git -C "$REPO_DIR" rev-parse --short=12 HEAD)"
echo "  disk:      $(df -h / | awk 'NR==2{print $4" free"}')"
