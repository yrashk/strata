/* store.c: pages, trees, the allocator and the commit (see stdb.h).
 *
 * The disk, in pages of st->ps bytes:
 *   0        the boot header in its first block (offset 56 "STDB", 60 u32 page size)
 *   1, 2     the meta pages (their first block): commit c is in page 1 + (c & 1)
 *   3..first whatever mkdisk put there (the kernel's images)
 *   first..  tree pages and stream data
 *
 * A meta block: 0 checksum, 8 "STDBMETA", 16 commit, 24 pages, 32 first,
 * 40 catalog root, 48 its height, 56 free root, 64 height, 72 pending root,
 * 80 height, 88 boot manifest page, 96 next namespace id, 104 free pages,
 * 112 page size, 120 and 128 the spare extent (start, pages): free pages
 * that are in no tree (see finalize).
 *
 * A tree page: 0 checksum, 8 its own number, 16 the commit that wrote it,
 * 24 kind (1 branch, 2 leaf), 25 level (0 = leaf), 26 u16 cells, 28 u16
 * where the cells start; from 32 a u16 offset per cell, in key order; the
 * cells fill the page from its end downwards.
 *   leaf cell:   0 u16 key length, 2 u16 value length (bit 15: a flag), 8 the
 *                key, then the value at the next multiple of 8
 *   branch cell: 0 u16 key length, 8 u64 child, 16 the key. Child i holds the
 *                keys from key i up to key i+1; the key of cell 0 is not
 *                looked at.
 * Cells start at multiples of 8 and are padded with zeros to a multiple of
 * 8, so that every word in a page is aligned (the machine's loads must be).
 * A cell is at most a quarter of the page, a key at most an eighth.
 *
 * The free tree: u64 (big-endian) end page of a free extent -> u64 pages.
 * By its end, because pages are taken from an extent's front: the key
 * stays. A record of 0 pages means nothing and goes when it is next read.
 * The pending tree: u64 commit, u64 start (big-endian) -> u64 pages, u64
 * birth: pages freed by that commit, reusable once it is on the disk.
 * The catalog: u32 namespace (big-endian), tree name -> u64 root, u64 height.
 * Namespace 0 holds the tree "ns": a namespace's name -> u64 id, u64 flags.
 *
 * Blobs. A value is inline bytes, or (flag set) a stream: u64 length, u64
 * stream id. A stream's pages are in its namespace's tree ".ext": u64
 * stream id, u64 offset in pages (both big-endian) -> u64 first page, u64
 * pages, u64 birth. A range with no extent reads as zeros. Stream pages have
 * no header; they are written to the disk at once, into free pages, and
 * count from the commit like everything else. */
#include <stdlib.h>
#include <string.h>

#include "stdb.h"

enum { BRANCH = 1, LEAF = 2, HDR = 32 };

typedef struct { uint64_t no; int idx; } PathE;

#define R8(x) (((x) + 7) & ~7)
static uint16_t g16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static void p16(uint8_t *p, unsigned v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static uint64_t g64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static void p64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static uint64_t gbe(const uint8_t *p) { uint64_t v = 0; for (int i = 0; i < 8; i++) v = v << 8 | p[i]; return v; }
static void pbe(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * (7 - i))); }

static void fail(Store *st, const char *m) {
  snprintf(st->msg, sizeof st->msg, "%s", m);
  if (st->jb) longjmp(*st->jb, 1);
  fprintf(stderr, "stdb: %s\n", m);
  abort();
}

/* The checksum of a page or a meta block: its 8-byte words but the first. */
uint64_t st_sum(const uint8_t *p, size_t n, uint64_t seed) {
  uint64_t h = seed * 0x9E3779B97F4A7C15ull + 0xCBF29CE484222325ull;
  for (size_t i = 8; i < n; i += 8) h = (h ^ g64(p + i)) * 0x100000001B3ull;
  return h ^ h >> 32;
}

/* ---- the device ------------------------------------------------------------ */

void st_dev_init(StDev *d, uint64_t nblocks) {
  memset(d, 0, sizeof *d);
  d->nblocks = nblocks;
  d->img = calloc(nblocks, ST_BLK);
}

void st_dev_free(StDev *d) { free(d->img); d->img = NULL; }

static void dev_read(StDev *d, uint64_t lba, uint32_t n, uint8_t *dst) {
  memcpy(dst, d->img + lba * ST_BLK, (size_t)n * ST_BLK);
  d->reads++;
}

static void dev_write(StDev *d, uint64_t lba, uint32_t n, const uint8_t *src) {
  for (uint32_t i = 0; i < n; i++) {
    if (d->dead) return;
    if (d->cutting && d->writes == d->cut) { d->dead = 1; return; }
    memcpy(d->img + (lba + i) * ST_BLK, src + (size_t)i * ST_BLK, ST_BLK);
    d->writes++;
  }
}

/* ---- pages ----------------------------------------------------------------- */

static uint8_t *buf(Store *st, uint64_t no) {
  if (no >= st->npages) fail(st, "page beyond the disk");
  if (!st->pg[no]) st->pg[no] = calloc(1, st->ps);
  return st->pg[no];
}

/* A tree page, from the cache or the disk (checked). */
static uint8_t *P(Store *st, uint64_t no) {
  if (no < st->first || no >= st->npages) fail(st, "page number out of range");
  if (st->pg[no]) return st->pg[no];
  uint8_t *p = malloc(st->ps);
  dev_read(st->dev, no * (st->ps / ST_BLK), st->ps / ST_BLK, p);
  if (g64(p) != st_sum(p, st->ps, no) || g64(p + 8) != no) { free(p); fail(st, "bad page checksum"); }
  st->pg[no] = p;
  return p;
}

#define KIND(p) ((p)[24])
#define NC(p) g16((p) + 26)
#define LO(p) g16((p) + 28)

static uint8_t *cell(uint8_t *p, int i) { return p + g16(p + HDR + 2 * i); }
static int csize(const uint8_t *p, const uint8_t *c) {
  return KIND(p) == LEAF ? 8 + R8(g16(c)) + R8(g16(c + 2) & 0x7fff) : 16 + R8(g16(c));
}
static const uint8_t *ckey(const uint8_t *p, const uint8_t *c) { return c + (KIND(p) == LEAF ? 8 : 16); }
static int room(const uint8_t *p) { return LO(p) - (HDR + 2 * NC(p)); }
static int used(const Store *st, const uint8_t *p) { return (int)st->ps - LO(p) + 2 * NC(p); }
static int maxcell(const Store *st) { return (((int)st->ps - HDR) / 4 - 2) & ~7; }
int st_maxkey(const Store *st) { return (int)st->ps / 8 - 32; }
int st_maxval(const Store *st, int kl) { return maxcell(st) - 8 - R8(kl); }

static int kcmp(const uint8_t *a, int al, const uint8_t *b, int bl) {
  int r = memcmp(a, b, (size_t)(al < bl ? al : bl));
  return r ? r : al - bl;
}

/* Puts a cell at index i; there must be room for it and its slot. */
static void node_ins(uint8_t *p, int i, const uint8_t *c, int len) {
  int n = NC(p), lo = LO(p) - len;
  memcpy(p + lo, c, (size_t)len);
  memmove(p + HDR + 2 * (i + 1), p + HDR + 2 * i, (size_t)(2 * (n - i)));
  p16(p + HDR + 2 * i, (unsigned)lo);
  p16(p + 26, (unsigned)(n + 1));
  p16(p + 28, (unsigned)lo);
}

