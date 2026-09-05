/*
 * rocksdb_driver.cpp
 *
 * Standalone RocksDB driver that produces a multi-threaded, ROI-bracketed
 * Zipfian read/write workload for use with the ChampSim PIN tracer
 * (champsim_tracer_mt_roi_v2). The ROI is bracketed by champsim_roi_begin()
 * / champsim_roi_end() magic-NOP markers from champsim_markers.h.
 *
 * Phases:
 *   1. Load     : sequential WriteBatch inserts of N records, value size V.
 *   2. Compact  : full manual CompactRange + wait for L0 == 0.
 *   3. Warmup   : sequential iterator scan over all keys, prints cache hit
 *                 rate from rocksdb.block-cache-hit / -miss tickers.
 *   4. Compact  : second full manual CompactRange.
 *   5. Disable  : DisableAutoCompactions().
 *   6. ROI      : N worker threads run a Zipfian read/write loop. The main
 *                 thread emits champsim_roi_begin(), releases a barrier,
 *                 joins workers, then emits champsim_roi_end().
 *   7. Cleanup  : EnableAutoCompactions(); delete db.
 *
 * Worker TIDs (gettid()) are written to <db>/worker_tids.txt before the ROI
 * so a post-process step can keep only those threads' trace files.
 */

#include "zipfian.h"
#include "champsim_markers.h"

#include <rocksdb/cache.h>
#include <rocksdb/db.h>
#include <rocksdb/filter_policy.h>
#include <rocksdb/iterator.h>
#include <rocksdb/options.h>
#include <rocksdb/slice.h>
#include <rocksdb/statistics.h>
#include <rocksdb/table.h>
#include <rocksdb/write_batch.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <pthread.h>
#include <random>
#include <string>
#include <sys/syscall.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

/* ============================================================== */
/* CLI                                                            */
/* ============================================================== */

struct Args {
  std::string db_path        = "/mnt/sherlock/rahbera/workloadzoo/rocksdb-data/r1";
  long        num_records    = 5000000;
  int         value_size     = 1024;
  long        roi_ops_cap    = 1000000000; /* soft cap; wall clock trips first */
  int         read_pct       = 95;
  double      alpha          = 0.99;
  int         num_threads    = 4;
  std::vector<int> cpus;                   /* one CPU per thread, round-robin */
  int         cache_gb       = 8;
  unsigned    seed           = 42;
  int         warmup_secs    = 180;        /* untraced steady-state warmup */
  int         roi_secs       = 240;        /* traced + post-quota window    */
  bool        no_warmup_scan = false;
  bool        no_compact     = false;
  bool        overwrite      = false;
  bool        attach         = false;   /* v2: reuse an existing DB, skip the load */
  bool        no_fadvise     = false;
};

static void usage(const char *prog)
{
  std::fprintf(stderr,
    "Usage: %s [options]\n"
    "  -d PATH               DB directory                          [default: %s]\n"
    "  -n N                  num records to load                   [default: 5000000]\n"
    "  -v N                  value size in bytes                   [default: 1024]\n"
    "  -o N                  soft cap on per-thread ops (timer trips first)\n"
    "                                                              [default: 1000000000]\n"
    "  -r N                  read pct 0..100                       [default: 95]\n"
    "  -a F                  zipfian skew (0 = uniform)            [default: 0.99]\n"
    "  -t N                  num worker threads                    [default: 4]\n"
    "  --cpus=L              comma list of CPUs to pin             [required]\n"
    "  -c N                  block cache size in GB                [default: 8]\n"
    "  -s N                  RNG seed                              [default: 42]\n"
    "  --warmup-secs=N       untraced steady-state warmup seconds  [default: 180]\n"
    "  --roi-secs=N          wall-clock budget for traced window   [default: 240]\n"
    "  --no-warmup-scan      skip the sequential-scan warmup phase\n"
    "  --no-compact          skip both manual-compaction phases\n"
    "  --no-fadvise          skip POSIX_FADV_WILLNEED on SSTables\n"
    "  --overwrite           delete db_path if it exists\n"
    "  --attach              reuse an existing DB: skip load+post-load compaction\n"
    "\n",
    prog, "/mnt/sherlock/rahbera/workloadzoo/rocksdb-data/r1");
}

