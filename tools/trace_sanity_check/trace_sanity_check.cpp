// trace_sanity_check.cpp
//
// Standalone sanity-check reader for ChampSim trace files.
//
// Reads a .gz / .xz / .zst trace, walks it record-by-record, and prints
// aggregate stats: instruction / branch / load / store counts, unique
// 4 KB pages touched by loads (with the resulting data footprint in MB),
// and (for v2 traces only) int/fp/simd split, user/kernel split, access
// size histograms, and PA-side load footprint.
//
// Compressed traces are read by piping through the system zstd / xz / gzip
// / bzip2 binaries, chosen by file extension. The tool therefore needs no
// ChampSim checkout and no compression libraries at build time, and the
// reference decompressors are themselves the parity reference.
//
// Format is selected with --format {v1,v2,cloudsuite}, default v1.
// Record layouts mirror champsim/inc/trace_instruction.h and are
// static_asserted to the canonical 64 / 512 / 96 byte sizes.
//
// With --check, the v2 branch-type invariants are enforced and the tool
// exits non-zero on failure, so it works as a CI gate on a fresh trace.

#include <algorithm>
#include <array>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <getopt.h>

namespace {

constexpr int      NUM_INSTR_DESTINATIONS       = 2;
constexpr int      NUM_INSTR_SOURCES            = 4;
constexpr int      NUM_INSTR_DESTINATIONS_SPARC = 4;
constexpr int      MAX_MEM_VALUE_SIZE           = 64;
constexpr int      PAGE_SHIFT                   = 12;
constexpr uint64_t PAGE_BYTES                   = 1ull << PAGE_SHIFT;
constexpr int      BLOCK_SHIFT                  = 6;
constexpr uint64_t BLOCK_BYTES                  = 1ull << BLOCK_SHIFT;

constexpr uint8_t  INSTR_TYPE_INT  = 0;
constexpr uint8_t  INSTR_TYPE_FP   = 1;
constexpr uint8_t  INSTR_TYPE_SIMD = 2;

// v2 reserved[] contract, written by the pintools. reserved[0] is
// ChampSim's branch_type enum; reserved[1] is a feature bitmask;
// reserved[2] names the tracer that produced the record.
constexpr int NUM_BRANCH_TYPES = 8;
const char* const BRANCH_TYPE_NAMES[NUM_BRANCH_TYPES] = {
  "DIRECT_JUMP", "INDIRECT", "CONDITIONAL", "DIRECT_CALL",
  "INDIRECT_CALL", "RETURN", "OTHER", "NOT_BRANCH"
};
constexpr uint8_t BT_DIRECT_JUMP   = 0;
constexpr uint8_t BT_INDIRECT      = 1;
constexpr uint8_t BT_CONDITIONAL   = 2;
constexpr uint8_t BT_DIRECT_CALL   = 3;
constexpr uint8_t BT_INDIRECT_CALL = 4;
constexpr uint8_t BT_RETURN        = 5;
constexpr uint8_t BT_NOT_BRANCH    = 7;

constexpr uint8_t TRACE_FEATURE_EXPLICIT_BRANCH_TYPE = 0x01;
constexpr uint8_t TRACE_FEATURE_FLAGS_REGISTER       = 0x02;

// Must match champsim::REG_FLAGS.
constexpr uint8_t REG_FLAGS = 25;

// A control transfer that is not a conditional branch is always taken.
inline bool is_unconditional_transfer(uint8_t bt) {
  return bt == BT_DIRECT_JUMP || bt == BT_INDIRECT
      || bt == BT_DIRECT_CALL || bt == BT_INDIRECT_CALL || bt == BT_RETURN;
}

// --- Record layouts (mirror champsim/inc/instruction.h) ---------------

struct input_instr_v1 {
  uint64_t ip;
  uint8_t  is_branch;
  uint8_t  branch_taken;
  uint8_t  destination_registers[NUM_INSTR_DESTINATIONS];
  uint8_t  source_registers[NUM_INSTR_SOURCES];
  uint64_t destination_memory[NUM_INSTR_DESTINATIONS];
  uint64_t source_memory[NUM_INSTR_SOURCES];
};
static_assert(sizeof(input_instr_v1) == 64, "input_instr_v1 must be 64 bytes");

struct __attribute__((packed)) input_instr_v2 {
  uint64_t ip;
  uint8_t  is_branch;
  uint8_t  branch_taken;
  uint8_t  destination_registers[NUM_INSTR_DESTINATIONS];
  uint8_t  source_registers[NUM_INSTR_SOURCES];
  uint64_t destination_memory[NUM_INSTR_DESTINATIONS];
  uint64_t source_memory[NUM_INSTR_SOURCES];
  uint64_t destination_memory_pa[NUM_INSTR_DESTINATIONS];
  uint64_t source_memory_pa[NUM_INSTR_SOURCES];
  uint8_t  source_memory_size[NUM_INSTR_SOURCES];
  uint8_t  destination_memory_size[NUM_INSTR_DESTINATIONS];
  uint8_t  privilege;
  uint8_t  instr_type;
  uint8_t  reserved[8];
  uint8_t  source_memory_value[NUM_INSTR_SOURCES][MAX_MEM_VALUE_SIZE];
  uint8_t  destination_memory_value[NUM_INSTR_DESTINATIONS][MAX_MEM_VALUE_SIZE];
};
static_assert(sizeof(input_instr_v2) == 512, "input_instr_v2 must be 512 bytes");

// Cloudsuite is NOT packed in champsim/inc/instruction.h, so it carries
// natural padding to 96 bytes. We mirror the same layout exactly.
struct cloudsuite_instr {
  uint64_t ip;
  uint8_t  is_branch;
  uint8_t  branch_taken;
  uint8_t  destination_registers[NUM_INSTR_DESTINATIONS_SPARC];
  uint8_t  source_registers[NUM_INSTR_SOURCES];
  uint64_t destination_memory[NUM_INSTR_DESTINATIONS_SPARC];
  uint64_t source_memory[NUM_INSTR_SOURCES];
  uint8_t  asid[2];
};
static_assert(sizeof(cloudsuite_instr) == 96, "cloudsuite_instr must be 96 bytes");

// --- Trace reader -----------------------------------------------------
//
// Decompression is delegated to the reference command-line tools, selected
// by file extension. This keeps the tool free of both a ChampSim checkout
// and any compression -dev packages, and it cannot disagree with the
// canonical decompressor because it *is* the canonical decompressor.

class TraceReader {
 public:
  explicit TraceReader(const std::string& path) {
    const char* decomp = nullptr;
    if      (ends_with(path, ".gz"))  decomp = "gzip -dc";
    else if (ends_with(path, ".xz"))  decomp = "xz -dc";
    else if (ends_with(path, ".zst")) decomp = "zstd -dcq";
    else if (ends_with(path, ".bz2")) decomp = "bzip2 -dc";

    if (decomp == nullptr) {
      fp_ = std::fopen(path.c_str(), "rb");
      if (fp_ == nullptr) throw std::runtime_error("cannot open " + path);
      return;
    }

    std::string cmd = std::string(decomp) + " " + shell_quote(path);
    fp_ = ::popen(cmd.c_str(), "r");
    if (fp_ == nullptr) throw std::runtime_error("cannot run: " + cmd);
    piped_ = true;
  }

