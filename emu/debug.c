/* The debug engine of strata-emu (--debug): run control, breakpoints and
 * watchpoints, the machine's state decoded, an event log, capability
 * provenance and time travel, behind one JSON-lines protocol
 * (doc/debug-protocol.md). The text debugger (dbg/strata-dbg.c) and the
 * web debugger (site/debug/) are front-ends of it; the same engine runs in
 * the desktop build (transports: emu/debug_io.c) and in the browser
 * (web/web.c calls dbg_request() and dbg_run() from the worker).
 *
 * emu.c includes this file in front of main(), so the engine sees the whole
 * machine. Nothing here changes what an instruction does: the engine runs
 * the machine its own way, one core slot at a time, and watches from
 * outside step():
 *
 *   one TICK = one core's slot in a machine round. Round r runs core 0,
 *   then core 1, ..., exactly as machine_round() does without the JIT and
 *   without the fast loop (the reference interleaving of -t). dbg_tick
 *   counts slots since power-on; it is the debugger's clock and what time
 *   travel goes back to. Before a slot the engine decodes the instruction
 *   at the core's pc (breakpoints stop here, before it executes); after
 *   it, it compares the core with what it was (transfers issued, gifts,
 *   capabilities made, watchpoints) and diffs the pending device reads of
 *   all cores (completions). The hooks in emu.c (debug.h) report what
 *   cannot be seen from outside: far writes, disk writes, traps, console
 *   output.
 *
 * A plain `continue` with no breakpoint or watchpoint set, on a run that is
 * not recorded for time travel, runs machine_round() itself (the JIT, the
 * fast loop) and stops at a round boundary: a pause with the JIT on lands
 * between quanta.
 *
 * Time travel (emu/debug_tt.c) needs a deterministic run: the virtual
 * timer (-T virtual), no JIT, no network. The engine then keeps snapshots
 * every so many ticks and logs everything that comes from outside (console
 * input, Ctrl-C, the debugger's own writes) with its tick; going back is a
 * restore and a re-execution. */
#include "../common/json.h"

#define DBG_PROTO_VERSION 1
#define DBG_NBP 64        /* breakpoints and watchpoints */
#define DBG_EVN (1 << 16) /* events kept */
#define DBG_PROVMAX (1 << 20)
#define DBG_CONN 64 * 1024 /* console output kept for clients that connect later */

/* ------------------------------------------------------------ the engine's state */

enum { ST_STOPPED, ST_RUNNING, ST_DONE };
static int dbg_state = ST_STOPPED;
static const char *dbg_done_why = "";

static uint64_t dbg_tick;          /* core slots since power-on */
static uint64_t dbg_frontier;      /* the furthest tick reached: before it the run is replayed */
static int dbg_ci;                 /* the core whose slot comes next */
static bool dbg_rs;                /* the current round has started (rounds++, pend_service) */
static bool dbg_rr_live, dbg_rr_progress; /* this round: a live core, a step */
static uint64_t dbg_poll_at;       /* the round of the next host poll (as main's loop) */
static int64_t dbg_skip_tick = -1; /* the slot stopped in front of: its breakpoints are passed */
static bool dbg_tt;                /* time travel: snapshots and the input log are kept */
static bool dbg_ttok;              /* this run can be recorded (-T virtual, no network) */
static bool dbg_ff;                /* a fast continue: not recorded until it stops */
static bool dbg_tt_due;            /* recording starts again at the next round's start */
static void tt_restart(void); /* debug_tt.c */
static const char *tt_off_why(void);
static void tt_clear(void);
static bool dbg_fastok;            /* a plain continue may run machine_round() (JIT, fast loop) */
static bool dbg_trapped;           /* a trap was taken in this slot */
static int dbg_trap_cause;
static bool dbg_pause_req;
static bool dbg_quit;
static bool dbg_idle_pending, dbg_idle_skip; /* an idle wait in progress; skip ahead when it ends */

static const char *dbg_where;      /* --debug */
static const char *dbg_www;        /* --www */
#ifdef __EMSCRIPTEN__
static uint64_t dbg_hist_mib = 128; /* --history (a browser tab has less room) */
#else
static uint64_t dbg_hist_mib = 512; /* --history */
#endif
static const char *dbg_mapv[16];   /* --map */
static int dbg_nmapv;
static const char *dbg_in_path, *dbg_img_path;
static bool dbg_hold;

/* what the current run waits for */
enum { G_CONT, G_STEPI, G_ROUNDS, G_TICK, G_UNTILPC };
static struct {
  int kind;
  int core;      /* G_STEPI, G_UNTILPC: the core (-1: whichever runs pid) */
  int pid;       /* G_STEPI: follow this process (StrataOS) */
  uint64_t left; /* G_STEPI, G_ROUNDS */
  uint64_t target; /* G_TICK: the tick; G_UNTILPC: the pc */
  bool nobreak;  /* G_TICK: breakpoints do not stop it */
} goal;

/* why the machine stopped */
static struct {
  bool hit;
  int core, bp;
  char why[256];
} stop;

/* reverse search: instead of stopping, remember the last tick that would have stopped */
enum { SK_BPS = 1, SK_STEP, SK_TAG };
static struct {
  bool on;
  int kind, core, tag;
  int64_t last;   /* the last tick found, -1 none */
  int lastbp, lastcore;
} search;

/* ------------------------------------------------------------ breakpoints */

enum {
  BK_PC = 1, BK_TRAP, BK_SVC, BK_ERET, BK_CAPOP, BK_HALT, BK_PID, /* breakpoints */
  WK_LS, WK_FAR, WK_CAP, WK_TAG,                                  /* watchpoints */
};
static const char *const bk_names[] = {"", "pc", "trap", "svc", "eret", "capop", "halt", "pid", "ls", "far", "cap", "tag"};
/* capability operations a capop breakpoint selects (bits) */
enum {
  CO_GIVE = 1, CO_TAKE = 2, CO_SEND = 4, CO_RECV = 8, CO_DOM = 16, CO_REVOKE = 32, CO_UNDOM = 64,
  CO_SPLIT = 128, CO_SHARE = 256, CO_RESTRICT = 512, CO_JOIN = 1024, CO_SAVE = 2048, CO_RESTORE = 4096,
  CO_MKEP = 8192, CO_ATOMIC = 16384,
};
static const char *const co_names[] = {"give", "take", "send", "recv", "dom", "revoke", "undom", "split",
                                       "share", "restrict", "join", "save", "restore", "mkep", "atomic"};

typedef struct {
  int id, kind;
  bool on, temp;
  int core;           /* -1: any */
  uint64_t addr, len; /* pc; watched range */
  int mem;            /* WK_LS: 0 D-LS, 1 I-LS; WK_FAR: the space */
  int access;         /* watchpoints: 1 read, 2 write, 3 both; WK_TAG: 1 issue, 2 completion */
  int arg;            /* BK_TRAP cause (-1 any), BK_CAPOP bits, BK_PID pid, WK_CAP register, WK_TAG tag */
  char prog[24];      /* BK_PC (StrataOS): only while this program runs */
  uint64_t ignore, hits;
  bool cond;          /* stop only if x[creg] OP cval */
  int creg, cop;
  uint64_t cval;
  char desc[200];
} Bp;
static Bp dbg_bp[DBG_NBP];
static int dbg_nbp, dbg_bp_next = 1;
static int dbg_nlive_bp;   /* enabled ones (0: a continue may run at full speed) */
static int dbg_pid_prev[MAXCORES]; /* BK_PID: the pid each core ran in user mode at its last slot (-1 none) */
/* a pc breakpoint that stopped core i in front of dbg_bphold[i] does not fire
 * again there until the core has made its step (it may wait for rounds) */
static uint64_t dbg_bphold[MAXCORES];

/* ------------------------------------------------------------ transfers, stalls, events */

/* The last transfer of every tag of every core. */
typedef struct {
  bool valid, busy;
  uint8_t sub, space;
  uint64_t ls, len, far, pc;
  uint64_t issue_round, issue_tick, done_round, done_tick;
} TagRec;
static TagRec dbg_tags[MAXCORES][16];

/* A copy of every pending device read, to see completions (pend_diff). */
static Pending dbg_pshadow[MAXCORES][NPEND];
static int dbg_pnpend;
static uint64_t dbg_pseq;

/* A core that cannot make its step: since when and why. */
enum { SR_NONE, SR_LSPEND, SR_XPEND, SR_TAG, SR_PENDFULL, SR_TWAIT, SR_TANY, SR_TAKE, SR_RECV, SR_GIVE, SR_HALT, SR_OTHER };
static const char *const sr_names[] = {"", "ls-hazard", "xfer-hazard", "tag-busy", "pending-full", "twait", "tany",
                                       "inbox-empty", "inbox-empty", "inbox-full", "halt-drain", "blocked"};
typedef struct { bool on; uint64_t from_round, from_tick; int reason; uint64_t detail; } Stall;
static Stall dbg_stall[MAXCORES];

enum {
  EV_XFER = 1, EV_XDONE, EV_TRAP, EV_ERET, EV_GIVE, EV_TAKE, EV_SEND, EV_RECV, EV_DOM, EV_REVOKE, EV_UNDOM,
  EV_HALT, EV_STALL, EV_INPUT, EV_POKE,
};
static const char *const ev_names[] = {"", "xfer", "xdone", "trap", "eret", "give", "take", "send", "recv", "dom",
                                       "revoke", "undom", "halt", "stall", "input", "poke"};
typedef struct {
  uint64_t tick, round;
  uint16_t kind;
  int8_t core;
  uint8_t tag, sub, space, perms, flag;
  uint32_t id, pid;
  uint64_t a, b, c, d, pc;
} Ev;
static Ev *dbg_ev;               /* DBG_EVN of them, a ring */
static uint64_t dbg_evseq, dbg_evlo; /* the next sequence number; the oldest one still kept */

static void ev_add(const Ev *e) {
  if (!dbg_ev) return;
  Ev *d = &dbg_ev[dbg_evseq % DBG_EVN];
  *d = *e;
  d->tick = dbg_tick;
  d->round = rounds;
  dbg_evseq++;
  if (dbg_evseq - dbg_evlo > DBG_EVN) dbg_evlo = dbg_evseq - DBG_EVN;
}

/* ------------------------------------------------------------ capability provenance */

enum { PO_RESET = 1, PO_SPLIT, PO_SHARE, PO_RESTRICT, PO_GIVE, PO_MINT, PO_JOIN, PO_DOM, PO_REVOKER, PO_REVOKE, PO_UNDOM, PO_ATOMIC, PO_OTHER };
static const char *const po_names[] = {"", "reset", "split", "share", "restrict", "give", "mint", "join", "dom", "revoker",
                                       "revoke", "undom", "atomic", "other"};
typedef struct {
  uint32_t id, parent, parent2;
  uint8_t op, core, space, perms;
  int16_t from;  /* PO_GIVE: the sending node */
  uint8_t rv;
  uint64_t base, len, round, tick, pc;
} Prov;
static Prov *dbg_prov;
static uint32_t dbg_nprov;     /* records kept (id - 1 indexes them while < DBG_PROVMAX) */
static uint32_t dbg_next_id = 1;

/* Gives capability k (just made by core c with operation op) a new id. */
static void prov_new(Core *c, Cap *k, int op, uint32_t parent, uint32_t parent2, int from) {
  if (!k->valid) return;
  k->id = dbg_next_id++;
  if (!dbg_prov && !(dbg_prov = calloc(DBG_PROVMAX, sizeof *dbg_prov))) return;
  if (k->id - 1 >= DBG_PROVMAX) return;
  Prov *p = &dbg_prov[k->id - 1];
  *p = (Prov){k->id, parent, parent2, (uint8_t)op, (uint8_t)(c ? c->id : 255), k->space, k->perms, (int16_t)from, k->rv,
              k->base, k->len, rounds, dbg_tick, c ? c->pc : 0};
  dbg_nprov = k->id;
}
static const Prov *prov_get(uint32_t id) {
  if (!id || id > dbg_nprov || id - 1 >= DBG_PROVMAX || !dbg_prov) return NULL;
  return &dbg_prov[id - 1];
}

/* console output not yet sent, and the last DBG_CONN bytes for late clients */
static JW dbg_out;               /* events not yet sent (JSON lines) */
static char *dbg_conring;
static uint64_t dbg_conlen;
static char dbg_conpend[4096];
static int dbg_conpend_n;

static uint32_t rd32_ils(const Core *c, uint64_t a) {
  uint32_t v = 0;
  if (a + 4 <= ILS_BYTES) memcpy(&v, c->ils + a, 4);
  return v;
}

#include "debug_sym.c"

/* ------------------------------------------------------------ events out */

static void out_line(const JW *w) {
  jw_raw(&dbg_out, w->p, w->n);
  jw_raw(&dbg_out, "\n", 1);
}

static void con_flush(void) {
  if (!dbg_conpend_n) return;
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "ev", "console");
  jw_strn(&w, "data", dbg_conpend, (size_t)dbg_conpend_n);
  jw_oend(&w);
  out_line(&w);
  free(w.p);
  dbg_conpend_n = 0;
}

/* A console output byte of the guest: to the clients, not to stdout. */
static void dbg_con_out(uint8_t b) {
  if (dbg_muted) return;
  if (!dbg_conring) dbg_conring = malloc(DBG_CONN);
  if (dbg_conring) dbg_conring[dbg_conlen % DBG_CONN] = (char)b;
  dbg_conlen++;
  dbg_conpend[dbg_conpend_n++] = (char)b;
  if (dbg_conpend_n == (int)sizeof dbg_conpend || b == '\n') con_flush();
}

/* ------------------------------------------------------------ the hooks (debug.h) */

static void tt_dirty(uint8_t space, uint64_t addr);   /* debug_tt.c */
static void tt_disk_dirty(uint64_t off, uint64_t len);

