#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"; M="$INFRA"
k=$1
IN=$W/traces/pg_q21/trace_vcpu1_c$k.raw.zst
# Fields MEASURED, not assumed:
#   postgres16.15 : `select version()` in the guest
#   tpch_sf10     : dbgen -s 10; verified row counts (lineitem 59,986,052 etc)
#   q21           : TPC-H Q21, suppliers who kept orders waiting -- correlated
#                   EXISTS and NOT EXISTS subqueries over a self-joined lineitem,
#                   with orders, supplier and nation. Included at the
#                   researcher's direction as last priority; it is the most
#                   I/O-bound of the set (51.2% CPU / 8.3% iowait under KVM).
#                   Under TCG it measured 172.2 MIPS / **60.90% user**, i.e.
#                   39.10% KERNEL -- the most kernel-heavy query by a wide margin
#                   (q18 6.19%, q1 17.50%, q9 28.96%) and the corpus's clearest
#                   demonstration that the plugin's gap hint degrades with kernel
#                   fraction: it would have covered only 98.14% here.
#   sb2G          : shared_buffers=2GB against a 14 GB database -- 7x overcommit,
#                   so the working set cannot be cache-resident
#   wm64M         : work_mem=64MB (stock 4MB would spill every join/sort to disk
#                   and make this an I/O study rather than a memory one)
#   nopar         : max_parallel_workers_per_gather=0 -- ONE execution process.
#                   Deliberate deviation, the researcher's call: real analytics
#                   would use parallel query. Matches the 1t corpus convention.
N=postgres16.15_tpch_sf10_q21_sb2G_wm64M_nopar_1t_ubu24.04_qemu9.2.4tcg_1B_w$k
F=$W/traces/pg_q21/$N.filt.raw.zst
C=$W/out/$N.champsim2.zst
mkdir -p "$W/out" "$W/logs"
[ -s "$IN" ] || { echo "MISSING $IN"; exit 1; }
[ -e "$C" ] && { echo "$C exists - STOP"; exit 1; }
"$M/tracer/rpoint-cs/plugin/trace_filter" "$IN" "$F" || { echo "FILTER FAIL $N"; exit 1; }
"$M/tracer/rpoint-cs/converter/raw2champsim" "$F" "$C" 2>&1 | tee "$W/logs/$N.convert.log"
conv=${PIPESTATUS[0]}
grep -qE 'Decode failures: +0$' "$W/logs/$N.convert.log"; dec=$?
"$M/tools/trace_sanity_check/trace_sanity_check" -i "$C" -f v2 --check >/dev/null 2>&1; chk=$?
ins=$("$M/tools/trace_sanity_check/trace_sanity_check" -i "$C" -f v2 2>/dev/null | awk '/total instructions/{print $NF}')
if [ "$conv" -eq 0 ] && [ "$dec" -eq 0 ] && [ "$chk" -eq 0 ] && [ "${ins:-0}" -gt 600000000 ]; then
  rm -f "$F"; echo "OK $N ($ins insns)"
else
  echo "FAIL $N (conv=$conv decode=$dec check=$chk insns=${ins:-0}) - raw KEPT"
fi
