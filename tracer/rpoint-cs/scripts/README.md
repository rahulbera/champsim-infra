# scripts/

## Goal

Everything you run **on the host** to move a workload through the tracing
pipeline. Two layers:

- **The QEMU launchers** — the three ways you invoke QEMU here: boot fresh
  under KVM, restore a snapshot under KVM, and restore a snapshot under TCG
  *with the tracing plugin attached*. These are the whole story for a
  hand-driven workload such as Memcached or ScyllaDB.
- **The agentic capture orchestration** — provisioning, the unattended
  phase chain, the record watchdog, the non-agentic control, a status
  dashboard and disk reclamation. An agentic capture is many phases across
  many instances, so it is driven rather than typed.

What is NOT here: anything that runs the finished traces through ChampSim.
That is an experiment on the traces rather than part of producing them, and
it lives in `run-assets/` (see `run-assets/PROVENANCE.md`).

This directory also holds these self-contained subdirectories:
`capture-kit/` for AArch64 collaborators, and `smoke-trace/`, a
two-minute end-to-end correctness check of the x86-64 pipeline
(plugin → raw → converter → acceptance invariants) that boots a
throwaway kernel + initramfs rather than a VM image. See their entries
under Files below and the note at the end of this section.

> **Tracing an SWE agent?** The three launchers below are the ScyllaDB-era
> snapshot flow. The agentic workload has its own driver,
> **`capture_agentic.sh`**, plus the guest-side passes in `swe-agent/`. Start
> at `swe-agent/README.md`; the launchers here are used only indirectly
> (`boot_build.sh` / `boot_tcg_trace.sh` under `images/`).

## How this fits into the repo

These scripts are what you actually run on the host to move a workload
through the pipeline:

```
scripts/boot_kvm.sh          →  fresh guest VM under KVM (setup, install workload)
                                     │
                                     ▼   (savevm from QEMU monitor)
                                 snapshot named e.g. "scylla_run"
                                     │
        ┌────────────────────────────┴─────────────────────────────┐
        ▼                                                          ▼
scripts/restore_kvm.sh <ckpt>                         scripts/boot_tcg_trace.sh <limit> <ckpt>
    (KVM, fast — verify workload)                        (TCG + plugin, the actual tracing run)
                                                              │
                                                              ▼
                                                    plugin writes .raw.zst
```

All three scripts share a common set of QEMU flags (CPU model,
disable-kvm-features, port forwards, monitor/QMP sockets) so snapshots
taken under `boot_kvm.sh` load cleanly under either `restore_kvm.sh`
or `boot_tcg_trace.sh`.

## Files

### `boot_kvm.sh`

Boots the guest VM under KVM from scratch (no `-loadvm`). Use this
when setting up a new workload, installing packages, or reaching a
warm state you plan to snapshot.

Layout (7 vCPUs — ScyllaDB style):
- vCPU 0: OS / bootstrap (not traced)
- vCPUs 1–4: ScyllaDB shards (traced under TCG)
- vCPUs 5–6: benchmark client + OS housekeeping (not traced)

QEMU CPU model: `Haswell` with a long list of KVM-specific features
disabled (`kvmclock=off`, `kvm-asyncpf=off`, etc.). This is
intentional — features that only KVM implements would leave TCG
unable to restore the snapshot. Read `docs/pipeline/kvmclock-patch-details.md`
for why kvmclock in particular is worth its own document.

Port forwards: `2222→22` (SSH), `9042→9042` (CQL / ScyllaDB).

Monitor: telnet `127.0.0.1:4444`. QMP: TCP `127.0.0.1:4445`.

Usage:

```bash
./boot_kvm.sh
```

No arguments. Take snapshots from the QEMU monitor (`savevm <name>`).

### `restore_kvm.sh`

Loads a named snapshot under KVM. Same QEMU flags as `boot_kvm.sh`;
adds `-loadvm $1`. Use this to sanity-check that a snapshot is intact
before spending hours running it under TCG.

Usage:

```bash
./restore_kvm.sh scylla_run
```

### `boot_tcg_trace.sh`

**The actual tracing run.** Loads a snapshot under TCG multi-threaded
mode, attaches `plugin/champsim_tracer.so`, and writes per-vCPU
`.raw.zst` files under `~/qemu-tracing/traces/`. Uses the
plugin's `trigger=/tmp/trace_start` mode — tracing does not begin
until the file appears on the host, letting you defer the start of
tracing until the workload reaches steady state inside the (slow)
TCG-restored VM.

Layout: same 7-vCPU model, `-cpu Haswell` (with `hle/rtm/pcid/invpcid/tsc-deadline` off for TCG compatibility).

Cleans previous traces in `~/qemu-tracing/traces/` before starting.

Usage:

