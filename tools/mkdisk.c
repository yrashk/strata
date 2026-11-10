/* mkdisk: builds a bootable Strata disk image.
 *
 *   mkdisk -o disk.img -k kernel.stx [-b blocks] [file...]
 *
 * Layout (512-byte blocks):
 *   0      boot header (see firmware/bootrom.s)
 *   1..8   directory: 128 entries of { name[24], u32 lba, u32 size }
 *   9..    OS code image (I-LS bytes 0x4000..0x8000), then OS data image
 *          (D-LS bytes 0xA000..0xE000), then the kernel's far image (its
 *          SK_T3 sections: the code units, at most 0xD0000 bytes, offset 0 =
 *          far address 0), then each file, block-aligned
 *   rest   free space for files the OS creates
 * Files are stored under their base name. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../common/stx.h"

#define BLK 512u
#define OS_TEXT 0x4000u
#define OS_DATA 0xA000u
#define DIRENTS 128
#define DIRBLOCKS 8
#define FAR_MAX 0xD0000u

static uint8_t *disk;
static uint32_t nblocks = 8192, next_lba = 1 + DIRBLOCKS;

static void put32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

/* Places len bytes at the next free block; returns the first LBA. */
static uint32_t place(const uint8_t *data, uint32_t len, uint32_t *blocks) {
  uint32_t n = (len + BLK - 1) / BLK;
  if (next_lba + n > nblocks) { fprintf(stderr, "mkdisk: disk too small\n"); exit(1); }
  uint32_t lba = next_lba;
  memcpy(disk + (size_t)lba * BLK, data, len);
  next_lba += n;
  *blocks = n;
  return lba;
}

int main(int argc, char **argv) {
  const char *out = NULL, *kernel = NULL;
  const char *files[DIRENTS];
  int nfiles = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "-k") && i + 1 < argc) kernel = argv[++i];
    else if (!strcmp(argv[i], "-b") && i + 1 < argc) nblocks = (uint32_t)strtoul(argv[++i], NULL, 0);
    else if (argv[i][0] == '-') { fprintf(stderr, "usage: mkdisk -o disk.img -k kernel.stx [-b blocks] [file...]\n"); return 2; }
    else if (nfiles < DIRENTS) files[nfiles++] = argv[i];
    else { fprintf(stderr, "mkdisk: at most %d files\n", DIRENTS); return 1; }
  }
  if (!out || !kernel) { fprintf(stderr, "usage: mkdisk -o disk.img -k kernel.stx [-b blocks] [file...]\n"); return 2; }

  disk = calloc(nblocks, BLK);
  StxImage img;
  stx_load(kernel, &img);
  if (img.ils_size <= OS_TEXT || img.dls_size <= OS_DATA) {
    fprintf(stderr, "mkdisk: kernel must place code at I-LS 0x%x and data at D-LS 0x%x\n", OS_TEXT, OS_DATA);
    return 1;
  }
  uint32_t tlen = img.ils_size - OS_TEXT, dlen = img.dls_size - OS_DATA;
  /* the code must fit in the I-LS above 0x4000, the data below the stack */
  if (tlen > 0x4000) { fprintf(stderr, "mkdisk: kernel code is %u bytes, more than 16 KiB\n", tlen); return 1; }
  if (dlen > 0x4000) { fprintf(stderr, "mkdisk: kernel data is %u bytes, more than 16 KiB\n", dlen); return 1; }
  uint32_t tblocks, dblocks;
  uint32_t tlba = place(img.ils + OS_TEXT, tlen, &tblocks);
  uint32_t dlba = place(img.dls + OS_DATA, dlen, &dblocks);
  /* the far image: everything the kernel put in system memory (.far) */
  uint32_t flba = 0, fblocks = 0;
  if (img.t3_size) {
    if (img.t3_size > FAR_MAX) { fprintf(stderr, "mkdisk: kernel far image is %u bytes, more than 0x%x\n", img.t3_size, FAR_MAX); return 1; }
    flba = place(img.t3, img.t3_size, &fblocks);
  }

  uint8_t *dir = disk + BLK;
  for (int f = 0; f < nfiles; f++) {
    FILE *fp = fopen(files[f], "rb");
    if (!fp) { perror(files[f]); return 1; }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    uint8_t *buf = calloc(1, (size_t)sz + 1);
    if (fread(buf, 1, (size_t)sz, fp) != (size_t)sz) { perror(files[f]); return 1; }
    fclose(fp);
    const char *base = strrchr(files[f], '/');
    base = base ? base + 1 : files[f];
    if (strlen(base) > 24) { fprintf(stderr, "mkdisk: name too long: %s\n", base); return 1; }
    uint32_t nb;
    uint32_t lba = place(buf, (uint32_t)sz, &nb);
    uint8_t *e = dir + 32 * f;
    memcpy(e, base, strlen(base));
    put32(e + 24, lba);
    put32(e + 28, (uint32_t)sz);
    free(buf);
  }

  uint8_t *h = disk;
  memcpy(h, "STBOOT01", 8);
  put32(h + 8, tlba);
  put32(h + 12, tblocks);
  put32(h + 16, OS_TEXT);
  put32(h + 20, dlba);
  put32(h + 24, dblocks);
  put32(h + 28, OS_DATA);
  put32(h + 32, OS_TEXT);
  put32(h + 36, 1);
  put32(h + 40, next_lba);
  put32(h + 44, flba);
  put32(h + 48, fblocks);

  FILE *o = fopen(out, "wb");
  if (!o) { perror(out); return 1; }
  fwrite(disk, BLK, nblocks, o);
  fclose(o);
  fprintf(stderr, "mkdisk: %s: %u blocks, OS code %u + data %u + far %u blocks, %d files, %u blocks free\n", out,
          nblocks, tblocks, dblocks, fblocks, nfiles, nblocks - next_lba);
  return 0;
}
