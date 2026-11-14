/* fsl.c: the file system's trees for the host tools (see fsl.h). */
#include <stdlib.h>
#include <string.h>

#include "fsl.h"

static uint16_t g16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static void p16(uint8_t *p, unsigned v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static uint32_t g32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void p32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static uint64_t g64(const uint8_t *p) { return g32(p) | (uint64_t)g32(p + 4) << 32; }
static void p64(uint8_t *p, uint64_t v) { p32(p, (uint32_t)v); p32(p + 4, (uint32_t)(v >> 32)); }
static void pbe32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * (3 - i))); }
static uint32_t gbe32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void pbe64(uint8_t *p, uint64_t v) { pbe32(p, (uint32_t)(v >> 32)); pbe32(p + 4, (uint32_t)v); }
static uint64_t gbe64(const uint8_t *p) { return (uint64_t)gbe32(p) << 32 | gbe32(p + 4); }

static void trees(Fs *fs, int create) {
  fs->obj = st_tree(fs->st, fs->ns, "obj", create);
  fs->data = st_tree(fs->st, fs->ns, "data", create);
  fs->name = st_tree(fs->st, fs->ns, "name", create);
  fs->attr = st_tree(fs->st, fs->ns, "attr", create);
  fs->dict = st_tree(fs->st, fs->ns, "dict", create);
}

static void counters_save(Fs *fs) {
  uint8_t v[24];
  p64(v, fs->nextoid); p64(v + 8, fs->nobj); p32(v + 16, fs->nexttag); p32(v + 20, fs->nextattr);
  st_put(fs->st, fs->dict, "!", 1, v, 24, 0);
}

void fs_mkfs(Store *st, Fs *fs) {
  memset(fs, 0, sizeof *fs);
  fs->st = st;
  fs->ns = st_ns(st, "fs", 1);
  trees(fs, 1);
  fs->nextoid = 1;
  fs->nexttag = 1;
  fs->nextattr = FS_A_USER;
  counters_save(fs);
}

int fs_open(Store *st, Fs *fs) {
  uint8_t v[24];
  int vl;
  memset(fs, 0, sizeof *fs);
  fs->st = st;
  if (!(fs->ns = st_ns(st, "fs", 0))) return -1;
  trees(fs, 0);
  if (!fs->obj || !fs->data || !fs->name || !fs->attr || !fs->dict) return -1;
  if (!st_get(st, fs->dict, "!", 1, v, &vl, NULL) || vl != 24) return -1;
  fs->nextoid = g64(v); fs->nobj = g64(v + 8); fs->nexttag = g32(v + 16); fs->nextattr = g32(v + 20);
  return 0;
}

/* ---- records --------------------------------------------------------------- */

static int rec_enc(const FsRec *r, uint8_t *b) {
  int n = 32;
  b[0] = (uint8_t)r->kind; b[1] = (uint8_t)r->flags;
  p16(b + 2, (unsigned)r->ntags); p16(b + 4, (unsigned)r->nattr); p16(b + 6, (unsigned)r->nl);
  p64(b + 8, r->size); p64(b + 16, r->created); p64(b + 24, r->modified);
  memcpy(b + n, r->name, (size_t)r->nl); n += r->nl;
  for (int i = 0; i < r->ntags; i++, n += 4) p32(b + n, r->tags[i]);
  for (int i = 0; i < r->nattr; i++) {
    p32(b + n, r->attr[i].id); b[n + 4] = (uint8_t)r->attr[i].type; b[n + 5] = (uint8_t)r->attr[i].len;
    memcpy(b + n + 6, r->attr[i].val, (size_t)r->attr[i].len);
    n += 6 + r->attr[i].len;
  }
  return n;
}

