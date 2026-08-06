#!/usr/bin/env bash
#
# lang/ruby_bundler.sh — Ruby projects using bundler (rubocop, fluentd, ...).
#
# Instance env must supply: APT_PACKAGES, GATE_BUILD_CMD, GATE_TEST_CMD,
# GATE_MIN_TESTS.
#
# Ruby is the interpreted arm of the language comparison. MRI/YARV is a bytecode
# interpreter with a computed-goto dispatch loop, structurally close to CPython,
# so this is the closest available check on the original "interpreter dispatch
# dominates the frontend" hypothesis -- and it compares against SPEC's
# 714.cpython_r, which is the same kind of machine running a different workload.

lang_toolchain() {
  say "toolchain: system Ruby + bundler"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PACKAGES
  command -v ruby   >/dev/null || die "ruby not installed"
  command -v bundle >/dev/null || die "bundler not installed"
  ok "$(ruby --version), bundler $(bundle --version | awk '{print $3}')"
}

lang_deps() {
  say "gems"
  # The gem path is set GLOBALLY, never with `bundle config set --local`.
  # --local writes .bundle/config INSIDE the repo, which shows up in
  # `git status` and is silently absorbed into the agent's `git diff` answer --
  # the same class of corruption as a stray build artifact, but harder to spot
  # because the file is dot-prefixed.
  sudo mkdir -p /opt/bundle
  sudo chown -R ubuntu:ubuntu /opt/bundle
  bundle config set --global path /opt/bundle
  bundle config set --global jobs "$(nproc)"

  cd "$REPO_DIR"
  bundle install >/tmp/provision_bundle.log 2>&1 \
    || { tail -40 /tmp/provision_bundle.log; die "bundle install failed"; }
  ok "gems installed into /opt/bundle"

  # bundle install rewrites Gemfile.lock whenever it resolves anything
  # differently from what is checked in. That lands in the patch.
  local dirty
  dirty=$(git status --porcelain)
  if [ -n "$dirty" ]; then
    echo "  restoring files touched by bundler:"; echo "$dirty" | sed 's/^/    /'
    git checkout -- . || die "could not restore the tree after bundle install"
  fi
  [ -z "$(git status --porcelain)" ] || die "tree still dirty after restore"
  ok "tree clean"
  du -sh /opt/bundle 2>/dev/null | sed 's/^/  gems: /'
}

lang_offline_gate() {
  OFFLINE_ENV=(BUNDLE_PATH=/opt/bundle BUNDLE_FROZEN=true GEM_HOME=/opt/bundle)
  local log=/tmp/offline_gate.log
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD && $GATE_TEST_CMD" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # RSpec prints "N examples, M failures". Zero examples is a PASS as far as the
  # exit code is concerned, and is exactly what a mistyped spec path produces.
  local n
  n=$(grep -oE '^[0-9]+ examples?,' "$log" | tail -1 | grep -oE '^[0-9]+' || true)
  [ -n "$n" ] || { tail -30 "$log"; die "no rspec example count in the gate output"; }
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n examples, expected >= ${GATE_MIN_TESTS:-1}"; }
  ok "offline gate: ran $n rspec examples with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  [ ! -e "$REPO_DIR/.bundle/config" ] \
    || die ".bundle/config exists in the repo -- use the global bundler config"
  ok "no stray files"
}
