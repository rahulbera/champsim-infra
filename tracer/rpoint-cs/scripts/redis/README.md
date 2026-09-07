# scripts/redis/

Redis 7.0.15 under memtier. Five traces in the catalogue.

| file | stage |
|---|---|
| `boot_redis_kvm.sh` / `boot_redis_kvm_restore.sh` | boot fresh / restore under KVM |
| `launch_tcg_redis.sh` | restore under TCG |
| `convert_one_redis.sh` | one window through filter → convert → sanity |
| `ship_redis.sh` | historical ship driver (superseded by `common/ship_trace.sh`) |
| `redis_theta_prep.sh`, `redis_theta_scout.sh` | the Zipf-theta scouting pair |

## The theta scouting is the interesting part

`redis_theta_scout.sh` exists because **theta=0.99 produced an unusable trace**:
measured **7.7% branch / 70.8% mem**, squarely inside the reject band
(`branch < 10% AND mem > 70%`), which marks a degenerate bulk-copy regime where a
handful of hot keys stay resident and MGET-16 x 4000 B turns into memcpy.

The shipped configuration is **theta=0.80**, which measures 14.0-14.4% branch /
52.3-53.3% memory across all five windows, 39-41% user / 59-61% kernel,
`decode_fail 0`.

This is the counterexample worth remembering: a *more* skewed access distribution
made the trace *less* useful, because skew concentrated the working set into cache.
MongoDB at theta=0.99 is fine (15.5-17.7% branch / 44.4-48.3% mem) — the reject
band is a property of the workload+config pair, not of theta.

## Recorded caveat

Coverage is **58.92%**, the narrowest in the catalogue, because the gap came from
the plugin's buggy exit-time hint rather than `sgap.py`. At ~39% user the hint's
units error is at its worst. Traces are valid; recapture is the researcher's call.
