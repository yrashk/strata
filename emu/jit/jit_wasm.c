/* The JIT's WebAssembly backend: for the emulator built with Emscripten
 * (web/web.c: the play page's worker, and node for the tests). It
 * implements jit.h on its own; jit.c (code memory, patching) is for the
 * native backends and is not part of that build.
 *
 * Strata code is translated to WebAssembly at run time: the bytes of a
 * small module are written into a buffer, compiled and instantiated
 * synchronously by the host (new WebAssembly.Module / Instance: allowed at
 * any size in a worker and in node), and the module's one function is put
 * into a slot of the emulator's own indirect function table, so the
 * dispatcher below calls it like any C function pointer. The module
 * imports the emulator's linear memory: translated code works directly on
 * the Core structures, whose addresses are constants in the generated
 * code.
 *
 * What is translated is a region: the basic blocks reachable from a hot pc
 * through branches, jal (target and return address) and fall-through, up
 * to MAXRB blocks, each a run of plain instructions (the same subset as
 * the native backends: ALU, immediates, D-LS loads and stores, branches,
 * jal, jalr). A region becomes one function
 *
 *     (func (param $entry i32) (result i32)       ;; the block to start at
 *       load the guest registers the region uses into locals
 *       $ic = limit - instret                     ;; instructions left in the quantum
 *       block $exit
 *         loop $L                                 ;; backward jumps come here
 *           if $ic <= 0: $why = LIMIT, br $exit
 *           block .. block  br_table $next  end   ;; dispatch on the block number
 *           code of block 0  end  code of block 1  end ...
 *         end
 *       end
 *       store the registers the region writes, pc and instret
 *       [tail call the region at pc, if there is one]
 *       return $why)
 *
 * Blocks are laid out in address order, so falling through is free and a
 * forward branch inside the region is one `br`; a backward one sets $next
 * and goes round $L (where the quantum is checked); a block that branches
 * to its own start is wrapped in a loop of its own and never leaves it
 * while the quantum lasts. jalr looks its target up in the per-core tables
 * (fn[], blk[]): inside the same region it is a jump round $L too (so
 * calls and returns stay in one function once the caller's loop is the
 * region). Guest registers live in WebAssembly locals for as long as
 * control stays in the function.
 *
 * instret is exact: every way out of a block subtracts the instructions
 * retired since its start from $ic. A load or store whose address is out
 * of bounds, misaligned, or inside the hazard range of a pending device
 * read (emu.c: hazard_set) leaves the region in front of that instruction;
 * step() then traps or waits exactly as ever. So does an instruction the
 * JIT does not translate.
 *
 * Only hot code is translated: jit_exec() counts its visits to a pc that
 * has no translation and returns; emu.c runs cold code in its fast loop,
 * which comes back here after every backward jump. At HOT visits the
 * region is compiled. Regions are found through fn[] (I-LS word -> table
 * slot) and blk[] (-> block number); a region claims the entries of all
 * its blocks, so execution can enter it anywhere. With tail calls
 * (feature-detected) a region's exit calls the next region directly
 * (return_call_indirect through the emulator's table); without, it
 * returns to the dispatcher.
 *
 * tgetx into a translated word flushes the core's regions (their table
 * slots are reused), exactly as jit.c does. */
#ifdef __EMSCRIPTEN__

#include <emscripten.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jit_be.h"
#include "../../asm/isa.h"

#define MAXJCORES 16
#define ILS_WORDS (ILS_BYTES / 4)
#define MAXRB 192    /* blocks per region */
#define MAXRI 2048   /* instructions scanned per region */
#define HOT 24       /* visits before a pc is translated (jit_wasm_set_hot) */
#define HOT_NEVER 255
#define MAXREGIONS 2048 /* per core; more and the core's cache is flushed */
/* Regions alive across all cores (jit_wasm_set_budget): past it, every
 * core's translations are dropped. Each region is a WebAssembly module the
 * browser compiles to machine code, and some browsers (Safari on iOS) have
 * a small pool for that: the page sets a small budget there. */
static int budget = MAXREGIONS * MAXJCORES;

typedef struct {
  uint8_t *core;
  uint32_t *fn;   /* I-LS word -> table slot of the region that has a block starting there, or 0 */
  uint16_t *blk;  /* ... and that block's number */
  uint8_t *hot;   /* visits to an untranslated word */
  uint64_t tbits[ILS_WORDS / 64]; /* words some region was translated from */
  uint32_t *slots; /* the table slots of this core's regions */
  int nslots;
} JCore;

static JCore jcs[MAXJCORES];
static int njcores;
static JitLayout L;
static uint64_t jw_limit; /* the limit of the running jit_exec(): translated code reads it */
static bool tailcalls;
static unsigned hot_at = HOT;
static uint32_t *freeslots;
static int nfree, capfree;
static uint32_t slot_next, slot_end;