```bash
# Signature: ./boot_tcg_trace.sh [instruction_limit_per_vcpu] [checkpoint_name]

./boot_tcg_trace.sh 1000000 scylla_run     # 1 M insns per vCPU (smoke test)
./boot_tcg_trace.sh 200000000 scylla_run   # 200 M insns per vCPU (production)
./boot_tcg_trace.sh 0 scylla_run           # unlimited (until VM shutdown)
./boot_tcg_trace.sh                        # defaults: 1 M, no checkpoint (won't work)
```

To actually start tracing after the VM has settled:

```bash
touch /tmp/trace_start
```

The plugin polls once every 10 M instructions across all vCPUs
(≈once per wall-clock second under TCG). Traces land at
`~/qemu-tracing/traces/trace_vcpu<N>.raw.zst`.

### `capture_agentic.sh`

**Host-side driver for one agentic capture**, in five phases:

```bash
LLM_API_KEY=… ./capture_agentic.sh <instance_id> record    # real LLM, spends credits
                ./capture_agentic.sh <instance_id> verify  # offline replay, 0 misses
                ./capture_agentic.sh <instance_id> profile # size the trajectory
                ./capture_agentic.sh <instance_id> trace   # 4 x 300M windows
                ./capture_agentic.sh <instance_id> convert # -> ChampSim v2 + validate
```

`record` snapshots the guest to `<inst>.recorded.qcow2`, but **every later phase
restores the PROVISIONED image**, not that snapshot (`restore_from_provisioned`
in `capture_agentic.sh`; `verify`, `profile` and `trace` all call it). The
cassettes and the trajectory are pulled out of the recorded guest onto the host
and re-injected into the restored guest instead.

That is deliberate, and it is the difference between a valid measurement and a
meaningless one. The recording began from the provisioned state — a fully built
tree. Restoring the *recorded* image would start each measured run from a guest
whose repository the agent had already modified: the build outputs, the edited
files and the harness state from the record pass would all still be there, so
the replayed agent would redo its work against a tree that already contains the
answer. The actions would be identical (they are replayed from cassettes, not
derived from observations), so `compare_trajectories.py` could not see it, while
the amount of computation traced — the entire measurement — would be wrong.
Starting from the same disk state the recording started from is the only thing
that makes the numbers mean anything.

`restore_from_recorded()` is still defined in `capture_agentic.sh` but **nothing
calls it** — it is dead code left from the earlier design, not an alternate path.

Geometry defaults to `WINDOWS=4`, `WINDOW_LEN=300000000` — 300 M matches the
SPEC SimPoint slice length in `champsim-infra`, so agentic-vs-SPEC comparisons
are at identical geometry. `sample_gap` is computed from the measured user-mode
total as `(user − K·N)/(K−1)`, which is the formula the plugin itself prints.

Three things it refuses to let pass silently:

- **The trigger must have armed.** The plugin starts dormant, so an unarmed
  trigger yields a confident profile of *nothing*.
- **The chunk count must equal the window count.**
- **Every window must pass `trace_sanity_check --check`.** Validation is a gate,
  not a report; the load-bearing invariant is the conditional taken rate being
  strictly inside (0, 100)%.

`convert` needs `libcapstone.so.4` on `LD_LIBRARY_PATH` (the converter links it
for the AArch64 decoder); it defaults to `/home/rbera/local/lib`.

### The agentic capture orchestration

`capture_agentic.sh` above is one phase of one instance. These sequence it
across phases and across instances, unattended.

#### `provision_instance.sh`

HOST side: bring a fresh guest to the state the record pass expects, and
snapshot it. Boots the cloud image under KVM with the cloud-init seed, waits
for cloud-init, then **reboots** — `isolcpus` only takes effect on the next
boot — before snapshotting.

#### `run_capture_chain.sh`

Unattended `verify -> profile -> trace -> convert`, stopping at the FIRST
failure rather than carrying a bad artifact forward. One log per phase. Each
phase already has its own gate; this only sequences them.

**The optional second argument is the first phase to run**, and it defaults to
`verify` (`FIRST=${2:-verify}`). The loop walks `verify profile trace convert`
and starts executing at whichever phase matches, so:

```bash
./run_capture_chain.sh <instance_id>           # verify -> profile -> trace -> convert
./run_capture_chain.sh <instance_id> profile   # profile -> trace -> convert
./run_capture_chain.sh <instance_id> convert   # convert only
```

That default is load-bearing rather than cosmetic. It was `profile` at one
point, which meant a bare invocation skipped `verify` — the only gate that
catches a replay diverging from its recording — and then spent hours of TCG
faithfully tracing the wrong execution. Verify costs 2–5.5 minutes under KVM.

`advance_instance.sh` runs `verify` itself, under KVM and outside the TCG slot
semaphore, and then calls `run_capture_chain.sh <inst> profile` explicitly, so
the verify pass is not run twice.

