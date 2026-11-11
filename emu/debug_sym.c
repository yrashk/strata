/* The debug engine: symbol maps, the disassembler, Forth words and StrataOS
 * awareness. Part of emu/debug.c (which includes this file); see there.
 *
 * Maps are written by `sasm -g` (asm/sasm.c, write_map). Each one applies
 * to some of the code the cores run:
 *   - the image's own map (IMAGE.map next to IMAGE.stx, or --map): all of
 *     the I-LS, unless StrataOS awareness is on, when it is the boot ROM's
 *     and covers I-LS 0x0000..0x3FFF;
 *   - with --os DIR: DIR/kernel.map for the resident kernel (I-LS
 *     0x4000..0x7FFF) and its code units (far; core 0 runs them from its
 *     code cache through the overlay map), and DIR/prog/NAME.map for the
 *     program a core runs in user mode (NAME: the process's name in proc's
 *     table), loaded when first needed.
 * Code reached through the overlay map (xcall) is looked up at its far
 * address, in the map's .far section. */

enum { MS_TEXT, MS_DATA, MS_FAR, MS_CLUSTER, MS_ABS };
static const char *const ms_names[] = {"text", "data", "far", "cluster", "abs"};

typedef struct { char *name; uint64_t addr; uint8_t sect; } MSym;
typedef struct { uint32_t addr; uint16_t file; uint8_t sect; uint32_t line; } MLine;

enum { SC_IMAGE, SC_KERNEL, SC_PROG };
typedef struct {
  char *path, *root;
  char **files;
  int nfiles;
  MSym *syms;       /* sorted by section, then address */
  int nsyms;
  MLine *lines;     /* sorted by section, then address */
  int nlines;
  int scope;        /* SC_* */
  char prog[24];    /* SC_PROG: the program's name */
  int64_t forth;    /* D-LS address of Forth's v_latest, -1 if this is not a Forth */
} Map;

#define NMAPS 64
static Map *maps[NMAPS];
static int nmaps;
static const char *os_dir;       /* --os: where kernel.map and prog/ are */
static bool os_aware;
static char prog_missing[NMAPS][24]; /* program maps looked for and not found */
static int nprog_missing;

static int msym_cmp(const void *a, const void *b) {
  const MSym *x = a, *y = b;
  if (x->sect != y->sect) return x->sect - y->sect;
  return x->addr < y->addr ? -1 : x->addr > y->addr;
}
static int mline_cmp(const void *a, const void *b) {
  const MLine *x = a, *y = b;
  if (x->sect != y->sect) return x->sect - y->sect;
  return x->addr < y->addr ? -1 : x->addr > y->addr;
}

static int sect_code(const char *s) {
  for (int i = 0; i <= MS_ABS; i++)
    if (!strcmp(s, ms_names[i])) return i;
  return -1;
}

static char *dstrdup(const char *s) {
  char *p = malloc(strlen(s) + 1);
  if (!p) { perror("strata-emu"); exit(2); }
  strcpy(p, s);
  return p;
}

