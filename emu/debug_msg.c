/* The debug engine: StrataOS's messages, each request paired with its reply.
 * Part of emu/debug.c (which includes this file); see there and
 * doc/debug-protocol.md, "Messages".
 *
 * Where they are seen: a StrataOS message is a 4 KiB buffer of system memory
 * (T3) lent from one core's inbox to another's, a request by its sender and
 * the reply by whoever answers it. Every such move, whether a user-mode
 * `csend`, the dispatcher's `csend` for svc SEND or its `cgive` for svc
 * REPLY, core 0's answers and EXITED, enters a core's inbox through one
 * function of the emulator, inbox_push(); its hook (dbg_inbox) is the one
 * place this file is called from while the machine runs. That catches every
 * message on every path the machine can take (the engine's exact loop, the
 * fast loop and the JITs of a fast continue), needs nothing of the kernel's
 * code addresses, and only reads: the header and the data are read from T3
 * at the moment the buffer moves, when the sender has written all of it.
 *
 * Whose a buffer is, is known as the kernel knows it (pid_of): the process
 * whose arena it is in, or the kernel for its own. A buffer moved by the core
 * that runs its owner (the owner's `csend`, or its dispatcher's on svc SEND)
 * is a request; one moved by a core that runs another process, while a
 * request with that buffer waits, is that request's reply (the server, or
 * the kernel, answering); anything else is not a message (core 0 hands a new
 * process its buffer among the pieces of its arena).
 * Capabilities that are not buffers, moved by the same core to the same core
 * just before (within 64 instructions: the dispatcher sends attachments
 * first), are the message's attachments. The sender is the process the
 * sending core runs (core 0: the kernel); the receiver of a request is core 0
 * (the kernel) or the server of the core it goes to (the worker's w_server
 * slot), and the process that answers.
 *
 * Names come from DIR/msgops.txt (--os DIR), which tools/osspec.py writes
 * from the files of os/spec/, the ones the website's and the manual's tables of
 * the servers' messages are made from: an op's name, the fields of its
 * data (the summaries below decode them), what its errors mean.
 *
 * What is kept: the last MSG_N messages, and their headers and data in a
 * ring of bytes (MSG_POOL) that older messages lose theirs from first. On a
 * deterministic run, going back drops the messages (and replies) after the
 * new position; the replay records them again. */

#include <ctype.h>
#include <strings.h>

#define MSG_N 16384
#ifdef __EMSCRIPTEN__
#define MSG_POOL (4u << 20)
#else
#define MSG_POOL (16u << 20)
#endif
#define MSG_DATA 4032  /* data bytes a message carries at most (SYS_MAX) */
#define MSG_OPEN 1024  /* requests waiting for a reply, looked up by buffer */
#define MSG_NATT 3

/* ------------------------------------------------------------ the table (msgops.txt) */

enum { MX_FIX, MX_LEN, MX_RES };  /* how far the data reaches (osspec.py extent()) */
typedef struct { char type[6]; char *name; } MField;
typedef struct {
  char srv[8];
  int num;
  char name[16];
  uint8_t qx, rx;
  MField *q, *r;
  int nq, nr;
} MOp;
typedef struct { char srv[8]; int num; int code; char *text; } MErr;
static MOp *mops;
static int nmops;
static MErr *merrs;
static int nmerrs;
static bool msg_table;

static int mx_code(const char *s) { return !strcmp(s, "len") ? MX_LEN : !strcmp(s, "res") ? MX_RES : MX_FIX; }

static MOp *mop_find(const char *srv, int num) {
  for (int i = 0; i < nmops; i++)
    if (mops[i].num == num && !strcmp(mops[i].srv, srv)) return &mops[i];
  return NULL;
}

