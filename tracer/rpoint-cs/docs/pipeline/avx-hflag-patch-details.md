# AVX hflag Patch — Technical Reference

> **The second QEMU patch this pipeline needs.** `kvmclock-patch-details.md`
> made a KVM-taken snapshot *loadable* under TCG; this one makes the guest
> *survive* being loaded. Both are required. A QEMU without both cannot run
> Stage 4.
>
> **Discovered** 2026-09-04, during the Memcached v2 re-capture, on
> `rnadig` with QEMU 9.2.4. Line numbers below are QEMU 9.2.4 and were
> verified in `~/softwares/qemu-9.2.4/` on that host.

## Problem Statement

A snapshot taken under **KVM** and restored under **TCG** resumes with **AVX
disabled**, even though the guest's CPU model advertises AVX and the guest's
own view of `CR4.OSXSAVE` and `XCR0` is correct. Every VEX-encoded instruction
then raises `#UD`.

Modern userspace hits this immediately: glibc resolves its string and memory
functions through IFUNCs **at process start**, and a process started under KVM
on a Haswell-class model has already committed to the AVX2 implementations. On
resume those instructions no longer decode.

**This stops Stage 4 outright.** It is not a tracing problem — the plugin is
not involved, and it happens with no plugin loaded at all.

## Symptom

```
[ 3379.xxxxxx] Kernel panic - not syncing: Attempted to kill init!
               exitcode=0x0000008b
               Comm: systemd  PID: 1
```

`exitcode=0x8b` is `SIGSEGV|0x80` — a segfault with a core dumped. The visible
faulting instruction is a `-fstack-clash-protection` probe:

```
sub $0x1000,%rsp
orq $0,(%rsp)          <-- SIGSEGV here
```

**That instruction is a red herring.** It is merely the last one before an 8 MB
stack ran out. See *Failure Chain* below.

Secondary tell, easy to miss in the console spew:

```
Process 6208 (apport) has RLIMIT_CORE set to 1 / Aborting core
```

`apport` being spawned means **other** processes were faulting too. The failure
is system-wide within ~0.5 s of resume, not one bad program.

## How We Found It

Recorded because the diagnosis path is reusable, and because three plausible
hypotheses were wrong. Each step is a control, and each ruled something out:

| # | Test | Result | Ruled out |
|---|---|---|---|
| 0 | Restore under TCG with **no plugin** | panics identically — same RIP, same registers | the tracing plugin |
| 1 | Restore under TCG with v1's `-cpu` string (no `pmu=on`, no `kvm-*`) | panics identically | the CPU model string, and `pmu=on` |
| 2 | Restore under KVM instead | **clean** — uptime matches `vm_clock`, ssh works, store intact | the snapshot itself; it is sound |
| 3 | `-accel tcg,thread=single` | panics identically | MTTCG |
| 4 | Paused restore (`-S`), register diff TCG vs KVM, all vCPUs | **identical** except the accessed-bit encoding of unusable `ES/DS/FS/GS` (`00c00000` vs `00c00100`), cosmetic in 64-bit mode. `RIP/RSP/CR0/CR2/CR3/CR4/EFER/GDT/IDT/TR/FPU/YMM` all match | vmstate loading; the divergence is in **execution after resume** |
| 5 | `-d int` interrupt log | 1,509 `#UD` (`v=06`) at `cpl=3`; 942 at one address | — the mechanism |

Step 5 is what cracked it. Mapping the faulting addresses through
`/proc/1/maps` on a **KVM** restore of the same snapshot:

```
libc.so.6 +0x18ae24   vmovd   %esi,%xmm0        <-- 942 of the 1509
libc.so.6 +0x188a8d   vmovdqu (%rsi),%ymm0
          +0x189484, +0x18b014, +0x18b7c9, +0x18d674
```

All VEX-encoded, all inside glibc's AVX2 IFUNC region. The SIGILL handler is
`libsystemd-shared-255.so +0x167c38`.

### Failure Chain

```
KVM snapshot restored under TCG
        |
        v  HF_AVX_EN_MASK absent from the migrated hflags
   every VEX instruction -> #UD
        |
        v  glibc's AVX2 ifuncs were chosen at process start, under KVM
   SIGILL delivered to a handler that itself runs AVX2 code
        |
        v  1838 nested signal frames, SP falling 0x22C0 each
   0x7fff4e3e2128 -> 0x7fff4dbe42a8  ==  exactly 8 MB  ==  RLIMIT_STACK
        |
        v
   SIGSEGV on the stack-probe -> init dies -> kernel panic, ~12 s after resume
```

The 8 MB figure matching `RLIMIT_STACK` exactly is what confirms recursion
rather than corruption.

## Root Cause

