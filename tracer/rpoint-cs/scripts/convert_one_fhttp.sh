#!/bin/bash
set -u
W=$HOME/work/new-tracing; M=$W/champsim-infra
k=$1
IN=$W/traces/ren_fhttp/trace_vcpu1_c$k.raw.zst
# Fields MEASURED from the benchmark itself, not assumed:
#   spark3.5.3        : unique/apache-spark/spark-core_2.13-3.5.3.jar in the
#                       Renaissance jar; Scala 2.13, hadoop-client 3.3.6
#   renaissance0.16.1 : the harness (release v0.16.1, 2025-11-10)
#   finaglehttp       : Renaissance `finagle-http` -- many small HTTP requests to
#                       a Twitter Finagle HTTP server, client and server in ONE
#                       JVM over TCP loopback.
#                       INCLUDED ON CONTROL-FLOW GROUNDS, at the researcher's
#                       explicit direction: "more interesting from control-flow
#                       perspective: they may or may not be interesting from
#                       memory perspective. But that's fine." The memory-
#                       intensity half of the standing constraint is WAIVED for
#                       this workload; deployment realism still applies.
#                       MEASURED: live set 14.1 MB after GC (vs naive-bayes
#                       1.35 GB, page-rank 149 MB) -- ~100x smaller, as expected.
#                       47 JVM threads at launch, 49 at capture, all pinned.
#                       Under TCG: 75.4 MIPS, the SLOWEST rate in the corpus
#                       (tomcat 76.6, cassandra 84.5, q18 255.7), and 31.51%
#                       kernel -- every request crosses the kernel twice and TCG
#                       cannot accelerate syscalls.
#   local             : Spark local mode, ONE JVM, no cluster/HDFS/Zookeeper.
#                       Recorded deviation: no network shuffle over TCP.
#   jdk21g1gc4G       : OpenJDK 21.0.12, -XX:+UseG1GC, -Xms4g -Xmx4g pinned
N=finagle24.2.0_renaissance0.16.1_finaglehttp_local_jdk21g1gc4G_1t_ubu24.04_qemu9.2.4tcg_1B_w$k
F=$W/traces/ren_fhttp/$N.filt.raw.zst
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
