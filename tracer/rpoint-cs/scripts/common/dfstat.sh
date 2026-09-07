#!/bin/bash
# Report the max decode_fail across converter logs matching a glob.
#
# WHY THIS EXISTS: decode_fail is one field on a progress line that ends with
#   ... | decode_fail 0 memop_overflow 33380 | INT 508629459 FP 84 SIMD 1370457
# An unanchored `grep -oE '[0-9]+$'` on that line returns the SIMD count, not
# decode_fail. On 2026-09-06 12:45Z that misread reported decode_fail=1606302
# (actually w00001's SIMD count) and nearly triggered a false ESCALATE.
# Same family as the `grep -c` trap: never extract a number without its label.
set -u
pat="${1:?usage: dfstat.sh '<glob for *.convert.log>'}"
max=0; worst=""
for f in $pat; do
  [ -e "$f" ] || continue
  v=$(tr '\r' '\n' < "$f" | grep -aoE 'decode_fail[=: ]+[0-9]+' | grep -oE '[0-9]+' | sort -rn | head -1)
  v=${v:-0}
  [ "$v" -gt "$max" ] && { max=$v; worst=$(basename "$f"); }
done
echo "decode_fail_max=$max${worst:+ in=$worst}"
