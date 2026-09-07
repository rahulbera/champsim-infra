# scripts/dacapo/tomcat/

DaCapo Chopin `tomcat`. Three traces.

| file | stage |
|---|---|
| `boot_tomcat_kvm.sh` | boot `tomcat-guest.qcow2` under KVM |
| `launch_tcg_tomcat.sh` | restore under TCG |
| `convert_one_tomcat.sh` | one window through the converter chain |
| `run_tomcat_snap.sh`, `run_tomcat_profile.sh`, `run_tomcat_capture.sh`, `run_tomcat_ship.sh` | the four stages |

## Single-core slice

All **26 JVM threads** pinned — the smallest thread count of any JVM workload here
(cassandra 88, kafka 101, spark 268).

## The only workload in the corpus that genuinely idles

Tomcat waits on requests, so `trace_filter` legitimately strips **0.6-0.9%** of each
window as idle-loop noise. Everything else in the catalogue strips ~0% (PostgreSQL
under a server-side `DO` loop never idles at all).

That mattered operationally: the ship gate had been set at `>= 999,900,000` insns,
a 0.01% tolerance generalised from MongoDB. Tomcat tripped it and the ship
**aborted on a miscalibrated gate, not on a real defect**. Recalibrated to 99%,
which is what `common/ship_trace.sh` uses.

Measured, three windows, `decode_fail 0`:

```
w00000 50.9/49.1 user/kern, 17.5% branch, 41.8% mem, 997,166,412 insns
w00001 53.8/46.2, 17.6%, 41.7%, 995,871,453
```

3 windows span **97.64%** via `common/sgap.py` (hint: 96.70%). The two gaps imply
user fractions of 0.6812 and 0.6813 — as steady as Kafka's.

## One more trap this workload found

`run_tomcat_ship.sh` had `okcount() { … grep -acE '^OK' … || echo 0; }`, which
emits `0\n0` when there are no matches and makes numeric tests a shell error. The
fixed form pipes through `head -1` and defaults. The committed copy carried the
buggy version until the 2026-09-07 reorganisation.
