# scripts/renaissance/naivebayes/

Renaissance `naive-bayes` — multinomial Naive Bayes from Spark ML. Three traces.

Uses the shared guest, launcher and drivers from `../`. Only the converter is here.

## Why it was chosen

To test one specific claim: that the **DataFrame → Catalyst → Tungsten
whole-stage-codegen** path is a different machine from page-rank's RDD path, not
just a different algorithm.

Screened on measurement before committing, not on the config table:
- `copy_count=8000` — the largest input multiplier in the `apache-spark` group
- `spark_thread_limit=$cpu.count` — the only one defaulting to every core
- **live set 1.35 GB** after GC vs page-rank's 149 MB (9x)
- peak RSS 4.42 GB, so the 4 GB heap convention holds
- 3.7 GB spilled to disk per 3 iterations

## The claim held, and this is the evidence

**~54 M SIMD instructions per billion — 5.4% of the entire instruction stream.**
That is 2.8x dec-tree, 6x PostgreSQL q18, and 20x q1. Tungsten's generated
sparse-vector code JITs into wide vector loops; page-rank's RDD pointer-chasing
produces nothing like it.

Note that all three Spark benchmarks sit at ~95% user and 170-190 MIPS, so they are
**indistinguishable on privilege split**. The entire difference is in the mix.

## Measured, three windows, `decode_fail 0`

```
w00000 78.9/21.1 user/kern, 16.7% branch, 51.4% mem, SIMD 54,207,364
w00001 79.0/21.0, 16.7%, 51.4%, SIMD 54,466,479
w00002 78.8/21.2, 16.8%, 51.4%, SIMD 53,550,534
```

Memory at 51.4% on all three to one decimal, branch within 0.1 pt — a single steady
scan phase, unlike q9's two regimes.

291 JVM threads at launch, 274 at capture, all pinned. Profile:
107,476,839,742 instructions, **95.01% user**, 179.1 MIPS.
3 windows spanning **100.15%** via `common/sgap.py`.
