#!/usr/bin/env bash
#
# lang/c_make.sh — C projects that build with a plain in-tree `make` and vendor
# their dependencies (redis, valkey, ...).
#
# This is the easiest language to take offline and that is exactly why it is the
# useful control: there is no package manager in the loop at all, so "the build
# worked because the network was up" cannot happen. The offline gate still runs,
# because the TEST harness may pull things the build does not.
#
# Instance env must supply: APT_PACKAGES, GATE_BUILD_CMD, GATE_TEST_CMD.

lang_toolchain() {
  say "toolchain: system C toolchain + test harness"
  # No version pin: the distro gcc is the point of comparison against SPEC's
  # gcc/llvm benchmarks, and pinning an older gcc would make the generated code
  # less representative, not more.
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PACKAGES
  command -v gcc  >/dev/null || die "gcc not installed"
  command -v make >/dev/null || die "make not installed"
  ok "gcc $(gcc -dumpversion), $(make --version | head -1)"
  for c in ${REQUIRED_COMMANDS:-}; do
    command -v "$c" >/dev/null || die "required command missing after apt: $c"
    ok "have $c"
  done
}

lang_deps() {
  say "dependencies"
  # Nothing to fetch: this module is selected precisely for projects that vendor
  # everything in-tree. Build once WITH network so the offline gate below is a
  # test of the gate and not of a cold build.
  cd "$REPO_DIR"
  eval "$GATE_BUILD_CMD" >/tmp/provision_build.log 2>&1 \
    || { tail -40 /tmp/provision_build.log; die "initial build failed"; }
  ok "built with network (log: /tmp/provision_build.log)"

  # A build that dirties tracked files would be silently absorbed into the
  # agent's `git diff` answer. Object files and binaries must all be ignored.
  local dirty
  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || die "build dirties the tree, patch extraction would break:
$(echo "$dirty" | head -10)"
  ok "build leaves the tree clean (all artifacts gitignored)"
}

lang_offline_gate() {
  OFFLINE_ENV=()
  local log=/tmp/offline_gate.log
  # A from-scratch rebuild, not an incremental one: an incremental `make` after
  # lang_deps would be a no-op and the gate would pass without compiling a
  # single file -- structurally perfect and completely empty.
  run_offline "cd $REPO_DIR && ${GATE_CLEAN_CMD:-make distclean} >/dev/null 2>&1; \
               $GATE_BUILD_CMD && $GATE_TEST_CMD" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # "The command exited 0" is not evidence that anything ran. A test selector
  # that matches nothing exits 0 having executed zero tests, which is how a
  # capture ends up being a pristine recording of no work at all. Count the
  # harness's own per-test success lines and require a real number.
  local n
  n=$(grep -c '^\[ok\]' "$log" || true)
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n tests, expected >= ${GATE_MIN_TESTS:-1} -- exited 0 but did nothing"; }
  ok "offline gate: rebuilt from clean and ran $n tests with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  ok "no stray build artifacts"
}