static int rec_dec(FsRec *r, const uint8_t *b, int len) {
  if (len < 32) return -1;
  r->kind = b[0]; r->flags = b[1];
  r->ntags = g16(b + 2); r->nattr = g16(b + 4); r->nl = g16(b + 6);
  r->size = g64(b + 8); r->created = g64(b + 16); r->modified = g64(b + 24);
  int n = 32;
  if (r->nl > FS_NAMEMAX || r->ntags > 256 || r->nattr > 32 || n + r->nl + 4 * r->ntags > len) return -1;
  memcpy(r->name, b + n, (size_t)r->nl); r->name[r->nl] = 0; n += r->nl;
  for (int i = 0; i < r->ntags; i++, n += 4) r->tags[i] = g32(b + n);
  for (int i = 0; i < r->nattr; i++) {
    if (n + 6 > len || n + 6 + b[n + 5] > len) return -1;
    r->attr[i].id = g32(b + n); r->attr[i].type = b[n + 4]; r->attr[i].len = b[n + 5];
    memcpy(r->attr[i].val, b + n + 6, b[n + 5]);
    n += 6 + b[n + 5];
  }
  return n == len ? 0 : -1;
}

int fs_rec(Fs *fs, uint64_t oid, FsRec *r) {
  uint8_t k[8], b[FS_RECMAX];
  pbe64(k, oid);
  int64_t n = st_bread(fs->st, fs->ns, fs->obj, k, 8, 0, b, sizeof b);
  if (n < 0 || rec_dec(r, b, (int)n)) return -1;
  r->oid = oid;
  return 0;
}

static int rec_save(Fs *fs, const FsRec *r) {
  uint8_t k[8], b[FS_RECMAX + 600];
  int n = rec_enc(r, b);
  if (n > FS_RECMAX) return -1;
  pbe64(k, r->oid);
  st_bdel(fs->st, fs->ns, fs->obj, k, 8);
  st_bwrite(fs->st, fs->ns, fs->obj, k, 8, 0, b, (uint64_t)n, 0);
  return 0;
}

/* ---- the attribute index ----------------------------------------------------- */

static int akey(uint8_t *k, uint32_t id, const uint8_t *val, int vl, uint64_t oid) {
  pbe32(k, id);
  memcpy(k + 4, val, (size_t)vl);
  pbe64(k + 4 + vl, oid);
  return 12 + vl;
}

static void idx(Fs *fs, int add, uint32_t id, const uint8_t *val, int vl, uint64_t oid) {
  uint8_t k[4 + 300 + 8];
  int kl = akey(k, id, val, vl, oid);
  if (add) st_put(fs->st, fs->attr, k, kl, "", 0, 0);
  else st_del(fs->st, fs->attr, k, kl);
}

static void idx_int(Fs *fs, int add, uint32_t id, uint64_t v, uint64_t oid) {
  uint8_t b[8];
  pbe64(b, v);
  idx(fs, add, id, b, 8, oid);
}

/* An attribute's value as its index key holds it. */
static int aval(uint8_t *out, int type, const uint8_t *val, int len) {
  if (type == 0) { pbe64(out, g64(val)); return 8; }
  memcpy(out, val, (size_t)len);
  out[len] = 0;
  return len + 1;
}

/* ---- the dictionary ---------------------------------------------------------- */

static int64_t dict_id(Fs *fs, char pre, const char *name, int nl, int create, uint32_t type) {
  uint8_t k[300], v[16], rk[5];
  int vl;
  if (nl < 1 || nl > FS_NAMEMAX || memchr(name, '/', (size_t)nl) || memchr(name, 0, (size_t)nl)) return -1;
  k[0] = (uint8_t)pre;
  memcpy(k + 1, name, (size_t)nl);
  if (st_get(fs->st, fs->dict, k, nl + 1, v, &vl, NULL)) return g32(v);
  if (!create) return -1;
  uint32_t id = pre == 't' ? fs->nexttag++ : fs->nextattr++;
  memset(v, 0, 16);
  p32(v, id);
  if (pre == 'a') p32(v + 4, type);
  if (st_put(fs->st, fs->dict, k, nl + 1, v, pre == 't' ? 16 : 8, 0) < 0) return -1;
  rk[0] = (uint8_t)(pre - 32);
  pbe32(rk + 1, id);
  st_put(fs->st, fs->dict, rk, 5, name, nl, 0);
  return id;
}

