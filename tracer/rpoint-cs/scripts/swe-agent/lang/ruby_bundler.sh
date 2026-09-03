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

  # The gem path is exported to EVERY shell, not just set in bundler's config.
  # `bundle config set --global` writes ~/.bundle/config for the invoking user,
  # and provisioning runs as ubuntu while the agent runs as ROOT -- so root
  # would consult /root/.bundle/config, not find the path, and fall back to the
  # system gem dir with the project's gems missing. Environment variables are
  # the only form that follows the process regardless of which user owns it.
  sudo tee /etc/profile.d/00-ruby.sh >/dev/null <<'EOF'
export BUNDLE_PATH=/opt/bundle
export GEM_HOME=/opt/bundle
export BUNDLE_JOBS=4
EOF
  export BUNDLE_PATH=/opt/bundle GEM_HOME=/opt/bundle BUNDLE_JOBS=$(nproc)

  # Gems the recording'"'"'s image had but a stock Ubuntu guest does not. Ruby 3
  # moved several stdlib libraries out to BUNDLED gems (webrick, and others),
  # so a repo whose test helper requires one loads fine in the SWE-bench image
  # and dies here.
  #
  # INSTALLING THE GEM IS NOT ENOUGH, and this is the whole trap: `bundle exec`
  # prunes $LOAD_PATH to the gems named in Gemfile.lock, so a gem the lockfile
  # does not mention is unrequirable NO MATTER WHERE IT IS INSTALLED. jekyll'"'"'s
  # `sudo gem install webrick` succeeded and every single test file still died
  # with `cannot load such file -- webrick`, because bundler had already
  # removed the system gem dir from the load path.
  #
  # RUBYLIB is the one channel bundler leaves alone: Ruby puts those entries on
  # $LOAD_PATH at startup, and Bundler'"'"'s cleanup only drops entries rooted in a
  # gem path. So install the gem, then put its require path on RUBYLIB.
  #
  # The alternative -- adding it to the Gemfile -- also works and is rejected:
  # it rewrites Gemfile and Gemfile.lock, which lands in the agent'"'"'s own
  # `git diff` answer and corrupts the artifact we are trying to measure.
  RUBYLIB_EXTRA=""
  if [ -n "${EXTRA_BUNDLE_GEMS:-}" ]; then
    say "gems outside the bundle: $EXTRA_BUNDLE_GEMS"
    for g in $EXTRA_BUNDLE_GEMS; do
      # Into GEM_HOME (/opt/bundle, owned by ubuntu), NOT system-wide with
      # sudo: sudo resets the environment, so the gem would land in the
      # root-owned system dir while the lookup below runs under GEM_HOME.
      gem install "$g" --no-document >/tmp/provision_extragem.log 2>&1 \
        || { tail -20 /tmp/provision_extragem.log; die "gem install $g failed"; }
      gp=$(ruby -e "puts Gem::Specification.find_by_name('"'"'$g'"'"').full_require_paths" \
           2>/dev/null | tr '"'"'\n'"'"' '"'"':'"'"')
      [ -n "$gp" ] || die "installed $g but cannot locate its require path"
      RUBYLIB_EXTRA="${RUBYLIB_EXTRA}${gp}"
      ok "$g -> ${gp%:}"
    done
    RUBYLIB_EXTRA=${RUBYLIB_EXTRA%:}
    # Exported to every shell for the same reason BUNDLE_PATH is: provisioning
    # runs as ubuntu, the agent runs as root.
    echo "export RUBYLIB=$RUBYLIB_EXTRA" | sudo tee -a /etc/profile.d/00-ruby.sh >/dev/null
    export RUBYLIB=$RUBYLIB_EXTRA
  fi

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

  # The decisive check. `gem list` proving webrick is installed is exactly the
  # evidence that made jekyll look provisioned four times; the only question
  # that matters is whether it is requirable UNDER BUNDLE EXEC, which is how
  # both the gate and the traced agent will load it.
  for g in ${EXTRA_BUNDLE_GEMS:-}; do
    (cd "$REPO_DIR" && bundle exec ruby -e "require '$g'" >/dev/null 2>&1) \
      || die "$g installed but NOT requirable under bundle exec -- RUBYLIB did not take"
    ok "require '$g' works under bundle exec"
  done
}