/* Takes cell i out and closes the gap, so the free space stays in one piece. */
static void node_rm(uint8_t *p, int i) {
  int n = NC(p), lo = LO(p), off = g16(p + HDR + 2 * i), len = csize(p, p + off);
  memmove(p + lo + len, p + lo, (size_t)(off - lo));
  memmove(p + HDR + 2 * i, p + HDR + 2 * (i + 1), (size_t)(2 * (n - 1 - i)));
  for (int j = 0; j < n - 1; j++) {
    int o = g16(p + HDR + 2 * j);
    if (o < off) p16(p + HDR + 2 * j, (unsigned)(o + len));
  }
  p16(p + 26, (unsigned)(n - 1));
  p16(p + 28, (unsigned)(lo + len));
}

/* The first cell of a leaf whose key is not below the key. */
static int lsearch(uint8_t *p, const uint8_t *k, int kl, int *exact) {
  int lo = 0, hi = NC(p);
  while (lo < hi) {
    int mid = (lo + hi) / 2;
    uint8_t *c = cell(p, mid);
    if (kcmp(c + 8, g16(c), k, kl) < 0) lo = mid + 1; else hi = mid;
  }
  *exact = 0;
  if (lo < NC(p)) { uint8_t *c = cell(p, lo); *exact = !kcmp(c + 8, g16(c), k, kl); }
  return lo;
}

/* The child of a branch that holds the key. */
static int bsearchb(uint8_t *p, const uint8_t *k, int kl) {
  int lo = 1, hi = NC(p);
  while (lo < hi) {
    int mid = (lo + hi) / 2;
    uint8_t *c = cell(p, mid);
    if (kcmp(c + 16, g16(c), k, kl) <= 0) lo = mid + 1; else hi = mid;
  }
  return lo - 1;
}

/* ---- the allocator --------------------------------------------------------- */

static void *grow(void *a, int n, int *cap, size_t sz) {
  if (n < *cap) return a;
  *cap = *cap ? *cap * 2 : 64;
  return realloc(a, (size_t)*cap * sz);
}

/* A free extent into the list in memory, merged with its neighbours there
 * (not while the list is being written back: see finalize). */
static void avail_add(Store *st, uint64_t start, uint64_t len) {
  if (!len) return;
  st->avail = grow(st->avail, st->navail, &st->cavail, sizeof *st->avail);
  StExt *a = st->avail;
  if (st->in_b) { a[st->navail++] = (StExt){start, len, 0}; return; }
  int i = 0;
  while (i < st->navail && a[i].start < start) i++;
  if (i > 0 && a[i - 1].start + a[i - 1].len == start) {
    a[i - 1].len += len;
    if (i < st->navail && a[i].start == start + len) {
      a[i - 1].len += a[i].len;
      memmove(a + i, a + i + 1, (size_t)(st->navail - i - 1) * sizeof *a);
      st->navail--;
    }
  } else if (i < st->navail && a[i].start == start + len) {
    a[i].start = start;
    a[i].len += len;
  } else {
    memmove(a + i + 1, a + i, (size_t)(st->navail - i) * sizeof *a);
    a[i] = (StExt){start, len, 0};
    st->navail++;
  }
}

static int ld_has(Store *st, uint64_t key) {
  for (int i = 0; i < st->nld; i++) if (st->ld[i] == key) return 1;
  return 0;
}

static void ld_take(Store *st, uint64_t end, uint64_t len) {
  st->ld = grow(st->ld, st->nld, &st->cld, sizeof *st->ld);
  st->ld[st->nld++] = end;
  avail_add(st, end - len, len);
}

/* The next free record after the ones looked at -> memory. 0: there is none. */
static int load_next(Store *st) {
  uint8_t k[8], ok[8], ov[8];
  int okl, ovl;
  pbe(k, st->x);
  if (!st_seek(st, &st->fre, k, 8, ST_GT, ok, &okl, ov, &ovl, NULL)) return 0;
  st->x = gbe(ok);
  if (!ld_has(st, st->x)) ld_take(st, st->x, g64(ov));
  return 1;
}

/* The free record whose extent starts at `start`, if there is one -> memory. */
static void load_at(Store *st, uint64_t start) {
  uint8_t k[8], ok[8], ov[8];
  int okl, ovl;
  pbe(k, start);
  if (!st_seek(st, &st->fre, k, 8, ST_GT, ok, &okl, ov, &ovl, NULL)) return;
  uint64_t end = gbe(ok), len = g64(ov);
  if (len && end - len == start && !ld_has(st, end)) ld_take(st, end, len);
}

/* The free record whose extent ends at `end` -> memory. 1 if it was taken. */
static int load_end(Store *st, uint64_t end) {
  uint8_t k[8], v[8];
  int vl;
  pbe(k, end);
  if (ld_has(st, end) || !st_get(st, &st->fre, k, 8, v, &vl, NULL)) return 0;
  ld_take(st, end, g64(v));
  return 1;
}

/* The start of a transaction: what the last commits freed is reusable now. */
static void begin(Store *st) {
  if (st->began) return;
  st->began = 1;
  avail_add(st, st->spare.start, st->spare.len);
  st->spare.len = 0;
  uint8_t k[16] = {0}, ov[16];
  int kl = 16, ovl;
  while (st_seek(st, &st->pend, k, kl, ST_GT, k, &kl, ov, &ovl, NULL)) {
    if (gbe(k) >= st->txn) break;
    st->pld = grow(st->pld, st->npld, &st->cpld, sizeof *st->pld);
    memcpy(st->pld[st->npld++], k, 16);
    avail_add(st, gbe(k + 8), g64(ov));
  }
}

static uint64_t take(Store *st, int i, uint64_t n, uint64_t *got) {
  StExt *e = &st->avail[i];
  uint64_t k = n < e->len ? n : e->len, s = e->start;
  e->start += k;
  e->len -= k;
  if (!e->len) {
    memmove(e, e + 1, (size_t)(st->navail - i - 1) * sizeof *e);
    st->navail--;
  }
  st->nfree -= k;
  *got = k;
  return s;
}

/* n pages in one run if there is one (at `hint` if that is free), else the
 * front of the first free extent: *got says how many. */
static uint64_t alloc(Store *st, uint64_t n, uint64_t hint, uint64_t *got) {
  begin(st);
  if (!st->in_fin && st->nfree - st->txfreed < n + ST_RES) fail(st, "disk full");
  if (st->in_b) { /* while the list is written back: from its largest extent */
    int big = 0;
    if (!st->navail) fail(st, "disk full");
    for (int i = 1; i < st->navail; i++) if (st->avail[i].len > st->avail[big].len) big = i;
    return take(st, big, n, got);
  }
  if (hint) {
    int i;
    for (int pass = 0; pass < 2; pass++) {
      for (i = 0; i < st->navail; i++) if (st->avail[i].start == hint) return take(st, i, n, got);
      if (st->in_ft) break;
      load_at(st, hint);
    }
  }
  /* a single page (a tree page) with no neighbour free: from the first
   * run of some length, so that a commit's pages lie together */
  if (hint) for (int i = 0; i < st->navail; i++) if (st->avail[i].len >= 8 * n) return take(st, i, n, got);
  for (;;) {
    for (int i = 0; i < st->navail; i++) if (st->avail[i].len >= n) return take(st, i, n, got);
    if (st->in_ft || !load_next(st)) break;
  }
  if (!st->navail) fail(st, "disk full");
  return take(st, 0, n, got);
}

/* Pages the store stops using. Born in this transaction: free at once.
 * Older: reusable when this commit is on the disk. */
static void pfree(Store *st, uint64_t start, uint64_t len, uint64_t birth) {
  st->nfree += len;
  if (birth == st->txn) {
    for (uint64_t i = 0; i < len; i++) st->dirty[start + i] = 0;
    avail_add(st, start, len);
    return;
  }
  st->freed = grow(st->freed, st->nfreed, &st->cfreed, sizeof *st->freed);
  st->freed[st->nfreed++] = (StExt){start, len, birth};
  st->txfreed += len;
}