/* Loads a map; NULL if the file is not there or not a map. */
static Map *map_load(const char *path, int scope, const char *prog) {
  FILE *f = fopen(path, "r");
  if (!f) return NULL;
  char line[4096];
  if (!fgets(line, sizeof line, f) || strncmp(line, "strata-map 1", 12)) { fclose(f); return NULL; }
  Map *m = calloc(1, sizeof *m);
  m->path = dstrdup(path);
  m->scope = scope;
  m->forth = -1;
  if (prog) snprintf(m->prog, sizeof m->prog, "%s", prog);
  int capsym = 0, capline = 0, capfile = 0;
  while (fgets(line, sizeof line, f)) {
    line[strcspn(line, "\r\n")] = 0;
    char kind[16], sect[16], name[1024];
    unsigned long long a;
    int fi, ln;
    if (!strncmp(line, "root ", 5)) { m->root = dstrdup(line + 5); continue; }
    if (sscanf(line, "file %d %1023[^\n]", &fi, name) == 2) {
      if (fi >= capfile) {
        capfile = fi * 2 + 8;
        m->files = realloc(m->files, sizeof *m->files * (size_t)capfile);
      }
      while (m->nfiles <= fi) m->files[m->nfiles++] = NULL;
      m->files[fi] = dstrdup(name);
      continue;
    }
    if (sscanf(line, "%15s %15s %llx %1023s", kind, sect, &a, name) == 4 && !strcmp(kind, "sym")) {
      int sc = sect_code(sect);
      if (sc < 0) continue;
      if (m->nsyms == capsym) { capsym = capsym ? capsym * 2 : 256; m->syms = realloc(m->syms, sizeof *m->syms * (size_t)capsym); }
      m->syms[m->nsyms++] = (MSym){dstrdup(name), a, (uint8_t)sc};
      if (sc == MS_DATA && !strcmp(name, "v_latest")) m->forth = (int64_t)a;
      continue;
    }
    if (sscanf(line, "line %15s %llx %d %d", sect, &a, &fi, &ln) == 4) {
      int sc = sect_code(sect);
      if (sc < 0) continue;
      if (m->nlines == capline) { capline = capline ? capline * 2 : 1024; m->lines = realloc(m->lines, sizeof *m->lines * (size_t)capline); }
      m->lines[m->nlines++] = (MLine){(uint32_t)a, (uint16_t)fi, (uint8_t)sc, (uint32_t)ln};
    }
  }
  fclose(f);
  qsort(m->syms, (size_t)m->nsyms, sizeof *m->syms, msym_cmp);
  qsort(m->lines, (size_t)m->nlines, sizeof *m->lines, mline_cmp);
  if (nmaps < NMAPS) maps[nmaps++] = m;
  return m;
}

/* The map of program `name` (StrataOS), loaded on first use. */
static Map *map_prog(const char *name) {
  if (!name || !name[0] || !os_dir) return NULL;
  for (int i = 0; i < nmaps; i++)
    if (maps[i]->scope == SC_PROG && !strcmp(maps[i]->prog, name)) return maps[i];
  for (int i = 0; i < nprog_missing; i++)
    if (!strcmp(prog_missing[i], name)) return NULL;
  char path[2048];
  snprintf(path, sizeof path, "%s/prog/%s.map", os_dir, name);
  Map *m = map_load(path, SC_PROG, name);
  if (!m && nprog_missing < NMAPS) snprintf(prog_missing[nprog_missing++], 24, "%s", name);
  return m;
}

static Map *map_scope(int scope) {
  for (int i = 0; i < nmaps; i++)
    if (maps[i]->scope == scope) return maps[i];
  return NULL;
}

/* The last symbol of section `sect` at or below addr (NULL if none). */
static const MSym *map_sym_at(const Map *m, int sect, uint64_t addr) {
  if (!m) return NULL;
  int lo = 0, hi = m->nsyms - 1, best = -1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    const MSym *s = &m->syms[mid];
    if (s->sect < sect || (s->sect == sect && s->addr <= addr)) { if (s->sect == sect) best = mid; lo = mid + 1; }
    else hi = mid - 1;
  }
  return best >= 0 ? &m->syms[best] : NULL;
}

static const MLine *map_line_at(const Map *m, int sect, uint64_t addr) {
  if (!m) return NULL;
  int lo = 0, hi = m->nlines - 1, best = -1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    const MLine *l = &m->lines[mid];
    if (l->sect < sect || (l->sect == sect && l->addr <= addr)) { if (l->sect == sect) best = mid; lo = mid + 1; }
    else hi = mid - 1;
  }
  return best >= 0 ? &m->lines[best] : NULL;
}

static const MSym *map_sym_named(const Map *m, const char *name) {
  if (!m) return NULL;
  for (int i = 0; i < m->nsyms; i++)
    if (!strcmp(m->syms[i].name, name)) return &m->syms[i];
  return NULL;
}
static int64_t map_abs(const Map *m, const char *name, int64_t def) {
  const MSym *s = map_sym_named(m, name);
  return s ? (int64_t)s->addr : def;
}

/* ------------------------------------------------------------ StrataOS awareness */

/* The kernel's shared table (KST, T3 offset 0) and core 0's process records:
 * offsets come from kernel.map (CAREA, CA_SIZE, CA_CUR, K0_PROC, ...), the
 * process table from proc's map (procs, E_SIZE, E_NAME, ...): nothing here
 * hard-codes the kernel's layout. */
typedef struct { int pid, parent, state, status, core, ncores, flags; char name[17]; } OsProc;
#define OS_MAXPROC 128
static OsProc os_procs[OS_MAXPROC];
static int os_nprocs;
static uint64_t os_procs_at = ~0ull; /* dbg_tick of the last read */

