# scripts/common/

Shared by every workload. Nothing here is workload-specific.

| file | what it is |
|---|---|
| `lib.sh` | path resolution — see `../README.md`. Exports `SROOT`, `COMMON`, `RPCS`, `INFRA`, `W`. |
| `cpustr.sh` | `CPUSTR`, `QEMU_FIXED`, `IMAGES`, `MON`. Sourced by `lib.sh`. |
| `hmp.py` | talks to the QEMU monitor socket. Timeout 1800 s (a `savevm` of a 12 GB guest takes minutes). |
| `sgap.py` | computes the window gap. **Use this, never the plugin's hint.** |
| `ship_trace.sh` | the current ship driver, parameterised over `DEST`/`BENCH`/`NEW`/`NWIN`/`EXPECT`. |
| `convstat.sh` | counts filter + convert + sanity stages. |
| `guestpin.sh` | resolves a guest JVM by `/proc/PID/exe` and reports its pin mask. |
| `dfstat.sh` | max `decode_fail` across converter logs. |
| `build_qemu_avxfix.sh` | builds the patched QEMU. |

## `cpustr.sh` — why the CPU model looks like that

`CPUSTR` is `Haswell` with every paravirtual feature switched off, **`kvmclock=off`
foremost**. A KVM snapshot has to restore under TCG, and paravirt clock state does
not survive that boundary. This is not tuning; the pipeline does not work without it.

The cost is worth knowing: with `kvmclock=off` the guest falls back to `hpet`
(~7270 ns/call), which is why `track_io_timing` is unusable in these guests and why
I/O fractions were measured from two `/proc/stat` samples instead.

`QEMU_FIXED` points at the patched QEMU (`build_qemu_avxfix.sh`), which carries two
patches the KVM→TCG path requires: the kvmclock fix and the **AVX hflag** fix
(`cpu_sync_avx_hflag(env)` in `cpu_post_load()`). The second is what made JVM
tracing possible at all — a JVM with C2-compiled AVX2/FMA code had previously
died on restore, which is why "big data frameworks break quickly inside TCG
restore" was a standing blocker for years.

## `sgap.py` — the gap must be computed, not taken from the plugin

The plugin prints a `sample_gap` hint at exit. **It is wrong**, and its derivation
is in the file. It mixes an all-instruction window length with a user-only counter:
the correct form is `SGAP = (user/(K-1)) * (1 - K*N/total)`.

Six measured points from the campaigns, hint coverage against the correct 100.00%:

| workload | kernel % | hint would cover |
|---|---|---|
| q18 | 6.2 | 99.87% |
| dec-tree | 5.5 | 99.83% |
| q9 | 29.0 | 98.81% |
| finagle-http | 31.5 | **96.95%** |
| q21 | 39.1 | 98.14% |
| redis | 61 | 58.92% (actual, shipped) |

The error grows with kernel fraction **and** with short trajectories — finagle-http
is worse than q21 despite less kernel, because its trajectory is under half as long
so the fixed `K*N` is a larger share of it. Redis and RocksDB shipped before this
was understood and have narrower coverage than intended; their traces are valid,
this is representativeness rather than correctness.

## The three monitoring helpers

Each exists because a hand-written check produced a false reading during a
campaign. They are definitions rather than something retyped per poll:

- `convstat.sh` — counting only `raw2champsim` read a healthy sanity-check stage
  as `convert=0`, the literal escalation condition, on a working system.
- `guestpin.sh` — `pgrep -f … | head -1` returned a bash wrapper and misreported
  the pin as lost.
- `dfstat.sh` — an unanchored `[0-9]+$` on the converter progress line returned
  the **SIMD** counter, reporting 1,606,302 decode failures against a converter
  that was at `decode_fail 0`.

The general rule they encode: **never extract a number without anchoring it to its
label**, and never let a check pass on nothing (`bash -n` reports "syntax OK" on a
zero-byte file; `grep -c` prints `0` *and* exits 1, so `grep -c … || echo 0` emits
`0\n0` and numeric tests on it are shell errors).
