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
# Pin git's wire protocol to v1. GitHub's protocol-v2 handshake started failing
# from this host on 2026-09-02, and it fails in a maximally misleading way: git
# reports `could not read Username for 'https://github.com'` followed by
# `expected flush after ref listing`, which reads like an auth or rate-limit
# problem and is neither. Measured the same day -- curl GET of info/refs and
# POST of git-upload-pack both return HTTP 200 with a valid v2 ref listing, the
# API reports 60/60 requests remaining, there is no credential helper and no
# GITHUB_TOKEN, and the failure reproduces identically with the sandbox off.
# `protocol.version=0` and `=1` both succeed against the same URL in the same
# second that `=2` fails. It cost jekyll-8167 its last attempt, 60 seconds in,
# before any of the real work ran.
# Written to /etc/gitconfig rather than exported, so it also covers the clone
# below that runs under sudo, and every git the AGENT runs as root later.
sudo git config --system protocol.version 1
# A FULL clone on purpose. Blobless/shallow clones save a few hundred MB but
# break `git log -p`, `git show <old-sha>` and `git blame` offline, and
# SWE-agent routinely runs git history commands while exploring.
# RETRIED, because the clone is not reliable from this host. Pinning v1 above
# fixes the v2 handshake, but GitHub still throttles git operations from this IP
# and drops larger clones part-way with `the remote end hung up unexpectedly`
# (fluentd-3328, 2026-09-02: failed once, succeeded on the very next attempt with
# no other change). An unretried clone turns that into a provisioning failure
# booked against the instance, which is how jekyll-8167 spent its last attempt.
# The partial checkout is removed between tries: git refuses to clone into a
# non-empty directory, so a leftover would turn one flake into a hard failure.
sudo mkdir -p "$REPO_DIR"; sudo chown ubuntu:ubuntu "$REPO_DIR"
# Prefer the bare mirror the HOST staged at /opt/repo-cache/<name>.git. The
# guest reaches the network through QEMU's user-mode (SLIRP) stack, which drops
# larger clones outright: fluentd-3328 failed 5 of 5 in-guest attempts on
# 2026-09-02 while the identical clone succeeded from the host minutes earlier.
# Cloning from a local path removes GitHub from the guest's path completely.
CLONE_SRC=$REPO_URL
if [ -d "/opt/repo-cache/$REPO_NAME.git" ]; then
  CLONE_SRC=/opt/repo-cache/$REPO_NAME.git
  say "cloning from the host-staged mirror ($CLONE_SRC)"
fi
if [ ! -d "$REPO_DIR/.git" ]; then
  tries=0 max=${GIT_CLONE_RETRIES:-5}
  until git clone "$CLONE_SRC" "$REPO_DIR"; do
    tries=$((tries + 1))
    [ "$tries" -lt "$max" ] || die "git clone failed $max times -- see the throttling note above"
    say "clone attempt $tries failed; retrying in $((tries * 20))s"
    sudo rm -rf "$REPO_DIR"
    sleep $((tries * 20))
    sudo mkdir -p "$REPO_DIR"; sudo chown ubuntu:ubuntu "$REPO_DIR"
  done
fi
cd "$REPO_DIR"
# Point origin at the real remote even when we cloned from the local mirror --
# the recording's checkout had it, and a /opt/repo-cache path left in
# .git/config is a visible difference in the environment under trace.
[ "$CLONE_SRC" = "$REPO_URL" ] || git remote set-url origin "$REPO_URL"
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
  # From the host-staged mirror when present, for the same SLIRP reason as
  # /testbed above: fluentd-3328 cleared its whole offline gate and then died
  # here, on the one clone that still went to GitHub.
  if [ -d /opt/repo-cache/SWE-agent.git ]; then
    sudo git clone /opt/repo-cache/SWE-agent.git /opt/swe-agent \
      && sudo git -C /opt/swe-agent remote set-url origin https://github.com/SWE-agent/SWE-agent.git
  else
    sudo git clone https://github.com/SWE-agent/SWE-agent.git /opt/swe-agent
  fi
  sudo chown -R ubuntu:ubuntu /opt/swe-agent
