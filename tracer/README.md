# tracer/ — the two trace producers

Everything in this repo downstream of here *consumes* `.champsim2.zst` traces;
these two tools *produce* them. They cover disjoint classes of workload:

| Tool | Capture mechanism | Use it when |
|---|---|---|
| [`pintool/`](pintool/README.md) | Intel PIN instrumentation, ROI bracketed by magic-NOP markers | The workload is a normal x86-64 Linux binary you can run under PIN and instrument (add markers, rebuild or LD_PRELOAD). |
| [`rpoint-cs/`](rpoint-cs/README.md) | QEMU guest: snapshot under KVM, replay under TCG with a tracing plugin | The workload cannot be PIN-run — whole-system capture, multi-process pipelines, or LLM-agent sessions replayed from recorded cassettes (see the `swe-agent-tracing` branch). |

Both emit the same v2 record format with explicit branch types
([`rpoint-cs/docs/branch-type-contract.md`](rpoint-cs/docs/branch-type-contract.md));
`reserved[2]` in each record identifies which tracer produced it. Verify any
freshly generated trace with `tools/trace_sanity_check --check` before using it.