static uint8_t *newpage(Store *st, int kind, int level, uint64_t *no) {
  uint64_t got;
  *no = st->last = alloc(st, 1, st->last + 1, &got);
  uint8_t *p = buf(st, *no);
  memset(p, 0, st->ps);
  p64(p + 8, *no);
  p64(p + 16, st->txn);
  p[24] = (uint8_t)kind;
  p[25] = (uint8_t)level;
  p16(p + 28, st->ps);
  st->dirty[*no] = 1;
  return p;
}

/* A page about to change: itself if this transaction made it, else a copy
 * at a new place (the old one is freed); *no follows. */
static uint8_t *touch(Store *st, uint64_t *no) {
  uint8_t *p = P(st, *no);
  if (g64(p + 16) == st->txn) return p;
  uint64_t got, n = st->last = alloc(st, 1, st->last + 1, &got);
  uint8_t *q = buf(st, n);
  memcpy(q, p, st->ps);
  p64(q + 8, n);
  p64(q + 16, st->txn);
  st->dirty[n] = 1;
  pfree(st, *no, 1, g64(p + 16));
  *no = n;
  return q;
}

/* ---- trees ----------------------------------------------------------------- */

int st_get(Store *st, StTree *t, const void *key, int kl, uint8_t *val, int *vl, int *flag) {
  if (!t->root) return 0;
  uint64_t no = t->root;
  for (;;) {
    uint8_t *p = P(st, no);
    if (KIND(p) == BRANCH) { no = g64(cell(p, bsearchb(p, key, kl)) + 8); continue; }
    int ex, i = lsearch(p, key, kl, &ex);
    if (!ex) return 0;
    uint8_t *c = cell(p, i);
    int v = g16(c + 2);
    if (vl) *vl = v & 0x7fff;
    if (flag) *flag = v >> 15;
    if (val) memcpy(val, c + 8 + R8(g16(c)), (size_t)(v & 0x7fff));
    return 1;
  }
}

int st_seek(Store *st, StTree *t, const void *key, int kl, int mode,
            uint8_t *okey, int *okl, uint8_t *oval, int *ovl, int *flag) {
  if (!t->root) return 0;
  PathE path[ST_MAXH];
  uint64_t no = t->root;
  uint8_t *p;
  int l, i, ex;
  for (l = 0;; l++) {
    p = P(st, no);
    path[l].no = no;
    if (KIND(p) == LEAF) break;
    path[l].idx = bsearchb(p, key, kl);
    no = g64(cell(p, path[l].idx) + 8);
  }
  i = lsearch(p, key, kl, &ex);
  if (mode == ST_GT && ex) i++;
  if (mode == ST_LE && !ex) i--;
  if (mode == ST_LT) i--;
  if (i >= NC(p)) { /* the first record of the next leaf */
    for (l--; l >= 0; l--) if (path[l].idx + 1 < NC(P(st, path[l].no))) break;
    if (l < 0) return 0;
    no = g64(cell(P(st, path[l].no), path[l].idx + 1) + 8);
    while (KIND(p = P(st, no)) == BRANCH) no = g64(cell(p, 0) + 8);
    i = 0;
  } else if (i < 0) { /* the last record of the leaf before */
    for (l--; l >= 0; l--) if (path[l].idx > 0) break;
    if (l < 0) return 0;
    no = g64(cell(P(st, path[l].no), path[l].idx - 1) + 8);
    while (KIND(p = P(st, no)) == BRANCH) no = g64(cell(p, NC(p) - 1) + 8);
    i = NC(p) - 1;
  }
  if (i < 0 || i >= NC(p)) return 0;
  uint8_t *c = cell(p, i);
  int k = g16(c), v = g16(c + 2);
  /* the value first: okey may be the caller's key buffer */
  if (oval) memcpy(oval, c + 8 + R8(k), (size_t)(v & 0x7fff));
  if (ovl) *ovl = v & 0x7fff;
  if (flag) *flag = v >> 15;
  if (okey) memmove(okey, c + 8, (size_t)k);
  if (okl) *okl = k;
  return 1;
}

/* Down to the key's leaf, every page on the way made this transaction's
 * own. Returns the key's place in the leaf. */
static int descend_w(Store *st, StTree *t, const uint8_t *key, int kl, PathE *path, int *exact) {
  uint64_t no = t->root;
  for (int l = 0;; l++) {
    if (l >= ST_MAXH) fail(st, "tree too high");
    uint8_t *p = touch(st, &no);
    if (l == 0) t->root = no;
    else p64(cell(P(st, path[l - 1].no), path[l - 1].idx) + 8, no);
    path[l].no = no;
    if (KIND(p) == LEAF) return path[l].idx = lsearch(p, key, kl, exact);
    path[l].idx = bsearchb(p, key, kl);
    no = g64(cell(p, path[l].idx) + 8);
  }
}

/* A cell into the page at `level` of the path, at index idx; the page is
 * split when the cell does not fit, and the new page's cell goes into the
 * level above the same way. */
static void ins_at(Store *st, StTree *t, PathE *path, int level, int idx, const uint8_t *c, int len) {
  uint8_t *p = P(st, path[level].no);
  if (room(p) >= len + 2) { node_ins(p, idx, c, len); return; }
  uint8_t tmp[ST_MAXPS];
  memcpy(tmp, p, st->ps);
  int n = NC(tmp), m = n + 1, kind = KIND(tmp), total = 0, k;
  const uint8_t *cp[ST_MAXPS / 6 + 2];
  int cl[ST_MAXPS / 6 + 2];
  for (int i = 0, j = 0; i < m; i++) {
    if (i == idx) { cp[i] = c; cl[i] = len; }
    else { cp[i] = cell(tmp, j); cl[i] = csize(tmp, cp[i]); j++; }
    total += cl[i] + 2;
  }
  if (idx == n) k = n; /* appending: the full page stays as it is */
  else {
    int acc = 0;
    for (k = 0; k < m - 1;) { acc += cl[k] + 2; k++; if (acc >= total / 2) break; }
  }
  uint64_t rno;
  uint8_t *r = newpage(st, kind, tmp[25], &rno);
  p16(p + 26, 0);
  p16(p + 28, st->ps);
  for (int i = 0; i < k; i++) node_ins(p, i, cp[i], cl[i]);
  /* the separator: for leaves the shortest key above the left page's last */
  uint8_t bc[16 + ST_MAXPS / 8] = {0};
  const uint8_t *b = ckey(tmp, cp[k]);
  int bl = g16(cp[k]), sl = bl;
  if (kind == LEAF) {
    const uint8_t *a = ckey(tmp, cp[k - 1]);
    int al = g16(cp[k - 1]);
    for (sl = 0; sl < al && sl < bl && a[sl] == b[sl]; sl++) {}
    sl++;
  }
  p16(bc, (unsigned)sl);
  p64(bc + 8, rno);
  memcpy(bc + 16, b, (size_t)sl);
  for (int i = k; i < m; i++) {
    if (i == k && kind == BRANCH) { /* its key went up: none is kept here */
      uint8_t first[16] = {0};
      memcpy(first + 8, cp[i] + 8, 8);
      node_ins(r, 0, first, 16);
    } else node_ins(r, i - k, cp[i], cl[i]);
  }
  if (level == 0) {
    uint64_t top;
    uint8_t *root = newpage(st, BRANCH, tmp[25] + 1, &top);
    uint8_t first[16] = {0};
    p64(first + 8, path[0].no);
    node_ins(root, 0, first, 16);
    node_ins(root, 1, bc, 16 + R8(sl));
    t->root = top;
    t->height++;
  } else ins_at(st, t, path, level - 1, path[level - 1].idx + 1, bc, 16 + R8(sl));
}