fi
# /opt is root-owned, so `python3 -m venv /opt/venv` fails as ubuntu. It must be
# created and handed over FIRST. (An earlier version wrote `|| true` here, which
# turned that failure into a confusing "no such file: /opt/venv/bin/pip" three
# lines later -- never suppress an error you have not understood.)
# Existence is not health. A run that died after `pip install -e` left a venv
# whose /opt/venv/bin/sweagent was a ZERO-BYTE file and whose sweagent module
# would not import at all -- and because /opt/venv/bin/python existed, the old
# guard skipped rebuilding, so the next run failed later at the CLI check with
# no hint why. Test what must be true, not that a path exists.
venv_healthy() {
  [ -x /opt/venv/bin/python ] && [ -s /opt/venv/bin/pip ] \
    && /opt/venv/bin/python -c 'import sys' >/dev/null 2>&1
}
if ! venv_healthy; then
  if [ -e /opt/venv ]; then
    say "venv present but unhealthy -- rebuilding from scratch"
    sudo rm -rf /opt/venv
  fi
  sudo mkdir -p /opt/venv
  sudo chown ubuntu:ubuntu /opt/venv
  python3 -m venv /opt/venv
fi
[ -x /opt/venv/bin/pip ] || die "venv creation failed: no /opt/venv/bin/pip"
/opt/venv/bin/pip install --quiet --upgrade pip
/opt/venv/bin/pip install --quiet -e /opt/swe-agent
# pip can exit 0 having produced an unusable install: a truncated entry point,
# or an editable .pth pointing nowhere. Check the two things that must hold.
/opt/venv/bin/python -c 'import sweagent' >/dev/null 2>&1 \
  || die "sweagent is not importable -- venv is broken; remove /opt/venv and re-run"
[ -s /opt/venv/bin/sweagent ] \
  || die "/opt/venv/bin/sweagent is empty -- pip produced a truncated entry point"
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
  # SWE-ReX's own SOURCE DIGEST. `pip freeze` gives its VERSION, which does not
  # change when a file is edited in place -- and every proposed fix for the two
  # replay defects (gin's PTY wedge, the 25 s state-command timeout) is a local
  # patch to exactly this package. Without a content digest a patched capture is
  # indistinguishable from an unpatched one after the fact, which is the gap
  # gin's write-up 4.1.3 says must close BEFORE any patch is applied.
  # Sorted so the digest does not depend on filesystem ordering.
  echo "swerex_version=$(/opt/venv/bin/pip show swe-rex 2>/dev/null | awk '/^Version:/{print $2}')"
  echo "swerex_sha256=$(find /opt/venv/lib/python*/site-packages/swerex -name '*.py' 2>/dev/null \
      | sort | xargs cat 2>/dev/null | sha256sum | cut -d' ' -f1)"
  # The guest-side tools WE stage, for the same reason: replay_pinned.sh and the
  # lang/ modules are ours and they change between runs.
  echo "guest_tools_sha256=$(find /opt/swe-agent-tools \( -name '*.sh' -o -name '*.py' \) 2>/dev/null \
      | sort | xargs cat 2>/dev/null | sha256sum | cut -d' ' -f1)"
  echo "# --- pip freeze ---"
  /opt/venv/bin/pip freeze 2>/dev/null
} | sudo tee /opt/versions.txt >/dev/null
# /opt is root-owned and this script runs as ubuntu, so a plain redirect fails
# with EACCES -- after the toolchain, the clone and the venv have all been
# built, which is a costly place to die for a bookkeeping step.
sudo chown ubuntu:ubuntu /opt/versions.txt
ok "$(grep -c . /opt/versions.txt) lines -> /opt/versions.txt"

# ---------------------------------------------------------------------------
say "problem statement"
[ -f "$PROBLEM_STATEMENT" ] || die "missing $PROBLEM_STATEMENT -- stage it from the host first"
ok "$(wc -c <"$PROBLEM_STATEMENT") bytes at $PROBLEM_STATEMENT"

say "PROVISIONING COMPLETE"
echo "  instance:  $INSTANCE"
echo "  repo:      $REPO_DIR @ $(git -C "$REPO_DIR" rev-parse --short=12 HEAD)"
echo "  disk:      $(df -h / | awk 'NR==2{print $4" free"}')"
