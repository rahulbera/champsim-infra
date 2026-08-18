# scripts/smoke-trace/

## Goal

A **two-minute, self-contained end-to-end check** that the x86-64 pipeline is
still correct: plugin → raw v3 → converter → ChampSim v2 records → acceptance
invariants.

It boots a throwaway kernel + busybox initramfs running one branchy static
workload. Nothing is installed into a guest, no disk image is touched, and no
state persists. This exists to answer *"is the pipeline still correct?"* — not
to produce research traces. For those, use `../capture-kit/` (AArch64
collaborators) or `../boot_tcg_trace.sh` (full VM under TCG).

## Run it

```bash
make -C ../../plugin plugin CC=gcc     # note CC=gcc — see below
make -C ../../converter CC=gcc
./smoke_trace.sh [outdir]
```

Default outdir is `$TMPDIR/champsim-smoke-x86`. A full run takes a couple of
minutes and ends with the acceptance-check table.

## Env overrides

| Variable | Default | Purpose |
|---|---|---|
| `QEMU` | `~/qemu-custom/bin/qemu-system-x86_64` | must be **9.2.4**, built `--enable-plugins`, **system-emulation** (the plugin refuses to load under linux-user) |
| `PLUGIN` | `../../plugin/champsim_tracer.so` | |
| `CONVERTER` | `../../converter/raw2champsim` | |
| `SANITY` | auto-discovered at `../../../champsim-infra/tools/trace_sanity_check/` | skipped cleanly if absent |
| `LIMIT` | `30000000` | instructions traced |
| `WORK_ITERS` | `600000000` | workload iterations — **see below** |
| `KERNEL` | downloaded via `apt-get download` | any x86-64 bzImage works |

## Two things that will bite you

**1. `WORK_ITERS` must keep the workload running past the arming point.**

The script uses deferred tracing (`trigger=`) to skip ~4 B instructions of
kernel boot — without it, the trace is BIOS and early boot running in 16- and
32-bit modes, which the 64-bit decoder cannot decode (5.8% decode failures).

But **the plugin polls for the trigger only while instructions are retiring.**
If the guest finishes before the script arms it, the polls stop and the run ends
with `Trigger was never activated` — indistinguishable from a bad path. The
workload is sized (600 M iterations ≈ 60 s under TCG) so the trigger, armed 3 s
after the workload banner, lands comfortably inside it. Lower `WORK_ITERS` too
far and the check fails for that reason and no other.

Diagnose with a `-DTRIGGER_DEBUG` plugin build — see `../../plugin/README.md`.

**2. `CC=gcc` is not optional on a conda-active host.**

`CC` resolves to `aarch64-conda-linux-gnu-cc`, so a plain `make` builds for the
wrong architecture and dies on `zstd.h: No such file or directory` — the
cross-compiler's sysroot, not a missing zstd.

## Files

| File | Purpose |
|---|---|
| `smoke_trace.sh` | the driver: build initramfs → boot + capture → convert → validate |
| `work.c` | the workload — data-dependent conditionals, indirect calls through a function-pointer table, and recursive `fib()`, so the trace exercises every branch class the converter emits. Iteration count from `-DWORK_ITERS`. |

## What "pass" looks like

```
[PASS] explicit branch type on every record
[PASS] branch type spans multiple values
[PASS] conditional taken rate strictly in (0,100)
[PASS] unconditional transfers are 100% taken
[PASS] calls and returns have is_branch=1
[PASS] flags register present on both sides
```

The load-bearing ones are **conditional taken rate strictly inside (0,100)** — a
class pinned at 0% or 100% means direction is being fabricated — and **calls
balancing returns**, which cannot hold by accident.

Background on what these check and why: `../../docs/branch-type-contract.md`.
