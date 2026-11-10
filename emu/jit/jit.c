/* The JIT's common part: executable memory, the per-core translation
 * caches, block formation, the dispatcher that enters translated code and
 * chains blocks together, and invalidation when tgetx rewrites the I-LS.
 * The host code itself comes from a backend (jit_arm64.c, jit_x86_64.c).
 *
 * A block is a superblock: it starts at any pc, runs straight on past
 * conditional branches (a taken branch is a side exit), and ends at a jal
 * or jalr, in front of an instruction the JIT does not translate, at the
 * end of the I-LS, or after MAXBLK instructions. Blocks are found through a
 * direct-mapped table per core (one entry per I-LS word): the I-LS is only
 * 16384 words, so there is no hashing and no collision. */
#define _DEFAULT_SOURCE /* glibc: MAP_ANON under -std=c11 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jit_be.h"
#include "../../asm/isa.h"

#if defined(__aarch64__) || defined(__x86_64__)
#define JIT_HOST 1
#endif

#ifndef JIT_HOST

/* No backend for this host: the emulator only interprets. */
const char *jit_backend(void) { return NULL; }
bool jit_init(const JitLayout *lay, void *cores, size_t stride, int ncores) {
  (void)lay, (void)cores, (void)stride, (void)ncores;
  return false;
}
void jit_exec(int id, uint64_t limit) { (void)id, (void)limit; }
void jit_invalidate(int id, uint64_t ls, uint64_t len) { (void)id, (void)ls, (void)len; }

#else

#include <sys/mman.h>
#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#endif

#define MAXJCORES 16
#define MAXBLK 128                /* guest instructions per block, at most */
#define ILS_WORDS (ILS_BYTES / 4)
#define TRAMP_BYTES 4096
/* Code memory per core. All of it sits in one mapping so that every block
 * reaches the trampoline with a direct branch (arm64: +-128 MiB). */
#define REGION_BYTES (4u << 20)

typedef struct {
  uint8_t *core;            /* the emulator's Core */
  uint8_t *lo, *hi, *p;     /* this core's code region and its fill point */
  void **table;             /* I-LS word -> block entry, or NULL */
  uint64_t tbits[ILS_WORDS / 64]; /* I-LS words that some block was translated from */
  uint64_t gen;             /* bumped on every flush: stale patch sites are dropped */
} JCore;

static JCore jcs[MAXJCORES];
static int njcores;
static JitLayout L;
static JitEnter enter;
static uint8_t *mem;
static size_t memlen;
static bool wx; /* the mapping is W^X (mprotect around writes), not RWX */

const char *jit_backend(void) {
#if defined(__aarch64__)
  return "arm64";
#else
  return "x86-64";
#endif
}

/* Code memory is made writable only while code is written. On Apple arm64
 * a MAP_JIT mapping is RWX but each thread sees it either writable or
 * executable (pthread_jit_write_protect_np); elsewhere it is plain RWX, or
 * W^X through mprotect if the system refuses RWX. */
static void wr_begin(void) {
#if defined(__APPLE__) && defined(__aarch64__)
  pthread_jit_write_protect_np(0);
#else
  if (wx) mprotect(mem, memlen, PROT_READ | PROT_WRITE);
#endif
}

static void wr_end(uint8_t *lo, uint8_t *hi) {
#if defined(__APPLE__) && defined(__aarch64__)
  pthread_jit_write_protect_np(1);
  sys_icache_invalidate(lo, (size_t)(hi - lo));
#else
  if (wx) mprotect(mem, memlen, PROT_READ | PROT_EXEC);
  __builtin___clear_cache((char *)lo, (char *)hi); /* nothing to do on x86 */
#endif
}

