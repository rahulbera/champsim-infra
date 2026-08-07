#!/usr/bin/env bash
#
# run_agentic_sweep.sh — the CBP6 campaign, re-run on the agentic traces.
#
# Follows README §5 step for step: validate, sweep, gate, roll up. The point of
# the comparison is stated here so it does not get lost:
#
#   The SPEC campaign found direction is 58.4% of the branch headroom and
#   targets the other 41.6%, and that no CBP2025 submission addresses targets.
#   The agentic traces are 86-88% INDIRECT in their compute-heavy windows. So
#   the prediction is that the CBP2025 predictors -- which reproduce their
#   championship ordering on SPEC and buy ~0.8% IPC there -- buy even less here,
#   while the perfdir/perfall oracle GAP widens sharply. Direction prediction is
#   not the lever for this workload class, and this measures by how much.
#
# Usage: run_agentic_sweep.sh [traces_dir] [run_dir]
#
set -uo pipefail

R=/home/rbera/work/bpeval/cbp6-runs
TRACES=${1:-/home/rbera/work/bpeval/qemu-tracing/images/champsim_out}
RUN=${2:-/home/rbera/work/bpeval/cbp6-agentic}
SANITY=/home/rbera/work/bpeval/champsim-infra/tools/trace_sanity_check/trace_sanity_check
JOBS=${JOBS:-12}

say()  { printf '\n=== %s ===\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

mkdir -p "$RUN"
LOG=$RUN/agentic_sweep.log
exec > >(tee -a "$LOG") 2>&1

say "0. collect traces"
# The captures write champsim_out/<instance>/<tag>.champsim2.zst; the sweep
# wants one flat directory. Symlink rather than copy -- these are ~700 MB each.
FLAT=$RUN/traces
mkdir -p "$FLAT"
n=0
for t in "$TRACES"/*/*.champsim2.zst; do
  [ -e "$t" ] || continue
  ln -sf "$t" "$FLAT/$(basename "$t")"; n=$((n+1))
done
[ "$n" -gt 0 ] || die "no traces under $TRACES/*/"
echo "  $n traces linked into $FLAT"

say "1. validate the traces (README §5 step 1 -- do not skip)"
# Primary: enforces the v2 branch-type invariants. A previous generation of
# these traces shipped with the flags register omitted; ChampSim then saw ZERO
# conditional branches and all four predictors returned an identical 21.93 MPKI,
# which reads as a plausible result rather than as a bug.
fail=0
for t in "$FLAT"/*.champsim2.zst; do
  if "$SANITY" -i "$t" -f v2 --check --heartbeat 0 >"$RUN/$(basename "$t").sanity.log" 2>&1; then
    echo "  [ok]   $(basename "$t")"
  else
    echo "  [FAIL] $(basename "$t")"; tail -5 "$RUN/$(basename "$t").sanity.log" | sed 's/^/         /'
    fail=1
  fi
done
[ "$fail" -eq 0 ] || die "trace validation failed -- fix the traces before sweeping"

# Secondary: tests one thing the other cannot -- that a branch recorded
# not-taken is followed by its fall-through address. No simulator bug can fake
# that, and it is the property the perfect-predictor oracle silently depends on.
say "2. fall-through integrity (independent of the simulator)"
for t in "$FLAT"/*.champsim2.zst; do
  out=$(python3 "$R/check_trace_integrity.py" "$t" 2000000 2>&1) || true
  verdict=$(grep -oE '\b(OK|WARN|FAIL)\b' <<<"$out" | head -1)
  printf '  %-6s %s\n' "${verdict:-?}" "$(basename "$t")"
  [ "$verdict" = FAIL ] && fail=1
done
[ "$fail" -eq 0 ] || die "fall-through integrity failed"

say "3. sweep (7 configs x $n traces)"
[ -d "$R/bin" ] || die "no $R/bin -- run rebuild_bin.sh first"
CBP6_TRACES="$FLAT" CBP6_OUT="$RUN" CBP6_BIN="$R/bin" JOBS="$JOBS" \
  bash "$R/run_sweep.sh" || die "sweep reported a failure"

say "4. post-sweep gates (README §5 step 2)"
# A wrapped trace invalidates cross-configuration comparison, because different
# configurations wrap at different points.
w=$(grep -rl 'Reached end of trace' "$RUN/results/" 2>/dev/null | wc -l)
m=$(grep -rl 'carries no explicit branch type' "$RUN/results/" 2>/dev/null | wc -l)
echo "  wrapped traces:            $w  (must be 0)"
echo "  missing v2 branch metadata: $m  (must be 0)"
[ "$w" -eq 0 ] && [ "$m" -eq 0 ] || die "post-sweep gate failed"

say "5. weights, then roll up"
WEIGHTS=$RUN/weights
python3 "$R/make_agentic_weights.py" "$TRACES" "$WEIGHTS" || die "weight generation failed"
mkdir -p "$RUN/analysis"
cd "$R"
CBP6_RUN_DIR="$RUN" CBP6_SIMPOINT="$WEIGHTS" CBP6_TRACES="$FLAT" python3 rollup.py \
  || die "rollup failed"
CBP6_RUN_DIR="$RUN" CBP6_SIMPOINT="$WEIGHTS" python3 headroom.py \
  || echo "  [warn] headroom.py reported a problem -- read its output above"

say "DONE"
echo "  per-trace:     $RUN/analysis/per_trace.csv"
echo "  per-benchmark: $RUN/analysis/per_benchmark.csv"
echo "  summary:       $RUN/analysis/summary.csv"
echo "  SPEC campaign to compare against: $R/analysis/"
