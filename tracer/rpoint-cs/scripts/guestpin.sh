#!/bin/bash
# Report the pinned state of a guest JVM, resolving the pid by /proc/PID/exe.
#   guestpin.sh <ssh-port> [jar-pattern]
# Default pattern matches BOTH benchmark harnesses in this campaign. The first
# version hardcoded the DaCapo jar and reported "NO JVM" for a perfectly healthy
# Spark run -- a monitor that manufactures a failure, which is the failure mode
# that costs trust. Pass a pattern for anything else.
PORT=${1:?usage: guestpin.sh <ssh-port> [jar-pattern]}
PAT=${2:-'dacapo-23.11-MR2-chopin.jar|renaissance-mit'}
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"
timeout 100 ssh -n $SSHOPT -p "$PORT" ubuntu@127.0.0.1 "
J=\$(for p in \$(pgrep -f '$PAT'); do readlink /proc/\$p/exe 2>/dev/null | grep -q java && echo \$p; done | head -1)
[ -n \"\$J\" ] || { echo 'NO JVM matching: $PAT'; exit 1; }
echo \"pid=\$J mask=\$(taskset -p \$J|grep -oE '[0-9a-f]+\$') threads=\$(ls /proc/\$J/task|wc -l) unpinned=\$(for t in /proc/\$J/task/*; do tid=\${t##*/}; taskset -p \$tid 2>/dev/null|grep -oE '[0-9a-f]+\$'; done|grep -vc '^2\$')\"
" 2>&1 | grep -vi '^warning'
