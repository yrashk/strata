/* The dynamic binary translator of strata-emu: the interface emu.c uses.
 *
 * The JIT translates the plain integer ISA (ALU, immediates, loads and
 * stores to the D-LS, branches, jal, jalr) into host code, a block at a
 * time, and runs it directly on the emulator's Core structures. Every
 * other instruction (transfers, waits, capabilities, CSRs, system
 * instructions, overlays, ltag/linst) and every instruction that traps is
 * left to the interpreter: translated code stops in front of it with the
 * core's state exactly as the interpreter would have it.
 *
 * The JIT knows nothing about Core except where its fields are (JitLayout),
 * so emu.c keeps the one definition of the machine. */
#ifndef STRATA_JIT_H
#define STRATA_JIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Byte offsets of the fields the translated code uses, in the emulator's
 * per-core structure: the registers x[32], pc, instret, the two Local
 * Stores, and the hazard range of the device reads in flight (two
 * uint64_t, base and span: only the WebAssembly backend's loads and
 * stores check it). */
typedef struct {
  size_t x, pc, instret, dls, ils, hz;
} JitLayout;

/* The host backend compiled in ("arm64", "x86-64", "wasm"), or NULL when this host
 * has none (the emulator then only interprets). */
const char *jit_backend(void);

/* Sets up code memory and one translation cache per core. `cores` is the
 * emulator's core array, `stride` the size of one element. False if the
 * host has no backend or no executable memory could be mapped. */
bool jit_init(const JitLayout *lay, void *cores, size_t stride, int ncores);

/* Runs core `id` in translated code from its pc until its instret reaches
 * `limit` or the next instruction must be interpreted (it is not
 * translatable, it traps, or the pc is bad). Returns with pc and instret
 * updated; the caller then runs the interpreter for one step if it wants
 * to go on. The caller must not use it while the core has a pending stop
 * or, with the native backends, a pending device read (their loads and
 * stores do not check for bytes in flight; the "wasm" backend's do, against
 * the hazard range). The "wasm" backend translates only hot code: it
 * also returns at a pc it has not translated yet, and the caller
 * interprets on from there. */
void jit_exec(int id, uint64_t limit);

/* The I-LS range [ls, ls + len) of core `id` has been overwritten (tgetx):
 * forget every translation that read from it. */
void jit_invalidate(int id, uint64_t ls, uint64_t len);

#endif
