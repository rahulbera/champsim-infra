# docs/

## Goal

All prose documentation for the QEMU-based ChampSim trace generation
pipeline lives here. Two flavors, split into subdirectories:

- **`pipeline/`** — pipeline-wide references. These describe the tracing
  infrastructure itself: what QEMU flags to use, what the raw trace
  format looks like, the **two QEMU patches** the KVM-snapshot ->
  TCG-restore path requires (kvmclock, AVX hflag), and how to strip TCG
  idle-loop noise. If you are new
  to the project, start here.
- **`workloads/`** — per-workload playbooks and design specs. Each
  document walks you through setting up one target workload (Memcached,
  ScyllaDB, RocksDB, FAISS, DLRM) and producing traces from it.
- **`validation/`** — how to check that a produced trace is actually
  usable, rather than merely well-formed.
- **`verification/`** — audits of *completed* capture campaigns: what was
  really run, what the traces really measured, and where the methodology
  failed silently. `validation/` asks whether one trace is healthy;
  `verification/` asks whether the whole approach was sound. **Read the
  audit for a workload before re-running its playbook in `workloads/`.**
- **`branch-type-contract.md`** — the explicit branch-type contract
  (`reserved[0..2]`), the x86-64 classification reference, and the
  x86/AArch64 status split. Read this before trusting the branch fields
  of any trace this repo produces.

## How this fits into the repo

The code in `plugin/`, `converter/`, and `scripts/` implements the
pipeline that these docs describe. Anything in `plugin/README.md`,
`converter/README.md`, or `scripts/README.md` is a *quick reference for
the code in that directory*; documents in `docs/pipeline/` are the
authoritative long-form references — start there when you want the full
"why", not just the "how to run".

## File index

| File / dir | Purpose |
|---|---|
| `pipeline/` | Pipeline-wide references (stages, boot commands, kvmclock patch, idle-loop filtering) |
| `workloads/` | Per-workload playbooks (Memcached, ScyllaDB, RocksDB, FAISS, DLRM) |
| `validation/` | Checking a produced trace is usable, not just well-formed |
| `verification/` | Post-hoc audits of finished campaigns — **why the first Memcached/RocksDB traces did not exercise the memory system** |
| `branch-type-contract.md` | Explicit branch type: contract, x86-64 reference, verification, **AArch64 gap** |

See each subdirectory's README for the file-by-file breakdown.

## Note on workloads and tracer choice

Not every document in `workloads/` uses the QEMU pipeline that this
repo implements. Some target workloads are better served by Intel PIN
(standalone C++ programs with no significant kernel-mode work — FAISS,
DLRM, RocksDB) and use the PIN tracer in `tracer/pintool/`.
The relevant workload doc says which tracer to use up front. The
`workloads/README.md` also lists this mapping explicitly.

For the same reason, `verification/` spans both tracers: the
2026-09-04 audit covers the Memcached (QEMU) and RocksDB (PIN)
campaigns together, because they were one research effort and several
of its findings — the trace-level footprint and skew gaps, the
literature corrections, the simulation-side criteria — apply to any
trace this project produces, whichever tracer made it.
