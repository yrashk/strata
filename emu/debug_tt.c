/* The debug engine: time travel. Part of emu/debug.c (which includes this
 * file); see there.
 *
 * A deterministic run (the virtual timer, no JIT, no network) is a
 * function of its image, its disk and what comes from outside: console
 * input, Ctrl-C and the debugger's own writes to registers and memory. The
 * engine logs those with the position they arrived at and keeps SNAPSHOTS
 * of the machine at round boundaries every `tt_every` ticks; going back to
 * tick T is restoring the last snapshot at or before T and executing
 * forward to T with the log replayed. Reverse stepping and reverse
 * continue search backwards: snapshot by snapshot, the interval is executed
 * again and the last tick that would have stopped is remembered.
 *
 * Memory is kept in REGIONS of 4 KiB pages: T3 (64 MiB), T2, the disk and
 * each core's whole Core structure (registers, capabilities, the save
 * table, both Local Stores, the inbox). A snapshot stores only the pages
 * that changed since the previous one, as versions: page p's content at
 * snapshot S is its last version at or before S (no version: zeros). Far
 * memory and the disk know which pages changed from the hooks in emu.c
 * (dirty bits); the cores are compared page by page. The rest of the
 * machine (devices, timer, revocation generations, the host's input queue,
 * the engine's own tables) is a small blob per snapshot.
 *
 * The memory used is bounded (--history MiB): when it is exceeded, every
 * other snapshot is dropped (its versions merge into the next one) and the
 * interval doubles, so a long run keeps a coarser history of all of it. */

#define TT_PG 4096u

typedef struct { uint32_t serial; uint8_t *data; } PVer; /* data NULL: zeros */
typedef struct { PVer *v; uint32_t n, cap; } PList;
typedef struct {
  uint8_t *base;
  uint64_t bytes;
  uint32_t npages;
  PList *pl;
  uint8_t *dirty;  /* hooked regions: pages written since the base snapshot */
} Region;

/* everything of the machine that is not in a region */
typedef struct {
  uint8_t sq_buf[32];
  int sq_fill;
  uint8_t sq_cmds[BLK_QDEPTH][32];
  int sq_from[BLK_QDEPTH];
  int sq_head, sq_cnt;
  Gift blk_inbox[IQ];
  int bi_head, bi_cnt;
  uint8_t cq[BLK_QDEPTH][16];
  int cq_head, cq_cnt, cq_byte;
  Gift blk_out;
  int blk_out_to;
  uint64_t rounds, tmr_deadline, tmr_wbuf, tmr_lnow, tmr_ldl, ptr_lstate;
  int npending;
  uint64_t slow_events, pend_seq, net_lstat;
  bool faulted;
  uint16_t ggen[NGRAN3 + NGRAN2];
  bool ghead[NGRAN3 + NGRAN2];
  unsigned long long mach_steps, opt_break_at;
  uint64_t lead[MAXCORES], blocked_at[MAXCORES];
  uint8_t idle[sizeof idle];
  uint8_t host_inq[HOST_INQ];
  int host_in_head, host_in_cnt, host_breaks;
  uint64_t host_in_taken;
  bool in_open;
  int64_t in_off;
  uint64_t host_ptr_q[PTR_QLEN];
  int host_ptr_head, host_ptr_cnt, ptr_iscript;
  unsigned ptr_x, ptr_y, ptr_btn;
  bool ptr_in, ptr_used;
  /* the engine's */
  uint64_t tick, poll_at, evseq, pseq;
  TagRec tags[MAXCORES][16];
  Pending pshadow[MAXCORES][NPEND];
  int pnpend;
  Stall stall[MAXCORES];
  int pid_prev[MAXCORES];
  uint64_t bphold[MAXCORES];
  uint32_t nprov, next_id;
} Misc;

typedef struct {
  uint64_t tick, round, hash;
  uint32_t serial;
  Misc *misc;
  uint32_t *delta;   /* region << 26 | page of every version made by this snapshot */
  uint32_t ndelta, capdelta;
} Snap;

/* the input log */
enum { IN_BYTES, IN_BREAK, IN_XREG, IN_PC, IN_PTR, IN_MEM }; /* IN_PTR: a = PTR_* kind, b = x | y << 32; IN_MEM + 0 dls, 1 ils, 2 t2, 3 t3, 4 disk */
typedef struct {
  uint64_t pos;  /* 2 * tick + (after the round's start) */
  int kind, core;
  uint64_t a, b;
  uint8_t *data;
  size_t n;
} InLog;

