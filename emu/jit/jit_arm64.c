/* The JIT's arm64 backend (Apple Silicon macOS, Linux).
 *
 * Register use while translated code runs:
 *   x0-x2    scratch (x0 = exit reason, x1 = exit pc, x2 = patch site at an exit)
 *   x19      the Core
 *   x20      the core's D-LS
 *   x21      instret - limit: negative while the quantum lasts
 *   24 guest registers in x3-x17 and x22-x30 (gmap); the other 7, the
 *   least used ones in the programs we have, stay in Core.x[] and go
 *   through the scratch registers.
 * x18 (the platform register) is never touched. The trampoline saves the
 * callee-saved registers; translated code never calls anything, so the
 * caller-saved ones are free for guest state.
 *
 * Stack frame of the trampoline (translated code runs inside it):
 *   [sp+0..95] saved x19-x30, [sp+96] limit, [sp+104] the jalr table,
 *   [sp+112] where to store the patch site.
 *
 * Exits: every way out of a block is an out-of-line stub that adds the
 * block's retired instruction count to x21 and then either branches to
 * the trampoline's common exit, or (once chained) straight to the next
 * block. A conditional branch's taken path and a block's fall-through end
 * are such stubs; a chained stub is "add x21, x21, #n; b next_block". */
#if defined(__aarch64__)

#include <string.h>

#include "jit_be.h"
#include "../../asm/isa.h"

enum { S0 = 0, S1 = 1, S2 = 2, CTX = 19, DLS = 20, BUD = 21, ZR = 31, SP = 31 };
enum { F_LIMIT = 96, F_TABLE = 104, F_SITE = 112, FRAME = 128 };
enum { C_EQ = 0, C_NE = 1, C_HS = 2, C_LO = 3, C_GE = 10, C_LT = 11 };

/* guest register -> host register (0: kept in memory) */
static const uint8_t gmap[32] = {
    [1] = 3,   [2] = 4,   [5] = 5,   [6] = 6,   [7] = 7,   [8] = 8,   [9] = 9,   [10] = 10,
    [11] = 11, [12] = 12, [13] = 13, [14] = 14, [15] = 15, [18] = 16, [19] = 17, [20] = 22,
    [21] = 23, [22] = 24, [25] = 25, [26] = 26, [28] = 27, [29] = 28, [30] = 29, [31] = 30,
};

static JitLayout L;
static uint32_t *exit_common;
static JitBuf *B;

static uint32_t *cur(void) { return (uint32_t *)B->p; }
static void emit(uint32_t w) {
  memcpy(B->p, &w, 4);
  B->p += 4;
}
static int32_t dist(const void *from, const void *to) { return (int32_t)((const uint8_t *)to - (const uint8_t *)from); }

