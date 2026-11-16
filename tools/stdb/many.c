/* many.c: the store with many files, on the host.
 *
 *   stdb-many N [pagesize]
 *
 * Makes a file system of N small files (names f0000000.., two of fifty
 * tags each, one attribute, contents of 0 to 1500 bytes so that some are
 * streams), commits every 10,000, then checks the whole store and the file
 * system's own invariants, and prints what the trees came to: pages, height,
 * bytes of metadata per file. */
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "fsl.h"

int main(int argc, char **argv) {
  uint64_t n = argc > 1 ? strtoull(argv[1], NULL, 0) : 100000;
  uint32_t ps = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 4096;
  uint64_t pages = 64 + n * 3 / 4 + n * 1200 / ps; /* room for the trees and the contents */
  StDev d;
  Store st;
  Fs fs;
  clock_t t0 = clock();
  st_dev_init(&d, pages * (ps / ST_BLK));
  st_format(&d, ps, 3);
  if (st_mount(&st, &d)) { fprintf(stderr, "stdb-many: %s\n", st.msg); return 1; }
  fs_mkfs(&st, &fs);
  static uint8_t body[1500];
  for (int i = 0; i < 1500; i++) body[i] = (uint8_t)(i * 31 + 7);
  for (uint64_t i = 0; i < n; i++) {
    char name[32], t1[16], t2[16];
    const char *tags[2] = {t1, t2};
    snprintf(name, sizeof name, "f%07llu", (unsigned long long)i);
    snprintf(t1, sizeof t1, "t%llu", (unsigned long long)(i % 50));
    snprintf(t2, sizeof t2, "t%llu", (unsigned long long)((i * 7 + 3) % 50));
    int64_t oid = fs_add(&fs, name, body, (i * 2654435761u) % 4 ? (i * 37) % 200 : 1100 + i % 400, tags, 2, 0);
    if (oid < 0) { fprintf(stderr, "stdb-many: %s\n", fs.msg); return 1; }
    uint8_t v[8] = {(uint8_t)i, (uint8_t)(i >> 8), (uint8_t)(i >> 16), (uint8_t)(i >> 24)};
    if (fs_setattr(&fs, (uint64_t)oid, "serial", 0, v, 8)) { fprintf(stderr, "stdb-many: attribute\n"); return 1; }
    if (i % 10000 == 9999 && fs_commit(&fs)) { fprintf(stderr, "stdb-many: %s\n", fs.msg); return 1; }
  }
  if (fs_commit(&fs)) { fprintf(stderr, "stdb-many: %s\n", fs.msg); return 1; }
  double made = (double)(clock() - t0) / CLOCKS_PER_SEC;
  if (st_check(&st, stderr) || fs_check(&fs, stderr)) { fprintf(stderr, "stdb-many: the check failed\n"); return 1; }
  /* a few lookups, and a tag's files through the index */
  for (uint64_t i = 0; i < n; i += n / 7 + 1) {
    char name[48];
    snprintf(name, sizeof name, "t%llu/t%llu/f%07llu", (unsigned long long)(i % 50), (unsigned long long)((i * 7 + 3) % 50), (unsigned long long)i);
    if (fs_lookup(&fs, name) != (int64_t)i + 1) { fprintf(stderr, "stdb-many: %s is not found\n", name); return 1; }
  }
  StTree *ext = st_tree(&st, fs.ns, ".ext", 0);
  uint64_t used = st.npages - st.first - st.nfree;
  printf("stdb-many: %llu files, %u-byte pages: made in %.1f s; heights: obj %llu, name %llu, attr %llu, data %llu, extents %llu; "
         "%llu pages in use (%.0f bytes a file, contents included); commit %llu; allocator passes at most %d: no problems\n",
         (unsigned long long)n, ps, made, (unsigned long long)fs.obj->height, (unsigned long long)fs.name->height,
         (unsigned long long)fs.attr->height, (unsigned long long)fs.data->height, (unsigned long long)(ext ? ext->height : 0),
         (unsigned long long)used, (double)used * ps / (double)n, (unsigned long long)st.commit, st.maxiter);
  st_close(&st);
  st_dev_free(&d);
  return 0;
}
