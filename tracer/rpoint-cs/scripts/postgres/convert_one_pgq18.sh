#!/bin/bash
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"; M="$INFRA"
k=$1
IN=$W/traces/pg_q18/trace_vcpu1_c$k.raw.zst
# Fields MEASURED, not assumed:
#   postgres16.15 : `select version()` in the guest
#   tpch_sf10     : dbgen -s 10; verified row counts (lineitem 59,986,052 etc)
#   q18           : TPC-H Q18, large volume customer -- a grouped aggregate over
#                   lineitem feeding an IN-subquery, then joined back to orders
#                   and customer. Screened IN on a MEASURED basis: I had wanted
#                   to drop it for its 4.06M temp reads, and perf showed it is
#                   the MOST compute-bound of the four at 87.6% CPU / 2.8%
#                   iowait -- the hash-aggregate spill is absorbed by the OS page
#                   cache (12 GB guest RAM vs a 14 GB database).
#                   Confirmed under TCG at 255.7 MIPS / 93.81% user: the fastest
#                   and most user-pure query in the set (q1 82.50%, q9 71.04%).
#   sb2G          : shared_buffers=2GB against a 14 GB database -- 7x overcommit,
#                   so the working set cannot be cache-resident
#   wm64M         : work_mem=64MB (stock 4MB would spill every join/sort to disk
#                   and make this an I/O study rather than a memory one)
#   nopar         : max_parallel_workers_per_gather=0 -- ONE execution process.
#                   Deliberate deviation, the researcher's call: real analytics
#                   would use parallel query. Matches the 1t corpus convention.
N=postgres16.15_tpch_sf10_q18_sb2G_wm64M_nopar_1t_ubu24.04_qemu9.2.4tcg_1B_w$k
F=$W/traces/pg_q18/$N.filt.raw.zst
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