static struct { bool on; uint64_t addr; uint8_t space; } dbg_farw; /* the first watched far write of a slot */

static void dbg_far_written(uint8_t space, uint64_t addr) {
  if (dbg_tt) tt_dirty(space, addr);
  for (int i = 0; i < dbg_nbp; i++) {
    Bp *b = &dbg_bp[i];
    if (!b->on || b->kind != WK_FAR || !(b->access & 2) || b->mem != space) continue;
    if (addr < b->addr + b->len && b->addr < addr + 8 && !dbg_farw.on) {
      dbg_farw.on = true;
      dbg_farw.addr = addr;
      dbg_farw.space = space;
    }
  }
}
static void dbg_disk_written(uint64_t off, uint64_t len) {
  if (dbg_tt) tt_disk_dirty(off, len);
}
static void dbg_trap(Core *c, int cause, uint64_t tval) {
  dbg_trapped = true;
  dbg_trap_cause = cause;
  Ev e = {0};
  e.kind = EV_TRAP;
  e.core = (int8_t)c->id;
  e.a = (uint64_t)cause;
  e.b = tval;
  e.pc = c->pc;
  e.flag = c->user;
  e.pid = (uint32_t)os_cur_pid(c->id);
  ev_add(&e);
}

/* ------------------------------------------------------------ stopping */

static void stop_req(int core, int bp, const char *fmt, ...) {
  if (stop.hit) return;
  stop.hit = true;
  stop.core = core;
  stop.bp = bp;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(stop.why, sizeof stop.why, fmt, ap);
  va_end(ap);
}

/* A breakpoint or watchpoint fired on core `core`: a stop, or (reverse
 * search) the tick remembered. Counts hits and ignore counts. */
static void bp_fire(Bp *b, int core, const char *what) {
  if (goal.kind == G_TICK && goal.nobreak && !search.on) return;
  if (search.on) {
    if (search.kind == SK_BPS) { search.last = (int64_t)dbg_tick; search.lastbp = b->id; search.lastcore = core; }
    return;
  }
  b->hits++;
  if (b->ignore) { b->ignore--; return; }
  stop_req(core, b->id, "%s %d: %s%s%s", b->kind >= WK_LS ? "watchpoint" : "breakpoint", b->id, b->desc,
           what && what[0] ? ", " : "", what ? what : "");
  if (b->temp) b->on = false;
}

static uint64_t reg_value(const Core *c, int r) {
  if (r >= 0 && r < 32) return c->x[r];
  if (r == 32) return c->pc;
  if (r == 33) return c->instret;
  return 0;
}
static bool cond_ok(const Bp *b, const Core *c) {
  if (!b->cond) return true;
  uint64_t v = reg_value(c, b->creg), w = b->cval;
  switch (b->cop) {
  case 0: return v == w;
  case 1: return v != w;
  case 2: return (int64_t)v < (int64_t)w;
  case 3: return (int64_t)v > (int64_t)w;
  case 4: return (int64_t)v <= (int64_t)w;
  case 5: return (int64_t)v >= (int64_t)w;
  }
  return true;
}

static void bp_recount(void) {
  dbg_nlive_bp = 0;
  for (int i = 0; i < dbg_nbp; i++) dbg_nlive_bp += dbg_bp[i].on;
}

/* ------------------------------------------------------------ one tick */

/* What the instruction a core is about to execute will touch, decoded
 * from its registers before the step. */
enum { DK_NONE, DK_LOAD, DK_STORE, DK_XFER, DK_CAP, DK_CAP2, DK_TAMO, DK_LTAG, DK_LINST, DK_SYS };
typedef struct {
  uint32_t ir;
  int kind;
  unsigned op, fn, sub, tag, ci, cd, cs, slot;
  uint64_t addr, len, off, far, b, pc, instret;
  Cap cap, pcd, pcs;
  bool halted, user;
  Cap caps[NCAPS]; /* only when a capability watchpoint is set */
} Pre;

static bool any_capwatch(void) {
  for (int i = 0; i < dbg_nbp; i++)
    if (dbg_bp[i].on && dbg_bp[i].kind == WK_CAP) return true;
  return false;
}

static void pre_decode(Core *c, Pre *p) {
  memset(p, 0, offsetof(Pre, caps));
  p->pc = c->pc;
  p->instret = c->instret;
  p->halted = c->halted;
  p->user = c->user;
  if (any_capwatch()) memcpy(p->caps, c->caps, sizeof p->caps);
  if ((c->pc & 3) || c->pc >= ILS_BYTES) return;
  uint32_t ir;
  memcpy(&ir, c->ils + c->pc, 4);
  p->ir = ir;
  unsigned op = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31;
  unsigned funct = ir & 0x7ff;
  uint64_t simm = (uint64_t)sext(ir & 0xffff, 16);
  p->op = op;
  p->b = c->x[rs2];
  switch (op) {
  case OP_LD: case OP_LW: case OP_LWU: case OP_LH: case OP_LHU: case OP_LB: case OP_LBU:
    p->kind = DK_LOAD;
    p->addr = c->x[rs1] + simm;
    p->len = op == OP_LD ? 8 : op <= OP_LWU ? 4 : op <= OP_LHU ? 2 : 1;
    break;
  case OP_SD: case OP_SW: case OP_SH: case OP_SB:
    p->kind = DK_STORE;
    p->addr = c->x[rs1] + simm;
    p->len = 8u >> (op - OP_SD);
    break;
  case OP_XFER:
    p->kind = DK_XFER;
    p->sub = (ir >> 23) & 7;
    p->tag = (ir >> 19) & 15;
    p->ci = (ir >> 10) & 15;
    p->addr = c->x[(ir >> 14) & 31];
    p->off = c->x[(ir >> 5) & 31];
    p->len = c->x[ir & 31];
    p->cap = c->caps[p->ci];
    p->far = p->cap.base + p->off;
    break;
  case OP_TAMO:
    p->kind = DK_TAMO;
    p->ci = (funct >> 7) & 15;
    p->cap = c->caps[p->ci];
    p->off = c->x[rs1];
    p->far = p->cap.base + p->off;
    p->len = 8;
    break;
  case OP_CAP: case OP_CAP2:
    p->kind = op == OP_CAP ? DK_CAP : DK_CAP2;
    p->fn = funct & 15;
    p->cd = rd & 15;
    p->cs = rs1 & 15;
    p->slot = (funct >> 5) & 63;
    p->pcd = c->caps[p->cd];
    p->pcs = c->caps[p->cs];
    break;
  case OP_LTAG: case OP_LINST: {
    unsigned lsh = c->tgeom & 63, lsets = (c->tgeom >> 6) & 63, ways = (c->tgeom >> 12) & 15;
    uint64_t line = c->x[rs1] >> lsh, set = line & ((1ull << lsets) - 1), span = ((uint64_t)ways + 1) * 8;
    p->kind = op == OP_LTAG ? DK_LTAG : DK_LINST;
    p->addr = c->ttag + set * span;
    p->len = span;
    break;
  }
  case OP_SYS: p->kind = DK_SYS; p->fn = ir & 0xffff; break;
  }
}

/* the capability-operation bit of a decoded instruction (0: none) */
static int pre_capop(const Pre *p) {
  if (p->kind == DK_CAP)
    switch (p->fn) {
    case CF_GIVE: return CO_GIVE;
    case CF_TAKE: return CO_TAKE;
    case CF_SPLIT: return CO_SPLIT;
    case CF_SHARE: return CO_SHARE;
    case CF_RESTR: return CO_RESTRICT;
    case CF_JOIN: return CO_JOIN;
    case CF_SAVE: return CO_SAVE;
    case CF_RESTORE: return CO_RESTORE;
    case CF_ATOM: return CO_ATOMIC;
    }
  if (p->kind == DK_CAP2)
    switch (p->fn) {
    case C2_SEND: return CO_SEND;
    case C2_RECV: return CO_RECV;
    case C2_DOM: return CO_DOM;
    case C2_REVOKE: return CO_REVOKE;
    case C2_UNDOM: return CO_UNDOM;
    case C2_MKEP: return CO_MKEP;
    case C2_SAVEX: return CO_SAVE;
    case C2_RESTOREX: return CO_RESTORE;
    }
  return 0;
}

static const char *cur_prog(const Core *c) { return os_aware && c->user ? os_name_of(os_cur_pid(c->id)) : NULL; }

/* Breakpoints in front of core c's instruction. */
static void pre_hits(Core *c, const Pre *p) {
  if (search.on && search.kind != SK_BPS) return;
  for (int i = 0; i < dbg_nbp && !stop.hit; i++) {
    Bp *b = &dbg_bp[i];
    if (!b->on || (b->core >= 0 && b->core != c->id)) continue;
    switch (b->kind) {
    case BK_PC:
      if (c->pc != b->addr || c->pc == dbg_bphold[c->id] || !cond_ok(b, c)) continue;
      if (b->prog[0]) {
        const char *pn = cur_prog(c);
        if (!pn || strcmp(pn, b->prog)) continue;
      }
      bp_fire(b, c->id, NULL);
      if (stop.hit && !search.on) dbg_bphold[c->id] = c->pc;
      break;
    case BK_SVC: if (p->kind == DK_SYS && p->fn == SYS_SVC && cond_ok(b, c)) bp_fire(b, c->id, NULL); break;
    case BK_ERET: if (p->kind == DK_SYS && p->fn == SYS_ERET && cond_ok(b, c)) bp_fire(b, c->id, NULL); break;
    case BK_CAPOP: {
      int co = pre_capop(p);
      if (co && (b->arg & co) && cond_ok(b, c)) bp_fire(b, c->id, co_names[__builtin_ctz((unsigned)co)]);
      break;
    }
    case BK_PID: {
      int now = c->user ? os_cur_pid(c->id) : -1;
      if (now == b->arg && dbg_pid_prev[c->id] != b->arg) {
        char w[64];
        snprintf(w, sizeof w, "pid %d runs on core %d", now, c->id);
        bp_fire(b, c->id, w);
      }
      break;
    }
    }
  }
}

/* why core c cannot make its step now (the conditions step() waits on) */
static int stall_reason(const Core *c, uint64_t *detail) {
  *detail = 0;
  if ((c->pc & 3) || c->pc >= ILS_BYTES) return SR_OTHER;
  uint32_t ir;
  memcpy(&ir, c->ils + c->pc, 4);
  unsigned op = ir >> 26, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31, funct = ir & 0x7ff;
  uint64_t busy = tag_busy(c);
  switch (op) {
  case OP_LD: case OP_LW: case OP_LWU: case OP_LH: case OP_LHU: case OP_LB: case OP_LBU:
  case OP_SD: case OP_SW: case OP_SH: case OP_SB: case OP_LTAG: case OP_LINST:
    *detail = busy;
    return SR_LSPEND;
  case OP_XFER: {
    uint64_t ls = c->x[(ir >> 14) & 31], len = c->x[ir & 31];
    unsigned sub = (ir >> 23) & 7, tg = (ir >> 19) & 15;
    if (sub != XF_GETX && len)
      for (int i = 0; i < NPEND; i++)
        if (c->pend[i].on && ls < c->pend[i].ls + c->pend[i].len && c->pend[i].ls < ls + len) { *detail = (uint64_t)c->pend[i].tag; return SR_XPEND; }
    if (busy >> tg & 1) { *detail = tg; return SR_TAG; }
    return SR_PENDFULL;
  }
  case OP_TWAIT: *detail = busy & (ir & 0xffff); return SR_TWAIT;
  case OP_TANY: *detail = c->x[rs1]; return SR_TANY;
  case OP_SYS: *detail = busy; return SR_HALT;
  case OP_CAP:
    if ((funct & 15) == CF_TAKE) { *detail = (funct & 16) ? c->x[rs2] + c->corebase : 0xff; return SR_TAKE; }
    if ((funct & 15) == CF_GIVE) { *detail = c->x[rs2] + c->corebase; return SR_GIVE; }
    return SR_OTHER;
  case OP_CAP2:
    if ((funct & 15) == C2_RECV) { *detail = c->caps[rs1 & 15].base; return SR_RECV; }
    if ((funct & 15) == C2_SEND) { *detail = c->caps[(ir >> 21) & 15].base; return SR_GIVE; }
    return SR_OTHER;
  }
  return SR_OTHER;
}

/* Watchpoints on Local Store bytes: core c touched [a, a + n) of mem (0
 * D-LS, 1 I-LS) with access acc (1 read, 2 write). */
static void ls_touch(int core, int mem, uint64_t a, uint64_t n, int acc, const char *how) {
  if (!n) return;
  for (int i = 0; i < dbg_nbp; i++) {
    Bp *b = &dbg_bp[i];
    if (!b->on || b->kind != WK_LS || b->mem != mem || !(b->access & acc) || (b->core >= 0 && b->core != core)) continue;
    if (a < b->addr + b->len && b->addr < a + n) {
      char w[128];
      snprintf(w, sizeof w, "core %d %s %s [0x%llx, 0x%llx)", core, how, acc == 2 ? "wrote" : "read", (unsigned long long)a,
               (unsigned long long)(a + n));
      bp_fire(b, core, w);
    }
  }
}
static void tag_touch(int core, int tag, int what, const char *how) {
  if (search.on && search.kind == SK_TAG && search.core == core && search.tag == tag && what == 1) search.last = (int64_t)dbg_tick;
  for (int i = 0; i < dbg_nbp; i++) {
    Bp *b = &dbg_bp[i];
    if (!b->on || b->kind != WK_TAG || b->arg != tag || !(b->access & what) || (b->core >= 0 && b->core != core)) continue;
    char w[96];
    snprintf(w, sizeof w, "core %d tg%d %s", core, tag, how);
    bp_fire(b, core, w);
  }
}

/* Pending device reads that completed (in pend_service or in another core's
 * step) since the last look: tags idle again, their bytes written. */
