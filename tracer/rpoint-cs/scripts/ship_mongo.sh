#!/bin/bash
# Ship Redis v1 theta=0.8 traces to the kratos2 catalogue.
# ORDER IS NON-NEGOTIABLE: rename -> hash local -> rsync -> verify ON KRATOS2
# -> register -> (only then, separately) reclaim.  This script STOPS before
# reclamation; deletion is a separate, deliberate step.
set -euo pipefail
W=$HOME/work/new-tracing
OUT=$W/out
DEST=/home/rahbera/tracezoo/champsim/version2.1/mongodb
CAT=/home/rahbera/tracezoo/champsim/CHECKSUMS.sha256
STAGE=$W/ship_mongo
NEW=mongodb8.0.29_libmongoc_40Mx1KB_rd95wr05_zipf0.99_wt1G_1t_ubu24.04_qemu9.2.4tcg_1B

mkdir -p "$STAGE"

echo "=== 0. gate: five OK ==="
n=$(grep -cE '^OK' "$W/logs/convert.mongo_v1.log")
[ "$n" -eq 5 ] || { echo "ABORT: only $n OK verdicts"; exit 1; }
! grep -qE '^(FAIL|MISSING)' "$W/logs/convert.mongo_v1.log" || { echo "ABORT: FAIL/MISSING present"; exit 1; }
echo "5 OK, no FAIL/MISSING"

echo "=== 1. names already in the self-describing scheme -- verify, do not rename ==="
for k in 00000 00001 00002 00003 00004; do
  f="$OUT/${NEW}_w$k.champsim2.zst"
  [ -s "$f" ] || { echo "ABORT: missing $f"; exit 1; }
  echo "  present: $(basename "$f")"
done

echo "=== 2. re-verify UNDER THE NEW NAMES ==="
for k in 00000 00001 00002 00003 00004; do
  f="$OUT/${NEW}_w$k.champsim2.zst"
  "$W/champsim-infra/tools/trace_sanity_check/trace_sanity_check" -i "$f" -f v2 --check >/dev/null 2>&1 \
    || { echo "ABORT: sanity check failed on $(basename "$f")"; exit 1; }
  ins=$("$W/champsim-infra/tools/trace_sanity_check/trace_sanity_check" -i "$f" -f v2 2>/dev/null | awk '/total instructions/{print $NF}')
  [ "${ins:-0}" -ge 999900000 ] || { echo "ABORT: $(basename \"$f\") has $ins insns, expected >=999,900,000"; exit 1; }
  echo "  OK $(basename "$f") ($ins insns)"
done

echo "=== 3. hash locally ==="
( cd "$OUT" && sha256sum ${NEW}_w0000*.champsim2.zst ) > "$STAGE/mongo.sha256"
cat "$STAGE/mongo.sha256"

echo "=== 4. rsync to kratos2 ==="
ssh -n -o BatchMode=yes kratos2 "mkdir -p $DEST"
rsync -a --info=progress2 --partial \
  "$OUT/${NEW}"_w0000*.champsim2.zst "$STAGE/mongo.sha256" \
  kratos2:"$DEST/"

echo "=== 5. GATE: verify ON KRATOS2 ==="
ssh -n -o BatchMode=yes kratos2 "cd $DEST && sha256sum -c mongo.sha256" | tee "$STAGE/verify.out"
grep -q 'FAILED' "$STAGE/verify.out" && { echo "ABORT: checksum FAILED on kratos2"; exit 1; }
[ "$(grep -c ': OK$' "$STAGE/verify.out")" -eq 5 ] || { echo "ABORT: not 5 OK on kratos2"; exit 1; }
echo "all five verified on kratos2"

echo "=== 6. register in the catalogue ==="
before=$(ssh -n -o BatchMode=yes kratos2 "wc -l < $CAT")
echo "  CHECKSUMS before: $before"
[ "$before" -eq 172 ] || { echo "ABORT: expected 172 lines, found $before"; exit 1; }
# the catalogue records BARE BASENAMES (verified against the memcached/rocksdb rows),
# not paths -- mongo.sha256 is already in exactly that form
cp "$STAGE/mongo.sha256" "$STAGE/mongo.catrows"
cat "$STAGE/mongo.catrows"
rsync -a "$STAGE/mongo.catrows" kratos2:/tmp/mongo.catrows
ssh -n -o BatchMode=yes kratos2 "cat /tmp/mongo.catrows >> $CAT && wc -l < $CAT && rm -f /tmp/mongo.catrows"

echo
echo "=== SHIPPED AND REGISTERED.  Reclamation is a SEPARATE step. ==="
