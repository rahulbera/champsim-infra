# scripts/mongodb/

MongoDB 8.0.29 driven through libmongoc. Five traces in the catalogue.

| file | stage |
|---|---|
| `boot_mongo_kvm.sh` | boot `mongo-guest.qcow2` under KVM |
| `launch_tcg_mongo.sh` | restore under TCG |
| `convert_one_mongo.sh` | one window through the converter chain |
| `ship_mongo.sh` | historical ship driver (superseded by `common/ship_trace.sh`) |

Configuration: 40M documents x 1 KB, 95% read / 5% write, **theta=0.99** Zipfian,
WiredTiger cache 1 GB.

## Why theta=0.99 is fine here but was rejected for Redis

Redis at theta=0.99 measured 7.7% branch / 70.8% mem — inside the reject band, a
degenerate bulk-copy regime. MongoDB at the *same* theta measures **15.5-17.7%
branch / 44.4-48.3% mem**, comfortably outside it.

The difference is the server, not the distribution: WiredTiger's B-tree traversal,
document decoding and cache machinery keep real control flow in the trace even when
the hot set is small. The reject band screens a workload+configuration pair; it is
not a statement about skew.

## Measured, five windows (user/kern/branch/mem)

```
w00000 51.7/48.3/15.5/48.3    w00001 54.8/45.2/16.0/48.2
w00002 56.7/43.3/16.8/46.6    w00003 55.4/44.6/16.0/48.2
w00004 56.1/43.9/17.7/44.4
```
