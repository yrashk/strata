/* The JIT's x86-64 backend (macOS, Linux; System V calling convention).
 *
 * x86-64 has too few registers to keep the guest's 31 in host registers,
 * so guest registers stay in Core.x[] and instructions work on them through
 * memory operands and a few scratch registers; an L1-resident operand costs
 * little next to the interpreter's decode and dispatch.
 *
 * Register use while translated code runs:
 *   rbx      the Core (guest registers at [rbx + x], the D-LS at [rbx + dls])
 *   r15      instret - limit: negative while the quantum lasts
 *   rax, rcx, rdx, rsi, rdi  scratch; at an exit eax = reason, rdx = pc,
 *            rcx = patch site
 * Stack frame of the trampoline: [rsp] limit, [rsp+8] the jalr table,
 * [rsp+16] where to store the patch site, then the saved registers.
 *
 * Exits work as in the arm64 backend: out-of-line stubs add the retired
 * instruction count to r15 and jump to the common exit or, once chained,
 * to the next block ("add r15, n; jmp next"). */
#if defined(__x86_64__)

#include <string.h>

#include "jit_be.h"
#include "../../asm/isa.h"

enum { RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15 };
enum { CTX = RBX, BUD = R15 };
enum { F_LIMIT = 0, F_TABLE = 8, F_SITE = 16, FRAME = 24 };
/* condition codes */
enum { CC_B = 2, CC_AE = 3, CC_E = 4, CC_NE = 5, CC_S = 8, CC_NS = 9, CC_L = 0xC, CC_GE = 0xD };

static JitLayout L;
static uint8_t *exit_common;
static JitBuf *B;

static uint8_t *cur(void) { return B->p; }
static void byte(unsigned v) { *B->p++ = (uint8_t)v; }
static void d32(int32_t v) {
  memcpy(B->p, &v, 4);
  B->p += 4;
}
static int32_t rel(const uint8_t *from, const uint8_t *to) { return (int32_t)(to - from); }

/* ---- encodings */