/* ---- encodings (64-bit forms) */
static uint32_t ADDr(int d, int n, int m) { return 0x8B000000u | m << 16 | n << 5 | d; }
static uint32_t ADDlsl(int d, int n, int m, int sh) { return 0x8B000000u | m << 16 | sh << 10 | n << 5 | d; }
static uint32_t SUBr(int d, int n, int m) { return 0xCB000000u | m << 16 | n << 5 | d; }
static uint32_t ADDi(int d, int n, unsigned imm) { return 0x91000000u | imm << 10 | n << 5 | d; }
static uint32_t SUBi(int d, int n, unsigned imm) { return 0xD1000000u | imm << 10 | n << 5 | d; }
static uint32_t CMPr(int n, int m) { return 0xEB000000u | m << 16 | n << 5 | 31; }
static uint32_t ANDr(int d, int n, int m) { return 0x8A000000u | m << 16 | n << 5 | d; }
static uint32_t ORRr(int d, int n, int m) { return 0xAA000000u | m << 16 | n << 5 | d; }
static uint32_t EORr(int d, int n, int m) { return 0xCA000000u | m << 16 | n << 5 | d; }
static uint32_t MOVr(int d, int m) { return ORRr(d, ZR, m); }
static uint32_t DP2(uint32_t op, int d, int n, int m) { return op | m << 16 | n << 5 | d; }
enum { LSLV = 0x9AC02000u, LSRV = 0x9AC02400u, ASRV = 0x9AC02800u, UDIV = 0x9AC00800u, SDIV = 0x9AC00C00u };
static uint32_t MADD(int d, int n, int m, int a) { return 0x9B000000u | m << 16 | a << 10 | n << 5 | d; }
static uint32_t MSUB(int d, int n, int m, int a) { return 0x9B008000u | m << 16 | a << 10 | n << 5 | d; }
static uint32_t UMULH(int d, int n, int m) { return 0x9BC00000u | m << 16 | 31 << 10 | n << 5 | d; }
static uint32_t CSET(int d, int c) { return 0x9A9F07E0u | (unsigned)(c ^ 1) << 12 | d; }
static uint32_t CSINV(int d, int n, int m, int c) { return 0xDA800000u | m << 16 | c << 12 | n << 5 | d; }
static uint32_t MOVZ(int d, unsigned imm, int hw) { return 0xD2800000u | hw << 21 | imm << 5 | d; }
static uint32_t MOVK(int d, unsigned imm, int hw) { return 0xF2800000u | hw << 21 | imm << 5 | d; }
static uint32_t MOVN(int d, unsigned imm, int hw) { return 0x92800000u | hw << 21 | imm << 5 | d; }
static uint32_t UBFM(int d, int n, int r, int s) { return 0xD3400000u | r << 16 | s << 10 | n << 5 | d; }
static uint32_t SBFM(int d, int n, int r, int s) { return 0x93400000u | r << 16 | s << 10 | n << 5 | d; }
static uint32_t LDRui(int t, int n, size_t off) { return 0xF9400000u | (uint32_t)(off / 8) << 10 | n << 5 | t; }
static uint32_t STRui(int t, int n, size_t off) { return 0xF9000000u | (uint32_t)(off / 8) << 10 | n << 5 | t; }
static uint32_t STP(int a, int b, int n, int off) { return 0xA9000000u | (uint32_t)((off / 8) & 0x7f) << 15 | b << 10 | n << 5 | a; }
static uint32_t LDP(int a, int b, int n, int off) { return 0xA9400000u | (uint32_t)((off / 8) & 0x7f) << 15 | b << 10 | n << 5 | a; }
static uint32_t STPpre(int a, int b, int n, int off) { return 0xA9800000u | (uint32_t)((off / 8) & 0x7f) << 15 | b << 10 | n << 5 | a; }
static uint32_t LDPpost(int a, int b, int n, int off) { return 0xA8C00000u | (uint32_t)((off / 8) & 0x7f) << 15 | b << 10 | n << 5 | a; }
static uint32_t Bto(int32_t off) { return 0x14000000u | ((uint32_t)(off >> 2) & 0x3ffffff); }
static uint32_t Bcond(int32_t off, int c) { return 0x54000000u | ((uint32_t)(off >> 2) & 0x7ffff) << 5 | c; }
static uint32_t CBZ(int t, int32_t off) { return 0xB4000000u | ((uint32_t)(off >> 2) & 0x7ffff) << 5 | t; }
static uint32_t TBZ(int t, int bit, int32_t off) {
  return 0x36000000u | (uint32_t)(bit >> 5) << 31 | (uint32_t)(bit & 31) << 19 | ((uint32_t)(off >> 2) & 0x3fff) << 5 | t;
}
static uint32_t BR(int n) { return 0xD61F0000u | n << 5; }
static uint32_t ADR(int d, int32_t off) { return 0x10000000u | ((uint32_t)off & 3) << 29 | ((uint32_t)(off >> 2) & 0x7ffff) << 5 | d; }
enum { RET = 0xD65F03C0u };
/* logical immediates: AND, ORR, EOR, ANDS (TST with d = 31) */
enum { ANDi = 0x92000000u, ORRi = 0xB2000000u, EORi = 0xD2000000u, ANDSi = 0xF2000000u };

/* Load/store with a register offset ([n, m]): the opcode words. */
enum {
  LDRX = 0xF8606800u, LDRW = 0xB8606800u, LDRSW = 0xB8A06800u, LDRH = 0x78606800u, LDRSH = 0x78A06800u,
  LDRB = 0x38606800u, LDRSB = 0x38A06800u, STRX = 0xF8206800u, STRW = 0xB8206800u, STRH = 0x78206800u,
  STRB = 0x38206800u,
};
static uint32_t LSr(uint32_t op, int t, int n, int m) { return op | m << 16 | n << 5 | t; }

