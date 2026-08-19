# Design: tracing an SWE-agent workload for ChampSim

**Date:** 2026-08-06
**Status:** approved design, ready for implementation planning
**Source brief:** `docs/workloads/swe-agent-tracing-plan.md`

---

## 1. Goal and hypothesis

Capture ChampSim-format instruction traces of a coding agent doing real work, so
they can be simulated for frontend design-space exploration.

**Hypothesis:** agentic AI workloads stress the processor frontend — branch
prediction, instruction fetch, decode — differently from traditional benchmarks
like SPEC CPU.

The hypothesis is **comparative**, and that shapes the whole design: these traces
must be methodologically comparable to the SPEC traces already captured in
`champsim-infra`, or a measured difference could be an artifact of differing
methodology rather than a property of the workload. Concretely, that fixes the
slice geometry (§6) and the validation gate (§9).

A plausible mechanism worth stating: CPython's interpreter dispatch loop is
close to a worst case for indirect branch prediction, and an agent stacks a
large-I-footprint harness plus constant process spawn on top of it.

## 2. Scope

**In scope.** A repeatable pipeline that produces validated ChampSim v2 traces
of SWE-agent solving **one** SWE-bench Multilingual task end to end (§3.1), plus
the plugin feature and proxy needed to make that possible. Scaling to further
tasks follows once the pipeline is proven.

**Out of scope.** Running the full benchmark; ROI discovery via SimPoint;
AArch64; simulator-side ChampSim configuration; publishing results.

**Explicitly rejected: SimPoint-based region selection.** SimPoint clusters
basic-block vectors to find *recurring* phases. An agent trajectory is not a
loop nest — it is a sequence of *distinct* activities (proxy → harness → `git` →
`pytest`). There is little for SimPoint to cluster, so uniform sampling is the
more honest strategy here, not merely the cheaper one.

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Tasks | **one Prometheus (Go) task first**, end to end, before scaling | prove the pipeline on a single task; see §3.1 |
| Region selection | uniform sampling, no SimPoint | §2 |
| Sample geometry | **4 windows × 300 M instructions** | matches `champsim-infra` SPEC SimPoint slice length ⇒ apples-to-apples |
| Guest vCPUs | 4 | agent isolated on one; others absorb OS work; near-free under MTTCG on a 32-thread host |
| Traced vCPU | vCPU 1 (not 0) | vCPU 0 carries default IRQ/boot duties |
| Trace content | user **+** kernel, idle filtered afterwards | reversible; kernel I-footprint is part of the frontend cost being measured |
| Sampling clock | user-mode instructions only | prevents a window landing inside an idle stretch |
| Agent | SWE-agent + SWE-ReX **Local** backend | full harness I-footprint; no Docker, so tools inherit CPU affinity |
| LLM determinism | local record/replay HTTP proxy | see §4 |
| Orchestration | KVM for build+record, TCG for trace, **no snapshots** | §5 |

### 3.1 Task selection: one Prometheus (Go) task first

**SWE-bench Multilingual contains no Python instances.** It is 300 tasks across
9 languages — C, C++, Go, Java, JavaScript, TypeScript, PHP, Ruby, Rust —
deliberately excluding Python because SWE-bench Verified already covers it. (A
separate, similarly-named *Multi-SWE-bench* from ByteDance does include Python;
they are different datasets.)

The dataset holds **8 Prometheus instances**, all `prometheus/prometheus` (Go):

```
prometheus__prometheus-9248    prometheus__prometheus-10633
prometheus__prometheus-10720   prometheus__prometheus-11859
prometheus__prometheus-12874   prometheus__prometheus-13845
prometheus__prometheus-14861   prometheus__prometheus-15142
```

Go strengthens rather than weakens the experiment. The agent harness remains
Python — CPython's dispatch loop is the indirect-branch-heavy component the
hypothesis targets — while the *tools* become `go build`/`go test`. The Go
compiler is a large Go binary and the test binaries are statically linked, so a
single trace captures a **mixed** frontend workload (interpreter + compiled
toolchain) rather than a pure-interpreter one. That is closer to what a real
agent does, and it makes an all-Python task a natural later contrast rather
than the baseline.

Two consequences for Pass 1, both load-bearing:

* **The Go module cache and toolchain must be fully pre-populated**, because
  replay runs with networking off. A cold `go mod download` mid-replay fails.
* **Go's build cache state is a deliberate choice.** Pre-warming it makes the
  traced run faster but unrepresentative of a first build; leaving it cold
  makes the first `go test` dominate the trace. Whichever is chosen must be
  recorded with the traces, since it materially changes the instruction mix.