/* ---- the host side */

/* Whether the engine has tail calls: validates a module whose function is
 * `return_call 0`. */
EM_JS(int, jw_js_tailcalls, (void), {
  try {
    return WebAssembly.validate(new Uint8Array(
      [0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 6, 1, 4, 0, 18, 0, 11])) ? 1 : 0;
  } catch (e) { return 0; }
});

/* Grows the emulator's function table by n slots; returns the first new
 * one, or -1. (The memory and the table are the runtime's wasmMemory and
 * wasmTable: module-scope variables in every Emscripten so far, also
 * exported on Module by the build.) */
EM_JS(int, jw_js_grow, (int n), {
  try { return (typeof wasmTable != "undefined" ? wasmTable : Module["wasmTable"]).grow(n); } catch (e) { return -1; }
});

/* Empties table slot idx, so the module that was there can be collected. */
EM_JS(void, jw_js_clear, (int idx), {
  try { (typeof wasmTable != "undefined" ? wasmTable : Module["wasmTable"]).set(idx, null); } catch (e) { }
});

/* Compiles the module at [p, p + n) and puts its function "f" into table
 * slot idx. */
EM_JS(int, jw_js_install, (const uint8_t *p, int n, int idx), {
  try {
    var mem = typeof wasmMemory != "undefined" ? wasmMemory : Module["wasmMemory"];
    var tab = typeof wasmTable != "undefined" ? wasmTable : Module["wasmTable"];
    var mod = new WebAssembly.Module(new Uint8Array(mem.buffer, p, n));
    var inst = new WebAssembly.Instance(mod, { "e": { "m": mem, "t": tab } });
    tab.set(idx, inst.exports["f"]);
    return 1;
  } catch (e) {
    err("strata-emu: jit: " + e);
    return 0;
  }
});

/* ---- output buffers */

typedef struct {
  uint8_t *p;
  size_t n, cap;
} Buf;

static void put(Buf *b, unsigned v) {
  if (b->n == b->cap) {
    b->cap = b->cap ? b->cap * 2 : 4096;
    b->p = realloc(b->p, b->cap);
    if (!b->p) { perror("strata-emu: jit"); exit(2); }
  }
  b->p[b->n++] = (uint8_t)v;
}
static void uleb(Buf *b, uint64_t v) {
  do {
    unsigned c = v & 0x7f;
    v >>= 7;
    put(b, c | (v ? 0x80 : 0));
  } while (v);
}
static void sleb(Buf *b, int64_t v) {
  for (;;) {
    unsigned c = (unsigned)v & 0x7f;
    v >>= 7; /* arithmetic */
    if ((v == 0 && !(c & 0x40)) || (v == -1 && (c & 0x40))) { put(b, c); return; }
    put(b, c | 0x80);
  }
}
static void append(Buf *b, const Buf *s) {
  for (size_t i = 0; i < s->n; i++) put(b, s->p[i]);
}

/* ---- WebAssembly instructions */

enum {
  W_BLOCK = 0x02, W_LOOP = 0x03, W_IF = 0x04, W_ELSE = 0x05, W_END = 0x0b, W_BR = 0x0c, W_BR_IF = 0x0d,
  W_BR_TABLE = 0x0e, W_RETURN_CALL_INDIRECT = 0x13, W_LOCAL_GET = 0x20, W_LOCAL_SET = 0x21, W_LOCAL_TEE = 0x22,
  W_I32_LOAD = 0x28, W_I64_LOAD = 0x29, W_I32_LOAD16_U = 0x2f, W_I64_LOAD8_S = 0x30, W_I64_LOAD8_U = 0x31,
  W_I64_LOAD16_S = 0x32, W_I64_LOAD16_U = 0x33, W_I64_LOAD32_S = 0x34, W_I64_LOAD32_U = 0x35,
  W_I64_STORE = 0x37, W_I64_STORE8 = 0x3c, W_I64_STORE16 = 0x3d, W_I64_STORE32 = 0x3e,
  W_I32_CONST = 0x41, W_I64_CONST = 0x42, W_I32_EQ = 0x46, W_I32_AND = 0x71, W_I32_OR = 0x72, W_I32_SHR_U = 0x76,
  W_I64_EQZ = 0x50, W_I64_EQ = 0x51, W_I64_NE = 0x52, W_I64_LT_S = 0x53, W_I64_LT_U = 0x54, W_I64_GT_S = 0x55,
  W_I64_LE_S = 0x57, W_I64_GE_S = 0x59, W_I64_GE_U = 0x5a,
  W_I64_ADD = 0x7c, W_I64_SUB = 0x7d, W_I64_MUL = 0x7e, W_I64_DIV_S = 0x7f, W_I64_DIV_U = 0x80,
  W_I64_REM_S = 0x81, W_I64_REM_U = 0x82, W_I64_AND = 0x83, W_I64_OR = 0x84, W_I64_XOR = 0x85,
  W_I64_SHL = 0x86, W_I64_SHR_S = 0x87, W_I64_SHR_U = 0x88, W_I32_WRAP_I64 = 0xa7, W_I64_EXTEND_I32_U = 0xad,
  T_VOID = 0x40, T_I32 = 0x7f, T_I64 = 0x7e, T_FUNCREF = 0x70,
};

