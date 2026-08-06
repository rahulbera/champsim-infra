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

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS FAILURE(S)"; exit 1