  ~TraceReader() { finish(); }

  // Close the stream and report whether it ended cleanly. MUST be called after
  // the read loop and its result MUST be checked.
  //
  // A decompressor that dies mid-stream -- truncated .zst, bit rot, disk full,
  // SIGPIPE, OOM-killed -- simply stops producing bytes, which is byte-for-byte
  // indistinguishable from end-of-trace at the read() level. Discarding
  // pclose()'s status therefore turns half a trace into a "healthy short trace"
  // that sails through the acceptance checks. Returns 0 on a clean end.
  int finish() {
    if (fp_ == nullptr) return status_;
    if (read_error_) status_ = -1;
    if (piped_) {
      int st = ::pclose(fp_);
      if (st != 0 && status_ == 0) status_ = st;
    } else {
      if (std::fclose(fp_) != 0 && status_ == 0) status_ = -1;
    }
    fp_ = nullptr;
    return status_;
  }

  TraceReader(const TraceReader&)            = delete;
  TraceReader& operator=(const TraceReader&) = delete;

  // Read exactly one record. A short read at EOF ends the walk; a short
  // read of a PARTIAL record means the trace is truncated, which is worth
  // saying out loud rather than silently rounding down.
  bool read(void* dst, size_t n) {
    size_t got = std::fread(dst, 1, n, fp_);
    if (got == n) return true;
    if (got != 0) partial_bytes_ = got;
    if (std::ferror(fp_)) read_error_ = true;
    return false;
  }

  [[nodiscard]] size_t partial_bytes() const { return partial_bytes_; }