/* Locals: 0 = $entry (the parameter); 1..31 = the guest registers;
 * then the i64 and the i32 temporaries. */
enum {
  LIC = 32, LT0, LT1, LT2, LT3, LHB, LHS, LXPC, /* i64: quantum left, scratch, hazard base/span, exit pc */
  LNEXT, LWHY, LA,                              /* i32: block number, exit reason, scratch */
  N_I64 = LXPC, N_I32 = LA - LXPC,
};

static Buf code; /* the function body being generated (without prologue and epilogue) */
static uint32_t used, dirty; /* guest registers read or written / written by the region */

static void op(unsigned o) { put(&code, o); }
static void op1(unsigned o, uint64_t a) { put(&code, o), uleb(&code, a); }
static void i32c(int32_t v) { put(&code, W_I32_CONST), sleb(&code, v); }
static void i64c(uint64_t v) { put(&code, W_I64_CONST), sleb(&code, (int64_t)v); }
static void lget(int l) { op1(W_LOCAL_GET, (unsigned)l); }
static void lset(int l) { op1(W_LOCAL_SET, (unsigned)l); }
static void ltee(int l) { op1(W_LOCAL_TEE, (unsigned)l); }
/* a load or store at [address on the stack] + off */
static void mem(unsigned o, unsigned align, uint32_t off) { put(&code, o), uleb(&code, align), uleb(&code, off); }
static void rget(unsigned r) {
  if (!r) { i64c(0); return; }
  used |= 1u << r;
  lget((int)r);
}
static void rset(unsigned r) { /* r != 0 */
  used |= 1u << r;
  dirty |= 1u << r;
  lset((int)r);
}

/* ---- a region */

typedef struct {
  uint32_t pc; /* its first instruction */
  int n;       /* instructions */
} RBlock;

static RBlock rb[MAXRB];
static int nrb;
static int16_t leader[ILS_WORDS]; /* I-LS word -> block number + 1 while a region is built */
static int cur;      /* the block being generated */
static int nest;     /* ifs and loops open inside it */
static uint32_t myfn; /* the table slot the region will get */
static uint32_t a_fn, a_blk, a_dls; /* addresses of the core's fn[], blk[] and D-LS */

static bool plain_at(const JCore *j, uint64_t pc, uint32_t *w) {
  if ((pc & 3) || pc >= L.ils_size) return false;
  memcpy(w, j->core + L.ils + pc, 4);
  return jit_plain(*w);
}

/* depth of the labels seen from the code of block `cur` */
static unsigned d_block(int m) { return (unsigned)(m - cur - 1 + nest); } /* m > cur: the start of block m */
static unsigned d_loop(void) { return (unsigned)(nrb - 1 - cur + nest); }
static unsigned d_exit(void) { return (unsigned)(nrb - cur + nest); }

static void ic_sub(int n) {
  if (!n) return;
  lget(LIC), i64c((uint64_t)n), op(W_I64_SUB), lset(LIC);
}

/* Leaves the region: n instructions of the block were retired, execution
 * continues at pc. */
static void emit_exit(int why, uint64_t pc, int n) {
  ic_sub(n);
  i64c(pc), lset(LXPC);
  i32c(why), lset(LWHY);
  op1(W_BR, d_exit());
}

/* Control goes to pc after n retired instructions of the block. */
static void emit_goto(uint64_t pc, int n) {
  int m = !(pc & 3) && pc < L.ils_size ? leader[pc / 4] - 1 : -1;
  if (m < 0) { emit_exit(JX_LINK, pc, n); return; }
  ic_sub(n);
  if (m > cur) { op1(W_BR, d_block(m)); return; }
  i64c(pc), lset(LXPC);
  i32c(m), lset(LNEXT);
  op1(W_BR, d_loop());
}

