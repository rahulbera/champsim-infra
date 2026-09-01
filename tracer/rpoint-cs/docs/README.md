# docs/

## Goal

All prose documentation for the QEMU-based ChampSim trace generation
pipeline lives here. Two flavors, split into subdirectories:

- **`pipeline/`** — pipeline-wide references. These describe the tracing
  infrastructure itself: what QEMU flags to use, what the raw trace
  format looks like, how to work around the kvmclock snapshot
  incompatibility, and how to strip TCG idle-loop noise. If you are new
  to the project, start here.
- **`workloads/`** — per-workload playbooks and design specs. Each
  document walks you through setting up one target workload (Memcached,
  ScyllaDB, **SWE-agent**, RocksDB, FAISS, DLRM) and producing traces
  from it. `workloads/swe-agent/` exists **only on the
  `swe-agent-tracing` branch** and is the one workload that cannot
  simply be re-run — it splits into a record pass against a live LLM API
  and deterministic offline replays from the recorded cassettes.
- **`validation/`** — how to check that a produced trace is actually
  usable, rather than merely well-formed.
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
| `workloads/` | Per-workload playbooks (Memcached, ScyllaDB, SWE-agent, RocksDB, FAISS, DLRM) |
| `workloads/swe-agent/` | The LLM-coding-agent capture campaign: the plan, the results, and the SPEC comparison (`swe-agent-tracing` branch only) |
| `validation/` | Checking a produced trace is usable, not just well-formed |
| `superpowers/` | Dated design specs, plans and research notes. **Historical** — several carry SUPERSEDED banners; never read one as current behavior |
| `branch-type-contract.md` | Explicit branch type: contract, x86-64 reference, verification, **AArch64 gap** |

See each subdirectory's README for the file-by-file breakdown.

## Note on workloads and tracer choice

Not every document in `workloads/` uses the QEMU pipeline that this
repo implements. Some target workloads are better served by Intel PIN
(standalone C++ programs with no significant kernel-mode work — FAISS,
DLRM, RocksDB) and use the PIN tracer in `tracer/pintool/`.
The relevant workload doc says which tracer to use up front. The
`workloads/README.md` also lists this mapping explicitly.