int st_put(Store *st, StTree *t, const void *key, int kl, const void *val, int vl, int flag) {
  if (kl < 1 || kl > st_maxkey(st) || vl < 0 || vl > st_maxval(st, kl)) return -1;
  begin(st);
  if (!t->root) { newpage(st, LEAF, 0, &t->root); t->height = 1; }
  PathE path[ST_MAXH];
  int ex, i = descend_w(st, t, key, kl, path, &ex), h = (int)t->height;
  uint8_t c[ST_MAXPS / 4] = {0};
  p16(c, (unsigned)kl);
  p16(c + 2, (unsigned)(vl | (flag ? 0x8000 : 0)));
  memcpy(c + 8, key, (size_t)kl);
  memcpy(c + 8 + R8(kl), val, (size_t)vl);
  if (ex) node_rm(P(st, path[h - 1].no), i);
  ins_at(st, t, path, h - 1, i, c, 8 + R8(kl) + R8(vl));
  return !ex;
}

/* After a cell left the page at `level`: an empty page goes; one under a
 * quarter full joins a neighbour when both fit in one page. */
static void rebalance(Store *st, StTree *t, PathE *path, int level) {
  uint8_t *p = P(st, path[level].no);
  if (level == 0) {
    if (NC(p) == 0) { pfree(st, path[0].no, 1, g64(p + 16)); t->root = 0; t->height = 0; }
    else for (uint64_t no = path[0].no; KIND(p) == BRANCH && NC(p) == 1; p = P(st, no)) {
      t->root = g64(cell(p, 0) + 8); /* a root with one child: the child is the root */
      t->height--;
      pfree(st, no, 1, g64(p + 16));
      no = t->root;
    }
    return;
  }
  uint8_t *par = P(st, path[level - 1].no);
  int pi = path[level - 1].idx;
  if (NC(p) == 0) {
    pfree(st, path[level].no, 1, g64(p + 16));
    node_rm(par, pi);
    rebalance(st, t, path, level - 1);
    return;
  }
  if (used(st, p) >= ((int)st->ps - HDR) / 4) return;
  int li, ri;
  if (pi + 1 < NC(par)) { li = pi; ri = pi + 1; }
  else if (pi > 0) { li = pi - 1; ri = pi; }
  else return;
  uint64_t lno = g64(cell(par, li) + 8), rno = g64(cell(par, ri) + 8);
  uint8_t *pl = P(st, lno), *pr = P(st, rno);
  uint8_t *sep = cell(par, ri);
  int extra = KIND(pl) == BRANCH ? R8(g16(sep)) - R8(g16(cell(pr, 0))) : 0;
  if (used(st, pl) + used(st, pr) + extra > (int)st->ps - HDR) return;
  pl = touch(st, &lno);
  p64(cell(par, li) + 8, lno);
  for (int i = 0, n = NC(pr); i < n; i++) {
    uint8_t *c = cell(pr, i);
    if (i == 0 && KIND(pr) == BRANCH) { /* its first cell gets the separator as its key */
      uint8_t bc[16 + ST_MAXPS / 8] = {0};
      int sl = g16(sep);
      p16(bc, (unsigned)sl);
      memcpy(bc + 8, c + 8, 8);
      memcpy(bc + 16, sep + 16, (size_t)sl);
      node_ins(pl, NC(pl), bc, 16 + R8(sl));
    } else node_ins(pl, NC(pl), c, csize(pr, c));
  }
  pfree(st, rno, 1, g64(pr + 16));
  node_rm(par, ri);
  rebalance(st, t, path, level - 1);
}

int st_del(Store *st, StTree *t, const void *key, int kl) {
  if (!st_get(st, t, key, kl, NULL, NULL, NULL)) return 0;
  begin(st);
  PathE path[ST_MAXH];
  int ex, i = descend_w(st, t, key, kl, path, &ex), h = (int)t->height;
  node_rm(P(st, path[h - 1].no), i);
  rebalance(st, t, path, h - 1);
  return 1;
}

/* ---- the catalog ----------------------------------------------------------- */

static int catkey(uint8_t *k, uint32_t ns, const char *name, int nl) {
  k[0] = (uint8_t)(ns >> 24); k[1] = (uint8_t)(ns >> 16); k[2] = (uint8_t)(ns >> 8); k[3] = (uint8_t)ns;
  memcpy(k + 4, name, (size_t)nl);
  return 4 + nl;
}

StTree *st_tree(Store *st, uint32_t ns, const char *name, int create) {
  int nl = (int)strlen(name), fr = -1;
  if (nl < 1 || nl >= (int)sizeof st->open[0].name) return NULL;
  for (int i = 0; i < ST_NOPEN; i++) {
    StOpen *o = &st->open[i];
    if (!o->used) { if (fr < 0) fr = i; continue; }
    if (o->ns == ns && o->nl == nl && !memcmp(o->name, name, (size_t)nl)) return &o->t;
  }
  if (fr < 0) fail(st, "too many trees open");
  uint8_t k[80], v[16];
  int vl, kl = catkey(k, ns, name, nl);
  StOpen *o = &st->open[fr];
  memset(o, 0, sizeof *o);
  if (st_get(st, &st->cat, k, kl, v, &vl, NULL)) {
    o->t.root = g64(v);
    o->t.height = g64(v + 8);
  } else if (!create) return NULL;
  else o->isnew = 1;
  o->used = 1;
  o->ns = ns;
  o->nl = nl;
  memcpy(o->name, name, (size_t)nl);
  o->saved = o->t;
  return &o->t;
}

/* ---- commit ---------------------------------------------------------------- */

static void meta_write(Store *st) {
  uint8_t m[ST_MAXPS] = {0};
  uint64_t slot = 1 + (st->txn & 1);
  memcpy(m + 8, "STDBMETA", 8);
  p64(m + 16, st->txn);
  p64(m + 24, st->npages);
  p64(m + 32, st->first);
  p64(m + 40, st->cat.root); p64(m + 48, st->cat.height);
  p64(m + 56, st->fre.root); p64(m + 64, st->fre.height);
  p64(m + 72, st->pend.root); p64(m + 80, st->pend.height);
  p64(m + 88, st->manifest);
  p64(m + 96, st->nextns);
  p64(m + 104, st->nfree);
  p64(m + 112, st->ps);
  p64(m + 120, st->spare.start);
  p64(m + 128, st->spare.len);
  p64(m + 136, st->nextid);
  p64(m, st_sum(m, ST_BLK, slot));
  dev_write(st->dev, slot * (st->ps / ST_BLK), 1, m);
  st->dev->cmds++;
}

static int meta_read(Store *st, uint64_t slot, uint8_t *m) {
  dev_read(st->dev, slot * (st->ps / ST_BLK), 1, m);
  return !memcmp(m + 8, "STDBMETA", 8) && g64(m) == st_sum(m, ST_BLK, slot) && g64(m + 112) == st->ps;
}

static uint64_t avail_total(Store *st) {
  uint64_t n = 0;
  for (int i = 0; i < st->navail; i++) n += st->avail[i].len;
  return n;
}

/* The free extent in memory that ends at `end`: its index, or -1. */
static int avail_end(Store *st, uint64_t end) {
  for (int i = 0; i < st->navail; i++) if (st->avail[i].start + st->avail[i].len == end) return i;
  return -1;
}