static void emit_alu(unsigned f, unsigned rd, unsigned rs1, unsigned rs2) {
  static const uint8_t simple[] = {
    [ALU_ADD] = W_I64_ADD, [ALU_SUB] = W_I64_SUB, [ALU_AND] = W_I64_AND, [ALU_OR] = W_I64_OR,
    [ALU_XOR] = W_I64_XOR, [ALU_SLL] = W_I64_SHL, [ALU_SRL] = W_I64_SHR_U, [ALU_SRA] = W_I64_SHR_S,
    [ALU_MUL] = W_I64_MUL,
  };
  switch (f) {
  case ALU_SLT: case ALU_SLTU:
    rget(rs1), rget(rs2), op(f == ALU_SLT ? W_I64_LT_S : W_I64_LT_U), op(W_I64_EXTEND_I32_U);
    break;
  case ALU_MULHU: /* the high half of a 64x64 product, from 32-bit halves */
    rget(rs1), lset(LT0), rget(rs2), lset(LT1);
    /* t2 = ah*bl + ((al*bl) >> 32) */
    lget(LT0), i64c(32), op(W_I64_SHR_U), lget(LT1), i64c(0xffffffffu), op(W_I64_AND), op(W_I64_MUL);
    lget(LT0), i64c(0xffffffffu), op(W_I64_AND), lget(LT1), i64c(0xffffffffu), op(W_I64_AND), op(W_I64_MUL);
    i64c(32), op(W_I64_SHR_U), op(W_I64_ADD), lset(LT2);
    /* t3 = al*bh + (t2 & M) */
    lget(LT0), i64c(0xffffffffu), op(W_I64_AND), lget(LT1), i64c(32), op(W_I64_SHR_U), op(W_I64_MUL);
    lget(LT2), i64c(0xffffffffu), op(W_I64_AND), op(W_I64_ADD), lset(LT3);
    /* ah*bh + (t2 >> 32) + (t3 >> 32) */
    lget(LT0), i64c(32), op(W_I64_SHR_U), lget(LT1), i64c(32), op(W_I64_SHR_U), op(W_I64_MUL);
    lget(LT2), i64c(32), op(W_I64_SHR_U), op(W_I64_ADD);
    lget(LT3), i64c(32), op(W_I64_SHR_U), op(W_I64_ADD);
    break;
  case ALU_DIVU: case ALU_REMU: /* by zero: all ones / the dividend */
    rget(rs2), op(W_I64_EQZ), op(W_IF), op(T_I64);
    if (f == ALU_DIVU) i64c(~0ull); else rget(rs1);
    op(W_ELSE);
    rget(rs1), rget(rs2), op(f == ALU_DIVU ? W_I64_DIV_U : W_I64_REM_U);
    op(W_END);
    break;
  case ALU_DIV: /* by zero: all ones; INT64_MIN / -1 = INT64_MIN (div_s would trap) */
    rget(rs2), op(W_I64_EQZ), op(W_IF), op(T_I64);
    i64c(~0ull);
    op(W_ELSE);
    rget(rs1), i64c(0x8000000000000000ull), op(W_I64_EQ), rget(rs2), i64c(~0ull), op(W_I64_EQ), op(W_I32_AND);
    op(W_IF), op(T_I64);
    rget(rs1);
    op(W_ELSE);
    rget(rs1), rget(rs2), op(W_I64_DIV_S);
    op(W_END);
    op(W_END);
    break;
  case ALU_REM: /* by zero: the dividend; INT64_MIN % -1 = 0, which rem_s gives */
    rget(rs2), op(W_I64_EQZ), op(W_IF), op(T_I64);
    rget(rs1);
    op(W_ELSE);
    rget(rs1), rget(rs2), op(W_I64_REM_S);
    op(W_END);
    break;
  default:
    rget(rs1), rget(rs2), op(simple[f]);
  }
  if (rd) rset(rd); else op(0x1a); /* drop */
}

/* One instruction that is not a branch or jump: instruction i of the
 * block, at pc. */
