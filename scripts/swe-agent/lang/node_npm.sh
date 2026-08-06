#!/usr/bin/env bash
#
# lang/node_npm.sh — JavaScript/TypeScript projects using npm (preact, axios, ...).
#
# Instance env must supply: NODE_VERSION, GATE_BUILD_CMD, GATE_TEST_CMD,
# GATE_MIN_TESTS.
#
# The JIT arm of the language comparison. V8 compiles hot JavaScript at runtime
# and dispatches megamorphic sites through inline caches, which is a third
# execution model again -- neither an interpreter dispatch loop (Ruby/CPython)
# nor statically compiled code (C/Rust/Go). If the indirect share tracks
# execution model rather than language family, this is where it should show.

lang_toolchain() {
  say "toolchain: Node ${NODE_VERSION}"
  # NodeSource rather than the distro package: noble ships whatever Node was
  # current at release, and a project's engines field can reject it.
  if [ "$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)" != "${NODE_VERSION%%.*}" ]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION%%.*}.x" | sudo -E bash -
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  fi
  command -v node >/dev/null || die "node not installed"
  command -v npm  >/dev/null || die "npm not installed"
  ok "node $(node --version), npm $(npm --version)"
}

lang_deps() {
  say "npm packages"
  cd "$REPO_DIR"
  # `npm ci` installs EXACTLY the lockfile and fails if package.json and
  # package-lock.json disagree -- which is what we want, because `npm install`
  # would silently update the lockfile and land it in the agent's patch.
  # node_modules/ is gitignored in every project that ships a lockfile.
  [ -f package-lock.json ] || die "no package-lock.json -- npm ci cannot be used, and npm install rewrites the lockfile"
  npm ci --no-audit --no-fund >/tmp/provision_npm.log 2>&1 \
    || { tail -40 /tmp/provision_npm.log; die "npm ci failed"; }
  ok "node_modules installed from the lockfile"

  local dirty
  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || die "npm ci dirtied the tree, patch extraction would break:
$(echo "$dirty" | head -10)"
  ok "tree clean"
  du -sh node_modules 2>/dev/null | sed 's/^/  node_modules: /'
}

lang_offline_gate() {
  # npm_config_offline stops any stray `npm` call in the test script from
  # reaching the registry and hanging on DNS inside the capture window.
  OFFLINE_ENV=(npm_config_offline=true npm_config_audit=false npm_config_fund=false CI=true)
  local log=/tmp/offline_gate.log
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD && $GATE_TEST_CMD" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # Jest/mocha print "Tests: N passed" or "N passing". Zero is a passing exit
  # code and is what an empty testPathPattern produces.
  local n
  n=$(grep -oE '([0-9]+) (passed|passing)' "$log" | grep -oE '^[0-9]+' \
      | awk '{if($1>m) m=$1} END{print m+0}')
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n tests, expected >= ${GATE_MIN_TESTS:-1}"; }
  ok "offline gate: built and ran $n tests with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  ok "no stray files"
}
