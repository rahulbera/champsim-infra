#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"; M="$INFRA"
k=$1
IN=$W/traces/tomcat_v1/trace_vcpu1_c$k.raw.zst
# Fields MEASURED from the benchmark, not assumed:
#   tomcat10.1.11 : run banner "Version: tomcat 10.1.11", corroborated by
#                   dat/tomcat/RELEASE-NOTES "Apache Tomcat Version 10.1.11"
#   800Kreq       : "Starting 800000 requests..." at -s large
#   1t            : "Server created with thread pool size 1" from -t 1
#   jdk21g1gc512M : OpenJDK 21.0.12, -XX:+UseG1GC, -Xms512m -Xmx512m.
#                   DELIBERATE deviation from the ~5.8x-minheap ratio used for
#                   cassandra and kafka: tomcat's minheap at -s large is only
#                   35 MB, and 5.8x of that (~200 MB) is not a heap anyone would
#                   deploy. 512 MB is the smallest realistic one and still keeps
#                   G1 active. Realism beats ratio-consistency; the value is in
#                   the trace name so the choice stays visible.
N=tomcat10.1.11_dacapo23.11_800Kreq_jdk21g1gc512M_1t_ubu24.04_qemu9.2.4tcg_1B_w$k
F=$W/traces/tomcat_v1/$N.filt.raw.zst
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
