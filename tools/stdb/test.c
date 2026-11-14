/* test.c: the store against a model, and against power cuts.
 *
 *   stdb-test [seed]
 *
 * 1. Random puts, deletes and commits on several trees, compared with a
 *    plain array after every step that reads, the whole store checked
 *    (st_check) and read back through a fresh mount after every commit.
 * 2. A recorded run of commits is repeated with the device cut after every
 *    possible number of written blocks; each image left must mount, pass
 *    the check, hold exactly the state of the last commit whose blocks were
 *    all written, and take a further commit. */
#include <stdlib.h>
#include <string.h>

#include "stdb.h"

static uint64_t rs;
static uint32_t rnd(void) {
  rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
  return (uint32_t)(rs >> 16);
}

#define NT 3
typedef struct { int t, kl, vl; uint8_t *k, *v; } Ent;
static Ent *mod;
static int nmod, cmod;
static const char *tname[NT] = {"alpha", "beta", "gamma"};

static int mfind(int t, const uint8_t *k, int kl) {
  for (int i = 0; i < nmod; i++)
    if (mod[i].t == t && mod[i].kl == kl && !memcmp(mod[i].k, k, (size_t)kl)) return i;
  return -1;
}

static void mput(int t, const uint8_t *k, int kl, const uint8_t *v, int vl) {
  int i = mfind(t, k, kl);
  if (i < 0) {
    if (nmod == cmod) mod = realloc(mod, (size_t)(cmod = cmod ? cmod * 2 : 256) * sizeof *mod);
    i = nmod++;
    mod[i] = (Ent){t, kl, 0, malloc((size_t)kl), NULL};
    memcpy(mod[i].k, k, (size_t)kl);
  } else free(mod[i].v);
  mod[i].vl = vl;
  mod[i].v = malloc((size_t)vl + 1);
  memcpy(mod[i].v, v, (size_t)vl);
}

static void mdel(int i) {
  free(mod[i].k); free(mod[i].v);
  mod[i] = mod[--nmod];
}

static void bclear(void);
static void mclear(void) { while (nmod) mdel(0); bclear(); }

/* Blobs: a few keys in a tree of their own, each a byte array in the model. */
#define NB 12
static struct { int there; uint64_t len; uint8_t *d; } blob[NB];

static void bclear(void) {
  for (int i = 0; i < NB; i++) { free(blob[i].d); blob[i].d = NULL; blob[i].there = 0; blob[i].len = 0; } }

static void die(const char *m);

static void bstep(Store *st) {
  int i = (int)(rnd() % NB), op = (int)(rnd() % 10);
  StTree *t = st_tree(st, 1, "blob", 1);
  uint8_t key[2] = {'b', (uint8_t)('a' + i)};
  uint32_t ps = st->ps;
  if (op < 6) { /* write somewhere: mostly near the end, sometimes far beyond, sometimes inside */
    uint64_t off = blob[i].len, len = rnd() % (3 * ps);
    if (rnd() % 3 == 0) off = rnd() % (blob[i].len + 1);
    if (rnd() % 12 == 0) off += rnd() % (20 * ps);
    if (rnd() % 3 == 0) len = rnd() % 200;
    if (rnd() % 10 == 0) len = 30 * ps + rnd() % ps;
    uint8_t *d = malloc(len + 1);
    for (uint64_t j = 0; j < len; j++) d[j] = (uint8_t)rnd();
    st_bwrite(st, 1, t, key, 2, off, d, len, 0);
    if (!blob[i].there && len == 0 && off == 0) { blob[i].there = 1; }
    uint64_t end = off + len > blob[i].len ? off + len : blob[i].len;
    blob[i].d = realloc(blob[i].d, end + 1);
    if (end > blob[i].len) memset(blob[i].d + blob[i].len, 0, end - blob[i].len);
    memcpy(blob[i].d + off, d, len);
    blob[i].len = end;
    blob[i].there = 1;
    free(d);
  } else if (op < 8 && blob[i].there) {
    uint64_t size = rnd() % (blob[i].len + 1 + (rnd() % 4 == 0 ? 3 * ps : 0));
    st_btrunc(st, 1, t, key, 2, size);
    blob[i].d = realloc(blob[i].d, size + 1);
    if (size > blob[i].len) memset(blob[i].d + blob[i].len, 0, size - blob[i].len);
    blob[i].len = size;
  } else if (op == 8 && blob[i].there) {
    if (!st_bdel(st, 1, t, key, 2)) die("blob delete: not there");
    free(blob[i].d); blob[i].d = NULL; blob[i].there = 0; blob[i].len = 0;
  }
}