static uint64_t t3_word(uint64_t off) {
  if (off + 8 > T3_BYTES) return 0;
  uint64_t v;
  memcpy(&v, t3 + off, 8);
  return v;
}

/* The pid core i runs now (KST CA_CUR), 0 if none or not known. */
static int os_cur_pid(int i) {
  Map *k = map_scope(SC_KERNEL);
  if (!os_aware || !k) return 0;
  int64_t ca = map_abs(k, "CAREA", -1), sz = map_abs(k, "CA_SIZE", -1), cur = map_abs(k, "CA_CUR", -1);
  if (ca < 0 || sz < 0 || cur < 0) return 0;
  return (int)(t3_word((uint64_t)(ca + i * sz + cur)) & 0xffff);
}

static const char *os_name_of(int pid);

/* Reads the process table: proc's (names, parents, states) where proc's
 * D-LS can be read (the core it is alone on runs it), else core 0's records
 * (pids and cores only). Cached per tick. */
static void os_read_procs(void) {
  if (os_procs_at == dbg_tick) return;
  Map *k = map_scope(SC_KERNEL), *p = map_prog("proc");
  if (!os_aware || !k) { os_nprocs = 0; return; }
  OsProc tab[OS_MAXPROC];
  int n = 0;
  /* core 0's records: pid, flags, first core, cores */
  int64_t kp = map_abs(k, "K0_PROC", -1), ksz = map_abs(k, "KP_SIZE", 64), nk = map_abs(k, "NKPROC", 64);
  int64_t kpid = map_abs(k, "KP_PID", 0), kfl = map_abs(k, "KP_FLAGS", 8), kco = map_abs(k, "KP_CORE", 16), kn = map_abs(k, "KP_N", 24);
  int proc_core = -1;
  if (kp >= 0)
    for (int64_t r = 0; r < nk && n < OS_MAXPROC; r++) {
      uint64_t a = (uint64_t)(kp + r * ksz);
      if (a + (uint64_t)ksz > DLS_BYTES) break;
      int pid = (int)rd64(cores[0].dls + a + kpid);
      if (!pid) continue;
      OsProc *o = &tab[n++];
      memset(o, 0, sizeof *o);
      o->pid = pid;
      o->flags = (int)rd64(cores[0].dls + a + kfl);
      o->core = (int)rd64(cores[0].dls + a + kco);
      o->ncores = (int)rd64(cores[0].dls + a + kn);
      o->state = 1;
      o->parent = -1;
      if (pid == 1) proc_core = o->core;
    }
  /* proc's table, if proc's D-LS is its core's: proc runs there now, or the
   * core is idle and proc is the only thread it has (CA_SLOT) */
  bool proc_here = false;
  if (p && proc_core > 0 && proc_core < ncores) {
    int cur = os_cur_pid(proc_core);
    int64_t ca = map_abs(k, "CAREA", -1), sz = map_abs(k, "CA_SIZE", -1), sl = map_abs(k, "CA_SLOT", -1), ns = map_abs(k, "NSLOT", 16);
    proc_here = cur == 1;
    if (cur == 0 && ca >= 0 && sz >= 0 && sl >= 0) {
      proc_here = true;
      for (int64_t q = 0; q < ns; q++) {
        int pid = (int)(t3_word((uint64_t)(ca + proc_core * sz + sl + 8 * q)) & 0xff);
        if (pid && pid != 1) proc_here = false;
      }
    }
  }
  if (proc_here) {
    const MSym *ps = map_sym_named(p, "procs");
    int64_t esz = map_abs(p, "E_SIZE", 80), np = map_abs(p, "NPROC", 64);
    int64_t epid = map_abs(p, "E_PID", 0), epar = map_abs(p, "E_PARENT", 8), est = map_abs(p, "E_STATE", 16);
    int64_t estat = map_abs(p, "E_STATUS", 24), eco = map_abs(p, "E_CORE", 40), enm = map_abs(p, "E_NAME", 64);
    const uint8_t *d = cores[proc_core].dls;
    if (ps)
      for (int64_t r = 0; r < np; r++) {
        uint64_t a = ps->addr + (uint64_t)(r * esz);
        if (a + (uint64_t)esz > DLS_BYTES) break;
        int pid = (int)rd64(d + a + epid);
        if (!pid) continue;
        OsProc *o = NULL;
        for (int i = 0; i < n; i++)
          if (tab[i].pid == pid) o = &tab[i];
        if (!o && n < OS_MAXPROC) {
          o = &tab[n++];
          memset(o, 0, sizeof *o);
          o->pid = pid;
          uint64_t cw = rd64(d + a + eco);
          o->core = (int)(cw & 255);
          o->ncores = (int)(cw >> 8 & 255);
        }
        if (!o) break;
        o->parent = (int)rd64(d + a + epar);
        o->state = (int)rd64(d + a + est);
        o->status = (int)rd64(d + a + estat);
        memcpy(o->name, d + a + enm, 16);
        o->name[16] = 0;
        for (int i = 0; i < 16; i++)
          if ((unsigned char)o->name[i] < ' ' || (unsigned char)o->name[i] > '~') { o->name[i] = 0; break; }
      }
  }
  /* names seen before stay known (proc is not always readable) */
  for (int i = 0; i < n; i++)
    if (!tab[i].name[0])
      for (int j = 0; j < os_nprocs; j++)
        if (os_procs[j].pid == tab[i].pid && os_procs[j].name[0]) { memcpy(tab[i].name, os_procs[j].name, 17); if (tab[i].parent < 0) tab[i].parent = os_procs[j].parent; }
  memcpy(os_procs, tab, sizeof tab[0] * (size_t)n);
  os_nprocs = n;
  os_procs_at = dbg_tick;
}