static Region tt_rg[3 + MAXCORES];
static int tt_nrg;
static Snap *tt_snaps;
static int tt_n, tt_cap;
static int tt_base = -1;          /* the snapshot the dirty bits are relative to */
static int tt_next;               /* the first snapshot after the current position */
static uint32_t tt_serial;
#define TT_EVERY0 50000
static uint64_t tt_every = TT_EVERY0; /* ticks between snapshots */
static uint64_t tt_bytes;         /* memory held by versions and blobs */
static InLog *tt_log;
static size_t tt_nlog, tt_caplog;
static uint64_t tt_applied = 0;   /* positions up to here have had their log entries applied, + 1 */
static uint64_t tt_diverged;      /* replays whose state did not match the snapshot (should stay 0) */
static const uint8_t tt_zero[TT_PG];

static void rg_add(uint8_t *base, uint64_t bytes, bool hooked) {
  Region *r = &tt_rg[tt_nrg++];
  r->base = base;
  r->bytes = bytes;
  r->npages = (uint32_t)((bytes + TT_PG - 1) / TT_PG);
  r->pl = calloc(r->npages, sizeof *r->pl);
  r->dirty = hooked ? calloc(r->npages, 1) : NULL;
  if (!r->pl || (hooked && !r->dirty)) { perror("strata-emu: time travel"); exit(2); }
}

static uint32_t pg_bytes(const Region *r, uint32_t p) {
  uint64_t off = (uint64_t)p * TT_PG;
  return (uint32_t)(r->bytes - off < TT_PG ? r->bytes - off : TT_PG);
}

/* page p's content at snapshot serial s (NULL: zeros) */
static const uint8_t *pg_at(const Region *r, uint32_t p, uint32_t s) {
  const PList *l = &r->pl[p];
  int lo = 0, hi = (int)l->n - 1, best = -1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    if (l->v[mid].serial <= s) { best = mid; lo = mid + 1; }
    else hi = mid - 1;
  }
  return best >= 0 ? l->v[best].data : NULL;
}

static void delta_add(Snap *s, uint32_t e) {
  if (s->ndelta == s->capdelta) {
    s->capdelta = s->capdelta ? s->capdelta * 2 : 64;
    s->delta = realloc(s->delta, sizeof *s->delta * s->capdelta);
  }
  s->delta[s->ndelta++] = e;
}

/* a new version of page p of region ri for snapshot s: the page as it is now */
static void pg_version(int ri, uint32_t p, Snap *s) {
  Region *r = &tt_rg[ri];
  uint32_t n = pg_bytes(r, p);
  const uint8_t *now = r->base + (uint64_t)p * TT_PG;
  uint8_t *d = NULL;
  if (memcmp(now, tt_zero, n)) {
    d = malloc(TT_PG);
    if (!d) return;
    memcpy(d, now, n);
    tt_bytes += TT_PG;
  }
  PList *l = &r->pl[p];
  if (l->n == l->cap) {
    l->cap = l->cap ? l->cap * 2 : 2;
    l->v = realloc(l->v, sizeof *l->v * l->cap);
  }
  l->v[l->n++] = (PVer){s->serial, d};
  delta_add(s, (uint32_t)ri << 26 | p);
}

static uint64_t tt_hash(void) {
  uint64_t h = 1469598103934665603ull;
#define H(p, n) do { const uint8_t *q_ = (const uint8_t *)(p); for (size_t i_ = 0; i_ < (size_t)(n); i_++) h = (h ^ q_[i_]) * 1099511628211ull; } while (0)
  for (int i = 0; i < ncores; i++) {
    const Core *c = &cores[i];
    H(&c->pc, 8);
    H(c->x, sizeof c->x);
    H(&c->instret, 8);
    H(&c->halted, 1);
    H(&c->user, 1);
    for (int k = 0; k < NCAPS; k++) { H(&c->caps[k].base, 8); H(&c->caps[k].len, 8); H(&c->caps[k].perms, 1); }
  }
  H(&rounds, 8);
  H(&mach_steps, 8);
#undef H
  return h;
}