static void bcompare(Store *st, const char *when) {
  StTree *t = st_tree(st, 1, "blob", 0);
  for (int i = 0; i < NB; i++) {
    uint8_t key[2] = {'b', (uint8_t)('a' + i)};
    int64_t size = t ? st_bsize(st, t, key, 2) : -1;
    if (size != (blob[i].there ? (int64_t)blob[i].len : -1)) { fprintf(stderr, "%s: blob %d is %lld bytes, the model %lld\n", when, i, (long long)size, blob[i].there ? (long long)blob[i].len : -1); exit(1); }
    if (size <= 0) continue;
    uint8_t *b = malloc((size_t)size);
    /* in two reads at an odd place, to cross pages unaligned */
    uint64_t cut = rnd() % ((uint64_t)size + 1);
    if (st_bread(st, 1, t, key, 2, 0, b, cut) != (int64_t)cut || st_bread(st, 1, t, key, 2, cut, b + cut, (uint64_t)size - cut + 5) != size - (int64_t)cut) die("blob read: wrong count");
    if (memcmp(b, blob[i].d, (size_t)size)) { fprintf(stderr, "%s: blob %d\n", when, i); die("blob bytes differ from the model"); }
    free(b);
  }
}

static void die(const char *m) { fprintf(stderr, "stdb-test: %s\n", m); exit(1); }

/* A key: mostly short, from a small alphabet so that prefixes are shared;
 * now and then as long as a key may be. */
static int mkkey(Store *st, uint8_t *k) {
  int kl = 1 + (int)(rnd() % 12);
  if (rnd() % 50 == 0) kl = 1 + (int)(rnd() % (uint32_t)st_maxkey(st));
  for (int i = 0; i < kl; i++) k[i] = (uint8_t)('a' + rnd() % 4);
  if (rnd() % 4 == 0 && kl > 2) k[kl - 1] = (uint8_t)rnd();
  return kl;
}

/* The store holds what the model holds, in order. */
static void compare(Store *st, const char *when) {
  for (int t = 0; t < NT; t++) {
    StTree *tr = st_tree(st, 1, tname[t], 0);
    int n = 0, want = 0, kl = 0, vl, pl = 0;
    uint8_t k[ST_MAXPS / 8], v[ST_MAXPS / 4], prev[ST_MAXPS / 8];
    for (int i = 0; i < nmod; i++) want += mod[i].t == t;
    while (tr && st_seek(st, tr, k, kl, ST_GT, k, &kl, v, &vl, NULL)) {
      int i = mfind(t, k, kl);
      if (i < 0 || mod[i].vl != vl || memcmp(mod[i].v, v, (size_t)vl)) { fprintf(stderr, "%s: tree %d\n", when, t); die("a record differs from the model"); }
      if (n && (memcmp(prev, k, (size_t)(pl < kl ? pl : kl)) > 0 || (pl >= kl && !memcmp(prev, k, (size_t)kl)))) die("records out of order");
      memcpy(prev, k, (size_t)kl); pl = kl;
      n++;
    }
    if (n != want) { fprintf(stderr, "%s: tree %d has %d records, the model %d\n", when, t, n, want); exit(1); }
  }
  bcompare(st, when);
}

