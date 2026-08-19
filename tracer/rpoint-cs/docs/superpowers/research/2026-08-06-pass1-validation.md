# Pass 1 validation record

Guest image: `images/swe-agent-guest.provisioned.qcow2`
Instance: `prometheus__prometheus-15142` · base_commit `16bba78f1549cfd7909b61ebd7c55c822c86630b`

## Environment (verified, not assumed)

| Property | Value | How checked |
|---|---|---|
| Guest OS / kernel | Ubuntu 24.04.4 / 6.8.0-136-generic | `uname -r` |
| Root filesystem | 58 G (growpart ran) | `df -h /` |
| vCPU 1 isolated | `isolated=1`, `nohz_full=1` | `/sys/devices/system/cpu/{isolated,nohz_full}` |
| Userspace CPU count | 3 of 4 (isolated CPU invisible) | `nproc` |
| ASLR | off | `kernel.randomize_va_space=0` |
| THP / swap | `[never]` / 0 B | `/sys/kernel/mm/...`, `free -h` |
| Go | go1.23.8, `GOTOOLCHAIN=local`, `CC=gcc` | `go version`, `go env` |
| Prometheus | `16bba78f1549`, clean tree | `git rev-parse`, `git status --porcelain` |
| Module cache | 1.5 G | `du -sh /opt/go/pkg/mod` |
| **Offline build** | **passes** | `unshare -n` + `GOPROXY=off` → `go build ./...` and `go test -c` |
| SWE-agent | 1.1.0 (SWE-ReX 1.4.0) | `sweagent --help` |

## Benchmark instance reliability

`FAIL_TO_PASS` = `TestHeadAppendHistogramAndCommitConcurrency` (+2 subtests) —
a **concurrency** test, so reliability had to be demonstrated, not assumed.

| Configuration | Runs | Result |
|---|---|---|
| KVM, base + test_patch | 10 | **FAIL 10/10** (bug reproduces) |
| KVM, base + test_patch + gold_patch | 10 | **PASS 10/10** (fix works) |
| **TCG, pinned to isolated CPU 1**, base + test_patch | 5 | **FAIL 5/5**, 11–17 s each |

Zero vacuous runs in all three. The TCG row is the load-bearing one: it is the
actual traced configuration, and single-CPU emulated scheduling is precisely
what could have flipped a concurrency test.

### The gate that first passed for the wrong reason

The initial attempt ran the test at bare `base_commit` and reported a clean
10/10 PASS. It was meaningless: in SWE-bench the `FAIL_TO_PASS` tests are
**added by the test_patch**, so `-run` matched nothing, `go test` printed
`[no tests to run]` in 0.008 s and exited 0. Ten successful runs of nothing.

Two separate no-op modes therefore had to be defended against explicitly:

* `(cached)` — a warm `GOCACHE` replays a previous result and runs zero tests.
  Defeated with `-count=1`.
* `[no tests to run]` — the regex matches nothing. Now counted separately as
  `vacuous` rather than folded into pass/fail, so it can never read as green.

## Mitigations under TCG (record with the traces)

```
spectre_v2: Mitigation: Retpolines; STIBP: disabled; RSB filling
```

Retpolines are **active** under `-cpu qemu64`, so kernel code in the trace
contains indirect-branch thunks. `mitigations=off` was deliberately NOT set:
switching it off would materially change the branch mix in a study whose whole
subject is branch prediction. The traced pass must use the same `-cpu qemu64`,
since a different CPU model changes CPUID and hence the mitigation selection.
