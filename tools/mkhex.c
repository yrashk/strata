/* mkhex: produces $readmemh files that put Strata images into block RAM.
 *
 *   mkhex ils  image.stx out.hex          I-LS contents (8192 x 64-bit words)
 *   mkhex dls  image.stx out.hex          D-LS contents (8192 x 64-bit words)
 *   mkhex disk disk.img words out.hex     the first `words` 64-bit words of a disk
 *   mkhex plat ncores disk_blocks out.hex platform table bytes (common/platform.h) */
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
  if (argc == 4 && (!strcmp(argv[1], "ils") || !strcmp(argv[1], "dls"))) {
    StxImage img;
    stx_load(argv[2], &img);
    FILE *f = out(argv[3]);
    if (!strcmp(argv[1], "ils")) words(f, img.ils, ILS_BYTES / 8);
    else words(f, img.dls, DLS_BYTES / 8);
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
  if (argc == 5 && !strcmp(argv[1], "plat")) {
    uint8_t t[PLAT_LEN];
    plat_build(t, atoi(argv[2]), strtoull(argv[3], NULL, 0));
    FILE *f = out(argv[4]);
    for (int i = 0; i < PLAT_LEN; i++) fprintf(f, "%02x\n", t[i]);
    fclose(f);
    return 0;
  }
  fprintf(stderr, "usage: mkhex ils|dls image.stx out.hex | disk disk.img words out.hex | plat ncores blocks out.hex\n");
  return 2;
}
