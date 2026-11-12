/* mkhex: produces $readmemh files that put Strata images into block RAM.
 *
 *   mkhex ils  image.stx out.hex [kib]    I-LS contents (kib x 128 64-bit words; default 64 KiB)
 *   mkhex dls  image.stx out.hex [kib]    D-LS contents (the same)
 *   mkhex disk disk.img words out.hex     the first `words` 64-bit words of a disk
 *   mkhex plat ncores disk_blocks out.hex [nxmap [t2_bytes [dls_kib [ils_kib]]]]
 *                                          platform table bytes (common/platform.h); t2_bytes:
 *                                          the cluster store's size in its memory entry, for
 *                                          a build whose T2 is smaller than T2_BYTES (T2_W)
 *                                          (0: T2_BYTES); dls_kib / ils_kib: the Local Stores
 *                                          (the RTL's DLS_KIB / ILS_KIB; default 64) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../common/stx.h"
#include "../common/platform.h"

static FILE *out(const char *p) {
  FILE *f = fopen(p, "w");
  if (!f) { perror(p); exit(1); }
  return f;
}

static void words(FILE *f, const uint8_t *p, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) fprintf(f, "%016llx\n", (unsigned long long)stx_word(p, i));
}

int main(int argc, char **argv) {
  if ((argc == 4 || argc == 5) && (!strcmp(argv[1], "ils") || !strcmp(argv[1], "dls"))) {
    StxImage img;
    stx_load(argv[2], &img);
    unsigned kib = argc == 5 ? (unsigned)strtoul(argv[4], NULL, 0) : LS_DEF_KIB;
    if (!ls_kib_ok(kib)) { fprintf(stderr, "mkhex: Local Store KiB: a power of two, 4..64\n"); return 2; }
    bool ils = !strcmp(argv[1], "ils");
    if ((ils ? img.ils_size : img.dls_size) > kib * 1024) {
      fprintf(stderr, "mkhex: %s: the %s section does not fit %u KiB\n", argv[2], ils ? "I-LS" : "D-LS", kib);
      return 1;
    }
    FILE *f = out(argv[3]);
    words(f, ils ? img.ils : img.dls, kib * 128);
    fclose(f);
    return 0;
  }
  if (argc == 5 && !strcmp(argv[1], "disk")) {
    uint64_t blocks;
    uint8_t *d = stx_disk_load(argv[2], &blocks);
    uint32_t n = (uint32_t)strtoul(argv[3], NULL, 0);
    if ((uint64_t)n > blocks * 64) { fprintf(stderr, "mkhex: disk has only %llu words\n", (unsigned long long)(blocks * 64)); return 1; }
    FILE *f = out(argv[4]);
    words(f, d, n);
    fclose(f);
    return 0;
  }
  if (argc >= 5 && argc <= 9 && !strcmp(argv[1], "plat")) {
    uint8_t t[PLAT_LEN];
    unsigned nx = argc >= 6 ? (unsigned)strtoul(argv[5], NULL, 0) : NXMAP_DEF;
    if (nx < NXMAP_MIN || nx > NXMAP_MAX) { fprintf(stderr, "mkhex: overlay map entries: 4..16\n"); return 2; }
    unsigned dk = argc >= 8 ? (unsigned)strtoul(argv[7], NULL, 0) : LS_DEF_KIB;
    unsigned ik = argc >= 9 ? (unsigned)strtoul(argv[8], NULL, 0) : LS_DEF_KIB;
    if (!ls_kib_ok(dk) || !ls_kib_ok(ik)) { fprintf(stderr, "mkhex: Local Store KiB: a power of two, 4..64\n"); return 2; }
    plat_build(t, atoi(argv[2]), strtoull(argv[3], NULL, 0), nx, dk, ik);
    if (argc >= 7 && strtoull(argv[6], NULL, 0)) { /* entry 1 is T2's memory entry: its size */
      uint64_t t2 = strtoull(argv[6], NULL, 0);
      if (!t2 || t2 > T2_BYTES || (t2 & 7)) { fprintf(stderr, "mkhex: T2 bytes: 8..%u, whole words\n", (unsigned)T2_BYTES); return 2; }
      plat_put(t + 32 + 1 * 32 + 24, t2, 8);
      plat_put(t + 16, 0, 4); /* the checksum again */
      uint32_t sum = 0;
      for (int i = 0; i < PLAT_LEN; i++) sum += t[i];
      plat_put(t + 16, sum, 4);
    }
    FILE *f = out(argv[4]);
    for (int i = 0; i < PLAT_LEN; i++) fprintf(f, "%02x\n", t[i]);
    fclose(f);
    return 0;
  }
  fprintf(stderr, "usage: mkhex ils|dls image.stx out.hex [kib] | disk disk.img words out.hex | plat ncores blocks out.hex [nxmap [t2bytes [dls_kib [ils_kib]]]]\n");
  return 2;
}
