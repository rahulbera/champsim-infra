#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"; M="$INFRA"
k=$1
IN=$W/traces/ren_nbayes/trace_vcpu1_c$k.raw.zst
# Fields MEASURED from the benchmark itself, not assumed:
#   spark3.5.3        : unique/apache-spark/spark-core_2.13-3.5.3.jar in the
#                       Renaissance jar; Scala 2.13, hadoop-client 3.3.6
#   renaissance0.16.1 : the harness (release v0.16.1, 2025-11-10)
#   naivebayes        : Renaissance `naive-bayes` -- multinomial Naive Bayes from
#                       Spark ML. Chosen as the counterpart to page-rank because
#                       page-rank is the ONLY one of the eight apache-spark
#                       benchmarks using the raw RDD API; naive-bayes runs the
#                       DataFrame -> Catalyst -> Tungsten whole-stage-codegen
#                       path, generating Java at runtime via Janino and scanning
#                       packed off-heap UnsafeRows. Different engine, not just a
#                       different algorithm.
#                       MEASURED before committing: copy_count=8000 (largest
#                       input multiplier in the group), spark_thread_limit=all
#                       cores, live set 1.35 GB after GC vs page-rank's 149 MB
#                       (9x), peak RSS 4.42 GB, 3.7 GB spilled to disk per 3
#                       iterations. 291 JVM threads at launch, 274 at capture.
#   local             : Spark local mode, ONE JVM, no cluster/HDFS/Zookeeper.
#                       Recorded deviation: no network shuffle over TCP.
#   jdk21g1gc4G       : OpenJDK 21.0.12, -XX:+UseG1GC, -Xms4g -Xmx4g pinned
N=spark3.5.3_renaissance0.16.1_naivebayes_local_jdk21g1gc4G_1t_ubu24.04_qemu9.2.4tcg_1B_w$k
F=$W/traces/ren_nbayes/$N.filt.raw.zst
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