static int dict_name(Fs *fs, char pre, uint32_t id, char *out) {
  uint8_t rk[5];
  int vl;
  rk[0] = (uint8_t)pre;
  pbe32(rk + 1, id);
  if (!st_get(fs->st, fs->dict, rk, 5, (uint8_t *)out, &vl, NULL)) return -1;
  out[vl] = 0;
  return vl;
}

int fs_tagname(Fs *fs, uint32_t id, char *out) { return dict_name(fs, 'T', id, out); }

int fs_attrname(Fs *fs, uint32_t id, char *out) {
  static const char *builtin[] = {0, "tag", "size", "modified", "boot"};
  if (id >= 1 && id <= 4) { strcpy(out, builtin[id]); return (int)strlen(out); }
  return dict_name(fs, 'A', id, out);
}

static void tag_count(Fs *fs, uint32_t id, int d) {
  char name[FS_NAMEMAX + 2];
  uint8_t v[16];
  int vl, nl = dict_name(fs, 'T', id, name + 1);
  name[0] = 't';
  st_get(fs->st, fs->dict, name, nl + 1, v, &vl, NULL);
  p64(v + 8, g64(v + 8) + (uint64_t)d);
  st_put(fs->st, fs->dict, name, nl + 1, v, 16, 0);
}

/* ---- files ----------------------------------------------------------------- */

int64_t fs_lookup(Fs *fs, const char *name) {
  uint8_t v[8];
  int vl;
  if (!st_get(fs->st, fs->name, name, (int)strlen(name), v, &vl, NULL)) return -1;
  return (int64_t)g64(v);
}

int64_t fs_add(Fs *fs, const char *name, const uint8_t *data, uint64_t len,
               const char **tags, int ntags, int boot) {
  static FsRec r;
  uint8_t k[8], v[8];
  int nl = (int)strlen(name);
  if (nl < 1 || nl > FS_NAMEMAX || nl > st_maxkey(fs->st) || strchr(name, '/')) { snprintf(fs->msg, sizeof fs->msg, "bad name: %s", name); return -1; }
  if (boot && nl > 16) { snprintf(fs->msg, sizeof fs->msg, "a boot object's name is 16 bytes at most: %s", name); return -1; }
  if (fs_lookup(fs, name) >= 0) { snprintf(fs->msg, sizeof fs->msg, "two files named %s", name); return -1; }
  memset(&r, 0, sizeof r);
  r.oid = fs->nextoid++;
  r.kind = 1;
  r.flags = boot ? FS_BOOT : 0;
  r.size = len;
  r.created = r.modified = fs->st->txn;
  r.nl = nl;
  memcpy(r.name, name, (size_t)nl);
  for (int i = 0; i < ntags; i++) {
    int64_t id = dict_id(fs, 't', tags[i], (int)strlen(tags[i]), 1, 0);
    int dup = 0;
    if (id < 0 || tags[i][0] == '-' || r.ntags == 256) { snprintf(fs->msg, sizeof fs->msg, "bad tag name: %s", tags[i]); return -1; }
    for (int j = 0; j < r.ntags; j++) dup |= r.tags[j] == (uint32_t)id;
    if (dup) continue;
    r.tags[r.ntags++] = (uint32_t)id;
    tag_count(fs, (uint32_t)id, 1);
    pbe32(v, (uint32_t)id);
    idx(fs, 1, FS_A_TAG, v, 4, r.oid);
  }
  pbe64(k, r.oid);
  if (len || boot) st_bwrite(fs->st, fs->ns, fs->data, k, 8, 0, data, len, boot);
  p64(v, r.oid);
  st_put(fs->st, fs->name, name, nl, v, 8, 0);
  idx_int(fs, 1, FS_A_SIZE, r.size, r.oid);
  idx_int(fs, 1, FS_A_MOD, r.modified, r.oid);
  if (boot) { idx(fs, 1, FS_A_BOOT, v, 0, r.oid); fs->bootdirty = 1; }
  if (rec_save(fs, &r)) { snprintf(fs->msg, sizeof fs->msg, "too many tags: %s", name); return -1; }
  fs->nobj++;
  return (int64_t)r.oid;
}

