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
  # APT_PACKAGES is a descriptor field, and until 2026-09-02 this module simply
  # ignored it -- as did go.sh and node_npm.sh, while c_make, java_maven,
  # php_composer and ruby_bundler honoured it. A descriptor could therefore
  # declare a system dependency and have it silently dropped. nushell-13831
  # declared `pkg-config libssl-dev`, got neither, and died on openssl-sys with
  # "pkg-config could not be found" after the whole toolchain had installed.
  if [ -n "${APT_PACKAGES:-}" ]; then
    say "apt packages: $APT_PACKAGES"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PACKAGES
  fi
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

  # Blackhole build-time telemetry hosts.
  #
  # The record pass runs with the network UP and the replay runs with it DOWN,
  # so anything the agent does that reaches the internet succeeds while
  # recording and fails while replaying. immutable-js makes this concrete: its
  # `npm run build` ends in a build:stats step that fetches bundle sizes from
  # bundlephobia.com. Under replay that turns into a DNS timeout burning TCG
  # time inside the capture window, or a build failure the recording never saw.
  #
  # Pointing these at 127.0.0.1 makes the call fail FAST and IDENTICALLY in both
  # passes, which is the property that matters: the recorded environment should
  # behave like the replayed one. Blocking outbound traffic wholesale would be
  # more thorough but would also cut off the LLM endpoint the recording needs.
  local h
  for h in bundlephobia.com registry.npmjs.org.telemetry; do
    grep -q "[[:space:]]$h\$" /etc/hosts 2>/dev/null \
      || echo "127.0.0.1 $h" | sudo tee -a /etc/hosts >/dev/null
  done
  ok "build-time telemetry hosts blackholed"
}

