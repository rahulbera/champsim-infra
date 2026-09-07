# renaissance/

All five benchmarks here run from one jar (`renaissance-mit-0.16.1.jar`) inside
one guest (`spark-guest.qcow2`), so the guest and harness drivers live at this
level and the per-benchmark converters live below it:

```
boot_spark_kvm.sh        boots the shared guest under KVM
launch_tcg_spark.sh      restores it under TCG (MODE=bare|profile|capture)
run_ren_snap_profile.sh  savevm + FENCED 600 s profile (see below)
run_ren_profile.sh       the profile stage alone
run_ren_capture.sh       the windowed capture
  spark/                 page-rank        (RDD API)
  naivebayes/            naive-bayes      \
  dectree/               dec-tree          |  DataFrame -> Catalyst -> Tungsten
  finagle-http/          finagle-http      |  (finagle: Netty/HTTP, not Spark)
  finagle-chirper/       finagle-chirper  /
```

The `boot_spark_kvm.sh` / `launch_tcg_spark.sh` names are historical — they were
written for the Spark page-rank campaign and later served all five. They are
kept rather than renamed because the image they boot really is
`spark-guest.qcow2`; renaming the scripts without renaming the image would trade
one confusion for another.

`spark/` additionally has its own `run_spark_{snap,profile,capture,ship}.sh` from
the page-rank campaign, which predate the generic `run_ren_*` drivers.

## The fenced profile

`run_ren_snap_profile.sh` pauses any running converters (`SIGSTOP`) for the
600 s measured window and resumes them afterwards via a trap. This is not
incidental: the profile is the **only time-bounded stage** in the pipeline.
Capture and conversion are instruction- and data-bounded, so contention there
costs wall-clock and nothing else, but a contended profile executes fewer
instructions in its fixed window, yielding a smaller `SGAP` and a narrower slice
of the workload's trajectory — which would make the resulting user-fraction
incomparable across workloads.

`SIGSTOP` is safe on `raw2champsim` specifically: a plain read/write filter with
no timers, sockets, guest or monitor. **This is not a licence to signal QEMU** —
a capture is still stopped with a monitor `quit`.

## Gap sizing

Use `common/sgap.py`. Do **not** use the plugin's exit-time `sample_gap` hint: it
is unit-inconsistent, and its error grows with kernel fraction *and* with short
trajectories. finagle-http is the worst case measured anywhere in this project
(96.95% coverage against the correct 100.00%) despite a lower kernel fraction
than PostgreSQL Q21, because its trajectory is less than half as long.
