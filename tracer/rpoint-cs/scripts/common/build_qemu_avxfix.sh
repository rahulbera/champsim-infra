#!/bin/bash
set -eu
DST=$W/qemu-avxfix
PFX=$W/qemu-custom-avxfix
LOG=$W/logs
mkdir -p "$DST/build" "$LOG"
cd "$DST/build"
echo "=== configure $(date -u +%FT%TZ) ==="
../configure --target-list=x86_64-softmmu --enable-plugins --enable-kvm \
             --disable-docs --disable-werror --prefix="$PFX"
echo "=== build $(date -u +%FT%TZ) (-j$(nproc)) ==="
"$HOME/local/bin/ninja" -j"$(nproc)"
echo "=== done $(date -u +%FT%TZ) ==="
ls -l "$DST/build/qemu-system-x86_64"