static void step(Store *st) {
  if (rnd() % 8 == 0) { bstep(st); return; }
  int t = (int)(rnd() % NT), op = (int)(rnd() % 20);
  StTree *tr = st_tree(st, 1, tname[t], 1);
  uint8_t k[ST_MAXPS / 8], v[ST_MAXPS / 4], g[ST_MAXPS / 4];
  if (op < 16 || !nmod) {
    int kl = mkkey(st, k), vl = (int)(rnd() % 40), gl;
    if (rnd() % 20 == 0) vl = (int)(rnd() % (uint32_t)(st_maxval(st, kl) + 1));
    if (vl > st_maxval(st, kl)) vl = st_maxval(st, kl);
    for (int i = 0; i < vl; i++) v[i] = (uint8_t)rnd();
    int was = mfind(t, k, kl) >= 0;
    if (st_put(st, tr, k, kl, v, vl, 0) != !was) die("put: added or replaced, against the model");
    mput(t, k, kl, v, vl);
    if (!st_get(st, tr, k, kl, g, &gl, NULL) || gl != vl || memcmp(g, v, (size_t)vl)) die("get after put");
  } else if (op < 19) {
    int i = (int)(rnd() % (uint32_t)nmod);
    tr = st_tree(st, 1, tname[mod[i].t], 1);
    if (!st_del(st, tr, mod[i].k, mod[i].kl)) die("delete: not there");
    if (st_get(st, tr, mod[i].k, mod[i].kl, NULL, NULL, NULL)) die("get after delete");
    mdel(i);
  } else {
    int kl = mkkey(st, k);
    if (st_del(st, tr, k, kl) != (mfind(t, k, kl) >= 0)) die("delete of a random key, against the model");
    int i = mfind(t, k, kl);
    if (i >= 0) mdel(i);
  }
}

/* st_seek's four modes around a random key, against the model. */
static void seeks(Store *st) {
  int t = (int)(rnd() % NT), kl, okl, ovl;
  StTree *tr = st_tree(st, 1, tname[t], 1);
  uint8_t k[ST_MAXPS / 8], ok[ST_MAXPS / 8], ov[ST_MAXPS / 4];
  kl = mkkey(st, k);
  for (int mode = ST_GE; mode <= ST_LT; mode++) {
    int best = -1;
    for (int i = 0; i < nmod; i++) {
      if (mod[i].t != t) continue;
      int m = mod[i].kl < kl ? mod[i].kl : kl, c = memcmp(mod[i].k, k, (size_t)m);
      if (!c) c = mod[i].kl - kl;
      if (!(mode == ST_GE ? c >= 0 : mode == ST_GT ? c > 0 : mode == ST_LE ? c <= 0 : c < 0)) continue;
      if (best >= 0) {
        int bm = mod[i].kl < mod[best].kl ? mod[i].kl : mod[best].kl, bc = memcmp(mod[i].k, mod[best].k, (size_t)bm);
        if (!bc) bc = mod[i].kl - mod[best].kl;
        if (mode <= ST_GT ? bc > 0 : bc < 0) continue;
      }
      best = i;
    }
    int got = st_seek(st, tr, k, kl, mode, ok, &okl, ov, &ovl, NULL);
    if (got != (best >= 0)) die("seek: found or not, against the model");
    if (got && (okl != mod[best].kl || memcmp(ok, mod[best].k, (size_t)okl))) die("seek: another record than the model's");
  }
}

static void checked(Store *st, const char *when) {
  if (st_check(st, stderr)) { fprintf(stderr, "%s\n", when); die("the check failed"); }
}

