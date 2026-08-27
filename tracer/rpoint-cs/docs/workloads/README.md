# docs/workloads/

## Goal

Per-workload playbooks and design specs. Each document either walks you
through setting up one target workload and producing traces from it, or
specifies the design for a workload driver so that a collaborator (human
or agent) can implement it end-to-end.

One subdirectory per workload; every file for a workload lives in its own
directory, so a multi-stage playbook stays together and a new workload is
a new directory rather than another prefix convention.

## How this fits into the repo

Once you understand the pipeline (`docs/pipeline/`), pick a workload here
and follow that document. Two kinds of workloads live here, and they
differ in **which tracer they use** — the two producers now sit side by
side under `tracer/` in champsim-infra:

| Tracer | Where | Why | Workloads here |
|---|---|---|---|
| **QEMU TCG** | `tracer/rpoint-cs/` (this directory's repo) | Guest kernel work is on the hot path (network stack, syscalls). PIN would miss it. | Memcached, ScyllaDB, SWE-agent |
| **Intel PIN** | `tracer/pintool/` | Standalone C++ program, mostly user-mode. QEMU's 50–150× slowdown is not worth paying. | FAISS, DLRM, RocksDB |

Paths above are relative to the champsim-infra repo root. `tracer/README.md`
contrasts the two and says which to reach for.

The PIN workloads are documented here because the trace *format* (v2:
512-byte records, memory values, privilege bit) is shared with the QEMU
pipeline — `tracer/pintool/champsim_tracer_mt_roi_v3.cpp` emits the same
512-byte record this repo's `converter/raw2champsim.c` produces. The
workload *drivers* for FAISS/DLRM/RocksDB still live outside the repo, on
`/mnt/sherlock/rahbera/workloadzoo/`.

## Layout

### QEMU-traced workloads

#### `memcached/`

The three-stage Memcached playbook. There is no stage 3 document —
stage 3 is the plugin implementation itself, covered by
`plugin/champsim_tracer.c` and the design notes in `docs/pipeline/`.

- **`memcached-stage1.md`** — setting Memcached up inside the guest:
  host QEMU install, guest OS setup (cloud-init or GUI), guest tuning
  (ASLR off, THP off, swap off), Memcached with thread pinning, YCSB,
  and memtier_benchmark.
- **`memcached-stage2.md`** — identifying the region of interest and
  creating the golden snapshot. The 5-vCPU layout, the
  YCSB-load-only / memtier-run split, snapshot creation and validation,
  and the `roi_ready` / `roi_running` snapshot pair.
- **`memcached-stage4.md`** — restoring under TCG and starting the run,
  using the plugin's deferred-trigger mode so tracing begins when
  `touch /tmp/trace_start` is issued from the host.

#### `scylladb/`

- **`scyllaDB-stage1.md`** — the analogous stage-1 doc for ScyllaDB.
  Introduces the 7-vCPU layout (vCPU 0 bootstrap, vCPUs 1–4 ScyllaDB
  shards, vCPUs 5–6 client + OS) and switches to a named QEMU CPU model
  (`Skylake-Client`) so one snapshot loads under both KVM and TCG.
  Covers ScyllaDB install and tuning inside the guest. The workload
  driver it references, `scylla_bench.c`, is in `tools/scylla_bench/`.

#### `swe-agent/`

**Only on the `swe-agent-tracing` branch** — mainline carries the universal
tool, this campaign is project-specific. Capturing an LLM coding agent is a
different problem from the workloads above: the agent cannot simply be re-run,
because each run samples the model afresh and is therefore a different
workload. So capture splits into record (once, online, against a live API) and
replay (deterministic, offline, from recorded cassettes), and the cassettes in
`../../artifacts/` are the one artifact class nothing regenerates.

- **`swe-agent-tracing-plan.md`** — the original brief. `docs/superpowers/
  specs/2026-08-06-swe-agent-tracing-design.md` is the design derived from it.
- **`swe-agent-capture-results.md`** — results of the first capture,
  `prometheus__prometheus-15142` (SWE-bench Multilingual, Go), including the
  base commit and the per-window breakdown.
- **`agentic-vs-spec.md`** — the rolling record of the multi-language study:
  one section per captured instance, then the head-to-head against SPEC. This
  is where the six-instance / one-per-execution-model set is justified.
- **`spec_baseline.csv`** — the SPEC side of that comparison (TAGE-SC-L 64 KB,
  50 M warmup / 200 M sim), referenced from `agentic-vs-spec.md`.

### PIN-traced workloads (design specs)

These target `tracer/pintool/`, not this repo's QEMU pipeline.

#### `faiss/`

- **`faiss-tracing.md`** — task spec for the FAISS
  vector-similarity-search tracing pipeline: PIN tracer modifications
  for the extended format (memory values), FAISS install, dataset
  download (SIFT-1M, Deep-10M), driver design with a Zipfian query
  distribution, and multi-index-type comparison. Driver at
  `/mnt/sherlock/rahbera/workloadzoo/faiss-driver/`.

#### `dlrm/`

- **`dlrm-tracing-task.md`** — task spec for tracing FBGEMM
  embedding-bag kernels (the DLRM inner loop): Criteo dataset
  preparation, per-table Zipfian-distributed embedding lookups, and
  single-threaded tracing. Same tracer as FAISS. Driver at
  `/mnt/sherlock/rahbera/workloadzoo/dlrm-driver/`.

#### `rocksdb/`

- **`rocksdb-tracing-task.md`** — task spec for tracing RocksDB
  key-value operations with realistic Zipfian access: RocksDB install,
  driver design (load / compact / warmup / disable-auto-compactions /
  ROI), and the multi-threaded PIN tracer. Reuses the Zipfian generator
  from `tools/scylla_bench/scylla_bench.c`. Driver at
  `/mnt/sherlock/rahbera/workloadzoo/rocksdb-driver/`.

## How to use

- **Reproducing an existing workload's traces?** Follow that workload's
  directory from top to bottom. The QEMU workloads carry complete
  step-by-step commands; the PIN specs point at driver source that
  already exists.
- **Adding a new workload?** Decide QEMU or PIN based on the
  kernel-mode share of the workload, make a directory for it, and use
  the closest existing document as a template.
- **Cross-referencing the trace format?** The v2 record layout is
  defined in `plugin/champsim_tracer.c` (raw) and
  `converter/raw2champsim.c` (ChampSim v2 struct); the PIN side emits
  the same record from `tracer/pintool/`. Every workload doc points at
  these.
