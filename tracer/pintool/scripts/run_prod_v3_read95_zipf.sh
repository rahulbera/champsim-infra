#!/usr/bin/env bash
# run_prod_v3_read95_zipf.sh
#
# Production read95-zipfian RocksDB trace collection with the v3 tracer.
#
#   Workload : RocksDB, 5M records x 1KB, 95% reads, 5% writes
#   Skew     : Zipfian alpha = 0.99 (FNV-scrambled)
#   Threads  : 4 foreground workers, pinned to cores 0..3
#   Cache    : 8 GB block cache + OS page cache (pre-warmed via fadvise)
#   Warmup   : 10 minutes untraced steady-state queries before ROI
#   Sampling : 1 B insts/sample x 3 samples/thread, 500 M inter-sample skip
#
#   Tracer   : champsim_tracer_mt_roi_v3.so
#              -skip_master_tracing 1            (master is orchestrator)
#              -trace_only_registered_workers 1  (RocksDB pthread-pool
#                                                 threads excluded from
#                                                 active_tracing_threads)
#
# Output:
#   traces/<TAG>/<TAG>_t<tid>_s{0,1,2}.champsim2.zst   (4 workers, kept)
#   traces/<TAG>/run.log
#   <DBDIR>/worker_tids.txt
#
# Wall-clock budget:
#   Pre-ROI               ~ 90 s
#   Untraced warmup       600 s
#   Traced ROI            up to 2700 s (45 min); typical ~15 min
#   Destructor (native)   a few s

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

PIN=${PIN:-/home/rahbera/softwares/pin-external-4.0-99633-g5ca9893f2-gcc-linux/pin}
TRACER=${TRACER:-/home/rahbera/arishem/champsim/tracer/obj-intel64/champsim_tracer_mt_roi_v3.so}
DRIVER=./rocksdb_driver

TAG=rocksdb_read95_zipf0.99_4t_1B-3s-500M
TRACE_DIR=traces/${TAG}
DBDIR=/mnt/sherlock/rahbera/workloadzoo/rocksdb-data/${TAG}
LOG=${TRACE_DIR}/run.log

NUM_RECORDS=5000000
TRACE_INSTS=1000000000        # 1 B per sample
NUM_SAMPLES=3                 # 3 samples per thread
INTER_SKIP=500000000          # 500 M insts inter-sample skip
WARMUP_SECS=600               # 10 min untraced warmup
ROI_SECS=2700                 # 45 min wall-clock budget for traced window
                              # (estimated need: ~15 min for 3 x 1B traced
                              # plus 2 x 500M inter-skip; 3x margin)
CACHE_GB=8

mkdir -p "$TRACE_DIR"
TRACE_BASE="${TRACE_DIR}/${TAG}"

echo "TAG          : $TAG"
echo "TRACE_DIR    : $TRACE_DIR"
echo "DBDIR        : $DBDIR"
echo "Tracer       : $TRACER"
echo "Sampling     : ${TRACE_INSTS} insts/sample x ${NUM_SAMPLES} samples, inter-skip=${INTER_SKIP}"
echo "Warmup       : ${WARMUP_SECS}s"
echo "ROI window   : ${ROI_SECS}s"
echo "Block cache  : ${CACHE_GB} GB"
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
       -v 1024 \
       -r 95 -a 0.99 \
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
grep -E "sample [0-9] (complete|->)|registered|orchestrator" "$LOG"
echo
echo "===== THREAD FINAL PHASES (workers only) ====="
WORKERS=$(awk 'NR>2 {print $1}' "$DBDIR/worker_tids.txt" 2>/dev/null)
for w in $WORKERS; do
  grep "Thread fini: OS tid=$w " "$LOG"
done
echo
echo "===== WORKER TIDS (sidecar) ====="
cat "$DBDIR/worker_tids.txt" 2>/dev/null