static void rex(int w, int reg, int index, int base) {
  unsigned r = 0x40 | (unsigned)w << 3 | (unsigned)(reg >> 3 & 1) << 2 | (unsigned)(index >= 0 ? index >> 3 & 1 : 0) << 1 |
               (unsigned)(base >> 3 & 1);
  if (r != 0x40) byte(r);
}
/* ModRM (+SIB) + disp32 for [base + index << sc + disp]; index < 0: none */
static void mem(int reg, int base, int index, int sc, int32_t disp) {
  if (index < 0 && (base & 7) != RSP) {
    byte(0x80 | (reg & 7) << 3 | (base & 7));
  } else {
    byte(0x84 | (reg & 7) << 3);
    byte((unsigned)sc << 6 | (index < 0 ? 4u : (unsigned)(index & 7)) << 3 | (base & 7));
  }
  d32(disp);
}
/* opcode bytes (1 or 2, after an optional 0x66 prefix) with a memory operand */
static void opm(bool p66, int w, unsigned op1, int op2, int reg, int base, int index, int sc, int32_t disp) {
  if (p66) byte(0x66);
  rex(w, reg, index, base);
  byte(op1);
  if (op2 >= 0) byte((unsigned)op2);
  mem(reg, base, index, sc, disp);
}
/* opcode with a register operand: op reg, rm */
static void opr(int w, unsigned op1, int op2, int reg, int rm) {
  rex(w, reg, -1, rm);
  byte(op1);
  if (op2 >= 0) byte((unsigned)op2);
  byte(0xC0 | (reg & 7) << 3 | (rm & 7));
}
enum { A_ADD = 0x01, A_OR = 0x09, A_AND = 0x21, A_SUB = 0x29, A_XOR = 0x31, A_CMP = 0x39, A_TEST = 0x85, A_MOV = 0x89 };
static void alurr(unsigned op, int dst, int src) { opr(1, op, -1, src, dst); } /* op dst, src */
/* group-1 op r/m64, imm32 (sign-extended): /0 add, /1 or, /4 and, /5 sub, /6 xor, /7 cmp */
static void alui(int digit, int r, int32_t imm) {
  opr(1, 0x81, -1, digit, r);
  d32(imm);
}
static void shcl(int digit, int r) { opr(1, 0xD3, -1, digit, r); } /* /4 shl, /5 shr, /7 sar */
static void shi(int digit, int r, int n) {
  opr(1, 0xC1, -1, digit, r);
  byte((unsigned)n);
}
static void f7(int digit, int r) { opr(1, 0xF7, -1, digit, r); } /* /3 neg, /4 mul, /6 div, /7 idiv */
static void movrr(int dst, int src) { alurr(A_MOV, dst, src); }
static void zero32(int r) { opr(0, 0x31, -1, r, r); }
static void testi(int32_t imm) { /* test rax, imm32 (sign-extended) */
  byte(0x48);
  byte(0xA9);
  d32(imm);
}
static void setcc_rax(int cc) { /* rax = cc ? 1 : 0 */
  byte(0x0F), byte(0x90 + (unsigned)cc), byte(0xC0);
  byte(0x0F), byte(0xB6), byte(0xC0);
}
static void movi(int r, uint64_t v) {
  if (v <= 0xffffffffu) { /* mov r32, imm32 zero-extends */
    rex(0, 0, -1, r);
    byte(0xB8 + (r & 7));
    d32((int32_t)(uint32_t)v);
  } else if ((int64_t)v == (int32_t)v) {
    opr(1, 0xC7, -1, 0, r);
    d32((int32_t)v);
  } else {
    rex(1, 0, -1, r);
    byte(0xB8 + (r & 7));
    memcpy(B->p, &v, 8);
    B->p += 8;
  }
}
static uint8_t *jcc32(int cc) { /* returns the rel32 field */
  byte(0x0F), byte(0x80 + (unsigned)cc);
  d32(0);
  return cur() - 4;
}
static uint8_t *jmp32(void) {
  byte(0xE9);
  d32(0);
  return cur() - 4;
}
static uint8_t *jcc8(int cc) {
  byte(0x70 + (unsigned)cc), byte(0);
  return cur() - 1;
}
static uint8_t *jmp8(void) {
  byte(0xEB), byte(0);
  return cur() - 1;
}
static void here8(uint8_t *f) { *f = (uint8_t)(cur() - (f + 1)); }
static void here32(uint8_t *f) {
  int32_t v = rel(f + 4, cur());
  memcpy(f, &v, 4);
}
static void jmpto(const uint8_t *t) {
  byte(0xE9);
  d32(rel(cur() + 4, t));
}

/* ---- guest registers */

static void ldg(int r, unsigned g) {
  if (!g) zero32(r);
  else opm(false, 1, 0x8B, -1, r, CTX, -1, 0, (int32_t)(L.x + 8 * g));
}
static void stg(unsigned g, int r) { opm(false, 1, 0x89, -1, r, CTX, -1, 0, (int32_t)(L.x + 8 * g)); }
static void stgi(unsigned g, int32_t imm) { /* mov qword [g], imm32 (sign-extended) */
  opm(false, 1, 0xC7, -1, 0, CTX, -1, 0, (int32_t)(L.x + 8 * g));
  d32(imm);
}

/* ---- exits */

enum { SK_LIMIT, SK_INTERP, SK_LINK };
typedef struct {
  uint8_t *site; /* the rel32 of the jump to this stub */
  int kind;
  uint64_t pc;
  unsigned count;
} Stub;
static Stub stubs[3 * 128 + 4];
static int nstubs;

static void to_stub(uint8_t *site, int kind, uint64_t pc, unsigned count) { stubs[nstubs++] = (Stub){site, kind, pc, count}; }

static void place_stubs(uint64_t bpc, uint8_t *entry) {
  for (int i = 0; i < nstubs; i++) {
    Stub *s = &stubs[i];
    here32(s->site);
    if (s->count) alui(0, BUD, (int32_t)s->count);
    if (s->kind == SK_LINK && s->pc == bpc) { jmpto(entry); continue; } /* a loop to itself */
    uint8_t *site = cur();
    if (s->kind == SK_LINK) jmp32(); /* the patch site: falls through to the exit until chained */
    movi(RDX, s->pc);
    if (s->kind == SK_LINK) { /* lea rcx, [rip + site] */
      byte(0x48), byte(0x8D), byte(0x0D);
      d32(rel(cur() + 4, site));
    }
    movi(RAX, s->kind == SK_LINK ? JX_LINK : s->kind == SK_LIMIT ? JX_LIMIT : JX_INTERP);
    jmpto(exit_common);
  }
}

