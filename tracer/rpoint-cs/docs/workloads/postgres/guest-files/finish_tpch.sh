#!/bin/bash
set -u
D=/home/ubuntu/tpch-kit/dbgen
{
date -u "+%H:%M:%SZ keys+analyze start"
# dss.ri is the TPC-H reference-integrity script (PKs + FKs). It needs the schema
# name set; run it against the tpch db directly.
sudo -u postgres psql -q -d tpch -v ON_ERROR_STOP=0 -f $D/dss.ri 2>&1 | grep -viE "^$|NOTICE" | tail -5
date -u "+%H:%M:%SZ keys done"
sudo -u postgres psql -q -d tpch -c "ANALYZE" 2>&1 | tail -2
date -u "+%H:%M:%SZ analyze done"
echo "--- sizes ---"
sudo -u postgres psql -tAd tpch -c "select relname, pg_size_pretty(pg_total_relation_size(c.oid)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' order by pg_total_relation_size(c.oid) desc"
echo "--- database total ---"
sudo -u postgres psql -tAd tpch -c "select pg_size_pretty(pg_database_size('tpch'))"
} >> /home/ubuntu/finish_tpch.log 2>&1