 private:
  static bool ends_with(const std::string& s, const char* suffix) {
    size_t n = std::strlen(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
  }

  static std::string shell_quote(const std::string& s) {
    std::string q = "'";
    for (char c : s) {
      if (c == '\'') q += "'\\''";
      else           q += c;
    }
    q += "'";
    return q;
  }

  std::FILE* fp_            = nullptr;
  bool       piped_         = false;
  size_t     partial_bytes_ = 0;
  bool       read_error_    = false;
  int        status_        = 0;
};

// --- CLI --------------------------------------------------------------

enum class Format { V1, V2, Cloudsuite };

const char* fmt_name(Format f) {
  switch (f) {
    case Format::V1:         return "v1";
    case Format::V2:         return "v2";
    case Format::Cloudsuite: return "cloudsuite";
  }
  return "?";
}

struct Args {
  std::string input;
  Format      format    = Format::V1;
  uint64_t    heartbeat = 10'000'000;
  bool        no_unique = false;
  bool        check     = false;
  bool        ind_targets = false;
  std::string ind_csv;
};

void usage(const char* prog) {
  std::fprintf(stderr,
    "Usage: %s -i <trace.{gz,xz,zst}> [-f v1|v2|cloudsuite]\n"
    "                            [--heartbeat N] [--no-unique]\n"
    "\n"
    "  -i, --input        Input trace path (.gz/.xz/.zst). Required.\n"
    "  -f, --format       Trace record format: v1 (64B), v2 (512B),\n"
    "                     cloudsuite (96B). Default: v1.\n"
    "      --heartbeat N  Progress report every N records (default 10M; 0=off).\n"
    "      --no-unique    Skip the unique-load-page set (saves RAM on huge traces).\n"
    "      --check        Enforce the v2 branch-type invariants and exit\n"
    "                     non-zero if any fails (CI gate). Requires -f v2.\n"
    "      --indirect-targets     Report the distribution of distinct targets\n"
    "                     per indirect branch (INDIRECT + INDIRECT_CALL).\n"
    "                     Requires -f v2. Costs memory proportional to the\n"
    "                     number of (indirect PC, target) pairs.\n"
    "      --indirect-csv F  With --indirect-targets, also write one row per\n"
    "                     indirect PC to F: pc,exec_count,unique_targets.\n"
    "  -h, --help         Show this help.\n",
    prog);
}

bool parse_args(int argc, char** argv, Args& a) {
  enum { OPT_HEARTBEAT = 1000, OPT_NO_UNIQUE, OPT_CHECK, OPT_IND_TARGETS, OPT_IND_CSV };
  static const option longopts[] = {
    {"input",     required_argument, nullptr, 'i'},
    {"format",    required_argument, nullptr, 'f'},
    {"heartbeat", required_argument, nullptr, OPT_HEARTBEAT},
    {"no-unique", no_argument,       nullptr, OPT_NO_UNIQUE},
    {"check",     no_argument,       nullptr, OPT_CHECK},
    {"indirect-targets", no_argument,       nullptr, OPT_IND_TARGETS},
    {"indirect-csv",     required_argument, nullptr, OPT_IND_CSV},
    {"help",      no_argument,       nullptr, 'h'},
    {nullptr, 0, nullptr, 0}
  };
  int c;
  while ((c = getopt_long(argc, argv, "i:f:h", longopts, nullptr)) != -1) {
    switch (c) {
      case 'i': a.input = optarg; break;
      case 'f': {
        std::string v = optarg;
        if      (v == "v1")                       a.format = Format::V1;
        else if (v == "v2")                       a.format = Format::V2;
        else if (v == "cloudsuite" || v == "cs")  a.format = Format::Cloudsuite;
        else { std::fprintf(stderr, "error: unknown format '%s'\n", optarg); return false; }
        break;
      }
      case OPT_HEARTBEAT: a.heartbeat = std::strtoull(optarg, nullptr, 10); break;
      case OPT_NO_UNIQUE: a.no_unique = true; break;
      case OPT_CHECK:     a.check     = true; break;
      case OPT_IND_TARGETS: a.ind_targets = true; break;
      case OPT_IND_CSV:     a.ind_csv = optarg; a.ind_targets = true; break;
      case 'h': usage(argv[0]); std::exit(0);
      default:  usage(argv[0]); return false;
    }
  }
  // Silently collecting nothing would produce an empty report that reads as
  // "this trace has no polymorphic indirect branches" -- a real finding shape.
  if (a.ind_targets && a.format != Format::V2) {
    std::fprintf(stderr, "error: --indirect-targets requires -f v2 "
                         "(branch type lives in v2's reserved[0])\n");
    return false;
  }
  if (a.input.empty()) {
    std::fprintf(stderr, "error: --input is required\n\n");
    usage(argv[0]);
    return false;
  }
  return true;
}

// --- Stats ------------------------------------------------------------

struct Stats {
  uint64_t records      = 0;
  uint64_t branch_inst  = 0;
  uint64_t taken_branch = 0;
  uint64_t load_inst    = 0;
  uint64_t store_inst   = 0;
  uint64_t load_ops     = 0;
  uint64_t store_ops    = 0;
  uint64_t reg_src_ops  = 0;
  uint64_t reg_dst_ops  = 0;

  std::unordered_set<uint64_t> load_va_pages;

  // Instruction footprint.
  uint64_t                     ip_min = UINT64_MAX;
  uint64_t                     ip_max = 0;
  std::unordered_set<uint64_t> unique_pcs;
  std::unordered_set<uint64_t> unique_ip_pages;          // ip >> PAGE_SHIFT
  std::unordered_set<uint64_t> unique_ip_blocks;         // ip >> BLOCK_SHIFT
  std::unordered_set<uint64_t> unique_branch_pcs;
  std::unordered_set<uint64_t> unique_taken_branch_pcs;
  std::unordered_set<uint64_t> unique_load_pcs;
  std::unordered_set<uint64_t> unique_store_pcs;

  // v2-only.
  bool                            v2          = false;
  uint64_t                        int_inst    = 0;
  uint64_t                        fp_inst     = 0;
  uint64_t                        simd_inst   = 0;
  uint64_t                        other_type  = 0;
  uint64_t                        user_inst   = 0;
  uint64_t                        kernel_inst = 0;
  std::array<uint64_t, 256>       load_size_hist  = {};
  std::array<uint64_t, 256>       store_size_hist = {};
  std::unordered_set<uint64_t>    load_pa_pages;

  // v2 branch-type accounting (reserved[0..2]).
  std::array<uint64_t, NUM_BRANCH_TYPES> btype_hist  = {};
  std::array<uint64_t, NUM_BRANCH_TYPES> btype_taken = {};
  uint64_t                  explicit_bt_records = 0;  // reserved[1] bit0 set
  uint64_t                  flags_feature_records = 0;
  uint64_t                  call_ret_not_flagged = 0;  // call/ret with is_branch==0
  std::array<bool, 256>     tracer_ids_seen = {};
  uint64_t                  flags_in_src = 0;
  uint64_t                  flags_in_dst = 0;