lang_offline_gate() {
  OFFLINE_ENV=(BUNDLE_PATH=/opt/bundle BUNDLE_FROZEN=true GEM_HOME=/opt/bundle)
  # run_offline builds a clean environment, so an unexported RUBYLIB would be
  # dropped precisely where it is needed.
  [ -n "${RUBYLIB_EXTRA:-}" ] && OFFLINE_ENV+=("RUBYLIB=$RUBYLIB_EXTRA")
  local log=/tmp/offline_gate.log
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD && $GATE_TEST_CMD" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # Zero tests is a PASS as far as the exit code is concerned, and is exactly
  # what a mistyped test path produces -- so the count is the real gate.
  #
  # TAKE THE MAXIMUM ACROSS ALL THREE FRAMEWORKS, not the first one that matches.
  # A single file can produce TWO summary lines: faker-2705's test_avatar.rb runs
  # under test-unit and prints
  #     8 tests, 8 assertions, 0 failures, 0 errors, 0 pendings, ...
  # and then minitest's autorun fires at exit with nothing registered and prints
  #     0 runs, 0 assertions, 0 failures, 0 errors, 0 skips
  # Fixed precedence (rspec, then runs, then tests) picked minitest's ZERO and
  # rejected a gate in which 8 tests had demonstrably passed -- the coverage
  # report in the same log proves they ran.
  #
  # The honest question is "how many tests actually ran", so take the largest
  # count any recognised framework reported.
  # IF-BLOCKS, NOT `[ ] && [ ] && { }`. This module runs under `set -euo
  # pipefail`, where a false `&&` chain evaluates to 1 and kills the script --
  # silently, before any [FAIL] line is printed. The first version of this
  # counter did exactly that and faker-2705's gate produced NO output at all,
  # which is strictly worse than the wrong count it replaced. attempts.sh
  # carries a comment about this same trap; I walked into it anyway.
  local n=0 unit=tests c
  c=$(grep -oE '^[0-9]+ examples?,' "$log" | grep -oE '^[0-9]+' | sort -n | tail -1 || true)
  if [ -n "$c" ] && [ "$c" -gt "$n" ]; then n=$c; unit=examples; fi
  c=$(grep -oE '^[0-9]+ runs?,' "$log" | grep -oE '^[0-9]+' | sort -n | tail -1 || true)
  if [ -n "$c" ] && [ "$c" -gt "$n" ]; then n=$c; unit=runs; fi
  c=$(grep -oE '^[0-9]+ tests?,' "$log" | grep -oE '^[0-9]+' | sort -n | tail -1 || true)
  if [ -n "$c" ] && [ "$c" -gt "$n" ]; then n=$c; unit=tests; fi
  grep -qE '^[0-9]+ (examples?|runs?|tests?),' "$log" \
    || { tail -30 "$log"; die "no rspec/minitest/test-unit count in the gate output"; }
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n $unit, expected >= ${GATE_MIN_TESTS:-1}"; }
  ok "offline gate: ran $n $unit with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  [ ! -e "$REPO_DIR/.bundle/config" ] \
    || die ".bundle/config exists in the repo -- use BUNDLE_PATH instead"
  # The agent runs as root. Prove the gems resolve THERE, not just for the user
  # that provisioned them -- otherwise the first `bundle exec` of the traced run
  # fails on a missing gem, hours in.
  sudo -i bash -c "cd $REPO_DIR && bundle check" >/dev/null 2>&1 \
    || die "bundle check fails as root -- the agent would not find the gems"
  ok "gems resolve as root; no stray files"
}
