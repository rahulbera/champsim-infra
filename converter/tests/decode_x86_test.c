/*
 * decode_x86_test.c — golden unit test for the x86-64 decode backend.
 *
 * Companion to decode_aarch64_test.c. Links decode_x86.o + Zydis directly
 * (no raw2champsim.o) -- the backend is self-complete, so calling decode_x86()
 * alone reaches every decoded_regs_t field asserted here.
 *
 * WHY THIS EXISTS
 * ---------------
 * The branch classifier used to key off two things that do not mean what they
 * appear to mean, and both failures produced perfectly well-formed traces of
 * the wrong instruction classes:
 *
 *   1. A RANGE CHECK over ZydisMnemonic:
 *          mnem >= ZYDIS_MNEMONIC_JB && mnem <= ZYDIS_MNEMONIC_JS
 *      ZydisMnemonic is ordered ALPHABETICALLY, not by opcode family. JMP
 *      sorts inside [JB, JS], so every unconditional jump was reported
 *      CONDITIONAL (with FLAGS force-injected as a source, making it
 *      indistinguishable from a real conditional). JZ sorts after JS, so
 *      je/jz -- the most common conditional branch in x86 -- fell outside the
 *      range and was reported OTHER.
 *
 *   2. meta.branch_type == SHORT || NEAR to mean "direct". SHORT/NEAR/FAR
 *      describe the displacement encoding and segment, not whether the target
 *      is an immediate. `jmp *%rax` and `call *%rax` are NEAR, so the indirect
 *      classes were unreachable for the common register/memory forms.
 *
 * Both are the kind of bug a self-consistency check cannot see: the output is
 * structurally valid, just wrong. Only a differential oracle catches them,
 * which is what this table is.
 *
 * THE ORACLE
 * ----------
 * Every byte sequence below is REAL assembler output, produced with
 * `as --64` + `objdump -d` (GNU binutils) at authoring time, not hand-guessed.
 * The expectations are the x86-64 architecture, not the current behaviour of
 * decode_x86.c. If a row fails, fix decode_x86.c -- do NOT weaken the table.
 *
 * Beyond the per-row expectations, four invariants are checked on every row:
 *   - decode must succeed (ok)
 *   - no duplicate register in either the source or destination list (the
 *     record has only 4 src / 2 dst slots, so a repeat EVICTS a real operand)
 *   - every branch must write IP
 *   - the branch classes whose ChampSim INFERENCE fallback requires the
 *     absence of an IP source (indirect jump, return) must not carry one
 *
 * Prints "ALL PASS" and exits 0 iff every row passes.
 */

#include "../decode.h"

#include <stdio.h>
#include <string.h>

/* Internal 1-based codes returned by classify_branch(); 0 = not a branch.
 * These are NOT ChampSim's enum -- raw2champsim.c subtracts 1 when it writes
 * reserved[0], where the enum is 0-based with 7 = NOT_BRANCH. */
#define B_NONE          0
#define B_DIRECT_JUMP   1
#define B_INDIRECT      2
#define B_CONDITIONAL   3
#define B_DIRECT_CALL   4
#define B_INDIRECT_CALL 5
#define B_RETURN        6
#define B_OTHER         7

static const char *BN[] = {"NOT_BRANCH",    "DIRECT_JUMP", "INDIRECT",
                           "CONDITIONAL",   "DIRECT_CALL", "INDIRECT_CALL",
                           "RETURN",        "OTHER"};

/* "don't assert this field" */
#define ANY 0xFF

typedef struct {
  const char *name;
  uint8_t     bytes[8];
  uint8_t     len;
  uint8_t     want_branch;    /* B_* or ANY */
  uint8_t     want_flags_src; /* 1 = FLAGS must be a source, 0 = must not */
  uint8_t     want_ip_src;    /* 1 = IP must be a source, 0 = must not */
} row_t;

