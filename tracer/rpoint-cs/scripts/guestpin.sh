#!/bin/bash
# Report the pinned state of the DaCapo JVM in a guest, resolving the pid by
# /proc/PID/exe. `pgrep -f dacapo | head -1` returns a bash WRAPPER (mask f) and
# misreports the pin as lost -- that is the logged trap, and it caught me in a
# poll command at 01:41Z even though the pin was fine.
PORT=${1:?usage: guestpin.sh <ssh-port>}
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"
timeout 100 ssh -n $SSHOPT -p "$PORT" ubuntu@127.0.0.1 '
J=$(for p in $(pgrep -f "dacapo-23.11-MR2-chopin.jar"); do readlink /proc/$p/exe 2>/dev/null | grep -q java && echo $p; done | head -1)
[ -n "$J" ] || { echo "NO JVM"; exit 1; }
echo "pid=$J mask=$(taskset -p $J|grep -oE "[0-9a-f]+$") threads=$(ls /proc/$J/task|wc -l) unpinned=$(for t in /proc/$J/task/*; do tid=${t##*/}; taskset -p $tid 2>/dev/null|grep -oE "[0-9a-f]+$"; done|grep -vc "^2$")"
' 2>&1 | grep -vi '^warning'
