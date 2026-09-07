# scripts/dacapo/cassandra/

DaCapo Chopin `cassandra` — YCSB against an embedded Cassandra. Five traces.

| file | stage |
|---|---|
| `boot_java_kvm.sh` / `boot_java_kvm_restore.sh` | boot / restore `java-guest.qcow2` |
| `launch_tcg_java.sh` | restore under TCG |
| `convert_one_cass.sh` | one window through the converter chain |
| `run_cass_ship.sh` | ship driver (wraps `../ship_dacapo.sh`) |

## Single-core slice

The whole JVM — **88 threads**: YCSB workers, Cassandra pools, G1, JIT — is pinned
to the traced vCPU with `taskset -acp 1`, verified `mask=2` with 0 unpinned before
the snapshot and again after the TCG restore.

Unpinned, `vcpus=1` samples roughly 1/88th of the work interleaved with unrelated
guest activity and produces a plausible-looking scheduler artifact rather than the
workload. The pin is **pid-bound**: it survives `savevm`/`-loadvm` but not a guest
restart.

## Measured, five windows, `decode_fail 0`

```
w00000 34.6/65.4 user/kern, 17.6% branch, 40.4% mem
w00001 50.8/49.2, 18.8%, 40.9%
w00002 39.7/60.3, 17.8%, 40.8%
```

At **37.1% user** cassandra is the most kernel-heavy of the three DaCapo
workloads, and 5 windows span **97.84%** of the profiled trajectory via
`common/sgap.py`. The plugin's exit-time hint would have covered only 85.75% here —
the error scales with kernel fraction, and cassandra has the most of it.