static bool parse_cpu_list(const char *s, std::vector<int> &out)
{
  out.clear();
  const char *p = s;
  while (*p) {
    char *end = nullptr;
    long  v   = std::strtol(p, &end, 10);
    if (end == p) return false;
    out.push_back((int)v);
    p = end;
    if (*p == ',') p++;
    else if (*p) return false;
  }
  return !out.empty();
}

static bool parse_args(int argc, char **argv, Args &a)
{
  for (int i = 1; i < argc; i++) {
    std::string s = argv[i];
    auto need = [&](const char *flag) -> const char * {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "%s requires an argument\n", flag);
        return nullptr;
      }
      return argv[++i];
    };
    if      (s == "-d") { auto v = need("-d"); if (!v) return false; a.db_path = v; }
    else if (s == "-n") { auto v = need("-n"); if (!v) return false; a.num_records = std::atol(v); }
    else if (s == "-v") { auto v = need("-v"); if (!v) return false; a.value_size  = std::atoi(v); }
    else if (s == "-o") { auto v = need("-o"); if (!v) return false; a.roi_ops_cap = std::atol(v); }
    else if (s == "-r") { auto v = need("-r"); if (!v) return false; a.read_pct    = std::atoi(v); }
    else if (s == "-a") { auto v = need("-a"); if (!v) return false; a.alpha       = std::atof(v); }
    else if (s == "-t") { auto v = need("-t"); if (!v) return false; a.num_threads = std::atoi(v); }
    else if (s == "-c") { auto v = need("-c"); if (!v) return false; a.cache_gb    = std::atoi(v); }
    else if (s == "-s") { auto v = need("-s"); if (!v) return false; a.seed        = (unsigned)std::atol(v); }
    else if (s.rfind("--cpus=", 0) == 0) {
      if (!parse_cpu_list(s.c_str() + 7, a.cpus)) {
        std::fprintf(stderr, "invalid --cpus=%s\n", s.c_str() + 7);
        return false;
      }
    }
    else if (s.rfind("--warmup-secs=", 0) == 0) a.warmup_secs = std::atoi(s.c_str() + 14);
    else if (s.rfind("--roi-secs=", 0) == 0)    a.roi_secs    = std::atoi(s.c_str() + 11);
    else if (s == "--no-warmup-scan") a.no_warmup_scan = true;
    else if (s == "--no-compact")     a.no_compact     = true;
    else if (s == "--no-fadvise")     a.no_fadvise     = true;
    else if (s == "--overwrite")      a.overwrite      = true;
    else if (s == "--attach")         a.attach         = true;
    else if (s == "-h" || s == "--help") { usage(argv[0]); std::exit(0); }
    else { std::fprintf(stderr, "unknown arg: %s\n", s.c_str()); return false; }
  }

  if (a.cpus.empty()) {
    std::fprintf(stderr, "ERROR: --cpus=... is required\n");
    return false;
  }
  if (a.num_threads < 1) {
    std::fprintf(stderr, "ERROR: -t must be >= 1\n");
    return false;
  }
  if (a.read_pct < 0 || a.read_pct > 100) {
    std::fprintf(stderr, "ERROR: -r must be 0..100\n");
    return false;
  }
  return true;
}

/* ============================================================== */
/* Helpers                                                        */
/* ============================================================== */

static inline pid_t gettid_safe()
{
  return (pid_t)syscall(SYS_gettid);
}

static inline void format_key(char *buf, size_t len, long id)
{
  std::snprintf(buf, len, "user%07ld", id);
}

static double now_secs()
{
  using namespace std::chrono;
  return duration<double>(steady_clock::now().time_since_epoch()).count();
}

