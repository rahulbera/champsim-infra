#!/bin/bash
# Snapshot the warmed query backend, then profile it under TCG on a QUIET machine.
#
# WHY THE SIGSTOP: the 600 s profile is the ONLY time-bounded stage in the
# pipeline. Capture and conversion are instruction- and data-bounded, so
# contention there costs wall-clock and nothing else. The profile is different:
# a contended profile executes fewer instructions in its 600 s, which yields a
# smaller SGAP, which spreads the three windows over a NARROWER slice of the
# query's trajectory. That is not wrong, but it is not comparable to Q1, which
# was profiled on an idle machine at 204.7 MIPS. So we fence the profile by
# pausing the converters rather than by waiting for them to finish.
#
# SIGSTOP is safe HERE and only here: raw2champsim is a plain read/write filter
# with no timers, sockets, guest or monitor. This is NOT a licence to signal
# QEMU -- a capture is still stopped with a monitor `quit`, never a signal.
set -u
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
. "$SROOT/common/lib.sh"
W="${W:-$HOME/work/new-tracing}"
BENCH=${BENCH:?set BENCH}; SNAP=${SNAP:?set SNAP}; SECS=${SECS:-600}
LOG=$W/logs/ren_snap_profile_$BENCH.log
HMP="python3 $COMMON/hmp.py"
PIDS=""
resume() { [ -n "$PIDS" ] && kill -CONT $PIDS 2>/dev/null; echo "$(date -u '+%H:%M:%SZ') converters resumed: $PIDS"; }
{
  date -u '+%H:%M:%SZ savevm '"$SNAP"' (converters left running -- not a measured stage)'
  timeout 1800 $HMP $W/run/monitor-spark.sock "savevm $SNAP" 2>&1 | tail -3
  date -u '+%H:%M:%SZ savevm returned; verifying tag'
  timeout 120 $HMP $W/run/monitor-spark.sock "info snapshots" 2>&1 | tail -8

  PIDS=$(pgrep -f 'converter/raw2champsim' | tr '\n' ' ')
  trap resume EXIT INT TERM
  date -u '+%H:%M:%SZ pausing converters for the measured window: '"$PIDS"
  kill -STOP $PIDS 2>/dev/null
  sleep 2; echo "load now $(cut -d' ' -f1 /proc/loadavg)"

  BENCH=$BENCH SNAP=$SNAP SECS=$SECS bash $SROOT/renaissance/run_ren_profile.sh
  date -u '+%H:%M:%SZ profile driver returned'
  resume; trap - EXIT
  echo "=== profile log tail ==="; tail -12 $W/logs/ren_profile_$BENCH.log
  echo "ALLDONE"
} >> "$LOG" 2>&1
