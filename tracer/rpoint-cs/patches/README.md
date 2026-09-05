# patches/

The two QEMU patches the KVM-snapshot -> TCG-restore path requires, as applyable
diffs against a pristine **QEMU 9.2.4** tree.

`docs/pipeline/kvmclock-patch-details.md` and
`docs/pipeline/avx-hflag-patch-details.md` explain *why* each is needed. These
files are the *what* — until 2026-09-05 both patches existed only as local edits
on one host (`rnadig:~/softwares/qemu-9.2.4`, an unpacked tarball, not a repo),
so a second machine could not reproduce a capture without rediscovering them.

| Patch | Files touched | Symptom without it |
|---|---|---|
| `kvmclock-tcg-restore.patch` | `hw/i386/kvm/clock.c`, `hw/i386/pc_q35.c`, `hw/i386/pc_piix.c` | `loadvm` aborts: `Unknown savevm section or instance 'kvmclock' 0` |
| `avx-hflag-tcg-restore.patch` | `target/i386/machine.c` | guest resumes with AVX disabled; every VEX instruction raises `#UD`, glibc's AVX2 ifuncs SIGILL forever, nested handlers exhaust the 8 MB stack and init dies |

**kvmclock touches three files, not one.** Patching `clock.c` alone is not
enough: `kvmclock_create()` is called from machine init behind
`if (kvm_enabled())` in *both* `pc_q35.c` and `pc_piix.c`, so under TCG the
device would never be created and no VMState handler would be registered.

## Applying

```bash
cd <pristine-qemu-9.2.4>
patch -p1 < .../patches/kvmclock-tcg-restore.patch
patch -p1 < .../patches/avx-hflag-tcg-restore.patch
./configure --target-list=x86_64-softmmu --enable-plugins --enable-kvm \
            --disable-docs --disable-werror --prefix=<prefix>
ninja -C build
```

Build with `libaio-dev` and `liburing-dev` present, or the resulting binary
rejects `aio=native` / `aio=io_uring` at first boot.

Verified 2026-09-05 on minitron: a guest snapshotted under KVM (Haswell model
reporting AVX2) restores under TCG and keeps running — `uptime` matches the
snapshot's VM_CLOCK, no kvmclock error, no `#UD` storm.
