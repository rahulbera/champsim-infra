#!/usr/bin/env python3
"""draft_descriptor.py <instance_id> — draft an instance descriptor from evidence.

WHY. Hand-writing descriptors cost five provisioning runs in one night, every
one of them a guess that the evidence would have answered:

  gate path guessed from another repo's layout   fastlane   "No examples found"
  gate INVOCATION guessed, path right            micropython "no such file"
  gate required tests that fail at base commit   micropython 6 failures, all expected
  GATE_TEST_PATTERN left at another repo's       micropython counted 0 of 13 passing
  APT_PACKAGES missing a native-ext dependency   jekyll     psych/libyaml, nushell/openssl

Each is mechanical to get right and expensive to get wrong, so this reads the
evidence instead of guessing:

  which test matters  <- the instance's FAIL_TO_PASS
  how it is invoked   <- the instance's OWN trajectory, verbatim
  which set must pass <- PASS_TO_PASS (never the F2P: it fails at base by
                         construction, and a gate demanding it green rejects the
                         instance for having the bug it was selected for)
  how to count it     <- GATE_TEST_PATTERN, per language module
  what to install     <- per-language baseline including native-extension headers

It DRAFTS. It does not launch anything, and the output is meant to be read
before use -- the test-invocation candidates in particular are suggestions
ranked by how often the trajectory used them.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TRAJ_DIR = "/home/rbera/work/bpeval/InferSuite/local_agents/ML_typeid/replay_trajs"
SELECTION = "/home/rbera/work/bpeval/InferSuite/local_agents/ML_typeid/selection_36_count.tsv"

# Per-language defaults. APT_PACKAGES includes the headers native extensions
# need -- the single most common provisioning failure, because the error names
# the gem or crate rather than the missing -dev package.
LANG = {
    "C":          dict(mod="c_make",       apt="build-essential pkg-config",
                       cmds="gcc make", pat=r"^\[ok\]"),
    "C++":        dict(mod="c_make",       apt="build-essential pkg-config cmake",
                       cmds="gcc make cmake", pat=r"^\[ok\]"),
    "Rust":       dict(mod="rust_cargo",   apt="build-essential pkg-config libssl-dev",
                       cmds="cargo rustc", pat=r"^test .* ok$"),
    "Go":         dict(mod="go",           apt="build-essential",
                       cmds="go", pat=r"^(ok|PASS)"),
    "Java":       dict(mod="java_maven",   apt="build-essential",
                       cmds="java mvn", pat=r"Tests run:"),
    "PHP":        dict(mod="php_composer", apt="build-essential php-cli php-xml php-mbstring",
                       cmds="php composer", pat=r"^OK|Tests:"),
    # libyaml-dev for psych, zlib1g-dev for nokogiri/zlib: both bite as an
    # opaque native-extension build failure naming only the gem.
    "Ruby":       dict(mod="ruby_bundler", apt="ruby-full ruby-bundler build-essential libyaml-dev zlib1g-dev",
                       cmds="ruby bundle", pat=r"assertions|examples"),
    # node_npm.sh REQUIRES NODE_VERSION and installs from NodeSource rather than
    # the distro. Omitting it aborts provisioning with "NODE_VERSION: unbound
    # variable" AFTER the whole apt stage has run (vuejs__core-11870, 2026-09-02).
    # apt must NOT list nodejs/npm -- NodeSource supplies them.
    "JavaScript": dict(mod="node_npm",     apt="build-essential",
                       cmds="node npm", pat=r"^(ok|PASS|✓)", node="20"),
    "TypeScript": dict(mod="node_npm",     apt="build-essential",
                       cmds="node npm", pat=r"^(ok|PASS|✓)", node="20"),
}

TEST_RE = re.compile(
    r"(cargo test|go test|npx jest|npm test|yarn test|bundle exec|"
    r"ruby -I|rspec|pytest|phpunit|mvn .*test|make .*test|run-tests|\./runtest)",
    re.I)


def language_of(instance):
    try:
        with open(SELECTION) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) > 4 and p[1] == instance:
                    return p[3]
    except OSError:
        pass
    return None


def test_invocations(instance):
    """Every bash command in the trajectory that looks like it runs tests,
    most-frequent first. The invocation is the part that keeps being wrong, so
    it is quoted verbatim rather than reconstructed."""
    path = os.path.join(TRAJ_DIR, instance + ".min.traj")
    if not os.path.exists(path):
        return []
    traj = json.load(open(path))
    counts = {}
    for m in traj.get("history", []):
        if m.get("role") != "assistant":
            continue
        for tc in (m.get("tool_calls") or []):
            fn = tc.get("function", {})
            if fn.get("name") != "bash":
                continue
            try:
                cmd = json.loads(fn.get("arguments") or "{}").get("command", "")
            except ValueError:
                continue
            if TEST_RE.search(cmd) and len(cmd) < 300:
                counts[cmd] = counts.get(cmd, 0) + 1
    return sorted(counts.items(), key=lambda kv: -kv[1])


def next_slot(inst_dir):
    used = set()
    for name in os.listdir(inst_dir):
        if not name.endswith(".env"):
            continue
        for line in open(os.path.join(inst_dir, name)):
            if line.startswith("CAPTURE_SLOT="):
                try:
                    used.add(int(line.split("=", 1)[1].strip()))
                except ValueError:
                    pass
    n = 0
    while n in used:
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("instance")
    ap.add_argument("--write", action="store_true",
                    help="write instances/<id>.env (refuses to overwrite)")
    args = ap.parse_args()
    inst = args.instance

    ref_path = os.path.join(HERE, "reference", inst + ".json")
    if not os.path.exists(ref_path):
        sys.exit(f"no reference at {ref_path} -- run stage_instance.py {inst} --write-env first")
    ref = json.load(open(ref_path))

    lang = language_of(inst)
    if lang not in LANG:
        sys.exit(f"unknown language {lang!r} for {inst}; add it to LANG in this file")
    cfg = LANG[lang]

    inst_dir = os.path.join(HERE, "instances")
    slot = next_slot(inst_dir)
    repo = ref.get("repo") or "?"
    p2p, f2p = ref.get("PASS_TO_PASS") or [], ref.get("FAIL_TO_PASS") or []
    invs = test_invocations(inst)

    out = []
    out.append(f"# {inst} — {lang}, module {cfg['mod']}")
    out.append("# Drafted by draft_descriptor.py from the instance's own evidence.")
    out.append("# REVIEW GATE_TEST_CMD before use: the candidates below are ranked by")
    out.append("# how often the trajectory used them, not by whether they suit a gate.")
    out.append(f"INSTANCE={inst}")
    out.append(f"REPO_URL=https://github.com/{repo}")
    out.append(f"REPO_NAME={repo.split('/')[-1]}")
    out.append("REPO_DIR=/testbed")
    out.append(f"BASE_COMMIT={ref.get('base_commit')}")
    out.append(f"LANG_MODULE={cfg['mod']}")
    out.append(f'APT_PACKAGES="{cfg["apt"]}"')
    out.append(f'REQUIRED_COMMANDS="{cfg["cmds"]}"')
    if cfg.get("node"):
        out.append("# REQUIRED by node_npm.sh; check the repo's engines field before changing.")
        out.append(f'NODE_VERSION={cfg["node"]}')
    out.append("MODEL=openai/glm-5.2")
    out.append("UPSTREAM=https://api.z.ai")
    out.append("")
    out.append(f"# FAIL_TO_PASS ({len(f2p)}) — FAILS at the base commit. Never gate on it.")
    for x in f2p[:3]:
        out.append(f"#   {x[:100]}")
    out.append(f"# PASS_TO_PASS ({len(p2p)}) — guaranteed to pass at the base commit.")
    for x in p2p[:3]:
        out.append(f"#   {x[:100]}")
    out.append("#")
    out.append("# Test invocations this trajectory actually used (count, command):")
    if invs:
        for cmd, n in invs[:5]:
            out.append(f"#   [{n}x] {cmd[:150]}")
    else:
        out.append("#   NONE FOUND -- read the trajectory by hand before writing a gate.")
    out.append("GATE_BUILD_CMD='# TODO from the trajectory'")
    out.append(f"GATE_TEST_CMD='# TODO — adapt one of the invocations above'")
    out.append(f"GATE_TEST_PATTERN='{cfg['pat']}'")
    out.append("GATE_MIN_TESTS=5")
    out.append(f"CAPTURE_SLOT={slot}")
    text = "\n".join(out) + "\n"

    if args.write:
        dst = os.path.join(inst_dir, inst + ".env")
        if os.path.exists(dst):
            sys.exit(f"{dst} exists -- refusing to overwrite")
        open(dst, "w").write(text)
        print(f"  wrote {dst} (slot {slot}) -- GATE_* still need filling in")
    else:
        print(text)


if __name__ == "__main__":
    main()
