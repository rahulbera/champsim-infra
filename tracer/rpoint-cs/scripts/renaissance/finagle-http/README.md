# scripts/renaissance/finagle-http/

Renaissance `finagle-http` — many small HTTP requests to a Twitter Finagle server,
client and server in **one JVM over TCP loopback**. Three traces.

Uses the shared guest, launcher and drivers from `../`. Only the converter is here.

## *** ACCEPTED ON CONTROL-FLOW GROUNDS — the memory criterion is WAIVED ***

The standing constraint for this corpus is "memory-intensive traces, but NOT at the
cost of an unrealistic deployment scenario". For this workload and
`../finagle-chirper/` the researcher explicitly waived the first half:

> "The finagle workloads are more interesting from control-flow perspective: they
> may or may not be interesting from memory perspective. But that's fine. These
> traces may come in handy for new studies."

**Do not screen these out for a small footprint, and do not read a low memory
fraction as a defect.** Measured live set is **14.1 MB** after GC, against
naive-bayes's 1.35 GB — roughly 100x smaller, exactly as anticipated. Deployment
realism still applies and still holds.

## What it contributes that nothing else does

**The slowest workload this project has ever traced: 75.4 MIPS.** Below tomcat
(76.6) and cassandra (84.5), a third of PostgreSQL q18 (255.7). Its 600 s profile
covers only 45.2e9 instructions against q18's 153.4e9.

**Two of three windows are majority-kernel** (50.2%, 51.2%). Client and server share
one JVM over loopback, so every request crosses the kernel twice and TCG cannot
accelerate a syscall.

```
w00000 51.2/48.8 user/kern, 18.2% branch, 41.2% mem
w00001 49.8/50.2, 18.3%, 41.3%
w00002 48.8/51.2, 18.3%, 41.2%
```

High branch + kernel-heavy is a combination nothing else in the catalogue has.
q21 is also majority-kernel but at 12.7% branch / 57.7% mem — the opposite mix.
**The waiver was load-bearing:** on footprint alone these would have been screened
out, taking the corpus's only traces in this corner with them.

## The worst sample_gap hint case measured anywhere

The plugin's hint would have covered **96.95%** against the correct 100.00% — worse
than q21 *despite a lower kernel fraction* (31.5% vs 39.1%), because the shortfall
is `K*N*(1-f)/U` and this trajectory is under half q21's, so the fixed 3e9 of window
is a much larger share of it. **Short trajectories amplify the bug**; it is not a
function of kernel fraction alone. Use `common/sgap.py`.

47 JVM threads at launch, 49 at capture, all pinned. Profile: 45,227,376,391
instructions, **68.49% user**, 75.4 MIPS. 3 windows spanning **103.36%**.

## Recorded deviation

One JVM, loopback TCP: no traffic leaves the guest, so there is no NIC driver and no
real network latency — but the full socket syscall path, the Netty event loop and
TCP processing **are** present.
