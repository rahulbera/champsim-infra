# common/lib.sh — path resolution for every script in this tree.
#
# WHY THIS EXISTS: during the capture campaigns these scripts lived flat in the
# working directory ($HOME/work/new-tracing) and referred to each other by
# absolute path ($W/launch_tcg_pg.sh, $HOME/work/new-tracing/cpustr.sh, ...).
# The committed copies inherited those references, so the repo could not run
# itself: deleting the working directory broke 26 scripts, and cpustr.sh -- which
# carries the load-bearing CPUSTR string -- was not committed at all.
#
# Every script now resolves its own location and finds the rest of the tree from
# there, so the checkout is self-contained and relocatable.
#
# Callers do:
#     SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     SROOT="$SDIR"; while [ ! -d "$SROOT/common" ] && [ "$SROOT" != / ]; do SROOT="$(dirname "$SROOT")"; done
#     . "$SROOT/common/lib.sh"
#
# and then have:
#     SROOT   scripts/            (this tree's root)
#     COMMON  scripts/common/
#     RPCS    tracer/rpoint-cs/   (plugin/, converter/ live here)
#     INFRA    champsim-infra/     (tools/ lives here)
# NOTE: this is INFRA, not REPO, on purpose. smoke-trace/smoke_trace.sh defines
# its own $REPO meaning tracer/rpoint-cs -- one level BELOW champsim-infra. That
# subdirectory is deliberately self-contained and does not source this file, but
# if it ever did, a shared $REPO would silently resolve $REPO/plugin to the wrong
# place. Different name, no collision.
#
#     W       the DATA root -- traces, logs, run/, out/, images/.
#             Overridable: export W=/some/other/scratch before invoking.
#
# The SROOT walk is depth-independent on purpose: a script can move between
# scripts/postgres/ and scripts/dacapo/tomcat/ without its references breaking.

COMMON="$SROOT/common"
RPCS="$(cd "$SROOT/.." && pwd)"
INFRA="$(cd "$SROOT/../../.." && pwd)"

# Data root. NOT derived from the script location: traces and logs are working
# data that deliberately live outside the repo.
W="${W:-$HOME/work/new-tracing}"

# CPUSTR / QEMU_FIXED / IMAGES / MON
. "$COMMON/cpustr.sh"