/* Brings the free and pending trees up to date with what this transaction
 * took and freed. Changing those trees itself takes and frees pages, so
 * this repeats until a pass leaves nothing over:
 *   A  the free records taken into memory are deleted from the free tree;
 *      the pending records taken are deleted from the pending tree
 *   C  what was freed is recorded in the pending tree under this commit
 *   B  what is left in memory goes back into the free tree, the smallest
 *      extents first; the pages this needs come from the largest. The last
 *      extent left is not put into the tree (that insert could need more
 *      pages than the extent has): it is the meta page's spare extent.
 * While the free tree is being changed nothing is read from it, so enough
 * free pages are taken into memory before each pass. */
static void finalize(Store *st) {
  st->in_fin = 1;
  for (int it = 1;; it++) {
    if (it > 50) fail(st, "the allocator does not settle");
    if (it > st->maxiter) st->maxiter = it;
    st->x = 0;
    while (avail_total(st) < ST_RES && load_next(st)) {}
    for (int i = 0; i < st->navail; i++) { /* join neighbours still in the tree */
      uint64_t s = st->avail[i].start, e = s + st->avail[i].len;
      int n = st->nld;
      load_end(st, s);
      load_at(st, e);
      if (st->nld != n) i = -1;
    }
    st->in_ft = 1;
    while (st->nld) {
      uint8_t k[8];
      pbe(k, st->ld[--st->nld]);
      st_del(st, &st->fre, k, 8);
    }
    st->in_ft = 0;
    while (st->npld) st_del(st, &st->pend, st->pld[--st->npld], 16);
    while (st->nfreed) {
      StExt e = st->freed[--st->nfreed];
      uint8_t k[16], v[16];
      pbe(k, st->txn); pbe(k + 8, e.start);
      p64(v, e.len); p64(v + 8, e.birth);
      st_put(st, &st->pend, k, 16, v, 16, 0);
    }
    if (st->nld || st->npld) continue; /* those took more: delete them first */
    st->in_ft = st->in_b = 1;
    while (st->navail > 1) {
      int big = 0, small = -1;
      for (int i = 1; i < st->navail; i++) if (st->avail[i].len > st->avail[big].len) big = i;
      for (int i = 0; i < st->navail; i++)
        if (i != big && (small < 0 || st->avail[i].len < st->avail[small].len)) small = i;
      StExt e = st->avail[small];
      uint64_t end = e.start + e.len, len;
      uint8_t k[8], v[8];
      pbe(k, end);
      for (;;) { /* the insert may take pages from this very extent */
        int i = avail_end(st, end);
        len = i < 0 ? 0 : st->avail[i].len;
        p64(v, len);
        st_put(st, &st->fre, k, 8, v, 8, 0);
        i = avail_end(st, end);
        if ((i < 0 ? 0 : st->avail[i].len) == len) break;
      }
      int i = avail_end(st, end);
      if (i >= 0) {
        memmove(st->avail + i, st->avail + i + 1, (size_t)(st->navail - i - 1) * sizeof *st->avail);
        st->navail--;
      }
    }
    st->in_ft = st->in_b = 0;
    if (!st->nfreed) break;
  }
  st->spare = st->navail ? st->avail[0] : (StExt){0, 0, 0};
  st->navail = 0;
  st->in_fin = 0;
}

void st_commit(Store *st) {
  for (int i = 0; i < ST_NOPEN; i++) { /* the trees' new roots -> the catalog */
    StOpen *o = &st->open[i];
    if (!o->used || (!o->isnew && o->t.root == o->saved.root && o->t.height == o->saved.height)) continue;
    uint8_t k[80], v[16];
    int kl = catkey(k, o->ns, o->name, o->nl);
    p64(v, o->t.root);
    p64(v + 8, o->t.height);
    st_put(st, &st->cat, k, kl, v, 16, 0);
    o->saved = o->t;
    o->isnew = 0;
  }
  if (!st->began) return;
  finalize(st);
  uint32_t bpp = st->ps / ST_BLK;
  int run = 0;
  for (uint64_t no = st->first; no < st->npages; no++) {
    if (!st->dirty[no]) { run = 0; continue; }
    uint8_t *p = st->pg[no];
    p64(p, st_sum(p, st->ps, no));
    dev_write(st->dev, no * bpp, bpp, p);
    if (!run) st->dev->cmds++; /* neighbours go in one command */
    run = 1;
    st->dirty[no] = 0;
  }
  st->dev->flushes++;
  meta_write(st);
  st->dev->flushes++;
  st->commit = st->txn++;
  st->began = 0;
  st->txfreed = 0;
  st->x = 0;
}

static void reset(Store *st) {
  for (uint64_t i = 0; i < st->npages; i++) { free(st->pg[i]); st->pg[i] = NULL; st->dirty[i] = 0; }
  st->navail = st->nfreed = st->nld = st->npld = 0;
  st->began = st->in_ft = st->in_b = st->in_fin = 0;
  st->txfreed = 0;
  st->x = 0;
}

static int meta_load(Store *st) {
  uint8_t a[ST_BLK], b[ST_BLK], *m;
  int ga = meta_read(st, 1, a), gb = meta_read(st, 2, b);
  if (!ga && !gb) { snprintf(st->msg, sizeof st->msg, "no good meta page"); return -1; }
  m = !gb || (ga && g64(a + 16) > g64(b + 16)) ? a : b;
  st->commit = g64(m + 16);
  st->txn = st->commit + 1;
  st->npages = g64(m + 24);
  st->first = g64(m + 32);
  st->cat = (StTree){g64(m + 40), g64(m + 48)};
  st->fre = (StTree){g64(m + 56), g64(m + 64)};
  st->pend = (StTree){g64(m + 72), g64(m + 80)};
  st->manifest = g64(m + 88);
  st->nextns = g64(m + 96);
  st->nfree = g64(m + 104);
  st->spare = (StExt){g64(m + 120), g64(m + 128), 0};
  st->nextid = g64(m + 136);
  return 0;
}

void st_abort(Store *st) {
  reset(st);
  meta_load(st);
  for (int i = 0; i < ST_NOPEN; i++) {
    StOpen *o = &st->open[i];
    if (o->used && o->isnew) o->used = 0;
    o->t = o->saved;
  }
}

int st_mount(Store *st, StDev *d) {
  memset(st, 0, sizeof *st);
  st->dev = d;
  if (memcmp(d->img + 56, "STDB", 4)) { snprintf(st->msg, sizeof st->msg, "not a store"); return -1; }
  st->ps = d->img[60] | (uint32_t)d->img[61] << 8;
  if (st->ps != 1024 && st->ps != 2048 && st->ps != 4096) { snprintf(st->msg, sizeof st->msg, "bad page size"); return -1; }
  if (meta_load(st)) return -1;
  if (st->npages > d->nblocks / (st->ps / ST_BLK)) { snprintf(st->msg, sizeof st->msg, "store larger than the disk"); return -1; }
  st->pg = calloc(st->npages, sizeof *st->pg);
  st->dirty = calloc(st->npages, 1);
  return 0;
}

void st_close(Store *st) {
  if (st->pg) reset(st);
  free(st->pg); free(st->dirty); free(st->avail); free(st->freed); free(st->ld); free(st->pld);
  memset(st, 0, sizeof *st);
}

void st_format(StDev *d, uint32_t ps, uint64_t first) {
  Store s, *st = &s;
  memset(st, 0, sizeof *st);
  st->dev = d;
  st->ps = ps;
  st->npages = d->nblocks / (ps / ST_BLK);
  st->first = first < 3 ? 3 : first;
  st->txn = 1;
  st->nextns = st->nextid = 1;
  st->pg = calloc(st->npages, sizeof *st->pg);
  st->dirty = calloc(st->npages, 1);
  memcpy(d->img + 56, "STDB", 4);
  d->img[60] = (uint8_t)ps;
  d->img[61] = (uint8_t)(ps >> 8);
  d->img[62] = d->img[63] = 0;
  memset(d->img + ps, 0, 2 * (size_t)ps); /* no meta page of an older store */
  st->began = 1; /* nothing is pending; everything is free */
  st->nfree = st->npages - st->first;
  avail_add(st, st->first, st->nfree);
  st_commit(st);
  st_close(st);
}