static void pend_diff(void) {
  if (npending == dbg_pnpend && pend_seq == dbg_pseq) return;
  for (int i = 0; i < ncores; i++)
    for (int k = 0; k < NPEND; k++) {
      Pending *was = &dbg_pshadow[i][k], *now = &cores[i].pend[k];
      if (was->on && (!now->on || now->seq != was->seq)) {
        TagRec *t = &dbg_tags[i][was->tag];
        t->busy = false;
        t->done_round = rounds;
        t->done_tick = dbg_tick;
        Ev e = {0};
        e.kind = EV_XDONE;
        e.core = (int8_t)i;
        e.tag = (uint8_t)was->tag;
        e.a = was->ls;
        e.b = was->len;
        e.c = t->issue_round;
        e.d = was->port;
        ev_add(&e);
        tag_touch(i, was->tag, 2, "completed");
        ls_touch(i, 0, was->ls, was->len, 2, "device read");
      }
      *was = *now;
    }
  dbg_pnpend = npending;
  dbg_pseq = pend_seq;
}

static void prov_after(Core *c, const Pre *p);

/* After core c's slot: what its instruction did. */
static void post_step(Core *c, const Pre *p, bool ok) {
  bool exec = ok && !dbg_trapped && !p->halted; /* the instruction itself took effect */
  if (ok) dbg_bphold[c->id] = ~0ull;
  if (search.on && search.kind == SK_STEP && search.core == c->id && ok) search.last = (int64_t)dbg_tick;
  /* stalls: one event per stall, when it ends */
  Stall *st = &dbg_stall[c->id];
  if (!ok && !c->halted && !st->on) {
    st->on = true;
    st->from_round = rounds;
    st->from_tick = dbg_tick;
    st->reason = stall_reason(c, &st->detail);
  } else if ((ok || c->halted) && st->on) {
    Ev e = {0};
    e.kind = EV_STALL;
    e.core = (int8_t)c->id;
    e.a = st->from_round;
    e.b = rounds;
    e.c = (uint64_t)st->reason;
    e.d = st->detail;
    e.pc = c->pc;
    ev_add(&e);
    st->on = false;
  }
  if (exec) {
    switch (p->kind) {
    case DK_LOAD: ls_touch(c->id, 0, p->addr, p->len, 1, "load"); break;
    case DK_STORE: ls_touch(c->id, 0, p->addr, p->len, 2, "store"); break;
    case DK_LTAG: ls_touch(c->id, 0, p->addr, p->len, 1, "ltag"); break;
    case DK_LINST: ls_touch(c->id, 0, p->addr, p->len, 3, "linst"); break;
    case DK_XFER: {
      bool pending = false;
      for (int k = 0; k < NPEND; k++)
        if (c->pend[k].on && c->pend[k].tag == (int)p->tag && c->pend[k].seq + 1 == pend_seq) pending = true;
      TagRec *t = &dbg_tags[c->id][p->tag];
      *t = (TagRec){true, pending, (uint8_t)p->sub, p->cap.space, p->addr, p->len, p->far, p->pc, rounds, dbg_tick,
                    pending ? 0 : rounds, pending ? 0 : dbg_tick};
      Ev e = {0};
      e.kind = EV_XFER;
      e.core = (int8_t)c->id;
      e.tag = (uint8_t)p->tag;
      e.sub = (uint8_t)p->sub;
      e.space = p->cap.space;
      e.flag = pending;
      e.id = p->cap.id;
      e.a = p->addr;
      e.b = p->len;
      e.c = p->far;
      e.pc = p->pc;
      e.pid = (uint32_t)os_cur_pid(c->id);
      ev_add(&e);
      tag_touch(c->id, (int)p->tag, pending ? 1 : 3, pending ? "issued (pending)" : "issued and completed");
      if (p->sub == XF_GETX) ls_touch(c->id, 1, p->addr, p->len, 2, "tgetx");
      else if (p->sub == XF_PUT) ls_touch(c->id, 0, p->addr, p->len, 1, "tput");
      else if (!pending) ls_touch(c->id, 0, p->addr, p->len, 2, "tget");
      /* far watchpoints: reads by tget / tgetx, device ports by either */
      for (int i = 0; i < dbg_nbp; i++) {
        Bp *b = &dbg_bp[i];
        if (!b->on || b->kind != WK_FAR || b->mem != p->cap.space) continue;
        bool dev = p->cap.space == SP_DEV;
        uint64_t lo = p->far, n = dev ? 1 : p->len;
        bool rd = p->sub != XF_PUT, wr = p->sub == XF_PUT;
        if (!((rd && (b->access & 1)) || (dev && wr && (b->access & 2)))) continue;
        if (lo < b->addr + b->len && b->addr < lo + n) {
          char w[128];
          snprintf(w, sizeof w, "core %d %s %s 0x%llx", c->id, p->sub == XF_PUT ? "tput" : p->sub == XF_GET ? "tget" : "tgetx",
                   dev ? "port" : "at", (unsigned long long)lo);
          bp_fire(b, c->id, w);
        }
      }
      break;
    }
    case DK_TAMO:
      for (int i = 0; i < dbg_nbp; i++) {
        Bp *b = &dbg_bp[i];
        if (b->on && b->kind == WK_FAR && b->mem == p->cap.space && (b->access & 1) && p->far < b->addr + b->len && b->addr < p->far + 8) {
          char w[96];
          snprintf(w, sizeof w, "core %d tamo at 0x%llx", c->id, (unsigned long long)p->far);
          bp_fire(b, c->id, w);
        }
      }
      break;
    case DK_SYS:
      if (p->fn == SYS_ERET) {
        Ev e = {0};
        e.kind = EV_ERET;
        e.core = (int8_t)c->id;
        e.a = p->pc;
        e.b = c->pc;
        e.flag = c->user;
        e.pid = (uint32_t)os_cur_pid(c->id);
        ev_add(&e);
      }
      break;
    case DK_CAP: case DK_CAP2: prov_after(c, p); break;
    }
  }
  if (dbg_farw.on) {
    for (int i = 0; i < dbg_nbp; i++) {
      Bp *b = &dbg_bp[i];
      if (b->on && b->kind == WK_FAR && b->mem == dbg_farw.space && (b->access & 2) && dbg_farw.addr < b->addr + b->len &&
          b->addr < dbg_farw.addr + 8) {
        char w[96];
        snprintf(w, sizeof w, "write at 0x%llx (in core %d's slot)", (unsigned long long)dbg_farw.addr, c->id);
        bp_fire(b, c->id, w);
      }
    }
    dbg_farw.on = false;
  }
  if (ok && dbg_trapped)
    for (int i = 0; i < dbg_nbp; i++) {
      Bp *b = &dbg_bp[i];
      if (b->on && b->kind == BK_TRAP && (b->core < 0 || b->core == c->id) && (b->arg < 0 || b->arg == dbg_trap_cause))
        bp_fire(b, c->id, stx_cause_name(dbg_trap_cause));
    }
  if (!p->halted && c->halted) {
    Ev e = {0};
    e.kind = EV_HALT;
    e.core = (int8_t)c->id;
    e.a = c->x[10];
    e.b = c->instret;
    e.flag = faulted;
    e.pc = c->pc;
    ev_add(&e);
    for (int i = 0; i < dbg_nbp; i++)
      if (dbg_bp[i].on && dbg_bp[i].kind == BK_HALT && (dbg_bp[i].core < 0 || dbg_bp[i].core == c->id)) bp_fire(&dbg_bp[i], c->id, NULL);
  }
  for (int i = 0; i < dbg_nbp; i++) {
    Bp *b = &dbg_bp[i];
    if (!b->on || b->kind != WK_CAP || b->core != c->id) continue;
    const Cap *o = &p->caps[b->arg & 15], *n = &c->caps[b->arg & 15];
    if (o->valid != n->valid || o->space != n->space || o->perms != n->perms || o->base != n->base || o->len != n->len ||
        o->rv != n->rv || o->gen != n->gen) {
      char w[64];
      snprintf(w, sizeof w, "c%d changed", b->arg & 15);
      bp_fire(b, c->id, w);
    }
  }
  if (npending != dbg_pnpend || pend_seq != dbg_pseq) pend_diff();
  if (os_aware) dbg_pid_prev[c->id] = c->user ? os_cur_pid(c->id) : -1;
  /* the goal of a stepping command */
  if (!search.on && goal.kind == G_STEPI && ok) {
    bool mine = goal.pid ? (c->user && os_cur_pid(c->id) == goal.pid) : c->id == goal.core;
    if (mine && --goal.left == 0) stop_req(c->id, 0, "step");
  }
}

static void ev_gift(int kind, Core *c, const Cap *k, uint64_t node) {
  Ev e = {0};
  e.kind = (uint16_t)kind;
  e.core = (int8_t)c->id;
  e.space = k->space;
  e.perms = k->perms;
  e.id = k->id;
  e.a = node;
  e.b = k->base;
  e.c = k->len;
  e.pc = c->pc;
  e.pid = (uint32_t)os_cur_pid(c->id);
  /* a 4 KiB buffer in T3 given by a process is a StrataOS message: its op word */
  if (os_aware && k->space == SP_T3 && k->len == 4096 && k->base + 8 <= T3_BYTES) { e.flag = 1; e.d = t3_word(k->base); }
  ev_add(&e);
}

/* Provenance and events of a capability instruction that took effect. */
static void prov_after(Core *c, const Pre *p) {
  unsigned cd = p->cd, cs = p->cs;
  if (p->kind == DK_CAP) {
    switch (p->fn) {
    case CF_RESTR: prov_new(c, &c->caps[cd], PO_RESTRICT, p->pcs.id, 0, -1); break;
    case CF_SPLIT:
      prov_new(c, &c->caps[cd], PO_SPLIT, p->pcs.id, 0, -1);
      prov_new(c, &c->caps[cs], PO_SPLIT, p->pcs.id, 0, -1);
      break;
    case CF_JOIN: prov_new(c, &c->caps[cd], PO_JOIN, p->pcd.id, p->pcs.id, -1); break;
    case CF_SHARE: prov_new(c, &c->caps[cd], PO_SHARE, p->pcs.id, 0, -1); break;
    case CF_ATOM: prov_new(c, &c->caps[cd], PO_ATOMIC, p->pcs.id, 0, -1); break;
    case CF_GIVE: ev_gift(EV_GIVE, c, &p->pcs, p->b + c->corebase); break;
    case CF_TAKE: {
      uint32_t got = c->caps[cd].id;
      prov_new(c, &c->caps[cd], PO_GIVE, got, 0, (int)(c->takefrom + c->corebase));
      ev_gift(EV_TAKE, c, &c->caps[cd], c->takefrom + c->corebase);
      break;
    }
    }
  } else {
    switch (p->fn) {
    case C2_DOM:
      prov_new(c, &c->caps[cd], PO_DOM, p->pcs.id, 0, -1);
      prov_new(c, &c->caps[cs], PO_REVOKER, p->pcs.id, 0, -1);
      { Ev e = {0}; e.kind = EV_DOM; e.core = (int8_t)c->id; e.a = p->pcs.base; e.b = p->pcs.len; e.c = c->caps[cd].gen; e.space = p->pcs.space; e.pc = c->pc; ev_add(&e); }
      break;
    case C2_REVOKE: case C2_UNDOM:
      prov_new(c, &c->caps[cd], p->fn == C2_REVOKE ? PO_REVOKE : PO_UNDOM, p->pcs.id, 0, -1);
      { Ev e = {0}; e.kind = p->fn == C2_REVOKE ? EV_REVOKE : EV_UNDOM; e.core = (int8_t)c->id; e.a = p->pcs.base; e.b = p->pcs.len; e.c = c->caps[cd].gen; e.space = p->pcs.space; e.pc = c->pc; e.pid = (uint32_t)os_cur_pid(c->id); ev_add(&e); }
      break;
    case C2_MKEP: prov_new(c, &c->caps[cd], PO_MINT, 0, 0, -1); break;
    case C2_SEND: ev_gift(EV_SEND, c, &p->pcs, p->pcd.base); break;
    case C2_RECV: {
      uint32_t got = c->caps[cd].id;
      prov_new(c, &c->caps[cd], PO_GIVE, got, 0, (int)p->pcs.base);
      ev_gift(EV_RECV, c, &c->caps[cd], p->pcs.base);
      break;
    }
    }
  }
  /* anything else that made a capability without an id */
  for (int i = 0; i < NCAPS; i++)
    if (c->caps[i].valid && !c->caps[i].id) prov_new(c, &c->caps[i], PO_OTHER, 0, 0, -1);
}

static void tt_at_round(void);          /* debug_tt.c: snapshots, the input log */
static bool tt_log_at(uint64_t tick);   /* an entry of the input log at this tick */
static void tt_apply(uint64_t tick);    /* applies the input log's entries for this tick */

enum { TK_OK, TK_STOP, TK_IDLE, TK_DONE };
static double dbg_idle_ms;

static void done(const char *why) {
  dbg_state = ST_DONE;
  dbg_done_why = why;
}

/* After the last core's slot of a round: the end-of-round checks of main's
 * loop (halted, deadlock, idle, -m). */