static bool msg_load(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return false;
  char line[1024];
  if (!fgets(line, sizeof line, f) || strncmp(line, "strata-msgops 1", 15)) { fclose(f); return false; }
  while (fgets(line, sizeof line, f)) {
    line[strcspn(line, "\r\n")] = 0;
    char kind[4], srv[16], a[32], b[32];
    int num, n = 0;
    if (sscanf(line, "%3s %15s %d %31s %n", kind, srv, &num, a, &n) < 4 || !n) continue;
    const char *rest = line + n;
    if (!strcmp(kind, "op")) {
      MOp *o = realloc(mops, (size_t)(nmops + 1) * sizeof *mops);
      if (!o) break;
      mops = o;
      o = &mops[nmops++];
      memset(o, 0, sizeof *o);
      snprintf(o->srv, sizeof o->srv, "%s", srv);
      o->num = num;
      snprintf(o->name, sizeof o->name, "%s", a);
      b[0] = 0;
      char c[32] = "";
      sscanf(rest, "%31s %31s", b, c);
      o->qx = (uint8_t)mx_code(b);
      o->rx = (uint8_t)mx_code(c);
    } else if (!strcmp(kind, "fq") || !strcmp(kind, "fr")) {
      MOp *o = mop_find(srv, num);
      if (!o) continue;
      MField **fs = kind[1] == 'q' ? &o->q : &o->r;
      int *nf = kind[1] == 'q' ? &o->nq : &o->nr;
      MField *g = realloc(*fs, (size_t)(*nf + 1) * sizeof **fs);
      if (!g) break;
      *fs = g;
      snprintf(g[*nf].type, sizeof g[*nf].type, "%s", a);
      g[*nf].name = strdup(rest);
      (*nf)++;
    } else if (!strcmp(kind, "e")) {
      MErr *e = realloc(merrs, (size_t)(nmerrs + 1) * sizeof *merrs);
      if (!e) break;
      merrs = e;
      e = &merrs[nmerrs++];
      snprintf(e->srv, sizeof e->srv, "%s", srv);
      e->num = num;
      e->code = atoi(a);
      e->text = strdup(rest);
    }
  }
  fclose(f);
  return nmops > 0;
}

/* What a negative result means: the op's own words, else the name sys.s gives it. */
static const char *merr_text(const char *srv, int num, int64_t code) {
  for (int i = 0; i < nmerrs; i++)
    if (merrs[i].code == code && merrs[i].num == num && !strcmp(merrs[i].srv, srv)) return merrs[i].text;
  for (int i = 0; i < nmerrs; i++)
    if (merrs[i].code == code && !strcmp(merrs[i].srv, "*")) return merrs[i].text;
  return NULL;
}

/* ------------------------------------------------------------ the record */

typedef struct {
  uint64_t tick, round, instret; /* when it moved (instret: of the core that moved it) */
  int8_t core;                   /* the core that moved it */
  int16_t pid;                   /* the process that core ran (0: the kernel; -1 a guest's core) */
  char name[16];                 /* its name */
  uint64_t op, handle, len, mode, result;
  Cap att[MSG_NATT];
  uint8_t natt;
  uint64_t pos;                  /* its header and data in the pool */
  uint32_t n;
} MHalf;
typedef struct {
  uint64_t seq, ver;
  uint64_t base;                 /* the buffer (T3) */
  int8_t dcore;                  /* the core it was sent to */
  int16_t rpid;                  /* the receiver: 0 the kernel, -1 not known */
  char rname[16];
  char srv[8];                   /* the table its op is named from */
  bool replied;
  MHalf q, r;
} Msg;
static Msg *msg_ring;            /* MSG_N of them */
static uint64_t msg_seq, msg_lo; /* the next sequence number; the oldest kept */
static uint64_t msg_ver;         /* bumped by every new message and every reply */
static uint8_t *msg_pool;
static uint64_t msg_pos;         /* bytes written to the pool so far */
static uint64_t msg_open[MSG_OPEN]; /* seq + 1 of requests that wait, 0: free */
static uint64_t msg_moved;       /* buffers moved (requests and replies), for the cost */
static bool msg_on;              /* --os with a table: recording */
typedef struct { Cap cap[MSG_NATT]; int n, dest; uint64_t at; } MAtt;
static MAtt msg_att[MAXCORES];        /* per core: capabilities it just moved that are not buffers */

static Msg *msg_get(uint64_t seq) { return seq >= msg_lo && seq < msg_seq ? &msg_ring[seq % MSG_N] : NULL; }

