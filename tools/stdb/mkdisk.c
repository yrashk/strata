/* mkdisk (store format): builds a bootable Strata disk image.
 *
 *   mkdisk -o disk.img -k kernel.stx [-b blocks] [-p pagesize] [-B names]
 *          [[-t tag,tag...] [-a name=value] file...]
 *
 * -t sets the tags of the files that follow it (-t "" for none); -a gives
 * them an attribute (a number, or else a string; -a "" for none again).
 * -B names the boot objects, the files the kernel loads before any server
 * runs (default proc,dev,fs; -B "" for a disk without them): each must be
 * among the files, and is stored in one piece and listed in the boot
 * manifest. With -B "" and no files the disk gets no store at all: the
 * boot header and the kernel's images only (a disk too small for more).
 *
 * Layout (512-byte blocks; pages of 4096 bytes unless -p says 1024 or 2048):
 *   block 0   boot header (see firmware/bootrom.s; offset 56 "STDB", 60 u32
 *             page size)
 *   pages 1,2 the store's meta pages
 *   page 3..  OS code image (I-LS bytes 0x4000..0x8000), OS data image (D-LS
 *             bytes 0xA000..0xE000), the kernel's far image
 *   then      the store (doc/strata-fs-proposal.md): the file system's
 *             trees and the files, in namespace "fs"
 * Files are stored under their base name. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../common/stx.h"
#include "fsl.h"

#define OS_TEXT 0x4000u
#define OS_DATA 0xA000u
#define FAR_MAX 0xD0000u
#define MAXFILES 65536

static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }

static StDev dev;
static uint32_t next_lba;

/* Places len bytes at the next free block; returns the first LBA. */
static uint32_t place(const uint8_t *data, uint32_t len, uint32_t *blocks) {
  uint32_t n = (len + ST_BLK - 1) / ST_BLK;
  if (next_lba + n > dev.nblocks) { fprintf(stderr, "mkdisk: disk too small\n"); exit(1); }
  uint32_t lba = next_lba;
  memcpy(dev.img + (size_t)lba * ST_BLK, data, len);
  next_lba += n;
  *blocks = n;
  return lba;
}

static void usage(void) {
  fprintf(stderr, "usage: mkdisk -o disk.img -k kernel.stx [-b blocks] [-p pagesize] [-B names] [[-t tags] [-a name=value] file...]\n");
  exit(2);
}

