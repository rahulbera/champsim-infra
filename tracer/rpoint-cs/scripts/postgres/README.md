# scripts/postgres/

PostgreSQL 16.15, TPC-H scale factor 10. **Twelve traces — the database category
of the OSDI'24 CXL-tiering taxonomy.**

| file | stage |
|---|---|
| `boot_pg_kvm.sh` | boot `pg-guest.qcow2` under KVM (12 GB RAM, 120 GB disk, port 2234) |
| `launch_tcg_pg.sh` | restore under TCG, port 2235 (`MODE=bare|profile|capture`) |
| `run_pg_snap_profile.sh` | `savevm` + **fenced** 600 s profile |
| `run_pg_profile.sh`, `run_pg_profile2.sh` | the profile stage alone |
| `run_pg_capture.sh` | windowed capture |
| `convert_one_pgq{1,9,18,21}.sh` | one window each, provenance in the headers |

Guest-side scripts (`load_tpch.sh`, `mkqueries.sh`, `run_query_loop.sh`, `tpch.conf`,
`tpch_keys.sql`, the generated queries) are preserved at
`../../docs/workloads/postgres/guest-files/`, so the guest is rebuildable from the
repo alone.

## The result worth knowing

**A 33-point user-fraction range from one guest, one database, one configuration —
by changing only the SQL.** Wider than the three DaCapo JVMs (37.1 → 66.4).

| query | user % | TCG rate | branch | mem | coverage |
|---|---|---|---|---|---|
| q18 | 93.81 | 255.7 MIPS | 15.2-15.5 | 48.7-49.6 | 101.41% |
| q1 | 82.50 | 204.7 MIPS | 15.0-15.4 | 49.9-50.8 | 101.29% |
| q9 | 71.04 | 171.3 MIPS | 12.9-15.8 | 47.3-56.7 | 99.73% |
| q21 | 60.90 | 172.2 MIPS | 12.5-12.7 | 56.0-57.7 | 101.93% |

"Database" is several points in the space, not one.

- **q9** is the only workload whose windows split into two *regimes* rather than a
  gradient: w00000/w00001 at 55% user / 12.9% branch / 56.6% mem (hash build and
  probe), w00002 at 82% / 15.8% / 47.3% with 4x the SIMD (the aggregate).
- **q21** holds the corpus's first majority-kernel window (52.0%) and its most
  memory-biased traces. Outside the reject band on both axes, deliberately.

## Configuration, and the deviations

`shared_buffers=2GB` against a 14 GB database — **7x overcommit**, so the working
set cannot be buffer-resident. `work_mem=64MB` (stock 4 MB would spill every sort
and make this an I/O study). **`max_parallel_workers_per_gather=0`** — one execution
process, the researcher's explicit call, matching the `1t` convention. Real
analytics would use parallel query; this is a stated deviation.

Foreign keys were **not** created. tpch-kit's `dss.ri` is DB2 syntax targeting a
`TPCD` schema: it ran to completion against PostgreSQL and created **zero**
constraints while appearing to succeed. Caught only by querying `pg_constraint`
directly. The 8 primary keys were written by hand; FKs skipped deliberately.

## Two things that are load-bearing

**The query runs in a server-side PL/pgSQL `LOOP`**, not a shell loop over `psql`.
The CPU pin is pid-bound; a shell loop spawns a fresh backend every ~35 s and the
pin is silently lost.

**`run_pg_snap_profile.sh` pauses the converters** (`SIGSTOP`) for the 600 s measured
window. The profile is the only time-bounded stage — a contended one yields a
smaller `SGAP` and a narrower slice, making user fractions incomparable across
queries. Safe on `raw2champsim` specifically (a plain filter, no timers/sockets/
guest/monitor); **not** a licence to signal QEMU.