int fs_setattr(Fs *fs, uint64_t oid, const char *aname, int type, const uint8_t *val, int len) {
  static FsRec r;
  uint8_t enc[260];
  if (fs_rec(fs, oid, &r) || len > 255 || (type == 0 && len != 8) || (type == 1 && memchr(val, 0, (size_t)len))) return -1;
  if (!strcmp(aname, "tag") || !strcmp(aname, "size") || !strcmp(aname, "modified") || !strcmp(aname, "boot")) return -1;
  int64_t id = dict_id(fs, 'a', aname, (int)strlen(aname), 1, (uint32_t)type);
  int i;
  if (id < 0) return -1;
  for (i = 0; i < r.nattr; i++) if (r.attr[i].id == (uint32_t)id) break;
  if (i < r.nattr) idx(fs, 0, (uint32_t)id, enc, aval(enc, r.attr[i].type, r.attr[i].val, r.attr[i].len), oid);
  else if (r.nattr == 32) return -1;
  else r.nattr++;
  r.attr[i].id = (uint32_t)id; r.attr[i].type = type; r.attr[i].len = len;
  memcpy(r.attr[i].val, val, (size_t)len);
  idx(fs, 1, (uint32_t)id, enc, aval(enc, type, val, len), oid);
  return rec_save(fs, &r);
}

int64_t fs_read(Fs *fs, uint64_t oid, uint64_t off, uint8_t *b, uint64_t len) {
  uint8_t k[8];
  pbe64(k, oid);
  int64_t n = st_bread(fs->st, fs->ns, fs->data, k, 8, off, b, len);
  return n < 0 ? 0 : n;
}

int fs_nextname(Fs *fs, char *name, uint64_t *oid) {
  uint8_t v[8];
  int kl, vl;
  if (!st_seek(fs->st, fs->name, name, (int)strlen(name), ST_GT, (uint8_t *)name, &kl, v, &vl, NULL)) return 0;
  name[kl] = 0;
  *oid = g64(v);
  return 1;
}

/* ---- the boot manifest -------------------------------------------------------- */

static int manifest(Fs *fs) {
  Store *st = fs->st;
  static FsRec r;
  uint8_t k[12], ok[12], *p = NULL;
  uint64_t no = 0;
  int okl, n = 0, max = ((int)st->ps - 64) / 32;
  pbe32(k, FS_A_BOOT);
  memset(k + 4, 0, 8);
  while (st_seek(st, fs->attr, k, 12, ST_GT, ok, &okl, NULL, NULL, NULL) && okl == 12 && gbe32(ok) == FS_A_BOOT) {
    StExt e[2] = {{0, 0, 0}};
    uint8_t dk[8];
    memcpy(k, ok, 12);
    if (fs_rec(fs, gbe64(ok + 4), &r)) continue;
    pbe64(dk, r.oid);
    int ne = st_bextents(st, fs->ns, fs->data, dk, 8, e, 2);
    if (ne > 1 || (ne < 1 && r.size) || (ne == 1 && e[0].birth != 0) || n == max) {
      snprintf(fs->msg, sizeof fs->msg, n == max ? "too many boot objects" : "boot object %s is not in one piece", r.name);
      if (p) st_page_free(st, no);
      return -1;
    }
    if (!p) { p = st_page_new(st, &no); memcpy(p + 32, "STBOOTMF", 8); }
    uint8_t *en = p + 64 + 32 * n++;
    memcpy(en, r.name, (size_t)r.nl);
    p64(en + 16, e[0].start);
    p64(en + 24, r.size);
    p32(p + 40, (uint32_t)n);
  }
  if (st->manifest) st_page_free(st, st->manifest);
  st->manifest = no;
  return 0;
}

int fs_commit(Fs *fs) {
  if (fs->bootdirty && manifest(fs)) return -1;
  fs->bootdirty = 0;
  counters_save(fs);
  st_commit(fs->st);
  return 0;
}

/* ---- check and dump ----------------------------------------------------------- */

static int has(Fs *fs, uint32_t id, const uint8_t *val, int vl, uint64_t oid) {
  uint8_t k[4 + 300 + 8];
  return st_get(fs->st, fs->attr, k, akey(k, id, val, vl, oid), NULL, NULL, NULL);
}

