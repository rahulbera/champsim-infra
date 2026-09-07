# scripts/dacapo/

DaCapo Chopin 23.11-MR2, three workloads: `cassandra/`, `kafka/`, `tomcat/`.

`ship_dacapo.sh` lives here because all three share it (parameterised over
`BENCH`/`NEW`/`NWIN`/`EXPECT`). It is the historical driver;
`common/ship_trace.sh` supersedes it and additionally parameterises `DEST`.

Each workload has its own guest image — `java-guest` (cassandra), `kafka-guest`
(kafka), `tomcat-guest` — so the boot and launch scripts live in the subdirectories
rather than here.

## Why three, and why these three

Chopin's other workloads have smaller memory footprints. These were selected on
LLC-miss behaviour rather than heap size — **heap size anti-correlates with LLC
miss rate** in DaCapo's own published statistics, so screening on footprint would
have picked the wrong ones.

They were also the validation that the JVM pipeline worked at all, before Spark.
The AVX hflag patch (see `common/README.md`) is what made that possible.

## What the three together demonstrate

A 29-point spread in user fraction from the same guest family and the same tracer:

| workload | threads | user % | windows | coverage |
|---|---|---|---|---|
| cassandra | 88 | 37.1 | 5 | 97.84% |
| kafka | 101 | 50.6 | 3 | **99.32%** |
| tomcat | 26 | 66.4 | 3 | 97.64% |

"Trace one JVM" would have been wrong. Kafka's coverage is the best in the whole
campaign because it holds a near-constant user/kernel ratio, which is exactly the
condition under which the gap arithmetic is most accurate.
