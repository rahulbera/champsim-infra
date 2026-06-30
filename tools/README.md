# tools/ — standalone trace utilities

Two small C++ command-line tools for working with ChampSim trace files
**after** they're generated. They are independent of the run pipeline in
`scripts/` — build each with its own `make`.

| Tool | What it does |
|------|--------------|
| `trace_cutter/` | Splits one big zstd **v2** trace into N-instruction `.zst` chunks. |
| `trace_sanity_check/` | Walks a `.gz`/`.xz`/`.zst` trace and prints aggregate stats (instruction/branch/load/store counts, footprint, …). |

Both honour **`ZSTD_HOME`** (default: system zstd) the same way `pintool/` does,
in case you link against a custom zstd build.

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

The decompression backend is **`champsim/src/trace_reader.cc`, linked in
directly**, so it walks the file byte-for-byte the way the simulator does. That
means the build needs the ChampSim repo:

```bash
cd tools/trace_sanity_check
make CHAMPSIM_HOME=/home/rahbera/thesis/champsim     # default: ../../../champsim

./trace_sanity_check -i trace.champsim2.zst -f v2
```

| Flag | Default | Meaning |
|------|---------|---------|
| `-i`, `--input` | _(required)_ | Input trace (`.gz` / `.xz` / `.zst`). |
| `-f`, `--format` | `v1` | Record format: `v1` (64 B), `v2` (512 B), or `cloudsuite` (96 B). |
| `--heartbeat N` | `10M` | Progress report every N records (`0` = off). |
| `--no-unique` | off | Skip the unique-load-page set (saves RAM on very large traces). |

> `CHAMPSIM_HOME` defaults to `../../../champsim` — i.e. this infra repo sitting
> as a sibling of the ChampSim checkout. Point it at your ChampSim repo if your
> layout differs. The record layouts are `static_assert`-ed to the canonical
> 64 / 512 / 96-byte sizes, so a header mismatch fails the build loudly.
