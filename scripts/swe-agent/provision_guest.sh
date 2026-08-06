#!/usr/bin/env bash
#
# provision_guest.sh — Pass 1 provisioning, run INSIDE the guest over ssh.
#
# Installs the Go toolchain, the Prometheus checkout at the benchmark's
# base_commit, a fully populated offline module cache, and SWE-agent.
#
# Idempotent: safe to re-run. Every step that could silently produce a wrong
# result ends in an assertion, because the failure modes here do not announce
# themselves -- they show up hours later as a corrupt trace.
#
set -euo pipefail

# ---- benchmark facts (VERIFIED against the HF dataset, not assumed) ---------
INSTANCE=prometheus__prometheus-15142
REPO_URL=https://github.com/prometheus/prometheus
REPO_DIR=/prometheus                 # SWE-agent places repos at /{repo_name}
BASE_COMMIT=16bba78f1549cfd7909b61ebd7c55c822c86630b
GO_VERSION=1.23.8                    # pinned by swebench/harness/constants/go.py

say() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf '  [ok] %s\n' "$*"; }
die() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
say "1. Go toolchain ${GO_VERSION}"
# Ubuntu noble ships Go 1.22. prometheus's go.mod declares `toolchain go1.23.0`,
# so a 1.22 toolchain with GOTOOLCHAIN=local fails outright, and with the
# default GOTOOLCHAIN=auto it tries to DOWNLOAD go1.23 -- which in the
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

# ---------------------------------------------------------------------------
say "2. Go environment"
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
go env GOMODCACHE GOCACHE GOTOOLCHAIN GOFLAGS | sed 's/^/  /'
[ "$(go env GOTOOLCHAIN)" = "local" ] || die "GOTOOLCHAIN is not local"
[ "$(go env CC)" = "gcc" ] || die "go env CC is $(go env CC), expected gcc"
ok "go env pinned"

# ---------------------------------------------------------------------------
say "3. Prometheus checkout at ${BASE_COMMIT:0:12}"
# A FULL clone on purpose. Blobless/shallow clones save ~250 MB but break
# `git log -p`, `git show <old-sha>` and `git blame` offline, and SWE-agent
# routinely runs git history commands while exploring.
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
say "4. Populate the module cache for offline use"
# The two research reports disagreed here: plain `go mod download` may
# under-populate for a go>=1.17 module, while `go mod download all` dirties
# go.sum by ~144 lines and breaks patch extraction. Resolution: take the
# superset, then restore the tree. Correctness is decided by the offline gate
# in step 5, not by either argument.
go mod download
go mod download all || true
git checkout -- go.mod go.sum
[ -z "$(git status --porcelain)" ] || die "go.sum/go.mod still dirty after restore"
ok "module cache populated, tree restored clean"
du -sh /opt/go/pkg/mod 2>/dev/null | sed 's/^/  modcache: /'

# ---------------------------------------------------------------------------
say "5. OFFLINE GATE (the real test of step 4)"
# `go mod download` having succeeded proves nothing: the build pass HAS network,
# so a missing module is fetched on demand and never noticed. This is the only
# check that fails here rather than mid-trace with
# "module lookup disabled by GOPROXY=off".
if sudo unshare -n env PATH=/usr/local/go/bin:$PATH GOENV=/etc/go/env HOME=/home/ubuntu \
     GOFLAGS='-mod=readonly -buildvcs=false' GOPROXY=off \
     bash -c "cd $REPO_DIR && go build ./... && go test -c -o /dev/null ./tsdb"; then
  ok "builds and compiles tests with NO network"
else
  die "OFFLINE GATE FAILED — module cache is incomplete; the traced pass would die"
fi
# `go test -c ./tsdb` (SWE-bench's literal install cmd) drops a 32 MB tsdb.test
# binary that `git add -A` would swallow into the patch. -o /dev/null avoids it.
[ ! -e "$REPO_DIR/tsdb.test" ] || die "stray tsdb.test binary present"
[ ! -d "$REPO_DIR/vendor" ] || die "vendor/ present — would silently switch builds to -mod=vendor"
ok "no stray build artifacts"

# ---------------------------------------------------------------------------
say "6. SWE-agent"
if [ ! -d /opt/swe-agent ]; then
  sudo git clone https://github.com/SWE-agent/SWE-agent.git /opt/swe-agent
  sudo chown -R ubuntu:ubuntu /opt/swe-agent
fi
python3 -m venv /opt/venv 2>/dev/null || true
/opt/venv/bin/pip install --quiet --upgrade pip
/opt/venv/bin/pip install --quiet -e /opt/swe-agent
/opt/venv/bin/sweagent --help >/dev/null 2>&1 || die "sweagent CLI not working"
ok "sweagent installed: $(/opt/venv/bin/python -c 'import sweagent; print(sweagent.__version__)' 2>/dev/null || echo unknown)"

say "PROVISIONING COMPLETE"
echo "  repo:      $REPO_DIR @ $(git -C $REPO_DIR rev-parse --short=12 HEAD)"
echo "  go:        $(go version | awk '{print $3}')"
echo "  modcache:  $(du -sh /opt/go/pkg/mod 2>/dev/null | cut -f1)"
echo "  disk:      $(df -h / | awk 'NR==2{print $4" free"}')"
