# scripts/dacapo/kafka/

DaCapo Chopin `kafka`. Three traces.

| file | stage |
|---|---|
| `boot_java8g_kvm.sh` | boot `kafka-guest.qcow2` under KVM (8 GB heap variant) |
| `launch_tcg_java8g.sh` | restore under TCG |
| `convert_one_kafka.sh` | one window through the converter chain |
| `run_kafka_profile.sh`, `run_kafka_capture.sh`, `run_kafka_ship.sh` | the three stages |

## Single-core slice

All **101 JVM threads** pinned to the traced vCPU, verified before the snapshot and
after the TCG restore.

## The best coverage in the campaign, and why

3 windows x 1e9 spanning **99.32%** of the profiled trajectory — better than any
other workload. The plugin's hint would have given 94.96%.

The reason is measurable rather than lucky: the two gaps imply user fractions of
**0.5158** and **0.5042** against a profile average of **0.5063**. Kafka holds a
near-constant user/kernel ratio across its whole run, and the gap arithmetic
assumes exactly that. Cassandra's ratio swings much more, which is why its coverage
is 1.5 points lower under an identical method.

This is the cleanest evidence in the corpus that coverage shortfall tracks
*variance* in the user fraction, not just its level.