## 4. Determinism comes from the recording, not from temperature

The brief proposed `temperature=0` for a deterministic agent flow. **That is not
sufficient.** Cloud providers batch requests across users, so shared-batch
composition can flip an argmax between near-tied tokens and the generation
diverges from there.

This does not break the plan; it relocates where determinism lives. **Once a
trajectory is recorded, replay is exact by construction, at any temperature.**
`temperature=0` is still set, but only so that a future *re-recording* stays
close to the original.

One consequence: spacing samples evenly requires the trajectory's total length,
so a profile pass precedes the capture pass (§6). Two replay passes execute
identical *actions* but not a bit-identical instruction stream — ASLR,
`PYTHONHASHSEED`, and GC timing perturb it. `norandmaps` and `PYTHONHASHSEED=0`
bound the drift to well under a percent, which is far inside the tolerance for
sample spacing.

## 5. Architecture: three passes

```
PASS 1  BUILD    KVM, network on      Ubuntu 24.04 qcow2: SWE-agent + SWE-ReX(local),
                                      replay proxy, 2-3 task repos at base commits
                                      with deps pre-installed, guest tuning applied

PASS 2  RECORD   KVM, network on      proxy in RECORD mode -> GLM 5.2 upstream;
                 (needs API key)      run each task at temperature 0; cassettes and
                                      .traj saved into the image

PASS 3  TRACE    TCG, network OFF     same image; proxy in REPLAY mode; agent pinned
                 plugin attached      to vCPU 1; 4 x 300M windows captured
```

The image that records is byte-identical to the image that replays, so a
cassette miss can only mean genuine agent divergence, never an environment
difference.

### Why no snapshots

The repo's canonical flow is *KVM boot → snapshot at ROI → restore under TCG*,
which exists because Memcached had to load ~6 GB before its ROI. Our pre-ROI
cost is only boot plus agent startup, and boot was measured at **~4 B
instructions (~1–2 min under TCG)**. Paying that per capture run is cheaper than
the alternative, because the snapshot path additionally requires patching QEMU:
our build at `~/work/softwares/qemu-9.2.4` is stock, with `assert(kvm_enabled())`
still at `hw/i386/kvm/clock.c:335`, so it cannot load a KVM snapshot under TCG.

Snapshots remain available as a later optimisation if per-run boot cost becomes
material.

### KVM access on this host: use `sg kvm -c`, not `setfacl`

`/dev/kvm` is `root:kvm 0660` and this user was in neither. Two fixes exist and
only one of them holds:

* `sudo setfacl -m u:$USER:rw /dev/kvm` works **immediately** but is **not
  durable** — systemd-logind's `uaccess` mechanism re-applies device ACLs on
  session changes and silently wipes the manual entry. Observed here: verified
  present, then gone roughly thirty minutes later with no reboot, leaving only
  the `root` and `gdm` entries and a confusing "Permission denied" from QEMU.
* `sudo usermod -aG kvm $USER` *is* durable, but supplementary groups are fixed
  when a login session is created, so an already-running session never sees it.

The fix needing neither a restart nor re-application:

```bash
sg kvm -c '<command>'      # e.g. sg kvm -c /path/to/boot_script.sh
```

`sg` grants a group the user already belongs to per `/etc/group`, so it prompts
for no password. **Every KVM invocation in passes 1 and 2 must be wrapped this
way** unless the shell was created after the `usermod`. Quoting through `sg -c`
is awkward, so put the QEMU command in a script and run the script.

Verified: the guest boots to Ubuntu 24.04.4 / kernel 6.8.0-136 under KVM with
848 lines of serial output — which also confirms the serial channel that the
ROI trigger marker depends on (§8).

### Host prerequisites still missing

`cloud-localds`, `genisoimage`, `mkisofs`, `xorriso` and `mtools` are all
absent, so the cloud-init NoCloud seed image cannot be built without one of:
`sudo apt install cloud-image-utils` (preferred), or serving the seed over
`nocloud-net` from a local HTTP server via QEMU's SMBIOS serial (no root, but
more moving parts). `mkfs.vfat` exists but is useless alone — populating the
filesystem needs `mtools` or a loopback mount.

## 6. Sampling: the new plugin feature

The plugin today has `outdir/vcpus/limit/trigger/arch/capture_pa/values/rotate`.
There is **no periodic sampling** — verified across all branches and history.
`trigger=` is one-shot: it `unlink()`s the file and latches `tracing_enabled`
permanently.

### Knobs

