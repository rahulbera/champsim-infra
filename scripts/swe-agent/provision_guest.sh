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
say "problem statement"
[ -f "$PROBLEM_STATEMENT" ] || die "missing $PROBLEM_STATEMENT -- stage it from the host first"
ok "$(wc -c <"$PROBLEM_STATEMENT") bytes at $PROBLEM_STATEMENT"

say "PROVISIONING COMPLETE"
echo "  instance:  $INSTANCE"
echo "  repo:      $REPO_DIR @ $(git -C "$REPO_DIR" rev-parse --short=12 HEAD)"
echo "  disk:      $(df -h / | awk 'NR==2{print $4" free"}')"
