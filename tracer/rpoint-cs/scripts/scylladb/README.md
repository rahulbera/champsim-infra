# scripts/scylladb/

The earliest scripts in this tree, and the only ones that produced **no traces in
the current catalogue**. Kept as the origin of the pipeline's shape.

| file | what it does |
|---|---|
| `boot_scylla_kvm.sh` | fresh `ubuntu-guest.qcow2` under KVM |
| `restore_scylla_kvm.sh` | restore a snapshot under KVM |
| `boot_tcg_trace.sh` | restore under TCG with the tracing plugin attached |

They differ from everything else here in two ways, both worth noticing before
copying anything out of them:

- **`IMGDIR="$HOME/qemu-tracing/images"`**, not the `IMAGES` from `common/cpustr.sh`.
  These predate that convention and were written on a different host.
- **7 vCPUs, shard-per-core** — vCPU 0 for OS/bootstrap (untraced), 1-4 for ScyllaDB
  shards, 5-6 for the client. Every later workload traces a *single* pinned vCPU
  instead, which is the convention the whole catalogue follows (`1t` in every
  trace name).

`boot_scylla_kvm.sh` was called `boot_kvm.sh` until 2026-09-07, which collided with
an unrelated RocksDB script of the same name in the working directory — see
`../README.md`.
