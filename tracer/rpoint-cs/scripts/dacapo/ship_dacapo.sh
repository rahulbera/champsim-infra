#!/bin/bash
# Ship Redis v1 theta=0.8 traces to the kratos2 catalogue.
# ORDER IS NON-NEGOTIABLE: rename -> hash local -> rsync -> verify ON KRATOS2
# -> register -> (only then, separately) reclaim.  This script STOPS before
# reclamation; deletion is a separate, deliberate step.
set -euo pipefail
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
OUT=$W/out
DEST=/home/rahbera/tracezoo/champsim/version2.1/dacapo
CAT=/home/rahbera/tracezoo/champsim/CHECKSUMS.sha256
STAGE=$W/ship_dacapo
BENCH=${BENCH:?set BENCH to cass|kafka|tomcat}
NEW=${NEW:?set NEW to the trace basename prefix}
NWIN=${NWIN:?set NWIN to the window count}
EXPECT=${EXPECT:?set EXPECT to the current CHECKSUMS line count}

mkdir -p "$STAGE"

echo "=== 0. gate: five OK ==="
n=$(grep -cE '^OK' "$W/logs/convert.${BENCH}_v1.log")
[ "$n" -eq "$NWIN" ] || { echo "ABORT: only $n OK verdicts, expected $NWIN"; exit 1; }
! grep -qE '^(FAIL|MISSING)' "$W/logs/convert.${BENCH}_v1.log" || { echo "ABORT: FAIL/MISSING present"; exit 1; }
echo "$NWIN OK, no FAIL/MISSING"

echo "=== 1. names already in the self-describing scheme -- verify, do not rename ==="
KS=$(for i in $(seq 0 $((NWIN-1))); do printf "%05d " "$i"; done)
for k in $KS; do
  f="$OUT/${NEW}_w$k.champsim2.zst"
  [ -s "$f" ] || { echo "ABORT: missing $f"; exit 1; }
  echo "  present: $(basename "$f")"
done

echo "=== 2. re-verify UNDER THE NEW NAMES ==="
KS=$(for i in $(seq 0 $((NWIN-1))); do printf "%05d " "$i"; done)
for k in $KS; do
  f="$OUT/${NEW}_w$k.champsim2.zst"
  "$INFRA/tools/trace_sanity_check/trace_sanity_check" -i "$f" -f v2 --check >/dev/null 2>&1 \
    || { echo "ABORT: sanity check failed on $(basename "$f")"; exit 1; }
  ins=$("$INFRA/tools/trace_sanity_check/trace_sanity_check" -i "$f" -f v2 2>/dev/null | awk '/total instructions/{print $NF}')
  [ "${ins:-0}" -ge 990000000 ] || { echo "ABORT: $(basename \"$f\") has $ins insns, expected >=990,000,000 (99% of the window; idle-loop filtering legitimately removes up to ~1%)"; exit 1; }
  echo "  OK $(basename "$f") ($ins insns)"
done

echo "=== 3. hash locally ==="
( cd "$OUT" && sha256sum ${NEW}_w*.champsim2.zst ) > "$STAGE/${BENCH}.sha256"
cat "$STAGE/${BENCH}.sha256"

echo "=== 4. rsync to kratos2 ==="
ssh -n -o BatchMode=yes kratos2 "mkdir -p $DEST"
rsync -a --info=progress2 --partial \
  "$OUT/${NEW}"_w*.champsim2.zst "$STAGE/${BENCH}.sha256" \
  kratos2:"$DEST/"

echo "=== 5. GATE: verify ON KRATOS2 ==="
ssh -n -o BatchMode=yes kratos2 "cd $DEST && sha256sum -c ${BENCH}.sha256" | tee "$STAGE/verify.out"
grep -q 'FAILED' "$STAGE/verify.out" && { echo "ABORT: checksum FAILED on kratos2"; exit 1; }
[ "$(grep -c ': OK$' "$STAGE/verify.out")" -eq "$NWIN" ] || { echo "ABORT: not $NWIN OK on kratos2"; exit 1; }
echo "all five verified on kratos2"

echo "=== 6. register in the catalogue ==="
before=$(ssh -n -o BatchMode=yes kratos2 "wc -l < $CAT")
echo "  CHECKSUMS before: $before"
[ "$before" -eq "$EXPECT" ] || { echo "ABORT: expected $EXPECT lines, found $before"; exit 1; }
# the catalogue records BARE BASENAMES (verified against the memcached/rocksdb rows),
# not paths -- ${BENCH}.sha256 is already in exactly that form
cp "$STAGE/${BENCH}.sha256" "$STAGE/${BENCH}.catrows"
cat "$STAGE/${BENCH}.catrows"
rsync -a "$STAGE/${BENCH}.catrows" kratos2:/tmp/${BENCH}.catrows
ssh -n -o BatchMode=yes kratos2 "cat /tmp/${BENCH}.catrows >> $CAT && wc -l < $CAT && rm -f /tmp/${BENCH}.catrows"

echo
echo "=== SHIPPED AND REGISTERED.  Reclamation is a SEPARATE step. ==="
