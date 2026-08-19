#!/usr/bin/env bash
#
# common.sh — shared helpers + instance loading for the SWE-agent capture passes.
#
# Sourced by provision_guest.sh, record_trajectory.sh and replay_pinned.sh, all
# of which run INSIDE the guest. Not executable on its own.
#
# The three passes must agree exactly on repo path, base commit and model, or
# the traced execution is not the recorded one. Putting those facts in ONE
# sourced file per instance is what makes that agreement structural rather than
# a thing to remember.

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

SWE_TOOLS_DIR=${SWE_TOOLS_DIR:-/opt/swe-agent-tools}

# load_instance <instance_id>
#
# Sources instances/<id>.env and the language module it names, then asserts
# every variable the later passes depend on is actually set. An unset variable
# here becomes a wrong-repo or wrong-commit trace that looks perfectly valid.
load_instance() {
  local id="${1:-}"
  [ -n "$id" ] || die "usage: $0 <instance_id> [...]"

  local env_file="$SWE_TOOLS_DIR/instances/$id.env"
  [ -f "$env_file" ] || die "no instance descriptor: $env_file"
  # shellcheck disable=SC1090
  . "$env_file"

  local v
  for v in INSTANCE REPO_URL REPO_NAME REPO_DIR BASE_COMMIT LANG_MODULE MODEL; do
    [ -n "${!v:-}" ] || die "$env_file does not set $v"
  done
  [ "$INSTANCE" = "$id" ] || die "$env_file declares INSTANCE=$INSTANCE, expected $id"

  local lang_file="$SWE_TOOLS_DIR/lang/$LANG_MODULE.sh"
  [ -f "$lang_file" ] || die "no language module: $lang_file"
  # shellcheck disable=SC1090
  . "$lang_file"

  # Every language module must supply all four hooks. A missing one would
  # silently skip a step -- most dangerously the offline gate, whose absence
  # only shows up as a dead trace hours later.
  local f
  for f in lang_toolchain lang_deps lang_offline_gate lang_clean_check; do
    declare -F "$f" >/dev/null || die "$lang_file does not define $f()"
  done

  CASS=${CASS:-/opt/cassettes/$INSTANCE}
  PROBLEM_STATEMENT=${PROBLEM_STATEMENT:-/opt/problem_statements/$INSTANCE.md}
}

# assert_repo_pristine — the tree must be at base_commit with nothing modified.
#
# SWE-bench extracts the agent's answer with `git diff`, so any pre-existing
# modification is silently absorbed into the patch. Checked before recording AND
# before replay, because a stray build artifact from the previous pass is the
# normal way this breaks.
assert_repo_pristine() {
  git config --global --add safe.directory "$REPO_DIR"
  cd "$REPO_DIR" || die "no repo at $REPO_DIR"
  [ "$(git rev-parse HEAD)" = "$BASE_COMMIT" ] \
    || die "HEAD is $(git rev-parse HEAD), expected $BASE_COMMIT"
  [ -z "$(git status --porcelain)" ] \
    || die "tree dirty: $(git status --porcelain | head -3 | tr '\n' ' ')"
  ok "repo clean at $(git rev-parse --short=12 HEAD)"
}

# run_offline <cmd> — run a shell command with no network at all.
#
# `unshare -n` gives the child an empty network namespace, so a dependency that
# was silently fetched during provisioning fails HERE rather than mid-trace.
# This is the only check that distinguishes "the cache is complete" from "the
# cache looked complete because the network was up".
#
# Callers add language-specific variables by setting the OFFLINE_ENV array,
# e.g. OFFLINE_ENV=(GOPROXY=off GOFLAGS=-mod=readonly). `env -i` clears
# everything else so a variable that happens to be exported in the provisioning
# shell cannot quietly make the gate pass.
#
# Loopback is brought UP inside the namespace. A fresh netns has `lo` present
# but DOWN, so anything that binds 127.0.0.1 -- redis's test harness starts real
# servers and connects to them -- fails with "Cannot assign requested address".
# That failure looks exactly like a missing dependency, and the tempting "fix"
# is to weaken the gate. Loopback-only still reaches nothing outside the guest,
# so the gate keeps its meaning.
declare -a OFFLINE_ENV=()
run_offline() {
  # The env assignments are passed as separate argv entries rather than spliced
  # into a command string. Building that string with printf %q emits '' for an
  # empty array, which env then treats as the command name and fails with
  # "env: '': No such file or directory" -- and a gate that cannot run at all
  # looks exactly like a gate that ran and found no network.
  sudo unshare -n -- env -i \
    PATH="$PATH" HOME="${OFFLINE_HOME:-/home/ubuntu}" \
    ${OFFLINE_ENV[@]+"${OFFLINE_ENV[@]}"} \
    bash -c "ip link set lo up 2>/dev/null || true; $*"
}
