#!/usr/bin/env bash
#
# lang/php_composer.sh — PHP projects using Composer (carbon, laravel, ...).
#
# Instance env must supply: APT_PACKAGES, GATE_BUILD_CMD, GATE_TEST_CMD,
# GATE_MIN_TESTS.
#
# A second interpreted arm alongside Ruby. The Zend VM is a switch/computed-goto
# bytecode dispatcher like MRI and CPython, so it is a direct replicate of the
# interpreter hypothesis: if Ruby lands near SPEC's 99.8%-indirect cpython
# slice, PHP should too, and "interpreters defeat indirect prediction" stops
# being a single observation.

lang_toolchain() {
  say "toolchain: PHP + Composer"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PACKAGES
  command -v php      >/dev/null || die "php not installed"
  command -v composer >/dev/null || die "composer not installed"
  ok "$(php -v | head -1), $(composer --version 2>/dev/null | head -1)"

  # Composer's cache is per-user (~/.cache/composer) and provisioning runs as
  # ubuntu while the agent runs as root. vendor/ lives in the repo so the
  # INSTALL is shared, but any composer command root runs would still try to
  # populate its own cache -- point both at one place, for every user.
  sudo mkdir -p /opt/composer-cache
  sudo chown -R ubuntu:ubuntu /opt/composer-cache
  sudo tee /etc/profile.d/00-php.sh >/dev/null <<'EOF'
export COMPOSER_HOME=/opt/composer-cache
export COMPOSER_CACHE_DIR=/opt/composer-cache/cache
export COMPOSER_NO_INTERACTION=1
EOF
  export COMPOSER_HOME=/opt/composer-cache COMPOSER_CACHE_DIR=/opt/composer-cache/cache
  ok "composer home pinned to /opt/composer-cache for all users"
}

lang_deps() {
  say "composer packages"
  cd "$REPO_DIR"
  export COMPOSER_HOME=/opt/composer-cache COMPOSER_CACHE_DIR=/opt/composer-cache/cache

  # Composer derives the ROOT package's version FROM GIT. A detached checkout of
  # an old commit has no branch to read, so composer falls back to the clone's
  # default branch -- today's, not the commit's. laravel/framework at a
  # laravel-11 commit therefore resolved as "13.x-dev", and every dev dependency
  # pinning `laravel/framework ^11` came back as an unsatisfiable conflict:
  #
  #     laravel/framework is present at version 13.x-dev and cannot be modified
  #     by Composer
  #
  # which reads like a broken dependency set and is really a wrong self-version.
  # The commit states its own answer in extra.branch-alias, so read it from there
  # rather than hardcoding a version per instance.
  if [ -z "${COMPOSER_ROOT_VERSION:-}" ] && [ -f composer.json ]; then
    COMPOSER_ROOT_VERSION=$(php -r '
      $j = json_decode(file_get_contents("composer.json"), true);
      $a = $j["extra"]["branch-alias"] ?? [];
      echo $a ? reset($a) : "";
    ' 2>/dev/null || true)
  fi
  if [ -n "${COMPOSER_ROOT_VERSION:-}" ]; then
    export COMPOSER_ROOT_VERSION
    ok "root package version pinned to $COMPOSER_ROOT_VERSION (from extra.branch-alias)"
  else
    echo "  no extra.branch-alias in composer.json; letting composer infer the root version"
  fi
  # Prefer `composer install`: it obeys composer.lock exactly, where `update`
  # resolves afresh. But LIBRARIES deliberately do not commit a lock file (carbon
  # gitignores it), so there is nothing to obey and update is the only option.
  # The determinism that matters is still preserved: whatever it resolves is
  # captured in the provisioned image, and every later pass restores that image.
  if [ -f composer.lock ]; then
    composer install --no-interaction --no-progress >/tmp/provision_composer.log 2>&1 \
      || { tail -40 /tmp/provision_composer.log; die "composer install failed"; }
    ok "vendor/ installed from the committed composer.lock"
  else
    echo "  no composer.lock (normal for a library); resolving once and freezing it in the image"
    composer update --no-interaction --no-progress >/tmp/provision_composer.log 2>&1 \
      || { tail -40 /tmp/provision_composer.log; die "composer update failed"; }
    ok "vendor/ resolved; composer.lock written ($(grep -c '"name"' composer.lock 2>/dev/null || echo ?) packages)"
  fi

  local dirty
  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || die "composer dirtied the tree (vendor/ should be gitignored):
$(echo "$dirty" | head -10)"
  ok "tree clean"
  du -sh vendor 2>/dev/null | sed 's/^/  vendor: /'
}

lang_offline_gate() {
  # TZ is passed explicitly. run_offline uses `env -i`, which strips it, and
  # PHP with no date.timezone and no TZ emits warnings or dies depending on
  # configuration -- which is fatal for a DATE/TIME library's test suite. The
  # gate died three times at exactly this point with no output.
  OFFLINE_ENV=(COMPOSER_HOME=/opt/composer-cache COMPOSER_CACHE_DIR=/opt/composer-cache/cache
               HOME=/home/ubuntu TZ=UTC)
  # run_offline builds a clean environment, so the root-version pin must be
  # carried in explicitly or composer re-infers today's branch and the gate
  # fails with the very conflict lang_deps just resolved.
  [ -n "${COMPOSER_ROOT_VERSION:-}" ] && OFFLINE_ENV+=("COMPOSER_ROOT_VERSION=$COMPOSER_ROOT_VERSION")
  local log=/tmp/offline_gate.log
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD && $GATE_TEST_CMD" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # PHPUnit prints "OK (N tests, M assertions)" or "Tests: N". Zero tests is a
  # passing exit code and is what a bad --filter produces.
  local n
  n=$(grep -oE 'OK \([0-9]+ test|Tests: [0-9]+' "$log" | grep -oE '[0-9]+' | tail -1)
  [ -n "$n" ] || { tail -30 "$log"; die "no phpunit test count in the gate output"; }
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n tests, expected >= ${GATE_MIN_TESTS:-1}"; }
  ok "offline gate: ran $n phpunit tests with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  [ -d "$REPO_DIR/vendor" ] || die "vendor/ missing -- the agent would have no dependencies"
  ok "vendor/ present; no stray files"
}