static uint64_t pool_put(const uint8_t *p, uint32_t n) {
  uint64_t at = msg_pos;
  for (uint32_t i = 0; i < n;) {
    uint32_t o = (uint32_t)((msg_pos + i) % MSG_POOL), k = n - i < MSG_POOL - o ? n - i : MSG_POOL - o;
    memcpy(msg_pool + o, p + i, k);
    i += k;
  }
  msg_pos += n;
  return at;
}
/* a message's bytes, if the pool still has them (into buf, n of them) */
static bool pool_get(uint64_t at, uint32_t n, uint8_t *buf) {
  if (at + n > msg_pos || msg_pos - at > MSG_POOL) return false;
  for (uint32_t i = 0; i < n;) {
    uint32_t o = (uint32_t)((at + i) % MSG_POOL), k = n - i < MSG_POOL - o ? n - i : MSG_POOL - o;
    memcpy(buf + i, msg_pool + o, k);
    i += k;
  }
  return true;
}

static int ftype_size(const char *t) {
  return !strcmp(t, "u8") ? 1 : !strcmp(t, "u16") ? 2 : !strcmp(t, "u32") ? 4 : !strcmp(t, "u64") || !strcmp(t, "s64") ? 8 : -1;
}

/* The data bytes a message carries: by the table (its extent), else as its length says. */
static uint32_t msg_extent(const MOp *o, bool reply, const MHalf *h) {
  uint64_t n;
  int x = !o ? MX_LEN : reply ? o->rx : o->qx;
  int nf = !o ? 0 : reply ? o->nr : o->nq;
  const MField *fs = !o ? NULL : reply ? o->r : o->q;
  if (x == MX_LEN) n = h->len;
  else if (x == MX_RES) n = (int64_t)h->result > 0 ? h->result : 0;
  else {
    n = 0;
    for (int i = 0; i < nf; i++) {
      int s = ftype_size(fs[i].type);
      if (s < 0) { n += 256; break; } /* a variable tail: some of it */
      n += (uint64_t)s;
    }
  }
  if (!o && n > MSG_DATA) n = 256;
  return n > MSG_DATA ? MSG_DATA : (uint32_t)n;
}

/* The kernel's constants this file reads, from kernel.map, looked up once
 * (map_abs searches the map by name: too slow for every message). */
static struct {
  bool ok;
  int kst_t2;                                  /* the KST is in T2 (KST_SPACE = 2) */
  int64_t pbase, pgran, gpid, gshift;          /* the pool and its granules' owners */
  int64_t carea, casize, cacur, caslot;        /* the per-core areas */
  int64_t wserver;                             /* w_server in a worker's D-LS */
  int64_t gmask;                               /* core 0's K0_GMASK (cores lent to guests) */
} mk;
static void mk_init(void) {
  Map *k = map_scope(SC_KERNEL);
  if (!k) return;
  const MSym *ws = map_sym_named(k, "w_server");
  mk.kst_t2 = map_abs(k, "KST_SPACE", 3) == 2;
  mk.pbase = map_abs(k, "G_PBASE", -1), mk.pgran = map_abs(k, "G_PGRAN", -1);
  mk.gpid = map_abs(k, "G_GPID", -1), mk.gshift = map_abs(k, "GSHIFT", -1);
  mk.carea = map_abs(k, "CAREA", -1), mk.casize = map_abs(k, "CA_SIZE", -1);
  mk.cacur = map_abs(k, "CA_CUR", -1), mk.caslot = map_abs(k, "CA_SLOT", -1);
  mk.wserver = ws && ws->addr + 8 <= dls_size ? (int64_t)ws->addr : -1;
  mk.gmask = map_abs(k, "K0_GMASK", -1);
  mk.ok = mk.pbase >= 0 && mk.pgran >= 0 && mk.gpid >= 0 && mk.gshift >= 0 && mk.carea >= 0 && mk.casize >= 0 && mk.cacur >= 0;
}
static uint64_t mk_kst(uint64_t off) {
  if (!mk.kst_t2) return t3_word(off);
  if (off + 8 > T2_BYTES) return 0;
  return rd64(t2 + off);
}

/* The pid core i runs (os_cur_pid), -1 on a guest's core. */
static int msg_cur_pid(int i) {
  if (mk.gmask >= 0 && mk.gmask + 8 <= (int64_t)dls_size && (rd64(cores[0].dls + mk.gmask) >> i & 1)) return -1;
  return (int)(mk_kst((uint64_t)(mk.carea + i * mk.casize + mk.cacur)) & 0xffff);
}

/* The pid owning buffer `base`, as the kernel's pid_of finds it: its arena's
 * (the KST's granule table), 0 (the kernel) outside the pool. */
