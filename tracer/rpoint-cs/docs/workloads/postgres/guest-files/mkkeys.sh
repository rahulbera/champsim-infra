#!/bin/bash
{ date -u "+%H:%M:%SZ keys start"
  sudo -u postgres psql -q -d tpch -v ON_ERROR_STOP=1 -f /home/ubuntu/tpch_keys.sql 2>&1 | tail -3
  echo "rc=$?"
  date -u "+%H:%M:%SZ keys done, analyzing"
  sudo -u postgres psql -q -d tpch -c "ANALYZE" 2>&1 | tail -1
  date -u "+%H:%M:%SZ analyze done"
  sudo -u postgres psql -tAd tpch -c "select count(*) from pg_indexes where schemaname='public'" 
  sudo -u postgres psql -tAd tpch -c "select pg_size_pretty(pg_database_size('tpch'))"
} >> /home/ubuntu/mkkeys.log 2>&1