lang_deps() {
  say "npm packages"
  cd "$REPO_DIR"
  # `npm ci` installs EXACTLY the lockfile and fails if package.json and
  # package-lock.json disagree -- which is what we want, because `npm install`
  # would silently update the lockfile and land it in the agent's patch.
  # node_modules/ is gitignored in every project that ships a lockfile.
  # Three package managers, one rule: install EXACTLY the lockfile and fail if it
  # disagrees with package.json. `npm install`/`yarn`/`pnpm install` without the
  # frozen flag would silently rewrite the lockfile and land it in the agent's
  # patch, which corrupts both the measurement and the diff.
  #
  # This module accepted ONLY package-lock.json until 2026-09-02, which quietly
  # excluded every remaining TypeScript pick: vuejs uses pnpm and both docusaurus
  # instances use yarn. immutable-js-2006 was capturable purely because it ships
  # an npm lockfile. That is a coverage hole disguised as a dependency check.
  if [ -f package-lock.json ]; then
    npm ci --no-audit --no-fund >/tmp/provision_npm.log 2>&1 \
      || { tail -40 /tmp/provision_npm.log; die "npm ci failed"; }
    ok "node_modules installed from package-lock.json (npm ci)"
  elif [ -f yarn.lock ]; then
    # USE THE YARN THE REPO VENDORS, if it vendors one. Yarn Berry projects set
    # `yarnPath: .yarn/releases/yarn-X.Y.Z.cjs` in .yarnrc.yml and ship that file
    # in the tree. babel does exactly this (yarn 3.5.0).
    #
    # `npm install -g yarn` gives yarn 1.x CLASSIC, which reads .yarnrc (not
    # .yarnrc.yml), ignores yarnPath, and cannot parse a Berry lockfile at all --
    # so the install fails for a reason that looks like a corrupt lockfile.
    # Corepack would fetch the right version, but it fetches over the NETWORK,
    # which the gate and the traced run do not have. The vendored release is
    # already on disk and is exactly the version the lockfile was written by.
    #
    # It is installed as a PATH shim rather than just used here, because the
    # project's own build invokes `yarn` internally (babel's Makefile does), and
    # those calls must resolve to the same binary.
    local yp=""
    [ -f .yarnrc.yml ] && yp=$(sed -n 's/^yarnPath:[[:space:]]*//p' .yarnrc.yml | tr -d '"'"'"'"' | head -1)
    if [ -n "$yp" ] && [ -f "$REPO_DIR/$yp" ]; then
      say "yarn vendored by the repo: $yp"
      sudo tee /usr/local/bin/yarn >/dev/null <<SHIM
#!/bin/sh
exec node "$REPO_DIR/$yp" "\$@"
SHIM
      sudo chmod +x /usr/local/bin/yarn
      hash -r
      ok "yarn shim -> $(yarn --version 2>/dev/null || echo '?')"
    else
      command -v yarn >/dev/null || sudo npm install -g yarn >/dev/null 2>&1
    fi
    # --immutable is yarn 2+; --frozen-lockfile is yarn 1. Try the modern flag
    # and fall back rather than guessing the major version from the lockfile.
    yarn install --immutable >/tmp/provision_npm.log 2>&1 \
      || yarn install --frozen-lockfile >>/tmp/provision_npm.log 2>&1 \
      || { tail -40 /tmp/provision_npm.log; die "yarn install failed"; }
    ok "node_modules installed from yarn.lock (frozen)"
  elif [ -f pnpm-lock.yaml ]; then
    # Honour package.json's packageManager pin. `npm install -g pnpm` installs
    # the LATEST pnpm, and vuejs/core pins pnpm@9.10.0 -- a whole major behind
    # current, reading a lockfile written by that major. Installing the pinned
    # version is both more faithful to the recording and less likely to reject
    # the lockfile outright. The field can carry a +sha512 integrity suffix,
    # which is not part of the version.
    _pm=$(node -e 'try{const p=(require("./package.json").packageManager||"");
                       console.log(p.startsWith("pnpm@")?p.slice(5).split("+")[0]:"")}
                   catch(e){console.log("")}' 2>/dev/null || true)
    [ -n "$_pm" ] && echo "  package.json pins pnpm@$_pm"
    command -v pnpm >/dev/null || sudo npm install -g "pnpm@${_pm:-latest}" >/dev/null 2>&1
    pnpm install --frozen-lockfile >/tmp/provision_npm.log 2>&1 \
      || { tail -40 /tmp/provision_npm.log; die "pnpm install failed"; }
    ok "node_modules installed from pnpm-lock.yaml (frozen)"
  else
    die "no package-lock.json, yarn.lock or pnpm-lock.yaml -- cannot install a pinned dependency tree"
  fi

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
  # HOME is passed explicitly: run_offline builds a clean environment with
  # `env -i`, and yarn Berry (enableGlobalCache) and make both need a home
  # directory. The php module learned this the same way -- its gate died three
  # times with no output because TZ was stripped.
  OFFLINE_ENV=(npm_config_offline=true npm_config_audit=false npm_config_fund=false
               CI=true HOME=/home/ubuntu)
  local log=/tmp/offline_gate.log
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD && $GATE_TEST_CMD" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # Jest/mocha print "Tests: N passed" or "N passing". Zero is a passing exit
  # code and is what an empty testPathPattern produces.
  # THREE FORMATS, largest wins. jest prints "Tests: N passed", mocha "N
  # passing", and QUNIT's TAP reporter neither -- it prints "# pass N", which
  # three.js-26589 uses. Taking the max rather than the first match is the
  # lesson from ruby_bundler, where fixed precedence picked a framework's ZERO
  # over another's eight in the same log.
  # if-blocks, not `[ ] && { }`: this runs under set -euo pipefail and a false
  # && chain returns 1, which kills the script silently.
  local n=0 c
  c=$(grep -oE '([0-9]+) (passed|passing)' "$log" | grep -oE '^[0-9]+' \
      | awk '{if($1>m) m=$1} END{print m+0}' || true)
  if [ -n "$c" ] && [ "$c" -gt "$n" ]; then n=$c; fi
  c=$(grep -oE '^# pass +[0-9]+' "$log" | grep -oE '[0-9]+' \
      | awk '{if($1>m) m=$1} END{print m+0}' || true)
  if [ -n "$c" ] && [ "$c" -gt "$n" ]; then n=$c; fi
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n tests, expected >= ${GATE_MIN_TESTS:-1}"; }
  ok "offline gate: built and ran $n tests with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  ok "no stray files"
}