static void misc_save(Misc *m) {
  memcpy(m->sq_buf, sq_buf, sizeof sq_buf);
  m->sq_fill = sq_fill;
  memcpy(m->sq_cmds, sq_cmds, sizeof sq_cmds);
  memcpy(m->sq_from, sq_from, sizeof sq_from);
  m->sq_head = sq_head, m->sq_cnt = sq_cnt;
  memcpy(m->blk_inbox, blk_inbox, sizeof blk_inbox);
  m->bi_head = bi_head, m->bi_cnt = bi_cnt;
  memcpy(m->cq, cq, sizeof cq);
  m->cq_head = cq_head, m->cq_cnt = cq_cnt, m->cq_byte = cq_byte;
  m->blk_out = blk_out, m->blk_out_to = blk_out_to;
  m->rounds = rounds, m->tmr_deadline = tmr_deadline, m->tmr_wbuf = tmr_wbuf, m->tmr_lnow = tmr_lnow, m->tmr_ldl = tmr_ldl;
  m->ptr_lstate = ptr_lstate, m->npending = npending, m->slow_events = slow_events, m->pend_seq = pend_seq;
  m->net_lstat = net_lstat, m->faulted = faulted;
  memcpy(m->ggen, ggen, sizeof ggen);
  memcpy(m->ghead, ghead, sizeof ghead);
  m->mach_steps = mach_steps, m->opt_break_at = opt_break_at;
  memcpy(m->lead, lead, sizeof lead);
  memcpy(m->blocked_at, blocked_at, sizeof blocked_at);
  memcpy(m->idle, &idle, sizeof idle);
  memcpy(m->host_inq, host_inq, sizeof host_inq);
  m->host_in_head = host_in_head, m->host_in_cnt = host_in_cnt, m->host_breaks = host_breaks, m->host_in_taken = host_in_taken;
  m->in_open = host_in_fd >= 0;
  m->in_off = host_in_fd >= 0 ? (int64_t)lseek(host_in_fd, 0, SEEK_CUR) : 0;
  memcpy(m->host_ptr_q, host_ptr_q, sizeof host_ptr_q);
  m->host_ptr_head = host_ptr_head, m->host_ptr_cnt = host_ptr_cnt, m->ptr_iscript = host_ptr_iscript;
  m->ptr_x = host_ptr_x, m->ptr_y = host_ptr_y, m->ptr_btn = host_ptr_btn, m->ptr_in = host_ptr_in, m->ptr_used = host_ptr_used;
  m->tick = dbg_tick, m->poll_at = dbg_poll_at, m->evseq = dbg_evseq, m->pseq = dbg_pseq;
  memcpy(m->tags, dbg_tags, sizeof dbg_tags);
  memcpy(m->pshadow, dbg_pshadow, sizeof dbg_pshadow);
  m->pnpend = dbg_pnpend;
  memcpy(m->stall, dbg_stall, sizeof dbg_stall);
  memcpy(m->pid_prev, dbg_pid_prev, sizeof dbg_pid_prev);
  memcpy(m->bphold, dbg_bphold, sizeof dbg_bphold);
  m->nprov = dbg_nprov, m->next_id = dbg_next_id;
}