/* The N:immr:imms field of a logical immediate, or false if v has none
 * (v must be a rotated run of ones repeated in 2..64-bit elements). */
static bool bitmask(uint64_t v, uint32_t *enc) {
  if (v == 0 || v == ~0ull) return false;
  unsigned size = 64;
  for (unsigned s = 2; s < 64; s *= 2)
    if (v == ((v >> s) | (v << (64 - s)))) { size = s; break; }
  uint64_t mask = size == 64 ? ~0ull : (1ull << size) - 1, e = v & mask;
  unsigned ones = (unsigned)__builtin_popcountll(e);
  uint64_t run = (1ull << ones) - 1; /* ones < size <= 64 */
  for (unsigned r = 0; r < size; r++) {
    uint64_t rot = r ? ((e >> r) | (e << (size - r))) & mask : e;
    if (rot == run) {
      unsigned immr = (size - r) % size, imms = ((~(size - 1) << 1) & 0x3f) | (ones - 1);
      *enc = (size == 64 ? 1u << 22 : 0) | immr << 16 | imms << 10;
      return true;
    }
  }
  return false;
}

/* Puts a 64-bit constant in a register in as few instructions as it takes. */
static void movi(int d, uint64_t v) {
  if (!(v >> 16)) { emit(MOVZ(d, (unsigned)v, 0)); return; }
  if (!(~v >> 16)) { emit(MOVN(d, (unsigned)(~v & 0xffff), 0)); return; }
  int zeros = 0, ones = 0;
  for (int hw = 0; hw < 4; hw++) {
    unsigned h = (unsigned)(v >> 16 * hw) & 0xffff;
    zeros += h == 0;
    ones += h == 0xffff;
  }
  bool inv = ones > zeros, first = true;
  for (int hw = 0; hw < 4; hw++) {
    unsigned h = (unsigned)(v >> 16 * hw) & 0xffff;
    if (h == (inv ? 0xffffu : 0u)) continue;
    if (first) emit(inv ? MOVN(d, ~h & 0xffff, hw) : MOVZ(d, h, hw));
    else emit(MOVK(d, h, hw));
    first = false;
  }
}

/* d = n + imm, for d and n never 31 (31 is sp in the immediate forms). */
static void addimm(int d, int n, int64_t imm, int tmp) {
  if (imm >= 0 && imm < 4096) emit(ADDi(d, n, (unsigned)imm));
  else if (imm < 0 && imm > -4096) emit(SUBi(d, n, (unsigned)-imm));
  else { movi(tmp, (uint64_t)imm); emit(ADDr(d, n, tmp)); }
}

/* ---- guest registers */

/* A host register holding guest register g: its own, xzr for x0, or the
 * scratch s loaded from memory. xzr is only right where the encoding reads
 * 31 as the zero register (register-form ALU, compares, the value of a
 * store), never as a base or in an immediate-form ALU instruction. */
static int src(unsigned g, int s) {
  if (!g) return ZR;
  if (gmap[g]) return gmap[g];
  emit(LDRui(s, CTX, L.x + 8 * g));
  return s;
}
/* Where to compute a result for guest register g (g != 0), then commit. */
static int dst(unsigned g, int s) { return gmap[g] ? gmap[g] : s; }
static void commit(unsigned g, int h) {
  if (!gmap[g]) emit(STRui(h, CTX, L.x + 8 * g));
}

/* ---- exits */

enum { SK_LIMIT, SK_INTERP, SK_LINK };
typedef struct {
  uint32_t *site; /* the branch to this stub, fixed up when the stub is placed */
  int kind;
  uint64_t pc;    /* where execution continues */
  unsigned count; /* instructions retired when leaving this way */
} Stub;
static Stub stubs[3 * 128 + 4];
static int nstubs;

/* Emits branch `insn` (offset 0) to a stub that is placed after the block. */
static void to_stub(uint32_t insn, int kind, uint64_t pc, unsigned count) {
  stubs[nstubs++] = (Stub){cur(), kind, pc, count};
  emit(insn);
}

