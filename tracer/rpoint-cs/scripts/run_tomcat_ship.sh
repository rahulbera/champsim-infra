#!/bin/bash
set -u
W=$HOME/work/new-tracing; REPO=$W/champsim-infra
D=$REPO/tracer/rpoint-cs/docs/workloads/dacapo
LOG=$W/logs/convert.tomcat_v1.log
# grep -c on a file that does not exist yet yields EMPTY, and [ "" -eq 3 ] is a
# shell error, not a false. Normalise to an integer before testing.
okcount() { [ -e "$LOG" ] && grep -acE '^OK' "$LOG" 2>/dev/null || echo 0; }
{
  echo "waiting for tomcat conversion gate (3 OK)..."
  while :; do
    n=$(okcount)
    [ "${n:-0}" -eq 3 ] && break
    if [ -e "$LOG" ] && grep -qaE '^(FAIL|MISSING)' "$LOG"; then
      echo "FAIL/MISSING — STOPPING, needs a human"; grep -aE '^(FAIL|MISSING)' "$LOG"; exit 1
    fi
    sleep 60
  done
  date -u '+%H:%M:%SZ tomcat gate reached (3 OK)'
  echo "waiting for kafka to finish registering (CHECKSUMS must reach 185)..."
  for i in $(seq 1 240); do
    L=$(timeout 45 ssh -n -o BatchMode=yes kratos2 'wc -l < /home/rahbera/tracezoo/champsim/CHECKSUMS.sha256' 2>/dev/null)
    [ "${L:-0}" = "185" ] && { echo "CHECKSUMS at 185"; break; }
    sleep 30
  done
  L=$(timeout 45 ssh -n -o BatchMode=yes kratos2 'wc -l < /home/rahbera/tracezoo/champsim/CHECKSUMS.sha256' 2>/dev/null)
  [ "${L:-0}" = "185" ] || { echo "ABORT: CHECKSUMS is ${L:-unknown}, expected 185 — not shipping tomcat unattended"; exit 1; }
  mkdir -p "$D"; cp $W/traces/tomcat_v1/trace_vcpu1_manifest.txt "$D/tomcat-v1-manifest.txt"
  echo "manifest preserved"
  BENCH=tomcat \
  NEW=tomcat10.1.11_dacapo23.11_800Kreq_jdk21g1gc512M_1t_ubu24.04_qemu9.2.4tcg_1B \
  NWIN=3 EXPECT=185 bash $W/ship_dacapo.sh
  echo "SHIP_RC=$?"
} >> "$W/logs/tomcat_ship_run.log" 2>&1