static void pin_to_cpu(int cpu)
{
  cpu_set_t mask;
  CPU_ZERO(&mask);
  CPU_SET(cpu, &mask);
  int rc = pthread_setaffinity_np(pthread_self(), sizeof(mask), &mask);
  if (rc != 0) {
    std::fprintf(stderr, "[fatal] pthread_setaffinity_np(cpu=%d) failed: %s\n",
                 cpu, std::strerror(rc));
    std::exit(2);
  }
}

static std::string get_prop(rocksdb::DB *db, const char *name)
{
  std::string v;
  if (!db->GetProperty(name, &v)) v = "?";
  return v;
}

/* POSIX_FADV_WILLNEED on every SSTable (and other persistent) file in the
 * DB directory. This nudges the kernel to keep the file pages resident
 * for the upcoming ROI window. Combined with an 8 GB block cache that
 * fits the full decompressed dataset, this guarantees that any rare
 * block-cache miss that escapes to RocksDB's file layer hits the page
 * cache, not the disk. */
static void fadvise_willneed(const std::string &dir)
{
  size_t total_bytes = 0;
  int    files       = 0;
  for (auto &ent : fs::directory_iterator(dir)) {
    if (!ent.is_regular_file()) continue;
    const std::string &p = ent.path().string();
    /* Restrict to RocksDB persistent file extensions to avoid touching
     * LOG/CURRENT etc. */
    auto ext = ent.path().extension().string();
    if (ext != ".sst" && ext != ".log" && ext != ".ldb") continue;

    int fd = ::open(p.c_str(), O_RDONLY);
    if (fd < 0) continue;
    off_t size = (off_t)ent.file_size();
    posix_fadvise(fd, 0, size, POSIX_FADV_WILLNEED);
    /* Read one byte every 4 KB to actually fault pages in -- WILLNEED
     * is just a hint and the kernel may defer it. */
    static thread_local char throwaway[4096];
    for (off_t off = 0; off < size; off += 4096) {
      ssize_t n = pread(fd, throwaway, 1, off);
      (void)n;
    }
    ::close(fd);
    total_bytes += (size_t)size;
    files++;
  }
  std::fprintf(stderr,
               "[fadvise] WILLNEED+pre-touch on %d files, %.1f MB\n",
               files, (double)total_bytes / (1024.0 * 1024.0));
}

static void wait_for_compaction(rocksdb::DB *db)
{
  for (;;) {
    std::string pending = get_prop(db, "rocksdb.compaction-pending");
    std::string running = get_prop(db, "rocksdb.num-running-compactions");
    if (pending == "0" && running == "0") break;
    std::fprintf(stderr,
                 "[compact] waiting (pending=%s running=%s)\n",
                 pending.c_str(), running.c_str());
    std::this_thread::sleep_for(std::chrono::seconds(2));
  }
}

/* ============================================================== */
/* Worker                                                         */
/* ============================================================== */

struct WorkerCtx {
  int                   id;
  int                   cpu;
  rocksdb::DB          *db;
  long                  ops_cap;     /* soft per-thread cap; deadline trips first */
  std::chrono::steady_clock::time_point deadline;
  int                   read_pct;
  double                alpha;
  long                  num_records;
  int                   value_size;
  unsigned              seed;
  double                zeta_n;
  double                zeta_2;
  std::atomic<long>    *total_ops;
  std::atomic<long>    *total_reads;
  std::atomic<long>    *total_writes;
  std::atomic<long>    *total_hits;
  pid_t                 worker_tid;   /* filled in by worker after gettid() */
};