static void emit_insn(uint32_t ir, uint64_t pc, int i) {
  unsigned o = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31;
  unsigned imm16 = ir & 0xffff;
  uint64_t simm = (uint64_t)(int64_t)(int16_t)imm16;
  if (o == OP_ALU) { emit_alu(ir & 15, rd, rs1, rs2); return; }
  if (o >= OP_LD && o <= OP_SB) {
    bool store = o >= OP_SD;
    int lg = store ? 3 - (int)(o - OP_SD) : o == OP_LD ? 3 : o <= OP_LWU ? 2 : o <= OP_LHU ? 1 : 0;
    /* the address; out of bounds or misaligned iff it has a bit outside the D-LS size - size */
    rget(rs1);
    if (simm) i64c(simm), op(W_I64_ADD);
    ltee(LT0);
    i64c(~(uint64_t)(L.dls_size - (1u << lg))), op(W_I64_AND), i64c(0), op(W_I64_NE);
    lget(LT0), lget(LHB), op(W_I64_SUB), lget(LHS), op(W_I64_LT_U); /* a device read in flight */
    op(W_I32_OR);
    op(W_IF), op(T_VOID);
    nest++;
    emit_exit(JX_INTERP, pc, i);
    nest--;
    op(W_END);
    lget(LT0), op(W_I32_WRAP_I64);
    if (store) {
      static const uint8_t st[] = {W_I64_STORE8, W_I64_STORE16, W_I64_STORE32, W_I64_STORE};
      rget(rd);
      mem(st[lg], 0, a_dls);
    } else {
      static const uint8_t ld[] = {[OP_LD - OP_LD] = W_I64_LOAD, [OP_LW - OP_LD] = W_I64_LOAD32_S,
                                   [OP_LWU - OP_LD] = W_I64_LOAD32_U, [OP_LH - OP_LD] = W_I64_LOAD16_S,
                                   [OP_LHU - OP_LD] = W_I64_LOAD16_U, [OP_LB - OP_LD] = W_I64_LOAD8_S,
                                   [OP_LBU - OP_LD] = W_I64_LOAD8_U};
      mem(ld[o - OP_LD], 0, a_dls);
      if (rd) rset(rd); else op(0x1a);
    }
    return;
  }
  /* immediates */
  if (!rd) return; /* no effect */
  switch (o) {
  case OP_ADDI: rget(rs1), i64c(simm), op(W_I64_ADD); break;
  case OP_SLTI: rget(rs1), i64c(simm), op(W_I64_LT_S), op(W_I64_EXTEND_I32_U); break;
  case OP_SLTIU: rget(rs1), i64c(simm), op(W_I64_LT_U), op(W_I64_EXTEND_I32_U); break;
  case OP_ANDI: rget(rs1), i64c(imm16), op(W_I64_AND); break;
  case OP_ORI: rget(rs1), i64c(imm16), op(W_I64_OR); break;
  case OP_XORI: rget(rs1), i64c(imm16), op(W_I64_XOR); break;
  case OP_SLLI: rget(rs1), i64c(imm16 & 63), op(W_I64_SHL); break;
  case OP_SRLI: rget(rs1), i64c(imm16 & 63), op(W_I64_SHR_U); break;
  case OP_SRAI: rget(rs1), i64c(imm16 & 63), op(W_I64_SHR_S); break;
  case OP_LUI: i64c(simm << 16); break;
  }
  rset(rd);
}

/* The last instruction of a block when it is a branch, jal or jalr: n is
 * the block's length. `self`: the block is wrapped in a loop of its own
 * (label depth nest - 1 from here) because this instruction jumps to its
 * start. */
static void emit_jump(uint32_t ir, uint64_t pc, int n, bool self) {
  unsigned o = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31;
  uint64_t simm = (uint64_t)(int64_t)(int16_t)(ir & 0xffff);
  if (o == OP_JALR) {
    rget(rs1);
    if (simm) i64c(simm), op(W_I64_ADD);
    i64c(~3ull), op(W_I64_AND), lset(LXPC);
    if (rd) i64c(pc + 4), rset(rd);
    ic_sub(n);
    /* a target with a block in this region: go round the loop */
    lget(LXPC), i64c(L.ils_size), op(W_I64_LT_U), op(W_IF), op(T_VOID);
    nest++;
    lget(LXPC), op(W_I32_WRAP_I64), ltee(LA), mem(W_I32_LOAD, 2, a_fn), i32c((int32_t)myfn), op(W_I32_EQ);
    op(W_IF), op(T_VOID);
    nest++;
    lget(LA), i32c(1), op(W_I32_SHR_U), mem(W_I32_LOAD16_U, 1, a_blk), lset(LNEXT);
    op1(W_BR, d_loop());
    nest--;
    op(W_END);
    nest--;
    op(W_END);
    i32c(JX_LINK), lset(LWHY);
    op1(W_BR, d_exit());
    return;
  }
  if (o == OP_JAL) {
    uint64_t target = pc + ((uint64_t)((int64_t)((uint64_t)(ir & 0x1fffff) << 43) >> 43) << 2);
    if (rd) i64c(pc + 4), rset(rd);
    emit_goto(target, n);
    return;
  }
  /* a conditional branch: compares x[rd] with x[rs1] */
  static const uint8_t cc[] = {W_I64_EQ, W_I64_NE, W_I64_LT_S, W_I64_GE_S, W_I64_LT_U, W_I64_GE_U};
  uint64_t target = pc + (simm << 2);
  rget(rd), rget(rs1), op(cc[o - OP_BEQ]);
  op(W_IF), op(T_VOID);
  nest++;
  if (self) { /* stay in the block's own loop while the quantum lasts */
    ic_sub(n);
    lget(LIC), i64c(0), op(W_I64_GT_S), op1(W_BR_IF, 1);
    emit_goto(target, 0); /* round $L, which exits with LIMIT */
  } else {
    emit_goto(target, n);
  }
  nest--;
  op(W_END);
}

static bool is_jump(uint32_t ir) { return ir >> 26 >= OP_BEQ; } /* among plain instructions */

