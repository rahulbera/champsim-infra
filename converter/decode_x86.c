/*
 * decode_x86.c — x86 instruction decode (Zydis) -> ChampSim register sets
 *
 * Moved verbatim from raw2champsim.c as part of the AArch64 decode-module
 * split. Behavior must remain byte-identical to the pre-refactor inline
 * code: same operand iteration order, same WRITE-before-READ ordering,
 * same fixup_champsim_reg application, same base-before-index handling
 * (base skips RIP, index does not), same bound checks, and the same
 * FLAGS -> SP -> PC synthesis order.
 */

#include "decode.h"

#include <string.h>

#include <Zydis/Zydis.h>

/* ================================================================
 * x86 register mapping: Zydis register -> ChampSim register ID
 *
 * ChampSim uses uint8_t register IDs. We map x86 registers to a
 * compact ID space. Key registers:
 *   6  = RSP (REG_STACK_POINTER)
 *   25 = RFLAGS (REG_FLAGS)
 *   26 = RIP (REG_INSTRUCTION_POINTER)
 * ================================================================ */

static uint8_t map_zydis_register(ZydisRegister reg)
{
  /* Group: GPR 64-bit → IDs 1-16 */
  if (reg >= ZYDIS_REGISTER_RAX && reg <= ZYDIS_REGISTER_R15) {
    return (uint8_t)(reg - ZYDIS_REGISTER_RAX + 1);
    /* RAX=1, RCX=2, RDX=3, RBX=4, RSP=5, RBP=6, RSI=7, RDI=8, R8-R15=9-16 */
    /* Note: RSP maps to 5 here, but ChampSim expects RSP=6 */
  }

  /* Map 32-bit GPRs to their 64-bit counterparts */
  if (reg >= ZYDIS_REGISTER_EAX && reg <= ZYDIS_REGISTER_R15D) {
    return (uint8_t)(reg - ZYDIS_REGISTER_EAX + 1);
  }

  /* Map 16-bit GPRs */
  if (reg >= ZYDIS_REGISTER_AX && reg <= ZYDIS_REGISTER_R15W) {
    return (uint8_t)(reg - ZYDIS_REGISTER_AX + 1);
  }

  /* Map 8-bit GPRs (AL-R15B) */
  if (reg >= ZYDIS_REGISTER_AL && reg <= ZYDIS_REGISTER_R15B) {
    return (uint8_t)(reg - ZYDIS_REGISTER_AL + 1);
  }

  /* High-byte registers (AH, CH, DH, BH) */
  if (reg >= ZYDIS_REGISTER_AH && reg <= ZYDIS_REGISTER_BH) {
    return (uint8_t)(reg - ZYDIS_REGISTER_AH + 1);
  }

  /* RFLAGS */
  if (reg == ZYDIS_REGISTER_RFLAGS || reg == ZYDIS_REGISTER_FLAGS ||
      reg == ZYDIS_REGISTER_EFLAGS) {
    return 25; /* REG_FLAGS */
  }

  /* RIP */
  if (reg == ZYDIS_REGISTER_RIP || reg == ZYDIS_REGISTER_EIP ||
      reg == ZYDIS_REGISTER_IP) {
    return 26; /* REG_INSTRUCTION_POINTER */
  }

  /* RSP special case: ChampSim's REG_STACK_POINTER = 6 */
  /* In our mapping above, RSP gets 5 (RAX=1..RSP=5).
     ChampSim expects RSP=6. Let's fix this. */
  /* Actually, let's look at the Zydis register enum ordering.
     The mapping RAX=1,RCX=2,RDX=3,RBX=4,RSP=5 doesn't match ChampSim
     where RSP=6 has a special meaning (stack pointer detection).
     We'll apply a correction. */

  /* XMM/YMM/ZMM: IDs 32-63 */
  if (reg >= ZYDIS_REGISTER_XMM0 && reg <= ZYDIS_REGISTER_XMM31) {
    return (uint8_t)(32 + (reg - ZYDIS_REGISTER_XMM0));
  }
  if (reg >= ZYDIS_REGISTER_YMM0 && reg <= ZYDIS_REGISTER_YMM31) {
    return (uint8_t)(32 + (reg - ZYDIS_REGISTER_YMM0));
  }
  if (reg >= ZYDIS_REGISTER_ZMM0 && reg <= ZYDIS_REGISTER_ZMM31) {
    return (uint8_t)(32 + (reg - ZYDIS_REGISTER_ZMM0));
  }

  /* ST(0)-ST(7): FP registers, IDs 64-71 */
  if (reg >= ZYDIS_REGISTER_ST0 && reg <= ZYDIS_REGISTER_ST7) {
    return (uint8_t)(64 + (reg - ZYDIS_REGISTER_ST0));
  }

  /* MM0-MM7: MMX registers, IDs 72-79 */
  if (reg >= ZYDIS_REGISTER_MM0 && reg <= ZYDIS_REGISTER_MM7) {
    return (uint8_t)(72 + (reg - ZYDIS_REGISTER_MM0));
  }

  /* Segment registers, K-mask registers, etc: map to a generic ID */
  if (reg != ZYDIS_REGISTER_NONE) {
    return 80; /* generic "other register" */
  }

  return 0; /* no register */
}

