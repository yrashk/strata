/* The debug engine's hooks in the emulator (emu/debug.c is the engine).
 *
 * emu.c includes this right after its Core type. Every hook is guarded by
 * `dbg_on`, which only --debug sets: without it the emulator runs exactly
 * as it always has (the same code paths, the fast loop and the JITs), and
 * each hook costs one predictable branch on a path that is not hot (a far
 * write, a trap, a console byte, a disk write).
 *
 * The engine observes everything else from outside step(): it decodes the
 * instruction a core is about to execute and compares the core before and
 * after (emu/debug.c, "one tick"). */
#ifndef STRATA_EMU_DEBUG_H
#define STRATA_EMU_DEBUG_H

static bool dbg_on;                                  /* --debug: the engine runs the machine */
static bool dbg_muted;                               /* replaying ticks already seen: no output, no messages */
static void dbg_far_written(uint8_t space, uint64_t addr); /* 8 bytes of T2 / T3 at addr were written */
static void dbg_disk_written(uint64_t off, uint64_t len);  /* the block device wrote the disk */
static void dbg_trap(Core *c, int cause, uint64_t tval);   /* a trap is being taken */
static void dbg_con_out(uint8_t b);                  /* a console output byte (instead of stdout) */

#endif
