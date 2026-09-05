#!/usr/bin/env bash
# run_prod_v3_n20M_chain_zipf06.sh
#
# Run rd95 first, then rd50, sequentially, for n=20M / zipf alpha=0.6.
# Same structure as run_prod_v3_n20M_chain.sh (the zipf=0.8 chain).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CHAIN_LOG=traces/chain_n20M_zipf06.log
mkdir -p traces

{
  echo "=========================================="
  echo "CHAIN START : $(date -Iseconds)"
  echo "=========================================="

  echo
  echo ">>> [1/2] rd95-zipf0.6-n20M starting at $(date -Iseconds)"
  ./run_prod_v3_n20M_rd95_zipf06.sh
  RD95_RC=$?
  echo ">>> [1/2] rd95 finished at $(date -Iseconds) rc=$RD95_RC"

  echo
  echo ">>> [2/2] rd50-zipf0.6-n20M starting at $(date -Iseconds)"
  ./run_prod_v3_n20M_rd50_zipf06.sh
  RD50_RC=$?
  echo ">>> [2/2] rd50 finished at $(date -Iseconds) rc=$RD50_RC"

  echo
  echo "=========================================="
  echo "CHAIN END   : $(date -Iseconds)"
  echo "  rd95 rc   : $RD95_RC"
  echo "  rd50 rc   : $RD50_RC"
  echo "=========================================="
} 2>&1 | tee -a "$CHAIN_LOG"