/* ---- the checker ----------------------------------------------------------- */

typedef struct { Store *st; FILE *out; int bad; uint8_t *map; } Chk;

static void bad(Chk *c, const char *what, uint64_t no) {
  c->bad++;
  if (c->out) fprintf(c->out, "stdb: page %llu: %s\n", (unsigned long long)no, what);
}

static void mark(Chk *c, uint64_t start, uint64_t len, int as, const char *what) {
  for (uint64_t i = start; i < start + len; i++) {
    if (i < c->st->first || i >= c->st->npages) { bad(c, what, i); return; }
    if (c->map[i]) { bad(c, "used twice", i); return; }
    c->map[i] = (uint8_t)as;
  }
}

/* A subtree whose keys must lie in [lo, hi). */
static void walk(Chk *c, uint64_t no, int level, const uint8_t *lo, int lol, const uint8_t *hi, int hil, int root) {
  Store *st = c->st;
  if (no < st->first || no >= st->npages) { bad(c, "child out of range", no); return; }
  if (c->map[no]) { bad(c, "used twice", no); return; }
  c->map[no] = 1;
  jmp_buf jb, *old = st->jb;
  st->jb = &jb;
  uint8_t *volatile p = NULL;
  if (!setjmp(jb)) p = P(st, no);
  st->jb = old;
  if (!p) { bad(c, st->msg, no); return; }
  int n = NC(p), kind = KIND(p);
  if (p[25] != level || kind != (level ? BRANCH : LEAF)) { bad(c, "wrong level or kind", no); return; }
  if (g64(p + 16) > st->commit) bad(c, "written by a later commit", no);
  if (n == 0 || (kind == BRANCH && n < 2 && root)) bad(c, "too few cells", no);
  if (LO(p) < HDR + 2 * n || LO(p) > st->ps) { bad(c, "bad cell area", no); return; }
  int sum = 0;
  for (int i = 0; i < n; i++) {
    int off = g16(p + HDR + 2 * i);
    if (off < LO(p) || (off & 7) || off + (kind == LEAF ? 8 : 16) > (int)st->ps) { bad(c, "cell outside the page", no); return; }
    uint8_t *ce = p + off;
    int sz = csize(p, ce);
    if (off + sz > (int)st->ps || sz > maxcell(st) || g16(ce) > st_maxkey(st)) { bad(c, "bad cell", no); return; }
    sum += sz;
    const uint8_t *k = ckey(p, ce);
    int kl = g16(ce);
    if (kind == BRANCH && i == 0) continue;
    if (lo && kcmp(k, kl, lo, lol) < 0) bad(c, "key below its page's range", no);
    if (hi && kcmp(k, kl, hi, hil) >= 0) bad(c, "key above its page's range", no);
    if (i > (kind == BRANCH)) {
      uint8_t *pc = cell(p, i - 1);
      if (kcmp(ckey(p, pc), g16(pc), k, kl) >= 0) bad(c, "keys out of order", no);
    }
  }
  if (sum != (int)st->ps - LO(p)) bad(c, "cells do not fill the cell area", no);
  if (kind == LEAF) return;
  for (int i = 0; i < n; i++) {
    uint8_t *ce = cell(p, i), *ne = i + 1 < n ? cell(p, i + 1) : NULL;
    walk(c, g64(ce + 8), level - 1, i ? ce + 16 : lo, i ? g16(ce) : lol,
         ne ? ne + 16 : hi, ne ? g16(ne) : hil, 0);
  }
}

static void walk_tree(Chk *c, StTree t) {
  if (!t.root) { if (t.height) bad(c, "an empty tree with a height", 0); return; }
  walk(c, t.root, (int)t.height - 1, NULL, 0, NULL, 0, 1);
}

typedef struct { uint32_t ns; uint64_t id, len; int seen; } SId;

static int sid_cmp(const void *a, const void *b) {
  const SId *x = a, *y = b;
  return x->ns != y->ns ? (x->ns < y->ns ? -1 : 1) : x->id != y->id ? (x->id < y->id ? -1 : 1) : 0;
}

/* Every stream's extents: inside the store, used once, in order, within
 * the stream's length, and belonging to a stream some value names. */
static void check_streams(Chk *c) {
  Store *st = c->st;
  SId *ids = NULL;
  int n = 0, cap = 0;
  uint8_t ck[80] = {0}, cv[16], k[ST_MAXPS / 8], v[ST_MAXPS / 4];
  int ckl = 0, cvl, kl, vl, fl;
  while (st_seek(st, &st->cat, ck, ckl, ST_GT, ck, &ckl, cv, &cvl, NULL)) {
    StTree t = {g64(cv), g64(cv + 8)};
    if (ckl == 8 && !memcmp(ck + 4, ".ext", 4)) continue;
    for (kl = 0; st_seek(st, &t, k, kl, ST_GT, k, &kl, v, &vl, &fl);) {
      if (!fl) continue;
      if (vl != 16) { bad(c, "bad stream value", 0); continue; }
      ids = grow(ids, n, &cap, sizeof *ids);
      ids[n++] = (SId){(uint32_t)(gbe(ck) >> 32), g64(v + 8), g64(v), 0};
    }
  }
  qsort(ids, (size_t)n, sizeof *ids, sid_cmp);
  for (int i = 1; i < n; i++) if (!sid_cmp(&ids[i - 1], &ids[i])) bad(c, "two values name one stream", ids[i].id);
  for (ckl = 0; st_seek(st, &st->cat, ck, ckl, ST_GT, ck, &ckl, cv, &cvl, NULL);) {
    StTree t = {g64(cv), g64(cv + 8)};
    if (ckl != 8 || memcmp(ck + 4, ".ext", 4)) continue;
    uint64_t pid = 0, pend = 0;
    SId *cur = NULL;
    for (kl = 0; st_seek(st, &t, k, kl, ST_GT, k, &kl, v, &vl, NULL);) {
      if (kl != 16 || vl != 24) { bad(c, "bad extent record", 0); continue; }
      uint64_t id = gbe(k), off = gbe(k + 8), pages = g64(v + 8);
      if (!cur || id != pid) {
        SId key = {(uint32_t)(gbe(ck) >> 32), id, 0, 0};
        cur = bsearch(&key, ids, (size_t)n, sizeof *ids, sid_cmp);
        if (!cur) { bad(c, "extent of no stream", g64(v)); pid = id; pend = 0; continue; }
        pid = id; pend = 0;
      }
      if (!pages || off < pend) bad(c, "stream extents overlap", g64(v));
      if (cur && (off + pages) * st->ps >= cur->len + st->ps) bad(c, "extent beyond its stream's length", g64(v));
      if (g64(v + 16) > st->commit) bad(c, "extent written by a later commit", g64(v));
      pend = off + pages;
      mark(c, g64(v), pages, 4, "stream extent outside the store");
    }
  }
  free(ids);
}