static void *worker_main(void *arg)
{
  WorkerCtx *ctx = (WorkerCtx *)arg;

  pin_to_cpu(ctx->cpu);
  ctx->worker_tid = gettid_safe();

  /* Register as a foreground worker with the v3 tracer (no-op on v2/v1).
   * Required when the tracer is launched with -trace_only_registered_workers 1
   * so RocksDB pthread-pool flush/compaction threads do not interfere
   * with workers' INTER_SKIP timing. The marker is benign on older
   * tracers and outside PIN. */
  champsim_register_worker();

  zipfian_t zipf;
  zipfian_init_precomputed(&zipf,
                           ctx->num_records,
                           ctx->alpha,
                           ctx->zeta_n,
                           ctx->zeta_2,
                           ctx->seed);

  /* Per-thread write-value buffer, randomised once. The value bytes the
   * tracer captures will reflect this content; randomising it deters
   * trivial value-prediction artifacts. */
  std::vector<char> wbuf(ctx->value_size);
  {
    std::mt19937 rng(ctx->seed ^ 0xABCDEF);
    for (int i = 0; i < ctx->value_size; i++)
      wbuf[i] = (char)('a' + (rng() % 26));
  }

  rocksdb::ReadOptions  ro;
  rocksdb::WriteOptions wo;
  wo.disableWAL = true;   /* no I/O serialisation noise; durability not
                             needed for an in-memory benchmark */

  std::mt19937 rwsel(ctx->seed ^ 0xBEEF1234);

  long ops = 0, reads = 0, writes = 0, hits = 0;
  char keybuf[32];

  /* Workers begin running as soon as they are spawned. The driver spawns
   * them BEFORE champsim_roi_begin() so they get a steady-state warmup
   * window of untraced execution. The PIN tracer keeps them in
   * WAITING_FOR_ROI until the marker fires, then transitions each thread
   * to TRACING on its next basic block. The loop terminates when the
   * deadline trips (typical) or when the soft op cap is reached. */

  /* Check the deadline every CHECK_EVERY ops to keep the bound tight
   * without paying for std::chrono on every iteration. */
  constexpr long CHECK_EVERY = 4096;

  while (ops < ctx->ops_cap) {
    if ((ops & (CHECK_EVERY - 1)) == 0) {
      if (std::chrono::steady_clock::now() >= ctx->deadline) break;
    }

    long key_id = zipfian_next(&zipf);
    format_key(keybuf, sizeof(keybuf), key_id);
    rocksdb::Slice key(keybuf, std::strlen(keybuf));

    int roll = (int)(rwsel() % 100);
    if (roll < ctx->read_pct) {
      std::string val;
      rocksdb::Status st = ctx->db->Get(ro, key, &val);
      reads++;
      if (st.ok()) hits++;
    } else {
      rocksdb::Slice val(wbuf.data(), ctx->value_size);
      ctx->db->Put(wo, key, val);
      writes++;
    }
    ops++;
  }

  ctx->total_ops->fetch_add(ops, std::memory_order_relaxed);
  ctx->total_reads->fetch_add(reads, std::memory_order_relaxed);
  ctx->total_writes->fetch_add(writes, std::memory_order_relaxed);
  ctx->total_hits->fetch_add(hits, std::memory_order_relaxed);
  return nullptr;
}

/* ============================================================== */
/* Phases                                                         */
/* ============================================================== */