static int msg_owner(uint64_t base) {
  uint64_t pb = mk_kst((uint64_t)mk.pbase), ng = mk_kst((uint64_t)mk.pgran), g = (base - pb) >> mk.gshift;
  if (base < pb || g >= ng || g >= 256) return 0;
  return (int)mk_kst((uint64_t)mk.gpid + g * 8);
}

/* The pid of the server of core n (its dispatcher's w_server slot), -1 none. */
static int msg_server_of(int n) {
  if (n <= 0 || n >= ncores || mk.wserver < 0 || mk.caslot < 0) return -1;
  int64_t slot = (int64_t)rd64(cores[n].dls + mk.wserver);
  if (slot < 0 || slot >= 16) return -1;
  return (int)(mk_kst((uint64_t)(mk.carea + n * mk.casize + mk.caslot + slot * 8)) & 0xff);
}

static void msg_init(void) {
  if (!os_aware || !os_dir) return;
  char path[4096];
  snprintf(path, sizeof path, "%s/msgops.txt", os_dir);
  msg_table = msg_load(path);
  if (!msg_table) fprintf(stderr, "strata-emu: --os: no %s (messages are shown without names)\n", path);
  msg_ring = calloc(MSG_N, sizeof *msg_ring);
  msg_pool = malloc(MSG_POOL);
  mk_init();
  msg_on = msg_ring && msg_pool && mk.ok;
}

/* A process's name. Names are kept per pid (reading proc's table for every
 * message would cost more than the rest), forgotten when a process ends
 * (EXITED: its pid may come again with another program). */
static char msg_names[256][16];
static void msg_who(int pid, char *name, size_t n) {
  if (pid == 0) { snprintf(name, n, "kernel"); return; }
  if (pid < 0 || pid > 255) { snprintf(name, n, "?"); return; }
  if (!msg_names[pid][0]) {
    const char *s = os_name_of(pid);
    if (s) snprintf(msg_names[pid], sizeof msg_names[pid], "%s", s);
  }
  snprintf(name, n, "%s", msg_names[pid][0] ? msg_names[pid] : "?");
}

/* the table a message's op is named from */
static void msg_srv(Msg *m) {
  const char *s = m->dcore == 0 ? "kernel" : m->rname;
  uint64_t op = m->q.op;
  if (op == 36 || op == 37 || op == 38 || (m->q.pid == 0 && m->dcore != 0 && mop_find("system", (int)op))) s = "system";
  snprintf(m->srv, sizeof m->srv, "%s", s);
}

static void msg_half(MHalf *h, Core *c, uint64_t base, const MOp *o, bool reply) {
  h->tick = dbg_tick + (dbg_in_fast ? (uint64_t)c->id : 0);
  h->round = rounds;
  h->instret = c->instret;
  h->core = (int8_t)c->id;
  h->op = t3_word(base);
  h->handle = t3_word(base + 8);
  h->len = t3_word(base + 16);
  h->mode = t3_word(base + 24);
  h->result = t3_word(base + 32);
  uint32_t n = 64 + msg_extent(o, reply, h);
  h->pos = pool_put(t3 + base, n);
  h->n = n;
}

static void msg_rebuild_open(void) {
  memset(msg_open, 0, sizeof msg_open);
  int k = 0;
  for (uint64_t s = msg_seq; s > msg_lo && k < MSG_OPEN; s--) {
    Msg *m = &msg_ring[(s - 1) % MSG_N];
    if (!m->replied) msg_open[k++] = s;
  }
}

