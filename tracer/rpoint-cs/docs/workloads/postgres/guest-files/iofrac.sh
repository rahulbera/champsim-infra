#!/bin/bash
# Measure the I/O-wait fraction of each TPC-H query WITHOUT track_io_timing.
#
# Why not track_io_timing: this guest has no TSC clocksource (only hpet/acpi_pm,
# a consequence of kvmclock=off which we need for KVM->TCG snapshot restore).
# pg_test_timing measures 7270 ns per call. PostgreSQL makes two per block read,
# so Q18 (~20M reads) would pay ~290 s of instrumentation on a 51 s query --
# the measurement would be dominated by the act of measuring.
#
# Instead: the guest is otherwise idle, so system-wide CPU accounting across the
# query IS the query. Two /proc/stat samples, negligible overhead.
#   busy%   = (user+nice+sys) / (wall * ncpu)   -- how much of the run was compute
#   iowait% = iowait          / (wall * ncpu)   -- how much was blocked on disk
set -u
HZ=$(getconf CLK_TCK); NC=$(nproc)
snap() { awk '/^cpu /{print $2+$3+$4, $5, $6}' /proc/stat; }
{
printf "%-5s %10s %9s %9s %9s\n" QUERY WALL_s BUSY_pct IOWAIT_pct IDLE_pct
for q in 1 6 9 18 21; do
  Q=$(cat /home/ubuntu/queries/q$q.sql)
  sudo -u postgres psql -q -d tpch -c "$Q" >/dev/null 2>&1   # warm
  read b0 i0 w0 <<< "$(snap)"; t0=$(date +%s.%N)
  sudo -u postgres psql -q -d tpch -c "$Q" >/dev/null 2>&1
  t1=$(date +%s.%N); read b1 i1 w1 <<< "$(snap)"
  awk -v q="$q" -v b=$((b1-b0)) -v idl=$((i1-i0)) -v io=$((w1-w0)) \
      -v t0=$t0 -v t1=$t1 -v hz=$HZ -v nc=$NC 'BEGIN{
        wall=t1-t0; tot=wall*hz*nc;
        printf "Q%-4s %10.2f %8.1f%% %8.1f%% %8.1f%%\n", q, wall, 100*b/tot, 100*io/tot, 100*idl/tot }'
done
} >> /home/ubuntu/iofrac.log 2>&1