static const char *os_name_of(int pid) {
  if (!pid) return NULL;
  os_read_procs();
  for (int i = 0; i < os_nprocs; i++)
    if (os_procs[i].pid == pid) return os_procs[i].name[0] ? os_procs[i].name : NULL;
  return NULL;
}
static int os_pid_named(const char *name) {
  os_read_procs();
  for (int i = 0; i < os_nprocs; i++)
    if (!strcmp(os_procs[i].name, name)) return os_procs[i].pid;
  return 0;
}

/* ------------------------------------------------------------ which map, which address */

/* Where core c's code at I-LS address pc comes from: the map to look in,
 * the section and the address in that section. A valid overlay entry that
 * covers pc means far code (looked up at its far address). */
typedef struct { Map *map; int sect; uint64_t addr; } Where;

static Where where_code(const Core *c, uint64_t pc) {
  Where w = {NULL, MS_TEXT, pc};
  uint64_t sl = c->xslot ? 1ull << c->xslot : 4;
  int hit = -1;
  for (int i = 0; i < NXMAP && hit < 0; i++)
    if (c->xm_v[i] && pc >= c->xm_ils[i] && pc < c->xm_ils[i] + sl) hit = i;
  if (os_aware) {
    if (c->user && pc >= 0x8000) {
      int pid = os_cur_pid(c->id);
      w.map = map_prog(os_name_of(pid));
      return w;
    }
    if (pc < 0x4000 && hit < 0) { w.map = map_scope(SC_IMAGE); return w; }
    w.map = map_scope(SC_KERNEL);
    if (hit >= 0) {
      /* a kernel unit: far offsets in the kernel image, which the boot ROM
       * loaded at the base of the far-image capability (c15 on core 0) */
      const Cap *k = &cores[0].caps[15];
      uint64_t kb = k->valid && (k->perms & P_X) ? k->base : 0;
      w.sect = MS_FAR;
      w.addr = c->xm_far[hit] + (pc - c->xm_ils[hit]) - kb;
    }
    return w;
  }
  w.map = map_scope(SC_IMAGE);
  if (hit >= 0) { w.sect = MS_FAR; w.addr = c->xm_far[hit] + (pc - c->xm_ils[hit]); }
  return w;
}

/* The Forth word whose code holds pc, from the dictionary in c's D-LS
 * (headers: u16 link, u16 hash, u16 xt, u16 size, u8 flags, u8 fold,
 * u8 name length, name; see lang/forth/forth.s). */