| knob | meaning |
|---|---|
| `sample_len=N` | instructions per window (`0` = feature off; today's behaviour) |
| `sample_gap=M` | instructions skipped between windows |
| `sample_count=K` | stop after K windows (`0` = unlimited) |
| `sample_clock=user\|all` | which instructions advance the counters (**default `user`**) |
| `profile=on` | count only, write nothing, report totals (the spacing dry run) |

### Semantics

Per-vCPU state, consistent with `limit=` and `rotate=` already being per-vCPU:

```
DORMANT --(trigger)--> CAPTURING(N) <--> SKIPPING(M) --(K windows)--> DONE
```

`SKIPPING` reuses the existing dormant fast path (counter increment only, no
record building), so skipped stretches run at ~300 MIPS rather than the ~30 MIPS
of active tracing.

`sample_clock=user` has a deliberately asymmetric meaning, because the obvious
symmetric reading would break the SPEC comparability that §1 rests on:

| phase | `sample_clock=user` | `sample_clock=all` |
|---|---|---|
| **gap** (`sample_gap`) | advances on **user-mode instructions only** | advances on every instruction |
| **window start** | begins at the **first user-mode instruction** after the gap completes | begins immediately |
| **window length** (`sample_len`) | **every instruction counts** | every instruction counts |

So a window is always **exactly `sample_len` records**, which is what keeps it
comparable to a 300 M SPEC slice. If the user-mode clock also governed window
length, a window would contain `sample_len` user instructions *plus* however many
kernel instructions interleaved — no longer a 300 M slice, and not comparable.

What the user-mode clock buys is that idle stretches neither consume the gap nor
start a window.

The privilege bit is already computed per instruction, so this costs nothing.
**Note it is an address heuristic (`vaddr >= 0xFFFF800000000000`), not the
architectural CPL** — reliable for the x86-64 canonical split, but it is a VA
test and should be described as such.

**Implementation hazard.** `finalize_pending_insn()` is what clears
`has_pending`, and `mem_cb` gates on that flag. The transition from capturing to
skipping must call `finalize_pending_insn()` first; otherwise memory operations
belonging to *skipped* instructions attach themselves to the last *captured*
instruction, silently corrupting its operand list.

Each window is emitted as its own chunk, reusing the existing `rotate=` naming
and manifest (`trace_vcpu1_c00000.raw.zst`, plus start-instruction / count /
compressed-size per chunk). `rotate=` together with `sample_len=` is a
configuration error and is rejected at parse time.

`limit=` continues to cap total traced instructions and acts as a safety net.

### Spacing

`profile=on` runs one dormant-speed pass and reports total user-mode
instructions in the ROI. Then `M = (total − K·N) / (K − 1)`. Deterministic
replay is what makes the two-pass approach valid.

### Interaction with the branch-type work

Each window ends without a successor, which is exactly the chunk-boundary case
handled in `docs/branch-type-contract.md` §5: an unconditional transfer is
forced taken, a trailing conditional is dropped. That is 4 boundary records
across 1.2 B instructions per task.

## 7. Guest configuration

```
-smp 4  -m 16G  -cpu qemu64          (fixed CPU model; must not vary across runs)
kernel cmdline: isolcpus=1 nohz_full=1 rcu_nocbs=1 norandmaps
```

vCPU 1 is isolated and traced (`vcpus=1`); vCPUs 0/2/3 absorb kernel threads,
IRQs and systemd. Inside the guest: IRQ affinity masked away from CPU 1, swap
off, THP off, `PYTHONHASHSEED=0`, unnecessary services disabled.

The agent is launched under `taskset -c 1`. Tool subprocesses **inherit** the
affinity through `fork`/`exec`, so they land on the traced vCPU automatically —
this is the specific reason the Local backend was chosen over Docker, whose
daemon/`containerd`/`runc` process trees would not inherit it.

The replay proxy also runs on vCPU 1.

> **Modeling caveat, to be carried into the results.** In production the LLM is
> remote, so the proxy's serving cost is an artifact of this setup. Its
> inclusion is deliberate — the brief lists the proxy as CPU work to capture —
> but it inflates the agent's apparent CPU work and must be stated whenever
> these traces are reported.

**Expect a high idle fraction.** Pinning improves purity but *worsens* idle: when
the agent blocks, nothing else is runnable on vCPU 1, so it executes the emulated
`HLT` loop. `docs/pipeline/task-tcg-idle-loop-filtering.md` measured ~80% kernel
under TCG versus ~50% under KVM for Memcached. `sample_clock=user` and
`trace_filter` both attack this; `trace_filter --stats-only` quantifies it.

## 8. Arming the ROI

The guest prints a unique marker to the serial console immediately before
invoking the agent. The host driver tails the serial log and touches the trigger
file. This is the pattern already proven by `scripts/smoke-trace/smoke_trace.sh`.

The driver must verify `TRIGGER DETECTED` appears in the log and abort loudly
otherwise. **Rationale:** the plugin polls for the trigger only while
instructions retire, so if the guest finishes first the polls simply stop and the
run ends with `Trigger was never activated` — a symptom identical to a wrong path
or a permission error. Replay here runs for minutes, so the margin is ample, but
the check is cheap and the failure is otherwise confusing. `-DTRIGGER_DEBUG`
disambiguates if needed.

## 9. Replay proxy

A single-file local HTTP server with two modes.

**RECORD** — forwards to the GLM 5.2 upstream, writes each `(request → response)`
pair to a cassette keyed by a hash of the *canonicalised* request body (model,
messages, tools, temperature).

**REPLAY** — serves from cassettes only. **A miss is a hard 500 with a loud log
line, never a passthrough.** With guest networking down a silent fallback is
impossible anyway, but failing loudly converts environment drift into an
immediate diagnosable error instead of a quietly wrong trace.

Cassettes are stored per task alongside the `.traj`, so a capture is reproducible
without an API key. **The API key is required only in Pass 2 and never enters the
trace pipeline.**

The canonicalisation must exclude anything that varies per run (request IDs,
timestamps) or every request misses. This is the fiddliest part of the proxy and
gets its own unit test (§11).

## 10. Conversion and validation

Per 300 M window:

```
trace_filter  window.raw.zst → window.filtered.raw.zst      # strip HLT..HLT idle
raw2champsim  window.filtered.raw.zst → window.champsim2.zst
trace_sanity_check -i window.champsim2.zst -f v2 --check
```

`trace_filter` accepts raw v3 with PA and rejects AArch64 explicitly (its header
comment says "v2" — stale, the code handles `{2,3}`).

`trace_filter --stats-only` on the *unfiltered* window records the idle fraction,
which is a result in its own right: it measures how much of the agent's wall time
is genuinely blocked.

All six acceptance checks must pass. The two load-bearing ones are **conditional
taken-rate strictly inside (0,100)** and **calls balancing returns**; both are
described in `docs/branch-type-contract.md` §9.

ChampSim is invoked with `--trace-version 2`.

## 11. Testing

Layered, following the principle established by the branch-type work: **every
defect in that effort produced structurally valid, semantically wrong output, and
only differential tests against an independent oracle caught them.**

1. **Proxy unit tests** — cassette-key canonicalisation; record/replay round trip
   over a synthetic conversation; a miss raises rather than passes through.
2. **Sampling knob tests** — K windows of exactly N instructions; gaps of exactly
   M; `sample_clock=user` does not advance on kernel instructions; `rotate=` plus
   `sample_len=` rejected at parse time.
3. **Differential cross-check (the important one)** — capture a region via
   sampling, and the same region via `rotate=`, then assert the records are
   identical. This is what catches a sampler off-by-one, the same class of bug as
   the 1.56× skip-counter error in the pintool, which self-consistency checks
   could not see.
4. **End-to-end smoke** — extend `scripts/smoke-trace/` with the sampling knobs
   so the feature is validated in ~2 minutes before committing to an
   hours-long agent capture.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Trajectory length unknown; profile pass could be slow if 10× the ~100 B estimate | cap the profile pass; fall back to a fixed gap |
| Preparing 2–3 SWE-bench task environments without task images is the largest unknown in Pass 1 | pick tasks with simple dependency trees; verify each runs before recording |
| Idle fraction may stay high even after pinning | `sample_clock=user`, `trace_filter`, and `--stats-only` to quantify |
| Proxy inflates apparent CPU work vs. a real deployment | documented modeling choice; stated wherever results are reported |
| Cassette-key over-specificity causes universal misses | unit test; loud failure surfaces it in seconds |

## 13. Inputs required from the user

1. **Which 2–3 SWE-bench Multilingual tasks** to run.
2. **The GLM 5.2 API key**, at Pass 2 only.

## 14. Deliverables

- Plugin sampling feature + tests (`plugin/champsim_tracer.c`, `plugin/README.md`)
- Replay proxy + tests
- Guest build/record/trace scripts under `scripts/swe-agent/`
- 2–3 tasks × 4 windows of validated `.champsim2.zst`
- A workload playbook in `docs/workloads/`, and an idle-fraction measurement
