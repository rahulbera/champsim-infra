#!/usr/bin/env bash
#
# smoke_trace.sh -- end-to-end x86-64 validation of the full pipeline:
#
#   QEMU 9.2.4 (x86_64-softmmu, TCG) + champsim_tracer.so
#     -> raw v3 trace
#     -> converter/raw2champsim (Zydis x86 backend)
#     -> ChampSim v2 records with explicit branch type
#     -> trace_sanity_check --check   (acceptance invariants)
#
# Unlike scripts/capture-kit (which drives a full VM disk image), this boots a
# throwaway kernel + busybox initramfs with a single static, branchy workload.
# Nothing persists, nothing is installed into a guest, and a full run takes a
# couple of minutes -- it exists to answer "is the pipeline still correct?",
# not to produce research traces.
#
# Usage: scripts/smoke-trace/smoke_trace.sh [outdir]
#
# Env overrides (all optional):
#   QEMU        qemu-system-x86_64 built for x86_64-softmmu with --enable-plugins
#               (default: ~/qemu-custom/bin/qemu-system-x86_64)
#   PLUGIN      path to champsim_tracer.so   (default: <repo>/plugin/...)
#   CONVERTER   path to raw2champsim         (default: <repo>/converter/...)
#   SANITY      path to trace_sanity_check   (optional; skipped if absent)
#   LIMIT       instructions to trace        (default: 30000000)
#   WORK_ITERS  workload iterations          (default: 600000000, ~60s)
#   KERNEL      bzImage to boot. If unset the script downloads the running
#               distro's kernel package with `apt-get download` (no install).
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/champsim-smoke-x86}"

QEMU="${QEMU:-$HOME/qemu-custom/bin/qemu-system-x86_64}"
PLUGIN="${PLUGIN:-$REPO/plugin/champsim_tracer.so}"
CONVERTER="${CONVERTER:-$REPO/converter/raw2champsim}"
SANITY="${SANITY:-}"
LIMIT="${LIMIT:-30000000}"
WORK_ITERS="${WORK_ITERS:-600000000}"

# The trigger file must be somewhere the QEMU process can see. It is deleted
# by the plugin at startup (to clear stale triggers) and again when detected.
TRIGGER="$OUT/trace_start"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$QEMU" ]      || die "no qemu-system-x86_64 at $QEMU (set QEMU=)"
[ -f "$PLUGIN" ]    || die "no plugin at $PLUGIN -- build it: make -C $REPO/plugin plugin"
[ -x "$CONVERTER" ] || die "no converter at $CONVERTER -- build it: make -C $REPO/converter"
command -v busybox >/dev/null || die "busybox not found (apt install busybox-static)"
command -v cpio    >/dev/null || die "cpio not found (apt install cpio)"

mkdir -p "$OUT"/{root/bin,traces}
cd "$OUT"

# ── guest kernel ────────────────────────────────────────────────────────────
# Any x86-64 bzImage works. Downloading the running kernel's package is just
# the least-surprising way to get one without building a kernel.
if [ -z "${KERNEL:-}" ]; then
  if [ ! -f "$OUT/vmlinuz" ]; then
    say "fetching a guest kernel (download only, nothing is installed)"
    ( cd "$OUT" && apt-get download "linux-image-$(uname -r)" >/dev/null 2>&1 ) \
      || die "could not download linux-image-$(uname -r); set KERNEL=/path/to/bzImage"
    dpkg-deb -x "$OUT"/linux-image-*.deb "$OUT/extract"
    cp "$OUT/extract/boot/vmlinuz-$(uname -r)" "$OUT/vmlinuz"
  fi
  KERNEL="$OUT/vmlinuz"
fi
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"

# ── guest userspace ─────────────────────────────────────────────────────────
say "building initramfs (busybox + static workload, ${WORK_ITERS} iterations)"
cp "$(command -v busybox)" root/bin/busybox
gcc -O1 -static -DWORK_ITERS="${WORK_ITERS}L" \
    -o root/bin/work "$REPO/scripts/smoke-trace/work.c"

cat > root/init <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc 2>/dev/null
echo "GUEST: starting workload"
/bin/work
echo "GUEST: workload done"
/bin/busybox poweroff -f
INIT
chmod +x root/init
( cd root && find . | cpio -o -H newc 2>/dev/null | gzip -9 > ../initramfs.gz )

# ── capture ─────────────────────────────────────────────────────────────────
# Deferred tracing: the plugin stays dormant until TRIGGER appears, so the
# ~4B instructions of kernel boot are skipped and the trace is the workload.
#
# The plugin only polls while instructions are retiring. If the guest finishes
# before the trigger is armed, the checks simply stop and the run ends with
# "Trigger was never activated" -- which looks exactly like a bad path. That is
# why WORK_ITERS must keep the workload running past the arming point below.
# (Build the plugin with -DTRIGGER_DEBUG to log each poll with a timestamp.)
say "booting guest and capturing $LIMIT instructions"
rm -f "$TRIGGER" boot.log; rm -f traces/*
"$QEMU" -accel tcg -cpu qemu64 -smp 1 -m 1G \
  -kernel "$KERNEL" -initrd initramfs.gz \
  -append "console=ttyS0 quiet" -nographic -no-reboot \
  -plugin "$PLUGIN,outdir=$OUT/traces,vcpus=0,limit=$LIMIT,trigger=$TRIGGER" \
  > boot.log 2>&1 &
QPID=$!

for _ in $(seq 1 300); do
  grep -q "GUEST: starting workload" boot.log 2>/dev/null && break
  kill -0 $QPID 2>/dev/null || die "QEMU exited before the workload started (see $OUT/boot.log)"
  sleep 1
done
sleep 3                                   # get past the workload's prologue
touch "$TRIGGER"
for _ in $(seq 1 30); do
  grep -q "TRIGGER DETECTED" boot.log 2>/dev/null && break
  kill -0 $QPID 2>/dev/null || break
  sleep 1
done
grep -q "TRIGGER DETECTED" boot.log 2>/dev/null \
  || die "trigger never fired -- workload likely too short; raise WORK_ITERS (see $OUT/boot.log)"
wait $QPID 2>/dev/null || true

RAW="$OUT/traces/trace_vcpu0.raw.zst"
[ -s "$RAW" ] || die "no raw trace produced"
grep -a "insns," boot.log || true

# ── convert ─────────────────────────────────────────────────────────────────
say "converting to ChampSim v2"
"$CONVERTER" "$RAW" "$OUT/smoke.champsim2.zst" | tail -14

# ── validate ────────────────────────────────────────────────────────────────
# trace_sanity_check lives in the champsim-infra repo; skip cleanly if absent.
if [ -z "$SANITY" ]; then
  # Plain `if`, not a `&&` chain: under `set -e` a failing chain would abort
  # the script here instead of falling through to the skip message below.
  for c in "$REPO/../champsim-infra/tools/trace_sanity_check/trace_sanity_check"; do
    if [ -x "$c" ]; then SANITY="$c"; break; fi
  done
fi
if [ -n "$SANITY" ] && [ -x "$SANITY" ]; then
  say "acceptance checks"
  "$SANITY" -i "$OUT/smoke.champsim2.zst" -f v2 --check | tail -22
else
  say "trace_sanity_check not found -- skipping acceptance checks"
  echo "  build it: make -C <champsim-infra>/tools/trace_sanity_check"
fi

say "done"
echo "  trace: $OUT/smoke.champsim2.zst"