static void phase_load(rocksdb::DB *db, const Args &a)
{
  std::fprintf(stderr, "[load] inserting %ld records of %d bytes...\n",
               a.num_records, a.value_size);
  /* v2 CHANGE (2026-09-05): values are DERIVED PER RECORD.
   *
   * v1 filled this buffer once and Put() the SAME bytes for every record,
   * so a -n 20000000 -v 1024 DB held 20 M byte-identical values. Snappy
   * compressed that duplication away (~21 GB logical -> 6.3-9.2 GB on disk),
   * which made DB size unpredictable from n*v and left the captured value
   * channel degenerate: with the QEMU plugin's values=on, every recorded
   * value would be the same letter soup. Neither is a workload anyone runs.
   *
   * Each record's bytes now come from a PRNG seeded by (seed, record id):
   * distinct per record, deterministic, reproducible from the seed. */
  std::vector<char> vbuf(a.value_size);
  unsigned char v2lut[256];
  for (int i = 0; i < 256; i++) v2lut[i] = (unsigned char)('a' + (i % 26));
  auto fill_value_for = [&](long id) {
    uint64_t x = ((uint64_t)a.seed * 0x9E3779B97F4A7C15ull)
               ^ ((uint64_t)id + 0x1010101ull);
    if (x == 0) x = 0x9E3779B97F4A7C15ull;
    int j = 0;
    while (j < a.value_size) {
      x ^= x << 13; x ^= x >> 7; x ^= x << 17;   /* xorshift64 */
      uint64_t w = x;
      for (int b = 0; b < 8 && j < a.value_size; b++, j++, w >>= 8)
        vbuf[j] = (char)v2lut[w & 0xFF];
    }
  };
  rocksdb::WriteOptions wo;
  wo.disableWAL = true;

  const long kBatch = 1000;
  rocksdb::WriteBatch wb;
  double t0   = now_secs();
  double tlog = t0;
  long   logged = 0;
  char   keybuf[32];

  for (long i = 1; i <= a.num_records; i++) {
    format_key(keybuf, sizeof(keybuf), i);
    fill_value_for(i);                    /* v2: distinct per record */
    rocksdb::Slice key(keybuf, std::strlen(keybuf));
    rocksdb::Slice val(vbuf.data(), a.value_size);
    wb.Put(key, val);
    if ((i % kBatch) == 0) {
      rocksdb::Status st = db->Write(wo, &wb);
      if (!st.ok()) {
        std::fprintf(stderr, "[fatal] WriteBatch failed: %s\n",
                     st.ToString().c_str());
        std::exit(3);
      }
      wb.Clear();
    }

    if ((i % 100000) == 0) {
      double t  = now_secs();
      double dt = t - tlog;
      double rate = (i - logged) / (dt > 0 ? dt : 1);
      std::fprintf(stderr,
                   "[load] %ld / %ld (%.1f%%) ops/s: %.0f\n",
                   i, a.num_records, 100.0 * (double)i / (double)a.num_records,
                   rate);
      tlog   = t;
      logged = i;
    }
  }
  if (wb.Count() > 0) {
    rocksdb::Status st = db->Write(wo, &wb);
    if (!st.ok()) {
      std::fprintf(stderr, "[fatal] final WriteBatch failed: %s\n",
                   st.ToString().c_str());
      std::exit(3);
    }
  }
  /* Flush any remaining memtable to L0 so the upcoming compaction sees it. */
  db->Flush(rocksdb::FlushOptions());

  std::fprintf(stderr, "[load] done in %.1fs\n", now_secs() - t0);
}

static void phase_compact(rocksdb::DB *db, const char *tag)
{
  std::fprintf(stderr, "[compact %s] running full CompactRange...\n", tag);
  double t0 = now_secs();
  rocksdb::CompactRangeOptions opts;
  rocksdb::Status st = db->CompactRange(opts, nullptr, nullptr);
  if (!st.ok()) {
    std::fprintf(stderr, "[fatal] CompactRange failed: %s\n",
                 st.ToString().c_str());
    std::exit(3);
  }
  wait_for_compaction(db);
  std::string l0 = get_prop(db, "rocksdb.num-files-at-level0");
  std::fprintf(stderr, "[compact %s] done in %.1fs. L0 files: %s\n",
               tag, now_secs() - t0, l0.c_str());
}

