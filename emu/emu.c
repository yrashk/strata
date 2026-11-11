/* strata-emu: architectural reference emulator for the Strata prototype.
 *
 *   strata-emu [-c ncores] [-t trace.txt] [-m max_steps] [-d disk.img]
 *              [-i input.txt] [-b steps] [-T real|virtual] [-g none]
 *              [-F frame.ppm] [-z scale] [-r WxH] [-H] [-N mode] [-J|-j] image.stx
 *
 * This is the ISA's sequential semantics written as code: every transfer
 * completes at the instant it issues, so tags are never busy and nothing
 * ever stalls on a Local Store range. Cores are interleaved one instruction
 * at a time; a core blocked on ctake (empty inbox) or cgive (full inbox)
 * yields its turn. With the JIT (emu/jit/, the default unless tracing or
 * using the virtual timer) a core runs a quantum of steps per turn.
 *
 * The RTL must produce the same console output, the same per-core
 * instruction trace and the same per-core halt state for any program whose
 * results do not depend on timing-visible behaviour:
 *   - the cycle and stalls CSRs, tpoll, and CCR.PTRAP traps;
 *   - which sender an any-sender `ctake` (or `cpoll`) sees first when more
 *     than one node may give to the same core at once;
 *   - the interleaving of output from different cores on one device, unless
 *     the cores serialise it by handing a capability around. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../asm/isa.h"
#include "../common/stx.h"
#include "../common/platform.h"
#include "../common/display.h"
#include "../common/net.h"
#include "jit/jit.h"

#define MAXCORES 15 /* + the block device = 16 inbox senders, the width of cpoll/tany masks */
#define NCAPS 16
#define CTABMAX CTAB_MAX /* save-table entries at most; ctab_size of them exist (-S) */
#define NXMAP ((int)NXMAP_MAX) /* overlay map entries at most; nxmap of them exist (-X) */
#define NGRAN3 (T3_BYTES >> GRAN_SHIFT) /* revocation granules of T3 */
#define NGRAN2 (T2_BYTES >> GRAN_SHIFT) /* ... and of T2 (after T3's in the table) */
#define GMASK ((uint64_t)GRAN_BYTES - 1)
#define IQ 4      /* block device inbox depth */
#define SQ 2      /* inbox depth per sender */
#define MAXNODES (MAXCORES + 1)
#define NPEND 4   /* device reads one core may have waiting at once (the RTL queue depth) */

enum { SP_NONE = 0, SP_T2 = 2, SP_T3 = 3, SP_DEV = 4, SP_CORE = 5, SP_EP = 6 };
enum { P_R = 1, P_W = 2, P_X = 4, P_A = 8, P_D = 16, P_V = 32 };
enum {
  C_ILLEGAL = 1, C_LSFAULT, C_CAPINV, C_PERM, C_BOUNDS, C_XALIGN, C_IFAULT, C_XMISS, C_PEND, C_CAPOP,
  C_PRIV, C_HALT, C_STOP, C_SVC,
};

typedef struct {
  bool valid;
  uint8_t space, perms;
  uint64_t base, len;
  bool rv;      /* revocable: live only while its granule's generation is gen */
  uint16_t gen; /* revocable: the generation of the granule holding base when it was
                 * made; a revoker (P_V): the permissions crevoke / cundom give */
  uint32_t id;  /* the debugger's provenance id (emu/debug.c); 0 unless debugging */
} Cap;
/* (capability literals below leave the debugger's id at 0) */
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"


/* The revocation granules of system memory (T3) and the cluster store (T2),
 * shared by all cores: a generation each, and a HEAD bit marking the first
 * granule of a unit (a range made revocable or revoked as one, see cdom). */
static uint16_t ggen[NGRAN3 + NGRAN2];
static bool ghead[NGRAN3 + NGRAN2];

/* the table index of the granule holding byte `a` of a memory space, -1 if none */
static int gidx(uint8_t space, uint64_t a) {
  if (space == SP_T3) return a < T3_BYTES ? (int)(a >> GRAN_SHIFT) : -1;
  if (space == SP_T2) return a < T2_BYTES ? (int)(NGRAN3 + (a >> GRAN_SHIFT)) : -1;
  return -1;
}

/* A capability can be used only while valid and, if it is revocable, while
 * the granule holding its base still has the generation it was made under. */
static bool live(Cap k) {
  if (!k.valid || !k.rv) return k.valid;
  int g = gidx(k.space, k.base);
  return g >= 0 && ggen[g] == k.gen;
}
/* a revoker: a live capability with V (revokers are never revocable themselves) */
static bool revoker(Cap k) { return live(k) && (k.perms & P_V) && !k.rv; }

/* Revokes the units the granules [a, b) touch (b > a): every one of their
 * granules gets the generation one past the highest among them, so every
 * revocable capability based there dies, and [a, b) becomes a unit of its
 * own (the parts of touched units outside it become units too). Returns
 * the new generation. */
static uint16_t revoke_units(int a, int b) {
  int lo0 = a < (int)NGRAN3 ? 0 : (int)NGRAN3, end = a < (int)NGRAN3 ? (int)NGRAN3 : (int)(NGRAN3 + NGRAN2);
  int lo = a, hi = b;
  while (lo > lo0 && !ghead[lo]) lo--; /* back to the start of the unit holding a */
  while (hi < end && !ghead[hi]) hi++; /* on to the end of the unit holding b - 1 */
  uint16_t m = 0;
  for (int k = lo; k < hi; k++)
    if (ggen[k] > m) m = ggen[k];
  m++;
  for (int k = lo; k < hi; k++) {
    ggen[k] = m;
    ghead[k] = k == lo || k == a || k == b;
  }
  return m;
}

typedef struct {
  Cap cap;
  int from; /* sender node */
} Gift;

/* A device read that cannot complete yet (console input, the break port,
 * timer WAIT, VSYNC, the pointer's EVENT) stays in flight: its tag is busy and loads/stores over
 * its bytes wait, exactly as the hardware behaves. `port` is the port it
 * reads, `target` the tick at which a VSYNC completes, `seq` its issue order
 * (the oldest waiting read is served first). */
typedef struct { bool on; int tag; uint64_t ls, len, port, target, seq; } Pending;

typedef struct {
  int id;
  bool halted, blocked, traced;
  uint64_t pc, x[32];
  Cap caps[NCAPS], ctab[CTABMAX];
  bool xm_v[NXMAP];
  uint8_t xm_sp[NXMAP];
  uint64_t xm_far[NXMAP], xm_ils[NXMAP];
  uint64_t instret, ccr, ttag, tdata, tgeom, scratch, takefrom;
  uint64_t corebase, corecount; /* the core window of a supervised program */
  bool user, spp_user;          /* current mode; the mode eret returns to (supervisor) */
  uint64_t s_cause, s_epc, s_tval, s_tvec, sscratch; /* supervisor trap state */
  uint64_t u_cause, u_epc, u_tval, u_tvec;           /* user trap state */
  uint64_t hz_base, hz_span;    /* the D-LS bytes of the device reads in flight, for the fast paths (hazard_set) */
  bool ipend;                   /* a stop request is pending */
  Pending pend[NPEND];          /* in-flight device reads */
  uint64_t xslot;               /* log2 bytes of an overlay slot; 0 = exact-match mapping */
  uint8_t dls[DLS_BYTES], ils[ILS_BYTES];
  /* the capability inbox: a small queue per sender, so that one sender can
   * never fill the inbox and block a gift another `ctake cd, rs` waits for */
  Cap inbox[MAXNODES][SQ];
  int iq_cnt[MAXNODES];
} Core;

#include "debug.h" /* the debug engine's hooks (--debug; emu/debug.c) */

/* ------------------------------------------------------------ devices */

static uint8_t plat_rom[PLAT_LEN];
static uint8_t blk_rom[BLK_IDENT_LEN];
static uint8_t *disk;
static uint64_t disk_blocks = 2048;

/* block device 0: submission bytes, pending commands, capability inbox,
 * completion entries */
static uint8_t sq_buf[32];
static int sq_fill;
static uint8_t sq_cmds[BLK_QDEPTH][32];
static int sq_head, sq_cnt;
static Gift blk_inbox[IQ];
static int bi_head, bi_cnt;
static uint8_t cq[BLK_QDEPTH][16];
static int cq_head, cq_cnt, cq_byte;
static Gift blk_out; /* a capability waiting to be returned */
static int blk_out_to = -1;

/* timer and framebuffer controller */
static bool virtual_time;       /* -T virtual: NOW = rounds / 100 */
static uint64_t rounds;         /* machine rounds: every live core gets one step */
static uint64_t tmr_deadline;   /* DEADLINE */
static uint64_t tmr_wbuf;       /* DEADLINE bytes written so far (takes effect at byte 7) */
static uint64_t tmr_lnow, tmr_ldl; /* NOW and DEADLINE, latched when their byte 0 is read */
static uint64_t ptr_lstate;        /* the pointer's STATE, latched when its byte 0 is read */
static int npending;            /* pending device reads, machine wide */
static uint64_t slow_events = 1; /* counts what can unblock a core: completed device reads, steps of step() */
static uint64_t pend_seq;
static uint64_t net_lstat;      /* network STATUS, latched when its byte 0 is read */

static Core cores[MAXCORES];
static int ncores = 4;
static uint64_t ctab_size = CTAB_DEF; /* capability save-table entries per core (-S) */
static unsigned nxmap = NXMAP_DEF;    /* overlay map entries per core (-X) */
static uint8_t *t2, *t3;
static FILE *trace;
static bool faulted;

/* ------------------------------------------------------------ helpers */

static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void wr64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static int64_t sext(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }

static uint8_t *far_ptr(uint8_t space, uint64_t addr) {
  if (space == SP_T2) return t2 + (addr & (T2_BYTES - 1) & ~7ull);
  if (space == SP_T3) return t3 + (addr & (T3_BYTES - 1) & ~7ull);
  return NULL;
}

/* A word written to far memory: a write into the framebuffer window feeds
 * the live scanout (and opens the window the first time). */
static inline void far_wrote(uint8_t space, uint64_t addr) {
  if (dbg_on) dbg_far_written(space, addr);
  if (space != SP_T3) return;
  addr &= (T3_BYTES - 1) & ~7ull;
  if (addr >= FB_BASE && addr < (uint64_t)FB_BASE + FB_SIZE) host_fb_touch((uint32_t)(addr - FB_BASE), 8);
}

static void setx(Core *c, unsigned r, uint64_t v) { if (r) c->x[r] = v; }

static uint64_t le(const uint8_t *p, int n) {
  uint64_t v = 0;
  for (int i = 0; i < n; i++) v |= (uint64_t)p[i] << (8 * i);
  return v;
}

static bool inbox_push(Core *dst, Cap cap, int from) {
  if (dst->iq_cnt[from] == SQ) return false;
  dst->inbox[from][dst->iq_cnt[from]++] = cap;
  return true;
}

/* Runs block-device commands while a command and a capability are both
 * waiting, the completion queue has room and no capability is waiting to be
 * returned. Data moves between the disk and the far memory the capability
 * names; the capability goes back to the core named in the command. */
