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
// The decompression backend is champsim/src/trace_reader.cc, linked in
// directly. That guarantees byte-for-byte parity with how the simulator
// itself walks the same files.
//
// Format is selected with --format {v1,v2,cloudsuite}, default v1.
// Record layouts mirror champsim/inc/instruction.h and are
// static_asserted to the canonical 64 / 512 / 96 byte sizes.

#include "trace_reader.h"

#include <array>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <unordered_set>

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
    "  -h, --help         Show this help.\n",
    prog);
}

bool parse_args(int argc, char** argv, Args& a) {
  enum { OPT_HEARTBEAT = 1000, OPT_NO_UNIQUE };
  static const option longopts[] = {
    {"input",     required_argument, nullptr, 'i'},
    {"format",    required_argument, nullptr, 'f'},
    {"heartbeat", required_argument, nullptr, OPT_HEARTBEAT},
    {"no-unique", no_argument,       nullptr, OPT_NO_UNIQUE},
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
      case 'h': usage(argv[0]); std::exit(0);
      default:  usage(argv[0]); return false;
    }
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
  }
}

}  // namespace

int main(int argc, char** argv) {
  Args a;
  if (!parse_args(argc, argv, a)) return 1;

  std::fprintf(stderr, "trace_sanity_check: %s  (format=%s)\n",
               a.input.c_str(), fmt_name(a.format));

  Stats  s;
  size_t record_size = 0;
  auto   t0          = std::chrono::steady_clock::now();
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
  } catch (const std::exception& e) {
    std::fprintf(stderr, "error: %s (after %lu records)\n",
                 e.what(), (unsigned long)s.records);
    return 1;
  }
  double sec = secs_since(t0);

  print_stats(a, s, sec, record_size);
  return 0;
}
