#!/usr/bin/env bash
# run_prod_read95_zipf.sh
#
# Production read95-zipfian RocksDB trace collection.
#
#   Workload : RocksDB, 5M records x 1KB, 95% reads, 5% writes
#   Skew     : Zipfian alpha = 0.99 (FNV-scrambled)
#   Threads  : 4 foreground workers, pinned to cores 0..3
#   Cache    : 8 GB block cache + OS page cache (pre-warmed via fadvise)
#   Warmup   : 10 minutes untraced steady-state queries before ROI
#   Sampling : 1 B insts/sample x 3 samples/thread, 2 B inter-sample skip
#
# Output:
#   traces/<TAG>/<TAG>_t<tid>_s{0,1,2}.champsim2.zst   (4 workers, kept)
#   traces/<TAG>/<TAG>_t<tid>_master_s0.champsim2.zst  (discard)
#   traces/<TAG>/<TAG>_t<tid>_s*.champsim2.zst         (RocksDB internal threads,
#                                                       filter via worker_tids.txt)
#   traces/<TAG>/run.log
#   <DBDIR>/worker_tids.txt
#
# Wall-clock budget: ~75 min worst case. Workers exit at the deadline
# (warmup_secs + roi_secs); driver returns from main; destructor runs at
# near-native speed because PIN instrumentation is removed at ROI end.

set -euo pipefail

# Always run from the script's directory so relative paths
# (./rocksdb_driver, traces/) resolve correctly regardless of caller CWD.
cd "$(dirname "$(readlink -f "$0")")"

PIN=${PIN:-/home/rahbera/softwares/pin-external-4.0-99633-g5ca9893f2-gcc-linux/pin}
TRACER=${TRACER:-/home/rahbera/arishem/champsim/tracer/obj-intel64/champsim_tracer_mt_roi_v2.so}
DRIVER=./rocksdb_driver

TAG=rocksdb_read95_zipf0.99_4t_1B-3s-200M
TRACE_DIR=traces/${TAG}
DBDIR=/mnt/sherlock/rahbera/workloadzoo/rocksdb-data/${TAG}
LOG=${TRACE_DIR}/run.log

NUM_RECORDS=5000000
TRACE_INSTS=1000000000        # 1 B per sample
NUM_SAMPLES=3                 # 3 samples per thread
INTER_SKIP=200000000          # 200 M insts inter-sample skip
                              # (chose small after observing PIN's INTER_SKIP
                              # path runs at <1 M insts/sec/thread for our
                              # workload, making 2 B impractical in any
                              # reasonable wall-clock budget)
WARMUP_SECS=600               # 10 min untraced warmup
ROI_SECS=3600                 # 60 min wall-clock budget for ROI window
CACHE_GB=8

mkdir -p "$TRACE_DIR"

# Output base for the tracer: directory + tag prefix so every trace file
# starts with the descriptive tag.
TRACE_BASE="${TRACE_DIR}/${TAG}"

echo "TAG          : $TAG"
echo "TRACE_DIR    : $TRACE_DIR"
echo "DBDIR        : $DBDIR"
echo "Tracer       : $TRACER"
echo "Sampling     : ${TRACE_INSTS} insts/sample x ${NUM_SAMPLES} samples, inter-skip=${INTER_SKIP}"
echo "Warmup       : ${WARMUP_SECS}s"
echo "ROI window   : ${ROI_SECS}s"
echo "Block cache  : ${CACHE_GB} GB"
echo

"$PIN" -t "$TRACER" \
    -use_markers 1 \
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
echo "----- output files -----"
ls -lh "${TRACE_BASE}"_t*.champsim2.zst 2>/dev/null || echo "no trace files produced"
echo
echo "----- worker tids -----"
cat "$DBDIR/worker_tids.txt" 2>/dev/null || true
