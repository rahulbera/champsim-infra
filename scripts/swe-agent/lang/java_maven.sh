#!/usr/bin/env bash
#
# lang/java_maven.sh — Java projects built with Maven (gson, ...).
#
# Instance env must supply: JDK_PACKAGE, GATE_BUILD_CMD, GATE_TEST_CMD,
# GATE_MIN_TESTS.
#
# The JVM arm. HotSpot JITs hot methods and resolves invokevirtual /
# invokeinterface through inline caches that fall back to vtable dispatch --
# a different mechanism again from V8's inline caches, MRI's computed goto, or
# Go's itab. If the indirect share tracks execution model rather than language
# family, the JVM and V8 should land closer to each other than either does to C.

lang_toolchain() {
  say "toolchain: JDK + Maven"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PACKAGES
  command -v java >/dev/null || die "java not installed"
  command -v mvn  >/dev/null || die "maven not installed"
  ok "$(java -version 2>&1 | head -1), $(mvn -v | head -1)"

  # The local repository is set SYSTEM-WIDE, not in ~/.m2.
  #
  # Maven defaults to ${user.home}/.m2/repository, and provisioning runs as
  # ubuntu while the agent runs as ROOT -- so root would look in /root/.m2,
  # find nothing, and try to download the world with the network down. Exactly
  # the failure the bundler module hit. A settings.xml under /etc/maven applies
  # to every user, which ~/.m2 cannot.
  sudo mkdir -p /opt/m2 /etc/maven
  sudo chown -R ubuntu:ubuntu /opt/m2
  sudo tee /etc/maven/settings.xml >/dev/null <<'EOF'
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <localRepository>/opt/m2</localRepository>
  <offline>false</offline>
</settings>
EOF
  ok "maven local repository pinned to /opt/m2 for all users"
}

lang_deps() {
  say "maven dependencies"
  cd "$REPO_DIR"
  # go-offline resolves plugins as well as dependencies; without the plugin
  # half, `mvn -o test` still reaches out for surefire at test time.
  # go-offline walks the WHOLE reactor by default, so one unrelated sibling
  # module with unresolvable dependencies fails the step even though the module
  # under test is fine (gson-extras does exactly this). MVN_SCOPE narrows it to
  # the same projects the build and test commands use.
  # shellcheck disable=SC2086
  mvn -B -q ${MVN_SCOPE:-} dependency:go-offline >/tmp/provision_mvn.log 2>&1 \
    || { tail -40 /tmp/provision_mvn.log; die "mvn dependency:go-offline failed"; }
  # A first online build warms anything go-offline missed (annotation
  # processors, test-scoped plugins) so the gate tests the cache, not the net.
  eval "$GATE_BUILD_CMD" >>/tmp/provision_mvn.log 2>&1 \
    || { tail -40 /tmp/provision_mvn.log; die "initial maven build failed"; }
  ok "dependencies resolved into /opt/m2"

  local dirty
  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || die "maven dirtied the tree:
$(echo "$dirty" | head -10)"
  ok "tree clean"
  du -sh /opt/m2 2>/dev/null | sed 's/^/  m2: /'
}

lang_offline_gate() {
  OFFLINE_ENV=(MAVEN_OPTS=-Dmaven.repo.local=/opt/m2 HOME=/home/ubuntu)
  local log=/tmp/offline_gate.log
  # -o is maven's own offline flag; the namespace makes it true rather than
  # merely requested.
  run_offline "cd $REPO_DIR && $GATE_BUILD_CMD -o && $GATE_TEST_CMD -o" >"$log" 2>&1 \
    || { tail -40 "$log"; die "OFFLINE GATE FAILED -- the traced pass would die"; }

  # Surefire prints "Tests run: N, Failures: ...". Zero tests run is a passing
  # build, and is what a bad -Dtest= filter produces.
  local n
  n=$(grep -oE 'Tests run: [0-9]+' "$log" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
  [ "$n" -ge "${GATE_MIN_TESTS:-1}" ] \
    || { tail -30 "$log"; die "offline gate ran only $n tests, expected >= ${GATE_MIN_TESTS:-1}"; }
  ok "offline gate: built and ran $n tests with NO network"
}

lang_clean_check() {
  [ -z "$(cd "$REPO_DIR" && git status --porcelain)" ] \
    || die "tree dirty after gate: $(cd "$REPO_DIR" && git status --porcelain | head -5)"
  # Prove the repository resolves for ROOT, the user that will actually need it.
  sudo -i bash -c "cd $REPO_DIR && mvn -o -B -q validate" >/dev/null 2>&1 \
    || die "mvn -o fails as root -- the agent would not find the dependencies"
  ok "dependencies resolve as root; no stray files"
}