`HF_AVX_EN_MASK` (bit 28 of `env->hflags`, `target/i386/cpu.h:174,201`) is the
TCG decoder's cached answer to "is AVX usable right now" — derived from
`CR4.OSXSAVE` and `XCR0`. The decoder consults it and nothing else:

```c
/* target/i386/tcg/decode-new.c.inc:2419 (also :2455, :2462) */
if (!(s->flags & HF_AVX_EN_MASK)) {
    goto illegal_op;                 /* -> #UD */
}
```

It is recomputed by exactly one function:

```c
/* target/i386/helper.c:35 */
void cpu_sync_avx_hflag(CPUX86State *env)
{
    if ((env->cr[4] & CR4_OSXSAVE_MASK)
        && (env->xcr0 & (XSTATE_SSE_MASK | XSTATE_YMM_MASK))
            == (XSTATE_SSE_MASK | XSTATE_YMM_MASK)) {
        env->hflags |= HF_AVX_EN_MASK;
    } else {
        env->hflags &= ~HF_AVX_EN_MASK;
    }
}
```

**And it has exactly two callers, both on TCG-only write paths:**

| Caller | Location | Enclosing function |
|---|---|---|
| `CR4` write | `target/i386/helper.c:234` | `cpu_x86_update_cr4()` (`:182`) |
| `XSETBV` | `target/i386/tcg/fpu_helper.c:3205` | `helper_xsetbv()` (`:3170`) |

Under KVM the **hardware** performs those writes. QEMU's software emulation of
them never runs, so `env->hflags` never gains the bit — harmlessly, because
under KVM nothing reads it.

Then the snapshot is written. `hflags` is migrated **verbatim**:

```
target/i386/machine.c:1664   VMSTATE_UINT32(env.hflags, X86CPU)
```

and `cpu_post_load()` (`machine.c:313`) repairs only `HF_CPL_MASK`, never the
AVX bit. So the bit that was meaningless under KVM arrives, still clear, in a
TCG guest where it *is* meaningful.

**The inputs needed to recompute it are already in the snapshot**, which is why
the fix is trivial and needs no re-capture:

```
target/i386/machine.c:1686   VMSTATE_UINTTL(env.cr[4], X86CPU)
target/i386/machine.c:1742   VMSTATE_UINT64_V(env.xcr0, X86CPU, 12)
```

`env->xcr0` is read back from KVM by `kvm_get_xcrs()`
(`target/i386/kvm/kvm.c:4241`, called at `:5381`), so it is populated and
correct on the save side.

## Why It Is Intermittent — And Why That Matters

**v1's own snapshot (`memcached_rd95`, 2026-04-25) restores under TCG without
panicking**, verified on a throwaway copy: no panic, `systemd` alive, `sshd`
answering. v1 captured 24 traces through this same path and never noticed.

That is not evidence the bug is absent. `cpu_sync_avx_hflag()` runs on the next
`CR4` write or `XSETBV` **under TCG** — so a restored guest that happens to
reach a context switch restoring `XCR0` before it executes its first VEX
instruction repairs itself silently. It is a race between recovery and the
first AVX instruction, decided by whatever the guest was doing when `savevm`
ran.

> **Do not treat "it worked last time" as a fix.** A configuration that merely
> wins the race is not a basis for a capture campaign, and a trace produced by
> one is not reproducible. Patch the QEMU.

## The Patch

One line, plus the comment explaining why it is there, in `cpu_post_load()`:

```diff
--- a/target/i386/machine.c
+++ b/target/i386/machine.c
@@ -354,6 +354,16 @@ static int cpu_post_load(void *opaque, int version_id)
     env->hflags &= ~HF_CPL_MASK;
     env->hflags |= (env->segs[R_SS].flags >> DESC_DPL_SHIFT) & HF_CPL_MASK;
 
+    /*
+     * hflags is migrated verbatim, but HF_AVX_EN_MASK is only ever set by the
+     * TCG-side writers of CR4 (cpu_x86_update_cr4) and XCR0 (helper_xsetbv).
+     * A snapshot taken under KVM therefore carries hflags WITHOUT that bit --
+     * hardware performed those writes, not QEMU -- so restoring it under TCG
+     * leaves AVX disabled and every VEX-encoded instruction raises #UD.
+     * cr[4] and xcr0 are both migrated, so just recompute the bit here.
+     */
+    cpu_sync_avx_hflag(env);
+
 #ifdef CONFIG_KVM
     if ((env->hflags & HF_GUEST_MASK) &&
```

It is placed beside the existing `HF_CPL_MASK` repair because it is the same
kind of thing: a derived `hflags` field that migration cannot carry correctly
and `cpu_post_load()` must reconstruct. `cpu_sync_avx_hflag()` is already
declared in `target/i386/cpu.h:2437`, so no header change is needed, and it is
compiled unconditionally — not behind `CONFIG_TCG`.

