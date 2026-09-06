#!/bin/bash
set -u
W=$HOME/work/new-tracing; REPO=$W/champsim-infra
D=$REPO/tracer/rpoint-cs/docs/workloads/spark
LOG=$W/logs/convert.spark_v1.log
# grep -c prints "0" AND exits 1 with no matches, so `|| echo 0` emits "0\n0"
# and every numeric test on it is a shell error. Five occurrences tonight.
# One definition, piped through head -1, defaulted.
okcount() { local n; n=$( grep -acE '^OK' "$LOG" 2>/dev/null | head -1 ); echo "${n:-0}"; }
{
  echo "waiting for spark conversion gate (3 OK)..."
  while :; do
    n=$(okcount); [ "$n" -eq 3 ] && break
    if [ -e "$LOG" ] && grep -qaE '^(FAIL|MISSING)' "$LOG"; then
      echo "FAIL/MISSING — STOPPING, needs a human"; grep -aE '^(FAIL|MISSING)' "$LOG"; exit 1
    fi
    sleep 60
  done
  date -u '+%H:%M:%SZ spark gate reached (3 OK)'
  echo "waiting for the catalogue to settle at 188 (tomcat registered)..."
  for i in $(seq 1 240); do
    L=$(timeout 45 ssh -n -o BatchMode=yes kratos2 'wc -l < /home/rahbera/tracezoo/champsim/CHECKSUMS.sha256' 2>/dev/null | head -1)
    [ "${L:-0}" = "188" ] && { echo "CHECKSUMS at 188"; break; }
    sleep 30
  done
  L=$(timeout 45 ssh -n -o BatchMode=yes kratos2 'wc -l < /home/rahbera/tracezoo/champsim/CHECKSUMS.sha256' 2>/dev/null | head -1)
  [ "${L:-0}" = "188" ] || { echo "ABORT: CHECKSUMS is ${L:-unknown}, expected 188"; exit 1; }
  mkdir -p "$D"; cp "$W/traces/spark_v1/trace_vcpu1_manifest.txt" "$D/spark-v1-manifest.txt"
  echo "manifest preserved"
  BENCH=spark \
  NEW=spark3.5.3_renaissance0.16.1_pagerank_local_jdk21g1gc4G_1t_ubu24.04_qemu9.2.4tcg_1B \
  NWIN=3 EXPECT=188 DEST_OVERRIDE=1 bash "$W/ship_spark.sh"
  echo "SHIP_RC=$?"
} >> "$W/logs/spark_ship_run.log" 2>&1