static void misc_load(const Misc *m) {
  memcpy(sq_buf, m->sq_buf, sizeof sq_buf);
  sq_fill = m->sq_fill;
  memcpy(sq_cmds, m->sq_cmds, sizeof sq_cmds);
  memcpy(sq_from, m->sq_from, sizeof sq_from);
  sq_head = m->sq_head, sq_cnt = m->sq_cnt;
  memcpy(blk_inbox, m->blk_inbox, sizeof blk_inbox);
  bi_head = m->bi_head, bi_cnt = m->bi_cnt;
  memcpy(cq, m->cq, sizeof cq);
  cq_head = m->cq_head, cq_cnt = m->cq_cnt, cq_byte = m->cq_byte;
  blk_out = m->blk_out, blk_out_to = m->blk_out_to;
  rounds = m->rounds, tmr_deadline = m->tmr_deadline, tmr_wbuf = m->tmr_wbuf, tmr_lnow = m->tmr_lnow, tmr_ldl = m->tmr_ldl;
  ptr_lstate = m->ptr_lstate, npending = m->npending, slow_events = m->slow_events, pend_seq = m->pend_seq;
  net_lstat = m->net_lstat, faulted = m->faulted;
  memcpy(ggen, m->ggen, sizeof ggen);
  memcpy(ghead, m->ghead, sizeof ghead);
  mach_steps = m->mach_steps, opt_break_at = m->opt_break_at;
  memcpy(lead, m->lead, sizeof lead);
  memcpy(blocked_at, m->blocked_at, sizeof blocked_at);
  memcpy(&idle, m->idle, sizeof idle);
  memcpy(host_inq, m->host_inq, sizeof host_inq);
  host_in_head = m->host_in_head, host_in_cnt = m->host_in_cnt, host_breaks = m->host_breaks, host_in_taken = m->host_in_taken;
  if (m->in_open) {
    if (host_in_fd < 0 && dbg_in_path) host_in_fd = open(dbg_in_path, O_RDONLY);
    if (host_in_fd >= 0) lseek(host_in_fd, (off_t)m->in_off, SEEK_SET);
  } else if (host_in_fd >= 0) {
    close(host_in_fd);
    host_in_fd = -1;
  }
  memcpy(host_ptr_q, m->host_ptr_q, sizeof host_ptr_q);
  host_ptr_head = m->host_ptr_head, host_ptr_cnt = m->host_ptr_cnt, host_ptr_iscript = m->ptr_iscript;
  host_ptr_x = m->ptr_x, host_ptr_y = m->ptr_y, host_ptr_btn = m->ptr_btn, host_ptr_in = m->ptr_in, host_ptr_used = m->ptr_used;
  /* events and capability records newer than the snapshot are dropped (the replay makes them again) */
  if (dbg_evseq > m->evseq) {
    if (dbg_evseq > DBG_EVN && dbg_evseq - DBG_EVN > dbg_evlo) dbg_evlo = dbg_evseq - DBG_EVN;
    dbg_evseq = m->evseq;
    if (dbg_evlo > dbg_evseq) dbg_evlo = dbg_evseq;
  }
  dbg_tick = m->tick, dbg_poll_at = m->poll_at, dbg_pseq = m->pseq;
  memcpy(dbg_tags, m->tags, sizeof dbg_tags);
  memcpy(dbg_pshadow, m->pshadow, sizeof dbg_pshadow);
  dbg_pnpend = m->pnpend;
  memcpy(dbg_stall, m->stall, sizeof dbg_stall);
  memcpy(dbg_pid_prev, m->pid_prev, sizeof dbg_pid_prev);
  memcpy(dbg_bphold, m->bphold, sizeof dbg_bphold);
  dbg_nprov = m->nprov, dbg_next_id = m->next_id;
}

/* Takes a snapshot of the machine now (a round boundary). */
static void tt_snap(void) {
  if (tt_n == tt_cap) {
    tt_cap = tt_cap ? tt_cap * 2 : 64;
    tt_snaps = realloc(tt_snaps, sizeof *tt_snaps * (size_t)tt_cap);
  }
  Snap *s = &tt_snaps[tt_n];
  memset(s, 0, sizeof *s);
  s->tick = dbg_tick;
  s->round = rounds;
  s->serial = ++tt_serial;
  uint32_t bs = tt_base >= 0 ? tt_snaps[tt_base].serial : 0;
  for (int ri = 0; ri < tt_nrg; ri++) {
    Region *r = &tt_rg[ri];
    for (uint32_t p = 0; p < r->npages; p++) {
      if (r->dirty) {
        if (!r->dirty[p]) continue;
        r->dirty[p] = 0;
      }
      const uint8_t *was = tt_base >= 0 ? pg_at(r, p, bs) : NULL;
      if (!memcmp(r->base + (uint64_t)p * TT_PG, was ? was : tt_zero, pg_bytes(r, p))) continue;
      pg_version(ri, p, s);
    }
  }
  s->misc = malloc(sizeof *s->misc);
  if (s->misc) misc_save(s->misc);
  s->hash = tt_hash();
  tt_bytes += sizeof *s->misc + sizeof *s;
  tt_base = tt_n;
  tt_n++;
  tt_next = tt_n;
}

/* Drops snapshot i (not the first nor the last): its versions that the
 * next snapshot needs become the next snapshot's. */