/* The hook (emu.c, inbox_push): core `from` has put capability k into dst's inbox. */
static void dbg_inbox(const Core *dst, const Cap *k, int from) {
  if (!msg_on || from < 0 || from >= ncores) return;
  Core *c = &cores[from];
  bool buf = k->space == SP_T3 && k->len == 4096 && k->base + 4096 <= T3_BYTES;
  MAtt *a = &msg_att[from];
  bool atts = a->n && a->dest == dst->id && c->instret - a->at <= 64;
  if (!buf) { /* an attachment, if a message follows */
    if (!atts) a->n = 0;
    if (a->n < MSG_NATT) a->cap[a->n++] = *k;
    a->dest = dst->id;
    a->at = c->instret;
    return;
  }
  msg_moved++;
  int pid = msg_cur_pid(from);
  /* a request that waits with this buffer? */
  int oi = -1;
  for (int i = 0; i < MSG_OPEN; i++) {
    Msg *m = msg_open[i] ? msg_get(msg_open[i] - 1) : NULL;
    if (m && m->base == k->base) { oi = i; break; }
  }
  Msg *m = oi >= 0 ? msg_get(msg_open[oi] - 1) : NULL;
  int owner = msg_owner(k->base);
  if (m && pid != owner) { /* its reply */
    msg_half(&m->r, c, k->base, mop_find(m->srv, (int)m->q.op), true);
    m->r.pid = (int16_t)pid;
    msg_who(pid, m->r.name, sizeof m->r.name);
    if (atts) { memcpy(m->r.att, a->cap, sizeof m->r.att); m->r.natt = (uint8_t)a->n; }
    if (m->rpid < 0 && pid > 0) { m->rpid = (int16_t)pid; snprintf(m->rname, sizeof m->rname, "%s", m->r.name); }
    m->replied = true;
    m->ver = ++msg_ver;
    msg_open[oi] = 0;
    a->n = 0;
    return;
  }
  if (pid != owner) { a->n = 0; return; } /* not a message */
  if (m) msg_open[oi] = 0; /* (it waited in vain: its sender sends it again) */
  if (msg_seq - msg_lo == MSG_N) {
    for (int i = 0; i < MSG_OPEN; i++) if (msg_open[i] == msg_lo + 1) msg_open[i] = 0;
    msg_lo++;
  }
  m = &msg_ring[msg_seq % MSG_N];
  memset(m, 0, sizeof *m);
  m->seq = msg_seq++;
  m->ver = ++msg_ver;
  m->base = k->base;
  m->dcore = (int8_t)dst->id;
  m->rpid = (int16_t)(dst->id == 0 ? 0 : msg_server_of(dst->id));
  msg_who(m->rpid, m->rname, sizeof m->rname);
  m->q.pid = (int16_t)pid;
  msg_who(pid, m->q.name, sizeof m->q.name);
  m->q.op = t3_word(k->base);
  msg_srv(m);
  if (!strcmp(m->srv, "system") && m->q.op == 7) { /* EXITED: that pid's name is forgotten */
    uint64_t gone = t3_word(k->base + 8);
    if (gone < 256) msg_names[gone][0] = 0;
  }
  msg_half(&m->q, c, k->base, mop_find(m->srv, (int)m->q.op), false);
  if (atts) { memcpy(m->q.att, a->cap, sizeof m->q.att); m->q.natt = (uint8_t)a->n; }
  a->n = 0;
  int i = 0;
  while (i < MSG_OPEN && msg_open[i]) i++;
  if (i == MSG_OPEN) { /* full: the oldest waiting one is forgotten */
    i = 0;
    for (int j = 1; j < MSG_OPEN; j++) if (msg_open[j] < msg_open[i]) i = j;
  }
  msg_open[i] = m->seq + 1;
}

/* Time travel went back to `tick`: messages and replies from it on are dropped. */
static void msg_rewind(uint64_t tick) {
  if (!msg_on) return;
  while (msg_seq > msg_lo && msg_ring[(msg_seq - 1) % MSG_N].q.tick >= tick) msg_seq--;
  for (uint64_t s = msg_lo; s < msg_seq; s++) {
    Msg *m = &msg_ring[s % MSG_N];
    if (m->replied && m->r.tick >= tick) { m->replied = false; memset(&m->r, 0, sizeof m->r); m->ver = ++msg_ver; }
  }
  for (int i = 0; i < ncores; i++) msg_att[i].n = 0;
  memset(msg_names, 0, sizeof msg_names);
  msg_rebuild_open();
}

/* ------------------------------------------------------------ views */

/* a short name of a field: its first three words, without an article
 * ("the bytes read" -> bytes_read); one that depends on the mode -> data */
static void fname(const char *s, char *o, size_t n) {
  if (!strncmp(s, "the ", 4)) s += 4;
  else if (!strncmp(s, "a ", 2)) s += 2;
  else if (!strncmp(s, "an ", 3)) s += 3;
  if (!strncmp(s, "mode ", 5) || !strncmp(s, "found ", 6)) s = "data";
  size_t k = 0;
  int words = 0;
  for (; *s && k + 1 < n && !strchr(",:;(`", *s); s++) {
    if (*s == ' ' && ++words == 3) break;
    o[k++] = *s == ' ' ? '_' : *s;
  }
  while (k && o[k - 1] == '_') k--;
  o[k] = 0;
}

