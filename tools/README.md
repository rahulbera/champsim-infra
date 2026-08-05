# tools/ — standalone trace utilities

Two small C++ command-line tools for working with ChampSim trace files
**after** they're generated. They are independent of the run pipeline in
`scripts/` — build each with its own `make`.

| Tool | What it does |
|------|--------------|
| `trace_cutter/` | Splits one big zstd **v2** trace into N-instruction `.zst` chunks. |
| `trace_sanity_check/` | Walks a `.gz`/`.xz`/`.zst` trace and prints aggregate stats (instruction/branch/load/store counts, footprint, …). |

`trace_cutter` honours **`ZSTD_HOME`** (default: system zstd) the same way
`pintool/` does, in case you link against a custom zstd build.
`trace_sanity_check` needs no compression libraries at all — it shells out to the
reference decompressors.

---

## trace_cutter

Splits a zstd-compressed **v2** ChampSim trace (fixed 512-byte
`trace_instr_v2_t` records) into N-instruction chunks. Each output chunk is a
self-contained `.zst` file; the last chunk may be short. Useful for carving a
huge trace into uniformly-sized simulation points.

```bash
cd tools/trace_cutter
make                              # honours ZSTD_HOME; falls back to system zstd

./trace_cutter -i big.champsim2.zst -o out_dir/ -n 50000000
```

| Flag | Default | Meaning |
|------|---------|---------|
| `-i`, `--input` | _(required)_ | Input zstd v2 trace. |
| `-o`, `--output-dir` | _(required)_ | Output directory (created if missing). |
| `-n`, `--num-instr` | _(required)_ | Records (instructions) per chunk, `> 0`. |
| `-l`, `--level` | `3` | zstd compression level for the output chunks. |
| `-w`, `--workers` | `0` | zstd encoder worker threads (`0` = single-threaded). |
| `--dry-run` | off | Count records and report how many chunks would be written; write nothing. |

> Input must be the **v2** 512-byte format. The tool reassembles records across
> zstd decompression-frame boundaries, so every chunk boundary lands on a whole
> 512-byte record. Use `--dry-run` first to see the chunk count.

---

## trace_sanity_check

Walks a trace record-by-record and prints aggregate statistics: instruction /
branch / load / store counts, unique 4 KB load pages (and the resulting data
footprint in MB), and — for v2 traces — int/fp/simd split, user/kernel split,
access-size histograms, and PA-side load footprint.

Self-contained — **no ChampSim checkout and no compression `-dev` packages
needed**. Compressed traces are read by piping through the system
`zstd`/`xz`/`gzip`/`bzip2` binaries, chosen by file extension, so the reference
decompressor is itself the parity reference.

```bash
cd tools/trace_sanity_check
make

./trace_sanity_check -i trace.champsim2.zst -f v2
./trace_sanity_check -i trace.champsim2.zst -f v2 --no-unique --check   # CI gate
```

| Flag | Default | Meaning |
|------|---------|---------|
| `-i`, `--input` | _(required)_ | Input trace (`.gz` / `.xz` / `.zst` / `.bz2`, or raw). |
| `-f`, `--format` | `v1` | Record format: `v1` (64 B), `v2` (512 B), or `cloudsuite` (96 B). |
| `--heartbeat N` | `10M` | Progress report every N records (`0` = off). |
| `--no-unique` | off | Skip the unique-load-page set (saves RAM on very large traces). |
| `--check` | off | Enforce the v2 branch-type invariants; exit 2 if any fails. |

> There is no format autodetection: `-f v1` on a v2 trace silently misreads it,
> because 512 is a multiple of 64. A trailing partial record now produces a
> warning, which is usually the first sign you picked the wrong `-f`.

### `--check` — the branch-type acceptance gate

Verifies that a freshly generated v2 trace is actually usable for
branch-predictor work. Six invariants, all hard failures:

1. every record carries the explicit-branch-type feature bit (`reserved[1] & 1`)
2. `reserved[0]` spans more than one value — a constant column means it is not
   being written at all
3. **conditional branches exist and their taken rate is strictly inside (0, 100)%**
4. unconditional transfers (jump / indirect / call / return) are 100% taken
5. calls and returns have `is_branch = 1`
6. the flags register appears on both the source and destination side

Check 3 is the one that would have caught the bug that motivated all of this: a
pre-fix trace reports zero conditional branches and a "direct jump" bucket that
is only ~49% taken, when a genuine unconditional jump is always taken. Check 4
catches the same thing from the other direction.

The conditional *share* of branches is reported as `[INFO]` rather than gated,
because it is workload-dependent (60-85% is typical for integer workloads, but a
short loop-heavy trace like `/bin/ls` runs much higher).