static void tt_drop(int i) {
  Snap *s = &tt_snaps[i], *nx = &tt_snaps[i + 1];
  for (uint32_t k = 0; k < s->ndelta; k++) {
    Region *r = &tt_rg[s->delta[k] >> 26];
    PList *l = &r->pl[s->delta[k] & ((1u << 26) - 1)];
    for (uint32_t j = 0; j < l->n; j++) {
      if (l->v[j].serial != s->serial) continue;
      if (j + 1 < l->n && l->v[j + 1].serial == nx->serial) { /* superseded */
        if (l->v[j].data) tt_bytes -= TT_PG;
        free(l->v[j].data);
        memmove(&l->v[j], &l->v[j + 1], sizeof *l->v * (l->n - j - 1));
        l->n--;
      } else {
        l->v[j].serial = nx->serial;
        delta_add(nx, s->delta[k]);
      }
      break;
    }
  }
  free(s->delta);
  free(s->misc);
  tt_bytes -= sizeof *s->misc + sizeof *s;
  memmove(&tt_snaps[i], &tt_snaps[i + 1], sizeof *tt_snaps * (size_t)(tt_n - i - 1));
  tt_n--;
  if (tt_base > i) tt_base--;
  if (tt_next > i) tt_next--;
}

/* Drops the snapshots after tick t (a new future), with their versions. */
static void tt_cut(uint64_t t) {
  while (tt_n > 0 && tt_snaps[tt_n - 1].tick > t) {
    Snap *s = &tt_snaps[tt_n - 1];
    for (uint32_t k = 0; k < s->ndelta; k++) {
      Region *r = &tt_rg[s->delta[k] >> 26];
      PList *l = &r->pl[s->delta[k] & ((1u << 26) - 1)];
      if (l->n && l->v[l->n - 1].serial == s->serial) {
        if (l->v[l->n - 1].data) tt_bytes -= TT_PG;
        free(l->v[l->n - 1].data);
        l->n--;
      }
    }
    free(s->delta);
    free(s->misc);
    tt_bytes -= sizeof *s->misc + sizeof *s;
    tt_n--;
  }
  if (tt_next > tt_n) tt_next = tt_n;
  if (tt_base >= tt_n) tt_base = tt_n - 1;
}

/* Why going back is not possible now. */
static const char *tt_off_why(void) {
  return dbg_tt_due ? "recording starts again at the next round's start (after a fast continue): step once"
                    : "no time travel in this run (needs -T virtual and no network)";
}

/* Forgets the whole history (a fast continue: what runs is not recorded). */
static void tt_clear(void) {
  for (int ri = 0; ri < tt_nrg; ri++) {
    Region *r = &tt_rg[ri];
    for (uint32_t p = 0; p < r->npages; p++) {
      PList *l = &r->pl[p];
      for (uint32_t k = 0; k < l->n; k++) free(l->v[k].data);
      l->n = 0;
    }
  }
  for (int i = 0; i < tt_n; i++) { free(tt_snaps[i].delta); free(tt_snaps[i].misc); }
  for (size_t i = 0; i < tt_nlog; i++) free(tt_log[i].data);
  tt_n = tt_next = 0;
  tt_base = -1;
  tt_nlog = 0;
  tt_bytes = 0;
  tt_every = TT_EVERY0;
}

/* Recording starts again here, at a round's start (a fast continue has
 * stopped): the first snapshot looks at everything. */
static void tt_restart(void) {
  tt_clear();
  for (int ri = 0; ri < tt_nrg; ri++)
    if (tt_rg[ri].dirty) memset(tt_rg[ri].dirty, 1, tt_rg[ri].npages);
  dbg_frontier = dbg_tick;
  dbg_muted = false;
  tt_applied = 2 * dbg_tick;
  tt_snap();
  dbg_tt = true;
}

/* Keeps the history inside its budget. */
static void tt_thin(void) {
  while (tt_bytes > dbg_hist_mib << 20 && tt_n > 2) {
    for (int i = tt_n - 2; i >= 1; i -= 2) tt_drop(i);
    tt_every *= 2;
  }
}