static bool forth_word(const Core *c, const Map *m, uint64_t pc, char *name, size_t n, uint64_t *xt_out) {
  if (!m || m->forth < 0 || (uint64_t)m->forth + 8 > DLS_BYTES) return false;
  uint64_t h = rd64(c->dls + m->forth) & 0xffff, best = 0, bxt = 0;
  for (int guard = 0; h && h + 11 < DLS_BYTES && guard < 20000; guard++) {
    uint64_t xt = c->dls[h + 4] | (uint64_t)c->dls[h + 5] << 8;
    if (xt <= pc && xt >= bxt) { best = h; bxt = xt; }
    h = c->dls[h] | (uint64_t)c->dls[h + 1] << 8;
  }
  if (!best) return false;
  unsigned len = c->dls[best + 10];
  if (best + 11 + len > DLS_BYTES) return false;
  snprintf(name, n, "%.*s", (int)len, (const char *)c->dls + best + 11);
  if (xt_out) *xt_out = bxt;
  return true;
}

/* "label+off" for core c's code at pc, or "" when no map knows it. */
static void sym_code(const Core *c, uint64_t pc, char *out, size_t n) {
  out[0] = 0;
  Where w = where_code(c, pc);
  const MSym *s = map_sym_at(w.map, w.sect, w.addr);
  uint64_t fxt = 0;
  char fw[64];
  bool f = w.sect == MS_TEXT && forth_word(c, w.map, pc, fw, sizeof fw, &fxt);
  if (f && (!s || fxt > s->addr)) {
    if (pc == fxt) snprintf(out, n, "%s", fw);
    else snprintf(out, n, "%s+%llu", fw, (unsigned long long)(pc - fxt));
    return;
  }
  if (!s) return;
  if (w.addr == s->addr) snprintf(out, n, "%s", s->name);
  else snprintf(out, n, "%s+%llu", s->name, (unsigned long long)(w.addr - s->addr));
}

/* The source line of core c's code at pc: file and line, false if unknown. */
static bool line_code(const Core *c, uint64_t pc, const char **file, int *line, const Map **mo) {
  Where w = where_code(c, pc);
  const MLine *l = map_line_at(w.map, w.sect, w.addr);
  if (!l || l->file >= w.map->nfiles || !w.map->files[l->file]) return false;
  *file = w.map->files[l->file];
  *line = (int)l->line;
  if (mo) *mo = w.map;
  return true;
}

/* "name" or "name+off" for a D-LS address of core c (its program's data). */
static void sym_data(const Core *c, uint64_t a, char *out, size_t n) {
  out[0] = 0;
  Map *m = os_aware && c->user ? map_prog(os_name_of(os_cur_pid(c->id))) : os_aware ? map_scope(SC_KERNEL) : map_scope(SC_IMAGE);
  const MSym *s = map_sym_at(m, MS_DATA, a);
  if (!s || a - s->addr > 4096) return;
  if (a == s->addr) snprintf(out, n, "%s", s->name);
  else snprintf(out, n, "%s+%llu", s->name, (unsigned long long)(a - s->addr));
}

/* Resolves a location: a number, `label`, `label+N`, `file.s:line`, or
 * `prog:label` (StrataOS: a program's label; sets *prog). Returns false if
 * nothing matches. *sect is MS_TEXT unless the label is elsewhere. */
