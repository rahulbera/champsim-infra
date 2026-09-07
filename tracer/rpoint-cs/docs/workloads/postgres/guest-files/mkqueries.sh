#!/bin/bash
# Generate TPC-H queries that PostgreSQL will actually parse. The tpch-kit
# templates are written against the TPC reference (DB2 dialect) and need three
# fixes, all of them long-standing and well known:
#   1. ":n" header markers emitted by qgen
#   2. a "limit -1;" footer when the query has no LIMIT -- invalid in PG
#   3. DB2 interval precision, e.g. "interval 90 day (3)" -- the "(3)" is not
#      valid PG syntax
#   4. a ";" terminating the template BEFORE qgen appends "limit N;", which
#      splits one statement into two
cd /home/ubuntu/tpch-kit/dbgen
mkdir -p /home/ubuntu/queries
for q in "$@"; do
  DSS_QUERY=./queries ./qgen -d "$q" 2>/dev/null \
    | sed -e "/^:[a-z0-9]/d" \
          -e "/^limit -1;/d" \
          -e "s/ day ([0-9])/ day/g" \
          -e "/^select/,\$!d" \
    | tr -d ";" > /tmp/q$q.body
  { cat /tmp/q$q.body; echo ";"; } > /home/ubuntu/queries/q$q.sql
done