/* Restores snapshot i: the machine as it was at its tick. */
static void tt_restore(int i) {
  Snap *s = &tt_snaps[i];
  /* far memory and the disk: the pages written since, or changed by a later snapshot */
  for (int ri = 0; ri < tt_nrg; ri++) {
    Region *r = &tt_rg[ri];
    if (!r->dirty) continue;
    for (uint32_t p = 0; p < r->npages; p++)
      if (r->dirty[p]) {
        const uint8_t *d = pg_at(r, p, s->serial);
        memcpy(r->base + (uint64_t)p * TT_PG, d ? d : tt_zero, pg_bytes(r, p));
        r->dirty[p] = 0;
      }
  }
  for (int j = i + 1; j < tt_n; j++)
    for (uint32_t k = 0; k < tt_snaps[j].ndelta; k++) {
      uint32_t e = tt_snaps[j].delta[k], p = e & ((1u << 26) - 1);
      Region *r = &tt_rg[e >> 26];
      if (!r->dirty) continue;
      const uint8_t *d = pg_at(r, p, s->serial);
      memcpy(r->base + (uint64_t)p * TT_PG, d ? d : tt_zero, pg_bytes(r, p));
    }
  /* the cores, whole */
  for (int ri = 0; ri < tt_nrg; ri++) {
    Region *r = &tt_rg[ri];
    if (r->dirty) continue;
    for (uint32_t p = 0; p < r->npages; p++) {
      const uint8_t *d = pg_at(r, p, s->serial);
      memcpy(r->base + (uint64_t)p * TT_PG, d ? d : tt_zero, pg_bytes(r, p));
    }
  }
  misc_load(s->misc);
  dbg_ci = 0;
  dbg_rs = false;
  dbg_skip_tick = -1;
  tt_base = i;
  tt_next = i + 1;
  tt_applied = 2 * s->tick; /* the snapshot's position has had nothing applied yet */
  dbg_muted = dbg_tick < dbg_frontier;
  dbg_idle_pending = false;
  for (int k = 0; k < ncores; k++) {
    dec_invalidate(&cores[k], 0, ILS_BYTES);
    if (use_jit) jit_invalidate(k, 0, ILS_BYTES);
  }
  host_fb_touch(0, host_fb_bytes());
  os_procs_at = ~0ull;
  if (dbg_state == ST_DONE) dbg_state = ST_STOPPED;
}

/* At the start of a round: pass a snapshot (replay), or take one (live). */
static void tt_at_round(void) {
  if (tt_next < tt_n && tt_snaps[tt_next].tick == dbg_tick) {
    if (tt_snaps[tt_next].hash != tt_hash()) tt_diverged++;
    for (int ri = 0; ri < tt_nrg; ri++)
      if (tt_rg[ri].dirty) memset(tt_rg[ri].dirty, 0, tt_rg[ri].npages);
    tt_base = tt_next++;
    return;
  }
  if (dbg_tick < dbg_frontier || tt_next < tt_n) return;
  if (tt_n && dbg_tick - tt_snaps[tt_n - 1].tick < tt_every) return;
  tt_snap();
  tt_thin();
}

static void tt_dirty(uint8_t space, uint64_t addr) {
  Region *r = &tt_rg[space == SP_T3 ? 0 : 1];
  uint64_t p = (addr & ((space == SP_T3 ? T3_BYTES : T2_BYTES) - 1)) / TT_PG;
  if (r->dirty) r->dirty[p] = 1;
}
static void tt_disk_dirty(uint64_t off, uint64_t len) {
  Region *r = &tt_rg[2];
  if (!dbg_tt || !r->dirty) return;
  for (uint64_t p = off / TT_PG; p < r->npages && p * TT_PG < off + len; p++) r->dirty[p] = 1;
}

static void tt_init(void) {
  rg_add(t3, T3_BYTES, true);
  rg_add(t2, T2_BYTES, true);
  rg_add(disk, disk_blocks * BLK_BLOCK, true);
  for (int i = 0; i < ncores; i++) rg_add((uint8_t *)&cores[i], sizeof(Core), false);
  for (int ri = 0; ri < 3; ri++) memset(tt_rg[ri].dirty, 1, tt_rg[ri].npages); /* the first snapshot looks at everything */
  tt_snap();
}

/* ------------------------------------------------------------ the input log */

static uint64_t cur_pos(void) { return 2 * dbg_tick + (dbg_rs || dbg_ci ? 1 : 0); }