static int end_of_round(void) {
  if (!dbg_rr_live) { done("halted"); return TK_DONE; }
  if (goal.kind == G_ROUNDS && !search.on && --goal.left == 0) stop_req(-1, 0, "round");
  if (!dbg_rr_progress) {
    int r = round_idle();
    if (r == RND_DEADLOCK) { done("deadlock"); return TK_DONE; }
    if (host_ptr_script_stepped()) host_ptr_script_do();
    else if (virtual_time) {
      bool live = dbg_tick >= dbg_frontier && !search.on;
      if (tt_log_at(dbg_tick)) { /* (replay) input comes at the next slot: no skip */ }
      else if (idle.timed && (!idle.input || !live)) rounds = idle.next * 100; /* nothing else can happen first */
      else {
        /* live, and only input (or input or a deadline) can wake the machine:
         * wait for it in real time; a deadline that comes first is then
         * skipped to, as if no input had come (dbg_run) */
        uint64_t now = now_ticks();
        dbg_idle_skip = idle.timed;
        dbg_idle_pending = true;
        dbg_idle_ms = !idle.timed ? 200 : idle.next <= now ? 0 : (double)(idle.next - now) / 1000.0;
        if (dbg_idle_ms > 50) dbg_idle_ms = 50;
        return TK_IDLE;
      }
    } else {
      uint64_t now = now_ticks();
      dbg_idle_ms = !idle.timed ? 1 : idle.next <= now ? 0 : (double)(idle.next - now) / 1000.0;
      if (dbg_idle_ms > 1) dbg_idle_ms = 1;
      return TK_IDLE;
    }
  }
  if (opt_max_steps && mach_steps >= opt_max_steps) { done("timeout"); return TK_DONE; }
  return TK_OK;
}

/* One core slot. */
static int dbg_tick1(void) {
  if (dbg_ci == 0 && !dbg_rs) {
    /* the round's start: a snapshot, the input log, then what main's loop does */
    if (dbg_tt_due) { dbg_tt_due = false; tt_restart(); }
    if (dbg_tt) { tt_at_round(); tt_apply(dbg_tick); }
    rounds++;
    if (opt_break_at && mach_steps >= opt_break_at) { opt_break_at = 0; press_break(); }
    host_ptr_script_run(mach_steps);
    if (rounds >= dbg_poll_at) { dbg_poll_at = rounds + 4096; host_poll(); net_host_poll(); }
    pend_service();
    pend_diff();
    dbg_rs = true;
    dbg_rr_live = dbg_rr_progress = false;
    if (stop.hit) return TK_STOP;
  }
  if (dbg_tt) tt_apply(dbg_tick);
  /* (a stop at a tick is in front of its slot, after the round's start) */
  if (goal.kind == G_TICK && dbg_tick == goal.target) { stop_req(-1, 0, "tick"); return TK_STOP; }
  Core *c = &cores[dbg_ci];
  if (!c->halted) {
    dbg_rr_live = true;
    Pre p;
    pre_decode(c, &p);
    if (dbg_skip_tick != (int64_t)dbg_tick) {
      if (!search.on && goal.kind == G_UNTILPC && (goal.core < 0 || goal.core == c->id) && c->pc == goal.target)
        stop_req(c->id, 0, "until");
      pre_hits(c, &p);
      if (stop.hit) { dbg_skip_tick = (int64_t)dbg_tick; return TK_STOP; }
    }
    dbg_trapped = false;
    bool ok = step(c);
    if (ok) { dbg_rr_progress = true; c->traced = false; mach_steps++; slow_events++; }
    else blocked_at[dbg_ci] = slow_events;
    post_step(c, &p, ok);
  }
  dbg_skip_tick = -1;
  dbg_ci++;
  dbg_tick++;
  if (dbg_tick > dbg_frontier) dbg_frontier = dbg_tick;
  if (dbg_muted && dbg_tick >= dbg_frontier) dbg_muted = false;
  if (dbg_ci == ncores) {
    dbg_ci = 0;
    dbg_rs = false;
    int r = end_of_round();
    if (r != TK_OK) return r;
  }
  return stop.hit ? TK_STOP : TK_OK;
}

/* One machine round at full speed (machine_round(): the JIT, the fast loop),
 * for a plain continue on a run that is not recorded. As main's loop. */
static int dbg_fast_round(void) {
  rounds++;
  if (opt_break_at && mach_steps >= opt_break_at) { opt_break_at = 0; press_break(); }
  host_ptr_script_run(mach_steps);
  host_poll();
  net_host_poll();
  int r = machine_round();
  dbg_tick += (uint64_t)ncores;
  if (dbg_tick > dbg_frontier) dbg_frontier = dbg_tick;
  pend_diff();
  if (r == RND_HALTED) { done("halted"); return TK_DONE; }
  if (r == RND_DEADLOCK) { done("deadlock"); return TK_DONE; }
  if (opt_max_steps && mach_steps >= opt_max_steps) { done("timeout"); return TK_DONE; }
  if (r == RND_IDLE) {
    if (host_ptr_script_stepped()) { host_ptr_script_do(); return TK_OK; }
    uint64_t now = now_ticks();
    /* virtual time: on to the next deadline at once. A fast continue is
     * catching up, so it does not wait for input that might come first (as
     * the exact loop does, which keeps a live machine near real time); input
     * that comes meanwhile is taken at the next slice. */
    if (virtual_time && idle.timed && (!idle.input || dbg_ff)) { rounds = idle.next * 100; return TK_OK; }
    dbg_idle_ms = !idle.timed ? 1 : idle.next <= now ? 0 : (double)(idle.next - now) / 1000.0;
    if (dbg_idle_ms > 1) dbg_idle_ms = 1;
    if (virtual_time) rounds += (uint64_t)(dbg_idle_ms * 100000);
    return TK_IDLE;
  }
  return TK_OK;
}

static double dbg_now_ms(void) { return (double)host_us() / 1000.0; }

static void ev_stopped(void);

/* A fast continue has stopped: recording starts again from here (now, at a
 * round's start; else at the next one). */
static void ff_end(void) {
  if (!dbg_ff) return;
  dbg_ff = false;
  if (!dbg_ttok) return;
  if (dbg_ci == 0 && !dbg_rs) tt_restart();
  else dbg_tt_due = true;
}

/* Runs the machine while it is running, for up to `ms` milliseconds.
 * Returns -1 when it is not running (any more), 0 when the time is up,
 * or the milliseconds to wait (idle: every core waits for input or time). */
static double dbg_run(double ms) {
  if (dbg_state != ST_RUNNING) return -1;
  if (dbg_idle_pending) { /* a wait has ended: skip to the deadline unless input came */
    dbg_idle_pending = false;
    if (dbg_idle_skip && idle.timed) rounds = idle.next * 100;
  }
  double end = dbg_now_ms() + ms;
  for (unsigned k = 0;; k++) {
    if (dbg_pause_req) {
      dbg_pause_req = false;
      stop_req(-1, 0, "paused");
    }
    int r;
    if (stop.hit) r = TK_STOP;
    else if ((dbg_fastok || dbg_ff) && !dbg_tt && goal.kind == G_CONT && !dbg_nlive_bp && dbg_ci == 0 && !dbg_rs) r = dbg_fast_round();
    else r = dbg_tick1();
    if (r == TK_STOP) { dbg_state = ST_STOPPED; ff_end(); ev_stopped(); return -1; }
    if (r == TK_DONE) { ff_end(); ev_stopped(); return -1; }
    if (r == TK_IDLE) { con_flush(); return dbg_idle_ms > 0 ? dbg_idle_ms : 0.001; }
    if ((k & 1023) == 1023) {
      con_flush();
      if (dbg_now_ms() >= end) return 0;
    }
  }
}

#include "debug_tt.c"

/* ------------------------------------------------------------ JSON views */

static const char *space_name(int s) {
  switch (s) {
  case SP_NONE: return "none";
  case SP_T2: return "t2";
  case SP_T3: return "t3";
  case SP_DEV: return "dev";
  case SP_CORE: return "core";
  case SP_EP: return "ep";
  }
  return "?";
}
static void perms_str(int p, char *s) {
  const char *l = "rwxadv";
  int n = 0;
  for (int i = 0; i < 6; i++)
    if (p >> i & 1) s[n++] = l[i];
  s[n] = 0;
  if (!n) strcpy(s, "-");
}
/* a device port's name */
static const char *port_name(uint64_t port) {
  switch (port) {
  case DEV_CONSOLE: return "console out";
  case DEV_CONSOLE + CON_IN: return "console in";
  case DEV_CONSOLE + CON_BREAK: return "console break";
  case DEV_CONSOLE + CON_RELEASE: return "console release";
  case DEV_TIMER + TMR_NOW: return "timer NOW";
  case DEV_TIMER + TMR_FREQ: return "timer FREQ";
  case DEV_TIMER + TMR_DEADLINE: return "timer DEADLINE";
  case DEV_TIMER + TMR_WAIT: return "timer WAIT";
  case DEV_FBCTL + FBC_PRESENT: return "fb PRESENT";
  case DEV_FBCTL + FBC_VSYNC: return "fb VSYNC";
  case DEV_POINTER + PTR_EVENT: return "pointer EVENT";
  case DEV_POINTER + PTR_STATE: return "pointer STATE";
  case DEV_NET + NET_TX: return "net TX";
  case DEV_NET + NET_RX: return "net RX";
  case DEV_NET + NET_STATUS: return "net STATUS";
  case DEV_BLK0 + BLK_SQ: return "blk SQ";
  case DEV_BLK0 + BLK_CQ: return "blk CQ";
  }
  if (port >= DEV_PLAT && port < DEV_PLAT + PLAT_LEN) return "platform table";
  if (port >= DEV_BLK0 && port < DEV_BLK0 + BLK_IDENT_LEN) return "blk IDENT";
  return "";
}

static void jw_cap(JW *w, const char *key, const Cap *k) {
  jw_obj(w, key);
  bool lv = live(*k);
  jw_bool(w, "valid", k->valid);
  jw_bool(w, "live", lv);
  if (k->valid) {
    char ps[8];
    perms_str(k->perms, ps);
    jw_str(w, "space", space_name(k->space));
    jw_hex(w, "base", k->base);
    jw_hex(w, "len", k->len);
    jw_str(w, "perms", ps);
    jw_bool(w, "rv", k->rv);
    jw_int(w, "gen", k->gen);
    if (k->rv) {
      int g = gidx(k->space, k->base);
      jw_int(w, "gnow", g >= 0 ? ggen[g] : -1);
    }
    if (k->id) jw_uint(w, "id", k->id);
    if (k->space == SP_DEV && k->len <= 1) jw_str(w, "port", port_name(k->base));
  }
  jw_oend(w);
}

static void jw_where(JW *w, const Core *c, uint64_t pc) {
  char s[160];
  sym_code(c, pc, s, sizeof s);
  if (s[0]) jw_str(w, "sym", s);
  const char *f;
  int ln;
  if (line_code(c, pc, &f, &ln, NULL)) { jw_str(w, "file", f); jw_int(w, "line", ln); }
}

static void jw_stall(JW *w, const Core *c) {
  const Stall *st = &dbg_stall[c->id];
  if (!st->on || c->halted) return;
  jw_obj(w, "stall");
  jw_str(w, "reason", sr_names[st->reason]);
  jw_uint(w, "since", st->from_round);
  jw_uint(w, "since_tick", st->from_tick);
  jw_hex(w, "detail", st->detail);
  char why[200] = "";
  switch (st->reason) {
  case SR_LSPEND: snprintf(why, sizeof why, "its access overlaps a pending device read (tags 0x%llx)", (unsigned long long)st->detail); break;
  case SR_XPEND: snprintf(why, sizeof why, "the transfer's D-LS range overlaps the pending read on tg%llu", (unsigned long long)st->detail); break;
  case SR_TAG: snprintf(why, sizeof why, "tg%llu is still in flight", (unsigned long long)st->detail); break;
  case SR_PENDFULL: snprintf(why, sizeof why, "four device reads are already pending"); break;
  case SR_TWAIT: snprintf(why, sizeof why, "twait for busy tags 0x%llx", (unsigned long long)st->detail); break;
  case SR_TANY: snprintf(why, sizeof why, "tany: nothing of 0x%llx is ready", (unsigned long long)st->detail); break;
  case SR_TAKE: case SR_RECV:
    if (st->detail == 0xff) snprintf(why, sizeof why, "ctake: the inbox is empty");
    else snprintf(why, sizeof why, "waits for a capability from node %llu", (unsigned long long)st->detail);
    break;
  case SR_GIVE: snprintf(why, sizeof why, "node %llu's inbox is full", (unsigned long long)st->detail); break;
  case SR_HALT: snprintf(why, sizeof why, "halt drains the pending reads (tags 0x%llx)", (unsigned long long)st->detail); break;
  default: snprintf(why, sizeof why, "blocked"); break;
  }
  jw_str(w, "why", why);
  jw_oend(w);
}

static void jw_core_brief(JW *w, const Core *c) {
  jw_obj(w, NULL);
  jw_int(w, "core", c->id);
  jw_hex(w, "pc", c->pc);
  jw_where(w, c, c->pc);
  jw_bool(w, "halted", c->halted);
  jw_str(w, "mode", c->user ? "user" : "super");
  jw_uint(w, "instret", c->instret);
  int busy = (int)tag_busy(c);
  jw_int(w, "busy", busy);
  if (os_aware) {
    int pid = os_cur_pid(c->id);
    jw_int(w, "pid", pid);
    const char *nm = os_name_of(pid);
    if (nm) jw_str(w, "proc", nm);
  }
  if (!c->halted && (c->pc & 3) == 0 && c->pc < ILS_BYTES) {
    uint32_t ir;
    memcpy(&ir, c->ils + c->pc, 4);
    char d[160];
    disasm(c, ir, c->pc, d, sizeof d);
    jw_str(w, "insn", d);
  }
  jw_stall(w, c);
  jw_oend(w);
}

static void jw_position(JW *w) {
  jw_uint(w, "tick", dbg_tick);
  jw_uint(w, "round", rounds);
  jw_int(w, "next", dbg_ci);
  jw_uint(w, "steps", mach_steps);
  jw_uint(w, "frontier", dbg_frontier);
}