int st_check(Store *st, FILE *out) {
  Chk *c = malloc(sizeof *c);
  *c = (Chk){st, out, 0, calloc(st->npages, 1)};
  jmp_buf jb, *old = st->jb;
  walk_tree(c, st->cat);
  walk_tree(c, st->fre);
  walk_tree(c, st->pend);
  st->jb = &jb;
  if (!setjmp(jb) && !c->bad) {
    uint8_t k[80] = {0}, v[16];
    int kl = 0, vl;
    uint64_t nfree = 0;
    while (st_seek(st, &st->cat, k, kl, ST_GT, k, &kl, v, &vl, NULL)) {
      st->jb = old;
      walk_tree(c, (StTree){g64(v), g64(v + 8)});
      st->jb = &jb;
    }
    for (kl = 0; st_seek(st, &st->fre, k, kl, ST_GT, k, &kl, v, &vl, NULL);) {
      uint64_t end = gbe(k), len = g64(v);
      if (kl != 8 || vl != 8 || len > end) { bad(c, "bad free record", end); continue; }
      mark(c, end - len, len, 2, "free extent outside the store");
      nfree += len;
    }
    for (kl = 0; st_seek(st, &st->pend, k, kl, ST_GT, k, &kl, v, &vl, NULL);) {
      if (kl != 16 || vl != 16) { bad(c, "bad pending record", gbe(k + 8)); continue; }
      mark(c, gbe(k + 8), g64(v), 3, "pending extent outside the store");
      nfree += g64(v);
    }
    check_streams(c);
    if (st->manifest) { mark(c, st->manifest, 1, 1, "manifest outside the store"); P(st, st->manifest); }
    mark(c, st->spare.start, st->spare.len, 2, "spare extent outside the store");
    nfree += st->spare.len;
    for (uint64_t i = st->first; i < st->npages; i++) if (!c->map[i]) { bad(c, "neither used nor free", i); break; }
    if (nfree != st->nfree) bad(c, "the count of free pages is wrong", 0);
  } else if (!c->bad) bad(c, st->msg, 0);
  st->jb = old;
  int n = c->bad;
  free(c->map);
  free(c);
  return n;
}

uint64_t st_hash(Store *st) {
  uint64_t h = 0xCBF29CE484222325ull;
  uint8_t ck[80] = {0}, cv[16], k[ST_MAXPS / 8], v[ST_MAXPS / 4];
  int ckl = 0, cvl, kl, vl, fl;
#define MIX(p, n) for (int i_ = 0; i_ < (n); i_++) h = (h ^ (p)[i_]) * 0x100000001B3ull
  while (st_seek(st, &st->cat, ck, ckl, ST_GT, ck, &ckl, cv, &cvl, NULL)) {
    StTree t = {g64(cv), g64(cv + 8)};
    if (ckl == 8 && !memcmp(ck + 4, ".ext", 4)) continue; /* placement */
    MIX(ck, ckl);
    h = (h ^ 0xff) * 0x100000001B3ull;
    for (kl = 0; st_seek(st, &t, k, kl, ST_GT, k, &kl, v, &vl, &fl);) {
      uint8_t l[5] = {(uint8_t)kl, (uint8_t)(kl >> 8), (uint8_t)vl, (uint8_t)(vl >> 8), (uint8_t)fl};
      MIX(l, 5);
      MIX(k, kl);
      if (fl) { /* a stream: its length and bytes, not where they are */
        uint8_t b[ST_MAXPS];
        uint64_t len = g64(v);
        uint32_t ns = (uint32_t)(gbe(ck) >> 32);
        MIX(v, 8);
        for (uint64_t off = 0; off < len; off += st->ps) {
          int64_t r = st_bread(st, ns, &t, k, kl, off, b, st->ps);
          MIX(b, (int)r);
        }
        continue;
      }
      MIX(v, vl);
    }
  }
#undef MIX
  return h;
}

/* ---- pages for the layers above ---------------------------------------------- */

uint8_t *st_page_new(Store *st, uint64_t *no) { return newpage(st, 3, 0, no); }

void st_page_free(Store *st, uint64_t no) { pfree(st, no, 1, g64(P(st, no) + 16)); }

const uint8_t *st_page(Store *st, uint64_t no) { return P(st, no); }

/* ---- namespaces ------------------------------------------------------------ */

uint32_t st_ns(Store *st, const char *name, int create) {
  StTree *t = st_tree(st, 0, "ns", create);
  uint8_t v[16];
  int vl, nl = (int)strlen(name);
  if (!t) return 0;
  if (st_get(st, t, name, nl, v, &vl, NULL)) return (uint32_t)g64(v);
  if (!create) return 0;
  p64(v, st->nextns);
  p64(v + 8, 0);
  if (st_put(st, t, name, nl, v, 16, 0) < 0) return 0;
  return (uint32_t)st->nextns++;
}

/* ---- blobs ----------------------------------------------------------------- */

typedef struct { uint64_t off, start, pages, birth; } Ext;

static void ekey(uint8_t *k, uint64_t id, uint64_t off) { pbe(k, id); pbe(k + 8, off); }

/* The extent that holds page pi of the stream: 1. Else 0, and e->off is
 * where the next extent begins (all ones: there is none). */
static int ext_find(Store *st, StTree *et, uint64_t id, uint64_t pi, Ext *e) {
  uint8_t k[16], ok[16], v[24];
  int kl, vl;
  ekey(k, id, pi);
  if (st_seek(st, et, k, 16, ST_LE, ok, &kl, v, &vl, NULL) && gbe(ok) == id) {
    *e = (Ext){gbe(ok + 8), g64(v), g64(v + 8), g64(v + 16)};
    if (pi < e->off + e->pages) return 1;
  }
  e->off = ~0ull;
  if (st_seek(st, et, k, 16, ST_GT, ok, &kl, v, &vl, NULL) && gbe(ok) == id) e->off = gbe(ok + 8);
  return 0;
}

static void ext_put(Store *st, StTree *et, uint64_t id, Ext e) {
  uint8_t k[16], v[24];
  ekey(k, id, e.off);
  p64(v, e.start); p64(v + 8, e.pages); p64(v + 16, e.birth);
  st_put(st, et, k, 16, v, 24, 0);
}

static void ext_del(Store *st, StTree *et, uint64_t id, uint64_t off) {
  uint8_t k[16];
  ekey(k, id, off);
  st_del(st, et, k, 16);
}

/* Pages [a, b) of extent e leave it: the parts before and after stay. */
static void ext_cut(Store *st, StTree *et, uint64_t id, Ext e, uint64_t a, uint64_t b) {
  uint64_t end = e.off + e.pages;
  if (a > e.off) ext_put(st, et, id, (Ext){e.off, e.start, a - e.off, e.birth});
  else ext_del(st, et, id, e.off);
  if (b < end) ext_put(st, et, id, (Ext){b, e.start + (b - e.off), end - b, e.birth});
  pfree(st, e.start + (a - e.off), b - a, e.birth);
}

static void dio(Store *st, int wr, uint64_t page, uint64_t n, uint8_t *b) {
  uint32_t bpp = st->ps / ST_BLK;
  if (page < st->first || page + n > st->npages) fail(st, "stream page out of range");
  if (wr) dev_write(st->dev, page * bpp, (uint32_t)(n * bpp), b);
  else dev_read(st->dev, page * bpp, (uint32_t)(n * bpp), b);
}

/* Bytes into a stream. Pages this transaction wrote are written again in
 * place; older ones are replaced by new pages; a hole gets pages, after the
 * extent before it when those are free. */