/* bytes as a short quoted string */
static void qbytes(char *o, size_t n, const uint8_t *p, size_t len, size_t max) {
  size_t k = 0;
  if (k + 1 < n) o[k++] = '"';
  size_t i;
  for (i = 0; i < len && i < max && k + 6 < n; i++) {
    uint8_t b = p[i];
    if (b == '\n') k += (size_t)snprintf(o + k, n - k, "\\n");
    else if (b == '"' || b == '\\') k += (size_t)snprintf(o + k, n - k, "\\%c", b);
    else if (b >= 32 && b < 127) o[k++] = (char)b;
    else k += (size_t)snprintf(o + k, n - k, "\\x%02x", b);
  }
  if (k + 1 < n) o[k++] = '"';
  if (i < len) k += (size_t)snprintf(o + k, n - k, "+%zu", len - i);
  o[k < n ? k : n - 1] = 0;
}

/* The data of a message, decoded by the table's fields: "path=\"/bin/ls\"", "x=8 y=16 ...". */
static void msg_summary(const Msg *m, bool reply, char *o, size_t n) {
  const MHalf *h = reply ? &m->r : &m->q;
  const MOp *op = mop_find(m->srv, (int)m->q.op);
  o[0] = 0;
  uint8_t buf[64 + MSG_DATA];
  if (!h->n || !pool_get(h->pos, h->n, buf)) return;
  uint32_t dn = h->n - 64, off = 0;
  const uint8_t *d = buf + 64;
  const MField *fs = !op ? NULL : reply ? op->r : op->q;
  int nf = !op ? 0 : reply ? op->nr : op->nq;
  if (reply && (int64_t)h->result < 0) return;
  size_t k = 0;
  if (!op) { /* no table: the bytes */
    if (dn) qbytes(o, n, d, dn, 24);
    return;
  }
  /* (ws: a key event's value is its bytes) */
  bool wskey = reply && !strcmp(m->srv, "ws") && !strcmp(op->name, "EVENT") && dn >= 24 && rd64(d) == 1;
  for (int i = 0; i < nf && off < dn && k + 8 < n; i++) {
    char nm[24], v[96];
    fname(fs[i].name, nm, sizeof nm);
    int s = ftype_size(fs[i].type);
    if (!strcmp(fs[i].type, "pad")) continue;
    if (!strcmp(fs[i].type, "rep")) {
      snprintf(v, sizeof v, "[%u bytes: %s]", dn - off, fs[i].name);
      k += (size_t)snprintf(o + k, n - k, "%s%s", k ? " " : "", v);
      break;
    }
    if (s < 0) { /* bytes, text: the rest */
      uint32_t len = dn - off;
      if (op && (reply ? op->rx : op->qx) == MX_FIX && i < nf - 1) len = 0;
      if (op && (reply ? op->rx : op->qx) == MX_FIX && len > 16) { /* an unknown length: up to a 0 */
        uint32_t z = 0;
        while (z < len && d[off + z]) z++;
        len = z < 16 ? z : 16;
      }
      qbytes(v, sizeof v, d + off, len, 40);
      k += (size_t)snprintf(o + k, n - k, "%s%s=%s", k ? " " : "", nm, v);
      off += len;
      continue;
    }
    if (off + (uint32_t)s > dn) break;
    uint64_t x = 0;
    memcpy(&x, d + off, (size_t)s);
    off += (uint32_t)s;
    if (wskey && i == 1) {
      uint64_t cnt = rd64(d + 16);
      qbytes(v, sizeof v, d + 8, cnt < 8 ? cnt : 8, 8);
      k += (size_t)snprintf(o + k, n - k, "%skey=%s", k ? " " : "", v);
      continue;
    }
    if (!strcmp(fs[i].type, "s64") && (int64_t)x < 0) snprintf(v, sizeof v, "%lld", (long long)x);
    else if (x < 100000) snprintf(v, sizeof v, "%llu", (unsigned long long)x);
    else snprintf(v, sizeof v, "0x%llx", (unsigned long long)x);
    k += (size_t)snprintf(o + k, n - k, "%s%s=%s", k ? " " : "", nm, v);
  }
  if (k >= n) o[n - 1] = 0;
}