/* ---- the trampoline */

JitEnter jit_be_tramp(JitBuf *b, const JitLayout *lay) {
  L = *lay;
  B = b;
  uint8_t *start = cur();
  /* enter(core rdi, code rsi, limit rdx, table rcx, site r8) */
  static const int saved[] = {RBP, RBX, R12, R13, R14, R15};
  for (int i = 0; i < 6; i++) {
    rex(0, 0, -1, saved[i]);
    byte(0x50 + (saved[i] & 7));
  }
  alui(5, RSP, FRAME);
  opm(false, 1, 0x89, -1, RDX, RSP, -1, 0, F_LIMIT);
  opm(false, 1, 0x89, -1, RCX, RSP, -1, 0, F_TABLE);
  opm(false, 1, 0x89, -1, R8, RSP, -1, 0, F_SITE);
  movrr(CTX, RDI);
  opm(false, 1, 0x8B, -1, BUD, CTX, -1, 0, (int32_t)L.instret);
  alurr(A_SUB, BUD, RDX);
  opr(0, 0xFF, -1, 4, RSI); /* jmp rsi */
  /* the common exit: eax = why, rdx = pc, rcx = patch site */
  exit_common = cur();
  opm(false, 1, 0x89, -1, RDX, CTX, -1, 0, (int32_t)L.pc);
  opm(false, 1, 0x03, -1, BUD, RSP, -1, 0, F_LIMIT); /* add r15, [rsp] */
  opm(false, 1, 0x89, -1, BUD, CTX, -1, 0, (int32_t)L.instret);
  opm(false, 1, 0x8B, -1, RDX, RSP, -1, 0, F_SITE);
  opm(false, 1, 0x89, -1, RCX, RDX, -1, 0, 0);
  alui(0, RSP, FRAME);
  for (int i = 5; i >= 0; i--) {
    rex(0, 0, -1, saved[i]);
    byte(0x58 + (saved[i] & 7));
  }
  byte(0xC3);
  return (JitEnter)(void *)start;
}

/* ---- one guest instruction */