/* Fix RSP mapping: Zydis RAX,RCX,RDX,RBX,RSP ordering gives RSP=5,
   but ChampSim needs RSP=6 for stack pointer detection.
   We'll apply a post-mapping fixup. */
static uint8_t fixup_champsim_reg(uint8_t reg_id)
{
  /* In our mapping: RAX=1,RCX=2,RDX=3,RBX=4,RSP=5,RBP=6,...
     ChampSim wants RSP=6. The simplest fix: swap 5 and 6. */
  if (reg_id == 5) return 6;  /* RSP -> 6 (REG_STACK_POINTER) */
  if (reg_id == 6) return 5;  /* RBP -> 5 */
  return reg_id;
}

/* ================================================================
 * Instruction type classification from Zydis
 * ================================================================ */

static uint8_t classify_instr_type(const ZydisDecodedInstruction *insn)
{
  ZydisISAExt ext = insn->meta.isa_ext;

  /* SIMD extensions */
  switch (ext) {
  case ZYDIS_ISA_EXT_SSE:
  case ZYDIS_ISA_EXT_SSE2:
  case ZYDIS_ISA_EXT_SSE3:
  case ZYDIS_ISA_EXT_SSSE3:
  case ZYDIS_ISA_EXT_SSE4:
  case ZYDIS_ISA_EXT_SSE4A:
  case ZYDIS_ISA_EXT_AVX:
  case ZYDIS_ISA_EXT_AVX2:
  case ZYDIS_ISA_EXT_AVX512EVEX:
  case ZYDIS_ISA_EXT_AVX512VEX:
    /* Could be FP or integer SIMD. Check category for FP. */
    break;
  default:
    break;
  }

  /* Check for x87 FP */
  if (ext == ZYDIS_ISA_EXT_X87) {
    return INSTR_TYPE_FP;
  }

  /* Check category for scalar FP (SSE/AVX scalar operations) */
  ZydisInstructionCategory cat = insn->meta.category;
  switch (cat) {
  case ZYDIS_CATEGORY_SSE:
  case ZYDIS_CATEGORY_AVX:
  case ZYDIS_CATEGORY_AVX2:
  case ZYDIS_CATEGORY_AVX512:
    return INSTR_TYPE_SIMD;

  case ZYDIS_CATEGORY_X87_ALU:
    return INSTR_TYPE_FP;

  default:
    break;
  }

  /* Fallback: check ISA extension for SIMD-family instructions */
  switch (ext) {
  case ZYDIS_ISA_EXT_SSE:
  case ZYDIS_ISA_EXT_SSE2:
  case ZYDIS_ISA_EXT_SSE3:
  case ZYDIS_ISA_EXT_SSSE3:
  case ZYDIS_ISA_EXT_SSE4:
  case ZYDIS_ISA_EXT_SSE4A:
  case ZYDIS_ISA_EXT_AVX:
  case ZYDIS_ISA_EXT_AVX2:
  case ZYDIS_ISA_EXT_AVX512EVEX:
  case ZYDIS_ISA_EXT_AVX512VEX:
    return INSTR_TYPE_SIMD;
  default:
    return INSTR_TYPE_INT;
  }
}