/* The code of block `cur`. */
static void emit_block(const JCore *j) {
  const RBlock *b = &rb[cur];
  uint32_t last;
  memcpy(&last, j->core + L.ils + b->pc + 4 * (uint32_t)(b->n - 1), 4);
  uint64_t end = (uint64_t)b->pc + 4 * (uint64_t)b->n;
  bool self = false;
  if (last >> 26 >= OP_BEQ && last >> 26 <= OP_BGEU)
    self = b->pc + ((uint64_t)(int64_t)(int16_t)(last & 0xffff) << 2) + 4 * (uint64_t)(b->n - 1) == b->pc;
  if (self) op(W_LOOP), op(T_VOID), nest++;
  for (int i = 0; i < b->n; i++) {
    uint32_t ir;
    uint64_t pc = (uint64_t)b->pc + 4 * (uint64_t)i;
    memcpy(&ir, j->core + L.ils + pc, 4);
    if (is_jump(ir)) emit_jump(ir, pc, b->n, self); /* always the last one */
    else emit_insn(ir, pc, i);
  }
  if (self) op(W_END), nest--;
  unsigned lo = last >> 26;
  if (lo == OP_JAL || lo == OP_JALR) return; /* never falls through */
  /* falls through to `end`: the next block if it starts there, else out */
  uint32_t w;
  if (cur + 1 < nrb && rb[cur + 1].pc == end) ic_sub(b->n);
  else if (end < L.ils_size && !plain_at(j, end, &w)) emit_exit(JX_INTERP, end, b->n);
  else emit_exit(JX_LINK, end, b->n);
}

/* Finds the region's blocks from pc: nrb, rb[], leader[]. */
static void find_blocks(const JCore *j, uint64_t pc0) {
  static uint16_t q[MAXRB];
  int nq = 0, scanned = 0;
  uint32_t w;
#define LEAD(p)                                                                                  \
  do {                                                                                           \
    uint64_t p_ = (p);                                                                           \
    if (nq < MAXRB && plain_at(j, p_, &w) && !leader[p_ / 4]) leader[p_ / 4] = 1, q[nq++] = (uint16_t)(p_ / 4); \
  } while (0)
  LEAD(pc0);
  for (int h = 0; h < nq && scanned < MAXRI; h++) {
    for (uint64_t p = (uint64_t)q[h] * 4;; p += 4) {
      if (p != (uint64_t)q[h] * 4 && p < L.ils_size && leader[p / 4]) break; /* runs into a block */
      if (!plain_at(j, p, &w)) { LEAD(p + 4); break; } /* after the interpreter's instruction */
      scanned++;
      unsigned o = w >> 26;
      if (o >= OP_BEQ && o <= OP_BGEU) {
        LEAD(p + ((uint64_t)(int64_t)(int16_t)(w & 0xffff) << 2));
        LEAD(p + 4);
        break;
      }
      if (o == OP_JAL) {
        LEAD(p + ((uint64_t)((int64_t)((uint64_t)(w & 0x1fffff) << 43) >> 43) << 2));
        if ((w >> 21) & 31) LEAD(p + 4); /* the return address */
        break;
      }
      if (o == OP_JALR) break;
    }
  }
#undef LEAD
  /* in address order; each block runs to its jump, to the next block, or
   * to an instruction for the interpreter */
  for (int a = 1; a < nq; a++) {
    uint16_t v = q[a];
    int k = a;
    for (; k > 0 && q[k - 1] > v; k--) q[k] = q[k - 1];
    q[k] = v;
  }
  nrb = nq;
  for (int k = 0; k < nq; k++) {
    uint64_t p = (uint64_t)q[k] * 4;
    int n = 0;
    for (;; p += 4) {
      if (n && k + 1 < nq && p == (uint64_t)q[k + 1] * 4) break;
      if (!plain_at(j, p, &w)) break;
      n++;
      if (is_jump(w)) break;
    }
    rb[k] = (RBlock){(uint32_t)q[k] * 4, n};
    leader[q[k]] = (int16_t)(k + 1);
  }
}

static uint32_t slot_alloc(void) {
  if (nfree) return freeslots[--nfree];
  if (slot_next == slot_end) {
    int base = jw_js_grow(256);
    if (base < 0) return 0;
    slot_next = (uint32_t)base;
    slot_end = slot_next + 256;
  }
  return slot_next++;
}
static void slot_free(uint32_t s) {
  jw_js_clear((int)s);
  if (nfree == capfree) {
    capfree = capfree ? capfree * 2 : 256;
    freeslots = realloc(freeslots, (size_t)capfree * sizeof *freeslots);
    if (!freeslots) { perror("strata-emu: jit"); exit(2); }
  }
  freeslots[nfree++] = s;
}

/* Forgets every translation of a core. Only ever called from outside
 * translated code. */
static void flush(JCore *j) {
  for (int i = 0; i < j->nslots; i++) slot_free(j->slots[i]);
  j->nslots = 0;
  memset(j->fn, 0, ILS_WORDS * sizeof *j->fn);
  memset(j->blk, 0, ILS_WORDS * sizeof *j->blk);
  memset(j->hot, 0, ILS_WORDS);
  memset(j->tbits, 0, sizeof j->tbits);
}