int fs_check(Fs *fs, FILE *out) {
  Store *st = fs->st;
  static FsRec r;
  int bad = 0, kl, vl;
  uint64_t nobj = 0, nidx = 0, nboot = 0, n;
  uint64_t *tc = calloc(fs->nexttag + 1, sizeof *tc);
  uint8_t k[ST_MAXPS / 8], v[ST_MAXPS / 4], b[8], enc[260];
#define BAD(...) do { bad++; if (out) { fprintf(out, "stdb: fs: " __VA_ARGS__); fputc('\n', out); } } while (0)
  for (kl = 0; st_seek(st, fs->obj, k, kl, ST_GT, k, &kl, NULL, NULL, NULL);) {
    uint64_t oid = gbe64(k);
    nobj++;
    if (kl != 8 || fs_rec(fs, oid, &r)) { BAD("object %llu: bad record", (unsigned long long)oid); continue; }
    if (oid >= fs->nextoid) BAD("object %llu: beyond the next id", (unsigned long long)oid);
    if (fs_lookup(fs, r.name) != (int64_t)oid) BAD("%s: not under its name", r.name);
    int64_t ds = st_bsize(st, fs->data, k, 8);
    if ((ds < 0 ? 0 : (uint64_t)ds) != r.size) BAD("%s: size %llu but %lld bytes of contents", r.name, (unsigned long long)r.size, (long long)ds);
    pbe64(b, r.size);
    if (!has(fs, FS_A_SIZE, b, 8, oid)) BAD("%s: size not indexed", r.name);
    pbe64(b, r.modified);
    if (!has(fs, FS_A_MOD, b, 8, oid)) BAD("%s: modification not indexed", r.name);
    nidx += 2;
    if (r.flags & FS_BOOT) { nidx++; nboot++; if (!has(fs, FS_A_BOOT, b, 0, oid)) BAD("%s: boot flag not indexed", r.name); }
    for (int i = 0; i < r.ntags; i++, nidx++) {
      pbe32(b, r.tags[i]);
      if (r.tags[i] >= fs->nexttag) { BAD("%s: tag id beyond the next", r.name); continue; }
      tc[r.tags[i]]++;
      if (!has(fs, FS_A_TAG, b, 4, oid)) BAD("%s: tag %u not indexed", r.name, r.tags[i]);
    }
    for (int i = 0; i < r.nattr; i++, nidx++) {
      char an[FS_NAMEMAX + 1];
      if (r.attr[i].id < FS_A_USER || dict_name(fs, 'A', r.attr[i].id, an) < 0) BAD("%s: attribute %u has no name", r.name, r.attr[i].id);
      if (!has(fs, r.attr[i].id, enc, aval(enc, r.attr[i].type, r.attr[i].val, r.attr[i].len), oid)) BAD("%s: attribute %u not indexed", r.name, r.attr[i].id);
    }
  }
  if (nobj != fs->nobj) BAD("%llu objects, the count says %llu", (unsigned long long)nobj, (unsigned long long)fs->nobj);
  for (kl = 0, n = 0; st_seek(st, fs->name, k, kl, ST_GT, k, &kl, v, &vl, NULL); n++)
    if (vl != 8 || fs_rec(fs, g64(v), &r) || r.nl != kl || memcmp(r.name, k, (size_t)kl)) BAD("a name without its object");
  if (n != nobj) BAD("%llu names for %llu objects", (unsigned long long)n, (unsigned long long)nobj);
  /* every index entry was looked for from its record: as many entries as that, and no more */
  for (kl = 0, n = 0; st_seek(st, fs->attr, k, kl, ST_GT, k, &kl, NULL, NULL, NULL); n++) {}
  if (n != nidx) BAD("%llu index entries, the records account for %llu", (unsigned long long)n, (unsigned long long)nidx);
  for (kl = 1, k[0] = 't'; st_seek(st, fs->dict, k, kl, ST_GT, k, &kl, v, &vl, NULL) && k[0] == 't';) {
    char tn[FS_NAMEMAX + 1];
    uint32_t id = g32(v);
    if (vl != 16 || id >= fs->nexttag || dict_name(fs, 'T', id, tn) != kl - 1 || memcmp(tn, k + 1, (size_t)kl - 1)) { BAD("tag %u: bad dictionary entry", id); continue; }
    if (g64(v + 8) != tc[id]) BAD("tag %s: %llu files carry it, the count says %llu", tn, (unsigned long long)tc[id], (unsigned long long)g64(v + 8));
    tc[id] = 0;
  }
  for (uint32_t i = 0; i < fs->nexttag; i++) if (tc[i]) BAD("tag %u is carried but not in the dictionary", i);
  /* the boot manifest */
  uint64_t nm = 0;
  if (st->manifest) {
    const uint8_t *p = st_page(st, st->manifest);
    nm = g32(p + 40);
    if (memcmp(p + 32, "STBOOTMF", 8) || nm > (st->ps - 64) / 32) { BAD("bad boot manifest"); nm = 0; }
    for (uint64_t i = 0; i < nm; i++) {
      const uint8_t *en = p + 64 + 32 * i;
      char nmz[17] = {0};
      StExt e[2] = {{0, 0, 0}};
      memcpy(nmz, en, 16);
      int64_t oid = fs_lookup(fs, nmz);
      if (oid < 0 || fs_rec(fs, (uint64_t)oid, &r) || !(r.flags & FS_BOOT)) { BAD("manifest: %s is not a boot object", nmz); continue; }
      pbe64(b, (uint64_t)oid);
      int ne = st_bextents(st, fs->ns, fs->data, b, 8, e, 2);
      if (ne > 1 || e[0].birth || e[0].start != g64(en + 16) || r.size != g64(en + 24) ||
          e[0].len * st->ps < r.size) BAD("manifest: %s is not where it says", nmz);
    }
  }
  if (nm != nboot) BAD("%llu boot objects, %llu in the manifest", (unsigned long long)nboot, (unsigned long long)nm);
#undef BAD
  free(tc);
  return bad;
}