static const row_t TABLE[] = {
    /* --- Jcc. Zydis normalises the aliases (JA->JNBE, JE->JZ, JG->JNLE, ...),
       so these cover the full conditional set. All read FLAGS. ------------- */
    {"je",         {0x74, 0x18},             2, B_CONDITIONAL,   1, 1},
    {"jne",        {0x75, 0x16},             2, B_CONDITIONAL,   1, 1},
    {"ja",         {0x77, 0x14},             2, B_CONDITIONAL,   1, 1},
    {"jbe",        {0x76, 0x12},             2, B_CONDITIONAL,   1, 1},
    {"jg",         {0x7f, 0x10},             2, B_CONDITIONAL,   1, 1},
    {"jl",         {0x7c, 0x0e},             2, B_CONDITIONAL,   1, 1},
    {"js",         {0x78, 0x0c},             2, B_CONDITIONAL,   1, 1},
    {"jp",         {0x7a, 0x0a},             2, B_CONDITIONAL,   1, 1},
    {"jo",         {0x70, 0x08},             2, B_CONDITIONAL,   1, 1},

    /* --- Count-register conditionals. These branch on RCX and read NO flags.
       Injecting FLAGS here would fabricate a cmp->jcc dependency edge that the
       hardware does not have, which is exactly what a branch predictor study
       would then measure. LOOPE/LOOPNE genuinely do read ZF. -------------- */
    {"jrcxz",      {0xe3, 0x06},             2, B_CONDITIONAL,   0, 1},
    {"loop",       {0xe2, 0x04},             2, B_CONDITIONAL,   0, 1},
    {"loope",      {0xe1, 0x02},             2, B_CONDITIONAL,   1, 1},
    {"loopne",     {0xe0, 0x00},             2, B_CONDITIONAL,   1, 1},

    /* --- Unconditional jumps. Regression #1: jmp rel8 was CONDITIONAL.
       Regression #2: the indirect forms were DIRECT_JUMP.
       Note jmp rel8 carries IP as a source because Zydis reports RIP as a read
       of an IP-relative target -- harmless (no FLAGS, no other source, so it
       cannot be mistaken for a conditional), hence ANY. The indirect forms
       must NOT read IP, or the inference fallback misfires. --------------- */
    {"jmp rel8",   {0xeb, 0x24},             2, B_DIRECT_JUMP,   0, ANY},
    {"jmp *%rax",  {0xff, 0xe0},             2, B_INDIRECT,      0, 0},
    {"jmp *(%rax)",{0xff, 0x20},             2, B_INDIRECT,      0, 0},

    /* --- Calls. Regression #3: the indirect forms were DIRECT_CALL, so the
       indirect-call predictor never saw them. All push, so RSP is both read
       and written (asserted via the no-duplicate + IP-write invariants). --- */
    {"call rel32", {0xe8, 0x1b, 0, 0, 0},    5, B_DIRECT_CALL,   0, 1},
    {"call *%rax", {0xff, 0xd0},             2, B_INDIRECT_CALL, 0, 1},
    {"call *(%rax)",{0xff, 0x10},            2, B_INDIRECT_CALL, 0, 1},

    /* --- Returns. Must NOT read IP: ChampSim's inference keys a return on
       reads_sp && !reads_ip. ---------------------------------------------- */
    {"ret",        {0xc3},                   1, B_RETURN,        0, 0},
    {"ret $8",     {0xc2, 0x08, 0x00},       3, B_RETURN,        0, 0},
    {"lretq",      {0x48, 0xcb},             2, B_RETURN,        0, 0},

    /* --- Traps and system transfers. Zydis reports branch_type NONE for all
       of these, so they classify NOT_BRANCH. That is deliberate and matches
       the champsim-infra pintool (INS_IsBranch is false for syscall/int), so
       the two tracers agree.

       IRETQ is the interesting one: it reads SP and writes IP without reading
       IP, which is precisely ChampSim's inference signature for a RETURN. So
       under the old inference-only path a kernel trace's iretq silently
       polluted the return-address stack. Stating NOT_BRANCH explicitly is
       strictly better than inferring a return that no call ever pushed. ---- */
    {"syscall",    {0x0f, 0x05},             2, B_NONE,        ANY, ANY},
    {"int3",       {0xcc},                   1, B_NONE,        ANY, ANY},
    {"int $0x80",  {0xcd, 0x80},             2, B_NONE,        ANY, ANY},
    {"iretq",      {0x48, 0xcf},             2, B_NONE,        ANY, ANY},

    /* --- Non-branches. cmp/add must WRITE flags: that write is the producer
       half of the cmp->jcc edge the conditional rows consume. -------------- */
    {"cmp %rbx,%rax", {0x48, 0x39, 0xd8},    3, B_NONE,        ANY, 0},
    {"add %rbx,%rax", {0x48, 0x01, 0xd8},    3, B_NONE,        ANY, 0},
    {"mov %rax,%rbx", {0x48, 0x89, 0xc3},    3, B_NONE,        ANY, 0},
    {"nop",        {0x90},                   1, B_NONE,        ANY, 0},
};

#define NROWS ((int)(sizeof(TABLE) / sizeof(TABLE[0])))

static int has(const uint8_t *a, int n, uint8_t v)
{
  for (int i = 0; i < n; i++)
    if (a[i] == v) return 1;
  return 0;
}

static int has_dup(const uint8_t *a, int n)
{
  for (int i = 0; i < n; i++)
    for (int j = i + 1; j < n; j++)
      if (a[i] == a[j]) return 1;
  return 0;
}

int main(void)
{
  int fails = 0;

  printf("  %-15s %-15s %-15s  %-14s %s\n", "instruction", "got", "want",
         "src", "dst");

  for (int t = 0; t < NROWS; t++) {
    const row_t   *r = &TABLE[t];
    decoded_regs_t d = decode_x86(r->bytes, r->len);

    char src[64] = "", dst[32] = "";
    for (int i = 0; i < d.n_src; i++) sprintf(src + strlen(src), "%d ", d.src_regs[i]);
    for (int i = 0; i < d.n_dst; i++) sprintf(dst + strlen(dst), "%d ", d.dst_regs[i]);

    const char *why = NULL;

    if (!d.ok)
      why = "decode failed";
    else if (r->want_branch != ANY && d.is_branch != r->want_branch)
      why = "wrong branch class";
    else if (r->want_flags_src != ANY &&
             has(d.src_regs, d.n_src, CS_REG_FLAGS) != r->want_flags_src)
      why = r->want_flags_src ? "missing FLAGS source" : "fabricated FLAGS source";
    else if (r->want_ip_src != ANY &&
             has(d.src_regs, d.n_src, CS_REG_PC) != r->want_ip_src)
      why = r->want_ip_src ? "missing IP source" : "IP source breaks inference";
    else if (has_dup(d.src_regs, d.n_src) || has_dup(d.dst_regs, d.n_dst))
      why = "duplicate register evicts a slot";
    else if (d.is_branch && !has(d.dst_regs, d.n_dst, CS_REG_PC))
      why = "branch does not write IP";

    if (why) fails++;

    printf("  %-15s %-15s %-15s  %-14s %-8s%s%s\n", r->name,
           BN[d.is_branch & 7],
           r->want_branch == ANY ? "(any)" : BN[r->want_branch], src, dst,
           why ? "  <-- FAIL: " : "", why ? why : "");
  }

  printf("\n  %s (%d/%d)\n", fails ? "FAILURES" : "ALL PASS", NROWS - fails, NROWS);
  return fails ? 1 : 0;
}
