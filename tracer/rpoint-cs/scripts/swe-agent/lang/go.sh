#!/usr/bin/env bash
#
# lang/go.sh — Go toolchain module.
#
# Instance env must supply: GO_VERSION, GATE_BUILD_CMD, GATE_TEST_CMD.
# Sourced by provision_guest.sh; see lib/common.sh for the hook contract.

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
  say "toolchain: Go ${GO_VERSION}"
  # Ubuntu noble ships Go 1.22. A module declaring `toolchain go1.23.0` fails
  # outright under GOTOOLCHAIN=local with 1.22, and under the default
  # GOTOOLCHAIN=auto it tries to DOWNLOAD the newer toolchain -- which in the
  # no-network traced pass hangs on DNS rather than failing fast.
  if [ "$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')" != "go${GO_VERSION}" ]; then
    cd /tmp
    curl -fSL -O "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
    rm -f "go${GO_VERSION}.linux-amd64.tar.gz"
  fi
  export PATH=/usr/local/go/bin:$PATH
  [ "$(go version | awk '{print $3}')" = "go${GO_VERSION}" ] || die "go version mismatch: $(go version)"
  ok "$(go version)"

  # Written to Go's own env file so it applies to EVERY go invocation regardless
  # of which shell the agent spawns. GOTOOLCHAIN=local is the load-bearing one:
  # it is reset to `auto` by every Go reinstall (it lives in /usr/local/go/go.env).
  sudo mkdir -p /etc/go /opt/go /opt/gocache
  sudo tee /etc/go/env >/dev/null <<'EOF'
GOTOOLCHAIN=local
GOFLAGS=-mod=readonly -buildvcs=false
GOPATH=/opt/go
GOMODCACHE=/opt/go/pkg/mod
GOCACHE=/opt/gocache
GOSUMDB=off
EOF
  sudo chown -R ubuntu:ubuntu /opt/go /opt/gocache
  export GOENV=/etc/go/env
  sudo tee /etc/profile.d/00-go.sh >/dev/null <<'EOF'
export PATH=/usr/local/go/bin:$PATH
export GOENV=/etc/go/env
EOF
  # -mod=readonly stops the go command rewriting go.mod/go.sum, which would land
  # in `git diff` and corrupt SWE-bench patch extraction.
  # -buildvcs=false stops `go build` shelling out to git, which fails with
  # "error obtaining VCS status: exit status 128" on a dubious-ownership repo --
  # a message that reads like a network fault but is not.
  # GOTOOLCHAIN only EXISTS from Go 1.21. Writing it to /etc/go/env above is
  # harmless on older toolchains (the key is ignored), but ASSERTING it is not:
  # `go env GOTOOLCHAIN` on Go 1.19 prints an empty line for the unknown key, so
  # this check failed prometheus-10720's provisioning with "GOTOOLCHAIN is not
  # local" on a guest that was configured exactly right. There is simply nothing
  # to pin before 1.21 -- the auto-download behaviour it guards against does not
  # exist yet.
  _gotc=$(go env GOTOOLCHAIN 2>/dev/null || true)
  _gominor=$(go env GOVERSION 2>/dev/null | sed -n 's/^go1\.\([0-9]*\).*/\1/p')
  if [ -n "$_gotc" ] || { [ -n "$_gominor" ] && [ "$_gominor" -ge 21 ]; }; then
    [ "$_gotc" = "local" ] || die "GOTOOLCHAIN is '$_gotc', expected local"
    ok "GOTOOLCHAIN pinned to local"
  else
    ok "Go ${GO_VERSION} predates GOTOOLCHAIN (added in 1.21) -- nothing to pin"
  fi
  [ "$(go env CC)" = "gcc" ] || die "go env CC is $(go env CC), expected gcc"
  ok "go env pinned"
}

lang_deps() {
  say "populate the module cache for offline use"
  # The two research reports disagreed here: plain `go mod download` may
  # under-populate for a go>=1.17 module, while `go mod download all` dirties
  # go.sum by ~144 lines and breaks patch extraction. Resolution: take the
  # superset, then restore the tree. Correctness is decided by the offline gate,
  # not by either argument.
  cd "$REPO_DIR"
  go mod download
  go mod download all || true
  git checkout -- go.mod go.sum
  [ -z "$(git status --porcelain)" ] || die "go.sum/go.mod still dirty after restore"
  ok "module cache populated, tree restored clean"
  du -sh /opt/go/pkg/mod 2>/dev/null | sed 's/^/  modcache: /'
}

lang_offline_gate() {
  OFFLINE_ENV=(GOENV=/etc/go/env GOPROXY=off GOFLAGS='-mod=readonly -buildvcs=false')
  export PATH=/usr/local/go/bin:$PATH
  local log=/tmp/offline_gate.log
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD && $GATE_TEST_CMD" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # COUNT THE TESTS, like every other language module does. This one used to
  # trust the exit code alone, and `go test` on a package selector that matches
  # nothing exits 0 having run nothing -- the same "structurally perfect,
  # completely empty" gate the other modules were built to reject. A mistyped
  # ./path/... is silent otherwise.
  #
  # Two shapes are accepted: `go test -v` prints "--- PASS: TestX" per test, and
  # plain `go test` prints one "ok <pkg>" per package. Prefer the former count
  # when present because it is per-test rather than per-package.
  local n
  n=$(grep -cE '^--- PASS' "$log" || true)
  local unit="tests"
  if [ "$n" -eq 0 ]; then
    n=$(grep -cE '^ok[[:space:]]' "$log" || true); unit="packages"
  fi
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n $unit, expected >= ${GATE_MIN_TESTS:-1} -- exited 0 but did nothing"; }
  ok "offline gate: ran $n $unit with NO network"
}

lang_clean_check() {
  # `go test -c ./pkg` drops a multi-MB test binary that `git add -A` would
  # swallow into the patch; the gate command uses -o /dev/null to avoid it.
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -3)"
  # The hazard is -mod=vendor being selected silently, and Go selects it on
  # vendor/modules.txt, NOT on the mere existence of a vendor/ directory.
  # Testing the directory rejected gin-2121, whose commit tracks a lone
  # vendor/vendor.json -- a govendor manifest from the pre-modules era that Go
  # ignores entirely. That file is COMMITTED source at that revision (the
  # tree-dirty check above passes), so deleting it to satisfy the gate would
  # have modified the repo under test.
  #
  # An UNTRACKED vendor tree is still a real problem: it means the gate build
  # vendored dependencies as a side effect. The dirty-tree check above already
  # catches that, since anything untracked shows up there.
  [ ! -f "$REPO_DIR/vendor/modules.txt" ] \
    || die "vendor/modules.txt present -- builds would silently use -mod=vendor"
  ok "no stray build artifacts"
}
