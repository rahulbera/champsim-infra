#!/usr/bin/env bash
#
# lang/rust_cargo.sh — Rust projects built with cargo (ripgrep, bat, ...).
#
# Instance env must supply: RUST_VERSION, GATE_BUILD_CMD, GATE_TEST_CMD,
# GATE_MIN_TESTS.
#
# Rust is the second compiled arm. Go leans on interface dispatch, which is the
# leading explanation for the indirect-dominated profile of the first capture;
# Rust monomorphises generics and resolves most calls statically. If a Rust
# agent trace is ALSO indirect-dominated, "Go's interface dispatch" is not the
# explanation.

lang_toolchain() {
  say "toolchain: Rust ${RUST_VERSION}"
  # rustup rather than the distro rustc: the distro version moves with the
  # release, and the whole point of pinning is that two captures months apart
  # compile the same way.
  export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
  sudo mkdir -p /opt/rustup /opt/cargo
  sudo chown -R ubuntu:ubuntu /opt/rustup /opt/cargo
  if [ ! -x /opt/cargo/bin/cargo ]; then
    curl -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --default-toolchain "$RUST_VERSION" --profile minimal
  fi
  export PATH=/opt/cargo/bin:$PATH
  sudo tee /etc/profile.d/00-rust.sh >/dev/null <<'EOF'
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
export PATH=/opt/cargo/bin:$PATH
EOF
  [ "$(rustc --version | awk '{print $2}')" = "$RUST_VERSION" ] \
    || die "rustc is $(rustc --version), expected $RUST_VERSION"
  ok "$(rustc --version), $(cargo --version)"
}

lang_deps() {
  say "crates"
  export CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
  cd "$REPO_DIR"
  # `cargo fetch` populates $CARGO_HOME/registry, which lives OUTSIDE the repo.
  # `cargo vendor` would be the obvious alternative and is wrong here: it writes
  # vendor/ INSIDE the repo and needs a .cargo/config.toml alongside it, both of
  # which land in `git status` and are absorbed into the agent's patch.
  cargo fetch >/tmp/provision_cargo.log 2>&1 \
    || { tail -40 /tmp/provision_cargo.log; die "cargo fetch failed"; }
  # Build once with network so the offline gate tests the gate, not a cold build.
  eval "$GATE_BUILD_CMD" >>/tmp/provision_cargo.log 2>&1 \
    || { tail -40 /tmp/provision_cargo.log; die "initial cargo build failed"; }
  ok "crates fetched into /opt/cargo"

  # cargo rewrites Cargo.lock whenever it resolves anything differently from
  # what is checked in, and target/ must already be gitignored.
  local dirty
  dirty=$(git status --porcelain)
  if [ -n "$dirty" ]; then
    echo "  restoring files touched by cargo:"; echo "$dirty" | sed 's/^/    /'
    git checkout -- . || die "could not restore the tree after cargo"
  fi
  [ -z "$(git status --porcelain)" ] || die "tree still dirty after restore"
  ok "tree clean"
  du -sh /opt/cargo 2>/dev/null | sed 's/^/  crates: /'
}

lang_offline_gate() {
  OFFLINE_ENV=(CARGO_HOME=/opt/cargo RUSTUP_HOME=/opt/rustup CARGO_NET_OFFLINE=true)
  export PATH=/opt/cargo/bin:$PATH
  local log=/tmp/offline_gate.log
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD --offline && $GATE_TEST_CMD --offline" \
    >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # libtest prints "test result: ok. N passed; ...". A filter matching no tests
  # still prints "0 passed" and still exits 0.
  local n
  n=$(grep -oE '[0-9]+ passed' "$log" | grep -oE '^[0-9]+' \
      | awk '{s+=$1} END{print s+0}')
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n tests, expected >= ${GATE_MIN_TESTS:-1}"; }
  ok "offline gate: built and ran $n tests with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  [ ! -d "$REPO_DIR/vendor" ] \
    || die "vendor/ present in the repo -- use the shared CARGO_HOME registry instead"
  ok "no stray files"
}
