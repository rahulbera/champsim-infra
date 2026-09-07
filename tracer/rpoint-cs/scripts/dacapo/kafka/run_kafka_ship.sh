#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
D=$INFRA/tracer/rpoint-cs/docs/workloads/dacapo
{
  echo "waiting for kafka gate (3 OK)..."
  until [ "$(grep -acE '^OK' $W/logs/convert.kafka_v1.log)" -eq 3 ] \
     || grep -qaE '^(FAIL|MISSING)' $W/logs/convert.kafka_v1.log; do sleep 60; done
  date -u '+%H:%M:%SZ kafka gate reached'
  if grep -qaE '^(FAIL|MISSING)' $W/logs/convert.kafka_v1.log; then
    echo "FAIL/MISSING PRESENT — STOPPING, needs a human"; grep -aE '^(FAIL|MISSING)' $W/logs/convert.kafka_v1.log; exit 1
  fi
  # Do NOT ship concurrently with cassandra: both mutate CHECKSUMS.sha256, and the
  # line-count precondition (EXPECT) would race. Wait for cassandra to finish first.
  echo "waiting for the cassandra ship to finish (CHECKSUMS must settle at 182)..."
  for i in $(seq 1 240); do
    L=$(timeout 45 ssh -n -o BatchMode=yes kratos2 'wc -l < /home/rahbera/tracezoo/champsim/CHECKSUMS.sha256' 2>/dev/null)
    [ "$L" = "182" ] && { echo "CHECKSUMS at 182, cassandra registered"; break; }
    sleep 30
  done
  L=$(timeout 45 ssh -n -o BatchMode=yes kratos2 'wc -l < /home/rahbera/tracezoo/champsim/CHECKSUMS.sha256' 2>/dev/null)
  [ "$L" = "182" ] || { echo "ABORT: CHECKSUMS is $L, expected 182 — not shipping kafka unattended"; exit 1; }
  mkdir -p "$D"
  cp $W/traces/kafka_v1/trace_vcpu1_manifest.txt "$D/kafka-v1-manifest.txt"
  echo "manifest preserved"
  BENCH=kafka \
  NEW=kafka3.3.1_dacapo23.11trogdor_10Mmsg_2topx10part_jdk21g1gc2G_1t_ubu24.04_qemu9.2.4tcg_1B \
  NWIN=3 EXPECT=182 bash $SROOT/dacapo/ship_dacapo.sh
  echo "SHIP_RC=$?"
} >> "$W/logs/kafka_ship_run.log" 2>&1