static void jw_att(JW *w, const MHalf *h) {
  if (!h->natt) return;
  jw_arr(w, "att");
  for (int i = 0; i < h->natt; i++) jw_cap(w, NULL, &h->att[i]);
  jw_aend(w);
}

static void jw_half(JW *w, const Msg *m, const MHalf *h, bool reply) {
  jw_uint(w, "tick", h->tick);
  jw_uint(w, "round", h->round);
  jw_uint(w, "instret", h->instret);
  jw_int(w, "core", h->core);
  jw_int(w, "pid", h->pid);
  jw_str(w, "proc", h->name);
  jw_int(w, "handle", (int64_t)h->handle);
  jw_int(w, "len", (int64_t)h->len);
  jw_int(w, "mode", (int64_t)h->mode);
  char s[512];
  msg_summary(m, reply, s, sizeof s);
  if (s[0]) jw_str(w, "data", s);
  jw_uint(w, "bytes", h->n ? h->n - 64 : 0);
  jw_att(w, h);
}

static void msg_json(JW *w, const char *key, const Msg *m, bool hex) {
  const MOp *op = mop_find(m->srv, (int)m->q.op);
  jw_obj(w, key);
  jw_uint(w, "seq", m->seq);
  jw_hex(w, "buf", m->base);
  jw_str(w, "server", m->srv);
  jw_int(w, "to", m->rpid);
  jw_str(w, "toname", m->rname);
  jw_int(w, "tocore", m->dcore);
  jw_uint(w, "op", m->q.op);
  if (op) jw_str(w, "name", op->name);
  jw_half(w, m, &m->q, false);
  uint8_t buf[64 + MSG_DATA];
  if (hex && pool_get(m->q.pos, m->q.n, buf)) jw_hexbytes(w, "hex", buf, m->q.n);
  if (m->replied) {
    jw_obj(w, "reply");
    jw_int(w, "result", (int64_t)m->r.result);
    const char *e = (int64_t)m->r.result < 0 ? merr_text(m->srv, (int)m->q.op, (int64_t)m->r.result) : NULL;
    if (e) jw_str(w, "error", e);
    jw_half(w, m, &m->r, true);
    jw_uint(w, "rt", m->r.tick - m->q.tick);
    jw_uint(w, "rt_rounds", m->r.round - m->q.round);
    if (hex && pool_get(m->r.pos, m->r.n, buf)) jw_hexbytes(w, "hex", buf, m->r.n);
    jw_oend(w);
  } else jw_null(w, "reply");
  jw_oend(w);
}

/* the filters of `msgs` and `msgstats`: server, pid (or a process's name), op (number or name), core */
typedef struct { const char *server, *proc, *opname; int pid, op, core; bool waiting; } MFilter;
static void mfilter(const JVal *rq, MFilter *f) {
  memset(f, 0, sizeof *f);
  f->pid = f->op = f->core = -1;
  f->server = json_str(json_get(rq, "server"), NULL);
  const JVal *p = json_get(rq, "pid"), *o = json_get(rq, "op");
  if (p && p->t == J_STR && !isdigit((unsigned char)p->s[0])) f->proc = p->s;
  else if (p) f->pid = json_int(p, -1);
  if (o && o->t == J_STR && !isdigit((unsigned char)o->s[0])) f->opname = o->s;
  else if (o) f->op = json_int(o, -1);
  if (json_get(rq, "core")) f->core = json_int(json_get(rq, "core"), -1);
  f->waiting = json_bool(json_get(rq, "waiting"), false);
}
static bool mfilter_ok(const MFilter *f, const Msg *m) {
  if (f->server && strcasecmp(f->server, m->rname) && strcasecmp(f->server, m->srv)) return false;
  if (f->pid >= 0 && m->q.pid != f->pid && m->rpid != f->pid) return false;
  if (f->proc && strcmp(f->proc, m->q.name) && strcmp(f->proc, m->rname)) return false;
  if (f->op >= 0 && m->q.op != (uint64_t)f->op) return false;
  if (f->opname) {
    const MOp *op = mop_find(m->srv, (int)m->q.op);
    if (!op || strcasecmp(op->name, f->opname)) return false;
  }
  if (f->core >= 0 && m->q.core != f->core && m->dcore != f->core) return false;
  if (f->waiting && m->replied) return false;
  return true;
}