static void place_stubs(uint64_t bpc, uint32_t *entry) {
  for (int i = 0; i < nstubs; i++) {
    Stub *s = &stubs[i];
    uint32_t w = *s->site, *here = cur();
    int32_t off = dist(s->site, here);
    if ((w & 0xFC000000u) == 0x14000000u) w |= Bto(off) & 0x3ffffff;
    else if ((w & 0x7E000000u) == 0x36000000u) w |= ((uint32_t)(off >> 2) & 0x3fff) << 5; /* tbz */
    else w |= ((uint32_t)(off >> 2) & 0x7ffff) << 5;                                       /* b.cond */
    *s->site = w;
    if (s->count) emit(ADDi(BUD, BUD, s->count));
    if (s->kind == SK_LINK && s->pc == bpc) { emit(Bto(dist(cur(), entry))); continue; } /* a loop to itself */
    uint32_t *site = cur();
    if (s->kind == SK_LINK) emit(Bto(4)); /* the patch site: goes on to the exit below until chained */
    movi(1, s->pc);
    if (s->kind == SK_LINK) emit(ADR(2, dist(cur(), site)));
    emit(MOVZ(0, s->kind == SK_LINK ? JX_LINK : s->kind == SK_LIMIT ? JX_LIMIT : JX_INTERP, 0));
    emit(Bto(dist(cur(), exit_common)));
  }
}

/* ---- the trampoline */

JitEnter jit_be_tramp(JitBuf *b, const JitLayout *lay) {
  L = *lay;
  B = b;
  uint32_t *start = cur();
  /* enter(core x0, code x1, limit x2, table x3, site x4) */
  emit(STPpre(29, 30, SP, -FRAME));
  for (int r = 19; r < 29; r += 2) emit(STP(r, r + 1, SP, 16 + 8 * (r - 19)));
  emit(STRui(2, SP, F_LIMIT));
  emit(STRui(3, SP, F_TABLE));
  emit(STRui(4, SP, F_SITE));
  emit(MOVr(CTX, 0));
  emit(LDRui(BUD, CTX, L.instret));
  emit(SUBr(BUD, BUD, 2));
  movi(DLS, L.dls);
  emit(ADDr(DLS, CTX, DLS));
  for (int g = 1; g < 32; g++)
    if (gmap[g]) emit(LDRui(gmap[g], CTX, L.x + 8 * g));
  emit(BR(1));
  /* the common exit: x0 = why, x1 = pc, x2 = patch site */
  exit_common = cur();
  emit(STRui(1, CTX, L.pc));
  for (int g = 1; g < 32; g++)
    if (gmap[g]) emit(STRui(gmap[g], CTX, L.x + 8 * g));
  emit(LDRui(1, SP, F_LIMIT));
  emit(ADDr(BUD, BUD, 1));
  emit(STRui(BUD, CTX, L.instret));
  emit(LDRui(1, SP, F_SITE));
  emit(STRui(2, 1, 0));
  for (int r = 19; r < 29; r += 2) emit(LDP(r, r + 1, SP, 16 + 8 * (r - 19)));
  emit(LDPpost(29, 30, SP, FRAME));
  emit(RET);
  return (JitEnter)(void *)start;
}

/* ---- one guest instruction */