  // --- Indirect-target polymorphism (--indirect-targets) ---------------
  // Per indirect-branch PC: the set of distinct targets it ever jumps to,
  // and how many times it executed. A branch with one target is trivially
  // BTB-predictable; the interesting quantity is what fraction of the
  // DYNAMIC indirect stream comes from PCs with many targets.
  //
  // The target of an indirect branch is the IP of the NEXT retired record.
  // Nothing else in the trace names it, so this must be reconstructed by
  // carrying the pending branch PC across one iteration of the read loop.
  bool                                              want_ind_targets = false;
  std::unordered_map<uint64_t, std::unordered_set<uint64_t>> ind_targets;
  std::unordered_map<uint64_t, uint64_t>            ind_exec;
  uint64_t                                          ind_pending_pc = 0;
  bool                                              ind_pending    = false;
  uint64_t                                          ind_dangling   = 0;  // last record was an indirect branch
};

template <int NDST, int NSRC>
inline void update_common(Stats& s, uint64_t ip,
                          uint8_t is_branch, uint8_t branch_taken,
                          const uint64_t (&dst_mem)[NDST],
                          const uint64_t (&src_mem)[NSRC],
                          const uint8_t  (&dst_reg)[NDST],
                          const uint8_t  (&src_reg)[NSRC],
                          bool track_unique) {
  s.records++;
  if (is_branch) {
    s.branch_inst++;
    if (branch_taken) s.taken_branch++;
  }
  bool has_load = false, has_store = false;
  for (int i = 0; i < NDST; ++i) {
    if (dst_mem[i]) { s.store_ops++; has_store = true; }
    if (dst_reg[i])   s.reg_dst_ops++;
  }
  for (int i = 0; i < NSRC; ++i) {
    if (src_mem[i]) {
      s.load_ops++;
      has_load = true;
      if (track_unique) s.load_va_pages.insert(src_mem[i] >> PAGE_SHIFT);
    }
    if (src_reg[i]) s.reg_src_ops++;
  }
  if (has_load)  s.load_inst++;
  if (has_store) s.store_inst++;

  // Instruction footprint. Branch tracking is keyed on is_branch from the
  // record itself; an instruction may also be a load or store at the
  // same PC, so the PC sets are not mutually exclusive.
  if (ip < s.ip_min) s.ip_min = ip;
  if (ip > s.ip_max) s.ip_max = ip;
  if (track_unique) {
    s.unique_pcs.insert(ip);
    s.unique_ip_pages.insert(ip >> PAGE_SHIFT);
    s.unique_ip_blocks.insert(ip >> BLOCK_SHIFT);
    if (is_branch) {
      s.unique_branch_pcs.insert(ip);
      if (branch_taken) s.unique_taken_branch_pcs.insert(ip);
    }
    if (has_load)  s.unique_load_pcs.insert(ip);
    if (has_store) s.unique_store_pcs.insert(ip);
  }
}

double secs_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

void maybe_heartbeat(const Stats& s, uint64_t& next, uint64_t step,
                     std::chrono::steady_clock::time_point t0) {
  if (step == 0) return;
  while (s.records >= next) {
    double sec = secs_since(t0);
    std::fprintf(stderr,
                 "[heartbeat] %lu records  %.2f Mrec/s  elapsed %.1fs\n",
                 (unsigned long)s.records,
                 sec > 0 ? (double)s.records / sec / 1e6 : 0.0, sec);
    next += step;
  }
}

// --- Per-format read loops --------------------------------------------

void run_v1(TraceReader& tr, const Args& a, Stats& s) {
  input_instr_v1 r;
  auto     t0      = std::chrono::steady_clock::now();
  uint64_t next_hb = a.heartbeat;
  while (tr.read(&r, sizeof(r))) {
    update_common(s, r.ip, r.is_branch, r.branch_taken,
                  r.destination_memory, r.source_memory,
                  r.destination_registers, r.source_registers,
                  !a.no_unique);
    maybe_heartbeat(s, next_hb, a.heartbeat, t0);
  }
}

void run_v2(TraceReader& tr, const Args& a, Stats& s) {
  input_instr_v2 r;
  s.v2 = true;
  s.want_ind_targets = a.ind_targets;
  auto     t0      = std::chrono::steady_clock::now();
  uint64_t next_hb = a.heartbeat;
  while (tr.read(&r, sizeof(r))) {
    update_common(s, r.ip, r.is_branch, r.branch_taken,
                  r.destination_memory, r.source_memory,
                  r.destination_registers, r.source_registers,
                  !a.no_unique);
    switch (r.instr_type) {
      case INSTR_TYPE_INT:  s.int_inst++;   break;
      case INSTR_TYPE_FP:   s.fp_inst++;    break;
      case INSTR_TYPE_SIMD: s.simd_inst++;  break;
      default:              s.other_type++; break;
    }
    if (r.privilege) s.kernel_inst++;
    else             s.user_inst++;

    // reserved[0..2]: explicit branch type, feature bitmask, tracer id.
    // Old traces have these all zero, which reads as branch_type =
    // DIRECT_JUMP with the feature bit clear -- that is exactly why the
    // feature bit exists, and why the checks below key off it.
    uint8_t bt = r.reserved[0];
    if (bt < NUM_BRANCH_TYPES) {
      s.btype_hist[bt]++;
      if (r.branch_taken) s.btype_taken[bt]++;
    }

    // Indirect-target polymorphism. Resolve the PREVIOUS record's pending
    // indirect branch against this record's IP -- the target is only knowable
    // one record later. Done before arming a new pending PC, so that two
    // consecutive indirect branches resolve correctly rather than the first
    // being silently overwritten and lost.
    if (s.want_ind_targets) {
      if (s.ind_pending) {
        s.ind_targets[s.ind_pending_pc].insert(r.ip);
        s.ind_pending = false;
      }
      if (bt == BT_INDIRECT || bt == BT_INDIRECT_CALL) {
        s.ind_exec[r.ip]++;
        s.ind_pending_pc = r.ip;
        s.ind_pending    = true;
      }
    }
    if (r.reserved[1] & TRACE_FEATURE_EXPLICIT_BRANCH_TYPE) s.explicit_bt_records++;
    if (r.reserved[1] & TRACE_FEATURE_FLAGS_REGISTER)       s.flags_feature_records++;
    s.tracer_ids_seen[r.reserved[2]] = true;

    if ((bt == BT_DIRECT_CALL || bt == BT_INDIRECT_CALL || bt == BT_RETURN)
        && !r.is_branch) {
      s.call_ret_not_flagged++;
    }

    for (int i = 0; i < NUM_INSTR_SOURCES; ++i) {
      if (r.source_registers[i] == REG_FLAGS) { s.flags_in_src++; break; }
    }
    for (int i = 0; i < NUM_INSTR_DESTINATIONS; ++i) {
      if (r.destination_registers[i] == REG_FLAGS) { s.flags_in_dst++; break; }
    }
    for (int i = 0; i < NUM_INSTR_SOURCES; ++i) {
      if (r.source_memory[i]) {
        s.load_size_hist[r.source_memory_size[i]]++;
        if (!a.no_unique && r.source_memory_pa[i]) {
          s.load_pa_pages.insert(r.source_memory_pa[i] >> PAGE_SHIFT);
        }
      }
    }
    for (int i = 0; i < NUM_INSTR_DESTINATIONS; ++i) {
      if (r.destination_memory[i]) {
        s.store_size_hist[r.destination_memory_size[i]]++;
      }
    }
    maybe_heartbeat(s, next_hb, a.heartbeat, t0);
  }
  // The final record can be an indirect branch whose target the trace never
  // names. Record it rather than leaving a silently unresolved pending PC.
  if (s.ind_pending) { s.ind_dangling++; s.ind_pending = false; }
}

void run_cs(TraceReader& tr, const Args& a, Stats& s) {
  cloudsuite_instr r;
  auto     t0      = std::chrono::steady_clock::now();
  uint64_t next_hb = a.heartbeat;
  while (tr.read(&r, sizeof(r))) {
    update_common(s, r.ip, r.is_branch, r.branch_taken,
                  r.destination_memory, r.source_memory,
                  r.destination_registers, r.source_registers,
                  !a.no_unique);
    maybe_heartbeat(s, next_hb, a.heartbeat, t0);
  }
}

// --- Reporting --------------------------------------------------------

void print_count(const char* label, uint64_t n) {
  std::printf("  %-28s %20" PRIu64 "\n", label, n);
}

void print_pct(const char* label, uint64_t n, uint64_t total) {
  double p = total ? 100.0 * static_cast<double>(n) / static_cast<double>(total) : 0.0;
  std::printf("  %-28s %20" PRIu64 "  (%6.2f%%)\n", label, n, p);
}

// --- Indirect-target polymorphism report ------------------------------
//
// Two views of the same data, and they answer different questions:
//
//   STATIC  -- one vote per indirect branch PC. Describes the code.
//   DYNAMIC -- weighted by execution count. Describes the branch stream a
//              predictor actually sees, and is the one that matters: a single
//              hot 40-target dispatch jump is a prediction problem, while ten
//              thousand cold monomorphic call sites are not.
//
// A branch with exactly one distinct target is trivially BTB-predictable, so
// the headline is the DYNAMIC share coming from PCs with >1 target.
void report_indirect_targets(const Stats& s) {
  std::printf("\n-- v2: indirect-branch target polymorphism --\n");

  if (s.ind_exec.empty()) {
    std::printf("  (no INDIRECT or INDIRECT_CALL records in this trace)\n");
    return;
  }

  // Buckets are open-ended at the top: a dispatch loop with hundreds of
  // targets must not be summarised into the same cell as one with nine.
  struct Bucket { const char* name; uint64_t lo, hi; };
  static const Bucket BUCKETS[] = {
    {"1 (monomorphic)", 1, 1},       {"2",      2, 2},
    {"3-4",             3, 4},       {"5-8",    5, 8},
    {"9-16",            9, 16},      {"17-32", 17, 32},
    {"33-64",          33, 64},      {"65-256",65, 256},
    {"257+",          257, UINT64_MAX},
  };
  constexpr int NB = sizeof(BUCKETS) / sizeof(BUCKETS[0]);

  uint64_t stat_n[NB] = {}, dyn_n[NB] = {};
  uint64_t total_pcs = 0, total_exec = 0, mono_exec = 0, mono_pcs = 0;
  uint64_t sum_targets = 0, max_targets = 0, max_targets_pc = 0;
  double   dyn_weighted_targets = 0.0;
  std::vector<uint64_t> per_pc_targets;
  per_pc_targets.reserve(s.ind_exec.size());

  for (const auto& kv : s.ind_exec) {
    uint64_t pc = kv.first, exec = kv.second;
    auto it = s.ind_targets.find(pc);
    // A PC can execute yet have no recorded target only if it was the very
    // last record in the trace; count it, do not silently drop it.
    uint64_t nt = (it == s.ind_targets.end()) ? 0 : it->second.size();
    if (nt == 0) continue;
    total_pcs++; total_exec += exec; sum_targets += nt;
    per_pc_targets.push_back(nt);
    dyn_weighted_targets += static_cast<double>(nt) * static_cast<double>(exec);
    if (nt > max_targets) { max_targets = nt; max_targets_pc = pc; }
    if (nt == 1) { mono_pcs++; mono_exec += exec; }
    for (int b = 0; b < NB; ++b) {
      if (nt >= BUCKETS[b].lo && nt <= BUCKETS[b].hi) { stat_n[b]++; dyn_n[b] += exec; break; }
    }
  }
  if (total_pcs == 0) {
    std::printf("  (no indirect branch had a resolvable target)\n");
    return;
  }

  std::sort(per_pc_targets.begin(), per_pc_targets.end());
  uint64_t median = per_pc_targets[per_pc_targets.size() / 2];

  std::printf("  indirect branch PCs (static)            %14" PRIu64 "\n", total_pcs);
  std::printf("  indirect executions (dynamic)           %14" PRIu64 "\n", total_exec);
  std::printf("  distinct targets, mean per PC (static)  %14.2f\n",
              static_cast<double>(sum_targets) / static_cast<double>(total_pcs));
  std::printf("  distinct targets, median per PC (static)%14" PRIu64 "\n", median);
  std::printf("  distinct targets, exec-weighted mean    %14.2f   <-- what the predictor sees\n",
              dyn_weighted_targets / static_cast<double>(total_exec));
  std::printf("  most polymorphic PC                     %14" PRIu64 " targets at 0x%" PRIx64 "\n",
              max_targets, max_targets_pc);
  std::printf("  MONOMORPHIC (1 target): %6.2f%% of PCs, %6.2f%% of executions\n",
              100.0 * static_cast<double>(mono_pcs)  / static_cast<double>(total_pcs),
              100.0 * static_cast<double>(mono_exec) / static_cast<double>(total_exec));
  std::printf("  POLYMORPHIC (>1):       %6.2f%% of PCs, %6.2f%% of executions\n",
              100.0 * static_cast<double>(total_pcs - mono_pcs) / static_cast<double>(total_pcs),
              100.0 * static_cast<double>(total_exec - mono_exec) / static_cast<double>(total_exec));

  std::printf("\n  %-18s %12s %8s %14s %8s\n",
              "distinct targets", "PCs", "% PCs", "executions", "% exec");
  for (int b = 0; b < NB; ++b) {
    if (stat_n[b] == 0 && dyn_n[b] == 0) continue;
    std::printf("  %-18s %12" PRIu64 " %7.2f%% %14" PRIu64 " %7.2f%%\n",
                BUCKETS[b].name, stat_n[b],
                100.0 * static_cast<double>(stat_n[b]) / static_cast<double>(total_pcs),
                dyn_n[b],
                100.0 * static_cast<double>(dyn_n[b]) / static_cast<double>(total_exec));
  }
  if (s.ind_dangling) {
    std::printf("  note: %" PRIu64 " indirect branch(es) ended the trace with no successor "
                "record, so their target is unknown and they are excluded.\n", s.ind_dangling);
  }
}

void write_indirect_csv(const Stats& s, const std::string& path) {
  std::FILE* f = std::fopen(path.c_str(), "w");
  if (!f) {
    std::fprintf(stderr, "warning: cannot write --indirect-csv '%s'\n", path.c_str());
    return;
  }
  std::fprintf(f, "pc,exec_count,unique_targets\n");
  for (const auto& kv : s.ind_exec) {
    auto it = s.ind_targets.find(kv.first);
    std::fprintf(f, "0x%" PRIx64 ",%" PRIu64 ",%zu\n", kv.first, kv.second,
                 it == s.ind_targets.end() ? size_t{0} : it->second.size());
  }
  std::fclose(f);
  std::fprintf(stderr, "wrote per-PC indirect targets to %s\n", path.c_str());
}

void print_stats(const Args& a, const Stats& s, double sec, size_t record_size) {
  std::printf("\n==== trace_sanity_check ====\n");
  std::printf("input:        %s\n", a.input.c_str());
  std::printf("format:       %s (record size = %zu bytes)\n",
              fmt_name(a.format), record_size);
  std::printf("elapsed:      %.2f s\n", sec);
  if (sec > 0 && s.records > 0) {
    std::printf("throughput:   %.2f Mrec/s  %.1f MiB/s (uncompressed)\n",
                static_cast<double>(s.records) / sec / 1e6,
                static_cast<double>(s.records * record_size) / sec
                  / (1024.0 * 1024.0));
  }

  std::printf("\n-- Counts --\n");
  print_count("total instructions",  s.records);
  print_pct  ("branch instructions", s.branch_inst,  s.records);
  print_pct  ("  taken branches",    s.taken_branch, s.branch_inst);
  print_pct  ("load instructions",   s.load_inst,    s.records);
  print_pct  ("store instructions",  s.store_inst,   s.records);
  print_count("total load ops",      s.load_ops);
  print_count("total store ops",     s.store_ops);
  print_count("total reg src ops",   s.reg_src_ops);
  print_count("total reg dst ops",   s.reg_dst_ops);
  if (s.records) {
    std::printf("  %-28s %20.3f\n", "avg load ops / inst",
                static_cast<double>(s.load_ops) / static_cast<double>(s.records));
    std::printf("  %-28s %20.3f\n", "avg store ops / inst",
                static_cast<double>(s.store_ops) / static_cast<double>(s.records));
  }

  if (!a.no_unique) {
    uint64_t pages = s.load_va_pages.size();
    double   mb    = static_cast<double>(pages) * PAGE_BYTES / (1024.0 * 1024.0);
    std::printf("\n-- Load footprint (VA, 4KB pages) --\n");
    print_count("unique 4KB pages", pages);
    std::printf("  %-28s %20.2f MB\n", "data footprint", mb);
  }

  std::printf("\n-- Instruction footprint --\n");
  if (s.records) {
    std::printf("  %-28s         0x%016" PRIx64 "\n", "IP min", s.ip_min);
    std::printf("  %-28s         0x%016" PRIx64 "\n", "IP max", s.ip_max);
    uint64_t range = s.ip_max - s.ip_min;
    std::printf("  %-28s %20" PRIu64 "  (%.2f MB)\n",
                "IP range (max - min)", range,
                static_cast<double>(range) / (1024.0 * 1024.0));
  }
  if (!a.no_unique) {
    uint64_t blocks = s.unique_ip_blocks.size();
    uint64_t ipages = s.unique_ip_pages.size();
    print_count("unique PCs",          s.unique_pcs.size());
    print_count("unique I-blocks (64B)", blocks);
    std::printf("  %-28s %20.2f KB  (I-cache working set)\n",
                "I-block footprint",
                static_cast<double>(blocks) * BLOCK_BYTES / 1024.0);
    print_count("unique I-pages (4KB)", ipages);
    std::printf("  %-28s %20.2f MB  (I-TLB working set)\n",
                "I-page footprint",
                static_cast<double>(ipages) * PAGE_BYTES / (1024.0 * 1024.0));
    print_count("unique branch PCs",        s.unique_branch_pcs.size());
    print_count("unique taken-branch PCs",  s.unique_taken_branch_pcs.size());
    print_count("unique load PCs",          s.unique_load_pcs.size());
    print_count("unique store PCs",         s.unique_store_pcs.size());
  } else {
    std::printf("  (--no-unique set: skipping per-PC unique-set stats)\n");
  }

  if (s.v2) {
    std::printf("\n-- v2: instruction type --\n");
    print_pct("INT",   s.int_inst,   s.records);
    print_pct("FP",    s.fp_inst,    s.records);
    print_pct("SIMD",  s.simd_inst,  s.records);
    print_pct("other", s.other_type, s.records);

    std::printf("\n-- v2: privilege --\n");
    print_pct("user",   s.user_inst,   s.records);
    print_pct("kernel", s.kernel_inst, s.records);

    if (!a.no_unique) {
      uint64_t pa_pages = s.load_pa_pages.size();
      double   mb       = static_cast<double>(pa_pages) * PAGE_BYTES
                          / (1024.0 * 1024.0);
      std::printf("\n-- v2: load footprint (PA, 4KB pages) --\n");
      print_count("unique PA 4KB pages", pa_pages);
      std::printf("  %-28s %20.2f MB\n", "PA data footprint", mb);
    }

    std::printf("\n-- v2: load access-size histogram (bytes) --\n");
    for (int i = 0; i < 256; ++i) {
      if (s.load_size_hist[i]) {
        std::printf("  size=%-3d  count=%" PRIu64 "\n",
                    i, s.load_size_hist[i]);
      }
    }
    std::printf("\n-- v2: store access-size histogram (bytes) --\n");
    for (int i = 0; i < 256; ++i) {
      if (s.store_size_hist[i]) {
        std::printf("  size=%-3d  count=%" PRIu64 "\n",
                    i, s.store_size_hist[i]);
      }
    }

    if (s.want_ind_targets) report_indirect_targets(s);

    std::printf("\n-- v2: branch type (reserved[0]) --\n");
    if (s.explicit_bt_records == 0) {
      std::printf("  (no record carries the explicit-branch-type feature bit;\n"
                  "   this trace predates the tracer fix, so the column below is\n"
                  "   just zeroed reserved bytes read as DIRECT_JUMP)\n");
    }
    uint64_t branches = s.records - s.btype_hist[BT_NOT_BRANCH];
    for (int i = 0; i < NUM_BRANCH_TYPES; ++i) {
      if (s.btype_hist[i] == 0) continue;
      double share = branches ? 100.0 * static_cast<double>(s.btype_hist[i])
                                     / static_cast<double>(branches) : 0.0;
      double taken = s.btype_hist[i]
                       ? 100.0 * static_cast<double>(s.btype_taken[i])
                               / static_cast<double>(s.btype_hist[i]) : 0.0;
      std::printf("  %-14s %14" PRIu64 "  (%6.2f%% of branches, %6.2f%% taken)\n",
                  BRANCH_TYPE_NAMES[i], s.btype_hist[i],
                  i == BT_NOT_BRANCH ? 0.0 : share, taken);
    }
    print_count("control transfers", branches);

    std::printf("\n-- v2: record features (reserved[1..2]) --\n");
    print_pct("explicit branch type", s.explicit_bt_records, s.records);
    print_pct("flags register recorded", s.flags_feature_records, s.records);
    print_pct("records w/ FLAGS in src", s.flags_in_src, s.records);
    print_pct("records w/ FLAGS in dst", s.flags_in_dst, s.records);
    std::printf("  %-28s ", "tracer identity");
    bool any_id = false;
    for (int i = 0; i < 256; ++i) {
      if (!s.tracer_ids_seen[i]) continue;
      std::printf("%s%d", any_id ? ", " : "", i);
      any_id = true;
    }
    std::printf("%s\n", any_id ? "" : "(none)");
  }
}

// --- Acceptance checks ------------------------------------------------
//
// Invariants a trace carrying explicit branch types must satisfy. Returns
// the number of FAILED checks, so main() can exit non-zero as a CI gate.

int run_checks(const Stats& s) {
  int failures = 0;
  auto report = [&](bool ok, const char* name, const std::string& detail) {
    std::printf("  [%s] %-38s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
    if (!ok) failures++;
  };
  auto pct = [](uint64_t n, uint64_t d) {
    return d ? 100.0 * static_cast<double>(n) / static_cast<double>(d) : 0.0;
  };
  char buf[256];

  std::printf("\n==== acceptance checks ====\n");

  if (!s.v2) {
    std::printf("  --check applies to v2 traces only (use -f v2)\n");
    return 1;
  }

  // 1. Every record must declare the feature, or nothing below is meaningful.
  std::snprintf(buf, sizeof(buf), "%" PRIu64 " of %" PRIu64 " records",
                s.explicit_bt_records, s.records);
  report(s.records > 0 && s.explicit_bt_records == s.records,
         "explicit branch type on every record", buf);

  // 2. The field must actually vary; a constant column means it is not
  //    being written (all-zero reserved reads as a valid DIRECT_JUMP).
  int distinct = 0;
  for (int i = 0; i < NUM_BRANCH_TYPES; ++i) {
    if (s.btype_hist[i]) distinct++;
  }
  std::snprintf(buf, sizeof(buf), "%d distinct values present", distinct);
  report(distinct >= 2, "branch type spans multiple values", buf);

  // 3. THE check that would have caught the original bug: conditional
  //    branches must exist and must not be uniformly taken or not-taken.
  double cond_taken = pct(s.btype_taken[BT_CONDITIONAL], s.btype_hist[BT_CONDITIONAL]);
  std::snprintf(buf, sizeof(buf), "%" PRIu64 " conditionals, %.2f%% taken",
                s.btype_hist[BT_CONDITIONAL], cond_taken);
  report(s.btype_hist[BT_CONDITIONAL] > 0 && cond_taken > 0.0 && cond_taken < 100.0,
         "conditional taken rate strictly in (0,100)", buf);

  // 4. Unconditional transfers are taken by definition.
  uint64_t uncond = 0, uncond_taken = 0;
  for (int i = 0; i < NUM_BRANCH_TYPES; ++i) {
    if (!is_unconditional_transfer(static_cast<uint8_t>(i))) continue;
    uncond       += s.btype_hist[i];
    uncond_taken += s.btype_taken[i];
  }
  std::snprintf(buf, sizeof(buf), "%" PRIu64 " of %" PRIu64 " taken (%.2f%%)",
                uncond_taken, uncond, pct(uncond_taken, uncond));
  report(uncond > 0 && uncond_taken == uncond,
         "unconditional transfers are 100% taken", buf);

  // 5. Calls and returns must be flagged as control transfers.
  std::snprintf(buf, sizeof(buf), "%" PRIu64 " call/ret records with is_branch=0",
                s.call_ret_not_flagged);
  report(s.call_ret_not_flagged == 0, "calls and returns have is_branch=1", buf);

  // 6. Flags must reach the record, or ChampSim cannot build the
  //    cmp -> jcc dependency edge even with branch types correct.
  std::snprintf(buf, sizeof(buf), "src %.2f%%, dst %.2f%% of records",
                pct(s.flags_in_src, s.records), pct(s.flags_in_dst, s.records));
  report(s.flags_in_src > 0 && s.flags_in_dst > 0,
         "flags register present on both sides", buf);

  // Informational: workload-dependent, so not a gate.
  uint64_t branches = s.records - s.btype_hist[BT_NOT_BRANCH];
  std::printf("  [INFO] %-38s %.2f%% (typical integer workload: 60-85%%)\n",
              "conditional share of branches",
              pct(s.btype_hist[BT_CONDITIONAL], branches));

  std::printf("\n%s (%d failed)\n",
              failures ? "ACCEPTANCE CHECKS FAILED" : "all acceptance checks passed",
              failures);
  return failures;
}

}  // namespace

int main(int argc, char** argv) {
  Args a;
  if (!parse_args(argc, argv, a)) return 1;

  std::fprintf(stderr, "trace_sanity_check: %s  (format=%s)\n",
               a.input.c_str(), fmt_name(a.format));

  Stats  s;
  size_t record_size   = 0;
  size_t partial_bytes = 0;
  int    stream_status = 0;
  auto   t0            = std::chrono::steady_clock::now();
  try {
    TraceReader tr(a.input);
    if (a.format == Format::V1) {
      record_size = sizeof(input_instr_v1);
      run_v1(tr, a, s);
    } else if (a.format == Format::V2) {
      record_size = sizeof(input_instr_v2);
      run_v2(tr, a, s);
    } else {
      record_size = sizeof(cloudsuite_instr);
      run_cs(tr, a, s);
    }
    partial_bytes = tr.partial_bytes();
    stream_status = tr.finish();
  } catch (const std::exception& e) {
    std::fprintf(stderr, "error: %s (after %lu records)\n",
                 e.what(), (unsigned long)s.records);
    return 1;
  }
  double sec = secs_since(t0);

  print_stats(a, s, sec, record_size);
  if (a.ind_targets && !a.ind_csv.empty()) write_indirect_csv(s, a.ind_csv);

  if (partial_bytes != 0) {
    std::fprintf(stderr,
                 "warning: trailing %zu bytes are not a whole %zu-byte record "
                 "-- trace is truncated or the format is wrong\n",
                 partial_bytes, record_size);
  }
  if (s.records == 0) {
    std::fprintf(stderr, "error: no records read\n");
    return 1;
  }

  // A failed decompressor looks exactly like end-of-trace, so this must be a
  // hard failure -- otherwise half a trace passes the acceptance gate.
  if (stream_status != 0) {
    std::fprintf(stderr,
                 "error: input stream did not end cleanly (decompressor status %d) "
                 "after %lu records -- the trace is truncated or corrupt. "
                 "Statistics above describe only the part that was readable.\n",
                 stream_status, (unsigned long)s.records);
    return 1;
  }
  if (partial_bytes != 0) {
    std::fprintf(stderr, "error: trailing partial record -- refusing to certify\n");
    return 1;
  }

  if (a.check) return run_checks(s) == 0 ? 0 : 2;
  return 0;
}
