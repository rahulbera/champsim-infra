# slots.sh -- CAPTURE_SLOT resolution and validation.
#
# A slot fixes this capture's ssh forwards (KVM 2300+SLOT*10, TCG 2301+SLOT*10),
# its plugin trigger file, its profile output directory and its QEMU pidfile.
# Two captures on one slot therefore collide.
#
# The old derivation had two silent failure modes:
#
#   1. A MISSING CAPTURE_SLOT defaulted to 0 -- silently aliasing the instance
#      onto whichever one owns slot 0 (redis, here).
#   2. A DUPLICATE slot was left to announce itself as a port bind failure,
#      which only happens if the two captures run AT THE SAME TIME. Run them
#      sequentially and nothing complains at all, while the trigger file, the
#      pidfile and the profile output directory are shared -- so a stop_qemu
#      can kill the wrong guest and a profile can be read for the wrong run.
#
# Both were real: rubocop-13668 and rubocop-13680 shipped declaring slot 1.
#
# resolve_slot <instance> <instances_dir>  ->  echoes the slot, or fails loudly.

resolve_slot() {
  local inst=$1 dir=$2 env_file slot dupes

  env_file="$dir/$inst.env"
  [ -f "$env_file" ] || { echo "resolve_slot: no descriptor at $env_file" >&2; return 1; }

  slot=$(grep -h '^CAPTURE_SLOT=' "$env_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]')

  # Absent is an error, not a zero. A capture with no slot is a capture whose
  # ports, trigger file and pidfile belong to somebody else.
  [ -n "$slot" ] || {
    echo "resolve_slot: $inst declares no CAPTURE_SLOT in $env_file" >&2
    echo "  a missing slot used to default to 0 and silently share ports," >&2
    echo "  a trigger file and a pidfile with the slot-0 instance." >&2
    return 1
  }

  case "$slot" in
    ''|*[!0-9]*)
      echo "resolve_slot: $inst has non-numeric CAPTURE_SLOT='$slot'" >&2
      return 1 ;;
  esac

  # Uniqueness across every LIVE descriptor. instances/dropped/ is excluded on
  # purpose: a dropped instance keeps its descriptor for the record and may
  # legitimately reuse the slot of whatever replaced it.
  dupes=$(grep -l "^CAPTURE_SLOT=$slot\$" "$dir"/*.env 2>/dev/null | wc -l)
  if [ "$dupes" -gt 1 ]; then
    echo "resolve_slot: CAPTURE_SLOT=$slot is declared by $dupes live descriptors:" >&2
    grep -l "^CAPTURE_SLOT=$slot\$" "$dir"/*.env 2>/dev/null | sed 's|.*/|    |' >&2
    echo "  slots must be unique -- they fix ports, the trigger file and the pidfile." >&2
    return 1
  fi

  echo "$slot"
}