/* Does what an input-log entry says. */
static void inject(const InLog *e) {
  switch (e->kind) {
  case IN_BYTES:
    for (size_t i = 0; i < e->n; i++) host_in_push(e->data[i]);
    break;
  case IN_BREAK: press_break(); break;
  case IN_XREG: setx(&cores[e->core], (unsigned)e->a, e->b); break;
  case IN_PC: cores[e->core].pc = e->b; break;
  case IN_PTR: { /* the pointer device, as web/web.c web_pointer */
    int x = (int)(int32_t)(uint32_t)e->b, y = (int)(int32_t)(uint32_t)(e->b >> 32);
    switch ((int)e->a) {
    case PTR_MOVE: host_ptr_move(x, y); break;
    case PTR_BUTTON: host_ptr_button(x, y != 0); break;
    case PTR_WHEEL: host_ptr_wheel(x, y); break;
    case PTR_ENTER: host_ptr_enter(true); break;
    case PTR_LEAVE: host_ptr_enter(false); break;
    }
    pend_service(); /* (a waiting EVENT read completes now) */
    break;
  }
  default: {
    int sp = e->kind - IN_MEM;
    uint8_t *p = sp == 0 ? cores[e->core].dls : sp == 1 ? cores[e->core].ils : sp == 2 ? t2 : sp == 3 ? t3 : disk;
    memcpy(p + e->a, e->data, e->n);
    if (sp == 1) { jit_invalidate(e->core, e->a, e->n); dec_invalidate(&cores[e->core], e->a, e->n); }
    if (sp == 2 || sp == 3)
      for (uint64_t i = 0; i < e->n; i += 8) dbg_far_written(sp == 2 ? SP_T2 : SP_T3, (e->a + i) & ~7ull);
    if (sp == 4) dbg_disk_written(e->a, e->n);
    break;
  }
  }
  if (e->kind == IN_BYTES) pend_service(); /* (a waiting console read completes now, as in web_input) */
  pend_diff();
}

/* applies the log's entries for the current position (once) */
static void tt_apply_pos(void) {
  uint64_t pos = cur_pos();
  if (pos < tt_applied) return;
  tt_applied = pos + 1;
  /* (entries are in position order; few: a linear search from the end is fine) */
  size_t i = tt_nlog;
  while (i > 0 && tt_log[i - 1].pos >= pos) i--;
  for (; i < tt_nlog && tt_log[i].pos == pos; i++) inject(&tt_log[i]);
}
static void tt_apply(uint64_t tick) {
  (void)tick;
  tt_apply_pos();
}
static bool tt_log_at(uint64_t tick) {
  for (size_t i = tt_nlog; i > 0; i--) {
    if (tt_log[i - 1].pos >> 1 == tick) return true;
    if (tt_log[i - 1].pos >> 1 < tick) break;
  }
  return false;
}

/* The debugger changed the machine (or input came) at the current position
 * of a replay: the recorded future is no longer this run's. */
static void tt_new_future(void) {
  uint64_t pos = cur_pos();
  while (tt_nlog && tt_log[tt_nlog - 1].pos > pos) free(tt_log[--tt_nlog].data);
  tt_cut(dbg_tick);
  dbg_frontier = dbg_tick;
  dbg_muted = false;
}

/* Something from outside: logged with its position (time travel), and done. */
static void tt_input_log(int kind, const uint8_t *p, size_t n, int core, uint64_t a, uint64_t b) {
  InLog e = {cur_pos(), kind, core, a, b, NULL, n};
  if (n) {
    e.data = malloc(n);
    if (e.data) memcpy(e.data, p, n);
    else e.n = 0;
  }
  if (dbg_tt) {
    if (dbg_tick < dbg_frontier) tt_new_future();
    if (tt_nlog == tt_caplog) {
      tt_caplog = tt_caplog ? tt_caplog * 2 : 64;
      tt_log = realloc(tt_log, sizeof *tt_log * tt_caplog);
    }
    tt_log[tt_nlog++] = e;
    tt_applied = cur_pos() + 1;
    inject(&e);
  } else {
    inject(&e);
    free(e.data);
  }
}

/* ------------------------------------------------------------ going back */

/* Executes from the current position to the front of tick t's slot (as a
 * forward stop there would be: after the round's start), quietly. */
static bool tt_run_to(uint64_t t) {
  bool was = search.on;
  __typeof__(goal) g = goal;
  search.on = true;
  search.kind = 0;
  goal.kind = G_TICK;
  goal.target = t;
  stop.hit = false;
  for (;;) {
    int r = dbg_tick1();
    if (r != TK_OK || dbg_tick > t) break;
  }
  search.on = was;
  goal = g;
  stop.hit = false;
  return dbg_tick == t;
}

