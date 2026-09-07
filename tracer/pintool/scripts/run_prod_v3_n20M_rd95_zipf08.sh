#!/usr/bin/env bash
# run_prod_v3_n20M_rd95_zipf08.sh
#
# Production read95-zipfian RocksDB trace collection — larger working set.
# Differences from run_prod_v3_read95_zipf.sh (the earlier 5M / alpha=0.99 run):
#
#   N records       :  5M  ->  20M     (4x more rows)
#   Zipfian alpha   : 0.99 ->  0.8     (less skew, broader hot subset)
#   Block cache GB  :   8  ->   16     (cover ~80% of decompressed DB)
#   Warmup secs     : 600  -> 1200     (bigger DB needs more steady-state time)
#   ROI secs        : 2700 -> 3600     (extra margin; with broader skew, sample
#                                       wall time can be ~10-20% longer per Get)
#
# Same as before: 1 B insts/sample x 3 samples/thread, 500 M inter-sample skip,
# 4 worker threads pinned to cores 0..3, v3 tracer with skip_master_tracing
# and trace_only_registered_workers both ON.
#
# Expected MPKI lift on a Lion-Cove-style 192K/2.5M/3M hierarchy: ~2-3x over
# the 5M / 0.99 baseline (1.6 -> 3-5).

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

PIN=${PIN:-/home/rahbera/softwares/pin-external-4.0-99633-g5ca9893f2-gcc-linux/pin}
TRACER=${TRACER:-/home/rahbera/arishem/champsim/tracer/obj-intel64/champsim_tracer_mt_roi_v3.so}
DRIVER=./rocksdb_driver

TAG=rocksdb_n20M_v1K_rd95_zipf0.8_4t_1B-3s-500M
TRACE_DIR=traces/${TAG}
DBDIR=/mnt/sherlock/rahbera/workloadzoo/rocksdb-data/${TAG}
LOG=${TRACE_DIR}/run.log

NUM_RECORDS=20000000          # 20 M records (4x previous)
VALUE_SIZE=1024               # 1 KB
TRACE_INSTS=1000000000        # 1 B per sample
NUM_SAMPLES=3                 # 3 samples per thread
INTER_SKIP=500000000          # 500 M insts inter-sample skip
WARMUP_SECS=1200              # 20 min untraced warmup (bigger DB needs more)
ROI_SECS=3600                 # 60 min wall-clock budget for ROI window
CACHE_GB=16                   # 16 GB block cache (~80% of 20 GB raw)
READ_PCT=95
ALPHA=0.8

mkdir -p "$TRACE_DIR"
TRACE_BASE="${TRACE_DIR}/${TAG}"

echo "TAG          : $TAG"
echo "TRACE_DIR    : $TRACE_DIR"
echo "DBDIR        : $DBDIR"
echo "Tracer       : $TRACER"
echo "Records      : ${NUM_RECORDS} x ${VALUE_SIZE}B = $((NUM_RECORDS * VALUE_SIZE / 1024 / 1024 / 1024)) GB raw"
echo "Skew         : Zipfian alpha=${ALPHA}"
echo "Sampling     : ${TRACE_INSTS} insts/sample x ${NUM_SAMPLES} samples, inter-skip=${INTER_SKIP}"
echo "Warmup       : ${WARMUP_SECS}s"
echo "ROI window   : ${ROI_SECS}s"
echo "Block cache  : ${CACHE_GB} GB"
echo "Read pct     : ${READ_PCT}%"
echo "Knobs        : -skip_master_tracing 1 -trace_only_registered_workers 1"
echo

"$PIN" -t "$TRACER" \
    -use_markers 1 \
    -skip_master_tracing 1 \
    -trace_only_registered_workers 1 \
    -values 1 \
    -t "$TRACE_INSTS" \
    -n "$NUM_SAMPLES" \
    -s "$INTER_SKIP" \
    -zstd_level 3 \
    -exit_on_done 0 \
    -o "$TRACE_BASE" \
    -- "$DRIVER" \
       -d "$DBDIR" \
       -n "$NUM_RECORDS" \
       -v "$VALUE_SIZE" \
       -r "$READ_PCT" -a "$ALPHA" \
       -t 4 --cpus=0,1,2,3 \
       -c "$CACHE_GB" \
       -s 42 \
       --warmup-secs="$WARMUP_SECS" \
       --roi-secs="$ROI_SECS" \
       --overwrite 2>&1 | tee "$LOG"

echo
echo "===== TRACE FILES ====="
ls -lh "${TRACE_BASE}"_t*.champsim2.zst 2>/dev/null || echo "no files"
echo
echo "===== SAMPLE COMPLETION ====="
grep -E "sample [0-9] (complete|->)|registered|orchestrator|block-cache during ROI" "$LOG"
echo
echo "===== THREAD FINAL PHASES (workers only) ====="
WORKERS=$(awk 'NR>2 {print $1}' "$DBDIR/worker_tids.txt" 2>/dev/null)
for w in $WORKERS; do
  grep "Thread fini: OS tid=$w " "$LOG"
done
echo
echo "===== WORKER TIDS (sidecar) ====="
cat "$DBDIR/worker_tids.txt" 2>/dev/null
