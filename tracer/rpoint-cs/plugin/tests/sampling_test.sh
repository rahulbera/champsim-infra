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

echo "== Task 3: user-mode sampling clock =="

# Needs a guest with a real user/kernel split. The BIOS boot cannot exercise
# this: SeaBIOS runs entirely at low addresses, so the VA-based privilege
# heuristic reads it as 100% "user" and both clocks behave identically.
# Build the assets with scripts/smoke-trace/smoke_trace.sh, then export:
#   GUEST_KERNEL=<bzImage>  GUEST_INITRD=<initramfs.gz>
GUEST_KERNEL="${GUEST_KERNEL:-}"
GUEST_INITRD="${GUEST_INITRD:-}"
if [ -z "$GUEST_KERNEL" ] || [ ! -f "$GUEST_KERNEL" ]; then
  echo "  SKIP: set GUEST_KERNEL and GUEST_INITRD (see scripts/smoke-trace/) to run this"
else
  run_guest() { # run_guest <outdir> <extra-plugin-args>
    local out="$1"; local extra="$2"
    mkdir -p "$out"; rm -f "$out"/trace_vcpu*.raw.zst "$out"/*manifest.txt
    timeout 300 "$QEMU" -accel tcg -cpu qemu64 -smp 1 -m 1G \
      -kernel "$GUEST_KERNEL" -initrd "$GUEST_INITRD" \
      -append "console=ttyS0 quiet" -nographic -no-reboot \
      -plugin "$PLUGIN,outdir=$out,vcpus=0$extra" > "$out/boot.log" 2>&1
    return 0
  }
  win_start() { awk -v k="$2" '!/^#/ && $1==k {print $3}' "$1/trace_vcpu0_manifest.txt"; }

  # Kernel-mode instructions must NOT advance the gap under sample_clock=user,
  # so a user-clock run reaches window 1 LATER in the instruction stream than
  # sample_len+sample_gap. Only the user run is needed: Task 2 already proved
  # on BIOS that an all-clock run lands at EXACTLY sample_len+sample_gap, so
  # that is the oracle and a second guest boot would just re-derive it.
  #
  # The gap must be large enough to reach kernel-heavy execution. Until paging
  # is enabled the kernel's decompressor and early setup run at LOW virtual
  # addresses, which the VA-based privilege heuristic reads as "user" -- a 100M
  # gap sits entirely inside that region and the two clocks agree exactly.
  # Measured on this guest with profile=on: 19.5B instructions, 91.3% user /
  # 8.7% kernel (1.70B kernel), essentially all of it after decompression.
  SLEN=200000
  SGAP=2000000000
  run_guest "$WORK/t3u" ",sample_len=$SLEN,sample_gap=$SGAP,sample_count=2,sample_clock=user"

  start_u=$(win_start "$WORK/t3u" 1)
  all_clock_would_be=$((SLEN + SGAP))
  [ -n "$start_u" ] && [ "$start_u" -gt "$all_clock_would_be" ]
  check "kernel insns do not advance the gap ($start_u > $all_clock_would_be)" $?

  # Window length is clock-independent: exactly sample_len regardless of clock.
  bad=$(awk -v n="$SLEN" '!/^#/ && $4 != n {print}' \
        "$WORK/t3u/trace_vcpu0_manifest.txt" | wc -l)
  [ "$bad" -eq 0 ]
  check "window length is exactly sample_len under the user clock ($bad bad rows)" $?
fi

echo "== Task 4: profile mode =="

run_bios "$WORK/t4" ",limit=0,profile=on"

grep -qE "PROFILE: [0-9]+ instructions \\([0-9]+ user, [0-9]+ kernel\\)" "$WORK/t4/plugin_stderr.log"
check "profile mode reports total/user/kernel counts" $?

n_files=$(ls "$WORK/t4"/trace_vcpu0*.raw.zst 2>/dev/null | wc -l)
[ "$n_files" -eq 0 ]
check "profile mode writes no trace files (got $n_files)" $?

echo "== Task 5: sampling with gap=0 must equal rotation =="

# Sampling with sample_gap=0 and sample_clock=all is definitionally the same
# schedule as rotate=, so the two must produce byte-identical chunks. This is
# the check that catches an off-by-one at the window boundary -- the class of
# bug that produced the 1.56x pintool skip-counter error and that no
# self-consistency check can see.
run_bios "$WORK/t5s" ",limit=100000,sample_len=50000,sample_gap=0,sample_count=2,sample_clock=all"
run_bios "$WORK/t5r" ",limit=100000,rotate=50000"

same=0
for k in 00000 00001; do
  a="$WORK/t5s/trace_vcpu0_c$k.raw.zst"
  b="$WORK/t5r/trace_vcpu0_c$k.raw.zst"
  if [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"; then :; else same=1; fi
done
[ "$same" -eq 0 ]
check "gap=0 sampling is byte-identical to rotate= for every chunk" $?

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS FAILURE(S)"; exit 1
