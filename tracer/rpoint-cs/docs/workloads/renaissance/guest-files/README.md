# guest-files/ — extracted from the Renaissance guest before it was deleted

`jar-checksums.txt` — sha256 for `renaissance-mit-0.16.1.jar`,
`dacapo-23.11-MR2-chopin.jar` and the DaCapo zip, so the exact artifacts can be
re-obtained. The jars themselves are not committed (419 MB / 6.3 GB).

## The AVX canaries are NOT here

`AvxCanary.java` and `VecCheck.java` live at
**`tracer/rpoint-cs/workloads/dacapo/`**, which is the guest-source layer and had
them first.

They were briefly duplicated here on 2026-09-07: extracting the guest's contents
before deleting its image, I copied them out without checking whether the repo
already had them. It did, byte-identical. The copy was removed rather than left to
diverge.

## What they are

The J1 gate — the check that a JVM with C2-compiled AVX2/FMA code survives a
KVM→TCG restore at all. `AvxCanary` vectorises an FMA loop, prints
`CANARY ready-for-snapshot`, then heartbeats; `VecCheck` compares an
auto-vectorised reduction against a loop-carried scalar one and asserts they agree.

That gate is why the JVM workloads in this corpus exist. A JVM had previously died
on restore, which made "big data frameworks break quickly inside TCG restore" a
standing blocker; the cause was the QEMU AVX hflag bug, fixed by the patch in
`tracer/rpoint-cs/patches/`.
