#!/usr/bin/env bash
#
# rebuild_bin.sh — rebuild the seven CBP6 binaries into cbp6-runs/bin.
#
# Follows README §4 exactly. The `make clean` between builds is NOT optional:
# CHAMPSIM_TRACE_MEMORY_VALUES changes ooo_model_instr's size in every
# translation unit, so mixing objects across the two settings is an ODR
# violation that produces WRONG STATISTICS rather than a link error.
#
# Ends with §8's check that cbp_runlts and cbp_runlts_rv actually differ. If the
# payload flag is dropped, the two are byte-identical and the roll-up
# reproduces the campaign's "load values do not help" finding for entirely the
# wrong reason.
#
set -euo pipefail

CS=${CS:-/home/rbera/work/bpeval/ChampSim}
R=${R:-/home/rbera/work/bpeval/cbp6-runs}
B=$R/bin
J=${J:-12}          # leave cores for the captures running alongside

# The active conda base env points CXX and ~30 other toolchain variables at an
# AARCH64 cross-compiler and injects x86 -march flags, so ChampSim's build dies
# with "unknown value 'nocona' for '-march'". Unsetting the usual four is not
# enough in general; a scrubbed environment is. Note this also drops conda's
# python3 from PATH, which is what we want -- config.sh needs only the stdlib.
CLEAN="env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=$HOME TERM=dumb"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

cd "$CS"
[ "$(git rev-parse --abbrev-ref HEAD)" = rbdev ] || die "ChampSim is not on rbdev"
head=$(git rev-parse --short HEAD)
say "ChampSim rbdev @ $head (README §9 expects 30078792 or later), -j$J"

mkdir -p "$B"

say "build 1/3 — four predictors, memory-value payload OFF"
$CLEAN make clean >/dev/null
$CLEAN ./config.sh "$R/sweep_a.json" >/dev/null
$CLEAN make -j"$J" > /tmp/claude-1000/cbp6_build_a.log 2>&1 || { tail -25 /tmp/claude-1000/cbp6_build_a.log; die "build A failed"; }
cp bin/cbp_tagescl64 bin/cbp_tagescl192 bin/cbp_runlts bin/cbp_ddtage "$B/"
echo "  -> tagescl64 tagescl192 runlts ddtage"

say "build 2/3 — RUNLTS with the register-value channel live (SEPARATE build)"
$CLEAN make clean >/dev/null
$CLEAN ./config.sh "$R/sweep_b.json" >/dev/null
$CLEAN CPPFLAGS=-DCHAMPSIM_TRACE_MEMORY_VALUES=1 make -j"$J" > /tmp/claude-1000/cbp6_build_b.log 2>&1 \
  || { tail -25 /tmp/claude-1000/cbp6_build_b.log; die "build B failed"; }
cp bin/cbp_runlts_rv "$B/"
echo "  -> runlts_rv"

say "build 3/3 — headroom oracles"
$CLEAN make clean >/dev/null
$CLEAN ./config.sh "$R/sweep_c.json" >/dev/null
$CLEAN make -j"$J" > /tmp/claude-1000/cbp6_build_c.log 2>&1 || { tail -25 /tmp/claude-1000/cbp6_build_c.log; die "build C failed"; }
cp bin/cbp_perfdir bin/cbp_perfall "$B/"
echo "  -> perfdir perfall"

say "verification"
n=$(ls "$B" | wc -l)
[ "$n" -eq 7 ] || die "expected 7 binaries in $B, found $n"
cmp -s "$B/cbp_runlts" "$B/cbp_runlts_rv" \
  && die "BROKEN: cbp_runlts and cbp_runlts_rv are byte-identical -- the payload flag was dropped, and the sweep would reproduce 'load values do not help' for the wrong reason"
echo "  [ok] 7 binaries, and runlts / runlts_rv differ"
u=$(md5sum "$B"/* | awk '{print $1}' | sort -u | wc -l)
[ "$u" -eq 7 ] || die "only $u distinct binaries of 7 -- some config did not take"
echo "  [ok] all 7 are distinct"
ls -la "$B" | awk 'NR>1{printf "    %-18s %8.2f MB\n", $9, $5/1048576}'