bool jit_init(const JitLayout *lay, void *cores, size_t stride, int ncores) {
  if (ncores < 1 || ncores > MAXJCORES) return false;
  /* the backends address these fields with short unsigned offsets */
  size_t offs[] = {lay->x, lay->pc, lay->instret};
  for (unsigned i = 0; i < sizeof offs / sizeof *offs; i++)
    if (offs[i] % 8 || offs[i] + 8 * 32 > 32760) return false;
  L = *lay;
  memlen = TRAMP_BYTES + (size_t)ncores * REGION_BYTES;
  int flags = MAP_PRIVATE | MAP_ANON;
#if defined(__APPLE__)
  flags |= MAP_JIT;
#endif
  void *m = mmap(NULL, memlen, PROT_READ | PROT_WRITE | PROT_EXEC, flags, -1, 0);
  if (m == MAP_FAILED) {
    m = mmap(NULL, memlen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) return false;
    wx = true;
  }
  mem = m;
  wr_begin();
  JitBuf b = {mem, mem + TRAMP_BYTES};
  enter = jit_be_tramp(&b, &L);
  wr_end(mem, b.p);
  for (int i = 0; i < ncores; i++) {
    JCore *j = &jcs[i];
    j->core = (uint8_t *)cores + (size_t)i * stride;
    j->lo = j->p = mem + TRAMP_BYTES + (size_t)i * REGION_BYTES;
    j->hi = j->lo + REGION_BYTES;
    j->table = calloc(ILS_WORDS, sizeof *j->table);
    if (!j->table) return false;
  }
  njcores = ncores;
  return true;
}

/* Forgets every translation of a core (its region is reused from the
 * start). Only ever called from outside translated code. */
static void flush(JCore *j) {
  j->p = j->lo;
  memset(j->table, 0, ILS_WORDS * sizeof *j->table);
  memset(j->tbits, 0, sizeof j->tbits);
  j->gen++;
}

/* Translates the block at pc, or returns NULL when the instruction at pc
 * is one for the interpreter. */
static void *translate(JCore *j, uint64_t pc) {
  const uint8_t *ils = j->core + L.ils;
  uint32_t ir[MAXBLK];
  int n = 0, tail = JT_NEXT_LINK;
  for (uint64_t p = pc; n < MAXBLK && p < ILS_BYTES; p += 4) {
    uint32_t w;
    memcpy(&w, ils + p, 4);
    if (!jit_plain(w)) { tail = JT_NEXT_INTERP; break; }
    ir[n++] = w;
    if (w >> 26 == OP_JAL || w >> 26 == OP_JALR) break;
  }
  if (!n) return NULL;
  size_t need = (size_t)n * JIT_MAX_PER_INSN + JIT_MAX_BLOCK_EXTRA;
  if ((size_t)(j->hi - j->p) < need) flush(j);
  wr_begin();
  JitBuf b = {j->p, j->hi};
  void *entry = jit_be_block(&b, pc, ir, n, tail);
  wr_end(j->p, b.p);
  if (b.p > j->hi) { fprintf(stderr, "jit: code region overflow\n"); abort(); }
  j->p = (uint8_t *)(((uintptr_t)b.p + 15) & ~(uintptr_t)15);
  for (uint64_t w = pc / 4; w < pc / 4 + (uint64_t)n; w++) j->tbits[w / 64] |= 1ull << (w % 64);
  j->table[pc / 4] = entry;
  return entry;
}

void jit_exec(int id, uint64_t limit) {
  JCore *j = &jcs[id];
  uint64_t *pcp = (uint64_t *)(j->core + L.pc), *ip = (uint64_t *)(j->core + L.instret);
  void *site = NULL;
  uint64_t site_gen = 0;
  while (*ip < limit) {
    uint64_t pc = *pcp;
    if ((pc & 3) || pc >= ILS_BYTES) return; /* the interpreter raises the fetch fault */
    void *code = j->table[pc / 4];
    if (!code && !(code = translate(j, pc))) return;
    if (site && site_gen == j->gen) { /* chain the exit we came from to this block */
      uint8_t *lo, *hi;
      wr_begin();
      jit_be_link(site, code, &lo, &hi);
      wr_end(lo, hi);
    }
    site = NULL;
    uint64_t why = enter(j->core, code, limit, (void *const *)j->table, &site);
    if (why == JX_INTERP) return;
    if (why == JX_LINK) site_gen = j->gen;
    else site = NULL;
  }
}

void jit_invalidate(int id, uint64_t ls, uint64_t len) {
  if (id >= njcores || !len) return;
  JCore *j = &jcs[id];
  uint64_t w0 = ls / 4, w1 = (ls + len + 3) / 4;
  if (w1 > ILS_WORDS) w1 = ILS_WORDS;
  for (uint64_t w = w0; w < w1; w++) {
    if (!(w % 64) && w + 64 <= w1 && !j->tbits[w / 64]) { w += 63; continue; }
    if (j->tbits[w / 64] >> (w % 64) & 1) { flush(j); return; }
  }
}

#endif