static void blk_run(void) {
  for (;;) {
    if (blk_out_to >= 0) {
      if (!inbox_push(&cores[blk_out_to], blk_out.cap, blk_out.from)) return;
      blk_out_to = -1;
    }
    if (!sq_cnt || !bi_cnt || cq_cnt == BLK_QDEPTH) return;
    uint8_t *cmd = sq_cmds[sq_head];
    sq_head = (sq_head + 1) % BLK_QDEPTH;
    sq_cnt--;
    Cap k = blk_inbox[bi_head].cap;
    bi_head = (bi_head + 1) % IQ;
    bi_cnt--;
    unsigned op = cmd[0], reply = cmd[1];
    uint64_t cid = le(cmd + 2, 2), n = le(cmd + 4, 4), lba = le(cmd + 8, 8), off = le(cmd + 16, 8);
    uint64_t bytes = n * BLK_BLOCK;
    int st = BLK_OK;
    if (op != BLK_OP_READ && op != BLK_OP_WRITE && op != BLK_OP_FLUSH) st = BLK_E_OP;
    else if (op != BLK_OP_FLUSH && (n > BLK_MAXCMD || lba > disk_blocks || n > disk_blocks - lba)) st = BLK_E_LBA;
    else if (op != BLK_OP_FLUSH && (off > k.len || bytes > k.len - off || (off & 7))) st = BLK_E_RANGE;
    else if (op != BLK_OP_FLUSH && (k.space != SP_T2 && k.space != SP_T3)) st = BLK_E_PERM;
    else if (op == BLK_OP_READ && !(k.perms & P_W)) st = BLK_E_PERM;
    else if (op == BLK_OP_WRITE && !(k.perms & P_R)) st = BLK_E_PERM;
    if (st == BLK_OK && op != BLK_OP_FLUSH) {
      for (uint64_t i = 0; i < bytes; i += 8) {
        uint8_t *fp = far_ptr(k.space, k.base + off + i);
        if (op == BLK_OP_READ) { memcpy(fp, disk + lba * BLK_BLOCK + i, 8); far_wrote(k.space, k.base + off + i); }
        else memcpy(disk + lba * BLK_BLOCK + i, fp, 8);
      }
      if (dbg_on && op == BLK_OP_WRITE) dbg_disk_written(lba * BLK_BLOCK, bytes);
    }
    uint8_t *e = cq[(cq_head + cq_cnt) % BLK_QDEPTH];
    memset(e, 0, 16);
    plat_put(e, cid, 2);
    plat_put(e + 2, (uint64_t)st, 2);
    plat_put(e + 4, st == BLK_OK ? n : 0, 4);
    cq_cnt++;
    blk_out = (Gift){k, ncores};
    blk_out_to = reply < (unsigned)ncores ? (int)reply : 0;
  }
}

/* Timer ticks since power-on: host microseconds, or rounds / 100 (a
 * nominal 100 MHz machine in which every core takes one step per cycle). */
static uint64_t now_ticks(void) { return virtual_time ? rounds / 100 : host_us(); }

/* Completes a pending read: its bytes are byte i of `v` (zero past 8). */
static void pend_fill(Core *c, Pending *p, uint64_t v) {
  for (uint64_t i = 0; i < p->len; i++) c->dls[p->ls + i] = i < 8 ? (uint8_t)(v >> (8 * i)) : 0;
  p->on = false;
  npending--;
  slow_events++;
}

/* The oldest pending read of a port, or NULL. */
static Pending *pend_oldest(uint64_t port, Core **who) {
  Pending *best = NULL;
  for (int i = 0; i < ncores; i++)
    for (int k = 0; k < NPEND; k++) {
      Pending *p = &cores[i].pend[k];
      if (p->on && p->port == port && (!best || p->seq < best->seq)) { best = p; *who = &cores[i]; }
    }
  return best;
}

/* Console input for a read of `len` bytes into c's D-LS: completes it if
 * that many bytes are there (or the input has ended). */
static bool con_in_ready(uint64_t len) {
  if ((uint64_t)host_in_cnt < len) host_poll_input();
  return (uint64_t)host_in_cnt >= len || !host_input_live();
}
static void con_in_fill(Core *c, uint64_t ls, uint64_t len) {
  for (uint64_t i = 0; i < len; i++) {
    int ch = host_getc();
    c->dls[ls + i] = ch < 0 ? 0x04 : (uint8_t)ch;
  }
}

/* Network RX for a read of `len` bytes into c's D-LS: the head packet's
 * first bytes, zeros past its end; the packet leaves the queue. */
static void net_rx_fill(Core *c, uint64_t ls, uint64_t len) {
  unsigned n;
  const uint8_t *pk = net_rx_head(&n);
  for (uint64_t i = 0; i < len; i++) c->dls[ls + i] = i < n ? pk[i] : 0;
  net_rx_pop();
}

/* Completes whatever pending device reads can complete now. */
static void pend_service(void) {
  if (!npending) return;
  Core *c;
  Pending *p;
  while (host_breaks && (p = pend_oldest(DEV_CONSOLE + CON_BREAK, &c))) { host_breaks--; pend_fill(c, p, 0x0303030303030303ull); }
  while (host_ptr_ready() && (p = pend_oldest(DEV_POINTER + PTR_EVENT, &c))) pend_fill(c, p, host_ptr_pop());
  while ((p = pend_oldest(DEV_CONSOLE + CON_IN, &c)) && con_in_ready(p->len)) {
    con_in_fill(c, p->ls, p->len);
    p->on = false;
    npending--;
    slow_events++;
  }
  /* network: the oldest waiting RX read takes the next packet */
  while (net_rx_count() && (p = pend_oldest(DEV_NET + NET_RX, &c))) {
    net_rx_fill(c, p->ls, p->len);
    p->on = false;
    npending--;
    slow_events++;
  }
  if (!npending) return;
  uint64_t now = now_ticks();
  for (int i = 0; i < ncores; i++)
    for (int k = 0; k < NPEND; k++) {
      p = &cores[i].pend[k];
      if (!p->on) continue;
      if (p->port == DEV_TIMER + TMR_WAIT && now >= tmr_deadline) pend_fill(&cores[i], p, now);
      else if (p->port == DEV_FBCTL + FBC_VSYNC && now >= p->target) pend_fill(&cores[i], p, now / FB_FRAME_TICKS);
    }
}

/* One byte written to device space: byte `i` of a transfer starting at `port`. */
static void dev_write(uint64_t port, uint64_t i, uint8_t b) {
  uint64_t a = port + i;
  if (port == DEV_CONSOLE) {
    if (dbg_on) dbg_con_out(b); /* the debugger's console, not its own terminal */
    else fputc(b, stdout);
    return;
  }
  if (port == DEV_CONSOLE + CON_RELEASE) {   /* complete every pending break and input read with 0 */
    Core *c;
    Pending *p;
    while ((p = pend_oldest(DEV_CONSOLE + CON_BREAK, &c))) pend_fill(c, p, 0);
    while ((p = pend_oldest(DEV_CONSOLE + CON_IN, &c))) pend_fill(c, p, 0);
    return;
  }
  if (port == DEV_POINTER + PTR_EVENT) { /* complete every waiting EVENT read with 0 */
    Core *c;
    Pending *p;
    while ((p = pend_oldest(DEV_POINTER + PTR_EVENT, &c))) pend_fill(c, p, 0);
    return;
  }
  if (a >= DEV_TIMER + TMR_DEADLINE && a < DEV_TIMER + TMR_DEADLINE + 8) {
    unsigned j = (unsigned)(a - DEV_TIMER - TMR_DEADLINE);
    tmr_wbuf = (tmr_wbuf & ~(0xffull << (8 * j))) | (uint64_t)b << (8 * j);
    if (j == 7) tmr_deadline = tmr_wbuf; /* pending waits see it at once (pend_service) */
    return;
  }
  if (port == DEV_NET + NET_TX) { net_tx_put(i, b); return; } /* the packet: sent when the transfer ends */
  if (port == DEV_NET + NET_CANCEL) {        /* complete every waiting RX read with zeros */
    Core *c;
    Pending *p;
    while ((p = pend_oldest(DEV_NET + NET_RX, &c))) pend_fill(c, p, 0);
    return;
  }
  if (port == DEV_BLK0 + BLK_SQ) {
    sq_buf[sq_fill++] = b;
    if (sq_fill == 32) {
      sq_fill = 0;
      if (sq_cnt < (int)BLK_QDEPTH) {
        memcpy(sq_cmds[(sq_head + sq_cnt) % BLK_QDEPTH], sq_buf, 32);
        sq_cnt++;
      }
      blk_run();
    }
  }
}

/* One byte read from device space: byte `i` of a transfer starting at `port`
 * (the waiting ports are handled by the caller). */
static uint8_t dev_read(uint64_t port, uint64_t i) {
  uint64_t a = port + i;
  if (a >= DEV_TIMER && a < DEV_TIMER + TMR_WINDOW) {
    unsigned j = (unsigned)(a & 7);
    switch ((a - DEV_TIMER) & ~7ull) {
    case TMR_NOW: if (j == 0) tmr_lnow = now_ticks(); return (uint8_t)(tmr_lnow >> (8 * j));
    case TMR_FREQ: return (uint8_t)((uint64_t)TMR_HZ >> (8 * j));
    case TMR_DEADLINE: if (j == 0) tmr_ldl = tmr_deadline; return (uint8_t)(tmr_ldl >> (8 * j));
    default: return 0; /* WAIT other than at the start of a transfer */
    }
  }
  if (a >= DEV_NET + NET_STATUS && a < DEV_NET + NET_STATUS + 8) { /* latched at byte 0 */
    unsigned j = (unsigned)(a & 7);
    if (j == 0) net_lstat = net_status();
    return (uint8_t)(net_lstat >> (8 * j));
  }
  if (a >= DEV_POINTER + PTR_STATE && a < DEV_POINTER + PTR_STATE + 8) {
    unsigned j = (unsigned)(a & 7);
    if (j == 0) ptr_lstate = host_ptr_state();
    return (uint8_t)(ptr_lstate >> (8 * j));
  }
  if (a >= DEV_PLAT && a < DEV_PLAT + PLAT_LEN) return plat_rom[a - DEV_PLAT];
  if (a >= DEV_BLK0 + BLK_IDENT && a < DEV_BLK0 + BLK_IDENT + BLK_IDENT_LEN) return blk_rom[a - DEV_BLK0];
  if (port == DEV_BLK0 + BLK_CQ) {
    if (!cq_cnt) return 0; /* an empty completion queue reads as zeros */
    uint8_t v = cq[cq_head][cq_byte++];
    if (cq_byte == 16) { cq_byte = 0; cq_head = (cq_head + 1) % BLK_QDEPTH; cq_cnt--; blk_run(); }
    return v;
  }
  return 0;
}

static void fatal(Core *c, int cause, uint64_t tval, bool dbl) {
  if (!dbg_muted) fprintf(stderr, "core %d: %sfault %s pc=0x%llx tval=0x%llx\n", c->id, dbl ? "double " : "",
          stx_cause_name(cause), (unsigned long long)c->pc, (unsigned long long)tval);
  c->halted = true;
  faulted = true;
}

/* A trap in user mode goes to the program's own handler (utvec) when it
 * installed one and the cause is its business; halts, interrupts, privilege
 * violations and anything without a user handler go to the supervisor. */
static void trap(Core *c, int cause, uint64_t tval) {
  if (dbg_on) dbg_trap(c, cause, tval);
  if (c->user) {
    bool to_s = cause == C_HALT || cause == C_STOP || cause == C_PRIV || cause == C_SVC || c->u_tvec == 0 ||
                c->pc == c->u_tvec;
    if (!to_s) {
      c->u_epc = c->pc;
      c->u_cause = (uint64_t)cause;
      c->u_tval = tval;
      c->pc = c->u_tvec;
      return;
    }
    c->s_epc = c->pc;
    c->s_cause = (uint64_t)cause;
    c->s_tval = tval;
    c->spp_user = true;
    c->user = false;
    if (c->s_tvec == 0) { fatal(c, cause, tval, false); return; }
    c->pc = c->s_tvec;
    return;
  }
  bool dbl = c->s_tvec != 0 && c->pc == c->s_tvec; /* the handler's first instruction faulted */
  c->s_epc = c->pc;
  c->s_cause = (uint64_t)cause;
  c->s_tval = tval;
  c->spp_user = false;
  if (c->s_tvec == 0 || dbl) fatal(c, cause, tval, dbl);
  else c->pc = c->s_tvec;
}

static void retire(Core *c, uint64_t npc) {
  c->pc = npc;
  c->instret++;
}