/* ================================================================
 * Branch classification
 * ================================================================ */

static bool is_branch_instruction(const ZydisDecodedInstruction *insn)
{
  switch (insn->meta.branch_type) {
  case ZYDIS_BRANCH_TYPE_NONE:
    return false;
  default:
    return true;
  }
}

/* Append with de-duplication.
 *
 * The record has only 4 source and 2 destination slots, so a repeated register
 * is not merely untidy -- it evicts a real one. Duplicates arise naturally
 * here: Zydis reports RSP as an explicit operand of CALL/RET *and* as the base
 * of the implicit [rsp] memory operand, and RIP is reported as written by a
 * branch before the synthesis step below appends it again. Before this, a
 * conditional branch emitted destination_registers = {26, 26}, consuming both
 * slots with the same register. */
static void add_reg(uint8_t *arr, int *n, int cap, uint8_t reg)
{
  if (reg == 0 || *n >= cap) return;
  for (int i = 0; i < *n; i++)
    if (arr[i] == reg) return;
  arr[(*n)++] = reg;
}

static uint8_t classify_branch(const ZydisDecodedInstruction *insn,
                               const ZydisDecodedOperand *ops)
{
  ZydisMnemonic mnem = insn->mnemonic;

  /* Conditional jumps.
   *
   * These are enumerated EXPLICITLY. The previous form was a range check,
   *     mnem >= ZYDIS_MNEMONIC_JB && mnem <= ZYDIS_MNEMONIC_JS
   * which is wrong because ZydisMnemonic is ordered ALPHABETICALLY, not by
   * opcode family: JB, JBE, JCXZ, JECXZ, JL, JLE, JMP, JNB, ..., JS, JZ.
   *   - JMP sorts INSIDE [JB, JS], so every unconditional jump was classified
   *     BRANCH_CONDITIONAL and had FLAGS force-injected as a source below,
   *     making it indistinguishable from a real conditional branch. The
   *     dedicated `if (mnem == ZYDIS_MNEMONIC_JMP)` block further down was
   *     therefore dead code.
   *   - JZ sorts AFTER JS, so je/jz -- the most common conditional branch in
   *     x86 -- fell out of the range entirely and was emitted as BRANCH_OTHER.
   *
   * Zydis normalises the aliases (JA->JNBE, JAE->JNB, JE->JZ, JNE->JNZ,
   * JG->JNLE, JGE->JNL, JNA->JBE, JNAE->JB, JNG->JLE, JNGE->JL), so this list
   * is the complete set of x86-64 Jcc forms.
   */
  switch (mnem) {
  case ZYDIS_MNEMONIC_JB:    case ZYDIS_MNEMONIC_JBE:
  case ZYDIS_MNEMONIC_JL:    case ZYDIS_MNEMONIC_JLE:
  case ZYDIS_MNEMONIC_JNB:   case ZYDIS_MNEMONIC_JNBE:
  case ZYDIS_MNEMONIC_JNL:   case ZYDIS_MNEMONIC_JNLE:
  case ZYDIS_MNEMONIC_JNO:   case ZYDIS_MNEMONIC_JNP:
  case ZYDIS_MNEMONIC_JNS:   case ZYDIS_MNEMONIC_JNZ:
  case ZYDIS_MNEMONIC_JO:    case ZYDIS_MNEMONIC_JP:
  case ZYDIS_MNEMONIC_JS:    case ZYDIS_MNEMONIC_JZ:
  /* Count-register conditionals: these read RCX/ECX/CX, not FLAGS. */
  case ZYDIS_MNEMONIC_JCXZ:  case ZYDIS_MNEMONIC_JECXZ:
  case ZYDIS_MNEMONIC_JRCXZ:
  /* LOOP variants: decrement RCX and branch on it (LOOPE/LOOPNE also read ZF). */
  case ZYDIS_MNEMONIC_LOOP:  case ZYDIS_MNEMONIC_LOOPE:
  case ZYDIS_MNEMONIC_LOOPNE:
    return 3; /* BRANCH_CONDITIONAL */
  default:
    break;
  }

  /* JMP / CALL: direct vs indirect is decided by the TARGET OPERAND, not by
   * meta.branch_type.
   *
   * The previous code tested `branch_type == SHORT || branch_type == NEAR`,
   * but SHORT/NEAR/FAR describe the *displacement encoding and segment*, not
   * whether the target is an immediate. `jmp *%rax` and `call *%rax` are both
   * NEAR, so both were classified as DIRECT -- the indirect classes were
   * unreachable for the common register/memory forms, and the return-address
   * stack and indirect predictor never saw them. (The old comment "will refine
   * below" pointed at a refinement that does not exist.)
   *
   * A direct branch has an IMMEDIATE target; register and memory targets are
   * indirect. */
  if (mnem == ZYDIS_MNEMONIC_JMP || mnem == ZYDIS_MNEMONIC_CALL) {
    bool direct = false;
    if (ops != NULL && insn->operand_count_visible > 0) {
      direct = (ops[0].type == ZYDIS_OPERAND_TYPE_IMMEDIATE);
    }
    if (mnem == ZYDIS_MNEMONIC_JMP) {
      return direct ? 1 /* BRANCH_DIRECT_JUMP */ : 2 /* BRANCH_INDIRECT */;
    }
    return direct ? 4 /* BRANCH_DIRECT_CALL */ : 5 /* BRANCH_INDIRECT_CALL */;
  }

  /* RET */
  if (mnem == ZYDIS_MNEMONIC_RET) {
    return 6; /* BRANCH_RETURN */
  }

  /* Other branches (INT, SYSCALL, etc.) */
  if (insn->meta.branch_type != ZYDIS_BRANCH_TYPE_NONE) {
    return 7; /* BRANCH_OTHER */
  }

  return 0; /* NOT_BRANCH */
}

