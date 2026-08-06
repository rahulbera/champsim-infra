#!/usr/bin/env bash
#
# lang/go.sh — Go toolchain module.
#
# Instance env must supply: GO_VERSION, GATE_BUILD_CMD, GATE_TEST_CMD.
# Sourced by provision_guest.sh; see lib/common.sh for the hook contract.

lang_toolchain() {
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
  [ "$(go env GOTOOLCHAIN)" = "local" ] || die "GOTOOLCHAIN is not local"
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
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD && $GATE_TEST_CMD"
}

lang_clean_check() {
  # `go test -c ./pkg` drops a multi-MB test binary that `git add -A` would
  # swallow into the patch; the gate command uses -o /dev/null to avoid it.
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -3)"
  [ ! -d "$REPO_DIR/vendor" ] \
    || die "vendor/ present -- would silently switch builds to -mod=vendor"
  ok "no stray build artifacts"
}