static void s_write(Store *st, StTree *et, uint64_t id, uint64_t oldlen, uint64_t off,
                    const uint8_t *data, uint64_t len) {
  uint32_t ps = st->ps;
  uint8_t pb[ST_MAXPS];
  while (len) {
    uint64_t pi = off / ps, po = off % ps, need = (po + len + ps - 1) / ps, run, dst, src = 0;
    Ext e, pv;
    int have = ext_find(st, et, id, pi, &e);
    if (have && e.birth == st->txn) {
      run = e.off + e.pages - pi;
      if (run > need) run = need;
      dst = src = e.start + (pi - e.off);
    } else {
      uint64_t lim = have ? e.off + e.pages - pi : e.off == ~0ull ? need : e.off - pi, hint = 0;
      int hp = !have && pi > 0 && ext_find(st, et, id, pi - 1, &pv);
      run = need < lim ? need : lim;
      if (hp) hint = pv.start + pv.pages;
      dst = alloc(st, run, hint, &run);
      if (have) {
        src = e.start + (pi - e.off);
        ext_cut(st, et, id, e, pi, pi + run);
        ext_put(st, et, id, (Ext){pi, dst, run, st->txn});
      } else if (hp && dst == hint && pv.birth == st->txn) {
        pv.pages += run;
        ext_put(st, et, id, pv);
      } else ext_put(st, et, id, (Ext){pi, dst, run, st->txn});
    }
    uint64_t cnt = run * ps - po;
    if (cnt > len) cnt = len;
    for (uint64_t j = 0; j < run; j++) {
      uint64_t ps0 = (pi + j) * ps, a = off > ps0 ? off : ps0, b = off + cnt < ps0 + ps ? off + cnt : ps0 + ps;
      if (b - a == ps) { dio(st, 1, dst + j, 1, (uint8_t *)(uintptr_t)(data + (a - off))); continue; }
      if (src) dio(st, 0, src + j, 1, pb); else memset(pb, 0, ps);
      if (oldlen < ps0 + ps) { /* nothing beyond the old end is kept */
        uint64_t z = oldlen > ps0 ? oldlen - ps0 : 0;
        memset(pb + z, 0, ps - z);
      }
      memcpy(pb + (a - ps0), data + (a - off), b - a);
      dio(st, 1, dst + j, 1, pb);
    }
    st->dev->cmds++;
    off += cnt; data += cnt; len -= cnt;
  }
}

/* The stream keeps its first `pages` pages. */
static void s_trim(Store *st, StTree *et, uint64_t id, uint64_t pages) {
  uint8_t k[16], ok[16], v[24];
  int kl, vl;
  Ext e;
  if (pages && ext_find(st, et, id, pages - 1, &e) && e.off + e.pages > pages) ext_cut(st, et, id, e, pages, e.off + e.pages);
  ekey(k, id, pages);
  while (st_seek(st, et, k, 16, ST_GE, ok, &kl, v, &vl, NULL) && gbe(ok) == id) {
    e = (Ext){gbe(ok + 8), g64(v), g64(v + 8), g64(v + 16)};
    ext_cut(st, et, id, e, e.off, e.off + e.pages);
  }
}

int64_t st_bsize(Store *st, StTree *t, const void *key, int kl) {
  uint8_t v[ST_MAXPS / 4];
  int vl, fl;
  if (!st_get(st, t, key, kl, v, &vl, &fl)) return -1;
  return fl ? (int64_t)g64(v) : vl;
}

int64_t st_bread(Store *st, uint32_t ns, StTree *t, const void *key, int kl, uint64_t off, uint8_t *b, uint64_t len) {
  uint8_t v[ST_MAXPS / 4], pb[ST_MAXPS];
  int vl, fl;
  uint32_t ps = st->ps;
  if (!st_get(st, t, key, kl, v, &vl, &fl)) return -1;
  uint64_t size = fl ? g64(v) : (uint64_t)vl, done = 0;
  if (off >= size) return 0;
  if (len > size - off) len = size - off;
  if (!fl) { memcpy(b, v + off, len); return (int64_t)len; }
  StTree *et = st_tree(st, ns, ".ext", 0);
  uint64_t id = g64(v + 8);
  while (done < len) {
    uint64_t o = off + done, pi = o / ps, po = o % ps, n = ps - po;
    Ext e;
    if (n > len - done) n = len - done;
    if (et && ext_find(st, et, id, pi, &e)) {
      if (po == 0 && n == ps) { /* whole pages: as many as the extent has */
        uint64_t run = e.off + e.pages - pi;
        if (run > (len - done) / ps) run = (len - done) / ps;
        dio(st, 0, e.start + (pi - e.off), run, b + done);
        done += run * ps;
        continue;
      }
      dio(st, 0, e.start + (pi - e.off), 1, pb);
      memcpy(b + done, pb + po, n);
    } else memset(b + done, 0, n);
    done += n;
  }
  return (int64_t)len;
}

void st_bwrite(Store *st, uint32_t ns, StTree *t, const void *key, int kl, uint64_t off,
               const uint8_t *data, uint64_t len, int stream) {
  uint8_t v[ST_MAXPS / 4], d[16];
  int vl = 0, fl = 0;
  begin(st);
  st_get(st, t, key, kl, v, &vl, &fl);
  uint64_t size = fl ? g64(v) : (uint64_t)vl, end = off + len > size ? off + len : size;
  if (!fl && !stream && end <= (uint64_t)st_maxval(st, kl)) {
    memset(v + size, 0, end - size);
    memcpy(v + off, data, len);
    st_put(st, t, key, kl, v, (int)end, 0);
    return;
  }
  StTree *et = st_tree(st, ns, ".ext", 1);
  uint64_t id = fl ? g64(v + 8) : st->nextid++;
  if (!fl && size) s_write(st, et, id, 0, 0, v, size);
  s_write(st, et, id, size, off, data, len);
  p64(d, end);
  p64(d + 8, id);
  st_put(st, t, key, kl, d, 16, 1);
}

void st_btrunc(Store *st, uint32_t ns, StTree *t, const void *key, int kl, uint64_t size) {
  uint8_t v[ST_MAXPS / 4];
  int vl, fl;
  if (!st_get(st, t, key, kl, v, &vl, &fl)) return;
  uint64_t old = fl ? g64(v) : (uint64_t)vl;
  if (size > old) { uint8_t z = 0; st_bwrite(st, ns, t, key, kl, size - 1, &z, 1, 0); return; }
  if (!fl) { st_put(st, t, key, kl, v, (int)size, 0); return; }
  StTree *et = st_tree(st, ns, ".ext", 1);
  Ext e;
  s_trim(st, et, g64(v + 8), (size + st->ps - 1) / st->ps);
  if (size % st->ps && ext_find(st, et, g64(v + 8), size / st->ps, &e)) { /* zeros after the new end */
    uint8_t z[ST_MAXPS] = {0};
    s_write(st, et, g64(v + 8), size, size, z, st->ps - size % st->ps);
  }
  p64(v, size);
  st_put(st, t, key, kl, v, 16, 1);
}

int st_bdel(Store *st, uint32_t ns, StTree *t, const void *key, int kl) {
  uint8_t v[ST_MAXPS / 4];
  int vl, fl;
  if (!st_get(st, t, key, kl, v, &vl, &fl)) return 0;
  if (fl) s_trim(st, st_tree(st, ns, ".ext", 1), g64(v + 8), 0);
  return st_del(st, t, key, kl);
}

/* A stream's extents, in order -> out (at most max): their number; -1 when
 * the value is inline or not there. */
int st_bextents(Store *st, uint32_t ns, StTree *t, const void *key, int kl, StExt *out, int max) {
  uint8_t v[ST_MAXPS / 4], k[16], ok[16], ev[24];
  int vl, fl, n = 0, okl;
  if (!st_get(st, t, key, kl, v, &vl, &fl) || !fl) return -1;
  StTree *et = st_tree(st, ns, ".ext", 0);
  uint64_t id = g64(v + 8);
  ekey(k, id, 0);
  for (int mode = ST_GE; et && st_seek(st, et, k, 16, mode, ok, &okl, ev, &vl, NULL) && gbe(ok) == id; mode = ST_GT) {
    if (n < max) out[n] = (StExt){g64(ev), g64(ev + 8), gbe(ok + 8)};
    n++;
    memcpy(k, ok, 16);
  }
  return n;
}