static uint64_t alu(unsigned op, uint64_t a, uint64_t b) {
  switch (op) {
  case ALU_ADD: return a + b;
  case ALU_SUB: return a - b;
  case ALU_AND: return a & b;
  case ALU_OR: return a | b;
  case ALU_XOR: return a ^ b;
  case ALU_SLL: return a << (b & 63);
  case ALU_SRL: return a >> (b & 63);
  case ALU_SRA: return (uint64_t)((int64_t)a >> (b & 63));
  case ALU_SLT: return (int64_t)a < (int64_t)b;
  case ALU_SLTU: return a < b;
  case ALU_MUL: return a * b;
  case ALU_MULHU: return (uint64_t)(((unsigned __int128)a * b) >> 64);
  case ALU_DIVU: return b ? a / b : ~0ull;
  case ALU_REMU: return b ? a % b : a;
  case ALU_DIV:
    if (!b) return ~0ull;
    if (a == 0x8000000000000000ull && b == ~0ull) return a;
    return (uint64_t)((int64_t)a / (int64_t)b);
  case ALU_REM:
    if (!b) return a;
    if (a == 0x8000000000000000ull && b == ~0ull) return 0;
    return (uint64_t)((int64_t)a % (int64_t)b);
  }
  return 0;
}

/* ------------------------------------------------------------ one instruction */

/* The tags of c's in-flight (pending) device reads. */
static uint64_t tag_busy(const Core *c) {
  uint64_t m = 0;
  for (int i = 0; i < NPEND; i++)
    if (c->pend[i].on) m |= 1ull << c->pend[i].tag;
  return m;
}

static void dec_invalidate(Core *c, uint64_t ls, uint64_t len); /* the fast loop's decode cache, below */

