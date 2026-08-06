#!/bin/bash
# sampling_test.sh — tests for the plugin's periodic sampling knobs.
#
# Uses the BIOS-only boot from smoke_capture.sh: no disk, no OS, ~20s, and
# SeaBIOS alone retires >200k instructions — enough to exercise the sampler.
# Window/gap sizes below are chosen to fit inside that budget with margin.
#
# Usage: sampling_test.sh [workdir]
set -u
WORK="${1:-${TMPDIR:-/tmp}/cstf-sampling}"
QEMU="${QEMU:-$HOME/qemu-custom/bin/qemu-system-x86_64}"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$PLUGIN_DIR/champsim_tracer.so"
FAILS=0

# Boot SeaBIOS with the given extra plugin args. Writes $1/plugin_stderr.log.
run_bios() {
  local out="$1"; shift
  local extra="$1"
  mkdir -p "$out"; rm -f "$out"/trace_vcpu*.raw.zst "$out"/*manifest.txt
  timeout 40 "$QEMU" \
    -accel tcg -display none -nodefaults -machine pc -m 256 \
    -plugin "$PLUGIN,outdir=$out,vcpus=0$extra" \
    2> "$out/plugin_stderr.log"
  return 0
}

check() { # check <description> <condition-rc>
  if [ "$2" -eq 0 ]; then echo "  PASS: $1"; else echo "  FAIL: $1"; FAILS=$((FAILS+1)); fi
}

echo "== Task 1: knob parsing and validation =="

run_bios "$WORK/t1a" ",limit=200000,sample_len=50000,sample_gap=20000,sample_count=3"
grep -q "Sampling: 3 windows x 50000 insns, gap 20000, clock=user" "$WORK/t1a/plugin_stderr.log"
check "knobs are parsed and reported in the banner" $?

run_bios "$WORK/t1b" ",limit=200000,sample_len=50000,rotate=1000"
grep -q "rotate= and sample_len= are mutually exclusive" "$WORK/t1b/plugin_stderr.log"
check "rotate= together with sample_len= is rejected" $?

run_bios "$WORK/t1c" ",limit=200000,sample_len=50000,sample_clock=bogus"
grep -q "sample_clock= must be user|all" "$WORK/t1c/plugin_stderr.log"
check "invalid sample_clock= value is rejected" $?

echo "== Task 2: window geometry =="

# 3 windows of 20k, gap 10k = 80k instructions total. SeaBIOS retires >200k,
# so this fits with margin; 50k/20k windows would not.
run_bios "$WORK/t2a" ",sample_len=20000,sample_gap=10000,sample_count=3,sample_clock=all"

n_chunks=$(ls "$WORK/t2a"/trace_vcpu0_c*.raw.zst 2>/dev/null | wc -l)
[ "$n_chunks" -eq 3 ]
check "exactly 3 chunk files produced (got $n_chunks)" $?

# Manifest columns: index file start_insn insn_count compressed_bytes
MAN="$WORK/t2a/trace_vcpu0_manifest.txt"
[ -f "$MAN" ]
check "manifest written" $?

if [ -f "$MAN" ]; then
  bad=$(awk '!/^#/ && $4 != 20000 {print}' "$MAN" | wc -l)
  [ "$bad" -eq 0 ]
  check "every window holds exactly 20000 instructions ($bad bad rows)" $?

  # Window k starts at k*(len+gap) = k*30000, where k is the chunk index (col 1).
  bad=$(awk '!/^#/ && $3 != $1*30000 {print}' "$MAN" | wc -l)
  [ "$bad" -eq 0 ]
  check "window start offsets are len+gap apart ($bad bad rows)" $?
else
  check "every window holds exactly 20000 instructions (no manifest)" 1
  check "window start offsets are len+gap apart (no manifest)" 1
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS FAILURE(S)"; exit 1
