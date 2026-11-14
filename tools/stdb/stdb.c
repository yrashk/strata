/* stdb: looks into a disk image in the store format.
 *
 *   stdb check IMAGE          the store and the file system, checked
 *   stdb dump IMAGE           every file (name, size, sum, tags, attributes)
 *                             and every other namespace's records, in a form
 *                             that does not depend on where things lie
 *   stdb ls IMAGE [TAG]       names, sizes and tags
 *   stdb get IMAGE NAME [OUT] a file's contents (to the standard output)
 *   stdb info IMAGE           sizes and counts */
#include <stdlib.h>
#include <string.h>

#include "fsl.h"

static StDev dev;
static Store st;
static Fs fs;

static void load(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(1); }
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint64_t fb = ((uint64_t)sz + ST_BLK - 1) / ST_BLK;
  for (uint64_t n = fb > 32768 ? fb : 32768;; n *= 2) { /* the image is cut after its last block in use */
    st_dev_init(&dev, n);
    rewind(f);
    if (fread(dev.img, 1, (size_t)sz, f) != (size_t)sz) { perror(path); exit(1); }
    if (!st_mount(&st, &dev)) break;
    if (strcmp(st.msg, "store larger than the disk") || n > (1u << 26)) { fprintf(stderr, "stdb: %s: %s\n", path, st.msg); exit(1); }
    st_dev_free(&dev);
  }
  fclose(f);
}

static void hex(const uint8_t *p, int n) {
  int text = n > 0;
  for (int i = 0; i < n; i++) text &= p[i] >= 32 && p[i] < 127 && p[i] != '"' && p[i] != '\\';
  if (text) { printf("\"%.*s\"", n, (const char *)p); return; }
  for (int i = 0; i < n; i++) printf("%02x", p[i]);
  if (!n) printf("-");
}

/* The trees of the namespaces that are not the file system's. */
static void dump_rest(void) {
  StTree *nst = st_tree(&st, 0, "ns", 0);
  uint8_t nk[256], nv[16];
  int nkl = 0, nvl;
  while (nst && st_seek(&st, nst, nk, nkl, ST_GT, nk, &nkl, nv, &nvl, NULL)) {
    uint32_t ns = (uint32_t)(nv[0] | nv[1] << 8 | nv[2] << 16 | (uint32_t)nv[3] << 24);
    if (ns == fs.ns) continue;
    uint8_t ck[80] = {(uint8_t)(ns >> 24), (uint8_t)(ns >> 16), (uint8_t)(ns >> 8), (uint8_t)ns}, cv[16];
    int ckl = 4, cvl;
    while (st_seek(&st, &st.cat, ck, ckl, ST_GT, ck, &ckl, cv, &cvl, NULL) && !memcmp(ck, nk + 0, 0) &&
           ck[0] == (uint8_t)(ns >> 24) && ck[1] == (uint8_t)(ns >> 16) && ck[2] == (uint8_t)(ns >> 8) && ck[3] == (uint8_t)ns) {
      char tn[80];
      memcpy(tn, ck + 4, (size_t)ckl - 4);
      tn[ckl - 4] = 0;
      if (!strcmp(tn, ".ext")) continue;
      StTree *t = st_tree(&st, ns, tn, 0);
      uint8_t k[ST_MAXPS / 8], v[ST_MAXPS / 4];
      int kl = 0, vl, fl;
      while (t && st_seek(&st, t, k, kl, ST_GT, k, &kl, v, &vl, &fl)) {
        printf("%.*s/%s ", nkl, (char *)nk, tn);
        hex(k, kl);
        printf(" = ");
        if (!fl) hex(v, vl);
        else {
          int64_t size = st_bsize(&st, t, k, kl);
          uint8_t *b = malloc((size_t)size + 1);
          uint64_t h = 0xCBF29CE484222325ull;
          st_bread(&st, ns, t, k, kl, 0, b, (uint64_t)size);
          for (int64_t i = 0; i < size; i++) h = (h ^ b[i]) * 0x100000001B3ull;
          printf("stream size=%lld sum=%016llx", (long long)size, (unsigned long long)h);
          free(b);
        }
        printf("\n");
      }
    }
  }
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: stdb check|dump|ls|get|info IMAGE [...]\n"); return 2; }
  const char *cmd = argv[1];
  load(argv[2]);
  jmp_buf jb;
  st.jb = &jb;
  if (setjmp(jb)) { fprintf(stderr, "stdb: %s: %s\n", argv[2], st.msg); return 1; }
  int havefs = !fs_open(&st, &fs);
  if (!strcmp(cmd, "check")) {
    int bad = st_check(&st, stderr);
    if (!bad && havefs) bad = fs_check(&fs, stderr);
    if (bad) { fprintf(stderr, "stdb: %s: %d problems\n", argv[2], bad); return 1; }
    printf("%s: commit %llu, %llu pages of %u bytes, %llu free", argv[2], (unsigned long long)st.commit,
           (unsigned long long)st.npages, st.ps, (unsigned long long)st.nfree);
    if (havefs) printf(", %llu files", (unsigned long long)fs.nobj);
    printf(": no problems\n");
    return 0;
  }
  if (!strcmp(cmd, "info")) {
    printf("commit %llu\npage size %u\npages %llu\nfirst page %llu\nfree pages %llu\nboot manifest page %llu\n",
           (unsigned long long)st.commit, st.ps, (unsigned long long)st.npages, (unsigned long long)st.first,
           (unsigned long long)st.nfree, (unsigned long long)st.manifest);
    if (havefs) printf("files %llu\ntags ever made %u\n", (unsigned long long)fs.nobj, fs.nexttag - 1);
    return 0;
  }
  if (!strcmp(cmd, "dump")) {
    if (havefs) fs_dump(&fs, stdout);
    dump_rest();
    return 0;
  }
  if (!havefs) { fprintf(stderr, "stdb: %s: no file system\n", argv[2]); return 1; }
  if (!strcmp(cmd, "ls")) {
    static FsRec r;
    char name[FS_NAMEMAX + 1] = "", tn[FS_NAMEMAX + 1];
    uint64_t oid;
    while (fs_nextname(&fs, name, &oid)) {
      if (fs_rec(&fs, oid, &r)) continue;
      int show = argc < 4;
      for (int i = 0; i < r.ntags && !show; i++) show = fs_tagname(&fs, r.tags[i], tn) >= 0 && !strcmp(tn, argv[3]);
      if (!show) continue;
      printf("%-26s %8llu ", r.name, (unsigned long long)r.size);
      for (int i = 0; i < r.ntags; i++) if (fs_tagname(&fs, r.tags[i], tn) >= 0) printf(" %s", tn);
      printf("\n");
    }
    return 0;
  }
  if (!strcmp(cmd, "get") && argc >= 4) {
    static FsRec r;
    int64_t oid = fs_lookup(&fs, argv[3]);
    if (oid < 0 || fs_rec(&fs, (uint64_t)oid, &r)) { fprintf(stderr, "stdb: no such file: %s\n", argv[3]); return 1; }
    FILE *o = argc > 4 ? fopen(argv[4], "wb") : stdout;
    if (!o) { perror(argv[4]); return 1; }
    uint8_t *b = malloc(1 << 16);
    for (uint64_t off = 0; off < r.size; off += 1 << 16) fwrite(b, 1, (size_t)fs_read(&fs, (uint64_t)oid, off, b, 1 << 16), o);
    if (o != stdout) fclose(o);
    return 0;
  }
  fprintf(stderr, "usage: stdb check|dump|ls|get|info IMAGE [...]\n");
  return 2;
}
