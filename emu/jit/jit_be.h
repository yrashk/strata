/* The interface between the common part of the JIT (jit.c: code memory,
 * translation caches, the dispatcher) and a host backend (jit_arm64.c,
 * jit_x86_64.c). Private to emu/jit/. */
#ifndef STRATA_JIT_BE_H
#define STRATA_JIT_BE_H

#include "jit.h"

/* Why translated code returned to the dispatcher. The trampoline returns
 * one of these; the core's pc is where execution continues. */
enum {
  JX_INTERP = 1, /* the instruction at pc needs the interpreter */
  JX_LIMIT = 2,  /* instret reached the limit at a block's entry */
  JX_LOOKUP = 3, /* an indirect jump (jalr) to a pc with no translation yet */
  JX_LINK = 4,   /* a direct exit not yet chained: *site may be patched to
                    jump straight to the translation of pc */
};

/* Enters translated code: runs `code` on `core` until an exit. `table` is
 * the core's I-LS-word -> host-code table (used by jalr to chain
 * indirectly); a JX_LINK exit stores its patch site in *site. */
typedef uint64_t (*JitEnter)(void *core, const void *code, uint64_t limit, void *const *table, void **site);

/* An output buffer for generated code. */
typedef struct {
  uint8_t *p, *end;
} JitBuf;

/* How a block ends after its last instruction, when that one is not a
 * jal/jalr (which always leave the block themselves). */
enum { JT_NEXT_INTERP, JT_NEXT_LINK };

/* The most bytes of host code one guest instruction can take (body and
 * out-of-line stub), and the fixed overhead of a block. */
#define JIT_MAX_PER_INSN 160
#define JIT_MAX_BLOCK_EXTRA 256

/* The instructions the JIT translates: everything with no effect outside
 * the registers, the pc and the D-LS. ALU with nonzero funct[10:4] is
 * illegal and left to the interpreter to trap. (Opcode numbers: asm/isa.h.) */
static inline bool jit_plain(uint32_t ir) {
  unsigned op = ir >> 26;
  if (op == 0x00) return !((ir & 0x7ff) >> 4);                 /* ALU */
  return (op >= 0x01 && op <= 0x0A) || (op >= 0x10 && op <= 0x16) || /* immediates, loads */
         (op >= 0x18 && op <= 0x1B) || (op >= 0x20 && op <= 0x25) || /* stores, branches */
         op == 0x28 || op == 0x29;                                    /* jal, jalr */
}

/* Writes the trampoline (enter, and the common exit every block jumps to)
 * and returns the entry point. Called once, at the start of code memory. */
JitEnter jit_be_tramp(JitBuf *b, const JitLayout *lay);

/* Translates the n instructions ir[0..n) found at pc, pc+4, ... and returns
 * the block's entry point. `tail` says how the block ends when ir[n-1] is
 * not jal/jalr: JT_NEXT_INTERP (the next instruction needs the
 * interpreter) or JT_NEXT_LINK (continue at pc + 4n). */
void *jit_be_block(JitBuf *b, uint64_t pc, const uint32_t *ir, int n, int tail);

/* Chains a JX_LINK exit: makes the patch site jump to `target`. Code memory
 * is writable when this is called. Returns the range it changed. */
void jit_be_link(void *site, const void *target, uint8_t **lo, uint8_t **hi);

#endif
