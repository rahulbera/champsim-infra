#!/bin/bash
# Screen TPC-H queries on MEASURED behaviour, not planner cost.
# Two runs each: the first is cold-ish, the second is what we care about since
# the capture snapshots a warm server. EXPLAIN (ANALYZE, BUFFERS) gives shared
# block hits vs reads -- the direct evidence of whether the query is actually
# touching memory beyond shared_buffers.
set -u
{
for q in 1 6 9 18 21; do
  Q=$(cat /home/ubuntu/queries/q$q.sql)
  sudo -u postgres psql -q -d tpch -c "$Q" > /dev/null 2>&1        # warm
  out=$(sudo -u postgres psql -tAd tpch -c "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT TEXT) $Q" 2>&1)
  ms=$(printf "%s" "$out" | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+")
  hit=$(printf "%s" "$out" | grep -oE "shared hit=[0-9]+" | awk -F= "{s+=\$2} END {print s+0}")
  rd=$(printf "%s"  "$out" | grep -oE "read=[0-9]+"       | awk -F= "{s+=\$2} END {print s+0}")
  tmp=$(printf "%s" "$out" | grep -oE "temp read=[0-9]+"  | awk -F= "{s+=\$2} END {print s+0}")
  nodes=$(printf "%s" "$out" | grep -cE "Hash Join|Merge Join|Nested Loop|Seq Scan|Sort|HashAggregate")
  printf "Q%-3s exec=%9s ms  shared_hit=%-10s read=%-9s temp_read=%-8s plannodes=%s\n" \
         "$q" "${ms:-?}" "$hit" "$rd" "$tmp" "$nodes"
done
} >> /home/ubuntu/screen_tpch.log 2>&1