/* Translates the region at pc and installs it. False if there is nothing
 * to translate there or the host refused the module. */
static bool translate(JCore *j, uint64_t pc0) {
  static Buf mod, body;
  if (j->nslots == MAXREGIONS) flush(j);
  int live = 0;
  for (int i = 0; i < njcores; i++) live += jcs[i].nslots;
  if (live >= budget)
    for (int i = 0; i < njcores; i++) flush(&jcs[i]);
  find_blocks(j, pc0);
  bool ok = false;
  if (!nrb) goto done;
  myfn = slot_alloc();
  if (!myfn) goto done;
  uint32_t core = (uint32_t)(uintptr_t)j->core;
  a_fn = (uint32_t)(uintptr_t)j->fn;
  a_blk = (uint32_t)(uintptr_t)j->blk;
  a_dls = core + (uint32_t)L.dls;

  /* the blocks, inside block $exit / loop $L */
  code.n = 0;
  used = dirty = 0;
  op(W_BLOCK), op(T_VOID);
  op(W_LOOP), op(T_VOID);
  lget(LIC), i64c(0), op(W_I64_LE_S), op(W_IF), op(T_VOID);
  i32c(JX_LIMIT), lset(LWHY), op1(W_BR, 2);
  op(W_END);
  for (int k = 0; k < nrb; k++) op(W_BLOCK), op(T_VOID);
  lget(LNEXT), op1(W_BR_TABLE, (unsigned)nrb);
  for (int k = 0; k < nrb; k++) uleb(&code, (unsigned)k);
  uleb(&code, 0);
  for (cur = 0; cur < nrb; cur++) {
    op(W_END);
    nest = 0;
    emit_block(j);
  }
  op(W_END); /* loop: the last block never falls out of it */
  op(0x00);  /* unreachable */
  op(W_END); /* block $exit */

  /* the function: locals, prologue, the blocks, epilogue */
  Buf blocks = code;
  code = body;
  code.n = 0;
  uleb(&code, 2), uleb(&code, N_I64), put(&code, T_I64), uleb(&code, N_I32), put(&code, T_I32);
  for (unsigned r = 1; r < 32; r++)
    if (used >> r & 1) i32c(0), mem(W_I64_LOAD, 3, core + (uint32_t)L.x + 8 * r), lset((int)r);
  i32c(0), mem(W_I64_LOAD, 3, (uint32_t)(uintptr_t)&jw_limit);
  i32c(0), mem(W_I64_LOAD, 3, core + (uint32_t)L.instret), op(W_I64_SUB), lset(LIC);
  i32c(0), mem(W_I64_LOAD, 3, core + (uint32_t)L.hz), lset(LHB);
  i32c(0), mem(W_I64_LOAD, 3, core + (uint32_t)L.hz + 8), lset(LHS);
  i32c(0), mem(W_I64_LOAD, 3, core + (uint32_t)L.pc), lset(LXPC);
  lget(0), lset(LNEXT);
  append(&code, &blocks);
  for (unsigned r = 1; r < 32; r++)
    if (dirty >> r & 1) i32c(0), lget((int)r), mem(W_I64_STORE, 3, core + (uint32_t)L.x + 8 * r);
  i32c(0), lget(LXPC), mem(W_I64_STORE, 3, core + (uint32_t)L.pc);
  i32c(0), i32c(0), mem(W_I64_LOAD, 3, (uint32_t)(uintptr_t)&jw_limit), lget(LIC), op(W_I64_SUB);
  mem(W_I64_STORE, 3, core + (uint32_t)L.instret);
  if (tailcalls) { /* straight on into the region that has a block at pc */
    lget(LWHY), i32c(JX_LINK), op(W_I32_EQ), lget(LXPC), i64c(L.ils_size), op(W_I64_LT_U), op(W_I32_AND);
    op(W_IF), op(T_VOID);
    lget(LXPC), op(W_I32_WRAP_I64), ltee(LA), mem(W_I32_LOAD, 2, a_fn), ltee(LNEXT);
    op(W_IF), op(T_VOID);
    lget(LA), i32c(1), op(W_I32_SHR_U), mem(W_I32_LOAD16_U, 1, a_blk);
    lget(LNEXT);
    op(W_RETURN_CALL_INDIRECT), uleb(&code, 0), uleb(&code, 0);
    op(W_END);
    op(W_END);
  }
  lget(LWHY);
  op(W_END);
  body = code;
  code = blocks;

  /* the module: (type (func (param i32) (result i32))), the emulator's
   * memory and table imported, one exported function "f" */
  static const uint8_t head[] = {
    0, 'a', 's', 'm', 1, 0, 0, 0,
    1, 6, 1, 0x60, 1, T_I32, 1, T_I32,                                   /* type */
    2, 16, 2, 1, 'e', 1, 'm', 2, 0, 0, 1, 'e', 1, 't', 1, T_FUNCREF, 0, 0, /* import */
    3, 2, 1, 0,                                                          /* function */
    7, 5, 1, 1, 'f', 0, 0,                                               /* export */
  };
  mod.n = 0;
  for (size_t i = 0; i < sizeof head; i++) put(&mod, head[i]);
  Buf sz = {0};
  uleb(&sz, body.n);
  put(&mod, 10), uleb(&mod, 1 + sz.n + body.n), put(&mod, 1), append(&mod, &sz), append(&mod, &body);
  free(sz.p);
  if (!jw_js_install(mod.p, (int)mod.n, (int)myfn)) { slot_free(myfn); goto done; }

  if (!j->slots && !(j->slots = malloc(MAXREGIONS * sizeof *j->slots))) { perror("strata-emu: jit"); exit(2); }
  j->slots[j->nslots++] = myfn;
  for (int k = 0; k < nrb; k++) {
    uint32_t w0 = rb[k].pc / 4;
    j->fn[w0] = myfn;
    j->blk[w0] = (uint16_t)k;
    for (uint32_t w = w0; w < w0 + (uint32_t)rb[k].n; w++) j->tbits[w / 64] |= 1ull << (w % 64);
  }
  ok = true;
done:
  for (int k = 0; k < nrb; k++) leader[rb[k].pc / 4] = 0;
  return ok;
}

