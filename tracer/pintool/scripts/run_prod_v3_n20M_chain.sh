#!/usr/bin/env bash
# run_prod_v3_n20M_chain.sh
#
# Run rd95 first, then rd50, sequentially. Designed to be launched once
# under nohup; total wall time ~2.7 hours.
#
# Output:
#   traces/rocksdb_n20M_v1K_rd95_zipf0.8_4t_1B-3s-500M/run.log
#   traces/rocksdb_n20M_v1K_rd50_zipf0.8_4t_1B-3s-500M/run.log
#   traces/chain.log    -- this wrapper's progress log
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CHAIN_LOG=traces/chain_n20M_zipf08.log
mkdir -p traces

{
  echo "=========================================="
  echo "CHAIN START : $(date -Iseconds)"
  echo "=========================================="

  echo
  echo ">>> [1/2] rd95-zipf0.8-n20M starting at $(date -Iseconds)"
  ./run_prod_v3_n20M_rd95_zipf08.sh
  RD95_RC=$?
  echo ">>> [1/2] rd95 finished at $(date -Iseconds) rc=$RD95_RC"

  echo
  echo ">>> [2/2] rd50-zipf0.8-n20M starting at $(date -Iseconds)"
  ./run_prod_v3_n20M_rd50_zipf08.sh
  RD50_RC=$?
  echo ">>> [2/2] rd50 finished at $(date -Iseconds) rc=$RD50_RC"

  echo
  echo "=========================================="
  echo "CHAIN END   : $(date -Iseconds)"
  echo "  rd95 rc   : $RD95_RC"
  echo "  rd50 rc   : $RD50_RC"
  echo "=========================================="
} 2>&1 | tee -a "$CHAIN_LOG"