static int tt_find(uint64_t t) { /* the last snapshot at or before tick t */
  int i = tt_n - 1;
  while (i > 0 && tt_snaps[i].tick > t) i--;
  return i;
}

static bool tt_goto(uint64_t t, char *err, size_t ne) {
  if (!dbg_tt) { snprintf(err, ne, "%s", tt_off_why()); return false; }
  if (t > dbg_frontier) { snprintf(err, ne, "tick %llu has not happened yet", (unsigned long long)t); return false; }
  if (t < tt_snaps[0].tick) { snprintf(err, ne, "the history starts at tick %llu", (unsigned long long)tt_snaps[0].tick); return false; }
  if (t <= dbg_tick) tt_restore(tt_find(t));
  if (!tt_run_to(t)) { snprintf(err, ne, "could not reach tick %llu", (unsigned long long)t); return false; }
  stop.hit = false;
  stop_req(-1, 0, "goto");
  return true;
}

/* Reverse search: back to the last tick before now at which `kind` holds
 * (SK_BPS: a breakpoint or watchpoint would stop; SK_STEP: core `core`
 * makes a step; SK_TAG: core's tag `tag` is issued), n times. */
static bool tt_reverse(int kind, int core, int tag, uint64_t n, char *err, size_t ne) {
  if (!dbg_tt) { snprintf(err, ne, "%s", tt_off_why()); return false; }
  uint64_t orig = dbg_tick;
  int64_t found = -1;
  int lastbp = 0, lastcore = -1;
  __typeof__(goal) g = goal;
  goal.kind = G_CONT;
  for (uint64_t rep = 0; rep < (n ? n : 1); rep++) {
    uint64_t hi = found >= 0 ? (uint64_t)found : orig;
    int64_t f = -1;
    for (int k = tt_find(hi ? hi - 1 : 0); k >= 0 && f < 0; k--) {
      if (tt_snaps[k].tick >= hi) continue;
      tt_restore(k);
      search.on = true;
      search.kind = kind;
      search.core = core;
      search.tag = tag;
      search.last = -1;
      stop.hit = false;
      while (dbg_tick < hi) {
        int r = dbg_tick1();
        if (r == TK_DONE || r == TK_IDLE) break;
      }
      search.on = false;
      if (search.last >= 0 && (uint64_t)search.last < hi) { f = search.last; lastbp = search.lastbp; lastcore = search.lastcore; }
      hi = tt_snaps[k].tick;
    }
    if (f < 0) break;
    found = f;
  }
  char e2[64];
  goal = g;
  if (found < 0) {
    tt_goto(orig, e2, sizeof e2);
    snprintf(err, ne, "%s", kind == SK_STEP ? "no earlier step of that core in the history" : kind == SK_TAG ? "no earlier issue of that tag in the history" : "no breakpoint or watchpoint fires earlier in the history");
    return false;
  }
  tt_restore(tt_find((uint64_t)found));
  tt_run_to((uint64_t)found);
  dbg_skip_tick = (int64_t)found;
  if (kind == SK_BPS && lastcore >= 0 && lastcore < ncores) dbg_bphold[lastcore] = cores[lastcore].pc;
  stop.hit = false;
  if (kind == SK_BPS) stop_req(lastcore, lastbp, "reverse: breakpoint %d", lastbp);
  else stop_req(core, 0, kind == SK_STEP ? "reverse step" : "reverse: tg%d issued", tag);
  return true;
}

static void tt_history_json(JW *w) {
  jw_obj(w, "history");
  jw_bool(w, "on", dbg_tt);
  if (dbg_tt && tt_n) {
    jw_uint(w, "from", tt_snaps[0].tick);
    jw_uint(w, "to", dbg_frontier);
    jw_int(w, "snapshots", tt_n);
    jw_uint(w, "every", tt_every);
    jw_uint(w, "bytes", tt_bytes);
    jw_uint(w, "budget", dbg_hist_mib << 20);
    jw_uint(w, "inputs", tt_nlog);
    jw_uint(w, "diverged", tt_diverged);
    jw_arr(w, "ticks");
    for (int i = 0; i < tt_n; i++) jw_uint(w, NULL, tt_snaps[i].tick);
    jw_aend(w);
  }
  jw_oend(w);
}