/* ---- jit.h */

const char *jit_backend(void) { return "wasm"; }

bool jit_init(const JitLayout *lay, void *cores, size_t stride, int ncores) {
  if (ncores < 1 || ncores > MAXJCORES) return false;
  L = *lay;
  tailcalls = jw_js_tailcalls();
  slot_next = slot_end = 0;
  if (!slot_alloc()) return false; /* no table growth: no JIT (and slot 0 stays "none") */
  for (int i = 0; i < ncores; i++) {
    JCore *j = &jcs[i];
    j->core = (uint8_t *)cores + (size_t)i * stride;
    j->fn = calloc(ILS_WORDS, sizeof *j->fn);
    j->blk = calloc(ILS_WORDS, sizeof *j->blk);
    j->hot = calloc(ILS_WORDS, 1);
    if (!j->fn || !j->blk || !j->hot) return false;
  }
  njcores = ncores;
  return true;
}

void jit_exec(int id, uint64_t limit) {
  JCore *j = &jcs[id];
  uint64_t *pcp = (uint64_t *)(j->core + L.pc), *ip = (uint64_t *)(j->core + L.instret);
  jw_limit = limit;
  while (*ip < limit) {
    uint64_t pc = *pcp;
    if ((pc & 3) || pc >= L.ils_size) return; /* the interpreter raises the fetch fault */
    uint32_t w = (uint32_t)pc / 4, f = j->fn[w];
    if (!f) { /* cold, or not for the JIT: count, and translate at HOT */
      if (j->hot[w] == HOT_NEVER) return;
      if (++j->hot[w] < hot_at) return;
      if (!translate(j, pc)) { j->hot[w] = HOT_NEVER; return; }
      f = j->fn[w];
    }
    if (((int (*)(int))(uintptr_t)f)(j->blk[w]) == JX_INTERP) return;
  }
}

void jit_invalidate(int id, uint64_t ls, uint64_t len) {
  if (id >= njcores || !len) return;
  JCore *j = &jcs[id];
  uint64_t w0 = ls / 4, w1 = (ls + len + 3) / 4;
  if (w1 > ILS_WORDS) w1 = ILS_WORDS;
  /* a word that was looked at and found cold or untranslatable may be code now */
  for (uint64_t w = w0; w < w1; w++) j->hot[w] = 0;
  for (uint64_t w = w0; w < w1; w++) {
    if (!(w % 64) && w + 64 <= w1 && !j->tbits[w / 64]) { w += 63; continue; }
    if (j->tbits[w / 64] >> (w % 64) & 1) { flush(j); return; }
  }
}

/* Counters for the page's status line and the tests: 0 regions translated
 * (all cores), 1 tail calls available. */
EMSCRIPTEN_KEEPALIVE int jit_wasm_stat(int what) {
  int n = 0;
  if (what == 1) return tailcalls;
  for (int i = 0; i < njcores; i++) n += jcs[i].nslots;
  return n;
}

/* For the tests: translate after n visits (1: everything, at once); 0
 * also turns the tail calls off. */
/* At most n regions alive across all cores (see `budget`). */
EMSCRIPTEN_KEEPALIVE void jit_wasm_set_budget(int n) { budget = n < 16 ? 16 : n; }

EMSCRIPTEN_KEEPALIVE void jit_wasm_set_hot(int n) {
  if (n <= 0) tailcalls = false;
  hot_at = n < 1 ? 1 : n > 200 ? 200 : (unsigned)n;
}

#endif /* __EMSCRIPTEN__ */