static void phase_warmup(rocksdb::DB *db,
                         std::shared_ptr<rocksdb::Statistics> stats,
                         const Args &a)
{
  std::fprintf(stderr, "[warmup] sequential scan of all %ld keys...\n",
               a.num_records);
  double t0 = now_secs();

  uint64_t hits_before   = stats->getTickerCount(rocksdb::BLOCK_CACHE_HIT);
  uint64_t misses_before = stats->getTickerCount(rocksdb::BLOCK_CACHE_MISS);

  rocksdb::ReadOptions ro;
  ro.fill_cache = true;
  std::unique_ptr<rocksdb::Iterator> it(db->NewIterator(ro));
  long n = 0;
  for (it->SeekToFirst(); it->Valid(); it->Next()) {
    /* touch value to force decompression into block cache */
    (void)it->value().size();
    n++;
    if ((n % 500000) == 0) {
      std::fprintf(stderr, "[warmup] scanned %ld / %ld\n", n, a.num_records);
    }
  }
  if (!it->status().ok()) {
    std::fprintf(stderr, "[fatal] iterator status: %s\n",
                 it->status().ToString().c_str());
    std::exit(3);
  }

  uint64_t hits_after   = stats->getTickerCount(rocksdb::BLOCK_CACHE_HIT);
  uint64_t misses_after = stats->getTickerCount(rocksdb::BLOCK_CACHE_MISS);
  uint64_t hits   = hits_after   - hits_before;
  uint64_t misses = misses_after - misses_before;
  double   total  = (double)(hits + misses);
  double   hr     = total > 0 ? 100.0 * (double)hits / total : 0.0;

  std::fprintf(stderr,
               "[warmup] scanned %ld in %.1fs. cache hit/miss = %llu / %llu (hr=%.1f%%)\n",
               n, now_secs() - t0,
               (unsigned long long)hits, (unsigned long long)misses, hr);
}

/* ============================================================== */
/* main                                                           */
/* ============================================================== */