/* `msgs {since, max, server, pid, op, core, waiting}` */
static void msgs_json(JW *w, const JVal *rq) {
  uint64_t since = json_u64(json_get(rq, "since"), 0), max = json_u64(json_get(rq, "max"), 500);
  MFilter f;
  mfilter(rq, &f);
  jw_uint(w, "version", msg_ver);
  jw_uint(w, "first", msg_lo);
  jw_uint(w, "next", msg_seq);
  jw_uint(w, "moved", msg_moved);
  jw_bool(w, "names", msg_table);
  /* the newest `max` of those changed since `since` */
  uint64_t start = msg_seq, cnt = 0;
  while (start > msg_lo && cnt < max) {
    const Msg *m = &msg_ring[(start - 1) % MSG_N];
    if (m->ver > since && mfilter_ok(&f, m)) cnt++;
    start--;
  }
  bool more = false;
  for (uint64_t s = start; s > msg_lo && !more; s--) {
    const Msg *m = &msg_ring[(s - 1) % MSG_N];
    more = m->ver > since && mfilter_ok(&f, m);
  }
  jw_bool(w, "truncated", more);
  jw_arr(w, "msgs");
  for (uint64_t s = start; s < msg_seq; s++) {
    const Msg *m = &msg_ring[s % MSG_N];
    if (m->ver > since && mfilter_ok(&f, m)) msg_json(w, NULL, m, false);
  }
  jw_aend(w);
}

/* `msgstats {server, pid, op, core}`: per receiver and op */
static void msgstats_json(JW *w, const JVal *rq) {
  MFilter f;
  mfilter(rq, &f);
  typedef struct { char srv[8], to[16]; uint64_t op, n, replied, errors, rt, rtmax; } St;
  static St st[512];
  int ns = 0;
  for (uint64_t s = msg_lo; s < msg_seq; s++) {
    const Msg *m = &msg_ring[s % MSG_N];
    if (!mfilter_ok(&f, m)) continue;
    int i;
    for (i = 0; i < ns; i++)
      if (st[i].op == m->q.op && !strcmp(st[i].to, m->rname) && !strcmp(st[i].srv, m->srv)) break;
    if (i == ns) {
      if (ns == (int)(sizeof st / sizeof *st)) continue;
      memset(&st[ns], 0, sizeof *st);
      snprintf(st[ns].srv, sizeof st[ns].srv, "%s", m->srv);
      snprintf(st[ns].to, sizeof st[ns].to, "%s", m->rname);
      st[ns++].op = m->q.op;
    }
    st[i].n++;
    if (m->replied) {
      uint64_t rt = m->r.tick - m->q.tick;
      st[i].replied++;
      st[i].rt += rt;
      if (rt > st[i].rtmax) st[i].rtmax = rt;
      if ((int64_t)m->r.result < 0) st[i].errors++;
    }
  }
  /* by receiver, then op */
  for (int i = 1; i < ns; i++)
    for (int j = i; j > 0; j--) {
      int c = strcmp(st[j - 1].to, st[j].to);
      if (c < 0 || (c == 0 && st[j - 1].op <= st[j].op)) break;
      St t = st[j]; st[j] = st[j - 1]; st[j - 1] = t;
    }
  jw_uint(w, "first", msg_lo);
  jw_uint(w, "next", msg_seq);
  jw_arr(w, "stats");
  for (int i = 0; i < ns; i++) {
    const MOp *op = mop_find(st[i].srv, (int)st[i].op);
    jw_obj(w, NULL);
    jw_str(w, "to", st[i].to);
    jw_str(w, "server", st[i].srv);
    jw_uint(w, "op", st[i].op);
    if (op) jw_str(w, "name", op->name);
    jw_uint(w, "n", st[i].n);
    jw_uint(w, "replied", st[i].replied);
    jw_uint(w, "errors", st[i].errors);
    jw_uint(w, "avg_rt", st[i].replied ? st[i].rt / st[i].replied : 0);
    jw_uint(w, "max_rt", st[i].rtmax);
    jw_oend(w);
  }
  jw_aend(w);
}
