#!/bin/bash
# Run one TPC-H query continuously in a SINGLE backend.
#
# Why a server-side DO loop rather than a shell loop over psql: the CPU pin is
# pid-bound (learned the hard way -- a guest restart loses it), and a shell loop
# spawns a NEW backend per execution, so the pin would be lost every ~35 s and
# `vcpus=1` would trace an unpinned process. A PL/pgSQL LOOP keeps one backend
# for the whole run, which is what makes the pin hold across the snapshot.
#
# The query is wrapped as a subquery under count(*) to force full execution while
# discarding the result rows (4 for Q1, ~175 for Q9, 100 for Q18/Q21 -- the
# aggregate is negligible against 35 s of scan and join work).
set -u
Q=${1:?usage: run_query_loop.sh <qnum>}
BODY=$(sed -e "s/;[[:space:]]*$//" /home/ubuntu/queries/q$Q.sql)
cat > /tmp/loop_q$Q.sql <<SQL
DO \$\$
BEGIN
  LOOP
    PERFORM count(*) FROM ( $BODY ) AS _t;
  END LOOP;
END
\$\$;
SQL
nohup setsid sudo -u postgres psql -q -d tpch -f /tmp/loop_q$Q.sql \
      > /home/ubuntu/qloop_q$Q.log 2>&1 < /dev/null &
echo "Q$Q loop launched"
