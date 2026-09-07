#!/bin/bash
# Load TPC-H SF=10 into PostgreSQL.
# dbgen writes a TRAILING | on every line, which COPY reads as a phantom extra
# column. Strip it in the stream via COPY ... FROM PROGRAM rather than rewriting
# 10 GB of .tbl files on disk.
set -u
D=/home/ubuntu/tpch-kit/dbgen
{
date -u "+%H:%M:%SZ load start"
for t in region nation supplier customer part partsupp orders lineitem; do
  s=$(date +%s)
  sudo -u postgres psql -q -d tpch -c "\copy $t from program 'sed -e s/\|\$// $D/$t.tbl' with (format csv, delimiter '|', quote e'\b')"
  rc=$?
  n=$(sudo -u postgres psql -tAd tpch -c "select count(*) from $t")
  printf "%-10s rc=%d rows=%-10s %4ds\n" "$t" "$rc" "$n" "$(( $(date +%s) - s ))"
done
date -u "+%H:%M:%SZ load done"
} >> /home/ubuntu/load_tpch.log 2>&1