static void insn(uint32_t ir, uint64_t pc, unsigned idx) {
  unsigned op = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31;
  unsigned imm16 = ir & 0xffff;
  int64_t simm = (int16_t)imm16;
  int a, b, d;
  switch (op) {
  case OP_ALU:
    if (!rd) break; /* no effect */
    a = src(rs1, S0), b = src(rs2, S1), d = dst(rd, S2);
    switch (ir & 15) {
    case ALU_ADD: emit(ADDr(d, a, b)); break;
    case ALU_SUB: emit(SUBr(d, a, b)); break;
    case ALU_AND: emit(ANDr(d, a, b)); break;
    case ALU_OR: emit(ORRr(d, a, b)); break;
    case ALU_XOR: emit(EORr(d, a, b)); break;
    case ALU_SLL: emit(DP2(LSLV, d, a, b)); break; /* the host also takes the count mod 64 */
    case ALU_SRL: emit(DP2(LSRV, d, a, b)); break;
    case ALU_SRA: emit(DP2(ASRV, d, a, b)); break;
    case ALU_SLT: emit(CMPr(a, b)); emit(CSET(d, C_LT)); break;
    case ALU_SLTU: emit(CMPr(a, b)); emit(CSET(d, C_LO)); break;
    case ALU_MUL: emit(MADD(d, a, b, ZR)); break;
    case ALU_MULHU: emit(UMULH(d, a, b)); break;
    /* The host divides by zero to 0 and INT_MIN / -1 to INT_MIN; the ISA
     * wants ~0 for a zero divisor, and a - q * b is then already right
     * for both remainders (a, and 0 for the overflow case). */
    case ALU_DIVU: case ALU_DIV:
      emit(DP2((ir & 15) == ALU_DIVU ? UDIV : SDIV, S2, a, b));
      emit(CMPr(b, ZR));
      emit(CSINV(d, S2, ZR, C_NE));
      break;
    case ALU_REMU: case ALU_REM:
      emit(DP2((ir & 15) == ALU_REMU ? UDIV : SDIV, S2, a, b));
      emit(MSUB(d, S2, b, a));
      break;
    }
    commit(rd, d);
    break;

  case OP_ADDI:
    if (!rd) break;
    d = dst(rd, S2);
    if (!rs1) movi(d, (uint64_t)simm);
    else addimm(d, src(rs1, S0), simm, S1);
    commit(rd, d);
    break;
  case OP_SLTI: case OP_SLTIU:
    if (!rd) break;
    d = dst(rd, S2), a = src(rs1, S0);
    movi(S1, (uint64_t)simm);
    emit(CMPr(a, S1));
    emit(CSET(d, op == OP_SLTI ? C_LT : C_LO));
    commit(rd, d);
    break;
  case OP_ANDI: case OP_ORI: case OP_XORI: {
    if (!rd) break;
    d = dst(rd, S2);
    uint32_t enc;
    if (!rs1) movi(d, op == OP_ANDI ? 0 : imm16);
    else if (!imm16) {
      if (op == OP_ANDI) movi(d, 0);
      else emit(MOVr(d, src(rs1, S0)));
    } else if (bitmask(imm16, &enc)) {
      a = src(rs1, S0);
      emit((op == OP_ANDI ? ANDi : op == OP_ORI ? ORRi : EORi) | enc | a << 5 | d);
    } else {
      a = src(rs1, S0);
      movi(S1, imm16);
      emit(op == OP_ANDI ? ANDr(d, a, S1) : op == OP_ORI ? ORRr(d, a, S1) : EORr(d, a, S1));
    }
    commit(rd, d);
    break;
  }
  case OP_SLLI: case OP_SRLI: case OP_SRAI: {
    if (!rd) break;
    int sh = imm16 & 63;
    d = dst(rd, S2);
    if (!rs1) movi(d, 0);
    else {
      a = src(rs1, S0);
      if (!sh) emit(MOVr(d, a));
      else if (op == OP_SLLI) emit(UBFM(d, a, (64 - sh) & 63, 63 - sh));
      else if (op == OP_SRLI) emit(UBFM(d, a, sh, 63));
      else emit(SBFM(d, a, sh, 63));
    }
    commit(rd, d);
    break;
  }
  case OP_LUI:
    if (!rd) break;
    d = dst(rd, S2);
    movi(d, (uint64_t)simm << 16);
    commit(rd, d);
    break;

  case OP_LD: case OP_LW: case OP_LWU: case OP_LH: case OP_LHU: case OP_LB: case OP_LBU:
  case OP_SD: case OP_SW: case OP_SH: case OP_SB: {
    bool store = op >= OP_SD;
    int lg = store ? 3 - (int)(op - OP_SD) : op == OP_LD ? 3 : op <= OP_LWU ? 2 : op <= OP_LHU ? 1 : 0;
    /* An access is in bounds and aligned iff no address bit outside
     * [lg, 16) is set: one test against a logical immediate. */
    uint64_t bad = ~0xffffull | ((1ull << lg) - 1);
    uint32_t enc;
    bitmask(bad, &enc); /* always encodable: a rotated run of ones */
    int ar;
    if (!rs1) movi(ar = S0, (uint64_t)simm);
    else {
      a = src(rs1, S0);
      if (simm) addimm(ar = S0, a, simm, S1);
      else ar = a;
    }
    emit(ANDSi | enc | ar << 5 | 31);
    to_stub(Bcond(0, C_NE), SK_INTERP, pc, idx); /* the interpreter traps */
    if (store) {
      static const uint32_t sop[4] = {STRB, STRH, STRW, STRX};
      emit(LSr(sop[lg], src(rd, S1), DLS, ar));
    } else if (rd) {
      uint32_t lop = op == OP_LD ? LDRX : op == OP_LW ? LDRSW : op == OP_LWU ? LDRW : op == OP_LH ? LDRSH
                   : op == OP_LHU ? LDRH : op == OP_LB ? LDRSB : LDRB;
      d = dst(rd, S1);
      emit(LSr(lop, d, DLS, ar));
      commit(rd, d);
    }
    break;
  }

  case OP_BEQ: case OP_BNE: case OP_BLT: case OP_BGE: case OP_BLTU: case OP_BGEU: {
    static const int cc[6] = {C_EQ, C_NE, C_LT, C_GE, C_LO, C_HS};
    a = src(rd, S0), b = src(rs1, S1);
    emit(CMPr(a, b));
    to_stub(Bcond(0, cc[op - OP_BEQ]), SK_LINK, pc + ((uint64_t)simm << 2), idx + 1);
    break;
  }
  case OP_JAL: {
    if (rd) {
      d = dst(rd, S2);
      movi(d, pc + 4);
      commit(rd, d);
    }
    uint64_t off = (uint64_t)((int64_t)((uint64_t)(ir & 0x1fffff) << 43) >> 43) << 2;
    to_stub(Bto(0), SK_LINK, pc + off, idx + 1);
    break;
  }
  case OP_JALR: {
    /* the target first: rd may be rs1 */
    if (!rs1) movi(S0, (uint64_t)simm & ~3ull);
    else {
      uint32_t enc;
      addimm(S0, src(rs1, S0), simm, S1);
      bitmask(~3ull, &enc);
      emit(ANDi | enc | S0 << 5 | S0);
    }
    if (rd) {
      d = dst(rd, S2);
      movi(d, pc + 4);
      commit(rd, d);
    }
    emit(ADDi(BUD, BUD, idx + 1));
    /* straight to the target's block if it has one (its entry checks the
     * quantum), else back to the dispatcher */
    uint32_t enc;
    bitmask(~0xffffull, &enc);
    emit(ANDSi | enc | S0 << 5 | 31);
    uint32_t *miss1 = cur();
    emit(Bcond(0, C_NE));
    emit(LDRui(S1, SP, F_TABLE));
    emit(ADDlsl(S1, S1, S0, 1)); /* 8-byte entries, one per 4-byte word */
    emit(LDRui(S1, S1, 0));
    uint32_t *miss2 = cur();
    emit(CBZ(S1, 0));
    emit(BR(S1));
    *miss1 = Bcond(dist(miss1, cur()), C_NE);
    *miss2 = CBZ(S1, dist(miss2, cur()));
    emit(MOVr(1, S0));
    emit(MOVZ(0, JX_LOOKUP, 0));
    emit(Bto(dist(cur(), exit_common)));
    break;
  }
  }
}

void *jit_be_block(JitBuf *b, uint64_t pc, const uint32_t *ir, int n, int tail) {
  B = b;
  nstubs = 0;
  uint32_t *entry = cur();
  to_stub(TBZ(BUD, 63, 0), SK_LIMIT, pc, 0); /* the quantum is used up */
  for (int i = 0; i < n; i++) insn(ir[i], pc + 4ull * (unsigned)i, (unsigned)i);
  unsigned last = ir[n - 1] >> 26;
  if (last != OP_JAL && last != OP_JALR)
    to_stub(Bto(0), tail == JT_NEXT_INTERP ? SK_INTERP : SK_LINK, pc + 4ull * (unsigned)n, (unsigned)n);
  place_stubs(pc, entry);
  return entry;
}

void jit_be_link(void *site, const void *target, uint8_t **lo, uint8_t **hi) {
  uint32_t w = Bto(dist(site, target));
  memcpy(site, &w, 4);
  *lo = site;
  *hi = (uint8_t *)site + 4;
}

#endif