static void ev_stopped(void) {
  con_flush();
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  if (dbg_state == ST_DONE) {
    jw_str(&w, "ev", "done");
    jw_str(&w, "why", dbg_done_why);
    jw_bool(&w, "faulted", faulted);
  } else {
    jw_str(&w, "ev", "stopped");
    jw_str(&w, "reason", stop.why);
    jw_int(&w, "core", stop.core);
    if (stop.bp) jw_int(&w, "bp", stop.bp);
  }
  jw_position(&w);
  jw_arr(&w, "cores");
  for (int i = 0; i < ncores; i++) jw_core_brief(&w, &cores[i]);
  jw_aend(&w);
  jw_oend(&w);
  out_line(&w);
  free(w.p);
}

/* ------------------------------------------------------------ requests */

static int req_core(const JVal *rq, char *err, size_t ne) {
  int c = json_int(json_get(rq, "core"), 0);
  if (c < 0 || c >= ncores) { snprintf(err, ne, "no core %d", c); return -1; }
  return c;
}

static int reg_index(const char *s) {
  if (!s) return -1;
  if (!strcmp(s, "pc")) return 32;
  if (!strcmp(s, "instret")) return 33;
  if (!strcmp(s, "fp")) return 8;
  if (s[0] == 'x' && s[1]) {
    char *e;
    long n = strtol(s + 1, &e, 10);
    if (!*e && n >= 0 && n < 32) return (int)n;
  }
  for (int i = 0; i < 32; i++)
    if (!strcmp(s, xr_names[i])) return i;
  return -1;
}

/* "reg OP value", e.g. "a0 == 5" */
static bool parse_cond(const char *s, Bp *b) {
  char r[16], op[4], v[64];
  if (sscanf(s, " %15[a-z0-9] %3[=!<>] %63s", r, op, v) != 3) return false;
  b->creg = reg_index(r);
  if (b->creg < 0) return false;
  static const char *const ops[] = {"==", "!=", "<", ">", "<=", ">="};
  b->cop = -1;
  for (int i = 0; i < 6; i++)
    if (!strcmp(op, ops[i])) b->cop = i;
  if (b->cop < 0) return false;
  b->cval = (uint64_t)strtoll(v, NULL, 0);
  if (v[0] != '-') b->cval = strtoull(v, NULL, 0);
  b->cond = true;
  return true;
}

static Bp *bp_alloc(int kind) {
  if (dbg_nbp == DBG_NBP) return NULL;
  Bp *b = &dbg_bp[dbg_nbp++];
  memset(b, 0, sizeof *b);
  b->id = dbg_bp_next++;
  b->kind = kind;
  b->on = true;
  b->core = -1;
  return b;
}

static int space_code(const char *s) {
  if (!s) return -1;
  if (!strcmp(s, "t2")) return SP_T2;
  if (!strcmp(s, "t3")) return SP_T3;
  if (!strcmp(s, "dev")) return SP_DEV;
  return -1;
}

static void jw_bp(JW *w, const Bp *b) {
  jw_obj(w, NULL);
  jw_int(w, "id", b->id);
  jw_str(w, "kind", bk_names[b->kind]);
  jw_bool(w, "on", b->on);
  jw_bool(w, "temp", b->temp);
  jw_int(w, "core", b->core);
  if (b->kind == BK_PC || b->kind == WK_LS || b->kind == WK_FAR) jw_hex(w, "addr", b->addr);
  if (b->kind == WK_LS || b->kind == WK_FAR) jw_hex(w, "len", b->len);
  jw_uint(w, "hits", b->hits);
  jw_uint(w, "ignore", b->ignore);
  jw_str(w, "desc", b->desc);
  jw_oend(w);
}


static void run_start(int kind) {
  goal.kind = kind;
  if (kind != G_TICK) goal.nobreak = false;
  stop.hit = false;
  stop.why[0] = 0;
  dbg_pause_req = false;
  if (dbg_state == ST_STOPPED) dbg_state = ST_RUNNING;
}

/* the hex string of n bytes */
static void jw_hexbytes(JW *w, const char *key, const uint8_t *p, size_t n) {
  jw_key(w, key);
  jw_raw(w, "\"", 1);
  static const char hx[] = "0123456789abcdef";
  char buf[512];
  size_t k = 0;
  for (size_t i = 0; i < n; i++) {
    buf[k++] = hx[p[i] >> 4];
    buf[k++] = hx[p[i] & 15];
    if (k == sizeof buf) { jw_raw(w, buf, k); k = 0; }
  }
  jw_raw(w, buf, k);
  jw_raw(w, "\"", 1);
}

/* a memory range a request names: space dls/ils (of `core`), t2, t3, disk */
static uint8_t *mem_range(const char *sp, int core, uint64_t addr, uint64_t len, char *err, size_t ne) {
  uint8_t *base = NULL;
  uint64_t size = 0;
  if (!strcmp(sp, "dls")) { base = cores[core].dls; size = DLS_BYTES; }
  else if (!strcmp(sp, "ils")) { base = cores[core].ils; size = ILS_BYTES; }
  else if (!strcmp(sp, "t2")) { base = t2; size = T2_BYTES; }
  else if (!strcmp(sp, "t3")) { base = t3; size = T3_BYTES; }
  else if (!strcmp(sp, "disk")) { base = disk; size = disk_blocks * BLK_BLOCK; }
  else { snprintf(err, ne, "unknown space %s (dls, ils, t2, t3, disk)", sp); return NULL; }
  if (addr > size || len > size - addr) { snprintf(err, ne, "outside %s", sp); return NULL; }
  return base + addr;
}

static void tags_json(JW *w, int i) {
  Core *c = &cores[i];
  uint64_t busy = tag_busy(c);
  jw_arr(w, "tags");
  for (int t = 0; t < 16; t++) {
    TagRec *r = &dbg_tags[i][t];
    jw_obj(w, NULL);
    jw_int(w, "tag", t);
    jw_bool(w, "busy", busy >> t & 1);
    if (r->valid) {
      static const char *const k[] = {"tget", "tput", "tgetx"};
      jw_str(w, "op", r->sub < 3 ? k[r->sub] : "?");
      jw_str(w, "space", space_name(r->space));
      jw_hex(w, "ls", r->ls);
      jw_hex(w, "len", r->len);
      jw_hex(w, "far", r->far);
      if (r->space == SP_DEV) jw_str(w, "port", port_name(r->far));
      jw_hex(w, "pc", r->pc);
      jw_uint(w, "issued", r->issue_round);
      jw_uint(w, "issued_tick", r->issue_tick);
      if (!(busy >> t & 1)) { jw_uint(w, "completed", r->done_round); jw_uint(w, "completed_tick", r->done_tick); }
    }
    jw_oend(w);
  }
  jw_aend(w);
}

static const char *pend_waits(const Pending *p, char *buf, size_t n) {
  uint64_t now = now_ticks();
  switch (p->port) {
  case DEV_CONSOLE + CON_IN: snprintf(buf, n, "%llu console byte(s); %d queued", (unsigned long long)p->len, host_in_cnt); break;
  case DEV_CONSOLE + CON_BREAK: snprintf(buf, n, "Ctrl-C"); break;
  case DEV_TIMER + TMR_WAIT:
    if (tmr_deadline > now) snprintf(buf, n, "the timer deadline %llu (now %llu, in %llu ticks)", (unsigned long long)tmr_deadline,
                                     (unsigned long long)now, (unsigned long long)(tmr_deadline - now));
    else snprintf(buf, n, "the timer deadline %llu (passed: completes at the next round)", (unsigned long long)tmr_deadline);
    break;
  case DEV_FBCTL + FBC_VSYNC: snprintf(buf, n, "the refresh at tick %llu (now %llu)", (unsigned long long)p->target, (unsigned long long)now); break;
  case DEV_POINTER + PTR_EVENT: snprintf(buf, n, "a pointer event"); break;
  case DEV_NET + NET_RX: snprintf(buf, n, "a network packet"); break;
  default: snprintf(buf, n, "?"); break;
  }
  return buf;
}

/* the provenance chain of capability `id`, oldest last */
static void prov_chain(JW *w, uint32_t id) {
  jw_arr(w, "chain");
  for (int guard = 0; id && guard < 256; guard++) {
    const Prov *p = prov_get(id);
    if (!p) break;
    jw_obj(w, NULL);
    jw_uint(w, "id", p->id);
    jw_str(w, "op", p->op < sizeof po_names / sizeof *po_names ? po_names[p->op] : "?");
    jw_uint(w, "parent", p->parent);
    if (p->parent2) jw_uint(w, "parent2", p->parent2);
    jw_int(w, "core", p->core == 255 ? -1 : p->core);
    if (p->from >= 0 && p->op == PO_GIVE) jw_int(w, "from", p->from);
    char ps[8];
    perms_str(p->perms, ps);
    jw_str(w, "space", space_name(p->space));
    jw_hex(w, "base", p->base);
    jw_hex(w, "len", p->len);
    jw_str(w, "perms", ps);
    jw_uint(w, "round", p->round);
    jw_uint(w, "tick", p->tick);
    if (p->core != 255) {
      jw_hex(w, "pc", p->pc);
      if (p->core < ncores) jw_where(w, &cores[p->core], p->pc);
    }
    jw_oend(w);
    id = p->parent;
  }
  jw_aend(w);
}

static void ev_json(JW *w, uint64_t seq, const Ev *e) {
  jw_obj(w, NULL);
  jw_uint(w, "seq", seq);
  jw_str(w, "kind", ev_names[e->kind]);
  jw_uint(w, "tick", e->tick);
  jw_uint(w, "round", e->round);
  jw_int(w, "core", e->core);
  if (e->pid) jw_uint(w, "pid", e->pid);
  switch (e->kind) {
  case EV_XFER: {
    static const char *const k[] = {"tget", "tput", "tgetx"};
    jw_int(w, "tag", e->tag);
    jw_str(w, "op", e->sub < 3 ? k[e->sub] : "?");
    jw_str(w, "space", space_name(e->space));
    jw_hex(w, "ls", e->a);
    jw_hex(w, "len", e->b);
    jw_hex(w, "far", e->c);
    if (e->space == SP_DEV) jw_str(w, "port", port_name(e->c));
    jw_bool(w, "pending", e->flag);
    jw_hex(w, "pc", e->pc);
    if (e->id) jw_uint(w, "cap", e->id);
    break;
  }
  case EV_XDONE:
    jw_int(w, "tag", e->tag);
    jw_hex(w, "ls", e->a);
    jw_hex(w, "len", e->b);
    jw_uint(w, "issued", e->c);
    jw_str(w, "port", port_name(e->d));
    break;
  case EV_TRAP:
    jw_str(w, "cause", stx_cause_name((int)e->a));
    jw_hex(w, "tval", e->b);
    jw_hex(w, "pc", e->pc);
    jw_bool(w, "user", e->flag);
    break;
  case EV_ERET: jw_hex(w, "from", e->a); jw_hex(w, "to", e->b); jw_bool(w, "user", e->flag); break;
  case EV_GIVE: case EV_TAKE: case EV_SEND: case EV_RECV: {
    char ps[8];
    perms_str(e->perms, ps);
    jw_int(w, e->kind == EV_GIVE || e->kind == EV_SEND ? "to" : "from", (int)e->a);
    jw_str(w, "space", space_name(e->space));
    jw_hex(w, "base", e->b);
    jw_hex(w, "len", e->c);
    jw_str(w, "perms", ps);
    if (e->id) jw_uint(w, "cap", e->id);
    if (e->flag) jw_uint(w, "msgop", e->d);
    jw_hex(w, "pc", e->pc);
    break;
  }
  case EV_DOM: case EV_REVOKE: case EV_UNDOM:
    jw_str(w, "space", space_name(e->space));
    jw_hex(w, "base", e->a);
    jw_hex(w, "len", e->b);
    jw_uint(w, "gen", e->c);
    break;
  case EV_HALT: jw_hex(w, "a0", e->a); jw_uint(w, "instret", e->b); jw_bool(w, "faulted", e->flag); break;
  case EV_STALL:
    jw_uint(w, "from", e->a);
    jw_uint(w, "to", e->b);
    jw_str(w, "reason", sr_names[e->c]);
    jw_hex(w, "detail", e->d);
    jw_hex(w, "pc", e->pc);
    break;
  case EV_INPUT: jw_uint(w, "bytes", e->a); break;
  }
  jw_oend(w);
}

/* A backtrace by heuristics (no frame pointers in the ABI): pc, ra if the
 * current function has not saved it yet, then words on the stack that are
 * return addresses (just past a call). */
static void backtrace_json(JW *w, Core *c) {
  jw_arr(w, "frames");
  jw_obj(w, NULL);
  jw_hex(w, "pc", c->pc);
  jw_where(w, c, c->pc);
  jw_oend(w);
  uint64_t seen[32];
  int ns = 0;
  uint64_t ra = c->x[1];
  bool ra_call = ra >= 4 && ra < ILS_BYTES && !(ra & 3) && (rd32_ils(c, ra - 4) >> 26) == OP_JAL;
  if (ra_call) {
    jw_obj(w, NULL);
    jw_hex(w, "pc", ra);
    jw_str(w, "via", "ra");
    jw_where(w, c, ra);
    jw_oend(w);
    seen[ns++] = ra;
  }
  uint64_t sp = c->x[2];
  for (uint64_t a = sp & ~7ull; a + 8 <= DLS_BYTES && a < sp + 512 && ns < 16; a += 8) {
    uint64_t v = rd64(c->dls + a);
    if (v < 4 || v >= ILS_BYTES || (v & 3)) continue;
    uint32_t prev = rd32_ils(c, v - 4);
    if ((prev >> 26) != OP_JAL || ((prev >> 21) & 31) != 1) continue;
    bool dup = false;
    for (int i = 0; i < ns; i++) dup |= seen[i] == v;
    if (dup) continue;
    seen[ns++] = v;
    jw_obj(w, NULL);
    jw_hex(w, "pc", v);
    jw_str(w, "via", "stack");
    jw_hex(w, "at", a);
    jw_where(w, c, v);
    jw_oend(w);
  }
  jw_aend(w);
}