int main(int argc, char **argv) {
  const char *out = NULL, *kernel = NULL, *bootnames = "proc,dev,fs";
  static const char *files[MAXFILES], *ftags[MAXFILES], *fattr[MAXFILES];
  const char *cur_tags = "", *cur_attr = "";
  uint32_t nblocks = STX_DISK_BLOCKS, ps = 4096;
  int nfiles = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "-k") && i + 1 < argc) kernel = argv[++i];
    else if (!strcmp(argv[i], "-b") && i + 1 < argc) nblocks = (uint32_t)strtoul(argv[++i], NULL, 0);
    else if (!strcmp(argv[i], "-p") && i + 1 < argc) ps = (uint32_t)strtoul(argv[++i], NULL, 0);
    else if (!strcmp(argv[i], "-B") && i + 1 < argc) bootnames = argv[++i];
    else if (!strcmp(argv[i], "-t") && i + 1 < argc) cur_tags = argv[++i];
    else if (!strcmp(argv[i], "-a") && i + 1 < argc) cur_attr = argv[++i];
    else if (argv[i][0] == '-') usage();
    else if (nfiles < MAXFILES) { ftags[nfiles] = cur_tags; fattr[nfiles] = cur_attr; files[nfiles++] = argv[i]; }
    else { fprintf(stderr, "mkdisk: too many files\n"); return 1; }
  }
  if (!out || !kernel) usage();
  if (ps != 1024 && ps != 2048 && ps != 4096) { fprintf(stderr, "mkdisk: the page size is 1024, 2048 or 4096\n"); return 1; }

  st_dev_init(&dev, nblocks);
  next_lba = 3 * (ps / ST_BLK);
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
  uint8_t *h = dev.img;
  memcpy(h, "STBOOT01", 8);
  put32(h + 8, tlba);
  put32(h + 12, tblocks);
  put32(h + 16, OS_TEXT);
  put32(h + 20, dlba);
  put32(h + 24, dblocks);
  put32(h + 28, OS_DATA);
  put32(h + 32, OS_TEXT);
  put32(h + 44, flba);
  put32(h + 48, fblocks);

  if (!nfiles && !*bootnames) { /* no store: the kernel's images only */
    FILE *o = fopen(out, "wb");
    if (!o) { perror(out); return 1; }
    fwrite(dev.img, ST_BLK, next_lba, o);
    fclose(o);
    fprintf(stderr, "mkdisk: %s: %u blocks, OS code %u + data %u + far %u blocks, no store\n", out, nblocks, tblocks, dblocks, fblocks);
    return 0;
  }
  uint64_t first = (next_lba + ps / ST_BLK - 1) / (ps / ST_BLK);
  if (first + ST_RES + 8 > nblocks / (ps / ST_BLK)) { fprintf(stderr, "mkdisk: disk too small\n"); return 1; }
  st_format(&dev, ps, first);
  Store st;
  Fs fs;
  jmp_buf jb;
  if (st_mount(&st, &dev)) { fprintf(stderr, "mkdisk: %s\n", st.msg); return 1; }
  st.jb = &jb;
  if (setjmp(jb)) { fprintf(stderr, "mkdisk: %s\n", st.msg); return 1; }
  fs_mkfs(&st, &fs);

  int nboot = 0;
  char seen[16][20];
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
    /* its tags */
    char *tl = strdup(ftags[f]);
    const char *tags[256];
    int nt = 0;
    for (char *t = strtok(tl, ","); t && nt < 256; t = strtok(NULL, ",")) tags[nt++] = t;
    /* a boot object? */
    int boot = 0;
    size_t bl = strlen(base);
    for (const char *b = bootnames; *b;) {
      const char *e = strchr(b, ',');
      size_t l = e ? (size_t)(e - b) : strlen(b);
      if (l == bl && !memcmp(b, base, l)) boot = 1;
      b += l + (e != NULL);
    }
    int64_t oid = fs_add(&fs, base, buf, (uint64_t)sz, tags, nt, boot);
    if (oid < 0) { fprintf(stderr, "mkdisk: %s\n", fs.msg); return 1; }
    if (boot && nboot < 16) snprintf(seen[nboot++], sizeof seen[0], "%s", base);
    if (*fattr[f]) {
      char *a = strdup(fattr[f]), *eq = strchr(a, '=');
      if (!eq || eq == a) { fprintf(stderr, "mkdisk: -a takes name=value\n"); return 1; }
      *eq++ = 0;
      char *end;
      unsigned long long num = strtoull(eq, &end, 0);
      uint8_t nv[8];
      for (int i = 0; i < 8; i++) nv[i] = (uint8_t)(num >> (8 * i));
      int r = *eq && !*end ? fs_setattr(&fs, (uint64_t)oid, a, 0, nv, 8)
                           : fs_setattr(&fs, (uint64_t)oid, a, 1, (uint8_t *)eq, (int)strlen(eq));
      if (r) { fprintf(stderr, "mkdisk: bad attribute for %s: %s\n", base, fattr[f]); return 1; }
      free(a);
    }
    free(tl);
    free(buf);
  }
  /* every boot object asked for is there */
  for (const char *b = bootnames; *b;) {
    const char *e = strchr(b, ',');
    size_t l = e ? (size_t)(e - b) : strlen(b);
    int found = 0;
    for (int i = 0; i < nboot; i++) found |= strlen(seen[i]) == l && !memcmp(seen[i], b, l);
    if (l && !found) { fprintf(stderr, "mkdisk: boot object %.*s is not among the files (-B \"\" for a disk without servers)\n", (int)l, b); return 1; }
    b += l + (e != NULL);
  }
  if (fs_commit(&fs)) { fprintf(stderr, "mkdisk: %s\n", fs.msg); return 1; }
  if (st_check(&st, stderr) || fs_check(&fs, stderr)) { fprintf(stderr, "mkdisk: the image does not pass its own check\n"); return 1; }
  uint64_t nfree = st.nfree, npages = st.npages;
  st_close(&st);

  uint64_t used = dev.nblocks;
  while (used > 1 && !memcmp(dev.img + (used - 1) * ST_BLK, dev.img + dev.nblocks * ST_BLK - ST_BLK, ST_BLK) &&
         !dev.img[(used - 1) * ST_BLK]) {
    int z = 1;
    for (uint32_t i = 0; i < ST_BLK && z; i++) z = !dev.img[(used - 1) * ST_BLK + i];
    if (!z) break;
    used--;
  }
  FILE *o = fopen(out, "wb");
  if (!o) { perror(out); return 1; }
  fwrite(dev.img, ST_BLK, used, o); /* only up to the last block in use: the rest of the disk reads zero */
  fclose(o);
  fprintf(stderr, "mkdisk: %s: %u blocks, OS code %u + data %u + far %u blocks, %d files, %d boot objects, %llu of %llu pages free\n",
          out, nblocks, tblocks, dblocks, fblocks, nfiles, nboot, (unsigned long long)nfree, (unsigned long long)npages);
  return 0;
}
