/* stdb: the StrataOS store on the host (doc/strata-fs-proposal.md).
 *
 * Copy-on-write B+trees over a block device image. This is the host's side
 * of the format (mkdisk, the checker) and the reference for the server in
 * os/: same structures, same algorithms, same allocation decisions.
 *
 * Errors: a routine that cannot go on (a bad page, a full disk) calls
 * longjmp on st->jb when the caller set one, and aborts otherwise. After
 * such a jump the transaction is undefined: call st_abort. */
#ifndef STDB_H
#define STDB_H
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>

#define ST_BLK 512u
#define ST_MAXPS 4096u
#define ST_MAXH 16     /* tree height at most */
#define ST_NOPEN 64    /* trees open at once */
#define ST_RES 64      /* pages kept back for the allocator's own trees */

/* A block device held in memory. Writes can be cut: with `cutting` set,
 * the device dies when `cut` blocks have been written, in the middle of a
 * command if that is where it falls. */
typedef struct {
  uint8_t *img;
  uint64_t nblocks;
  uint64_t writes, cmds, flushes, reads; /* blocks written; commands; ... */
  int cutting, dead;
  uint64_t cut;
} StDev;

typedef struct { uint64_t root, height; } StTree;
typedef struct { uint64_t start, len, birth; } StExt;

typedef struct {
  int used, isnew;
  uint32_t ns;
  int nl;
  char name[64];
  StTree t, saved;
} StOpen;

typedef struct Store {
  StDev *dev;
  uint32_t ps;            /* page size */
  uint64_t npages, first; /* pages on the disk; the first one the store manages */
  uint64_t commit, txn;   /* the last commit on the disk; the one being made */
  StTree cat, fre, pend;  /* catalog, free space, pending frees */
  uint64_t manifest, nextns, nextid, nfree;
  StExt spare;            /* free pages in no tree: the allocator's last extent */
  uint8_t **pg;           /* the cache: every page read or made */
  uint8_t *dirty;
  int began, in_ft, in_b, in_fin;
  uint64_t txfreed;       /* pages freed in this transaction, not yet reusable */
  uint64_t last;          /* the page allocated last: the next one goes after it */
  StExt *avail; int navail, cavail;   /* free extents taken into memory, sorted */
  StExt *freed; int nfreed, cfreed;   /* freed in this transaction */
  uint64_t *ld; int nld, cld;         /* free records taken (their keys) */
  uint8_t (*pld)[16]; int npld, cpld; /* pending records taken (their keys) */
  StOpen open[ST_NOPEN];
  jmp_buf *jb;
  char msg[160];
  int maxiter;            /* most passes a commit's allocator needed */
} Store;

enum { ST_GE, ST_GT, ST_LE, ST_LT };

void st_dev_init(StDev *d, uint64_t nblocks);
void st_dev_free(StDev *d);

/* Makes an empty store on the device: pages [first, npages) are its own. */
void st_format(StDev *d, uint32_t ps, uint64_t first);
/* 0, or -1 when no meta page is good (st->msg says why). */
int st_mount(Store *st, StDev *d);
void st_close(Store *st);
void st_commit(Store *st);
void st_abort(Store *st);

/* A tree of namespace ns by name; NULL if it is not there and create is 0. */
StTree *st_tree(Store *st, uint32_t ns, const char *name, int create);

int st_maxkey(const Store *st);
int st_maxval(const Store *st, int kl); /* the longest inline value beside a key */
/* 1 added, 0 replaced, -1 too long. flag: bit 15 of the value's length word. */
int st_put(Store *st, StTree *t, const void *key, int kl, const void *val, int vl, int flag);
int st_del(Store *st, StTree *t, const void *key, int kl); /* 1 deleted, 0 not there */
int st_get(Store *st, StTree *t, const void *key, int kl, uint8_t *val, int *vl, int *flag);
/* The nearest record at or after (GE), after (GT), at or before (LE), before
 * (LT) the key: 1 and the record, or 0. */
int st_seek(Store *st, StTree *t, const void *key, int kl, int mode,
            uint8_t *okey, int *okl, uint8_t *oval, int *ovl, int *flag);

/* Checks everything reachable from the meta page; problems go to `out`
 * (may be NULL). Returns their number. */
int st_check(Store *st, FILE *out);
/* A hash of every tree's name, keys and values, independent of placement. */
uint64_t st_hash(Store *st);

uint64_t st_sum(const uint8_t *p, size_t n, uint64_t seed);

/* A namespace's id by name (0: not there). */
uint32_t st_ns(Store *st, const char *name, int create);

/* Blobs: a value of any length under a key; short ones are kept in the
 * tree, longer ones (or `stream` set) as a stream. */
int64_t st_bsize(Store *st, StTree *t, const void *key, int kl); /* -1: not there */
int64_t st_bread(Store *st, uint32_t ns, StTree *t, const void *key, int kl, uint64_t off, uint8_t *b, uint64_t len);
void st_bwrite(Store *st, uint32_t ns, StTree *t, const void *key, int kl, uint64_t off,
               const uint8_t *data, uint64_t len, int stream);
void st_btrunc(Store *st, uint32_t ns, StTree *t, const void *key, int kl, uint64_t size);
int st_bdel(Store *st, uint32_t ns, StTree *t, const void *key, int kl);
/* out[i]: start page, pages, and in .birth the offset in pages. */
int st_bextents(Store *st, uint32_t ns, StTree *t, const void *key, int kl, StExt *out, int max);

/* A page of the caller's own (kind 3: header as a tree page's, the rest free
 * from byte 32), written with the commit; and giving one back. */
uint8_t *st_page_new(Store *st, uint64_t *no);
void st_page_free(Store *st, uint64_t no);
const uint8_t *st_page(Store *st, uint64_t no);
#endif