The `record` phase is deliberately outside the chain: it spends API credits and
should be an explicit act. Simulation is outside it too — running traces
through ChampSim is an experiment *on* them, not part of producing them, and
that tooling lives in `run-assets/`.

#### `advance_instance.sh`

Carries one instance from a finished record pass all the way through: waits for
the record pass to report success, pulls the cassettes and trajectory out of
the guest, then hands off to the chain.

#### `record_watchdog.sh`

Stops a record pass that has stopped making progress. Recording has no natural
bound here — the cost limits are disabled (litellm has no pricing for this
model) and the execution timeouts are disabled — so without this a wedged pass
runs indefinitely on real credits.

#### `capture_toolchain.sh`

HOST driver for the **non-agentic control**: same guest, same commit, same
pinned vCPU, same tracer, same 4x300M geometry as the agentic capture — only
the payload differs. `swe-agent/toolchain_only.sh` runs the build and test
suite without the agent, which is what makes the control a control.

#### `capture_status.sh`

One-screen view of every capture in flight: per-instance phase, validated
window count, cassettes recorded, guest liveness, and the non-agentic controls.

#### `reclaim_space.sh`

Frees disk from finished captures. **Dry-run by default** — nothing is deleted
without `--apply`, because a wrong deletion here costs a multi-hour TCG
re-trace or an API-credit re-record, not a re-download.

### `swe-agent/`

The guest-side capture passes (provision / record / replay), the record-replay
LLM proxy, and the per-instance and per-language descriptors that parameterise
them. See `swe-agent/README.md`.

### `capture-kit/`

A self-contained subdirectory, not a single launcher script — the
capture kit for an **AArch64 collaborator** capturing raw v3 traces on
their own (AArch64) host, where this project's x86-specific
`boot_kvm.sh`/`restore_kvm.sh`/`boot_tcg_trace.sh` don't apply. It
holds `probe_guest.sh` (collects guest facts), `configure_tracer.sh`
(turns those facts plus host facts into a ready-to-run
`run_trace.sh` and a `trace_metadata.txt` provenance sidecar), and its
own `README.md` — read that file, not this one, for the full flow.

**The one guest-side exception to "scripts/ is host-side":**
`probe_guest.sh` is the single script in this directory meant to run
*inside* the guest VM, not on the host — everything else here,
including the rest of the capture kit, runs on the host. See
`plugin/README.md` for the v3 raw format and knob semantics the kit
configures on the collaborator's behalf.

### `smoke-trace/`

Also a subdirectory rather than a launcher: a **two-minute end-to-end
correctness check** of the x86-64 pipeline — plugin → raw v3 →
converter → ChampSim v2 → acceptance invariants. It boots a throwaway
kernel + busybox initramfs running one branchy static workload, so it
needs no VM image, installs nothing into a guest, and leaves no state.

Use it after touching `plugin/champsim_tracer.c`, `converter/decode_x86.c`
or `converter/raw2champsim.c`, and before trusting a batch of traces:

```bash
make -C ../plugin plugin CC=gcc && make -C ../converter CC=gcc
./smoke-trace/smoke_trace.sh
```

It is *not* a way to produce research traces — that is what the three
launchers above and `capture-kit/` are for. Read
`smoke-trace/README.md` for the env knobs and the two failure modes
that are easy to misread (`WORK_ITERS` too small makes a working
trigger look broken; a conda `CC` builds the plugin for the wrong
architecture).

## How to use

Full pipeline flow — pick up the pieces you need:

```bash
# --- One-time setup: bring up a fresh VM and install the workload. ---
cd scripts/
./boot_kvm.sh
#   (inside the VM: install workload, load data, warm up)
#   (from QEMU monitor on 127.0.0.1:4444: savevm scylla_run)

# --- Later: verify snapshot loads cleanly under KVM. ---
./restore_kvm.sh scylla_run
#   (inside the VM: confirm workload responds normally)
#   quit QEMU

# --- The tracing run: same snapshot under TCG with the plugin. ---
./boot_tcg_trace.sh 200000000 scylla_run
#   (inside the guest — via SSH on port 2222 — wait for workload steady state)
#   (from another host shell:)
touch /tmp/trace_start
#   (QEMU exits when the per-vCPU instruction limit is reached, then:)
ls -lh ~/qemu-tracing/traces/
```

Then hand off to `plugin/trace_inspector` (validate), optionally
`plugin/trace_filter` (strip idle-loop noise), and finally
`converter/raw2champsim` (produce the ChampSim v2 file).

## Notes on scripts vs docs/pipeline/boot-commands.md

`docs/pipeline/boot-commands.md` is a hand-typed cheat sheet that
predates these scripts and reflects the older 5-vCPU Memcached
layout. When something in the two disagrees, **the scripts are
authoritative** — they're what actually gets executed. The doc is
kept because it's a useful compact reference and shows the deferred-
tracing pattern (`trigger=/tmp/trace_start`) explicitly.
