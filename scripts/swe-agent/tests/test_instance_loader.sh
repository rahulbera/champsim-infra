#!/usr/bin/env bash
#
# Tests for lib/common.sh's load_instance().
#
# Its entire job is to refuse to continue when an instance descriptor is
# incomplete or inconsistent. Every one of these failures, if it were allowed
# through, produces a trace that is complete, well-formed, and of the wrong
# thing -- which is undetectable after the fact. So the loader is tested for
# what it REJECTS, not for what it accepts.
#
# Runs anywhere; touches nothing outside its own temp dir.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0

check() {  # check <name> <expect-rc: 0|nonzero> <script...>
  local name=$1 expect=$2; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if { [ "$expect" = "0" ] && [ $rc -eq 0 ]; } || { [ "$expect" != "0" ] && [ $rc -ne 0 ]; }; then
    PASS=$((PASS+1)); printf '  [ok]  %s\n' "$name"
  else
    FAIL=$((FAIL+1)); printf '  [ERR] %s (rc=%d)\n%s\n' "$name" "$rc" "$(echo "$out" | sed 's/^/        /')"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/instances" "$TMP/lang" "$TMP/lib"
cp "$HERE/../lib/common.sh" "$TMP/lib/"

# A complete, valid descriptor + language module.
good_env() {
  cat >"$TMP/instances/$1.env" <<EOF
INSTANCE=$1
REPO_URL=https://github.com/acme/widget
REPO_NAME=widget
REPO_DIR=/widget
BASE_COMMIT=${2:-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}
LANG_MODULE=${3:-fake}
MODEL=openai/glm-5.2
EOF
}
cat >"$TMP/lang/fake.sh" <<'EOF'
lang_toolchain()    { :; }
lang_deps()         { :; }
lang_offline_gate() { :; }
lang_clean_check()  { :; }
EOF

# Driver: sources common.sh and loads the named instance.
cat >"$TMP/drive.sh" <<'EOF'
set -euo pipefail
SWE_TOOLS_DIR="$1"
. "$SWE_TOOLS_DIR/lib/common.sh"
load_instance "$2"
echo "loaded $INSTANCE repo=$REPO_DIR commit=$BASE_COMMIT"
EOF

echo "== load_instance =="

good_env valid__inst-1
check "accepts a complete descriptor"           0 bash "$TMP/drive.sh" "$TMP" valid__inst-1

check "rejects a missing descriptor"            1 bash "$TMP/drive.sh" "$TMP" no__such-1
check "rejects an empty instance id"            1 bash "$TMP/drive.sh" "$TMP" ""

# Each required variable, removed one at a time. A descriptor missing REPO_DIR
# or BASE_COMMIT is the highest-consequence failure in the pipeline.
for var in INSTANCE REPO_URL REPO_NAME REPO_DIR BASE_COMMIT LANG_MODULE MODEL; do
  good_env missing__$var
  grep -v "^$var=" "$TMP/instances/missing__$var.env" > "$TMP/x" && mv "$TMP/x" "$TMP/instances/missing__$var.env"
  check "rejects descriptor with no $var"       1 bash "$TMP/drive.sh" "$TMP" "missing__$var"
done

# A file whose INSTANCE disagrees with its filename means someone copied a
# descriptor and edited it incompletely -- the run would use the OLD commit.
good_env mismatch__inst-1
sed -i 's/^INSTANCE=.*/INSTANCE=some__other-9/' "$TMP/instances/mismatch__inst-1.env"
check "rejects filename/INSTANCE mismatch"      1 bash "$TMP/drive.sh" "$TMP" mismatch__inst-1

good_env nolang__inst-1 "" nosuchlang
check "rejects a missing language module"       1 bash "$TMP/drive.sh" "$TMP" nolang__inst-1

# A language module missing a hook silently SKIPS that step. If the skipped hook
# is lang_offline_gate, provisioning "succeeds" and the traced pass dies hours
# later on a DNS lookup inside the capture window.
for hook in lang_toolchain lang_deps lang_offline_gate lang_clean_check; do
  cp "$TMP/lang/fake.sh" "$TMP/lang/part_$hook.sh"
  grep -v "^$hook()" "$TMP/lang/fake.sh" > "$TMP/lang/part_$hook.sh"
  good_env "hook__$hook" "" "part_$hook"
  check "rejects module missing $hook()"        1 bash "$TMP/drive.sh" "$TMP" "hook__$hook"
done

echo
echo "== run_offline =="
# The command must genuinely have no route off the box, and loopback must be UP
# (redis's harness binds 127.0.0.1; a fresh netns leaves lo DOWN).
if sudo -n true 2>/dev/null && command -v unshare >/dev/null; then
  cat >"$TMP/off.sh" <<'EOF'
set -euo pipefail
. "$1/lib/common.sh"
run_offline "$2"
EOF
  check "loopback is up inside the namespace"   0 bash "$TMP/off.sh" "$TMP" \
        "ip -o link show lo | grep -q ',UP' || ip -o addr show lo | grep -q '127.0.0.1'"
  check "external network is unreachable"       1 bash "$TMP/off.sh" "$TMP" \
        "getent hosts github.com"
  check "OFFLINE_ENV reaches the command"       0 bash -c \
        ". $TMP/lib/common.sh; OFFLINE_ENV=(FOO=bar); run_offline '[ \"\$FOO\" = bar ]'"
else
  echo "  [skip] needs passwordless sudo + unshare"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