static void test_model(uint32_t ps, uint64_t blocks, int commits, int per) {
  StDev d;
  Store st, st2;
  st_dev_init(&d, blocks);
  st_format(&d, ps, 3);
  if (st_mount(&st, &d)) die(st.msg);
  checked(&st, "after format");
  int maxh = 0;
  for (int c = 0; c < commits; c++) {
    int n = 1 + (int)(rnd() % (uint32_t)per);
    if (c % 7 == 3) n *= 8; /* a large transaction now and then */
    for (int i = 0; i < n; i++) {
      /* phases: growing for a while, then shrinking, so that trees get high and low again */
      if ((c / 60) % 3 == 2 && nmod > 20 && rnd() % 4) {
        int j = (int)(rnd() % (uint32_t)nmod);
        st_del(&st, st_tree(&st, 1, tname[mod[j].t], 1), mod[j].k, mod[j].kl);
        mdel(j);
      } else step(&st);
      if (i % 16 == 0) seeks(&st);
    }
    if (c % 11 == 5) { /* a transaction given up: back to the last commit */
      st_abort(&st);
      mclear();
      uint8_t k[ST_MAXPS / 8], v[ST_MAXPS / 4];
      for (int t = 0; t < NT; t++) {
        StTree *tr = st_tree(&st, 1, tname[t], 0);
        int kl = 0, vl;
        while (tr && st_seek(&st, tr, k, kl, ST_GT, k, &kl, v, &vl, NULL)) mput(t, k, kl, v, vl);
      }
      for (int i = 0; i < NB; i++) {
        StTree *bt = st_tree(&st, 1, "blob", 0);
        uint8_t key[2] = {'b', (uint8_t)('a' + i)};
        int64_t size = bt ? st_bsize(&st, bt, key, 2) : -1;
        if (size < 0) continue;
        blob[i].there = 1;
        blob[i].len = (uint64_t)size;
        blob[i].d = malloc((size_t)size + 1);
        st_bread(&st, 1, bt, key, 2, 0, blob[i].d, (uint64_t)size);
      }
      checked(&st, "after abort");
      continue;
    }
    st_commit(&st);
    compare(&st, "after commit");
    checked(&st, "after commit");
    for (int t = 0; t < NT; t++) { StTree *tr = st_tree(&st, 1, tname[t], 0); if (tr && (int)tr->height > maxh) maxh = (int)tr->height; }
    if (c % 5 == 0) { /* what the disk holds, through a fresh mount */
      if (st_mount(&st2, &d)) die(st2.msg);
      if (st_hash(&st2) != st_hash(&st)) die("a fresh mount reads another state");
      checked(&st2, "fresh mount");
      st_close(&st2);
    }
  }
  printf("model: %u-byte pages, %d commits, %d records at the end, trees up to %d high, "
         "%llu blocks written in %llu commands, allocator passes at most %d\n",
         ps, commits, nmod, maxh, (unsigned long long)d.writes, (unsigned long long)d.cmds, st.maxiter);
  st_close(&st);
  st_dev_free(&d);
  mclear();
}

/* One run of the cut workload. Records, per commit, the state's hash and
 * the blocks written so far (when hashes is not NULL). */
static int run_cut(StDev *d, uint64_t seed, int commits, uint64_t *hashes, uint64_t *writes) {
  Store st;
  rs = seed;
  mclear();
  if (st_mount(&st, d)) die(st.msg);
  int c;
  for (c = 0; c < commits && !d->dead; c++) {
    int n = 1 + (int)(rnd() % 30);
    for (int i = 0; i < n; i++) step(&st);
    st_commit(&st);
    if (hashes && !d->dead) { hashes[c + 1] = st_hash(&st); writes[c + 1] = d->writes; }
  }
  st_close(&st);
  return c;
}