/* Executes one instruction. Returns false if the core is blocked (nothing happened). */
static bool step(Core *c) {
  if (c->user && c->ipend) { c->ipend = false; trap(c, C_STOP, 0); return true; }
  if (c->pc & 3 || c->pc >= ILS_BYTES) { trap(c, C_IFAULT, c->pc); return true; }
  uint32_t ir;
  memcpy(&ir, c->ils + c->pc, 4);
  if (trace && !c->traced) fprintf(trace, "%d %08llx %08x\n", c->id, (unsigned long long)c->pc, ir);
  c->traced = true;

  unsigned op = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31;
  unsigned funct = ir & 0x7ff, imm16 = ir & 0xffff;
  uint64_t simm = (uint64_t)sext(imm16, 16), zimm = imm16;
  uint64_t a = c->x[rs1], b = c->x[rs2];
  uint64_t npc = c->pc + 4;

  switch (op) {
  case OP_ALU:
    if (funct >> 4) { trap(c, C_ILLEGAL, ir); return true; }
    setx(c, rd, alu(funct & 15, a, b));
    break;
  case OP_ADDI: setx(c, rd, a + simm); break;
  case OP_SLTI: setx(c, rd, (int64_t)a < (int64_t)simm); break;
  case OP_SLTIU: setx(c, rd, a < simm); break;
  case OP_ANDI: setx(c, rd, a & zimm); break;
  case OP_ORI: setx(c, rd, a | zimm); break;
  case OP_XORI: setx(c, rd, a ^ zimm); break;
  case OP_SLLI: setx(c, rd, a << (imm16 & 63)); break;
  case OP_SRLI: setx(c, rd, a >> (imm16 & 63)); break;
  case OP_SRAI: setx(c, rd, (uint64_t)((int64_t)a >> (imm16 & 63))); break;
  case OP_LUI: setx(c, rd, simm << 16); break;

  case OP_LD: case OP_LW: case OP_LWU: case OP_LH: case OP_LHU: case OP_LB: case OP_LBU:
  case OP_SD: case OP_SW: case OP_SH: case OP_SB: {
    bool store = op >= OP_SD;
    int lg = store ? 3 - (int)(op - OP_SD)
                   : op == OP_LD ? 3 : op <= OP_LWU ? 2 : op <= OP_LHU ? 1 : 0;
    uint64_t sz = 1ull << lg;
    uint64_t base = store ? c->x[rs1] : a;
    uint64_t addr = base + simm;
    if (addr > DLS_BYTES - sz || (addr & (sz - 1))) { trap(c, C_LSFAULT, addr); return true; }
    for (int i = 0; i < NPEND; i++)
      if (c->pend[i].on && addr < c->pend[i].ls + c->pend[i].len && c->pend[i].ls < addr + sz) {
        if (c->ccr & 1) { trap(c, C_PEND, addr); return true; } /* CCR.PTRAP: trap instead of waiting */
        return false; /* the bytes are still in flight */
      }
    if (store) {
      uint64_t v = c->x[rd];
      memcpy(c->dls + addr, &v, sz);
    } else {
      uint64_t v = 0;
      memcpy(&v, c->dls + addr, sz);
      bool sgn = op == OP_LW || op == OP_LH || op == OP_LB;
      if (sgn && lg < 3) v = (uint64_t)sext(v, 8 << lg);
      setx(c, rd, v);
    }
    break;
  }

  case OP_BEQ: case OP_BNE: case OP_BLT: case OP_BGE: case OP_BLTU: case OP_BGEU: {
    uint64_t x1 = c->x[rd], x2 = c->x[rs1];
    bool t = false;
    switch (op) {
    case OP_BEQ: t = x1 == x2; break;
    case OP_BNE: t = x1 != x2; break;
    case OP_BLT: t = (int64_t)x1 < (int64_t)x2; break;
    case OP_BGE: t = (int64_t)x1 >= (int64_t)x2; break;
    case OP_BLTU: t = x1 < x2; break;
    case OP_BGEU: t = x1 >= x2; break;
    }
    if (t) npc = c->pc + (simm << 2);
    break;
  }
  case OP_JAL:
    setx(c, rd, c->pc + 4);
    npc = c->pc + ((uint64_t)sext(ir & 0x1fffff, 21) << 2);
    break;
  case OP_JALR:
    npc = (a + simm) & ~3ull;
    setx(c, rd, c->pc + 4);
    break;

  case OP_XFER: {
    unsigned sub = (ir >> 23) & 7, rl = (ir >> 14) & 31, ci = (ir >> 10) & 15, ro = (ir >> 5) & 31,
             rn = ir & 31;
    if (sub > XF_GETX) { trap(c, C_ILLEGAL, ir); return true; }
    Cap *k = &c->caps[ci];
    uint64_t ls = c->x[rl], off = c->x[ro], len = c->x[rn];
    uint8_t need = sub == XF_GET ? P_R : sub == XF_PUT ? P_W : P_X;
    uint64_t limit = sub == XF_GETX ? ILS_BYTES : DLS_BYTES;
    int f = 0;
    if (!live(*k)) f = C_CAPINV;
    else if (!(k->perms & need)) f = C_PERM;
    else if (k->space == SP_EP) f = C_PERM;
    else if ((k->space == SP_DEV || k->space == SP_CORE) && sub == XF_GETX) f = C_PERM;
    else if (k->space == SP_CORE && sub != XF_PUT) f = C_PERM;
    else if (k->space != SP_DEV && ((ls | off | len) & 7)) f = C_XALIGN;
    else if (k->space == SP_DEV ? off >= k->len /* a device offset names a port */
                                : (off > k->len || len > k->len - off)) f = C_BOUNDS;
    else if (ls > limit || len > limit - ls) f = C_LSFAULT;
    if (f) { trap(c, f, f == C_LSFAULT ? ls : off); return true; }
    /* a transfer whose D-LS bytes overlap an in-flight device read waits for
     * it (it is ordered after the read), as loads and stores do */
    if (sub != XF_GETX && len)
      for (int i = 0; i < NPEND; i++)
        if (c->pend[i].on && ls < c->pend[i].ls + c->pend[i].len && c->pend[i].ls < ls + len) {
          if (c->ccr & 1) { trap(c, C_PEND, ls); return true; } /* CCR.PTRAP: trap instead of waiting */
          return false;
        }
    unsigned tg = (ir >> 19) & 15;
    if (tag_busy(c) >> tg & 1) return false; /* the tag is still in flight: the issue waits */
    uint64_t far = k->base + off;
    if (sub == XF_GETX) { /* code being replaced: forget overlay mappings that point into it */
      jit_invalidate(c->id, ls, len); /* and its translations */
      dec_invalidate(c, ls, len);
      uint64_t sl = c->xslot ? 1ull << c->xslot : 4;
      for (int i = 0; i < NXMAP; i++)
        if (c->xm_v[i] && c->xm_ils[i] < ls + len && ls < c->xm_ils[i] + sl) c->xm_v[i] = false;
    }
    if (k->space == SP_CORE) { /* core control: a word with bit 0 set interrupts that core */
      for (uint64_t i = 0; i < len; i += 8) {
        uint64_t n = (far + i) / 8;
        if (n < (uint64_t)ncores && (rd64(c->dls + ls + i) & 1)) cores[n].ipend = true;
      }
    } else if (k->space == SP_DEV && sub == XF_GET && len &&
               (far == DEV_CONSOLE + CON_IN || far == DEV_CONSOLE + CON_BREAK ||
                far == DEV_TIMER + TMR_WAIT || far == DEV_FBCTL + FBC_VSYNC || far == DEV_POINTER + PTR_EVENT ||
                far == DEV_NET + NET_RX)) {
      /* a read that may have to wait: it completes now if it can, else stays in flight */
      Pending p = {true, (int)tg, ls, len, far, 0, pend_seq++};
      uint64_t now = 0;
      if (far == DEV_CONSOLE + CON_IN) fflush(stdout);
      if (far == DEV_TIMER + TMR_WAIT || far == DEV_FBCTL + FBC_VSYNC) now = now_ticks();
      if (far == DEV_FBCTL + FBC_VSYNC) p.target = (now / FB_FRAME_TICKS + 1) * FB_FRAME_TICKS;
      bool ready = far == DEV_CONSOLE + CON_IN ? con_in_ready(len)
                 : far == DEV_NET + NET_RX ? net_rx_count() > 0
                 : far == DEV_CONSOLE + CON_BREAK ? host_breaks > 0
                 : far == DEV_POINTER + PTR_EVENT ? host_ptr_ready()
                 : far == DEV_TIMER + TMR_WAIT ? now >= tmr_deadline : false;
      int slot = -1;
      for (int i = 0; i < NPEND && slot < 0; i++)
        if (!c->pend[i].on) slot = i;
      if (!ready && slot < 0) return false; /* too many in flight: the issue waits */
      if (ready) {
        if (far == DEV_CONSOLE + CON_IN) con_in_fill(c, ls, len);
        else if (far == DEV_NET + NET_RX) net_rx_fill(c, ls, len);
        else {
          if (far == DEV_CONSOLE + CON_BREAK) host_breaks--;
          uint64_t v = far == DEV_CONSOLE + CON_BREAK ? 0x0303030303030303ull
                     : far == DEV_POINTER + PTR_EVENT ? host_ptr_pop() : now;
          for (uint64_t i = 0; i < len; i++) c->dls[ls + i] = i < 8 ? (uint8_t)(v >> (8 * i)) : 0;
        }
      } else {
        c->pend[slot] = p;
        npending++;
      }
    } else if (k->space == SP_DEV) {
      for (uint64_t i = 0; i < len; i++) {
        if (sub == XF_PUT) dev_write(far, i, c->dls[ls + i]);
        else c->dls[ls + i] = dev_read(far, i);
      }
      if (sub == XF_PUT && far == DEV_FBCTL + FBC_PRESENT && len) host_present(t3 + FB_BASE);
      if (sub == XF_PUT && far == DEV_NET + NET_TX && len) net_tx_done(len); /* one transfer, one packet */
      fflush(stdout);
    } else {
      for (uint64_t i = 0; i < len; i += 8) {
        uint8_t *fp = far_ptr(k->space, far + i);
        if (sub == XF_PUT) { memcpy(fp, c->dls + ls + i, 8); far_wrote(k->space, far + i); }
        else memcpy((sub == XF_GET ? c->dls : c->ils) + ls + i, fp, 8);
      }
    }
    break;
  }
  /* memory transfers complete at once; only a pending device read keeps a tag busy */
  case OP_TWAIT:
    if (tag_busy(c) & imm16) return false;
    break;
  case OP_TPOLL: setx(c, rd, tag_busy(c) & imm16); break;
  case OP_TANY: { /* wait until any selected source is ready: tags 0-15 idle, bit 16 a gift */
    uint64_t want = a & 0x1ffff, ready = want & 0xffff & ~tag_busy(c);
    if ((want >> 16 & 1) && c->user) { trap(c, C_PRIV, ir); return true; } /* the inbox is the kernel's */
    if (want >> 16 & 1)
      for (int i = 0; i <= ncores; i++)
        if (c->iq_cnt[i]) ready |= 1ull << 16;
    if (want && !ready) return false;
    setx(c, rd, ready);
    break;
  }
  case OP_TAMO: {
    unsigned ci = (funct >> 7) & 15, aop = funct & 7;
    if (aop > AMO_OR || ((funct >> 3) & 15)) { trap(c, C_ILLEGAL, ir); return true; }
    Cap *k = &c->caps[ci];
    int f = 0;
    if (!live(*k)) f = C_CAPINV;
    else if (!(k->perms & P_A)) f = C_PERM;
    else if (a & 7) f = C_XALIGN;
    else if (k->len < 8 || a > k->len - 8) f = C_BOUNDS;
    if (f) { trap(c, f, a); return true; }
    uint8_t *fp = far_ptr(k->space, k->base + a);
    uint64_t old = fp ? rd64(fp) : 0, nw = old;
    switch (aop) {
    case AMO_ADD: nw = old + b; break;
    case AMO_SWAP: nw = b; break;
    case AMO_CAS: nw = old == c->x[rd] ? b : old; break;
    case AMO_AND: nw = old & b; break;
    case AMO_OR: nw = old | b; break;
    }
    if (fp) { wr64(fp, nw); far_wrote(k->space, k->base + a); }
    setx(c, rd, old);
    break;
  }

  case OP_CAP: {
    unsigned fn = funct & 15, slot = (funct >> 5) & 63, cd = rd & 15, cs = rs1 & 15;
    bool cap_rd = fn == CF_MOV || fn == CF_SPLIT || fn == CF_JOIN || fn == CF_SHARE || fn == CF_ATOM ||
                  fn == CF_RESTR || fn == CF_TAKE || fn == CF_CLEAR || fn == CF_RESTORE;
    /* a destination may be overwritten only if it is empty or copyable */
#define DEST_OK(k) (!live(k) || ((k).perms & P_D))
    bool cap_rs = fn == CF_MOV || fn == CF_SPLIT || fn == CF_JOIN || fn == CF_SHARE || fn == CF_ATOM ||
                  fn == CF_RESTR || fn == CF_BASE || fn == CF_LEN || fn == CF_PERMS || fn == CF_VALID ||
                  fn == CF_GIVE || fn == CF_SAVE;
    if (fn > CF_POLL || (cap_rd && (rd & 16)) || (cap_rs && (rs1 & 16))) { trap(c, C_ILLEGAL, ir); return true; }
    Cap s = c->caps[cs], dcap = c->caps[cd];
    bool linear = !(s.perms & P_D);
    switch (fn) {
    case CF_MOV: case CF_RESTR:
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      if (cd != cs && !DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      if (fn == CF_RESTR) s.perms &= (uint8_t)(b & 63);
      c->caps[cd] = s;
      if (cd != cs && linear) c->caps[cs] = (Cap){0};
      break;
    case CF_SPLIT:
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      /* capabilities are 8-byte aligned: the split point must be a multiple of 8 */
      /* a revoker is cut only at granule boundaries */
      if (cd == cs || b > s.len || (b & 7) || ((s.perms & P_V) && (b & GMASK)) || !DEST_OK(dcap)) {
        trap(c, C_CAPOP, b);
        return true;
      }
      c->caps[cd] = (Cap){true, s.space, s.perms, s.base + b, s.len - b, s.rv, s.gen};
      c->caps[cs].len = b;
      break;
    case CF_JOIN:
      if (!live(s) || !live(dcap)) { trap(c, C_CAPINV, cs); return true; }
      /* never across units: revocable pieces join only with the same generation,
       * and not where a unit begins (cs's base on a HEAD granule boundary) */
      if (cd == cs || dcap.space != s.space || dcap.perms != s.perms || dcap.rv != s.rv || dcap.gen != s.gen ||
          dcap.base + dcap.len != s.base || (s.rv && !(s.base & GMASK) && ghead[gidx(s.space, s.base)])) {
        trap(c, C_CAPOP, cs);
        return true;
      }
      c->caps[cd].len += s.len;
      c->caps[cs] = (Cap){0};
      break;
    case CF_SHARE:
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      if (!(s.perms & (P_R | P_X))) { trap(c, C_PERM, cs); return true; }
      if (cd != cs && !DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      c->caps[cd] = (Cap){true, s.space, (uint8_t)((s.perms & (P_R | P_X)) | P_D), s.base, s.len, s.rv, s.gen};
      if (cd != cs && linear) c->caps[cs] = (Cap){0};
      break;
    case CF_ATOM:
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      if (!(s.perms & P_W) || (s.space != SP_T2 && s.space != SP_T3)) { trap(c, C_PERM, cs); return true; }
      if (cd != cs && !DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      c->caps[cd] = (Cap){true, s.space, P_A | P_D, s.base, s.len, s.rv, s.gen};
      if (cd != cs) c->caps[cs] = (Cap){0};
      break;
    case CF_BASE: case CF_LEN: case CF_PERMS:
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      setx(c, rd, fn == CF_BASE ? s.base : fn == CF_LEN ? s.len : (uint64_t)s.space << 8 | s.perms);
      break;
    case CF_VALID: setx(c, rd, live(s)); break;
    case CF_GIVE: {
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      if ((c->user && !c->corecount) || (c->corecount && b >= c->corecount)) { trap(c, C_CAPOP, b); return true; } /* outside the window */
      b += c->corebase;
      if (b > (uint64_t)ncores || (b < (uint64_t)ncores && cores[b].halted)) { trap(c, C_CAPOP, b); return true; }
      if (b == (uint64_t)ncores) { /* node ncores is block device 0 */
        if (bi_cnt == IQ) return false;
        blk_inbox[(bi_head + bi_cnt) % IQ] = (Gift){s, c->id};
        bi_cnt++;
      } else if (!inbox_push(&cores[b], s, c->id)) {
        return false;
      }
      if (linear) c->caps[cs] = (Cap){0};
      if (b == (uint64_t)ncores) blk_run();
      break;
    }
    case CF_TAKE: {
      if (c->user) { trap(c, C_PRIV, ir); return true; } /* user mode: the inbox is the kernel's (it emulates ctake) */
      if (!DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      /* from a named sender, or else the lowest-numbered sender that has one */
      int from = -1;
      if (funct & 16) {
        uint64_t n = b + c->corebase;
        if (n < (uint64_t)MAXNODES && c->iq_cnt[n]) from = (int)n;
      } else {
        for (int i = 0; i <= ncores && from < 0; i++)
          if (c->iq_cnt[i]) from = i;
      }
      if (from < 0) return false;
      c->caps[cd] = c->inbox[from][0];
      for (int i = 1; i < c->iq_cnt[from]; i++) c->inbox[from][i - 1] = c->inbox[from][i];
      c->iq_cnt[from]--;
      c->takefrom = (uint64_t)from - c->corebase;
      break;
    }
    case CF_POLL: {
      if (c->user) { trap(c, C_PRIV, ir); return true; }
      uint64_t m = 0;
      for (int i = 0; i <= ncores; i++) {
        uint64_t f = (uint64_t)i - c->corebase;
        if (c->iq_cnt[i] && f < 64) m |= 1ull << f;
      }
      setx(c, rd, m);
      break;
    }
    case CF_CLEAR: c->caps[cd] = (Cap){0}; break;
    case CF_SAVE:
      if (c->user) { trap(c, C_PRIV, ir); return true; } /* the save table belongs to the supervisor */
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      if (!DEST_OK(c->ctab[slot])) { trap(c, C_CAPOP, slot); return true; }
      c->ctab[slot] = s;
      if (linear) c->caps[cs] = (Cap){0};
      break;
    case CF_RESTORE:
      if (c->user) { trap(c, C_PRIV, ir); return true; }
      if (!live(c->ctab[slot])) { trap(c, C_CAPINV, slot); return true; }
      if (!DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      c->caps[cd] = c->ctab[slot];
      if (!(c->ctab[slot].perms & P_D)) c->ctab[slot] = (Cap){0};
      break;
    }
    break;
  }

  case OP_CSRR: {
    uint64_t v = 0;
    switch (imm16) {
    case CSR_CYCLE: v = c->instret; break; /* the emulator's clock is its instruction count */
    case CSR_INSTRET: v = c->instret; break;
    case CSR_CAUSE: v = c->user ? c->u_cause : c->s_cause; break; /* banked by mode */
    case CSR_EPC: v = c->user ? c->u_epc : c->s_epc; break;
    case CSR_TVAL: v = c->user ? c->u_tval : c->s_tval; break;
    case CSR_TVEC: v = c->user ? c->u_tvec : c->s_tvec; break;
    case CSR_CCR: v = c->ccr; break;
    case CSR_COREID: v = (uint64_t)c->id - c->corebase; break;
    case CSR_TTAG: v = c->ttag; break;
    case CSR_TDATA: v = c->tdata; break;
    case CSR_TGEOM: v = c->tgeom; break;
    case CSR_NCORES: v = c->corecount ? c->corecount : (uint64_t)ncores; break;
    case CSR_SCRATCH: v = c->scratch; break;
    case CSR_STALLS: v = 0; break;
    case CSR_TAKEFROM: v = c->takefrom; break;
    case CSR_COREBASE: v = c->corebase; break;
    case CSR_CORECOUNT: v = c->corecount; break;
    case CSR_STATUS: v = (c->user ? 0 : 1) | (c->spp_user ? 0 : 2); break;
    case CSR_UCAUSE: v = c->u_cause; break;
    case CSR_UEPC: v = c->u_epc; break;
    case CSR_UTVAL: v = c->u_tval; break;
    case CSR_UTVEC: v = c->u_tvec; break;
    case CSR_XSLOT: v = c->xslot; break;
    case CSR_SSCRATCH: case CSR_IPEND:
      if (c->user) { trap(c, C_PRIV, ir); return true; }
      v = imm16 == CSR_SSCRATCH ? c->sscratch : c->ipend;
      break;
    }
    setx(c, rd, v);
    break;
  }
  case OP_CSRW:
    if (c->user && (imm16 == CSR_STATUS || imm16 == CSR_COREBASE || imm16 == CSR_CORECOUNT ||
                    (imm16 >= CSR_UCAUSE && imm16 <= CSR_IPEND))) {
      trap(c, C_PRIV, ir); /* supervisor state */
      return true;
    }
    switch (imm16) {
    case CSR_CAUSE: if (c->user) c->u_cause = a; else c->s_cause = a; break;
    case CSR_EPC: if (c->user) c->u_epc = a; else c->s_epc = a; break;
    case CSR_TVAL: if (c->user) c->u_tval = a; else c->s_tval = a; break;
    case CSR_TVEC: if (c->user) c->u_tvec = a; else c->s_tvec = a; break;
    case CSR_CCR: c->ccr = a; break;
    case CSR_TTAG: c->ttag = a; break;
    case CSR_TDATA: c->tdata = a; break;
    case CSR_TGEOM: c->tgeom = a; break;
    case CSR_SCRATCH: c->scratch = a; break;
    case CSR_COREBASE: c->corebase = a; break;
    case CSR_CORECOUNT: c->corecount = a; break;
    case CSR_STATUS: c->spp_user = !(a & 2); break; /* bit 1: eret returns to supervisor */
    case CSR_UCAUSE: c->u_cause = a; break;
    case CSR_UEPC: c->u_epc = a; break;
    case CSR_UTVAL: c->u_tval = a; break;
    case CSR_UTVEC: c->u_tvec = a; break;
    case CSR_SSCRATCH: c->sscratch = a; break;
    case CSR_IPEND: c->ipend = a & 1; break;
    case CSR_XSLOT: c->xslot = a & 63; break;
    }
    break;

  case OP_SYS:
    if (imm16 == SYS_HALT && tag_busy(c)) return false; /* halt drains the core's transfers first */
    if (imm16 == SYS_HALT && c->user) { trap(c, C_HALT, 0); return true; } /* back to the supervisor */
    if (imm16 == SYS_HALT) {
      c->instret++;
      c->halted = true;
      if (!dbg_muted) fprintf(stderr, "core %d: halt a0=%lld instret=%llu\n", c->id, (long long)c->x[10],
              (unsigned long long)c->instret);
      return true;
    }
    if (imm16 == SYS_SVC) { trap(c, c->user ? C_SVC : C_ILLEGAL, c->user ? 0 : ir); return true; }
    if (imm16 == SYS_ERET) {
      if (c->user) { npc = c->u_epc; break; }
      npc = c->s_epc;
      c->user = c->spp_user;
      break;
    }
    trap(c, C_ILLEGAL, ir);
    return true;

  case OP_LTAG: case OP_LINST: {
    unsigned lsh = c->tgeom & 63, lsets = (c->tgeom >> 6) & 63, ways = (c->tgeom >> 12) & 15;
    uint64_t line = a >> lsh, set = line & ((1ull << lsets) - 1), span = ((uint64_t)ways + 1) * 8;
    uint64_t eb = c->ttag + set * span, key = line << 1 | 1;
    if (!ways || (eb & 7) || eb > DLS_BYTES - span) { trap(c, C_LSFAULT, eb); return true; }
    for (int i = 0; i < NPEND; i++) /* the set's entry overlaps an in-flight device read: wait (or pend) */
      if (c->pend[i].on && eb < c->pend[i].ls + c->pend[i].len && c->pend[i].ls < eb + span) {
        if (c->ccr & 1) { trap(c, C_PEND, eb); return true; }
        return false;
      }
    uint64_t ctr = rd64(c->dls + eb + 8ull * ways), victim = ctr < ways ? ctr : 0;
    if (op == OP_LTAG) {
      uint64_t res = c->tdata + ((set * ways + victim) << lsh) | 0x8000000000000000ull;
      for (unsigned w = 0; w < ways; w++)
        if (rd64(c->dls + eb + 8ull * w) == key) {
          res = c->tdata + ((set * ways + w) << lsh) + (a & ((1ull << lsh) - 1));
          break;
        }
      setx(c, rd, res);
    } else {
      wr64(c->dls + eb + 8 * victim, key);
      wr64(c->dls + eb + 8ull * ways, victim + 1 == ways ? 0 : victim + 1);
    }
    break;
  }

  case OP_XMAP: {
    unsigned idx = rd, ci = funct & 15;
    if (rd >= nxmap) { trap(c, C_ILLEGAL, ir); return true; }
    if (funct & 16) { c->xm_v[idx] = false; break; }
    Cap *k = &c->caps[ci];
    if (!live(*k)) { trap(c, C_CAPINV, ci); return true; }
    if (!(k->perms & P_X)) { trap(c, C_PERM, ci); return true; }
    if (b >= k->len) { trap(c, C_BOUNDS, b); return true; }
    /* with xslot = n the far address must start a 2^n-byte slot */
    if (c->xslot && ((k->base + b) & ((1ull << c->xslot) - 1))) { trap(c, C_XALIGN, b); return true; }
    if ((a & 3) || a >= ILS_BYTES) { trap(c, C_LSFAULT, a); return true; }
    c->xm_v[idx] = true;
    c->xm_sp[idx] = k->space;
    c->xm_far[idx] = k->base + b;
    c->xm_ils[idx] = a;
    break;
  }
  case OP_XCALL: {
    /* With xslot = 0 a map entry matches one far address exactly. With
     * xslot = n it covers the 2^n-byte slot holding its far address (xmap
     * made it a multiple of 2^n; the low bits of an entry made under a
     * smaller xslot are ignored): any far address in the slot hits, at the
     * same offset in the I-LS slot. A call made from inside a mapped unit
     * links to a far return address (bit 63 set) that xret resolves later,
     * so the caller may be evicted meanwhile. */
    unsigned sh = (unsigned)c->xslot;
    uint64_t lo = (1ull << sh) - 1; /* the offset in a slot */
    uint64_t key;
    if (funct & 16) { /* xret rs1 */
      if (!(a >> 63)) { npc = a & ~3ull; break; }
      key = a & ~(1ull << 63);
      int hit = -1;
      for (int i = 0; i < NXMAP && hit < 0; i++)
        if (c->xm_v[i] && key >> sh == c->xm_far[i] >> sh) hit = i;
      if (hit < 0) { trap(c, C_XMISS, a); return true; }
      npc = c->xm_ils[hit] + (key & lo);
      break;
    }
    unsigned ci = funct & 15;
    Cap *k = &c->caps[ci];
    if (!live(*k)) { trap(c, C_CAPINV, ci); return true; }
    if (!(k->perms & P_X)) { trap(c, C_PERM, ci); return true; }
    if (a >= k->len) { trap(c, C_BOUNDS, a); return true; }
    key = k->base + a;
    int hit = -1;
    for (int i = 0; i < NXMAP && hit < 0; i++)
      if (c->xm_v[i] && c->xm_sp[i] == k->space && key >> sh == c->xm_far[i] >> sh) hit = i;
    if (hit < 0) { trap(c, C_XMISS, key); return true; }
    uint64_t link = c->pc + 4;
    if (c->xslot)
      for (int i = 0; i < NXMAP; i++)
        if (c->xm_v[i] && c->pc >= c->xm_ils[i] && c->pc - c->xm_ils[i] <= lo) {
          link = (1ull << 63) | ((c->xm_far[i] & ~lo) + (c->pc + 4 - c->xm_ils[i]));
          break;
        }
    setx(c, rd, link);
    npc = c->xm_ils[hit] + (key & lo);
    break;
  }

  case OP_CAP2: {
    unsigned fn = funct & 15, cd = rd & 15, cs = rs1 & 15;
    if ((rd | rs1) & 16 || fn > C2_RESTOREX) { trap(c, C_ILLEGAL, ir); return true; }
    if (c->user && fn != C2_SEND && fn != C2_RECV) { trap(c, C_PRIV, ir); return true; }
    Cap s = c->caps[cs], dcap = c->caps[cd];
    switch (fn) {
    case C2_DOM: { /* make a region revocable: cd = working capability, cs becomes its revoker */
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      if (cd == cs || !(s.perms & P_W) || (s.perms & P_D) || s.rv || (s.space != SP_T2 && s.space != SP_T3) ||
          !s.len || ((s.base | s.len) & GMASK) || !DEST_OK(dcap)) { trap(c, C_CAPOP, cs); return true; }
      int a = gidx(s.space, s.base), n = (int)(s.len >> GRAN_SHIFT), end = s.space == SP_T3 ? (int)NGRAN3 : (int)(NGRAN3 + NGRAN2);
      uint16_t m = 0;
      for (int k = a; k < a + n; k++)
        if (ggen[k] > m) m = ggen[k];
      m++; /* one generation for the whole region, newer than any of its granules had */
      for (int k = a; k < a + n; k++) {
        ggen[k] = m;
        ghead[k] = k == a;
      }
      if (a + n < end) ghead[a + n] = true; /* a unit ends here */
      c->caps[cd] = (Cap){true, s.space, s.perms, s.base, s.len, true, m};
      c->caps[cs] = (Cap){true, s.space, P_V, s.base, s.len, false, s.perms};
      break;
    }
    case C2_REVOKE: case C2_UNDOM: { /* kill every revocable capability based in the revoker's range */
      if (!revoker(s)) { trap(c, C_CAPINV, cs); return true; }
      if (cd == cs || !DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      if (!s.len) { trap(c, C_CAPOP, cs); return true; }
      int a = gidx(s.space, s.base);
      uint16_t g = revoke_units(a, a + (int)(s.len >> GRAN_SHIFT));
      if (fn == C2_REVOKE) {
        c->caps[cd] = (Cap){true, s.space, (uint8_t)(s.gen & 63), s.base, s.len, true, g};
      } else {
        c->caps[cd] = (Cap){true, s.space, (uint8_t)(s.gen & 63), s.base, s.len, false, 0};
        c->caps[cs] = (Cap){0};
      }
      break;
    }
    case C2_SEND: { /* csend cs, ce (ce in the rd field): give cs to the node ce names */
      Cap e = dcap, g = s;
      unsigned src = cs;
      if (!live(e) || e.space != SP_EP || !(e.perms & P_W)) { trap(c, C_CAPINV, cd); return true; }
      if (!live(g)) { trap(c, C_CAPINV, src); return true; }
      uint64_t n = e.base;
      if (n > (uint64_t)ncores || (n < (uint64_t)ncores && cores[n].halted)) { trap(c, C_CAPOP, n); return true; }
      if (n == (uint64_t)ncores) {
        if (bi_cnt == IQ) return false;
        blk_inbox[(bi_head + bi_cnt) % IQ] = (Gift){g, c->id};
        bi_cnt++;
      } else if (!inbox_push(&cores[n], g, c->id)) {
        return false;
      }
      if (!(g.perms & P_D)) c->caps[src] = (Cap){0};
      if (n == (uint64_t)ncores) blk_run();
      break;
    }
    case C2_RECV: { /* crecv cd, ce: take only from the node ce names */
      Cap e = s;
      if (!live(e) || e.space != SP_EP || !(e.perms & P_R)) { trap(c, C_CAPINV, cs); return true; }
      if (!DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      uint64_t n = e.base;
      if (n >= (uint64_t)MAXNODES || !c->iq_cnt[n]) return false;
      c->caps[cd] = c->inbox[n][0];
      for (int i = 1; i < c->iq_cnt[n]; i++) c->inbox[n][i - 1] = c->inbox[n][i];
      c->iq_cnt[n]--;
      c->takefrom = n - c->corebase;
      break;
    }
    case C2_MKEP: /* cmkep cd, rx: an endpoint for node x[rx] (send and receive, copyable) */
      if (!DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      if (b > (uint64_t)ncores) { trap(c, C_CAPOP, b); return true; }
      c->caps[cd] = (Cap){true, SP_EP, P_R | P_W | P_D, b, 1, 0, 0};
      break;
    case C2_SAVEX: /* csavex cs, rx: csave with the slot in x[rx], any slot of the table */
      if (b >= ctab_size) { trap(c, C_CAPOP, b); return true; }
      if (!live(s)) { trap(c, C_CAPINV, cs); return true; }
      if (!DEST_OK(c->ctab[b])) { trap(c, C_CAPOP, b); return true; }
      c->ctab[b] = s;
      if (!(s.perms & P_D)) c->caps[cs] = (Cap){0};
      break;
    case C2_RESTOREX: /* crestorex cd, rx: crestore from slot x[rx] */
      if (b >= ctab_size) { trap(c, C_CAPOP, b); return true; }
      if (!live(c->ctab[b])) { trap(c, C_CAPINV, b); return true; }
      if (!DEST_OK(dcap)) { trap(c, C_CAPOP, cd); return true; }
      c->caps[cd] = c->ctab[b];
      if (!(c->ctab[b].perms & P_D)) c->ctab[b] = (Cap){0};
      break;
    }
    break;
  }

  default: trap(c, C_ILLEGAL, ir); return true;
  }
  retire(c, npc);
  return true;
}

/* ------------------------------------------------------------ the fast loop */

/* The plain integer instructions (ALU, immediates, D-LS loads and stores,
 * branches, jal, jalr: the subset the JIT translates) have no effect
 * outside their core's registers, pc and D-LS. run_fast() executes a run
 * of them from a predecoded copy of the I-LS, several times faster than
 * step(): each I-LS word is decoded once into a Dec record (a handler
 * number and the operand fields), and the loop only dispatches on it.
 * It stops in front of everything else, and in front of a load or store
 * that would fault, with the core exactly as step() would have left it;
 * the caller then calls step(). The caller must not use it while the core
 * has a pending stop in user mode, or while tracing.
 *
 * Loads and stores must wait for the bytes of a device read still in
 * flight (step() does the waiting). hazard_set() records one range that
 * covers all of the core's pending reads, widened by 7 bytes downwards so
 * that one unsigned compare of the address does for every access size; the
 * fast loop, and code translated by the WebAssembly JIT, leave an access
 * that falls into it to step(), which checks exactly. The range can only
 * shrink while plain instructions run, and its bytes change only when a
 * read completes, which nothing outside the range can see.
 *
 * A record is decoded on first use and forgotten when tgetx overwrites its
 * word (dec_invalidate, next to jit_invalidate). */
enum {
  D_UNDEC = 0, /* not decoded yet */
  D_SLOW,      /* for step() */
  D_NOP,       /* a plain instruction whose only effect would be on x0 */
  D_ALU,       /* D_ALU + ALU_ADD .. D_ALU + ALU_REM */
  D_ADDI = D_ALU + 16, D_ANDI, D_ORI, D_XORI, D_SLLI, D_SRLI, D_SRAI, D_SLTI, D_SLTIU, D_LI,
  D_LD, D_LW, D_LWU, D_LH, D_LHU, D_LB, D_LBU, D_SD, D_SW, D_SH, D_SB,
  D_BEQ, D_BNE, D_BLT, D_BGE, D_BLTU, D_BGEU,
  D_JAL, D_J, D_JALR, D_JR, /* D_J, D_JR: the link register is x0 */
};
typedef struct {
  uint8_t h, rd, rs1, rs2;
  int32_t imm; /* the immediate as the handler wants it; a branch's or jal's target pc */
} Dec;
#define ILS_WORDS (ILS_BYTES / 4)
static Dec *dec_tab[MAXCORES]; /* ILS_WORDS records and a D_SLOW sentinel past the end */

static void dec_one(Dec *d, uint32_t ir, uint64_t pc) {
  unsigned op = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31;
  unsigned funct = ir & 0x7ff, imm16 = ir & 0xffff;
  int32_t simm = (int32_t)sext(imm16, 16);
  d->rd = (uint8_t)rd, d->rs1 = (uint8_t)rs1, d->rs2 = (uint8_t)rs2;
  d->imm = simm;
  d->h = D_SLOW;
  switch (op) {
  case OP_ALU:
    if (!(funct >> 4)) d->h = (uint8_t)(rd ? D_ALU + (funct & 15) : D_NOP);
    break;
  case OP_ADDI: d->h = D_ADDI; break;
  case OP_SLTI: d->h = D_SLTI; break;
  case OP_SLTIU: d->h = D_SLTIU; break;
  case OP_ANDI: d->h = D_ANDI, d->imm = (int32_t)imm16; break;
  case OP_ORI: d->h = D_ORI, d->imm = (int32_t)imm16; break;
  case OP_XORI: d->h = D_XORI, d->imm = (int32_t)imm16; break;
  case OP_SLLI: d->h = D_SLLI, d->imm = (int32_t)(imm16 & 63); break;
  case OP_SRLI: d->h = D_SRLI, d->imm = (int32_t)(imm16 & 63); break;
  case OP_SRAI: d->h = D_SRAI, d->imm = (int32_t)(imm16 & 63); break;
  case OP_LUI: d->h = D_LI, d->imm = (int32_t)((uint32_t)simm << 16); break;
  case OP_LD: case OP_LW: case OP_LWU: case OP_LH: case OP_LHU: case OP_LB: case OP_LBU:
    if (rd) d->h = (uint8_t)(D_LD + (op - OP_LD)); /* a load into x0 can still fault: step() */
    return;
  case OP_SD: case OP_SW: case OP_SH: case OP_SB: d->h = (uint8_t)(D_SD + (op - OP_SD)); return;
  case OP_BEQ: case OP_BNE: case OP_BLT: case OP_BGE: case OP_BLTU: case OP_BGEU:
    d->h = (uint8_t)(D_BEQ + (op - OP_BEQ));
    d->imm = (int32_t)((int64_t)pc + ((int64_t)simm << 2));
    return;
  case OP_JAL:
    d->h = rd ? D_JAL : D_J;
    d->imm = (int32_t)((int64_t)pc + (sext(ir & 0x1fffff, 21) << 2));
    return;
  case OP_JALR: d->h = rd ? D_JALR : D_JR; return;
  default: return;
  }
  if (d->h != D_SLOW && !rd) d->h = D_NOP; /* ALU and immediates into x0 */
}

/* Sets c's hazard range from its pending device reads: an access at
 * `addr` (of up to 8 bytes) may touch one iff addr - hz_base < hz_span. */
static void hazard_set(Core *c) {
  uint64_t lo = UINT64_MAX, hi = 0;
  for (int i = 0; i < NPEND; i++)
    if (c->pend[i].on && c->pend[i].len) {
      if (c->pend[i].ls < lo) lo = c->pend[i].ls;
      if (c->pend[i].ls + c->pend[i].len > hi) hi = c->pend[i].ls + c->pend[i].len;
    }
  if (lo >= hi) { c->hz_base = c->hz_span = 0; return; }
  c->hz_base = lo - 7; /* may wrap: the compare is modular */
  c->hz_span = hi - lo + 7;
}

/* tgetx has overwritten the I-LS range [ls, ls + len) of core c. */
static void dec_invalidate(Core *c, uint64_t ls, uint64_t len) {
  Dec *tab = dec_tab[c->id];
  if (!tab || !len) return;
  for (uint64_t w = ls / 4; w < (ls + len + 3) / 4 && w < ILS_WORDS; w++) tab[w].h = D_UNDEC;
}

/* Runs up to `max` plain instructions of core c. Returns how many it
 * retired; 0 means the instruction at pc is one for step(). With
 * `stop_back` it also returns after a taken backward branch or jump (the
 * JIT counts those to find hot code). */
static uint64_t run_fast(Core *c, uint64_t max, bool stop_back) {
  if (!max || (c->pc & 3) || c->pc >= ILS_BYTES) return 0;
  Dec *tab = dec_tab[c->id];
  if (!tab) {
    tab = dec_tab[c->id] = calloc(ILS_WORDS + 1, sizeof(Dec));
    if (!tab) { perror("strata-emu"); exit(2); }
    tab[ILS_WORDS].h = D_SLOW; /* running off the end: step() raises the fetch fault */
  }
  uint64_t *const x = c->x;
  uint8_t *const dls = c->dls;
  Dec *d = tab + c->pc / 4;
  uint64_t left = max, target, addr;
  const uint64_t hz_base = c->hz_base, hz_span = c->hz_span;
#define RD x[d->rd]
#define RS1 x[d->rs1]
#define RS2 x[d->rs2]
#define IMM ((uint64_t)(int64_t)d->imm)
#define PC ((uint64_t)(d - tab) * 4)
/* the D-LS address of a load or store of 2^lg bytes, or leave for step() to fault or wait */
#define ADDR(lg)                                                                       \
  addr = RS1 + IMM;                                                                    \
  if (addr > DLS_BYTES - (1u << (lg)) || (addr & ((1u << (lg)) - 1)) || addr - hz_base < hz_span) goto out
#define LOAD(type, lg) { type v; ADDR(lg); memcpy(&v, dls + addr, sizeof v); RD = (uint64_t)(int64_t)v; } break
#define LOADU(type, lg) { type v; ADDR(lg); memcpy(&v, dls + addr, sizeof v); RD = v; } break
#define STORE(type, lg) { type v = (type)RD; ADDR(lg); memcpy(dls + addr, &v, sizeof v); } break
#define BRANCH(cond) if (cond) { target = IMM; goto taken; } break
  for (;;) {
    switch (d->h) {
    case D_UNDEC: {
      uint32_t ir;
      memcpy(&ir, c->ils + PC, 4);
      dec_one(d, ir, PC);
      continue;
    }
    default: goto out; /* D_SLOW */
    case D_NOP: break;
    case D_ALU + ALU_ADD: RD = RS1 + RS2; break;
    case D_ALU + ALU_SUB: RD = RS1 - RS2; break;
    case D_ALU + ALU_AND: RD = RS1 & RS2; break;
    case D_ALU + ALU_OR: RD = RS1 | RS2; break;
    case D_ALU + ALU_XOR: RD = RS1 ^ RS2; break;
    case D_ALU + ALU_SLL: RD = RS1 << (RS2 & 63); break;
    case D_ALU + ALU_SRL: RD = RS1 >> (RS2 & 63); break;
    case D_ALU + ALU_SRA: RD = (uint64_t)((int64_t)RS1 >> (RS2 & 63)); break;
    case D_ALU + ALU_SLT: RD = (int64_t)RS1 < (int64_t)RS2; break;
    case D_ALU + ALU_SLTU: RD = RS1 < RS2; break;
    case D_ALU + ALU_MUL: RD = RS1 * RS2; break;
    case D_ALU + ALU_MULHU: case D_ALU + ALU_DIVU: case D_ALU + ALU_REMU: case D_ALU + ALU_DIV:
    case D_ALU + ALU_REM:
      RD = alu((unsigned)(d->h - D_ALU), RS1, RS2);
      break;
    case D_ADDI: RD = RS1 + IMM; break;
    case D_ANDI: RD = RS1 & IMM; break;
    case D_ORI: RD = RS1 | IMM; break;
    case D_XORI: RD = RS1 ^ IMM; break;
    case D_SLLI: RD = RS1 << d->imm; break;
    case D_SRLI: RD = RS1 >> d->imm; break;
    case D_SRAI: RD = (uint64_t)((int64_t)RS1 >> d->imm); break;
    case D_SLTI: RD = (int64_t)RS1 < (int64_t)d->imm; break;
    case D_SLTIU: RD = RS1 < IMM; break;
    case D_LI: RD = IMM; break;
    case D_LD: LOADU(uint64_t, 3);
    case D_LW: LOAD(int32_t, 2);
    case D_LWU: LOADU(uint32_t, 2);
    case D_LH: LOAD(int16_t, 1);
    case D_LHU: LOADU(uint16_t, 1);
    case D_LB: LOAD(int8_t, 0);
    case D_LBU: LOADU(uint8_t, 0);
    case D_SD: STORE(uint64_t, 3);
    case D_SW: STORE(uint32_t, 2);
    case D_SH: STORE(uint16_t, 1);
    case D_SB: STORE(uint8_t, 0);
    case D_BEQ: BRANCH(RD == RS1);
    case D_BNE: BRANCH(RD != RS1);
    case D_BLT: BRANCH((int64_t)RD < (int64_t)RS1);
    case D_BGE: BRANCH((int64_t)RD >= (int64_t)RS1);
    case D_BLTU: BRANCH(RD < RS1);
    case D_BGEU: BRANCH(RD >= RS1);
    case D_JAL: RD = PC + 4; /* fall through */
    case D_J: target = IMM; goto taken;
    case D_JALR: target = (RS1 + IMM) & ~3ull; RD = PC + 4; goto taken;
    case D_JR: target = (RS1 + IMM) & ~3ull; goto taken;
    }
    d++;
    if (--left == 0) break;
    continue;
  taken:
    left--;
    if (target >= ILS_BYTES) { /* retired; the next fetch faults in step() */
      c->pc = target;
      c->instret += max - left;
      return max - left;
    }
    {
      Dec *nd = tab + target / 4;
      bool back = nd <= d;
      d = nd;
      if (!left || (stop_back && back)) break;
    }
  }
out:
  c->pc = PC;
  c->instret += max - left;
  return max - left;
#undef RD
#undef RS1
#undef RS2
#undef IMM
#undef PC
#undef ADDR
#undef LOAD
#undef LOADU
#undef STORE
#undef BRANCH
}


/* ------------------------------------------------------------ JIT mode */

/* With the JIT (emu/jit/), a core takes a quantum of up to JIT_QUANTUM
 * steps per round instead of one: translated code runs the plain integer
 * instructions, step() everything else. Only timing-visible behaviour can
 * tell the difference (see the top of this file): linear capabilities make
 * races between cores impossible to express. Tracing (-t) needs the
 * one-instruction interleaving, so it always interprets. */
#ifndef JIT_QUANTUM
#define JIT_QUANTUM 8192
#endif
static bool use_jit;
/* The WebAssembly backend (jit_backend() "wasm"): it translates only hot
 * code and leaves the rest to the fast loop, and its loads and stores
 * check the hazard range (Core.hz_base). */
static bool jit_lazy;

/* Whether the instruction at c's pc talks to another core or a device:
 * gives and takes, the inbox, far atomics, the shared revocation domains,
 * device and core-control transfers. A quantum ends in front of such an
 * instruction, so that a core meets the others only at the start of its
 * turn, after each of them has had a turn too; without that, a core could
 * run thousands of steps ahead before the others start (and, say, find a
 * core that halts in its first steps still running). */
static bool jit_meets_others(const Core *c) {
  if (c->pc & 3 || c->pc >= ILS_BYTES) return false;
  uint32_t ir;
  memcpy(&ir, c->ils + c->pc, 4);
  unsigned op = ir >> 26, fn = ir & 15;
  if (op == OP_XFER) {
    uint8_t sp = c->caps[(ir >> 10) & 15].space;
    return sp == SP_DEV || sp == SP_CORE;
  }
  if (op == OP_CAP) return fn == CF_GIVE || fn == CF_TAKE || fn == CF_POLL;
  return op == OP_TAMO || op == OP_TANY || op == OP_CAP2;
}

/* Runs one quantum of core c. Returns the steps taken; 0 means the core
 * was blocked at once (as when step() returns false). */
static uint64_t run_jit(Core *c) {
  uint64_t done = 0;
  while (done < JIT_QUANTUM && !c->halted) {
    /* A pending stop is taken at the next step. */
    if (!(c->user && c->ipend)) {
      /* Loads and stores wait for the bytes of a device read in flight:
       * the fast loop and the WebAssembly JIT check for them; the native
       * backends do not, so a core with a pending read is left to the
       * fast loop there. */
      bool pend = false;
      for (int i = 0; i < NPEND; i++) pend |= c->pend[i].on;
      hazard_set(c);
      if (!pend || jit_lazy) {
        uint64_t before = c->instret;
        jit_exec(c->id, before + (JIT_QUANTUM - done));
        done += c->instret - before;
        if (done >= JIT_QUANTUM || c->halted) break;
      }
      /* Code the JIT has not translated (the WebAssembly JIT only
       * translates hot code, and counts at backward jumps to find it). */
      if (pend || jit_lazy) {
        uint64_t n = run_fast(c, JIT_QUANTUM - done, jit_lazy);
        done += n;
        if (n) continue;
      }
    }
    if (done && jit_meets_others(c)) break;
    if (!step(c)) break; /* blocked: the core yields the rest of its turn */
    done++;
  }
  return done;
}

/* ------------------------------------------------------------ one round */

/* One machine round: every live core gets a turn (one step, or a quantum
 * with the JIT). main() below and the browser's driver (web/web.c) both
 * run the machine by calling this in a loop; the caller counts the round
 * (rounds++) first. */
enum {
  RND_RAN,      /* some core made progress */
  RND_HALTED,   /* every core has halted */
  RND_IDLE,     /* every live core is blocked on a pending device read: see `idle` */
  RND_DEADLOCK, /* every live core is blocked and nothing can wake one */
};
static unsigned long long mach_steps; /* instructions retired by all cores */
/* What an idle machine waits for: time (the tick `next` at which a WAIT or
 * VSYNC completes), input (console bytes or Ctrl-C), or both. */
static struct { bool timed, input; uint64_t next; } idle;

/* The reference interleaving (no JIT) is one instruction per live core per
 * round, and it stays exactly that; but a core does not have to execute
 * its instruction in the round that accounts for it. Plain instructions
 * touch nothing another core (or a device) can see, and nothing another
 * core does can change what they compute, so a core may run a burst of
 * them ahead with run_fast() and then sit out one round per instruction:
 * lead[i] is how many rounds core i has still to sit out. Whenever it
 * executes anything else it is back in step with the machine, so every
 * instruction with an outside effect happens in the same round, in the
 * same order and at the same instret as without the bursts.
 *   - Not while tracing (the trace is written in round order).
 *   - A user-mode core can be interrupted by another core (core control),
 *     and the interrupt is taken at an exact instruction. So it only runs
 *     ahead over rounds in which no other core can execute anything but
 *     plain instructions (user_burst): every other live core is sitting
 *     out a lead that long, or is blocked with nothing having happened
 *     since that could unblock it (slow_events), and, with the virtual
 *     timer, no timer deadline falls into those rounds. (With the real
 *     timer the round in which a deadline is seen is a matter of host
 *     timing anyway.)
 *   - A device read in flight completes in some later round and changes
 *     its D-LS bytes; the burst stops in front of a load or store that
 *     may touch them (the hazard range), and step() waits as ever.
 * When every core that is not sitting out is blocked, the coming rounds
 * change nothing until the first lead runs out or a pending device read
 * completes: they are counted wholesale, up to the round of the next
 * timer deadline (virtual time; in real time, and for input, a completion
 * is asynchronous anyway and is simply seen at the next real round). */
#define FAST_BURST 4096
static uint64_t lead[MAXCORES];
static bool fast_off;                     /* tracing: every instruction through step() */
static unsigned long long opt_break_at;   /* -b: press Ctrl-C after this many steps (for tests) */
static unsigned long long opt_max_steps;  /* -m: 0 = no limit */

static uint64_t blocked_at[MAXCORES]; /* slow_events when core i last found itself blocked */

/* How many rounds user-mode core i may run ahead (0: none); see above. */
static uint64_t user_burst(int i) {
  if (cores[i].ipend || opt_break_at) return 0; /* (-b presses Ctrl-C at an exact step count) */
  uint64_t n = FAST_BURST;
  for (int j = 0; j < ncores; j++) {
    if (j == i || cores[j].halted) continue;
    if (lead[j]) n = lead[j] + 1 < n ? lead[j] + 1 : n; /* its next real step comes after ours of that round */
    else if (blocked_at[j] != slow_events) return 0;
  }
  if (npending && virtual_time)
    for (int j = 0; j < ncores; j++)
      for (int k = 0; k < NPEND; k++) {
        Pending *p = &cores[j].pend[k];
        uint64_t t = !p->on ? UINT64_MAX : p->port == DEV_TIMER + TMR_WAIT ? tmr_deadline
                     : p->port == DEV_FBCTL + FBC_VSYNC ? p->target : UINT64_MAX;
        if (t >= UINT64_MAX / 100) continue;
        if (t * 100 <= rounds) return 0;
        if (t * 100 - rounds < n) n = t * 100 - rounds; /* the round that sees the deadline is not ours to run early */
      }
  return n;
}

static int round_idle(void);

static int machine_round(void) {
  pend_service();
  bool any_live = false, progress = false;
  uint64_t longest = 0;
  if (use_jit) {
    for (int i = 0; i < ncores; i++) {
      Core *c = &cores[i];
      if (c->halted) continue;
      any_live = true;
      uint64_t n = run_jit(c);
      if (n) { progress = true; mach_steps += n; longest = n > longest ? n : longest; }
    }
    if (longest > 1) rounds += longest - 1; /* JIT: a round took that many steps */
  } else {
    int nlive = 0, nlead = 0;
    bool stepped = false;
    uint64_t minlead = UINT64_MAX;
    for (int i = 0; i < ncores; i++) nlive += !cores[i].halted;
    any_live = nlive > 0;
    for (int i = 0; i < ncores; i++) {
      Core *c = &cores[i];
      if (c->halted) continue;
      if (!lead[i]) {
        uint64_t n = 0;
        if (!fast_off) {
          uint64_t burst = !c->user ? FAST_BURST : nlive == 1 ? (c->ipend ? 0 : FAST_BURST) : user_burst(i);
          if (burst) {
            hazard_set(c);
            n = run_fast(c, burst, false);
          }
        }
        if (!n) {
          if (step(c)) { progress = stepped = true; c->traced = false; mach_steps++; slow_events++; }
          else blocked_at[i] = slow_events;
          continue;
        }
        lead[i] = n;
      }
      lead[i]--; /* this round's instruction of core i (already executed) */
      progress = true;
      mach_steps++;
      nlead++;
      if (lead[i] < minlead) minlead = lead[i];
    }
    if (nlead && !stepped && minlead) {
      /* the next minlead rounds: nlead instructions each, nothing else */
      uint64_t m = minlead, n = (uint64_t)nlead;
      if (npending && virtual_time) /* the first round that sees a deadline must be a real one */
        for (int i = 0; i < ncores; i++)
          for (int k = 0; k < NPEND; k++) {
            Pending *p = &cores[i].pend[k];
            uint64_t t = !p->on ? UINT64_MAX : p->port == DEV_TIMER + TMR_WAIT ? tmr_deadline
                         : p->port == DEV_FBCTL + FBC_VSYNC ? p->target : UINT64_MAX;
            if (t >= UINT64_MAX / 100) continue;
            uint64_t due = t * 100; /* the first round with now_ticks() >= t */
            m = due <= rounds + 1 ? 0 : due - rounds - 1 < m ? due - rounds - 1 : m;
          }
      /* -b and -m act at the round in which the step count reaches them */
      if (opt_break_at && mach_steps < opt_break_at && (opt_break_at - mach_steps + n - 1) / n < m)
        m = (opt_break_at - mach_steps + n - 1) / n;
      if (opt_max_steps && mach_steps < opt_max_steps && (opt_max_steps - mach_steps + n - 1) / n < m)
        m = (opt_max_steps - mach_steps + n - 1) / n;
      if ((opt_break_at && mach_steps >= opt_break_at) || (opt_max_steps && mach_steps >= opt_max_steps)) m = 0;
      rounds += m;
      mach_steps += m * n;
      for (int i = 0; i < ncores; i++)
        if (!cores[i].halted && lead[i] >= m) lead[i] -= m;
    }
  }
  if (!any_live) return RND_HALTED;
  if (progress) return RND_RAN;
  return round_idle();
}

/* Every live core is blocked. That is a deadlock unless a pending device
 * read can still complete: time passes for WAIT and VSYNC; input or Ctrl-C
 * can arrive while the terminal or window is open. Sets `idle`. */
static int round_idle(void) {
  idle.timed = idle.input = false;
  idle.next = UINT64_MAX;
  for (int i = 0; i < ncores; i++)
    for (int k = 0; k < NPEND; k++) {
      Pending *p = &cores[i].pend[k];
      if (!p->on) continue;
      if (p->port == DEV_TIMER + TMR_WAIT) { idle.timed = true; idle.next = idle.next < tmr_deadline ? idle.next : tmr_deadline; }
      else if (p->port == DEV_FBCTL + FBC_VSYNC) { idle.timed = true; idle.next = idle.next < p->target ? idle.next : p->target; }
      else if (p->port == DEV_CONSOLE + CON_IN) idle.input |= host_input_live();
      else if (p->port == DEV_CONSOLE + CON_BREAK) idle.input |= host_break_live();
      else if (p->port == DEV_NET + NET_RX) idle.input |= net_live(); /* a packet may come from the peer */
      else if (p->port == DEV_POINTER + PTR_EVENT) idle.input |= host_ptr_live();
    }
  uint64_t now = now_ticks();
  if (idle.timed && idle.next > now && idle.next - now > (1ull << 40)) idle.timed = false; /* a deadline nobody will see */
  return idle.timed || idle.input ? RND_IDLE : RND_DEADLOCK;
}

/* ------------------------------------------------------------ driver */

#define USAGE                                                                                         \
  "usage: strata-emu [-c ncores] [-t trace.txt] [-m max_steps] [-d disk.img] [-i input.txt]\n"       \
  "                  [-P pointer.txt] [-b steps] [-T real|virtual] [-g none] [-F frame.ppm]\n"             \
  "                  [-z scale] [-r WxH] [-S entries] [-X entries]\n"                                 \
  "                  [-H] [-N mode] [-J|-j] image.stx\n"                                                                     \
  "  -c N        cores (1..15, default 4)\n"                                                          \
  "  -t FILE     write an instruction trace\n"                                                        \
  "  -m N        stop after N steps (timeout)\n"                                                      \
  "  -d FILE     block device image\n"                                                                \
  "  -i FILE     console input from FILE (default: the terminal / stdin)\n"                          \
  "  -P FILE     scripted pointer input (see common/display.h)\n"                                   \
  "  -b N        press Ctrl-C after N steps\n"                                                        \
  "  -S N        capability save-table entries per core (64..256, default 256)\n"                     \
  "  -X N        overlay map entries per core (4..16, default 16)\n"                                  \
  "  -T MODE     timer: real (host microseconds, default) or virtual (rounds / 100)\n"               \
  "  -g none     never open a window (PRESENT still records the frame)\n"                            \
  "  -F FILE     at exit, write the frame as of the last PRESENT as a binary PPM\n"                          \
  "  -z N        window scale (default 1)\n"                                                         \
  "  -r WxH      framebuffer size (default 1280x800; width a multiple of 8, 320x200..2560x1600)\n"   \
  "  -H          when every core has halted, keep the window open until it is closed\n"         \
  "  -N MODE     network: none (default), loop, peer, udp:LPORT:HOST:RPORT (common/net.h)\n" \
  "  -J / -j     run with the JIT / only interpret (default: the JIT, except with -t or\n"     \
  "              -T virtual, which keep the exact one-instruction interleaving)\n"                \
  "  --debug WHERE  run under the debug engine, stopped at the first instruction: WHERE is\n"   \
  "              a TCP port (raw JSON lines, WebSocket and the web debugger on the same port),\n" \
  "              unix:PATH or stdio (doc/debug-protocol.md; strata-dbg starts it this way)\n"  \
  "  --map FILE  a symbol map (sasm -g) for the debugger; image.map is loaded by itself\n"     \
  "  --os DIR    StrataOS awareness: DIR/kernel.map, DIR/prog/NAME.map, the kernel's tables\n" \
  "  --www DIR   the files the debug port serves to a browser (default: site/)\n"            \
  "  --history N  time travel's memory, MiB (deterministic runs: -T virtual; default 512)\n"

/* Ctrl-C now: completes the oldest pending break read, or is remembered. */
static void press_break(void) {
  host_breaks++;
  pend_service();
}

/* ------------------------------------------------------------ the debug engine */

#include "debug.c" /* --debug: breakpoints, state queries, time travel, the protocol */


int main(int argc, char **argv) {
  const char *path = NULL, *in_path = NULL, *ppm = NULL;
  const char *disk_path = NULL;
  bool gfx = true, hold = false;
  unsigned fb_w = FB_DEF_WIDTH, fb_h = FB_DEF_HEIGHT;
  int scale = 1;
  int jit_opt = -1; /* -J 1, -j 0, else the default */
  for (int i = 1; i < argc; i++) {
    bool more = i + 1 < argc;
    if (!strcmp(argv[i], "-d") && more) disk_path = argv[++i];
    else if (!strcmp(argv[i], "-b") && more) opt_break_at = strtoull(argv[++i], NULL, 0);
    else if (!strcmp(argv[i], "-S") && more) {
      ctab_size = strtoull(argv[++i], NULL, 0);
      if (ctab_size < CTAB_MIN || ctab_size > CTAB_MAX) { fputs("strata-emu: -S: 64..256\n", stderr); return 2; }
    }
    else if (!strcmp(argv[i], "-X") && more) {
      nxmap = (unsigned)strtoul(argv[++i], NULL, 0);
      if (nxmap < NXMAP_MIN || nxmap > NXMAP_MAX) { fputs("strata-emu: -X: 4..16\n", stderr); return 2; }
    }
    else if (!strcmp(argv[i], "-i") && more) in_path = argv[++i];
    else if (!strcmp(argv[i], "-P") && more) {
      if (!host_ptr_script_open(argv[++i])) { perror(argv[i]); return 2; }
    }
    else if (!strcmp(argv[i], "-t") && more) {
      trace = fopen(argv[++i], "w");
      if (!trace) { perror("trace"); return 2; }
    } else if (!strcmp(argv[i], "-m") && more) opt_max_steps = strtoull(argv[++i], NULL, 0);
    else if (!strcmp(argv[i], "-c") && more) {
      ncores = atoi(argv[++i]);
      if (ncores < 1 || ncores > MAXCORES) { fprintf(stderr, "bad core count (1..%d)\n", MAXCORES); return 2; }
    } else if (!strcmp(argv[i], "-T") && more) {
      const char *m = argv[++i];
      if (!strcmp(m, "virtual")) virtual_time = true;
      else if (!strcmp(m, "real")) virtual_time = false;
      else { fputs(USAGE, stderr); return 2; }
    } else if (!strcmp(argv[i], "-g") && more) {
      const char *m = argv[++i];
      if (!strcmp(m, "none")) gfx = false;
      else if (!strcmp(m, "window") || !strcmp(m, "sdl")) gfx = true;
      else { fputs(USAGE, stderr); return 2; }
    } else if (!strcmp(argv[i], "-F") && more) ppm = argv[++i];
    else if (!strcmp(argv[i], "-r") && more) {
      if (!fb_parse_geometry(argv[++i], &fb_w, &fb_h)) { fprintf(stderr, "bad -r (WxH, width a multiple of 8, 320x200..2560x1600)\n"); return 2; }
    } else if (!strcmp(argv[i], "-z") && more) {
      scale = atoi(argv[++i]);
      if (scale < 1 || scale > 8) { fprintf(stderr, "bad scale (1..8)\n"); return 2; }
    } else if (!strcmp(argv[i], "-H")) hold = true;
    else if (!strcmp(argv[i], "-N") && more) {
      if (!net_host_open(argv[++i])) return 2;
    } else if (dbg_option(argc, argv, &i)) continue;
    else if (!strcmp(argv[i], "-J")) jit_opt = 1;
    else if (!strcmp(argv[i], "-j")) jit_opt = 0;
    else if (argv[i][0] != '-' && !path) path = argv[i];
    else { fputs(USAGE, stderr); return 2; }
  }
  if (!path) { fputs(USAGE, stderr); return 2; }

  StxImage img;
  stx_load(path, &img);
  if (!host_input_open(in_path)) { perror("input"); return 2; }
  host_clock_start();
  host_display_init(gfx, scale, ppm, fb_w, fb_h);
  disk = stx_disk_load(disk_path, &disk_blocks);
  plat_build_fb(plat_rom, ncores, disk_blocks, fb_w, fb_h, ctab_size, nxmap);
  blk_ident(blk_rom, disk_blocks);
  t2 = img.t2;
  t3 = img.t3;
  host_scan = t3 + FB_BASE; /* the display scans out live memory */
  for (int i = 0; i < ncores; i++) {
    Core *c = &cores[i];
    c->id = i;
    memcpy(c->dls, img.dls, DLS_BYTES);
    memcpy(c->ils, img.ils, ILS_BYTES);
    if (i == 0) {
      c->caps[0] = (Cap){true, SP_T3, P_R | P_W | P_X, 0, T3_BYTES, 0, 0};
      c->caps[1] = (Cap){true, SP_T2, P_R | P_W | P_X, 0, T2_BYTES, 0, 0};
    }
    c->caps[2] = (Cap){true, SP_DEV, P_W | P_D, 0, 1, 0, 0};
    if (i == 0) {
      c->caps[3] = (Cap){true, SP_DEV, P_R | P_W | P_D, 0, DEV_SPACE_LEN, 0, 0};
      c->caps[4] = (Cap){true, SP_CORE, P_W | P_D, 0, (uint64_t)ncores * 8, 0, 0}; /* core control */
    }
  }

  /* The JIT is for running programs fast; traces and the virtual timer
   * are for reproducing the reference interleaving, so they interpret. */
  fast_off = trace != NULL;
#ifdef NO_FAST /* a build for checking the fast paths against plain step() */
  fast_off = true;
#endif
  use_jit = !trace && (jit_opt >= 0 ? jit_opt == 1 : !virtual_time);
  if (use_jit) {
    JitLayout lay = {offsetof(Core, x), offsetof(Core, pc), offsetof(Core, instret), offsetof(Core, dls),
                     offsetof(Core, ils), offsetof(Core, hz_base)};
    use_jit = jit_init(&lay, cores, sizeof(Core), ncores);
    jit_lazy = use_jit && !strcmp(jit_backend(), "wasm");
    if (!use_jit && jit_opt == 1) fprintf(stderr, "strata-emu: no JIT on this host; interpreting\n");
  }

  if (dbg_on) dbg_setup(path, in_path, disk_path); /* (--debug: before the first round) */
#ifdef __EMSCRIPTEN__
  /* In the browser, web/web.c (which includes this file) runs the rounds a
   * slice at a time from the worker's loop: the machine is set up, return. */
  (void)hold;
  return web_start();
#endif
  if (dbg_on) return dbg_main(hold); /* the engine's loop instead of the one below */
  uint64_t poll_at = 0;
  for (;;) {
    rounds++;
    if (opt_break_at && mach_steps >= opt_break_at) { /* a simulated Ctrl-C */
      opt_break_at = 0;
      press_break();
    }
    host_ptr_script_run(mach_steps); /* -P */
    if (rounds >= poll_at || use_jit) { /* now and then: terminal input, window events */
      poll_at = rounds + 4096;
      host_poll();
      net_host_poll();
      if (host_quit) break;
    }
    int r = machine_round();
    if (r == RND_HALTED) {
      if (hold) host_hold();
      break;
    }
    if (r == RND_DEADLOCK) { fprintf(stderr, "deadlock: every live core is blocked\n"); return 1; }
    if (r == RND_IDLE && host_ptr_script_stepped()) { /* no step can come first: its time has come */
      host_ptr_script_do();
      continue;
    }
    if (r == RND_IDLE) {
      uint64_t now = now_ticks(), next = idle.next;
      fflush(stdout);
      if (virtual_time && idle.timed && !idle.input) {
        rounds = next * 100; /* nothing else can happen first: skip ahead */
      } else {
        uint64_t wait = !idle.timed ? 1000 : next <= now ? 0 : next - now < 1000 ? next - now : 1000;
        host_poll_input();
        net_host_poll();
        host_pump();
        if (host_quit) break;
        if (wait) usleep((useconds_t)wait);
        if (virtual_time) rounds += 100 * wait; /* interactive: let virtual time keep pace */
      }
    }
    if (opt_max_steps && mach_steps >= opt_max_steps) { fprintf(stderr, "timeout after %llu steps\n", mach_steps); return 1; }
  }
  fflush(stdout);
  if (trace) fclose(trace);
  return faulted ? 1 : 0;
}
