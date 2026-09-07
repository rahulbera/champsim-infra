#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
D=$INFRA/tracer/rpoint-cs/docs/workloads/dacapo
{
  echo "waiting for cassandra gate (5 OK)..."
  until [ "$(grep -acE '^OK' $W/logs/convert.cass_v1.log)" -eq 5 ] \
     || grep -qaE '^(FAIL|MISSING)' $W/logs/convert.cass_v1.log; do sleep 60; done
  date -u '+%H:%M:%SZ gate reached'
  if grep -qaE '^(FAIL|MISSING)' $W/logs/convert.cass_v1.log; then
    echo "FAIL/MISSING PRESENT — STOPPING, needs a human"; grep -aE '^(FAIL|MISSING)' $W/logs/convert.cass_v1.log; exit 1
  fi
  # provenance BEFORE anything can be deleted
  mkdir -p "$D"
  cp $W/traces/cass_v1/trace_vcpu1_manifest.txt "$D/cassandra-v1-manifest.txt"
  echo "manifest preserved -> $D/cassandra-v1-manifest.txt"
  BENCH=cass \
  NEW=cassandra5.1pre_dacapo23.11ycsb_100Kx1KB_rd50wr50_zipf0.99_jdk21g1gc1G_1t_ubu24.04_qemu9.2.4tcg_1B \
  NWIN=5 EXPECT=177 bash $SROOT/dacapo/ship_dacapo.sh
  echo "SHIP_RC=$?"
} >> "$W/logs/cass_ship_run.log" 2>&1
