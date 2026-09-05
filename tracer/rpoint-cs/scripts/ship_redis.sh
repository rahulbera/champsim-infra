#!/bin/bash
# Ship Redis v1 theta=0.8 traces to the kratos2 catalogue.
# ORDER IS NON-NEGOTIABLE: rename -> hash local -> rsync -> verify ON KRATOS2
# -> register -> (only then, separately) reclaim.  This script STOPS before
# reclamation; deletion is a separate, deliberate step.
set -euo pipefail
W=$HOME/work/new-tracing
OUT=$W/out
DEST=/home/rahbera/tracezoo/champsim/version2.1/redis
CAT=/home/rahbera/tracezoo/champsim/CHECKSUMS.sha256
STAGE=$W/ship_redis
NEW=redis7.0.15_memtier_8Mx512B_rd99wr01_zipf0.80_mget16_1t_ubu24.04_qemu9.2.4tcg_1B

mkdir -p "$STAGE"

echo "=== 0. gate: five OK ==="
n=$(grep -cE '^OK' "$W/logs/convert.redis_v1.log")
[ "$n" -eq 5 ] || { echo "ABORT: only $n OK verdicts"; exit 1; }
! grep -qE '^(FAIL|MISSING)' "$W/logs/convert.redis_v1.log" || { echo "ABORT: FAIL/MISSING present"; exit 1; }
echo "5 OK, no FAIL/MISSING"

echo "=== 1. rename to the self-describing scheme ==="
for k in 00000 00001 00002 00003 00004; do
  old="$OUT/redis_v1_n8M_v512_rd94_zipf08_mget16_1t_w$k.champsim2.zst"
  new="$OUT/${NEW}_w$k.champsim2.zst"
  if [ -e "$new" ]; then echo "  already renamed: $(basename "$new")"; continue; fi
  [ -s "$old" ] || { echo "ABORT: missing $old"; exit 1; }
  mv -n "$old" "$new"; echo "  $(basename "$new")"
done

echo "=== 2. re-verify UNDER THE NEW NAMES ==="
for k in 00000 00001 00002 00003 00004; do
  f="$OUT/${NEW}_w$k.champsim2.zst"
  "$W/champsim-infra/tools/trace_sanity_check/trace_sanity_check" -i "$f" -f v2 --check >/dev/null 2>&1 \
    || { echo "ABORT: sanity check failed on $(basename "$f")"; exit 1; }
  ins=$("$W/champsim-infra/tools/trace_sanity_check/trace_sanity_check" -i "$f" -f v2 2>/dev/null | awk '/total instructions/{print $NF}')
  [ "$ins" = "1000000000" ] || { echo "ABORT: $(basename "$f") has $ins insns, expected 1000000000"; exit 1; }
  echo "  OK $(basename "$f") ($ins insns)"
done

echo "=== 3. hash locally ==="
( cd "$OUT" && sha256sum ${NEW}_w0000*.champsim2.zst ) > "$STAGE/redis.sha256"
cat "$STAGE/redis.sha256"

echo "=== 4. rsync to kratos2 ==="
ssh -n -o BatchMode=yes kratos2 "mkdir -p $DEST"
rsync -a --info=progress2 --partial \
  "$OUT/${NEW}"_w0000*.champsim2.zst "$STAGE/redis.sha256" \
  kratos2:"$DEST/"

echo "=== 5. GATE: verify ON KRATOS2 ==="
ssh -n -o BatchMode=yes kratos2 "cd $DEST && sha256sum -c redis.sha256" | tee "$STAGE/verify.out"
grep -q 'FAILED' "$STAGE/verify.out" && { echo "ABORT: checksum FAILED on kratos2"; exit 1; }
[ "$(grep -c ': OK$' "$STAGE/verify.out")" -eq 5 ] || { echo "ABORT: not 5 OK on kratos2"; exit 1; }
echo "all five verified on kratos2"

echo "=== 6. register in the catalogue ==="
before=$(ssh -n -o BatchMode=yes kratos2 "wc -l < $CAT")
echo "  CHECKSUMS before: $before"
[ "$before" -eq 167 ] || { echo "ABORT: expected 167 lines, found $before"; exit 1; }
# the catalogue records BARE BASENAMES (verified against the memcached/rocksdb rows),
# not paths -- redis.sha256 is already in exactly that form
cp "$STAGE/redis.sha256" "$STAGE/redis.catrows"
cat "$STAGE/redis.catrows"
rsync -a "$STAGE/redis.catrows" kratos2:/tmp/redis.catrows
ssh -n -o BatchMode=yes kratos2 "cat /tmp/redis.catrows >> $CAT && wc -l < $CAT && rm -f /tmp/redis.catrows"

echo
echo "=== SHIPPED AND REGISTERED.  Reclamation is a SEPARATE step. ==="
