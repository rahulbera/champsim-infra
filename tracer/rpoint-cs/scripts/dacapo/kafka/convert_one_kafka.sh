#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"; M="$INFRA"
k=$1
IN=$W/traces/kafka_v1/trace_vcpu1_c$k.raw.zst
# Fields MEASURED from the benchmark, not assumed:
#   kafka3.3.1   : jar/kafka/kafka_2.13-3.3.1.jar, confirmed by the run banner
#                  "Version: kafka 3.3.1"
#   10Mmsg       : dat/kafka/simple_produce_bench-large.json maxMessages=10000000
#   2topx10part  : activeTopics dacapo-[1-2], numPartitions 10, replicationFactor 1
#   jdk21g1gc2G  : OpenJDK 21.0.12, -XX:+UseG1GC, -Xms2g -Xmx2g pinned explicitly
N=kafka3.3.1_dacapo23.11trogdor_10Mmsg_2topx10part_jdk21g1gc2G_1t_ubu24.04_qemu9.2.4tcg_1B_w$k
F=$W/traces/kafka_v1/$N.filt.raw.zst
C=$W/out/$N.champsim2.zst
mkdir -p "$W/out" "$W/logs"
[ -s "$IN" ] || { echo "MISSING $IN"; exit 1; }
[ -e "$C" ] && { echo "$C already exists - STOP"; exit 1; }
"$M/tracer/rpoint-cs/plugin/trace_filter" "$IN" "$F" || { echo "FILTER FAIL $N"; exit 1; }
"$M/tracer/rpoint-cs/converter/raw2champsim" "$F" "$C" 2>&1 | tee "$W/logs/$N.convert.log"
conv=${PIPESTATUS[0]}
grep -qE 'Decode failures: +0$' "$W/logs/$N.convert.log"; dec=$?
"$M/tools/trace_sanity_check/trace_sanity_check" -i "$C" -f v2 --check >/dev/null 2>&1; chk=$?
ins=$("$M/tools/trace_sanity_check/trace_sanity_check" -i "$C" -f v2 2>/dev/null | awk '/total instructions/{print $NF}')
if [ "$conv" -eq 0 ] && [ "$dec" -eq 0 ] && [ "$chk" -eq 0 ] && [ "${ins:-0}" -gt 600000000 ]; then
  rm -f "$F"; echo "OK $N ($ins insns)"
else
  echo "FAIL $N (conv=$conv decode=$dec check=$chk insns=${ins:-0}) - raw KEPT at $IN"
fi