**Direction of effect.** The patch can only ever *set* a bit that the migrated
state says should be set. On a TCG→TCG restore the bit is already correct and
the call is a no-op; under KVM the field is unread. It cannot enable AVX for a
guest whose `CR4`/`XCR0` do not permit it.

## Building It

Built into an **isolated tree** so the existing install and source stay
byte-identical — the v1 pipeline depends on them:

```bash
SRC=~/softwares/qemu-9.2.4
DST=$MCROOT/qemu-avxfix                 # source copy, excluding the old build dir
tar -C "$SRC" --exclude=./build -cf - . | tar -C "$DST" -xf -
# apply the diff above to $DST/target/i386/machine.c
mkdir -p "$DST/build" && cd "$DST/build"
../configure --target-list=x86_64-softmmu --enable-kvm --enable-plugins \
             --enable-slirp --prefix=$MCROOT/qemu-custom-avxfix \
             --disable-docs --disable-werror
ninja -j"$(nproc)"
# -> $DST/build/qemu-system-x86_64        (NOT installed; used in place)
```

The configure line is the original one, recovered from
`~/softwares/qemu-9.2.4/build/config.status`. Keep it identical: `--enable-plugins`
is what makes the tracer loadable at all, and `--enable-kvm` is needed because the
same binary takes the Stage-2 snapshot.

Reproducible driver: `$MCROOT/patch_qemu.sh` on `rnadig`.

## Verifying It

Three checks, in order. The third is the one that matters.

```bash
# 1. the fix is in the isolated tree and ONLY there
grep -c cpu_sync_avx_hflag $DST/target/i386/machine.c        # 1
grep -c cpu_sync_avx_hflag $SRC/target/i386/machine.c        # 0

# 2. the originals are untouched
md5sum ~/qemu-custom/bin/qemu-system-x86_64 $SRC/build/qemu-system-x86_64
#   both c4b30d08941b3620bde7ba8affa9c694   (patched binary: 4c610020646adb52c023b1341b390881)

# 3. a KVM-taken snapshot actually survives a TCG restore -- NO PLUGIN,
#    so a failure cannot be blamed on the tracer
$DST/build/qemu-system-x86_64 -accel tcg,thread=multi -cpu "$CPUSTR" \
    -smp 7 -m 12G -drive file=<image>,format=qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2288-:22 \
    -nographic -serial mon:stdio -loadvm <tag>
# PASS: guest reachable over ssh within ~60 s and `uptime` matches the
#       snapshot's vm_clock. FAIL: "Attempted to kill init" within ~12 s.
```

Result on 2026-09-04: guest alive at ~40 s, `up 56 min` against a snapshot
`vm_clock` of `00:56:07` — it resumed the real saved state, and no `#UD`.

## Operational Impact

**Every QEMU invocation in Stage 2 and Stage 4 must use the patched binary.**
On `rnadig` it is exported as `$QEMU_FIXED` in `~/.mcrc`. The unpatched
`~/qemu-custom/bin/qemu-system-x86_64` is kept only so v1 artifacts remain
reproducible; do not use it for new captures.

There is no change to snapshot format, plugin ABI, trace format, or capture
procedure. A snapshot taken before the patch — such as `mc_v2_a` — restores
correctly under the patched binary with **no need to re-capture it**, because
the fix reconstructs the bit from `cr[4]` and `xcr0`, which that snapshot
already carries.

## Upstream Status

Not yet reported. It is a genuine upstream bug, not a local misconfiguration:
any KVM-sourced snapshot restored under TCG loses AVX, and whether the guest
survives depends on what it executes next. Reporting it should quote
`cpu_post_load()` in `target/i386/machine.c` and the two TCG-only callers of
`cpu_sync_avx_hflag()`.

The same reasoning may apply to other derived `hflags` bits that only TCG write
paths maintain — this document does not claim to have audited them.

## Safety Assessment

| Risk | Assessment |
|---|---|
| Corrupting an existing snapshot | None. The patch runs on load and writes only `env->hflags` in memory. |
| Breaking the v1 pipeline | None. `~/qemu-custom` and `~/softwares/qemu-9.2.4` are byte-identical to before; verified by md5. |
| Wrongly enabling AVX | Not possible. The bit is computed from the guest's own migrated `CR4`/`XCR0`. |
| TCG→TCG restores | No-op; the bit is already correct. |
| Needing a re-capture | No. `cr[4]` and `xcr0` are in every snapshot at version ≥ 12. |

## See Also

- `kvmclock-patch-details.md` — the other QEMU patch this path requires.
- `docs/workloads/memcached/memcached-recapture-runbook.md` §4 — the restore
  pattern that must use `$QEMU_FIXED`.
- `docs/verification/2026-09-04-memcached-rocksdb-capture-audit.md` — the audit
  this campaign came out of.