static bool resolve_loc(const char *loc, uint64_t *addr, int *sect, char *prog, size_t np, char *err, size_t ne) {
  prog[0] = 0;
  *sect = MS_TEXT;
  char buf[512];
  snprintf(buf, sizeof buf, "%s", loc);
  char *e;
  unsigned long long v = strtoull(buf, &e, 0);
  if (*buf && !*e) { *addr = v; return true; }
  char *colon = strrchr(buf, ':');
  if (colon && colon[1] && strspn(colon + 1, "0123456789") == strlen(colon + 1)) {
    /* file:line, the first code at or after the line */
    *colon = 0;
    int want = atoi(colon + 1);
    const char *base = strrchr(buf, '/') ? strrchr(buf, '/') + 1 : buf;
    for (int mi = 0; mi < nmaps; mi++) {
      Map *m = maps[mi];
      for (int fi = 0; fi < m->nfiles; fi++) {
        const char *f = m->files[fi];
        if (!f) continue;
        const char *fb = strrchr(f, '/') ? strrchr(f, '/') + 1 : f;
        if (strcmp(f, buf) && strcmp(fb, base)) continue;
        const MLine *best = NULL;
        for (int i = 0; i < m->nlines; i++) {
          const MLine *l = &m->lines[i];
          if (l->file != fi || (l->sect != MS_TEXT && l->sect != MS_FAR) || (int)l->line < want) continue;
          if (!best || l->line < best->line || (l->line == best->line && l->addr < best->addr)) best = l;
        }
        if (best) {
          *addr = best->addr;
          *sect = best->sect;
          if (m->scope == SC_PROG) snprintf(prog, np, "%s", m->prog);
          return true;
        }
      }
    }
    snprintf(err, ne, "no code at %s:%d", buf, want);
    return false;
  }
  if (colon) { /* prog:label */
    *colon = 0;
    Map *m = map_prog(buf);
    if (!m) { snprintf(err, ne, "no map for program %s", buf); return false; }
    const MSym *s = map_sym_named(m, colon + 1);
    if (!s) { snprintf(err, ne, "%s has no label %s", buf, colon + 1); return false; }
    *addr = s->addr;
    *sect = s->sect;
    snprintf(prog, np, "%s", buf);
    return true;
  }
  uint64_t off = 0;
  char *plus = strchr(buf, '+');
  if (plus) { *plus = 0; off = strtoull(plus + 1, NULL, 0); }
  for (int mi = 0; mi < nmaps; mi++) {
    const MSym *s = map_sym_named(maps[mi], buf);
    if (s && s->sect != MS_ABS) {
      *addr = s->addr + off;
      *sect = s->sect;
      if (maps[mi]->scope == SC_PROG) snprintf(prog, np, "%s", maps[mi]->prog);
      return true;
    }
  }
  snprintf(err, ne, "no symbol %s", buf);
  return false;
}

/* ------------------------------------------------------------ the disassembler */