static int scmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

/* Every file by name: its size, tags and attributes by name, a sum of its
 * contents. Nothing here depends on ids, placement or commit numbers. */
void fs_dump(Fs *fs, FILE *out) {
  static FsRec r;
  char name[FS_NAMEMAX + 1] = "";
  uint64_t oid;
  uint8_t *b = malloc(1 << 16);
  while (fs_nextname(fs, name, &oid)) {
    if (fs_rec(fs, oid, &r)) continue;
    char *items[300];
    int ni = 0;
    uint64_t h = 0xCBF29CE484222325ull;
    for (uint64_t off = 0; off < r.size; off += 1 << 16) {
      int64_t n = fs_read(fs, oid, off, b, 1 << 16);
      for (int64_t i = 0; i < n; i++) h = (h ^ b[i]) * 0x100000001B3ull;
    }
    fprintf(out, "%s size=%llu sum=%016llx%s", r.name, (unsigned long long)r.size, (unsigned long long)h, r.flags & FS_BOOT ? " boot" : "");
    for (int i = 0; i < r.ntags; i++) { items[ni] = malloc(FS_NAMEMAX + 1); fs_tagname(fs, r.tags[i], items[ni++]); }
    qsort(items, (size_t)ni, sizeof *items, scmp);
    for (int i = 0; i < ni; i++) { fprintf(out, "%s%s", i ? "," : " tags=", items[i]); free(items[i]); }
    ni = 0;
    for (int i = 0; i < r.nattr; i++) {
      char an[FS_NAMEMAX + 1];
      items[ni] = malloc(FS_NAMEMAX + 300);
      fs_attrname(fs, r.attr[i].id, an);
      if (r.attr[i].type == 0) sprintf(items[ni++], "%s=%llu", an, (unsigned long long)g64(r.attr[i].val));
      else sprintf(items[ni++], "%s=\"%.*s\"", an, r.attr[i].len, (char *)r.attr[i].val);
    }
    qsort(items, (size_t)ni, sizeof *items, scmp);
    for (int i = 0; i < ni; i++) { fprintf(out, " %s", items[i]); free(items[i]); }
    fputc('\n', out);
  }
  free(b);
}