static void source_json(JW *w, const char *file, int from, int n, char *err, size_t ne) {
  char path[4096];
  FILE *f = NULL;
  if (file[0] == '/') f = fopen(file, "r");
  for (int i = 0; i < nmaps && !f; i++)
    if (maps[i]->root) {
      snprintf(path, sizeof path, "%s/%s", maps[i]->root, file);
      f = fopen(path, "r");
    }
  if (!f) f = fopen(file, "r");
  if (!f) { snprintf(err, ne, "cannot open %s", file); return; }
  char line[4096];
  int no = 0;
  jw_arr(w, "lines");
  while (fgets(line, sizeof line, f)) {
    no++;
    if (no < from) continue;
    if (no >= from + n) break;
    line[strcspn(line, "\r\n")] = 0;
    jw_str(w, NULL, line);
  }
  jw_aend(w);
  fclose(f);
}


/* Handles one request (a JSON object) and writes its answer into `w`. */
static void dbg_request(const char *line, size_t len, JW *w) {
  char err[256] = "";
  JVal *rq = json_parse(line, len);
  jw_reset(w);
  jw_obj(w, NULL);
  if (!rq || rq->t != J_OBJ) {
    jw_bool(w, "ok", false);
    jw_str(w, "error", "not a JSON object");
    jw_oend(w);
    json_free(rq);
    return;
  }
  const JVal *idv = json_get(rq, "id");
  if (idv && idv->t == J_NUM) jw_int(w, "id", (long long)idv->n);
  else if (idv && idv->t == J_STR) jw_str(w, "id", idv->s);
  const char *cmd = json_str(json_get(rq, "cmd"), "");
  jw_str(w, "cmd", cmd);
  size_t mark = w->n; /* "ok" goes in front of the payload: written last, patched in */
  jw_bool(w, "ok", true);
  bool busy = dbg_state == ST_RUNNING;

  if (!strcmp(cmd, "hello")) {
    jw_int(w, "version", DBG_PROTO_VERSION);
    jw_int(w, "ncores", ncores);
    jw_uint(w, "ctab", ctab_size);
    jw_uint(w, "nxmap", nxmap);
    jw_str(w, "image", dbg_img_path ? dbg_img_path : "");
    jw_bool(w, "jit", use_jit);
    jw_bool(w, "virtual", virtual_time);
    jw_bool(w, "timetravel", dbg_tt);
    jw_bool(w, "os", os_aware);
    jw_str(w, "state", dbg_state == ST_RUNNING ? "running" : dbg_state == ST_DONE ? "done" : "stopped");
    jw_arr(w, "maps");
    for (int i = 0; i < nmaps; i++) {
      jw_obj(w, NULL);
      jw_str(w, "path", maps[i]->path);
      jw_str(w, "scope", maps[i]->scope == SC_IMAGE ? "image" : maps[i]->scope == SC_KERNEL ? "kernel" : "prog");
      if (maps[i]->prog[0]) jw_str(w, "prog", maps[i]->prog);
      jw_bool(w, "forth", maps[i]->forth >= 0);
      jw_oend(w);
    }
    jw_aend(w);
    jw_position(w);
  } else if (!strcmp(cmd, "status")) {
    jw_str(w, "state", dbg_state == ST_RUNNING ? "running" : dbg_state == ST_DONE ? "done" : "stopped");
    if (dbg_state == ST_DONE) jw_str(w, "why", dbg_done_why);
    jw_position(w);
    jw_uint(w, "events", dbg_evseq);
    jw_uint(w, "console", dbg_conlen);
    if (dbg_tt) tt_history_json(w);
  } else if (!strcmp(cmd, "pause")) {
    if (busy) dbg_pause_req = true;
  } else if (!strcmp(cmd, "continue") || !strcmp(cmd, "stepi") || !strcmp(cmd, "step-round") || !strcmp(cmd, "until") ||
             !strcmp(cmd, "next") || !strcmp(cmd, "finish") || !strcmp(cmd, "goto") || !strcmp(cmd, "reverse-stepi") ||
             !strcmp(cmd, "reverse-continue") || !strcmp(cmd, "reverse-step-round") || !strcmp(cmd, "reverse-tag")) {
    if (busy) snprintf(err, sizeof err, "running (pause first)");
    else if (dbg_state == ST_DONE && strncmp(cmd, "reverse", 7) && strcmp(cmd, "goto")) snprintf(err, sizeof err, "the machine has stopped: %s", dbg_done_why);
    else if (!strcmp(cmd, "continue")) {
      /* fast: not recorded (the history is dropped) and, without live
       * breakpoints, at full speed (the JIT); recording starts again where
       * it stops */
      if (json_bool(json_get(rq, "fast"), false)) {
        if (dbg_tt) { tt_clear(); dbg_tt = false; }
        dbg_tt_due = false;
        dbg_ff = true;
      }
      run_start(G_CONT);
    }
    else if (!strcmp(cmd, "stepi")) {
      int pid = json_int(json_get(rq, "pid"), 0);
      int c = pid ? 0 : req_core(rq, err, sizeof err);
      if (c >= 0 && !pid && cores[c].halted) snprintf(err, sizeof err, "core %d has halted", c);
      else if (c >= 0) {
        goal.core = c;
        goal.pid = pid;
        goal.left = json_u64(json_get(rq, "n"), 1);
        if (!goal.left) goal.left = 1;
        run_start(G_STEPI);
      }
    } else if (!strcmp(cmd, "step-round")) {
      goal.left = json_u64(json_get(rq, "n"), 1);
      if (!goal.left) goal.left = 1;
      run_start(G_ROUNDS);
    } else if (!strcmp(cmd, "next") || !strcmp(cmd, "finish")) {
      int c = req_core(rq, err, sizeof err);
      if (c >= 0) {
        Core *k = &cores[c];
        uint32_t ir = (k->pc & 3) == 0 && k->pc < ILS_BYTES ? rd32_ils(k, k->pc) : 0;
        unsigned op = ir >> 26, rd = (ir >> 21) & 31;
        goal.core = c;
        if (!strcmp(cmd, "finish")) { goal.target = k->x[1]; run_start(G_UNTILPC); }
        else if ((op == OP_JAL || op == OP_JALR || op == OP_XCALL) && rd) { goal.target = k->pc + 4; run_start(G_UNTILPC); }
        else { goal.pid = 0; goal.left = 1; run_start(G_STEPI); }
      }
    } else if (!strcmp(cmd, "until")) {
      uint64_t a = 0;
      int sect;
      char prog[24];
      const char *loc = json_str(json_get(rq, "loc"), NULL);
      if (loc && !resolve_loc(loc, &a, &sect, prog, sizeof prog, err, sizeof err)) {}
      else {
        if (!loc) a = json_u64(json_get(rq, "addr"), 0);
        goal.core = json_get(rq, "core") ? json_int(json_get(rq, "core"), -1) : -1;
        goal.target = a;
        run_start(G_UNTILPC);
      }
    } else if (!strcmp(cmd, "goto")) {
      uint64_t t = json_u64(json_get(rq, "tick"), dbg_tick);
      if (t > dbg_tick) {
        if (dbg_state == ST_DONE) snprintf(err, sizeof err, "the machine has stopped: %s", dbg_done_why);
        else if (dbg_tt && t <= dbg_frontier) { if (tt_goto(t, err, sizeof err)) ev_stopped(); }
        else {
          goal.target = t;
          goal.nobreak = true;
          run_start(G_TICK);
        }
      } else if (t <= dbg_tick && tt_goto(t, err, sizeof err)) ev_stopped();
    } else if (!strcmp(cmd, "reverse-stepi")) {
      int c = req_core(rq, err, sizeof err);
      if (c >= 0 && tt_reverse(SK_STEP, c, 0, json_u64(json_get(rq, "n"), 1), err, sizeof err)) ev_stopped();
    } else if (!strcmp(cmd, "reverse-continue")) {
      if (tt_reverse(SK_BPS, -1, 0, 1, err, sizeof err)) ev_stopped();
    } else if (!strcmp(cmd, "reverse-tag")) {
      int c = req_core(rq, err, sizeof err);
      int tg = json_int(json_get(rq, "tag"), 0) & 15;
      if (c >= 0 && tt_reverse(SK_TAG, c, tg, 1, err, sizeof err)) ev_stopped();
    } else if (!strcmp(cmd, "reverse-step-round")) {
      /* back to the start of this round (if a core has had its turn in it), then of earlier ones */
      uint64_t n = json_u64(json_get(rq, "n"), 1), t = dbg_tick - (uint64_t)dbg_ci;
      if (!n) n = 1;
      uint64_t back = (dbg_ci ? n - 1 : n) * (uint64_t)ncores;
      t = t > back ? t - back : 0;
      if (tt_goto(t, err, sizeof err)) { stop.hit = false; stop_req(-1, 0, "reverse round"); ev_stopped(); }
    }
    if (!err[0]) jw_position(w);
  } else if (!strcmp(cmd, "break") || !strcmp(cmd, "tbreak")) {
    const char *kind = json_str(json_get(rq, "kind"), "pc");
    int k = 0;
    for (int i = 1; i <= BK_PID; i++)
      if (!strcmp(kind, bk_names[i])) k = i;
    Bp *b = k ? bp_alloc(k) : NULL;
    if (!k) snprintf(err, sizeof err, "unknown breakpoint kind %s", kind);
    else if (!b) snprintf(err, sizeof err, "too many breakpoints");
    else {
      b->temp = !strcmp(cmd, "tbreak") || json_bool(json_get(rq, "temp"), false);
      if (json_get(rq, "core")) b->core = json_int(json_get(rq, "core"), -1);
      b->ignore = json_u64(json_get(rq, "ignore"), 0);
      const char *cond = json_str(json_get(rq, "cond"), NULL);
      if (cond && !parse_cond(cond, b)) snprintf(err, sizeof err, "bad condition (reg OP value): %s", cond);
      if (k == BK_PC) {
        const char *loc = json_str(json_get(rq, "loc"), NULL);
        int sect;
        if (loc) resolve_loc(loc, &b->addr, &sect, b->prog, sizeof b->prog, err, sizeof err);
        else b->addr = json_u64(json_get(rq, "addr"), 0);
        if (json_get(rq, "prog")) snprintf(b->prog, sizeof b->prog, "%s", json_str(json_get(rq, "prog"), ""));
        char s[160] = "";
        const char *f;
        int ln;
        Core *c0 = &cores[b->core >= 0 ? b->core : 0];
        if (!b->prog[0]) {
          sym_code(c0, b->addr, s, sizeof s);
          if (line_code(c0, b->addr, &f, &ln, NULL)) {
            size_t n = strlen(s);
            snprintf(s + n, sizeof s - n, "%s%s:%d", n ? " " : "", f, ln);
          }
        } else snprintf(s, sizeof s, "in %s", b->prog);
        snprintf(b->desc, sizeof b->desc, "pc 0x%llx%s%s%s", (unsigned long long)b->addr, s[0] ? " (" : "", s, s[0] ? ")" : "");
      } else if (k == BK_TRAP) {
        const char *cs = json_str(json_get(rq, "cause"), NULL);
        b->arg = -1;
        if (cs)
          for (int i = 0; i <= 14; i++)
            if (!strcmp(cs, stx_cause_name(i))) b->arg = i;
        if (cs && b->arg < 0 && strcmp(cs, "any")) snprintf(err, sizeof err, "unknown trap cause %s", cs);
        snprintf(b->desc, sizeof b->desc, "trap %s", cs ? cs : "any");
      } else if (k == BK_CAPOP) {
        const char *ops = json_str(json_get(rq, "ops"), "give,take,send,recv,dom,revoke,undom");
        char buf[256];
        snprintf(buf, sizeof buf, "%s", ops);
        for (char *t = strtok(buf, ", "); t; t = strtok(NULL, ", ")) {
          int bit = -1;
          for (int i = 0; i < 15; i++)
            if (!strcmp(t, co_names[i])) bit = i;
          if (!strcmp(t, "all")) b->arg = 0x7fff;
          else if (bit < 0) snprintf(err, sizeof err, "unknown capability operation %s", t);
          else b->arg |= 1 << bit;
        }
        snprintf(b->desc, sizeof b->desc, "capability operation (%s)", ops);
      } else if (k == BK_PID) {
        const char *nm = json_str(json_get(rq, "name"), NULL);
        b->arg = json_int(json_get(rq, "pid"), 0);
        if (!os_aware) snprintf(err, sizeof err, "needs StrataOS awareness (--os DIR)");
        else if (nm && !(b->arg = os_pid_named(nm))) {
          /* not running yet: a pc breakpoint at the program's entry does it */
          Map *m = map_prog(nm);
          if (!m) snprintf(err, sizeof err, "no process %s and no map for it", nm);
          else {
            b->kind = BK_PC;
            const MSym *st = map_sym_named(m, "_start");
            b->addr = st ? st->addr : 0x8000;
            snprintf(b->prog, sizeof b->prog, "%s", nm);
          }
        }
        if (nm) snprintf(b->desc, sizeof b->desc, "process %s runs%s", nm, b->kind == BK_PC ? " (at its entry)" : "");
        else snprintf(b->desc, sizeof b->desc, "pid %d runs", b->arg);
        if (os_aware) for (int i = 0; i < ncores; i++) dbg_pid_prev[i] = cores[i].user ? os_cur_pid(i) : -1;
      } else snprintf(b->desc, sizeof b->desc, "%s", kind);
      if (b->core >= 0) {
        size_t n = strlen(b->desc);
        snprintf(b->desc + n, sizeof b->desc - n, " on core %d", b->core);
      }
      if (b->cond) {
        size_t n = strlen(b->desc);
        snprintf(b->desc + n, sizeof b->desc - n, " if %s", cond);
      }
      if (err[0]) dbg_nbp--;
      else { jw_int(w, "bp", b->id); jw_str(w, "desc", b->desc); }
      bp_recount();
    }
  } else if (!strcmp(cmd, "watch")) {
    const char *kind = json_str(json_get(rq, "kind"), "ls");
    int k = !strcmp(kind, "ls") ? WK_LS : !strcmp(kind, "far") ? WK_FAR : !strcmp(kind, "cap") ? WK_CAP : !strcmp(kind, "tag") ? WK_TAG : 0;
    Bp *b = k ? bp_alloc(k) : NULL;
    if (!k) snprintf(err, sizeof err, "unknown watchpoint kind %s (ls, far, cap, tag)", kind);
    else if (!b) snprintf(err, sizeof err, "too many watchpoints");
    else {
      if (json_get(rq, "core")) b->core = json_int(json_get(rq, "core"), -1);
      const char *acc = json_str(json_get(rq, "access"), k == WK_TAG ? "both" : "w");
      b->access = !strcmp(acc, "r") || !strcmp(acc, "issue") ? 1 : !strcmp(acc, "w") || !strcmp(acc, "complete") ? 2 : 3;
      b->ignore = json_u64(json_get(rq, "ignore"), 0);
      b->len = json_u64(json_get(rq, "len"), 8);
      const char *loc = json_str(json_get(rq, "loc"), NULL);
      if (k == WK_LS) {
        const char *mem = json_str(json_get(rq, "mem"), "dls");
        b->mem = !strcmp(mem, "ils");
        int sect;
        if (loc) resolve_loc(loc, &b->addr, &sect, b->prog, sizeof b->prog, err, sizeof err);
        else b->addr = json_u64(json_get(rq, "addr"), 0);
        snprintf(b->desc, sizeof b->desc, "%s [0x%llx, 0x%llx) %s", mem, (unsigned long long)b->addr,
                 (unsigned long long)(b->addr + b->len), acc);
      } else if (k == WK_FAR) {
        b->mem = space_code(json_str(json_get(rq, "space"), "t3"));
        b->addr = json_u64(json_get(rq, "addr"), 0);
        if (b->mem < 0) snprintf(err, sizeof err, "far watchpoints: space t2, t3 or dev");
        snprintf(b->desc, sizeof b->desc, "%s [0x%llx, 0x%llx) %s", space_name(b->mem), (unsigned long long)b->addr,
                 (unsigned long long)(b->addr + b->len), acc);
      } else if (k == WK_CAP) {
        b->arg = json_int(json_get(rq, "reg"), 0) & 15;
        if (b->core < 0) b->core = 0;
        snprintf(b->desc, sizeof b->desc, "c%d", b->arg);
      } else {
        b->arg = json_int(json_get(rq, "tag"), 0) & 15;
        snprintf(b->desc, sizeof b->desc, "tg%d %s", b->arg, b->access == 1 ? "issue" : b->access == 2 ? "completion" : "issue/completion");
      }
      if (b->core >= 0) {
        size_t n = strlen(b->desc);
        snprintf(b->desc + n, sizeof b->desc - n, " on core %d", b->core);
      }
      if (err[0]) dbg_nbp--;
      else { jw_int(w, "bp", b->id); jw_str(w, "desc", b->desc); }
      bp_recount();
    }
  } else if (!strcmp(cmd, "delete") || !strcmp(cmd, "enable") || !strcmp(cmd, "disable")) {
    const JVal *idj = json_get(rq, "bp");
    int id = json_int(idj, 0), found = 0;
    for (int i = 0; i < dbg_nbp; i++) {
      if (idj && dbg_bp[i].id != id) continue;
      found++;
      if (!strcmp(cmd, "delete")) { dbg_bp[i] = dbg_bp[--dbg_nbp]; i--; }
      else dbg_bp[i].on = !strcmp(cmd, "enable");
    }
    if (idj && !found) snprintf(err, sizeof err, "no breakpoint %d", id);
    bp_recount();
  } else if (!strcmp(cmd, "breakpoints")) {
    jw_arr(w, "bps");
    for (int i = 0; i < dbg_nbp; i++) jw_bp(w, &dbg_bp[i]);
    jw_aend(w);
  } else if (!strcmp(cmd, "cores")) {
    jw_position(w);
    jw_arr(w, "cores");
    for (int i = 0; i < ncores; i++) jw_core_brief(w, &cores[i]);
    jw_aend(w);
  } else if (!strcmp(cmd, "regs")) {
    int ci = req_core(rq, err, sizeof err);
    if (ci >= 0) {
      Core *c = &cores[ci];
      jw_int(w, "core", ci);
      jw_hex(w, "pc", c->pc);
      jw_where(w, c, c->pc);
      jw_arr(w, "x");
      for (int i = 0; i < 32; i++) jw_hex(w, NULL, c->x[i]);
      jw_aend(w);
      jw_obj(w, "csr");
      jw_uint(w, "instret", c->instret);
      jw_str(w, "mode", c->user ? "user" : "super");
      jw_hex(w, "ccr", c->ccr);
      jw_hex(w, "cause", c->s_cause);
      jw_hex(w, "epc", c->s_epc);
      jw_hex(w, "tval", c->s_tval);
      jw_hex(w, "tvec", c->s_tvec);
      jw_hex(w, "ucause", c->u_cause);
      jw_hex(w, "uepc", c->u_epc);
      jw_hex(w, "utval", c->u_tval);
      jw_hex(w, "utvec", c->u_tvec);
      jw_hex(w, "scratch", c->scratch);
      jw_hex(w, "sscratch", c->sscratch);
      jw_hex(w, "ttag", c->ttag);
      jw_hex(w, "tdata", c->tdata);
      jw_hex(w, "tgeom", c->tgeom);
      jw_hex(w, "takefrom", c->takefrom);
      jw_hex(w, "corebase", c->corebase);
      jw_hex(w, "corecount", c->corecount);
      jw_hex(w, "xslot", c->xslot);
      jw_bool(w, "ipend", c->ipend);
      jw_oend(w);
      jw_bool(w, "halted", c->halted);
      jw_stall(w, c);
    }
  } else if (!strcmp(cmd, "caps")) {
    int ci = req_core(rq, err, sizeof err);
    if (ci >= 0) {
      jw_int(w, "core", ci);
      jw_arr(w, "caps");
      for (int i = 0; i < NCAPS; i++) jw_cap(w, NULL, &cores[ci].caps[i]);
      jw_aend(w);
    }
  } else if (!strcmp(cmd, "ctab")) {
    int ci = req_core(rq, err, sizeof err);
    if (ci >= 0) {
      jw_int(w, "core", ci);
      jw_uint(w, "size", ctab_size);
      jw_arr(w, "entries");
      for (uint64_t i = 0; i < ctab_size; i++) {
        const Cap *k = &cores[ci].ctab[i];
        if (!k->valid) continue;
        jw_obj(w, NULL);
        jw_uint(w, "slot", i);
        jw_cap(w, "cap", k);
        jw_oend(w);
      }
      jw_aend(w);
    }
  } else if (!strcmp(cmd, "inbox")) {
    int ci = req_core(rq, err, sizeof err);
    if (ci >= 0) {
      jw_int(w, "core", ci);
      jw_arr(w, "from");
      for (int s = 0; s <= ncores; s++) {
        if (!cores[ci].iq_cnt[s]) continue;
        jw_obj(w, NULL);
        jw_int(w, "node", s);
        jw_arr(w, "caps");
        for (int k = 0; k < cores[ci].iq_cnt[s]; k++) jw_cap(w, NULL, &cores[ci].inbox[s][k]);
        jw_aend(w);
        jw_oend(w);
      }
      jw_aend(w);
    }
  } else if (!strcmp(cmd, "xmap")) {
    int ci = req_core(rq, err, sizeof err);
    if (ci >= 0) {
      Core *c = &cores[ci];
      jw_int(w, "core", ci);
      jw_uint(w, "xslot", c->xslot);
      jw_uint(w, "size", nxmap); /* the platform's NXMAP */
      jw_arr(w, "entries");
      for (int i = 0; i < (int)nxmap; i++) {
        jw_obj(w, NULL);
        jw_int(w, "index", i);
        jw_bool(w, "valid", c->xm_v[i]);
        if (c->xm_v[i]) {
          jw_str(w, "space", space_name(c->xm_sp[i]));
          jw_hex(w, "far", c->xm_far[i]);
          jw_hex(w, "ils", c->xm_ils[i]);
          jw_where(w, c, c->xm_ils[i]);
        }
        jw_oend(w);
      }
      jw_aend(w);
    }
  } else if (!strcmp(cmd, "tags")) {
    const JVal *cj = json_get(rq, "core");
    jw_arr(w, "cores");
    for (int i = 0; i < ncores; i++) {
      if (cj && json_int(cj, 0) != i) continue;
      jw_obj(w, NULL);
      jw_int(w, "core", i);
      tags_json(w, i);
      jw_stall(w, &cores[i]);
      jw_oend(w);
    }
    jw_aend(w);
  } else if (!strcmp(cmd, "pending")) {
    jw_arr(w, "reads");
    for (int i = 0; i < ncores; i++)
      for (int k = 0; k < NPEND; k++) {
        const Pending *p = &cores[i].pend[k];
        if (!p->on) continue;
        char buf[160];
        jw_obj(w, NULL);
        jw_int(w, "core", i);
        jw_int(w, "tag", p->tag);
        jw_hex(w, "port", p->port);
        jw_str(w, "name", port_name(p->port));
        jw_hex(w, "ls", p->ls);
        jw_hex(w, "len", p->len);
        jw_uint(w, "seq", p->seq);
        jw_uint(w, "issued", dbg_tags[i][p->tag].issue_round);
        jw_str(w, "waits", pend_waits(p, buf, sizeof buf));
        jw_oend(w);
      }
    jw_aend(w);
    jw_obj(w, "blk");
    jw_int(w, "commands", sq_cnt);
    jw_int(w, "partial", sq_fill);
    jw_int(w, "caps", bi_cnt);
    jw_int(w, "completions", cq_cnt);
    jw_int(w, "returning_to", blk_out_to);
    jw_oend(w);
    jw_int(w, "input_queued", host_in_cnt);
    jw_int(w, "breaks", host_breaks);
    jw_hex(w, "deadline", tmr_deadline);
    jw_uint(w, "now", now_ticks());
  } else if (!strcmp(cmd, "granules")) {
    /* the revocation units: runs of granules with one generation */
    jw_arr(w, "units");
    for (int sp = 0; sp < 2; sp++) {
      int lo = sp ? (int)NGRAN3 : 0, hi = sp ? (int)(NGRAN3 + NGRAN2) : (int)NGRAN3;
      for (int g = lo; g < hi;) {
        int e = g + 1;
        while (e < hi && !ghead[e] && ggen[e] == ggen[g]) e++;
        if (ggen[g] || ghead[g]) {
          jw_obj(w, NULL);
          jw_str(w, "space", sp ? "t2" : "t3");
          jw_hex(w, "base", (uint64_t)(g - lo) << GRAN_SHIFT);
          jw_hex(w, "len", (uint64_t)(e - g) << GRAN_SHIFT);
          jw_int(w, "gen", ggen[g]);
          jw_oend(w);
        }
        g = e;
      }
    }
    jw_aend(w);
  } else if (!strcmp(cmd, "mem")) {
    int ci = json_get(rq, "core") ? req_core(rq, err, sizeof err) : 0;
    const char *sp = json_str(json_get(rq, "space"), "dls");
    uint64_t a = json_u64(json_get(rq, "addr"), 0), n = json_u64(json_get(rq, "len"), 64);
    const char *loc = json_str(json_get(rq, "loc"), NULL);
    int sect;
    char prog[24];
    if (loc && resolve_loc(loc, &a, &sect, prog, sizeof prog, err, sizeof err) && !json_get(rq, "space"))
      sp = sect == MS_TEXT ? "ils" : sect == MS_FAR ? "t3" : sect == MS_CLUSTER ? "t2" : "dls";
    if (n > 65536) n = 65536;
    uint8_t *p = ci >= 0 && !err[0] ? mem_range(sp, ci, a, n, err, sizeof err) : NULL;
    if (p) {
      jw_str(w, "space", sp);
      jw_hex(w, "addr", a);
      jw_hexbytes(w, "hex", p, n);
      if (!strcmp(sp, "dls")) {
        char s[96];
        sym_data(&cores[ci], a, s, sizeof s);
        if (s[0]) jw_str(w, "sym", s);
      }
    }
  } else if (!strcmp(cmd, "set-reg") || !strcmp(cmd, "set-mem")) {
    int ci = req_core(rq, err, sizeof err);
    if (busy) snprintf(err, sizeof err, "running (pause first)");
    else if (ci >= 0 && !strcmp(cmd, "set-reg")) {
      int r = reg_index(json_str(json_get(rq, "reg"), ""));
      uint64_t v = json_u64(json_get(rq, "value"), 0);
      if (r < 0 || r == 33) snprintf(err, sizeof err, "unknown register");
      else tt_input_log(r == 32 ? IN_PC : IN_XREG, NULL, 0, ci, (uint64_t)r, v);
    } else if (ci >= 0) {
      const char *sp = json_str(json_get(rq, "space"), "dls");
      const char *hex = json_str(json_get(rq, "hex"), "");
      uint64_t a = json_u64(json_get(rq, "addr"), 0), n = strlen(hex) / 2;
      uint8_t *p = mem_range(sp, ci, a, n, err, sizeof err);
      if (p) {
        uint8_t tmp[4096];
        if (n > sizeof tmp) n = sizeof tmp;
        for (uint64_t i = 0; i < n; i++) {
          unsigned v;
          sscanf(hex + 2 * i, "%2x", &v);
          tmp[i] = (uint8_t)v;
        }
        int code = !strcmp(sp, "dls") ? 0 : !strcmp(sp, "ils") ? 1 : !strcmp(sp, "t2") ? 2 : !strcmp(sp, "t3") ? 3 : 4;
        tt_input_log(IN_MEM + code, tmp, n, ci, a, 0);
      }
    }
  } else if (!strcmp(cmd, "disasm")) {
    int ci = req_core(rq, err, sizeof err);
    if (ci >= 0) {
      Core *c = &cores[ci];
      uint64_t a = json_get(rq, "addr") ? json_u64(json_get(rq, "addr"), 0) : c->pc;
      const char *loc = json_str(json_get(rq, "loc"), NULL);
      int sect;
      char prog[24];
      if (loc) resolve_loc(loc, &a, &sect, prog, sizeof prog, err, sizeof err);
      int n = json_int(json_get(rq, "n"), 16), before = json_int(json_get(rq, "before"), 0);
      if (n > 1024) n = 1024;
      a &= ~3ull;
      a = a >= (uint64_t)before * 4 ? a - (uint64_t)before * 4 : 0;
      jw_arr(w, "lines");
      for (int i = 0; i < n && a < ILS_BYTES && !err[0]; i++, a += 4) {
        uint32_t ir = rd32_ils(c, a);
        char d[160], s[160];
        disasm(c, ir, a, d, sizeof d);
        jw_obj(w, NULL);
        jw_hex(w, "addr", a);
        jw_key(w, "word");
        jw_printf(w, "\"%08x\"", ir);
        jw_str(w, "text", d);
        Where wh = where_code(c, a);
        const MSym *sy = map_sym_at(wh.map, wh.sect, wh.addr);
        if (sy && sy->addr == wh.addr) jw_str(w, "label", sy->name);
        sym_code(c, a, s, sizeof s);
        if (s[0]) jw_str(w, "sym", s);
        const char *f;
        int ln;
        if (line_code(c, a, &f, &ln, NULL)) { jw_str(w, "file", f); jw_int(w, "line", ln); }
        if (a == c->pc) jw_bool(w, "pc", true);
        for (int b = 0; b < dbg_nbp; b++)
          if (dbg_bp[b].kind == BK_PC && dbg_bp[b].addr == a && (dbg_bp[b].core < 0 || dbg_bp[b].core == ci)) jw_int(w, "bp", dbg_bp[b].id);
        jw_oend(w);
      }
      jw_aend(w);
    }
  } else if (!strcmp(cmd, "sym")) {
    uint64_t a;
    int sect;
    char prog[24];
    if (resolve_loc(json_str(json_get(rq, "loc"), ""), &a, &sect, prog, sizeof prog, err, sizeof err)) {
      jw_hex(w, "addr", a);
      jw_str(w, "section", ms_names[sect]);
      if (prog[0]) jw_str(w, "prog", prog);
    }
  } else if (!strcmp(cmd, "source")) {
    const char *f = json_str(json_get(rq, "file"), "");
    source_json(w, f, json_int(json_get(rq, "from"), 1), json_int(json_get(rq, "n"), 20), err, sizeof err);
  } else if (!strcmp(cmd, "log")) {
    uint64_t since = json_u64(json_get(rq, "since"), 0), lim = json_u64(json_get(rq, "limit"), 2000);
    if (since < dbg_evlo) since = dbg_evlo;
    if (since > dbg_evseq) since = dbg_evseq;
    uint64_t end = since + lim < dbg_evseq ? since + lim : dbg_evseq;
    jw_uint(w, "first", dbg_evlo);
    jw_uint(w, "next", end);
    jw_uint(w, "last", dbg_evseq);
    jw_arr(w, "events");
    for (uint64_t s = since; s < end; s++) ev_json(w, s, &dbg_ev[s % DBG_EVN]);
    jw_aend(w);
  } else if (!strcmp(cmd, "prov")) {
    uint32_t id = (uint32_t)json_u64(json_get(rq, "id"), 0);
    const JVal *cj = json_get(rq, "core"), *rj = json_get(rq, "reg");
    if (cj && rj) {
      int ci = req_core(rq, err, sizeof err);
      if (ci >= 0) id = cores[ci].caps[json_int(rj, 0) & 15].id;
    }
    if (!err[0] && !prov_get(id)) snprintf(err, sizeof err, "no provenance for capability %u", id);
    if (!err[0]) prov_chain(w, id);
  } else if (!strcmp(cmd, "provgraph")) {
    /* every capability held now (registers, save tables, inboxes) and its ancestors */
    static uint8_t *mark;
    if (!mark) mark = calloc(DBG_PROVMAX, 1);
    if (mark) memset(mark, 0, DBG_PROVMAX);
    const JVal *cj = json_get(rq, "core");
    jw_arr(w, "held");
    for (int i = 0; i < ncores; i++) {
      if (cj && json_int(cj, 0) != i) continue;
      Core *c = &cores[i];
      for (int r = 0; r < NCAPS + (int)ctab_size; r++) {
        const Cap *k = r < NCAPS ? &c->caps[r] : &c->ctab[r - NCAPS];
        if (!k->valid || !k->id) continue;
        jw_obj(w, NULL);
        jw_int(w, "core", i);
        if (r < NCAPS) jw_int(w, "reg", r);
        else jw_int(w, "slot", r - NCAPS);
        jw_uint(w, "id", k->id);
        jw_bool(w, "live", live(*k));
        jw_oend(w);
        for (uint32_t id = k->id; id && mark && id - 1 < DBG_PROVMAX && !mark[id - 1];) {
          mark[id - 1] = 1;
          const Prov *p = prov_get(id);
          if (!p) break;
          if (p->parent2 && p->parent2 - 1 < DBG_PROVMAX) mark[p->parent2 - 1] |= 2;
          id = p->parent;
        }
      }
    }
    jw_aend(w);
    jw_arr(w, "nodes");
    for (uint32_t id = 1; mark && id <= dbg_nprov && id - 1 < DBG_PROVMAX; id++) {
      if (!mark[id - 1]) continue;
      const Prov *p = prov_get(id);
      char ps[8];
      perms_str(p->perms, ps);
      jw_obj(w, NULL);
      jw_uint(w, "id", id);
      jw_str(w, "op", po_names[p->op]);
      jw_uint(w, "parent", p->parent);
      if (p->parent2) jw_uint(w, "parent2", p->parent2);
      jw_int(w, "core", p->core == 255 ? -1 : p->core);
      if (p->op == PO_GIVE) jw_int(w, "from", p->from);
      jw_str(w, "space", space_name(p->space));
      jw_hex(w, "base", p->base);
      jw_hex(w, "len", p->len);
      jw_str(w, "perms", ps);
      jw_uint(w, "round", p->round);
      jw_oend(w);
    }
    jw_aend(w);
  } else if (!strcmp(cmd, "backtrace")) {
    int ci = req_core(rq, err, sizeof err);
    if (ci >= 0) backtrace_json(w, &cores[ci]);
  } else if (!strcmp(cmd, "processes")) {
    if (!os_aware) snprintf(err, sizeof err, "needs StrataOS awareness (--os DIR)");
    else {
      os_procs_at = ~0ull;
      os_read_procs();
      jw_arr(w, "procs");
      for (int i = 0; i < os_nprocs; i++) {
        OsProc *o = &os_procs[i];
        jw_obj(w, NULL);
        jw_int(w, "pid", o->pid);
        jw_int(w, "parent", o->parent);
        jw_int(w, "state", o->state);
        jw_int(w, "status", o->status);
        jw_int(w, "core", o->core);
        jw_int(w, "ncores", o->ncores);
        jw_str(w, "name", o->name);
        jw_arr(w, "running");
        for (int k = 0; k < ncores; k++)
          if (os_cur_pid(k) == o->pid) jw_int(w, NULL, k);
        jw_aend(w);
        jw_oend(w);
      }
      jw_aend(w);
    }
  } else if (!strcmp(cmd, "pointer")) {
    if (dbg_state == ST_DONE) snprintf(err, sizeof err, "the machine has stopped");
    else {
      int op = (int)json_int(json_get(rq, "op"), 0);
      int64_t x = json_int(json_get(rq, "x"), 0), y = json_int(json_get(rq, "y"), 0);
      if (op < PTR_MOVE || op > PTR_LEAVE) snprintf(err, sizeof err, "op: 1 move, 2 button, 3 wheel, 4 enter, 5 leave");
      else {
        tt_input_log(IN_PTR, NULL, 0, -1, (uint64_t)op, (uint64_t)(uint32_t)x | (uint64_t)(uint32_t)y << 32);
        dbg_idle_skip = false;
      }
    }
  } else if (!strcmp(cmd, "input") || !strcmp(cmd, "ctrl-c")) {
    if (dbg_state == ST_DONE) snprintf(err, sizeof err, "the machine has stopped");
    else if (host_in_fd >= 0) snprintf(err, sizeof err, "console input comes from the -i file");
    else {
      const JVal *d = json_get(rq, "data");
      if (!strcmp(cmd, "ctrl-c")) tt_input_log(IN_BREAK, NULL, 0, -1, 0, 0);
      else if (d && d->t == J_STR) {
        tt_input_log(IN_BYTES, (const uint8_t *)d->s, d->len, -1, 0, 0);
        Ev e = {0};
        e.kind = EV_INPUT;
        e.core = -1;
        e.a = d->len;
        ev_add(&e);
      }
      dbg_idle_skip = false;
    }
  } else if (!strcmp(cmd, "console")) {
    uint64_t n = dbg_conlen < DBG_CONN ? dbg_conlen : DBG_CONN, from = dbg_conlen - n;
    jw_key(w, "data");
    char *buf = malloc(n + 1);
    for (uint64_t i = 0; i < n && buf && dbg_conring; i++) buf[i] = dbg_conring[(from + i) % DBG_CONN];
    if (buf) jw_esc(w, buf, (size_t)n);
    else jw_puts(w, "\"\"");
    free(buf);
  } else if (!strcmp(cmd, "history")) {
    if (!dbg_tt) snprintf(err, sizeof err, "%s", tt_off_why());
    else tt_history_json(w);
  } else if (!strcmp(cmd, "quit") || !strcmp(cmd, "kill")) {
    dbg_quit = true;
  } else {
    snprintf(err, sizeof err, "unknown command %s", cmd);
  }
  if (err[0]) {
    /* replace the payload with the error */
    w->n = mark;
    w->p[w->n] = 0;
    w->depth = 1;
    w->first[1] = 0;
    jw_bool(w, "ok", false);
    jw_str(w, "error", err);
  }
  jw_oend(w);
  json_free(rq);
}