static void insn(uint32_t ir, uint64_t pc, unsigned idx) {
  unsigned op = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31;
  unsigned imm16 = ir & 0xffff;
  int32_t simm = (int16_t)imm16;
  switch (op) {
  case OP_ALU: {
    if (!rd) break; /* no effect */
    unsigned f = ir & 15;
    ldg(RAX, rs1);
    ldg(RCX, rs2);
    switch (f) {
    case ALU_ADD: alurr(A_ADD, RAX, RCX); break;
    case ALU_SUB: alurr(A_SUB, RAX, RCX); break;
    case ALU_AND: alurr(A_AND, RAX, RCX); break;
    case ALU_OR: alurr(A_OR, RAX, RCX); break;
    case ALU_XOR: alurr(A_XOR, RAX, RCX); break;
    case ALU_SLL: shcl(4, RAX); break; /* the host also takes the count mod 64 */
    case ALU_SRL: shcl(5, RAX); break;
    case ALU_SRA: shcl(7, RAX); break;
    case ALU_SLT: alurr(A_CMP, RAX, RCX); setcc_rax(CC_L); break;
    case ALU_SLTU: alurr(A_CMP, RAX, RCX); setcc_rax(CC_B); break;
    case ALU_MUL: opr(1, 0x0F, 0xAF, RAX, RCX); break; /* imul rax, rcx */
    case ALU_MULHU: f7(4, RCX); movrr(RAX, RDX); break;
    /* The host faults on a zero divisor and on INT_MIN / -1; the ISA gives
     * ~0 (quotient) or a (remainder) for the first, and INT_MIN or 0 for
     * the second. */
    case ALU_DIVU: case ALU_REMU: {
      alurr(A_TEST, RCX, RCX);
      uint8_t *z = jcc8(CC_E);
      zero32(RDX);
      f7(6, RCX);
      if (f == ALU_REMU) movrr(RAX, RDX);
      uint8_t *done = jmp8();
      here8(z);
      if (f == ALU_DIVU) movi(RAX, ~0ull); /* REMU: rax is already a */
      here8(done);
      break;
    }
    case ALU_DIV: case ALU_REM: {
      alurr(A_TEST, RCX, RCX);
      uint8_t *z = jcc8(CC_E);
      alui(7, RCX, -1);
      uint8_t *norm = jcc8(CC_NE);
      if (f == ALU_DIV) f7(3, RAX); /* a / -1 = -a, INT_MIN stays */
      else zero32(RAX);             /* a % -1 = 0 */
      uint8_t *done1 = jmp8();
      here8(norm);
      byte(0x48), byte(0x99); /* cqo */
      f7(7, RCX);
      if (f == ALU_REM) movrr(RAX, RDX);
      uint8_t *done2 = jmp8();
      here8(z);
      if (f == ALU_DIV) movi(RAX, ~0ull); /* REM: rax is already a */
      here8(done1);
      here8(done2);
      break;
    }
    }
    stg(rd, RAX);
    break;
  }

  case OP_ADDI: case OP_SLTI: case OP_SLTIU: case OP_ANDI: case OP_ORI: case OP_XORI:
  case OP_SLLI: case OP_SRLI: case OP_SRAI:
    if (!rd) break;
    ldg(RAX, rs1);
    switch (op) {
    case OP_ADDI: if (simm) alui(0, RAX, simm); break;
    case OP_SLTI: alui(7, RAX, simm); setcc_rax(CC_L); break;
    case OP_SLTIU: alui(7, RAX, simm); setcc_rax(CC_B); break; /* against the sign-extended immediate */
    case OP_ANDI: alui(4, RAX, (int32_t)imm16); break;
    case OP_ORI: alui(1, RAX, (int32_t)imm16); break;
    case OP_XORI: alui(6, RAX, (int32_t)imm16); break;
    case OP_SLLI: if (imm16 & 63) shi(4, RAX, imm16 & 63); break;
    case OP_SRLI: if (imm16 & 63) shi(5, RAX, imm16 & 63); break;
    case OP_SRAI: if (imm16 & 63) shi(7, RAX, imm16 & 63); break;
    }
    stg(rd, RAX);
    break;
  case OP_LUI:
    if (rd) stgi(rd, (int32_t)((uint32_t)simm << 16)); /* sext(imm16) << 16 fits a signed imm32 */
    break;

  case OP_LD: case OP_LW: case OP_LWU: case OP_LH: case OP_LHU: case OP_LB: case OP_LBU:
  case OP_SD: case OP_SW: case OP_SH: case OP_SB: {
    bool store = op >= OP_SD;
    int lg = store ? 3 - (int)(op - OP_SD) : op == OP_LD ? 3 : op <= OP_LWU ? 2 : op <= OP_LHU ? 1 : 0;
    ldg(RAX, rs1);
    if (simm) alui(0, RAX, simm);
    /* in bounds and aligned iff no address bit outside [lg, log2 D-LS size) is set
     * (a 32-bit immediate, sign-extended: the size is at most 64 KiB) */
    testi((int32_t)(uint32_t)(~(L.dls_size - 1) | ((1u << lg) - 1)));
    to_stub(jcc32(CC_NE), SK_INTERP, pc, idx); /* the interpreter traps */
    int32_t dl = (int32_t)L.dls;
    if (store) {
      ldg(RCX, rd);
      switch (op) {
      case OP_SD: opm(false, 1, 0x89, -1, RCX, CTX, RAX, 0, dl); break;
      case OP_SW: opm(false, 0, 0x89, -1, RCX, CTX, RAX, 0, dl); break;
      case OP_SH: opm(true, 0, 0x89, -1, RCX, CTX, RAX, 0, dl); break;
      case OP_SB: opm(false, 0, 0x88, -1, RCX, CTX, RAX, 0, dl); break;
      }
    } else if (rd) {
      switch (op) {
      case OP_LD: opm(false, 1, 0x8B, -1, RCX, CTX, RAX, 0, dl); break;
      case OP_LW: opm(false, 1, 0x63, -1, RCX, CTX, RAX, 0, dl); break;   /* movsxd */
      case OP_LWU: opm(false, 0, 0x8B, -1, RCX, CTX, RAX, 0, dl); break;  /* mov r32 zero-extends */
      case OP_LH: opm(false, 1, 0x0F, 0xBF, RCX, CTX, RAX, 0, dl); break; /* movsx */
      case OP_LHU: opm(false, 0, 0x0F, 0xB7, RCX, CTX, RAX, 0, dl); break;
      case OP_LB: opm(false, 1, 0x0F, 0xBE, RCX, CTX, RAX, 0, dl); break;
      case OP_LBU: opm(false, 0, 0x0F, 0xB6, RCX, CTX, RAX, 0, dl); break;
      }
      stg(rd, RCX);
    }
    break;
  }

  case OP_BEQ: case OP_BNE: case OP_BLT: case OP_BGE: case OP_BLTU: case OP_BGEU: {
    static const int cc[6] = {CC_E, CC_NE, CC_L, CC_GE, CC_B, CC_AE};
    ldg(RAX, rd);
    ldg(RCX, rs1);
    alurr(A_CMP, RAX, RCX);
    to_stub(jcc32(cc[op - OP_BEQ]), SK_LINK, pc + ((uint64_t)(int64_t)simm << 2), idx + 1);
    break;
  }
  case OP_JAL: {
    if (rd) stgi(rd, (int32_t)(pc + 4));
    uint64_t off = (uint64_t)((int64_t)((uint64_t)(ir & 0x1fffff) << 43) >> 43) << 2;
    to_stub(jmp32(), SK_LINK, pc + off, idx + 1);
    break;
  }
  case OP_JALR: {
    /* the target first: rd may be rs1 */
    ldg(RAX, rs1);
    if (simm) alui(0, RAX, simm);
    alui(4, RAX, -4);
    if (rd) stgi(rd, (int32_t)(pc + 4));
    alui(0, BUD, (int32_t)(idx + 1));
    /* straight to the target's block if it has one (its entry checks the
     * quantum), else back to the dispatcher */
    testi((int32_t)(uint32_t)~(L.ils_size - 1)); /* inside the I-LS */
    uint8_t *m1 = jcc8(CC_NE);
    opm(false, 1, 0x8B, -1, RCX, RSP, -1, 0, F_TABLE);
    opm(false, 1, 0x8B, -1, RCX, RCX, RAX, 1, 0); /* 8-byte entries, one per 4-byte word */
    alurr(A_TEST, RCX, RCX);
    uint8_t *m2 = jcc8(CC_E);
    opr(0, 0xFF, -1, 4, RCX); /* jmp rcx */
    here8(m1);
    here8(m2);
    movrr(RDX, RAX);
    movi(RAX, JX_LOOKUP);
    jmpto(exit_common);
    break;
  }
  }
}

void *jit_be_block(JitBuf *b, uint64_t pc, const uint32_t *ir, int n, int tail) {
  B = b;
  nstubs = 0;
  uint8_t *entry = cur();
  alurr(A_TEST, BUD, BUD);
  to_stub(jcc32(CC_NS), SK_LIMIT, pc, 0); /* the quantum is used up */
  for (int i = 0; i < n; i++) insn(ir[i], pc + 4ull * (unsigned)i, (unsigned)i);
  unsigned last = ir[n - 1] >> 26;
  if (last != OP_JAL && last != OP_JALR)
    to_stub(jmp32(), tail == JT_NEXT_INTERP ? SK_INTERP : SK_LINK, pc + 4ull * (unsigned)n, (unsigned)n);
  place_stubs(pc, entry);
  return entry;
}

void jit_be_link(void *site, const void *target, uint8_t **lo, uint8_t **hi) {
  uint8_t *s = site;
  int32_t v = rel(s + 5, target);
  memcpy(s + 1, &v, 4);
  *lo = s;
  *hi = s + 5;
}

#endif