static void test_cut(uint32_t ps, uint64_t blocks, int commits, uint64_t seed) {
  StDev base, d, e;
  Store st;
  st_dev_init(&base, blocks);
  st_format(&base, ps, 3);
  uint64_t *hashes = calloc((size_t)commits + 1, 8), *writes = calloc((size_t)commits + 1, 8);
  st_dev_init(&d, blocks);
  memcpy(d.img, base.img, blocks * ST_BLK);
  if (st_mount(&st, &d)) die(st.msg);
  hashes[0] = st_hash(&st);
  st_close(&st);
  run_cut(&d, seed, commits, hashes, writes);
  uint64_t total = d.writes;
  st_dev_init(&e, blocks);
  for (uint64_t cut = 0; cut < total; cut++) {
    memcpy(d.img, base.img, blocks * ST_BLK);
    d.writes = 0; d.dead = 0; d.cutting = 1; d.cut = cut;
    run_cut(&d, seed, commits, NULL, NULL);
    memcpy(e.img, d.img, blocks * ST_BLK);
    int k = 0;
    while (k < commits && writes[k + 1] <= cut) k++;
    jmp_buf jb;
    if (st_mount(&st, &e)) { fprintf(stderr, "cut at block %llu: %s\n", (unsigned long long)cut, st.msg); exit(1); }
    st.jb = &jb;
    if (setjmp(jb)) { fprintf(stderr, "cut at block %llu: %s\n", (unsigned long long)cut, st.msg); exit(1); }
    if (st_check(&st, stderr)) { fprintf(stderr, "cut at block %llu (commit %d was being written)\n", (unsigned long long)cut, k + 1); exit(1); }
    if (st_hash(&st) != hashes[k]) { fprintf(stderr, "cut at block %llu: the state is not commit %d's\n", (unsigned long long)cut, k); exit(1); }
    if (st.commit != (uint64_t)k + 1) die("the commit number is not the last whole commit's");
    /* and the store must go on from there */
    uint8_t key[4] = {'z', 'z', (uint8_t)cut, (uint8_t)(cut >> 8)};
    st_put(&st, st_tree(&st, 1, "alpha", 1), key, 4, key, 4, 0);
    st_commit(&st);
    if (st_check(&st, stderr)) { fprintf(stderr, "cut at block %llu: after one more commit\n", (unsigned long long)cut); exit(1); }
    st_close(&st);
  }
  printf("cuts: %u-byte pages, %d commits, a cut after each of %llu blocks: every image holds its last whole commit\n",
         ps, commits, (unsigned long long)total);
  free(hashes); free(writes);
  st_dev_free(&base); st_dev_free(&d); st_dev_free(&e);
  mclear();
}

/* A changed byte in any tree page is noticed; with the newest meta block
 * damaged the store is the commit before, whole. */
static void test_damage(void) {
  StDev d;
  Store st;
  st_dev_init(&d, 2048);
  st_format(&d, 1024, 3);
  if (st_mount(&st, &d)) die(st.msg);
  for (int i = 0; i < 600; i++) step(&st);
  st_commit(&st);
  for (int i = 0; i < 20; i++) step(&st);
  st_commit(&st);
  uint64_t first = st.first, npages = st.npages, slot = 1 + (st.commit & 1), commit = st.commit;
  uint8_t *used = calloc(npages, 1);
  for (uint64_t i = first; i < npages; i++) used[i] = st.pg[i] != NULL; /* every page was read or made */
  st_close(&st);
  int n = 0;
  for (uint64_t i = first; i <= npages; i++) {
    uint64_t at = i == npages ? slot * 1024 + 40 : i * 1024 + 8 + rnd() % 1016;
    if (i < npages && !used[i]) continue;
    d.img[at] ^= 0x10;
    int r = st_mount(&st, &d);
    if (i == npages) {
      if (r || st.commit != commit - 1 || st_check(&st, stderr)) die("with the newest meta block damaged, the commit before is not there");
      st_close(&st);
      d.img[at] ^= 0x10;
      break;
    }
    if (!r) {
      /* a page the store freed since may be unused: only a used one must fail */
      r = st_check(&st, NULL);
      st_close(&st);
    }
    d.img[at] ^= 0x10;
    n += r != 0;
  }
  if (st_mount(&st, &d) || st_check(&st, stderr)) die("the undamaged image fails");
  st_close(&st);
  if (n < 10) die("damage went unnoticed");
  printf("damage: a changed byte was noticed in %d pages\n", n);
  free(used);
  st_dev_free(&d);
  mclear();
}

int main(int argc, char **argv) {
  uint64_t seed = argc > 1 ? strtoull(argv[1], NULL, 0) : 1;
  rs = seed * 0x9E3779B97F4A7C15ull + 1;
  test_model(4096, 16384, 400, 60);
  test_model(1024, 8192, 400, 40);
  test_model(2048, 16384, 300, 40);
  test_cut(4096, 8192, 40, seed + 77);
  test_cut(1024, 2048, 40, seed + 99);
  test_damage();
  printf("stdb-test: OK\n");
  return 0;
}
