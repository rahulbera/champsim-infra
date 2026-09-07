# scripts/renaissance/dectree/

Renaissance `dec-tree` — Random Forest from Spark ML. Three traces.

Uses the shared guest, launcher and drivers from `../`. Only the converter is here.

## Why it was chosen

The second DataFrame/Tungsten benchmark, picked for **irregular histogram
aggregation and much branchier control flow** than either page-rank's RDD pointer
chasing or naive-bayes's sequential sparse scans. Config from
`benchmarks.properties`: `copy_count=100`, `spark_thread_limit=6`.

## It landed where predicted — the corpus's high-branch, low-memory corner

```
w00000 75.2/24.8 user/kern, 18.6% branch, 41.1% mem, SIMD 18,948,709
w00001 79.4/20.6, 17.0%, 42.5%, SIMD 19,796,059
w00002 77.7/22.3, 18.8%, 41.0%, SIMD 19,587,005
```

**Highest branch rate and lowest memory fraction measured in the campaign** —
18.8% branch against PostgreSQL q9's 12.9%, memory 41.0% against q21's 57.7%.
dec-tree and q21 sit at opposite corners and bracket every other trace in the
catalogue between them.

~19 M SIMD per billion: well above q18's 9 M, well below naive-bayes's 54 M. The
two Spark ML workloads did land in genuinely different places, which was the open
question when they were proposed.

290 JVM threads at launch, 287 at capture, all pinned, 0 unpinned. Profile:
103,861,568,088 instructions, **94.47% user**, 173.1 MIPS.
3 windows spanning **101.01%** via `common/sgap.py`.