static const char *const xr_names[32] = {
  "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};
static const char *const csr_nm[] = {
  "cycle", "instret", "cause", "epc", "tval", "tvec", "ccr", "coreid", "ttag", "tdata", "tgeom", "ncores",
  "scratch", "stalls", "takefrom", "corebase", "corecount", "reserved17", "status", "ucause", "uepc",
  "utval", "utvec", "sscratch", "ipend", "xslot",
};
static const char *const alu_nm[16] = {"add", "sub", "and", "or", "xor", "sll", "srl", "sra",
                                       "slt", "sltu", "mul", "mulhu", "divu", "remu", "div", "rem"};
static const char *const cf_nm[16] = {"cmov", "csplit", "cjoin", "cshare", "catomic", "crestrict", "cbase", "clen",
                                      "cperms", "cgive", "ctake", "cclear", "csave", "crestore", "cvalid", "cpoll"};
static const char *const c2_nm[8] = {"cdom", "crevoke", "cundom", "csend", "crecv", "cmkep", "csavex", "crestorex"};
static const char *const amo_nm[5] = {"add", "swap", "cas", "and", "or"};

/* The target of a branch or jump, with its label when known. */
static void dis_target(const Core *c, uint64_t t, char *out, size_t n) {
  char s[96];
  sym_code(c, t, s, sizeof s);
  if (s[0]) snprintf(out, n, "0x%llx <%s>", (unsigned long long)t, s);
  else snprintf(out, n, "0x%llx", (unsigned long long)t);
}

/* One instruction in sasm's syntax (common pseudo-instructions included). */
static void disasm(const Core *c, uint32_t ir, uint64_t pc, char *out, size_t n) {
  unsigned op = ir >> 26, rd = (ir >> 21) & 31, rs1 = (ir >> 16) & 31, rs2 = (ir >> 11) & 31;
  unsigned funct = ir & 0x7ff, imm16 = ir & 0xffff;
  long long simm = (int16_t)imm16;
  const char *D = xr_names[rd], *S1 = xr_names[rs1], *S2 = xr_names[rs2];
  char t[128];
  switch (op) {
  case OP_ALU:
    if (funct >> 4) break;
    if ((funct & 15) == ALU_SUB && !rs1) { snprintf(out, n, "neg   %s, %s", D, S2); return; }
    if ((funct & 15) == ALU_SLTU && !rs1) { snprintf(out, n, "snez  %s, %s", D, S2); return; }
    snprintf(out, n, "%-5s %s, %s, %s", alu_nm[funct & 15], D, S1, S2);
    return;
  case OP_ADDI:
    if (!rd && !rs1 && !simm) { snprintf(out, n, "nop"); return; }
    if (!rs1) { snprintf(out, n, "li    %s, %lld", D, simm); return; }
    if (!simm) { snprintf(out, n, "mv    %s, %s", D, S1); return; }
    snprintf(out, n, "addi  %s, %s, %lld", D, S1, simm);
    return;
  case OP_SLTI: snprintf(out, n, "slti  %s, %s, %lld", D, S1, simm); return;
  case OP_SLTIU:
    if (simm == 1) { snprintf(out, n, "seqz  %s, %s", D, S1); return; }
    snprintf(out, n, "sltiu %s, %s, %lld", D, S1, simm);
    return;
  case OP_ANDI: snprintf(out, n, "andi  %s, %s, 0x%x", D, S1, imm16); return;
  case OP_ORI: snprintf(out, n, "ori   %s, %s, 0x%x", D, S1, imm16); return;
  case OP_XORI: snprintf(out, n, "xori  %s, %s, 0x%x", D, S1, imm16); return;
  case OP_SLLI: snprintf(out, n, "slli  %s, %s, %u", D, S1, imm16 & 63); return;
  case OP_SRLI: snprintf(out, n, "srli  %s, %s, %u", D, S1, imm16 & 63); return;
  case OP_SRAI: snprintf(out, n, "srai  %s, %s, %u", D, S1, imm16 & 63); return;
  case OP_LUI: snprintf(out, n, "lui   %s, 0x%x", D, imm16); return;
  case OP_LD: case OP_LW: case OP_LWU: case OP_LH: case OP_LHU: case OP_LB: case OP_LBU: {
    static const char *const nm[] = {"ld", "lw", "lwu", "lh", "lhu", "lb", "lbu"};
    snprintf(out, n, "%-5s %s, %lld(%s)", nm[op - OP_LD], D, simm, S1);
    return;
  }
  case OP_SD: case OP_SW: case OP_SH: case OP_SB: {
    static const char *const nm[] = {"sd", "sw", "sh", "sb"};
    snprintf(out, n, "%-5s %s, %lld(%s)", nm[op - OP_SD], D, simm, S1);
    return;
  }
  case OP_BEQ: case OP_BNE: case OP_BLT: case OP_BGE: case OP_BLTU: case OP_BGEU: {
    static const char *const nm[] = {"beq", "bne", "blt", "bge", "bltu", "bgeu"};
    dis_target(c, pc + (uint64_t)(simm << 2), t, sizeof t);
    if (!rs1 && op <= OP_BGE) {
      static const char *const z[] = {"beqz", "bnez", "bltz", "bgez"};
      snprintf(out, n, "%-5s %s, %s", z[op - OP_BEQ], D, t);
    } else snprintf(out, n, "%-5s %s, %s, %s", nm[op - OP_BEQ], D, S1, t);
    return;
  }
  case OP_JAL:
    dis_target(c, pc + (uint64_t)(sext(ir & 0x1fffff, 21) << 2), t, sizeof t);
    if (!rd) snprintf(out, n, "j     %s", t);
    else if (rd == 1) snprintf(out, n, "call  %s", t);
    else snprintf(out, n, "jal   %s, %s", D, t);
    return;
  case OP_JALR:
    if (!rd && rs1 == 1 && !simm) { snprintf(out, n, "ret"); return; }
    if (!rd && !simm) { snprintf(out, n, "jr    %s", S1); return; }
    snprintf(out, n, "jalr  %s, %s, %lld", D, S1, simm);
    return;
  case OP_XFER: {
    unsigned sub = (ir >> 23) & 7, tg = (ir >> 19) & 15, rl = (ir >> 14) & 31, ci = (ir >> 10) & 15,
             ro = (ir >> 5) & 31, rn = ir & 31;
    static const char *const nm[] = {"tget", "tput", "tgetx"};
    if (sub > 2) break;
    snprintf(out, n, "%-5s tg%u, %s, c%u, %s, %s", nm[sub], tg, xr_names[rl], ci, xr_names[ro], xr_names[rn]);
    return;
  }
  case OP_TWAIT:
    if (imm16 == 0xffff) { snprintf(out, n, "tfence"); return; }
    /* fall through */
  case OP_TPOLL: {
    char m[128] = "";
    size_t k = 0;
    for (int i = 0; i < 16; i++)
      if (imm16 >> i & 1) k += (size_t)snprintf(m + k, sizeof m - k, "%stg%d", k ? ", " : "", i);
    if (!imm16) snprintf(m, sizeof m, "0");
    if (op == OP_TWAIT) snprintf(out, n, "twait %s", m);
    else snprintf(out, n, "tpoll %s, %s", D, m);
    return;
  }
  case OP_TANY: snprintf(out, n, "tany  %s, %s", D, S1); return;
  case OP_TAMO: {
    unsigned aop = funct & 7;
    if (aop > AMO_OR) break;
    snprintf(out, n, "tamo.%s %s, c%u, %s, %s", amo_nm[aop], D, (funct >> 7) & 15, S1, S2);
    return;
  }
  case OP_CAP: {
    unsigned fn = funct & 15, slot = (funct >> 5) & 63, cd = rd & 15, cs = rs1 & 15;
    switch (fn) {
    case CF_MOV: case CF_JOIN: case CF_SHARE: case CF_ATOM: snprintf(out, n, "%-5s c%u, c%u", cf_nm[fn], cd, cs); return;
    case CF_SPLIT: case CF_RESTR: snprintf(out, n, "%-5s c%u, c%u, %s", cf_nm[fn], cd, cs, S2); return;
    case CF_BASE: case CF_LEN: case CF_PERMS: case CF_VALID: snprintf(out, n, "%-5s %s, c%u", cf_nm[fn], D, cs); return;
    case CF_POLL: snprintf(out, n, "cpoll %s", D); return;
    case CF_GIVE: snprintf(out, n, "cgive c%u, %s", cs, S2); return;
    case CF_TAKE:
      if (funct & 16) snprintf(out, n, "ctake c%u, %s", cd, S2);
      else snprintf(out, n, "ctake c%u", cd);
      return;
    case CF_CLEAR: snprintf(out, n, "cclear c%u", cd); return;
    case CF_SAVE: snprintf(out, n, "csave c%u, %u", cs, slot); return;
    case CF_RESTORE: snprintf(out, n, "crestore c%u, %u", cd, slot); return;
    }
    break;
  }
  case OP_CAP2: {
    unsigned fn = funct & 15, cd = rd & 15, cs = rs1 & 15;
    if (fn > C2_RESTOREX) break;
    switch (fn) {
    case C2_SEND: snprintf(out, n, "csend c%u, c%u", cs, cd); return;
    case C2_MKEP: case C2_RESTOREX: snprintf(out, n, "%-5s c%u, %s", c2_nm[fn], cd, S2); return;
    case C2_SAVEX: snprintf(out, n, "csavex c%u, %s", cs, S2); return;
    default: snprintf(out, n, "%-5s c%u, c%u", c2_nm[fn], cd, cs); return;
    }
  }
  case OP_CSRR:
    if (imm16 < sizeof csr_nm / sizeof *csr_nm) snprintf(out, n, "csrr  %s, %s", D, csr_nm[imm16]);
    else snprintf(out, n, "csrr  %s, %u", D, imm16);
    return;
  case OP_CSRW:
    if (imm16 < sizeof csr_nm / sizeof *csr_nm) snprintf(out, n, "csrw  %s, %s", csr_nm[imm16], S1);
    else snprintf(out, n, "csrw  %u, %s", imm16, S1);
    return;
  case OP_SYS:
    if (imm16 == SYS_HALT) { snprintf(out, n, "halt"); return; }
    if (imm16 == SYS_ERET) { snprintf(out, n, "eret"); return; }
    if (imm16 == SYS_SVC) { snprintf(out, n, "svc"); return; }
    break;
  case OP_LTAG: snprintf(out, n, "ltag  %s, %s", D, S1); return;
  case OP_LINST: snprintf(out, n, "linst %s", S1); return;
  case OP_XMAP:
    if (funct & 16) snprintf(out, n, "xunmap %u", rd);
    else snprintf(out, n, "xmap  %u, %s, c%u, %s", rd, S1, funct & 15, S2);
    return;
  case OP_XCALL:
    if (funct & 16) snprintf(out, n, "xret  %s", S1);
    else snprintf(out, n, "xcall %s, c%u, %s", D, funct & 15, S1);
    return;
  }
  snprintf(out, n, ".word 0x%08x", ir);
}
