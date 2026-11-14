/* Strata prototype: .stx image loader shared by the RTL simulator harness
 * and the C emulator. Header-only. */
#ifndef STRATA_STX_H
#define STRATA_STX_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../asm/isa.h"

typedef struct {
  uint8_t *ils, *dls, *t2, *t3;
  uint32_t ils_size, dls_size, t2_size, t3_size; /* bytes present in the image */
} StxImage;

static const char *const stx_cause_names[] = {
  "none", "illegal", "lsfault", "capinv", "perm", "bounds", "xalign", "ifault", "xmiss", "pend", "capop",
  "priv", "halt", "stop", "svc",
};

static inline const char *stx_cause_name(int c) {
  return c >= 0 && c <= 14 ? stx_cause_names[c] : "?";
}

static inline uint32_t stx_rd32(FILE *f) {
  uint8_t b[4] = {0};
  if (fread(b, 1, 4, f) != 4) return 0;
  return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}

/* Loads an image; exits with a message on error. */
static inline void stx_load(const char *path, StxImage *img) {
  img->ils = (uint8_t *)calloc(1, ILS_BYTES);
  img->dls = (uint8_t *)calloc(1, DLS_BYTES);
  img->t2 = (uint8_t *)calloc(1, T2_BYTES);
  img->t3 = (uint8_t *)calloc(1, T3_BYTES);
  img->ils_size = img->dls_size = img->t2_size = img->t3_size = 0;
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
  char magic[4];
  if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "STX2", 4)) { fprintf(stderr, "%s: not an STX2 image\n", path); exit(2); }
  uint32_t n = stx_rd32(f);
  for (uint32_t i = 0; i < n; i++) {
    uint32_t kind = stx_rd32(f), base = stx_rd32(f), size = stx_rd32(f);
    (void)stx_rd32(f); /* reserved */
    uint8_t *dst;
    uint32_t limit;
    switch (kind) {
    case SK_ILS: dst = img->ils; limit = ILS_BYTES; break;
    case SK_DLS: dst = img->dls; limit = DLS_BYTES; break;
    case SK_T2: dst = img->t2; limit = T2_BYTES; break;
    case SK_T3: dst = img->t3; limit = T3_BYTES; break;
    default: fprintf(stderr, "%s: unknown section kind %u\n", path, kind); exit(2);
    }
    if ((uint64_t)base + size > limit) { fprintf(stderr, "%s: section too large\n", path); exit(2); }
    uint32_t *sz = kind == SK_ILS ? &img->ils_size : kind == SK_DLS ? &img->dls_size
                 : kind == SK_T2 ? &img->t2_size : &img->t3_size;
    if (base + size > *sz) *sz = base + size;
    if (fread(dst + base, 1, size, f) != size) { fprintf(stderr, "%s: truncated\n", path); exit(2); }
  }
  fclose(f);
}

static inline uint64_t stx_word(const uint8_t *p, uint32_t widx) {
  uint64_t v;
  memcpy(&v, p + (size_t)widx * 8, 8);
  return v;
}

/* The block device's capacity: 16 MiB, as the RTL's (DISK_WORDS). */
#define STX_DISK_BLOCKS 32768u

/* Loads a disk image (or makes an empty disk when path is NULL). The disk
 * has STX_DISK_BLOCKS blocks, or more if the image is larger (rounded up to
 * whole 512-byte blocks); a shorter image is the start of the disk, the
 * rest reads zero (mkdisk writes only the blocks it uses). */
static inline uint8_t *stx_disk_load(const char *path, uint64_t *blocks) {
  uint64_t n = STX_DISK_BLOCKS;
  FILE *f = NULL;
  if (path) {
    f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open disk %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint64_t used = ((uint64_t)sz + 511) / 512;
    if (used > n) n = used;
  }
  uint8_t *d = (uint8_t *)calloc(1, n * 512);
  if (f) {
    if (fread(d, 1, n * 512, f) == 0 && ferror(f)) { fprintf(stderr, "cannot read disk %s\n", path); exit(2); }
    fclose(f);
  }
  *blocks = n;
  return d;
}

/* Writes a disk back as an image: up to its last block that is not all
 * zeros (stx_disk_load reads the rest as zero again). */
static inline void stx_disk_save(const char *path, const uint8_t *d, uint64_t blocks) {
  while (blocks > 1) {
    const uint8_t *b = d + (blocks - 1) * 512;
    int zero = 1;
    for (int i = 0; i < 512 && zero; i++) zero = !b[i];
    if (!zero) break;
    blocks--;
  }
  FILE *f = fopen(path, "wb");
  if (!f || fwrite(d, 512, blocks, f) != blocks) { fprintf(stderr, "cannot write disk %s\n", path); exit(2); }
  fclose(f);
}

#endif
