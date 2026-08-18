# rpoint-cs — QEMU → ChampSim traces

rpoint-cs turns a **real workload running in a QEMU guest** into **ChampSim v2
traces with explicit branch types**. Boot and set up the guest once under KVM
at near-native speed, snapshot it, then restore the snapshot under TCG with the
tracing plugin and convert the instrumented stream offline:

1. **Capture** — `scripts/boot_kvm.sh` / `restore_kvm.sh` prepare the guest and
   snapshot it; `boot_tcg_trace.sh` restores under TCG with `plugin/` attached,
   emitting a raw per-vCPU stream.
2. **Convert** — `converter/` decodes the raw stream to ChampSim v2 records
   carrying an explicit branch type for every branch (see
   [docs/branch-type-contract.md](docs/branch-type-contract.md)), asserted by a
   30-encoding x86 golden unit test.

The name: this is the ChampSim counterpart of
[`rpoint`](../../garfield/gem5-infra/infra/rpoint) in gem5-infra. Both share the
capture-once / replay-many philosophy; rpoint snapshots a KVM guest into gem5
full-system checkpoints (AArch64), rpoint-cs replays a TCG guest into ChampSim
traces (x86-64).

## Layout

| Directory | What it is |
|---|---|
| `plugin/` | The QEMU TCG plugin that emits the raw instrumented stream. |
| `converter/` | Raw stream → ChampSim v2, x86 decode, explicit branch classification, golden tests. |
| `scripts/` | Boot/snapshot/restore drivers, the `capture-kit`, and a `smoke-trace` end-to-end test. |
| `docs/` | Pipeline and validation docs; the branch-type contract; workload notes. |
| `images/`, `snapshots/`, `dump/` | Gitignored bulk: VM disks, guest snapshots, raw traces. |
| `CLAUDE.md` | Full operational detail (guest config, capture runbooks). Predates the subsume — see below. |

## The SWE-agent capture campaign (this branch)

You are on **`swe-agent-tracing`**: mainline's universal tool plus the
project-specific campaign — record-once/replay-many capture of LLM coding
agents, `scripts/capture_agentic.sh` / `capture_toolchain.sh` and the
`swe-agent/` kit, the campaign docs, and under `artifacts/` the recorded LLM
**cassettes** + trajectories that make the replays reproducible — the one
artifact class nothing can regenerate. Record is the only pass that touches
an API key, and the key never reaches disk.

Six SWE-bench instances, one per execution model, four trace windows each,
plus three non-agentic toolchain controls (same repos, agent removed):

| Instance | Language | Execution model |
|---|---|---|
| prometheus-15142 | Go | compiled, interface dispatch |
| gin-3820 | Go | compiled, interface dispatch |
| redis-13115 | C | compiled, direct calls |
| rubocop-13668 | Ruby | MRI bytecode interpreter |
| ripgrep-2576 | Rust | compiled, monomorphised generics |
| immutable-js-2006 | JavaScript | V8 JIT, inline caches |

(`google__gson-2311`, Java, is captured — cassettes in `artifacts/` — but has
not been converted or simulated. prometheus's cassettes are NOT in git
anywhere; locating them is an open item.)

## Provenance

This directory was the standalone repo `rahulbera/qemu-tracing`, subsumed into
champsim-infra on 2026-08-18 by `git subtree add` — the original history, with
its original hashes, is the second parent of the subsume merge commit
(mainline imports the tool at its branch-type era; `swe-agent-tracing`
subtree-merges the remainder). The old repo is archived read-only. Some
in-tree docs (notably `CLAUDE.md`) still carry pre-subsume paths like
`~/qemu-tracing/…`; read them as `rpoint-cs/…`.