/* ================================================================
 * decode_x86 — public entry point
 * ================================================================ */

decoded_regs_t decode_x86(const uint8_t *bytes, uint8_t size)
{
  static ZydisDecoder decoder;
  static bool         inited = false;
  if (!inited) {
    ZydisDecoderInit(&decoder, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);
    inited = true;
  }

  decoded_regs_t out;
  memset(&out, 0, sizeof(out));

  ZydisDecodedInstruction insn;
  ZydisDecodedOperand     operands[ZYDIS_MAX_OPERAND_COUNT];

  ZyanStatus status = ZydisDecoderDecodeFull(
    &decoder, bytes, size, &insn, operands);

  if (!ZYAN_SUCCESS(status)) {
    out.ok         = false;
    out.instr_type = INSTR_TYPE_INT;
    return out;
  }

  /* Branch classification */
  out.is_branch = is_branch_instruction(&insn) ? classify_branch(&insn, operands) : 0;

  /* Instruction type */
  out.instr_type = classify_instr_type(&insn);

  /* Extract registers from operands */
  int src_reg_idx = 0;
  int dst_reg_idx = 0;

  for (int i = 0; i < insn.operand_count; i++) {
    const ZydisDecodedOperand *op = &operands[i];

    /* Skip hidden/implicit memory operands for register extraction,
       but DO process implicit register operands */
    if (op->type == ZYDIS_OPERAND_TYPE_REGISTER) {
      uint8_t reg_id = map_zydis_register(op->reg.value);
      reg_id = fixup_champsim_reg(reg_id);

      if (reg_id == 0) continue;

      if (op->actions & ZYDIS_OPERAND_ACTION_MASK_WRITE)
        add_reg(out.dst_regs, &dst_reg_idx, NUM_INSTR_DESTINATIONS, reg_id);
      if (op->actions & ZYDIS_OPERAND_ACTION_MASK_READ)
        add_reg(out.src_regs, &src_reg_idx, NUM_INSTR_SOURCES, reg_id);
    } else if (op->type == ZYDIS_OPERAND_TYPE_MEMORY) {
      /* Extract base and index registers as source registers */
      if (op->mem.base != ZYDIS_REGISTER_NONE &&
          op->mem.base != ZYDIS_REGISTER_RIP) {
        uint8_t reg_id = map_zydis_register(op->mem.base);
        reg_id = fixup_champsim_reg(reg_id);
        add_reg(out.src_regs, &src_reg_idx, NUM_INSTR_SOURCES, reg_id);
      }
      if (op->mem.index != ZYDIS_REGISTER_NONE) {
        uint8_t reg_id = map_zydis_register(op->mem.index);
        reg_id = fixup_champsim_reg(reg_id);
        add_reg(out.src_regs, &src_reg_idx, NUM_INSTR_SOURCES, reg_id);
      }
    }
  }

  /* Ensure FLAGS is a source on conditional branches that actually test it.
     Zydis normally surfaces RFLAGS as a hidden read operand, so this is a
     safety net -- but it must NOT fire for the count-register conditionals
     (JCXZ/JECXZ/JRCXZ, LOOP), which branch on RCX and read no flags.
     Injecting FLAGS there would fabricate a dependency edge that the hardware
     does not have. LOOPE/LOOPNE do read ZF, so they keep the injection. */
  bool cond_reads_flags =
      (out.is_branch == 3) &&
      !(insn.mnemonic == ZYDIS_MNEMONIC_JCXZ  ||
        insn.mnemonic == ZYDIS_MNEMONIC_JECXZ ||
        insn.mnemonic == ZYDIS_MNEMONIC_JRCXZ ||
        insn.mnemonic == ZYDIS_MNEMONIC_LOOP);

  if (cond_reads_flags)
    add_reg(out.src_regs, &src_reg_idx, NUM_INSTR_SOURCES, CS_REG_FLAGS);

  /* For CALL/RET, ensure RSP is both source and destination */
  if (out.is_branch == 4 || out.is_branch == 5 || out.is_branch == 6) {
    /* CALL or RET modifies RSP */
    add_reg(out.src_regs, &src_reg_idx, NUM_INSTR_SOURCES, CS_REG_SP);
    add_reg(out.dst_regs, &dst_reg_idx, NUM_INSTR_DESTINATIONS, CS_REG_SP);
  }

  /* RIP as a SOURCE, for conditional branches and calls only.
   *
   * The branch type is now stated explicitly in the record (reserved[0]), so
   * ChampSim does not need to infer it. This exists so the INFERENCE FALLBACK
   * still agrees with the explicit type if the feature bit is ever lost --
   * ChampSim's cascade (inc/instruction.h) distinguishes the classes partly by
   * whether IP is read:
   *     conditional    : reads_ip && (reads_flags || reads_other)
   *     direct call    : reads_sp && reads_ip && !reads_other
   *     indirect call  : reads_sp && reads_ip && reads_other
   *     indirect jump  : !reads_ip && reads_other      <- must NOT read IP
   *     return         : reads_sp && !reads_ip         <- must NOT read IP
   * so IP is added for exactly types 3/4/5, and is NOT synthesised for the two
   * classes whose inference requires its absence. Verified by unit test: the
   * register/memory forms `jmp *%rax`, `jmp *(%rax)` and `ret` carry no IP
   * source, so the fallback still resolves them to INDIRECT and RETURN.
   *
   * Direct jumps are a don't-care rather than a withhold: Zydis reports RIP as
   * a read operand of a rel8/rel32 jump (the target is IP-relative), so `jmp
   * .L` arrives here already carrying IP as a source. That is harmless -- with
   * neither FLAGS nor another source it cannot be mistaken for a conditional,
   * and the cascade still lands on direct jump.
   *
   * Added last, so that under source slot pressure it is dropped before FLAGS,
   * which carries the real cmp -> jcc dependency edge. */
  if (out.is_branch == 3 || out.is_branch == 4 || out.is_branch == 5)
    add_reg(out.src_regs, &src_reg_idx, NUM_INSTR_SOURCES, CS_REG_PC);

  /* For branch instructions, RIP is a destination */
  if (out.is_branch)
    add_reg(out.dst_regs, &dst_reg_idx, NUM_INSTR_DESTINATIONS, CS_REG_PC);

  out.n_src = (uint8_t)src_reg_idx;
  out.n_dst = (uint8_t)dst_reg_idx;

  out.ok = true;
  return out;
}