/* ------------------------------------------------------------ setup */

/* --debug and its companions (main's argument loop); true if argv[*i] was one. */
static bool dbg_option(int argc, char **argv, int *i) {
  bool more = *i + 1 < argc;
  const char *a = argv[*i];
  if (!strcmp(a, "--debug") && more) { dbg_where = argv[++*i]; dbg_on = true; host_in_pushed = true; return true; }
  if (!strcmp(a, "--map") && more) { if (dbg_nmapv < 16) dbg_mapv[dbg_nmapv++] = argv[++*i]; else ++*i; return true; }
  if (!strcmp(a, "--os") && more) { os_dir = argv[++*i]; return true; }
  if (!strcmp(a, "--www") && more) { dbg_www = argv[++*i]; return true; }
  if (!strcmp(a, "--history") && more) { dbg_hist_mib = strtoull(argv[++*i], NULL, 0); return true; }
  return false;
}

static void tt_init(void); /* debug_tt.c */

/* Called by main() once the machine is set up, before the first round. */
static void dbg_setup(const char *img, const char *in_path, const char *disk_path) {
  (void)disk_path;
  dbg_img_path = img;
  dbg_in_path = in_path;
  if (in_path) host_in_pushed = false; /* console input from the file, as without --debug */
  dbg_ev = calloc(DBG_EVN, sizeof *dbg_ev);
  /* maps: the image's own (IMAGE.map), --map files, --os */
  char path[4096];
  snprintf(path, sizeof path, "%s", img);
  char *dot = strrchr(path, '.');
  if (dot && !strchr(dot, '/')) strcpy(dot, ".map");
  else strncat(path, ".map", sizeof path - strlen(path) - 1);
  map_load(path, SC_IMAGE, NULL);
  for (int i = 0; i < dbg_nmapv; i++)
    if (!map_load(dbg_mapv[i], SC_IMAGE, NULL)) fprintf(stderr, "strata-emu: --map %s: not a map\n", dbg_mapv[i]);
  if (os_dir) {
    snprintf(path, sizeof path, "%s/kernel.map", os_dir);
    if (!map_load(path, SC_KERNEL, NULL)) fprintf(stderr, "strata-emu: --os: no %s (StrataOS awareness is off)\n", path);
    else os_aware = true;
  }
  for (int i = 0; i < MAXCORES; i++) dbg_pid_prev[i] = -1, dbg_bphold[i] = ~0ull;
  /* the capabilities the cores start with */
  for (int i = 0; i < ncores; i++)
    for (int r = 0; r < NCAPS; r++)
      if (cores[i].caps[r].valid) prov_new(&cores[i], &cores[i].caps[r], PO_RESET, 0, 0, -1);
  for (int i = 0; i < ncores; i++) memcpy(dbg_pshadow[i], cores[i].pend, sizeof dbg_pshadow[i]);
  /* the engine runs the reference interleaving; the JIT only for a plain continue */
  dbg_fastok = use_jit;
  fast_off = true;
  dbg_ttok = virtual_time && net_mode == NET_NONE;
  dbg_tt = dbg_ttok; /* (recorded runs step one instruction at a time; the JIT is for fast continues) */
  if (dbg_tt) tt_init();
  stop_req(-1, 0, "started");
}

#ifndef __EMSCRIPTEN__
#include "debug_io.c" /* the transports and the engine's loop */
#else
static int dbg_main(bool hold) { (void)hold; return 0; } /* (the worker drives the engine: web/web.c) */
#endif
