# scripts/renaissance/finagle-chirper/

Renaissance `finagle-chirper` — simulates a microblogging service on Twitter
Finagle, client and server in one JVM. Three traces.

Uses the shared guest, launcher and drivers from `../`. Only the converter is here.

## *** ACCEPTED ON CONTROL-FLOW GROUNDS — the memory criterion is WAIVED ***

Same waiver as `../finagle-http/`, in the researcher's words: these are wanted for
control flow and "may or may not be interesting from memory perspective. But that's
fine." Measured live set **18.8 MB** after GC. Do not treat a small footprint as a
defect here.

## The matched-pair property

chirper and finagle-http differ by **~9 points of kernel fraction** while their
branch and memory mixes are nearly identical:

| | user/kern | branch | mem | TCG rate |
|---|---|---|---|---|
| finagle-http | ~50/50 | 18.3% | 41.2% | 75.4 MIPS |
| finagle-chirper | ~59/41 | 18.6% | 41.6% | 100.5 MIPS |

The Netty/Finagle stack dominates the user-mode instruction shape regardless of the
service above it, so **the pair isolates kernel involvement with user code held
roughly constant**. That is a useful thing for a corpus to contain, and it is why
capturing both rather than one was worth the machine time.

chirper is less kernel-bound because it does more in-JVM work between requests than
http's tight request/response loop.

## Measured, three windows, `decode_fail 0`

```
w00000 59.5/40.5 user/kern, 18.6% branch, 41.4% mem
w00001 57.7/42.3, 18.5%, 41.7%
w00002 60.5/39.5, 18.6%, 41.7%
```

72 JVM threads at launch, 83 at capture, all pinned, 0 unpinned. Profile:
60,272,603,054 instructions, **82.12% user**, 100.5 MIPS.
3 windows spanning **103.90%** via `common/sgap.py`.