int main(int argc, char **argv)
{
  Args a;
  if (!parse_args(argc, argv, a)) return 1;

  /* DB dir handling */
  if (fs::exists(a.db_path)) {
    if (a.overwrite) {
      std::fprintf(stderr, "[init] --overwrite: removing existing %s\n",
                   a.db_path.c_str());
      std::error_code ec;
      fs::remove_all(a.db_path, ec);
      if (ec) {
        std::fprintf(stderr, "[fatal] remove_all failed: %s\n", ec.message().c_str());
        return 2;
      }
    } else if (!fs::is_empty(a.db_path)) {
        if (!a.attach) {
          std::fprintf(stderr,
                       "[fatal] %s exists and is non-empty. Use --overwrite to wipe, "
                       "or --attach to reuse it.\n", a.db_path.c_str());
          return 2;
        }
        std::fprintf(stderr, "[init] --attach: reusing existing DB at %s\n",
                     a.db_path.c_str());
    }
  }
  fs::create_directories(a.db_path);

  /* RocksDB options */
  rocksdb::Options options;
  options.create_if_missing = true;
  options.IncreaseParallelism(a.num_threads);
  options.compression = rocksdb::kSnappyCompression;
  options.write_buffer_size       = 256 * 1024 * 1024;
  options.max_write_buffer_number = 4;
  options.statistics = rocksdb::CreateDBStatistics();

  rocksdb::BlockBasedTableOptions table_options;
  table_options.block_cache = rocksdb::NewLRUCache(
      (size_t)a.cache_gb * 1024ULL * 1024ULL * 1024ULL);
  table_options.filter_policy.reset(rocksdb::NewBloomFilterPolicy(10));
  options.table_factory.reset(
      rocksdb::NewBlockBasedTableFactory(table_options));

  rocksdb::DB *db = nullptr;
  rocksdb::Status st = rocksdb::DB::Open(options, a.db_path, &db);
  if (!st.ok()) {
    std::fprintf(stderr, "[fatal] DB::Open: %s\n", st.ToString().c_str());
    return 3;
  }

  /* ---- Phase 1: Load ---- */
  if (!a.attach) phase_load(db, a);
  else std::fprintf(stderr, "[load] skipped (--attach)\n");

  /* ---- Phase 2: Compact ---- */
  if (!a.no_compact && !a.attach) phase_compact(db, "post-load");

  /* ---- Phase 3: Warmup scan ---- */
  if (!a.no_warmup_scan) phase_warmup(db, options.statistics, a);

  /* ---- Phase 4: Compact again ---- */
  if (!a.no_compact && !a.no_warmup_scan) phase_compact(db, "post-warmup");

  /* ---- Phase 5: Disable auto-compaction ---- */
  st = db->SetOptions(db->DefaultColumnFamily(),
                      {{"disable_auto_compactions", "true"}});
  if (!st.ok()) {
    std::fprintf(stderr, "[fatal] SetOptions(disable_auto_compactions=true): %s\n",
                 st.ToString().c_str());
    return 3;
  }
  std::fprintf(stderr, "[roi] auto-compaction disabled. compaction-pending=%s\n",
               get_prop(db, "rocksdb.compaction-pending").c_str());

  /* ---- Phase 5b: Pre-touch SSTables into the OS page cache ---- */
  if (!a.no_fadvise) fadvise_willneed(a.db_path);

  /* ---- Phase 5c: Precompute zeta once and prep workers ---- */
  double zeta_n = 0.0, zeta_2 = 0.0;
  if (a.alpha > 0.0) {
    std::fprintf(stderr, "[roi] precomputing zeta(%ld, %.2f)...\n",
                 a.num_records, a.alpha);
    double tz = now_secs();
    zeta_n = zipfian_zeta(a.num_records, a.alpha);
    zeta_2 = zipfian_zeta(2, a.alpha);
    std::fprintf(stderr, "[roi] zeta done in %.1fs\n", now_secs() - tz);
  }

  long ops_cap_per_thread = a.roi_ops_cap / a.num_threads;
  if (ops_cap_per_thread < 1) ops_cap_per_thread = 1;

  /* The deadline is set at worker spawn time and covers the entire
   * untraced-warmup PLUS traced ROI window. champsim_roi_begin() fires
   * after warmup_secs of execution; workers exit when this deadline
   * trips, regardless of whether the tracer is still emitting records.
   * roi_secs is the post-warmup budget; the tracer's per-thread quota
   * will normally trip first. */
  auto deadline = std::chrono::steady_clock::now()
                + std::chrono::seconds(a.warmup_secs + a.roi_secs);

  std::atomic<long> total_ops{0}, total_reads{0}, total_writes{0}, total_hits{0};
  std::vector<WorkerCtx> ctxs(a.num_threads);
  std::vector<pthread_t> tids(a.num_threads);

  for (int i = 0; i < a.num_threads; i++) {
    ctxs[i].id            = i;
    ctxs[i].cpu           = a.cpus[i % a.cpus.size()];
    ctxs[i].db            = db;
    ctxs[i].ops_cap       = ops_cap_per_thread;
    ctxs[i].deadline      = deadline;
    ctxs[i].read_pct      = a.read_pct;
    ctxs[i].alpha         = a.alpha;
    ctxs[i].num_records   = a.num_records;
    ctxs[i].value_size    = a.value_size;
    ctxs[i].seed          = a.seed + (unsigned)i * 0x9E3779B9u;
    ctxs[i].zeta_n        = zeta_n;
    ctxs[i].zeta_2        = zeta_2;
    ctxs[i].total_ops     = &total_ops;
    ctxs[i].total_reads   = &total_reads;
    ctxs[i].total_writes  = &total_writes;
    ctxs[i].total_hits    = &total_hits;
    ctxs[i].worker_tid    = 0;

    int rc = pthread_create(&tids[i], nullptr, worker_main, &ctxs[i]);
    if (rc != 0) {
      std::fprintf(stderr, "[fatal] pthread_create %d: %s\n", i, std::strerror(rc));
      return 4;
    }
  }

  /* Wait briefly so worker_tid fields populate before we write the sidecar. */
  std::this_thread::sleep_for(std::chrono::milliseconds(200));

  {
    std::string sidecar = a.db_path + "/worker_tids.txt";
    FILE *fp = std::fopen(sidecar.c_str(), "w");
    if (!fp) {
      std::fprintf(stderr, "[warn] cannot open %s for writing\n", sidecar.c_str());
    } else {
      std::fprintf(fp, "# rocksdb_driver worker thread IDs (gettid)\n");
      std::fprintf(fp, "# main_tid=%d\n", (int)gettid_safe());
      for (int i = 0; i < a.num_threads; i++)
        std::fprintf(fp, "%d\n", (int)ctxs[i].worker_tid);
      std::fclose(fp);
      std::fprintf(stderr, "[roi] wrote worker tids to %s\n", sidecar.c_str());
    }
  }

  /* ---- Phase 5d: untraced steady-state warmup ---- */
  std::fprintf(stderr,
               "[warmup-roi] %d threads running Zipfian loop UNTRACED for %d s "
               "(read_pct=%d, alpha=%.2f) ...\n",
               a.num_threads, a.warmup_secs, a.read_pct, a.alpha);
  std::this_thread::sleep_for(std::chrono::seconds(a.warmup_secs));

  /* Sample block-cache miss counter just before the ROI to compute
   * a pre/post delta and verify memory residency. */
  uint64_t bc_miss_pre =
      options.statistics->getTickerCount(rocksdb::BLOCK_CACHE_MISS);
  uint64_t bc_data_miss_pre =
      options.statistics->getTickerCount(rocksdb::BLOCK_CACHE_DATA_MISS);
  uint64_t bc_hit_pre =
      options.statistics->getTickerCount(rocksdb::BLOCK_CACHE_HIT);

  /* ---- Phase 6: traced ROI window ---- */
  std::fprintf(stderr,
               "[roi] tracing ON. roi_secs=%d (workers exit at deadline)\n",
               a.roi_secs);
  champsim_roi_begin();

  for (int i = 0; i < a.num_threads; i++) pthread_join(tids[i], nullptr);

  champsim_roi_end();
  /* ---- end Phase 6 ---- */

  uint64_t bc_miss_post =
      options.statistics->getTickerCount(rocksdb::BLOCK_CACHE_MISS);
  uint64_t bc_data_miss_post =
      options.statistics->getTickerCount(rocksdb::BLOCK_CACHE_DATA_MISS);
  uint64_t bc_hit_post =
      options.statistics->getTickerCount(rocksdb::BLOCK_CACHE_HIT);

  std::fprintf(stderr,
               "[roi] complete. ops=%ld reads=%ld writes=%ld hits=%ld (%.1f%%)\n",
               total_ops.load(), total_reads.load(), total_writes.load(),
               total_hits.load(),
               total_reads.load()
                 ? 100.0 * (double)total_hits.load() / (double)total_reads.load()
                 : 0.0);

  uint64_t roi_hit  = bc_hit_post  - bc_hit_pre;
  uint64_t roi_miss = bc_miss_post - bc_miss_pre;
  uint64_t roi_data_miss = bc_data_miss_post - bc_data_miss_pre;
  double   roi_total = (double)(roi_hit + roi_miss);
  std::fprintf(stderr,
               "[roi] block-cache during ROI: hit=%llu miss=%llu data_miss=%llu hr=%.3f%%\n",
               (unsigned long long)roi_hit,
               (unsigned long long)roi_miss,
               (unsigned long long)roi_data_miss,
               roi_total > 0 ? 100.0 * (double)roi_hit / roi_total : 0.0);

  std::fprintf(stderr, "[stats] block-cache-hit  total = %llu\n",
               (unsigned long long)bc_hit_post);
  std::fprintf(stderr, "[stats] block-cache-miss total = %llu\n",
               (unsigned long long)bc_miss_post);

  /* ---- Phase 7: Cleanup ---- */
  st = db->EnableAutoCompaction(
      std::vector<rocksdb::ColumnFamilyHandle *>{db->DefaultColumnFamily()});
  if (!st.ok()) {
    std::fprintf(stderr, "[warn] EnableAutoCompaction: %s\n",
                 st.ToString().c_str());
  }
  delete db;
  std::fprintf(stderr, "[done] driver exit.\n");
  return 0;
}
