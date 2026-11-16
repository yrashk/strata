/* sasm: two-pass assembler for the Strata prototype ISA.
 *
 *   sasm [-o out.stx] [-l] [-g out.map] [-I dir] file.s
 *
 * Sections, each with its own address space starting at 0:
 *   .text     instruction Local Store (I-LS)
 *   .data     data Local Store (D-LS)
 *   .far      system memory (T3), segment offsets
 *   .cluster  cluster store (T2), segment offsets
 *
 * Output is an .stx image: "STX2", u32 count, then per section
 * u32 kind, u32 base, u32 size, u32 reserved, then the bytes padded to a
 * multiple of 8. `base` is the lowest address the section uses, so every
 * piece of the file is 8-byte aligned and can be moved with transfers.
 *
 *   -T addr   start .text at addr instead of 0 (programs run under StrataOS
 *             use -T 0x8000)
 *   -g file   also write a symbol and line map for the debuggers (see
 *             write_map below; doc/debug-protocol.md describes the format)
 *
 * A StrataOS program (-T 0x8000) is assembled, unless told otherwise, with
 * paged code and far data (doc/big-code-proposal.md; "Paged code and far
 * data" below):
 *   -r        resident code: no paging (also the directive .resident)
 *   -n        near data: no far data cache (also the directive .near)
 *   -u KIB    the code unit size, 1, 2 or 4 KiB (default 2)
 *   -c KIB    the far data cache, 1 to 16 KiB (default 4)
 *   -v        print the layout: each group of code, where it went and why
 * A bare-metal program (text origin 0) is always resident and near. */
#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "isa.h"

/* ------------------------------------------------------------ diagnostics */

static const char *cur_file = "?";
static int cur_line = 0;
static int nerrors = 0;

static void err(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "%s:%d: error: ", cur_file, cur_line);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  nerrors++;
}

static void *xmalloc(size_t n) {
  void *p = calloc(1, n);
  if (!p) { perror("calloc"); exit(1); }
  return p;
}

static char *xstrdup(const char *s) {
  char *p = xmalloc(strlen(s) + 1);
  strcpy(p, s);
  return p;
}

/* ------------------------------------------------------------ source lines */

typedef struct { const char *file; int line; char *text; } Line;

static Line *lines;
static int nlines, caplines;
static const char *incdirs[16];
static int nincdirs;

static void add_line(const char *file, int no, const char *text) {
  if (nlines == caplines) {
    caplines = caplines ? caplines * 2 : 256;
    lines = realloc(lines, caplines * sizeof *lines);
  }
  lines[nlines++] = (Line){file, no, xstrdup(text)};
}

static FILE *open_include(const char *name, const char *from, char **found) {
  char path[1024];
  const char *slash = strrchr(from, '/');
  if (slash) {
    snprintf(path, sizeof path, "%.*s/%s", (int)(slash - from), from, name);
    FILE *f = fopen(path, "r");
    if (f) { *found = xstrdup(path); return f; }
  }
  FILE *f = fopen(name, "r");
  if (f) { *found = xstrdup(name); return f; }
  for (int i = 0; i < nincdirs; i++) {
    snprintf(path, sizeof path, "%s/%s", incdirs[i], name);
    f = fopen(path, "r");
    if (f) { *found = xstrdup(path); return f; }
  }
  return NULL;
}

static void read_file(const char *path, int depth) {
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "sasm: cannot open %s: %s\n", path, strerror(errno)); exit(1); }
  char buf[4096];
  int no = 0;
  const char *fname = xstrdup(path);
  while (fgets(buf, sizeof buf, f)) {
    no++;
    buf[strcspn(buf, "\r\n")] = 0;
    const char *p = buf;
    while (isspace((unsigned char)*p)) p++;
    if (!strncmp(p, ".include", 8) && isspace((unsigned char)p[8])) {
      const char *q = strchr(p, '"');
      const char *e = q ? strchr(q + 1, '"') : NULL;
      if (!q || !e) { cur_file = fname; cur_line = no; err(".include needs \"file\""); continue; }
      char name[1024];
      snprintf(name, sizeof name, "%.*s", (int)(e - q - 1), q + 1);
      char *found;
      FILE *g = open_include(name, fname, &found);
      if (!g) { cur_file = fname; cur_line = no; err("cannot find include %s", name); continue; }
      fclose(g);
      if (depth > 16) { cur_file = fname; cur_line = no; err("include nesting too deep"); continue; }
      read_file(found, depth + 1);
      continue;
    }
    add_line(fname, no, buf);
  }
  fclose(f);
}

/* ------------------------------------------------------------ sections */

enum { S_TEXT, S_DATA, S_FAR, S_CLUSTER, S_UNITS, NSECT };

typedef struct {
  const char *name;
  int kind;
  uint32_t limit;
  uint8_t *buf;
  uint32_t loc, size;
  uint32_t lo;   /* lowest address emitted */
  uint32_t org;  /* starting location */
} Section;

static Section sects[NSECT] = {
  {".text", SK_ILS, ILS_BYTES, 0, 0, 0, 0, 0},
  {".data", SK_DLS, DLS_BYTES, 0, 0, 0, 0, 0},
  {".far", SK_T3, T3_BYTES, 0, 0, 0, 0, 0},
  {".cluster", SK_T2, T2_BYTES, 0, 0, 0, 0, 0},
  {"(units)", SK_UNITS, 1u << 20, 0, 0, 0, 0, 0}, /* paged code: image offsets (not a directive) */
};
static int cs; /* current section */
static uint32_t text_org;
static int pass;
static int cur_li; /* the line being assembled */

/* ------------------------------------------------------------ paged code and far data: state */

static int opt_paged = -1, opt_far = -1; /* -1: by the text origin (on for StrataOS programs) */
static int ulg = 11;                     /* log2 of a code unit */
static int cache_kib = 4;                /* the far data cache */
static int opt_report;                   /* -v: print the layout */

/* .text labels, as the pre-scan finds them */
typedef struct { char *name; int region, func, taken; } TLabel;
static TLabel *tlabs;
static int ntlabs, captlabs;
static int *lsect;  /* per line: the section its contents go to (before the line's own directive) */
static int *lreg;   /* per line: its .text region, -1 for lines outside .text */
static int nregions;
static int *rgroup, *rpinned, *rfirst; /* per region: group, pinned, first line */
static int *rjoin;  /* per region: joined to the next one (a branch, a jump or a fall-through) */
static int *rwhy;   /* per region: the line that joined it to the next */
static int ngroups;
static int *gpinned, *gsect, *gfirst;   /* per group: pinned, actual section, first region */
static uint32_t *gbase, *gloc, *gsize;  /* per group: where it starts, where it is now, its bytes */
static int first_insn_line = -1;        /* the program's entry: its first .text instruction */
static uint32_t pinned_end, ubase;      /* the end of pinned code; the first unit's offset */
static uint32_t user_far_end;           /* the end of the program's own .far contents */
static const char *entry_target;        /* the entry's own `j` target */
static int paged_transfer(int rd, const char *target, int tail);
static int paged_branch(int op, int a, int b, const char *target);
static int line_paged(void);
static void emit_flink(uint32_t ret);

static void emit_byte(uint8_t b) {
  Section *s = &sects[cs];
  if (s->loc >= s->limit) {
    if (pass == 2) err("section %s overflows its %u bytes", s->name, s->limit);
    s->loc++;
    return;
  }
  if (pass == 2) s->buf[s->loc] = b;
  if (s->loc < s->lo) s->lo = s->loc;
  s->loc++;
  if (s->loc > s->size) s->size = s->loc;
}

static void emit_le(uint64_t v, int n) {
  for (int i = 0; i < n; i++) emit_byte((uint8_t)(v >> (8 * i)));
}

/* ------------------------------------------------------------ symbols */

typedef struct { char *name; int64_t value; int sect; int defined; } Sym;
static Sym *syms;
static int nsyms, capsyms;

static Sym *sym_find(const char *name) {
  for (int i = 0; i < nsyms; i++)
    if (!strcmp(syms[i].name, name)) return &syms[i];
  return NULL;
}

static Sym *sym_get(const char *name) {
  Sym *s = sym_find(name);
  if (s) return s;
  if (nsyms == capsyms) {
    capsyms = capsyms ? capsyms * 2 : 128;
    syms = realloc(syms, capsyms * sizeof *syms);
  }
  syms[nsyms] = (Sym){xstrdup(name), 0, -1, 0};
  return &syms[nsyms++];
}

static void sym_define(const char *name, int64_t v, int sect) {
  Sym *s = sym_get(name);
  if (pass == 1) {
    if (s->defined) { err("symbol %s redefined", name); return; }
    s->defined = 1;
  } else if (s->value != v) {
    err("symbol %s changed value between passes (internal)", name);
  }
  s->value = v;
  s->sect = sect;
}

/* ------------------------------------------------------------ expressions */

static const char *ep;     /* expression cursor */
static int eundef;         /* an undefined symbol was referenced */
static int esect;          /* section of the symbol referenced, -1 if none */

static void skipws(void) { while (isspace((unsigned char)*ep)) ep++; }

static int is_symstart(int c) { return isalpha(c) || c == '_' || c == '.' || c == '$'; }
static int is_symchar(int c) { return isalnum(c) || c == '_' || c == '.' || c == '$'; }

static int64_t e_or(void);

static int64_t e_primary(void) {
  skipws();
  if (*ep == '(') {
    ep++;
    int64_t v = e_or();
    skipws();
    if (*ep == ')') ep++; else err("expected ')'");
    return v;
  }
  if (*ep == '\'') {
    ep++;
    int c = (unsigned char)*ep++;
    if (c == '\\') {
      int e = *ep++;
      c = e == 'n' ? '\n' : e == 't' ? '\t' : e == '0' ? 0 : e == 'r' ? '\r' : e;
    }
    if (*ep == '\'') ep++; else err("bad character literal");
    return c;
  }
  if (isdigit((unsigned char)*ep)) {
    char *end;
    uint64_t v;
    if (ep[0] == '0' && (ep[1] == 'b' || ep[1] == 'B')) v = strtoull(ep + 2, &end, 2);
    else v = strtoull(ep, &end, 0);
    ep = end;
    return (int64_t)v;
  }
  if (is_symstart((unsigned char)*ep)) {
    char name[256];
    int n = 0;
    while (is_symchar((unsigned char)*ep) && n < 255) name[n++] = *ep++;
    name[n] = 0;
    if (!strcmp(name, ".")) { esect = cs; return sects[cs].loc; }
    Sym *s = sym_find(name);
    if (!s || !s->defined) {
      eundef = 1;
      if (pass == 2) err("undefined symbol %s", name);
      return 0;
    }
    if (s->sect >= 0) esect = s->sect;
    return s->value;
  }
  err("bad expression near '%s'", ep);
  ep += strlen(ep);
  return 0;
}

static int64_t e_unary(void) {
  skipws();
  if (*ep == '-') { ep++; return -e_unary(); }
  if (*ep == '+') { ep++; return e_unary(); }
  if (*ep == '~') { ep++; return ~e_unary(); }
  return e_primary();
}

static int64_t e_mul(void) {
  int64_t v = e_unary();
  for (;;) {
    skipws();
    char c = *ep;
    if (c != '*' && c != '/' && c != '%') return v;
    ep++;
    int64_t r = e_unary();
    if (c == '*') v *= r;
    else if (r == 0) { if (!eundef) err("division by zero"); v = 0; }
    else v = c == '/' ? v / r : v % r;
  }
}

static int64_t e_add(void) {
  int64_t v = e_mul();
  for (;;) {
    skipws();
    if (*ep == '+') { ep++; v += e_mul(); }
    else if (*ep == '-') { ep++; v -= e_mul(); }
    else return v;
  }
}

static int64_t e_shift(void) {
  int64_t v = e_add();
  for (;;) {
    skipws();
    if (ep[0] == '<' && ep[1] == '<') { ep += 2; v = (int64_t)((uint64_t)v << (e_add() & 63)); }
    else if (ep[0] == '>' && ep[1] == '>') { ep += 2; v >>= (e_add() & 63); }
    else return v;
  }
}

static int64_t e_and(void) {
  int64_t v = e_shift();
  for (skipws(); *ep == '&'; skipws()) { ep++; v &= e_shift(); }
  return v;
}

static int64_t e_xor(void) {
  int64_t v = e_and();
  for (skipws(); *ep == '^'; skipws()) { ep++; v ^= e_and(); }
  return v;
}

static int64_t e_or(void) {
  int64_t v = e_xor();
  for (skipws(); *ep == '|'; skipws()) { ep++; v |= e_xor(); }
  return v;
}

/* Evaluate a whole operand. *undef is set when a symbol is not yet known. */
static int64_t eval(const char *s, int *undef) {
  ep = s;
  eundef = 0;
  esect = -1;
  int64_t v = e_or();
  skipws();
  if (*ep) err("junk after expression: '%s'", ep);
  if (undef) *undef = eundef;
  return v;
}

/* ------------------------------------------------------------ operands */

#define MAXOPS 8

static char *trim(char *s) {
  while (isspace((unsigned char)*s)) s++;
  char *e = s + strlen(s);
  while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
  return s;
}

/* Split on top-level commas (outside parentheses and quotes). */
static int split_ops(char *s, char **ops) {
  int n = 0, depth = 0;
  char q = 0;
  char *start = s;
  s = trim(s);
  if (!*s) return 0;
  start = s;
  for (char *p = s;; p++) {
    if (q) {
      if (*p == '\\' && p[1]) { p++; continue; }
      if (*p == q) q = 0;
      if (!*p) break;
      continue;
    }
    if (*p == '"' || *p == '\'') { q = *p; continue; }
    if (*p == '(') depth++;
    if (*p == ')') depth--;
    if ((*p == ',' && depth == 0) || !*p) {
      int end = !*p;
      *p = 0;
      if (n < MAXOPS) ops[n++] = trim(start);
      else err("too many operands");
      if (end) break;
      start = p + 1;
    }
  }
  return n;
}

static const char *xreg_names[32] = {
  "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

static int parse_xreg(const char *s) {
  if (s[0] == 'x' && isdigit((unsigned char)s[1])) {
    char *e;
    long n = strtol(s + 1, &e, 10);
    if (!*e && n >= 0 && n < 32) return (int)n;
  }
  if (!strcmp(s, "fp")) return 8;
  for (int i = 0; i < 32; i++)
    if (!strcmp(s, xreg_names[i])) return i;
  return -1;
}

static int xreg(const char *s) {
  int r = parse_xreg(s);
  if (r < 0) err("expected integer register, got '%s'", s);
  return r < 0 ? 0 : r;
}

static int numbered(const char *s, const char *prefix, int max) {
  size_t n = strlen(prefix);
  if (strncmp(s, prefix, n) || !isdigit((unsigned char)s[n])) return -1;
  char *e;
  long v = strtol(s + n, &e, 10);
  return (!*e && v >= 0 && v < max) ? (int)v : -1;
}

static int creg(const char *s) {
  int r = numbered(s, "c", 16);
  if (r < 0) err("expected capability register c0..c15, got '%s'", s);
  return r < 0 ? 0 : r;
}

static int tagreg(const char *s) {
  int r = numbered(s, "tg", 16);
  if (r < 0) err("expected transfer tag tg0..tg15, got '%s'", s);
  return r < 0 ? 0 : r;
}

static const char *csr_names[] = {
  "cycle", "instret", "cause", "epc", "tval", "tvec", "ccr", "coreid",
  "ttag", "tdata", "tgeom", "ncores", "scratch", "stalls", "takefrom", "corebase",
  "corecount", "reserved17", "status", "ucause", "uepc", "utval", "utvec", "sscratch",
  "ipend", "xslot", "wdata", "wstack", "wcode",
};

static int csrnum(const char *s) {
  for (unsigned i = 0; i < sizeof csr_names / sizeof *csr_names; i++)
    if (!strcmp(s, csr_names[i])) return (int)i;
  int u;
  int64_t v = eval(s, &u);
  if (v < 0 || v > 0xffff) err("CSR number out of range");
  return (int)(v & 0xffff);
}

static int64_t value(const char *s) {
  int u;
  return eval(s, &u);
}

/* imm(reg) or (reg) */
static void memop(char *s, int64_t *imm, int *reg) {
  size_t n = strlen(s);
  char *open = NULL;
  if (n && s[n - 1] == ')') {
    int depth = 0;
    for (char *p = s + n - 1; p >= s; p--) {
      if (*p == ')') depth++;
      if (*p == '(' && --depth == 0) { open = p; break; }
    }
  }
  if (!open) { err("expected offset(register), got '%s'", s); *imm = 0; *reg = 0; return; }
  s[n - 1] = 0;
  *reg = xreg(trim(open + 1));
  *open = 0;
  char *off = trim(s);
  *imm = *off ? value(off) : 0;
}

/* ------------------------------------------------------------ encoding */

static uint32_t enc_r(int op, int rd, int rs1, int rs2, int funct) {
  return (uint32_t)op << 26 | (uint32_t)rd << 21 | (uint32_t)rs1 << 16 | (uint32_t)rs2 << 11 |
         (uint32_t)(funct & 0x7ff);
}

static uint32_t enc_i(int op, int rd, int rs1, int64_t imm) {
  return (uint32_t)op << 26 | (uint32_t)rd << 21 | (uint32_t)rs1 << 16 | (uint32_t)(imm & 0xffff);
}

static void emit_insn(uint32_t w) {
  if (sects[cs].loc & 3) err("instruction not 4-byte aligned in %s", sects[cs].name);
  emit_le(w, 4);
}

static void check_simm16(int64_t v) {
  if (pass == 2 && (v < -32768 || v > 32767)) err("immediate %lld does not fit in signed 16 bits", (long long)v);
}

static void check_uimm16(int64_t v) {
  if (pass == 2 && (v < 0 || v > 65535)) err("immediate %lld does not fit in unsigned 16 bits", (long long)v);
}

/* lui takes the upper half of a value, so either reading of the 16 bits is fine */
static void check_imm16(int64_t v) {
  if (pass == 2 && (v < -32768 || v > 65535)) err("immediate %lld does not fit in 16 bits", (long long)v);
}

/* twait / tpoll operand: a list of tags (tg0, tg3, ...) or one mask expression */
static int64_t tagmask(char **o, int n) {
  if (n >= 1 && !strncmp(o[0], "tg", 2)) {
    int64_t m = 0;
    for (int i = 0; i < n; i++) m |= (int64_t)1 << tagreg(o[i]);
    return m;
  }
  if (n != 1) err("expected a list of tags or one mask");
  int64_t v = n ? value(o[0]) : 0;
  check_uimm16(v);
  return v;
}

/* PC-relative word offset from the current instruction to target. */
static int64_t pcrel(const char *s, int bits) {
  int u;
  int64_t t = eval(s, &u);
  if (pass == 1 || u) return 0;
  if (esect >= 0 && esect != cs) err("branch target %s is in another section", s);
  int64_t d = t - (int64_t)sects[cs].loc;
  if (d & 3) err("branch target not 4-byte aligned");
  d >>= 2;
  int64_t lim = (int64_t)1 << (bits - 1);
  if (d < -lim || d >= lim) err("branch target out of range");
  return d;
}

/* li sizes decided in pass 1, replayed in pass 2 */
static int *li_sizes;
static int nli, capli, li_idx;

static int li_size(int64_t v, int undef) {
  if (undef) return 6;
  if (v >= -32768 && v <= 32767) return 1;
  if (v >= -2147483648LL && v <= 2147483647LL) return 2;
  return 6;
}

static void gen_li(int rd, int64_t v, int n) {
  if (n == 1) { emit_insn(enc_i(OP_ADDI, rd, 0, v)); return; }
  if (n == 2) {
    emit_insn(enc_i(OP_LUI, rd, 0, (v >> 16) & 0xffff));
    emit_insn(enc_i(OP_ORI, rd, rd, v & 0xffff));
    return;
  }
  int64_t hi = v >> 32;
  emit_insn(enc_i(OP_LUI, rd, 0, (hi >> 16) & 0xffff));
  emit_insn(enc_i(OP_ORI, rd, rd, hi & 0xffff));
  emit_insn(enc_i(OP_SLLI, rd, rd, 16));
  emit_insn(enc_i(OP_ORI, rd, rd, (v >> 16) & 0xffff));
  emit_insn(enc_i(OP_SLLI, rd, rd, 16));
  emit_insn(enc_i(OP_ORI, rd, rd, v & 0xffff));
}

static void do_li(int rd, const char *expr, int is_la) {
  int u;
  int64_t v = eval(expr, &u);
  int n;
  if (pass == 1) {
    n = is_la ? 2 : li_size(v, u);
    if (nli == capli) { capli = capli ? capli * 2 : 64; li_sizes = realloc(li_sizes, capli * sizeof(int)); }
    li_sizes[nli++] = n;
  } else {
    n = li_sizes[li_idx++];
    if (li_size(v, 0) > n) err("li value changed size between passes");
    if (is_la && (v < 0 || v > 0x7fffffff)) err("la address out of range");
  }
  gen_li(rd, v, n);
}

/* ------------------------------------------------------------ instruction table */

enum {
  F_R, F_I, F_IU, F_SH, F_LUI, F_LD, F_ST, F_B, F_JAL, F_JALR,
  F_XF, F_TWAIT, F_TPOLL, F_AMO,
  F_C_CDCS, F_C_CDCSRX, F_C_RDCS, F_C_CSRX, F_C_CD, F_C_CSSLOT, F_C_CDSLOT,
  F_CSRR, F_CSRW, F_SYS, F_LTAG, F_LINST, F_XMAP, F_XUNMAP, F_XCALL, F_XRET,
  F_C2_CDCS, F_C2_SEND, F_C2_MKEP, F_C2_CSRX,
};

typedef struct { const char *name; int fmt, op, fn, nops; } Insn;

static const Insn insns[] = {
  {"add", F_R, OP_ALU, ALU_ADD, 3}, {"sub", F_R, OP_ALU, ALU_SUB, 3},
  {"and", F_R, OP_ALU, ALU_AND, 3}, {"or", F_R, OP_ALU, ALU_OR, 3},
  {"xor", F_R, OP_ALU, ALU_XOR, 3}, {"sll", F_R, OP_ALU, ALU_SLL, 3},
  {"srl", F_R, OP_ALU, ALU_SRL, 3}, {"sra", F_R, OP_ALU, ALU_SRA, 3},
  {"slt", F_R, OP_ALU, ALU_SLT, 3}, {"sltu", F_R, OP_ALU, ALU_SLTU, 3},
  {"mul", F_R, OP_ALU, ALU_MUL, 3}, {"mulhu", F_R, OP_ALU, ALU_MULHU, 3},
  {"divu", F_R, OP_ALU, ALU_DIVU, 3}, {"remu", F_R, OP_ALU, ALU_REMU, 3},
  {"div", F_R, OP_ALU, ALU_DIV, 3}, {"rem", F_R, OP_ALU, ALU_REM, 3},
  {"addi", F_I, OP_ADDI, 0, 3}, {"slti", F_I, OP_SLTI, 0, 3}, {"sltiu", F_I, OP_SLTIU, 0, 3},
  {"andi", F_IU, OP_ANDI, 0, 3}, {"ori", F_IU, OP_ORI, 0, 3}, {"xori", F_IU, OP_XORI, 0, 3},
  {"slli", F_SH, OP_SLLI, 0, 3}, {"srli", F_SH, OP_SRLI, 0, 3}, {"srai", F_SH, OP_SRAI, 0, 3},
  {"lui", F_LUI, OP_LUI, 0, 2},
  {"ld", F_LD, OP_LD, 0, 2}, {"lw", F_LD, OP_LW, 0, 2}, {"lwu", F_LD, OP_LWU, 0, 2},
  {"lh", F_LD, OP_LH, 0, 2}, {"lhu", F_LD, OP_LHU, 0, 2}, {"lb", F_LD, OP_LB, 0, 2},
  {"lbu", F_LD, OP_LBU, 0, 2},
  {"sd", F_ST, OP_SD, 0, 2}, {"sw", F_ST, OP_SW, 0, 2}, {"sh", F_ST, OP_SH, 0, 2},
  {"sb", F_ST, OP_SB, 0, 2},
  {"beq", F_B, OP_BEQ, 0, 3}, {"bne", F_B, OP_BNE, 0, 3}, {"blt", F_B, OP_BLT, 0, 3},
  {"bge", F_B, OP_BGE, 0, 3}, {"bltu", F_B, OP_BLTU, 0, 3}, {"bgeu", F_B, OP_BGEU, 0, 3},
  {"jal", F_JAL, OP_JAL, 0, 2}, {"jalr", F_JALR, OP_JALR, 0, 3},
  {"tget", F_XF, OP_XFER, XF_GET, 5}, {"tput", F_XF, OP_XFER, XF_PUT, 5},
  {"tgetx", F_XF, OP_XFER, XF_GETX, 5},
  {"twait", F_TWAIT, OP_TWAIT, 0, 1}, {"tpoll", F_TPOLL, OP_TPOLL, 0, 2},
  {"tany", F_LTAG /* rd, rs1 */, OP_TANY, 0, 2},
  {"tamo.add", F_AMO, OP_TAMO, AMO_ADD, 4}, {"tamo.swap", F_AMO, OP_TAMO, AMO_SWAP, 4},
  {"tamo.cas", F_AMO, OP_TAMO, AMO_CAS, 4}, {"tamo.and", F_AMO, OP_TAMO, AMO_AND, 4},
  {"tamo.or", F_AMO, OP_TAMO, AMO_OR, 4},
  {"cmov", F_C_CDCS, OP_CAP, CF_MOV, 2}, {"cjoin", F_C_CDCS, OP_CAP, CF_JOIN, 2},
  {"cshare", F_C_CDCS, OP_CAP, CF_SHARE, 2}, {"catomic", F_C_CDCS, OP_CAP, CF_ATOM, 2},
  {"csplit", F_C_CDCSRX, OP_CAP, CF_SPLIT, 3}, {"crestrict", F_C_CDCSRX, OP_CAP, CF_RESTR, 3},
  {"cbase", F_C_RDCS, OP_CAP, CF_BASE, 2}, {"clen", F_C_RDCS, OP_CAP, CF_LEN, 2},
  {"cperms", F_C_RDCS, OP_CAP, CF_PERMS, 2}, {"cvalid", F_C_RDCS, OP_CAP, CF_VALID, 2},
  {"cpoll", F_CSRR /* rd only */, OP_CAP, CF_POLL, 1},
  {"cgive", F_C_CSRX, OP_CAP, CF_GIVE, 2},
  {"ctake", F_C_CD, OP_CAP, CF_TAKE, 1}, {"cclear", F_C_CD, OP_CAP, CF_CLEAR, 1},
  {"csave", F_C_CSSLOT, OP_CAP, CF_SAVE, 2}, {"crestore", F_C_CDSLOT, OP_CAP, CF_RESTORE, 2},
  {"csrr", F_CSRR, OP_CSRR, 0, 2}, {"csrw", F_CSRW, OP_CSRW, 0, 2},
  {"halt", F_SYS, OP_SYS, SYS_HALT, 0}, {"eret", F_SYS, OP_SYS, SYS_ERET, 0},
  {"svc", F_SYS, OP_SYS, 2 /* SYS_SVC */, 0},
  {"ltag", F_LTAG, OP_LTAG, 0, 2}, {"linst", F_LINST, OP_LINST, 0, 1},
  {"xmap", F_XMAP, OP_XMAP, 0, 4}, {"xunmap", F_XUNMAP, OP_XMAP, 0, 1},
  {"xcall", F_XCALL, OP_XCALL, 0, 3}, {"xret", F_XRET, OP_XCALL, 0, 1},
  {"cdom", F_C2_CDCS, OP_CAP2, C2_DOM, 2}, {"crevoke", F_C2_CDCS, OP_CAP2, C2_REVOKE, 2},
  {"cundom", F_C2_CDCS, OP_CAP2, C2_UNDOM, 2}, {"crecv", F_C2_CDCS, OP_CAP2, C2_RECV, 2},
  {"csend", F_C2_SEND, OP_CAP2, C2_SEND, 2}, {"cmkep", F_C2_MKEP, OP_CAP2, C2_MKEP, 2},
  {"csavex", F_C2_CSRX, OP_CAP2, C2_SAVEX, 2}, {"crestorex", F_C2_MKEP, OP_CAP2, C2_RESTOREX, 2},
};

static const Insn *find_insn(const char *m) {
  for (unsigned i = 0; i < sizeof insns / sizeof *insns; i++)
    if (!strcmp(insns[i].name, m)) return &insns[i];
  return NULL;
}

static void assemble_insn(const Insn *in, char **o, int n) {
  if (in->fmt == F_TWAIT) { emit_insn(enc_i(in->op, 0, 0, tagmask(o, n) & 0xffff)); return; }
  if (in->fmt == F_TPOLL) {
    if (n < 2) { err("tpoll rd, tags"); return; }
    emit_insn(enc_i(in->op, xreg(o[0]), 0, tagmask(o + 1, n - 1) & 0xffff));
    return;
  }
  if (in->fmt == F_C_CD && in->fn == CF_TAKE && n == 2) { /* ctake cd, rs: only from that sender */
    emit_insn(enc_r(in->op, creg(o[0]), 0, xreg(o[1]), 1 << 4 | in->fn));
    return;
  }
  if (n != in->nops) { err("%s takes %d operand(s), got %d", in->name, in->nops, n); return; }
  int64_t imm;
  int r;
  switch (in->fmt) {
  case F_R: emit_insn(enc_r(in->op, xreg(o[0]), xreg(o[1]), xreg(o[2]), in->fn)); break;
  case F_I: imm = value(o[2]); check_simm16(imm); emit_insn(enc_i(in->op, xreg(o[0]), xreg(o[1]), imm)); break;
  case F_IU: imm = value(o[2]); check_uimm16(imm); emit_insn(enc_i(in->op, xreg(o[0]), xreg(o[1]), imm)); break;
  case F_SH:
    imm = value(o[2]);
    if (pass == 2 && (imm < 0 || imm > 63)) err("shift amount out of range");
    emit_insn(enc_i(in->op, xreg(o[0]), xreg(o[1]), imm & 63));
    break;
  case F_LUI: imm = value(o[1]); check_imm16(imm); emit_insn(enc_i(in->op, xreg(o[0]), 0, imm)); break;
  case F_LD: memop(o[1], &imm, &r); check_simm16(imm); emit_insn(enc_i(in->op, xreg(o[0]), r, imm)); break;
  case F_ST: memop(o[1], &imm, &r); check_simm16(imm); emit_insn(enc_i(in->op, xreg(o[0]), r, imm)); break;
  case F_B:
    if (paged_branch(in->op, xreg(o[0]), xreg(o[1]), o[2])) break;
    emit_insn(enc_i(in->op, xreg(o[0]), xreg(o[1]), pcrel(o[2], 16)));
    break;
  case F_JAL:
    r = xreg(o[0]);
    if ((r == 0 || r == 1) && paged_transfer(r, o[1], r == 0)) break;
    emit_insn((uint32_t)in->op << 26 | (uint32_t)r << 21 | (uint32_t)(pcrel(o[1], 21) & 0x1fffff));
    break;
  case F_JALR:
    imm = value(o[2]);
    check_simm16(imm);
    if (opt_paged && xreg(o[0]) == 0 && imm == 0) { emit_insn(enc_r(OP_XCALL, 0, xreg(o[1]), 0, 1 << 4)); break; }
    if (line_paged()) {
      r = xreg(o[1]);
      if (xreg(o[0]) != 1 || imm != 0 || r == 1 || r == 31)
        err("paged code: only `jalr ra, rs, 0` (rs not ra or t6) is allowed; pin this function (.pinned) or use -r");
      emit_flink(sects[cs].loc + 4 * 8);
      emit_insn(enc_i(in->op, 0, r, 0));               /* jalr zero, rs, 0 */
      break;
    }
    emit_insn(enc_i(in->op, xreg(o[0]), xreg(o[1]), imm));
    break;
  case F_XF:
    emit_insn((uint32_t)in->op << 26 | (uint32_t)in->fn << 23 | (uint32_t)tagreg(o[0]) << 19 |
              (uint32_t)xreg(o[1]) << 14 | (uint32_t)creg(o[2]) << 10 | (uint32_t)xreg(o[3]) << 5 |
              (uint32_t)xreg(o[4]));
    break;
  case F_AMO:
    emit_insn(enc_r(in->op, xreg(o[0]), xreg(o[2]), xreg(o[3]), creg(o[1]) << 7 | in->fn));
    break;
  case F_C_CDCS: emit_insn(enc_r(in->op, creg(o[0]), creg(o[1]), 0, in->fn)); break;
  case F_C_CDCSRX: emit_insn(enc_r(in->op, creg(o[0]), creg(o[1]), xreg(o[2]), in->fn)); break;
  case F_C_RDCS: emit_insn(enc_r(in->op, xreg(o[0]), creg(o[1]), 0, in->fn)); break;
  case F_C_CSRX: emit_insn(enc_r(in->op, 0, creg(o[0]), xreg(o[1]), in->fn)); break;
  case F_C_CD: emit_insn(enc_r(in->op, creg(o[0]), 0, 0, in->fn)); break;
  case F_C_CSSLOT:
  case F_C_CDSLOT:
    imm = value(o[1]);
    if (pass == 2 && (imm < 0 || imm > 63)) err("capability slot out of range 0..63");
    if (in->fmt == F_C_CSSLOT) emit_insn(enc_r(in->op, 0, creg(o[0]), 0, (int)(imm & 63) << 5 | in->fn));
    else emit_insn(enc_r(in->op, creg(o[0]), 0, 0, (int)(imm & 63) << 5 | in->fn));
    break;
  case F_CSRR:
    if (in->op == OP_CAP) emit_insn(enc_r(in->op, xreg(o[0]), 0, 0, in->fn)); /* cpoll rd */
    else emit_insn(enc_i(in->op, xreg(o[0]), 0, csrnum(o[1])));
    break;
  case F_CSRW: emit_insn(enc_i(in->op, 0, xreg(o[1]), csrnum(o[0]))); break;
  case F_SYS: emit_insn(enc_i(in->op, 0, 0, in->fn)); break;
  case F_LTAG: emit_insn(enc_i(in->op, xreg(o[0]), xreg(o[1]), 0)); break;
  case F_LINST: emit_insn(enc_i(in->op, 0, xreg(o[0]), 0)); break;
  case F_XMAP:
  case F_XUNMAP:
    imm = value(o[0]);
    if (pass == 2 && (imm < 0 || imm > 15)) err("overlay map index out of range 0..15");
    if (in->fmt == F_XMAP) emit_insn(enc_r(in->op, (int)(imm & 15), xreg(o[1]), xreg(o[3]), creg(o[2])));
    else emit_insn(enc_r(in->op, (int)(imm & 15), 0, 0, 1 << 4));
    break;
  case F_XCALL: emit_insn(enc_r(in->op, xreg(o[0]), xreg(o[2]), 0, creg(o[1]))); break;
  case F_XRET: emit_insn(enc_r(in->op, 0, xreg(o[0]), 0, 1 << 4)); break;
  case F_C2_CDCS: emit_insn(enc_r(in->op, creg(o[0]), creg(o[1]), 0, in->fn)); break;
  case F_C2_SEND: emit_insn(enc_r(in->op, creg(o[1]), creg(o[0]), 0, in->fn)); break; /* csend cs, ce */
  case F_C2_MKEP: emit_insn(enc_r(in->op, creg(o[0]), 0, xreg(o[1]), in->fn)); break; /* also crestorex cd, rx */
  case F_C2_CSRX: emit_insn(enc_r(in->op, 0, creg(o[0]), xreg(o[1]), in->fn)); break;  /* csavex cs, rx */
  }
}

/* Pseudo-instructions. Returns 1 if handled. */
static int pseudo(const char *m, char **o, int n) {
#define NEED(k) do { if (n != (k)) { err("%s takes %d operand(s)", m, (k)); return 1; } } while (0)
  if (!strcmp(m, "nop")) { NEED(0); emit_insn(enc_i(OP_ADDI, 0, 0, 0)); return 1; }
  if (!strcmp(m, "mv")) { NEED(2); emit_insn(enc_i(OP_ADDI, xreg(o[0]), xreg(o[1]), 0)); return 1; }
  if (!strcmp(m, "li")) { NEED(2); do_li(xreg(o[0]), o[1], 0); return 1; }
  if (!strcmp(m, "la")) { NEED(2); do_li(xreg(o[0]), o[1], 1); return 1; }
  if (!strcmp(m, "seqz")) { NEED(2); emit_insn(enc_i(OP_SLTIU, xreg(o[0]), xreg(o[1]), 1)); return 1; }
  if (!strcmp(m, "snez")) { NEED(2); emit_insn(enc_r(OP_ALU, xreg(o[0]), 0, xreg(o[1]), ALU_SLTU)); return 1; }
  if (!strcmp(m, "neg")) { NEED(2); emit_insn(enc_r(OP_ALU, xreg(o[0]), 0, xreg(o[1]), ALU_SUB)); return 1; }
  if (!strcmp(m, "j")) {
    NEED(1);
    if (cur_li == first_insn_line && (opt_paged || opt_far)) { /* the entry: through the set-up stub */
      static char tgt[256];
      snprintf(tgt, sizeof tgt, "%s", o[0]);
      entry_target = tgt;
      emit_insn((uint32_t)OP_JAL << 26 | (uint32_t)(pcrel("__pinit", 21) & 0x1fffff));
      return 1;
    }
    if (paged_transfer(0, o[0], 1)) return 1;
    emit_insn((uint32_t)OP_JAL << 26 | (uint32_t)(pcrel(o[0], 21) & 0x1fffff));
    return 1;
  }
  if (!strcmp(m, "call")) {
    NEED(1);
    if (paged_transfer(1, o[0], 0)) return 1;
    emit_insn((uint32_t)OP_JAL << 26 | 1u << 21 | (uint32_t)(pcrel(o[0], 21) & 0x1fffff));
    return 1;
  }
  if (!strcmp(m, "ret")) { NEED(0); emit_insn(opt_paged ? enc_r(OP_XCALL, 0, 1, 0, 1 << 4) : enc_i(OP_JALR, 0, 1, 0)); return 1; }
  if (!strcmp(m, "jr")) {
    NEED(1);
    emit_insn(opt_paged ? enc_r(OP_XCALL, 0, xreg(o[0]), 0, 1 << 4) : enc_i(OP_JALR, 0, xreg(o[0]), 0));
    return 1;
  }
  if (!strcmp(m, "tfence")) { NEED(0); emit_insn(enc_i(OP_TWAIT, 0, 0, 0xffff)); return 1; }
  struct { const char *name; int op, swap, zero; } br[] = {
    {"beqz", OP_BEQ, 0, 1}, {"bnez", OP_BNE, 0, 1}, {"bltz", OP_BLT, 0, 1}, {"bgez", OP_BGE, 0, 1},
    {"bgtz", OP_BLT, 1, 1}, {"blez", OP_BGE, 1, 1},
    {"bgt", OP_BLT, 1, 0}, {"ble", OP_BGE, 1, 0}, {"bgtu", OP_BLTU, 1, 0}, {"bleu", OP_BGEU, 1, 0},
  };
  for (unsigned i = 0; i < sizeof br / sizeof *br; i++) {
    if (strcmp(m, br[i].name)) continue;
    int a, b;
    const char *t;
    if (br[i].zero) { NEED(2); a = xreg(o[0]); b = 0; t = o[1]; }
    else { NEED(3); a = xreg(o[0]); b = xreg(o[1]); t = o[2]; }
    if (br[i].swap) { int x = a; a = b; b = x; }
    if (paged_branch(br[i].op, a, b, t)) return 1;
    emit_insn(enc_i(br[i].op, a, b, pcrel(t, 16)));
    return 1;
  }
  return 0;
#undef NEED
}

/* ------------------------------------------------------------ directives */

static void emit_string(const char *s, int zero) {
  s = strchr(s, '"');
  if (!s) { err("expected string"); return; }
  for (s++; *s && *s != '"'; s++) {
    int c = (unsigned char)*s;
    if (c == '\\') {
      s++;
      switch (*s) {
      case 'n': c = '\n'; break;
      case 't': c = '\t'; break;
      case 'r': c = '\r'; break;
      case '0': c = 0; break;
      case 'x': c = (int)strtol(s + 1, (char **)&s, 16); s--; break;
      default: c = (unsigned char)*s;
      }
    }
    emit_byte((uint8_t)c);
  }
  if (*s != '"') err("unterminated string");
  if (zero) emit_byte(0);
}

static int directive(const char *d, char *rest) {
  char *o[MAXOPS];
  for (int i = 0; i < NSECT; i++)
    if (!strcmp(d, sects[i].name)) { cs = i; return 1; }
  if (!strcmp(d, ".global") || !strcmp(d, ".globl")) return 1;
  if (!strcmp(d, ".pinned") || !strcmp(d, ".resident") || !strcmp(d, ".near")) return 1; /* (the pre-scan's) */
  if (!strcmp(d, ".ascii")) { emit_string(rest, 0); return 1; }
  if (!strcmp(d, ".asciz") || !strcmp(d, ".string")) { emit_string(rest, 1); return 1; }
  int width = !strcmp(d, ".byte") ? 1 : !strcmp(d, ".half") ? 2 : !strcmp(d, ".word") ? 4 :
              !strcmp(d, ".dword") ? 8 : 0;
  if (width) {
    int n = split_ops(rest, o);
    for (int i = 0; i < n; i++) emit_le((uint64_t)value(o[i]), width);
    return 1;
  }
  if (!strcmp(d, ".space") || !strcmp(d, ".zero")) {
    int n = split_ops(rest, o);
    int u = 0;
    int64_t len = n ? eval(o[0], &u) : 0;
    int64_t fill = n > 1 ? value(o[1]) : 0;
    if (u || len < 0) { err(".space needs a known non-negative size"); return 1; }
    for (int64_t i = 0; i < len; i++) emit_byte((uint8_t)fill);
    return 1;
  }
  if (!strcmp(d, ".align")) {
    int u;
    int64_t a = eval(rest, &u);
    if (u || a <= 0 || (a & (a - 1))) { err(".align needs a power of two"); return 1; }
    while (sects[cs].loc & (a - 1)) emit_byte(0);
    return 1;
  }
  if (!strcmp(d, ".org")) {
    if (opt_paged && cur_li < nlines && lreg && lreg[cur_li] >= 0) { err(".org in paged code (assemble with -r)"); return 1; }
    int u;
    int64_t a = eval(rest, &u);
    if (u || a < sects[cs].loc) { err(".org cannot move backwards"); return 1; }
    while (sects[cs].loc < a) emit_byte(0);
    return 1;
  }
  if (!strcmp(d, ".equ") || !strcmp(d, ".set")) {
    int n = split_ops(rest, o);
    if (n != 2) { err(".equ name, value"); return 1; }
    int u;
    int64_t v = eval(o[1], &u);
    if (u && pass == 1) { err(".equ %s uses a symbol defined later", o[0]); return 1; }
    sym_define(o[0], v, -1);
    return 1;
  }
  return 0;
}

/* ------------------------------------------------------------ paged code and far data

   Paged code. The program's .text is cut into regions, one per function:
   a function is a label that some `call` or `jal ra` targets, and a region
   runs from such a label to the next (the first one from the start of
   .text). A branch, a jump that is not a tail call, and falling off the end
   of a region join regions into a group. A group is the unit of placement:
   either pinned (kept resident in .text, from the text origin) or paged
   (packed into code units of 2^ulg bytes in a section of its own, kind
   SK_UNITS, the image's first, its offsets the image file's: StrataOS gives
   a program a read and execute share of its image in c15 and pages units
   from it into the I-LS on a miss, so they take nothing of its memory). Pinned: the group of the entry, every group with a label
   whose address is taken (in an expression other than a branch or call
   target: a trap handler, a resume point, a function pointer, a jump
   table), every group with a `.pinned` line, and every group larger than a
   unit. So every code address the
   program can hold is an I-LS address.
   The rewrites, all of a fixed size so that pass 1 knows the layout:
     call/jal ra to a paged function   lui t6, ori t6, xcall ra, c15, t6
     j to a paged function (tail call) lui t6, ori t6, xcall zero, c15, t6
     call from paged to pinned code    a far link in ra (cbase c15 + the return
                                       point's offset, bit 63), ori t6, jalr
     j from paged to pinned code       ori t6, jalr zero, t6
     jalr ra, rs, 0 in paged code      a far link in ra, jalr zero, rs
     ret, jr rs (jalr zero, rs, 0)     xret rs, everywhere
   so a return address into a unit is always a far link, which xret
   resolves wherever the unit is now, paging it back in if need be. t6 is
   the rewrites' scratch register: a value in t6 does not survive a call
   (nor a branch or jump to a function). c15 is the kernel's: a paged
   program must not use it.

   Far data. A cache for far loads and stores (tgeom bit 16, FA) is appended
   to .data: its tag table (__fc_tags) and lines (__fc_lines), 64-byte lines,
   2 ways. A load or store past the D-LS then reaches the arena (c0) at that
   offset; the kernel serves the misses.

   Either mode needs set-up before the program runs: the entry, the
   program's first .text instruction, must be `j L`; it becomes `j __pinit`,
   a stub after the pinned code that sets xslot, ttag, tdata and tgeom and
   then goes on to L. A program that sets xslot or uses the overlay
   instructions itself is refused in paged mode, one that sets the cache
   CSRs or uses ltag / linst in far mode: they manage their own (-r, -n). */

static void strip_comment(char *s);

static int tl_find(const char *name) {
  for (int i = 0; i < ntlabs; i++)
    if (!strcmp(tlabs[i].name, name)) return i;
  return -1;
}

/* Splits a source line (a copy, comment stripped) into its labels, its
   mnemonic (lower case, "" if none) and the rest. Lines `name = expr` give
   the mnemonic "=" and the rest the expression. */
static int parse_line(char *buf, char **labs, char *m, size_t mlen, char **rest) {
  strip_comment(buf);
  char *s = trim(buf);
  int nl = 0;
  for (;;) {
    char *q = s;
    if (!is_symstart((unsigned char)*q)) break;
    while (is_symchar((unsigned char)*q)) q++;
    if (*q != ':') break;
    *q = 0;
    if (nl < 8) labs[nl++] = s;
    s = trim(q + 1);
  }
  *m = 0;
  *rest = s;
  if (!*s) return nl;
  char *eq = s;
  while (is_symchar((unsigned char)*eq)) eq++;
  while (isspace((unsigned char)*eq)) eq++;
  if (is_symstart((unsigned char)*s) && *eq == '=' && eq[1] != '=') {
    snprintf(m, mlen, "=");
    *rest = eq + 1;
    return nl;
  }
  char *sp = s + strcspn(s, " \t");
  snprintf(m, mlen, "%.*s", (int)(sp - s), s);
  for (char *c = m; *c; c++) *c = (char)tolower((unsigned char)*c);
  *rest = sp;
  return nl;
}

/* Marks every .text label named in expression e as address-taken. */
static void mark_taken(const char *e) {
  for (const char *p = e; *p;) {
    if (*p == '"' || *p == '\'') { /* skip a quoted string or character */
      char q = *p++;
      while (*p && *p != q) { if (*p == '\\' && p[1]) p++; p++; }
      if (*p) p++;
      continue;
    }
    if (is_symstart((unsigned char)*p) && (p == e || !is_symchar((unsigned char)p[-1]))) {
      const char *b = p;
      while (is_symchar((unsigned char)*p)) p++;
      char name[256];
      snprintf(name, sizeof name, "%.*s", (int)(p - b), b);
      int t = tl_find(name);
      if (t >= 0) tlabs[t].taken = 1;
      continue;
    }
    p++;
  }
}

static int is_branch(const char *m) {
  static const char *br[] = {"beq", "bne", "blt", "bge", "bltu", "bgeu", "beqz", "bnez", "bltz",
                             "bgez", "bgtz", "blez", "bgt", "ble", "bgtu", "bleu"};
  for (unsigned i = 0; i < sizeof br / sizeof *br; i++)
    if (!strcmp(m, br[i])) return 1;
  return 0;
}

/* jal's link register, or -1 if the line is not a jal */
static int jal_rd(const char *m, char **o, int n) {
  if (strcmp(m, "jal") || n != 2) return -1;
  return parse_xreg(o[0]);
}

static int region_of_label(const char *name) {
  int t = tl_find(name);
  return t < 0 ? -1 : tlabs[t].region;
}

/* a label on a section directive's line in .text has no region: no group, resident */
static int label_group(int t) { return tlabs[t].region < 0 ? -1 : rgroup[tlabs[t].region]; }
static int label_pinned(int t) { return tlabs[t].region < 0 ? 1 : gpinned[label_group(t)]; }
static int line_paged(void) { return opt_paged && lreg[cur_li] >= 0 && !gpinned[rgroup[lreg[cur_li]]]; }

static void prescan(void) {
  lsect = xmalloc(sizeof *lsect * (size_t)(nlines + 1));
  lreg = xmalloc(sizeof *lreg * (size_t)(nlines + 1));
  char buf[4096], m[64], *labs[8], *rest, *o[MAXOPS];
  /* 1: sections, .text labels, the directives that switch modes off, conflicts */
  int sect = S_TEXT, own_code = -1, own_cache = -1, own_c15 = -1;
  for (int li = 0; li < nlines; li++) {
    cur_file = lines[li].file; cur_line = lines[li].line; /* (split_ops's messages) */
    snprintf(buf, sizeof buf, "%s", lines[li].text);
    int nl = parse_line(buf, labs, m, sizeof m, &rest);
    lsect[li] = sect;
    if (sect == S_TEXT)
      for (int k = 0; k < nl; k++) {
        if (tl_find(labs[k]) >= 0) continue; /* (a redefinition: pass 1 says so) */
        if (ntlabs == captlabs) { captlabs = captlabs ? captlabs * 2 : 256; tlabs = realloc(tlabs, captlabs * sizeof *tlabs); }
        tlabs[ntlabs++] = (TLabel){xstrdup(labs[k]), -1, 0, 0};
      }
    for (int i = 0; i < NSECT; i++)
      if (!strcmp(m, sects[i].name)) sect = i;
    if (!strcmp(m, ".resident")) opt_paged = 0;
    if (!strcmp(m, ".near")) opt_far = 0;
    if (sect == S_TEXT && *m && m[0] != '.' && strcmp(m, "=") && first_insn_line < 0) first_insn_line = li;
    int n = split_ops(rest, o);
    for (int i = 0; i < n; i++)
      if (!strcmp(o[i], "c15") && own_c15 < 0) own_c15 = li;
    if (!strcmp(m, "xcall") || !strcmp(m, "xret") || !strcmp(m, "xmap") || !strcmp(m, "xunmap") ||
        (!strcmp(m, "csrw") && n == 2 && !strcmp(o[0], "xslot")))
      if (own_code < 0) own_code = li;
    if (!strcmp(m, "ltag") || !strcmp(m, "linst") ||
        (!strcmp(m, "csrw") && n == 2 && (!strcmp(o[0], "ttag") || !strcmp(o[0], "tdata") || !strcmp(o[0], "tgeom"))))
      if (own_cache < 0) own_cache = li;
  }
  if (opt_paged < 0) opt_paged = text_org != 0;
  if (opt_far < 0) opt_far = text_org != 0;
  if (opt_paged && own_c15 >= 0) {
    cur_file = lines[own_c15].file; cur_line = lines[own_c15].line;
    err("paged code: c15 holds the program's image (the kernel's): use another register, or -r");
  }
  if (opt_paged && own_code >= 0) {
    cur_file = lines[own_code].file; cur_line = lines[own_code].line;
    err("the program pages its own code: assemble it with -r (or .resident)");
  }
  if (opt_far && own_cache >= 0) {
    cur_file = lines[own_cache].file; cur_line = lines[own_cache].line;
    err("the program manages its own data cache: assemble it with -n (or .near)");
  }
  if ((opt_paged || opt_far) && first_insn_line >= 0) {
    snprintf(buf, sizeof buf, "%s", lines[first_insn_line].text);
    parse_line(buf, labs, m, sizeof m, &rest);
    if (strcmp(m, "j")) {
      cur_file = lines[first_insn_line].file; cur_line = lines[first_insn_line].line;
      err("paged code or far data: the program's first instruction must be `j` (or assemble with -r -n)");
    }
  }
  if (!opt_paged) {
    for (int li = 0; li < nlines; li++) lreg[li] = -1;
    return;
  }
  /* 2: functions (call targets) and labels whose address is taken */
  for (int li = 0; li < nlines; li++) {
    cur_file = lines[li].file; cur_line = lines[li].line;
    snprintf(buf, sizeof buf, "%s", lines[li].text);
    parse_line(buf, labs, m, sizeof m, &rest);
    if (!*m) continue;
    if (!strcmp(m, "=")) { mark_taken(rest); continue; }
    int n = split_ops(rest, o);
    if (!strcmp(m, "call") && n == 1) {
      int t = tl_find(o[0]);
      if (t >= 0) tlabs[t].func = 1;
      continue;
    }
    int rd = jal_rd(m, o, n);
    if (rd >= 0) {
      if (rd == 1) { int t = tl_find(o[1]); if (t >= 0) tlabs[t].func = 1; }
      continue;
    }
    if (!strcmp(m, "j") || is_branch(m)) continue; /* targets, not addresses */
    if (!strcmp(m, ".equ") || !strcmp(m, ".set")) { if (n == 2) mark_taken(o[1]); continue; }
    if (m[0] == '.' && strcmp(m, ".byte") && strcmp(m, ".half") && strcmp(m, ".word") && strcmp(m, ".dword"))
      continue; /* (other directives name no code) */
    for (int i = 0; i < n; i++) mark_taken(o[i]);
  }
  /* 3: regions, in .text order */
  rfirst = xmalloc(sizeof *rfirst * (size_t)(nlines + 1));
  int cur = -1;
  for (int li = 0; li < nlines; li++) {
    lreg[li] = -1;
    if (lsect[li] != S_TEXT) continue;
    snprintf(buf, sizeof buf, "%s", lines[li].text);
    int nl = parse_line(buf, labs, m, sizeof m, &rest);
    int sw = 0;
    for (int i = 0; i < NSECT; i++) sw |= !strcmp(m, sects[i].name);
    if (sw) continue; /* a section directive: not code */
    int starts = cur < 0;
    for (int k = 0; k < nl; k++) { int t = tl_find(labs[k]); if (t >= 0 && tlabs[t].func) starts = 1; }
    if (starts) { rfirst[nregions] = li; cur = nregions++; }
    lreg[li] = cur;
    for (int k = 0; k < nl; k++) { int t = tl_find(labs[k]); if (t >= 0) tlabs[t].region = cur; }
  }
  rjoin = calloc((size_t)nregions + 1, sizeof *rjoin);
  rwhy = calloc((size_t)nregions + 1, sizeof *rwhy);
  rpinned = calloc((size_t)nregions + 1, sizeof *rpinned);
  rgroup = xmalloc(sizeof *rgroup * (size_t)(nregions + 1));
  /* 4: what joins regions, and what pins them */
  int last_term = 1, last_reg = -1, last_line = 0; /* the region's last instruction ended it (j, ret, jr) */
  for (int li = 0; li < nlines; li++) {
    int r = lreg[li];
    if (r < 0) continue;
    cur_file = lines[li].file; cur_line = lines[li].line;
    snprintf(buf, sizeof buf, "%s", lines[li].text);
    int nl = parse_line(buf, labs, m, sizeof m, &rest);
    for (int k = 0; k < nl; k++) { int t = tl_find(labs[k]); if (t >= 0 && tlabs[t].taken) rpinned[r] = 1; }
    if (r != last_reg) {
      if (last_reg >= 0 && !last_term) for (int x = last_reg; x < r; x++) { if (!rjoin[x]) rwhy[x] = last_line; rjoin[x] = 1; } /* falls through */
      last_reg = r;
      last_term = 0;
    }
    if (!*m || !strcmp(m, "=") || !strcmp(m, ".equ") || !strcmp(m, ".set") || !strcmp(m, ".global") ||
        !strcmp(m, ".globl") || !strcmp(m, ".text") || !strcmp(m, ".resident") || !strcmp(m, ".near"))
      continue;
    if (!strcmp(m, ".pinned")) { rpinned[r] = 1; continue; }
    int n = split_ops(rest, o);
    const char *target = NULL;
    int term = 0;
    if (is_branch(m) && n >= 2) target = o[n - 1];
    else if (!strcmp(m, "j") && n == 1) { term = 1; target = o[0]; }
    else if (!strcmp(m, "call") || !strcmp(m, "halt")) term = 1; /* (a call that ends a region does not return) */
    else if (jal_rd(m, o, n) >= 0) {
      int rd = jal_rd(m, o, n);
      if (rd == 1) term = 1;
      else { term = rd == 0; target = o[1]; }
    } else if (!strcmp(m, "ret") || !strcmp(m, "jr") || !strcmp(m, "xret")) term = 1;
    else if (!strcmp(m, "jalr") && n == 3 && parse_xreg(o[0]) <= 1) term = 1;
    last_term = term;
    last_line = li;
    if (!target) continue;
    int tr = region_of_label(target);
    if (tr < 0 || tr == r) continue;
    if (tlabs[tl_find(target)].func) continue; /* a (conditional) tail call: becomes a far one */
    int lo = r < tr ? r : tr, hi = r < tr ? tr : r;
    for (int x = lo; x < hi; x++) { if (!rjoin[x]) rwhy[x] = li; rjoin[x] = 1; }
  }
  if (nregions) rpinned[0] = 1; /* the entry */
  /* 5: groups */
  gpinned = calloc((size_t)nregions + 1, sizeof *gpinned);
  gfirst = calloc((size_t)nregions + 1, sizeof *gfirst);
  gsect = calloc((size_t)nregions + 1, sizeof *gsect);
  gbase = calloc((size_t)nregions + 1, sizeof *gbase);
  gloc = calloc((size_t)nregions + 1, sizeof *gloc);
  gsize = calloc((size_t)nregions + 1, sizeof *gsize);
  for (int r = 0; r < nregions; r++) {
    if (r == 0 || !rjoin[r - 1]) gfirst[ngroups++] = r;
    rgroup[r] = ngroups - 1;
    if (rpinned[r]) gpinned[ngroups - 1] = 1;
  }
}

/* The layout from the sizes pass 1 measured: pinned groups in source order
   from the text origin, then the start-up stub; paged groups packed into
   units in source order, from ubase. */
static uint32_t stub_size(void);
static void layout(uint32_t far_end) {
  uint32_t us = 1u << ulg, a = text_org;
  for (int g = 0; g < ngroups; g++) /* a group too large for a unit stays resident */
    if (!gpinned[g] && gsize[g] > us) gpinned[g] = 2;
  for (int g = 0; g < ngroups; g++)
    if (gpinned[g]) { gsect[g] = S_TEXT; gbase[g] = a; a += gsize[g]; }
  pinned_end = a;
  (void)far_end;
  ubase = us; /* the units section is the image's first: its bytes start at file offset 24, padded to a unit */
  uint32_t u = ubase, used = 0;
  for (int g = 0; g < ngroups; g++) {
    if (gpinned[g]) continue;
    gsect[g] = S_UNITS;
    if (used + gsize[g] > us) { u += us; used = 0; }
    gbase[g] = u + used;
    used += gsize[g];
  }
}

/* The far link of the instruction at `ret` (an image offset): what xret
   resolves to come back there. ra = cbase(c15) + ret | 1 << 63; t6 clobbered. */
static void emit_flink(uint32_t ret) {
  emit_insn(enc_r(OP_CAP, 1, 15, 0, CF_BASE));           /* cbase ra, c15 (the image) */
  emit_insn(enc_i(OP_LUI, 31, 0, (ret >> 16) & 0xffff)); /* t6 = ret */
  emit_insn(enc_i(OP_ORI, 31, 31, ret & 0xffff));
  emit_insn(enc_r(OP_ALU, 1, 1, 31, ALU_ADD));           /* add ra, ra, t6 */
  emit_insn(enc_i(OP_ADDI, 31, 0, 1));                   /* t6 = 1 << 63 */
  emit_insn(enc_i(OP_SLLI, 31, 31, 63));
  emit_insn(enc_r(OP_ALU, 1, 1, 31, ALU_OR));            /* or ra, ra, t6 */
}

/* lui t6, ori t6, xcall rd, c15, t6: a call (rd = ra) or a jump (rd = zero)
   to the function at image offset v */
static void emit_farcall(int rd, int64_t v) {
  emit_insn(enc_i(OP_LUI, 31, 0, (v >> 16) & 0xffff));
  emit_insn(enc_i(OP_ORI, 31, 31, v & 0xffff));
  emit_insn(enc_r(OP_XCALL, rd, 31, 0, 15));            /* xcall rd, c15, t6 */
}

/* A call (rd = ra) or a jump (rd = zero) to label `target` in paged mode.
   Returns 0 if it is an ordinary one (assemble it as written). */
static int paged_transfer(int rd, const char *target, int tail) {
  if (!opt_paged || lreg[cur_li] < 0) return 0;
  int t = tl_find(target);
  if (t < 0) return 0;
  if (tail && (!tlabs[t].func || label_group(t) == rgroup[lreg[cur_li]])) return 0; /* a branch */
  int here_paged = line_paged(), there_pinned = label_pinned(t);
  if (!here_paged && there_pinned) return 0;
  int u;
  int64_t v = eval(target, &u);
  if (!there_pinned) { emit_farcall(rd, v); return 1; }
  if (rd == 1) emit_flink(sects[cs].loc + 4 * 9);
  emit_insn(enc_i(OP_ORI, 31, 0, v & 0xffff));           /* ori t6, zero, target */
  emit_insn(enc_i(OP_JALR, 0, 31, 0));                   /* jalr zero, t6, 0 */
  return 1;
}

/* A conditional branch (op, a, b) to `target` in paged mode: to another
   group it becomes the opposite branch over a jump there (always 4 words).
   Returns 0 if it is an ordinary one. */
static int paged_branch(int op, int a, int b, const char *target) {
  if (!opt_paged || lreg[cur_li] < 0) return 0;
  int t = tl_find(target);
  if (t < 0 || !tlabs[t].func || label_group(t) == rgroup[lreg[cur_li]]) return 0;
  int here_paged = line_paged(), there_pinned = label_pinned(t);
  if (!here_paged && there_pinned) return 0; /* both in .text */
  int inv = op == OP_BEQ ? OP_BNE : op == OP_BNE ? OP_BEQ : op == OP_BLT ? OP_BGE : op == OP_BGE ? OP_BLT
          : op == OP_BLTU ? OP_BGEU : OP_BLTU;
  emit_insn(enc_i(inv, a, b, 4));                        /* over the jump */
  int u;
  int64_t v = eval(target, &u);
  if (!there_pinned) emit_farcall(0, v);
  else {
    emit_insn(enc_i(OP_ORI, 31, 0, v & 0xffff));         /* ori t6, zero, target */
    emit_insn(enc_i(OP_JALR, 0, 31, 0));                 /* jalr zero, t6, 0 */
    emit_insn(enc_i(OP_ADDI, 0, 0, 0));                  /* (nop: four words either way) */
  }
  return 1;
}

static uint32_t stub_size(void) {
  uint32_t n = 0;
  if (opt_paged) n += 2;
  if (opt_far) n += 9;
  return 4 * (n + 3); /* and the jump on: at most 3 instructions */
}

/* __pinit: the set-up the entry `j L` now goes through, then on to L */
static void emit_stub(void) {
  sym_define("__pinit", sects[cs].loc, cs);
  if (opt_paged) {
    emit_insn(enc_i(OP_ADDI, 5, 0, ulg));                /* xslot = ulg */
    emit_insn(enc_i(OP_CSRW, 0, 5, 25));
  }
  if (opt_far) {
    int u;
    gen_li(5, eval("__fc_tags", &u), 2);
    emit_insn(enc_i(OP_CSRW, 0, 5, 8));                  /* ttag */
    gen_li(5, eval("__fc_lines", &u), 2);
    emit_insn(enc_i(OP_CSRW, 0, 5, 9));                  /* tdata */
    int sets = cache_kib * 1024 / 64 / 2, slg = 0;
    while ((1 << slg) < sets) slg++;
    gen_li(5, 6 | slg << 6 | 2 << 12 | 1 << 16, 2);      /* 64-byte lines, 2 ways, FA */
    emit_insn(enc_i(OP_CSRW, 0, 5, 10));                 /* tgeom */
  }
  uint32_t end = sects[cs].loc + 12;
  int u;
  int64_t v = entry_target ? eval(entry_target, &u) : 0;
  int t = entry_target ? tl_find(entry_target) : -1;
  if (opt_paged && t >= 0 && !label_pinned(t)) emit_farcall(0, v);
  else {
    int64_t d = (v - (int64_t)sects[cs].loc) >> 2;
    if (pass == 2 && entry_target && (u || esect != S_TEXT)) err("the entry's target %s is not code", entry_target);
    emit_insn((uint32_t)OP_JAL << 26 | (uint32_t)(d & 0x1fffff));
  }
  while (sects[cs].loc < end) emit_insn(enc_i(OP_ADDI, 0, 0, 0));
}

/* the far data cache, at the end of .data */
static void emit_cache(void) {
  while (sects[cs].loc & 63) emit_byte(0);
  int sets = cache_kib * 1024 / 64 / 2, slg = 0;
  while ((1 << slg) < sets) slg++;
  sets = 1 << slg;
  sym_define("__fc_lines", sects[cs].loc, cs);
  for (int i = 0; i < sets * 2 * 64; i++) emit_byte(0);
  sym_define("__fc_tags", sects[cs].loc, cs);
  for (int i = 0; i < sets * 3 * 8; i++) emit_byte(0);
}

/* ------------------------------------------------------------ listing */

static FILE *listing;

/* ------------------------------------------------------------ the debug map (-g) */

/* Every source line that put bytes into a section: its section, the
 * address of its first byte and the line (an index into lines[]). */
typedef struct { int sect; uint32_t addr; int line; } MapLine;
static MapLine *maplines;
static int nmaplines, capmaplines;

static void map_line(int sect, uint32_t addr, int li) {
  if (nmaplines == capmaplines) {
    capmaplines = capmaplines ? capmaplines * 2 : 1024;
    maplines = realloc(maplines, capmaplines * sizeof *maplines);
  }
  maplines[nmaplines++] = (MapLine){sect, addr, li};
}

/* The map, a text file read by the debug engine (emu/debug_sym.c):
 *   strata-map 1
 *   root DIR                    the directory the source paths are relative to
 *   image FILE                  the image this map describes
 *   org ADDR                    where .text starts (-T)
 *   file N PATH                 source file N
 *   sym SECTION ADDR NAME       a label (text, data, far, cluster) or a
 *                               constant (abs: `=`, .equ, .set)
 *   line SECTION ADDR FILE LINE the first byte a source line emitted
 * Addresses are hexadecimal; lines come in source order. */
static const char *sect_map_name[NSECT] = {"text", "data", "far", "cluster", "units"};

static void write_map(const char *path, const char *image) {
  FILE *f = fopen(path, "w");
  if (!f) { fprintf(stderr, "sasm: cannot write %s: %s\n", path, strerror(errno)); exit(1); }
  char cwd[2048];
  fprintf(f, "strata-map 1\n");
  if (getcwd(cwd, sizeof cwd)) fprintf(f, "root %s\n", cwd);
  fprintf(f, "image %s\norg 0x%x\n", image, text_org);
  /* the source files, numbered in order of first appearance */
  const char **files = xmalloc(sizeof *files * (size_t)(nlines + 1));
  int nfiles = 0;
  int *fileof = xmalloc(sizeof *fileof * (size_t)(nlines + 1));
  for (int i = 0; i < nlines; i++) {
    int k = nfiles;
    if (i && lines[i].file == lines[i - 1].file) k = fileof[i - 1];
    else
      for (int j = 0; j < nfiles; j++)
        if (!strcmp(files[j], lines[i].file)) { k = j; break; }
    if (k == nfiles) {
      files[nfiles++] = lines[i].file;
      fprintf(f, "file %d %s\n", k, lines[i].file);
    }
    fileof[i] = k;
  }
  for (int i = 0; i < nsyms; i++)
    if (syms[i].defined)
      fprintf(f, "sym %s 0x%llx %s\n", syms[i].sect >= 0 ? sect_map_name[syms[i].sect] : "abs",
              (unsigned long long)syms[i].value, syms[i].name);
  for (int i = 0; i < nmaplines; i++)
    fprintf(f, "line %s 0x%x %d %d\n", sect_map_name[maplines[i].sect], maplines[i].addr,
            fileof[maplines[i].line], lines[maplines[i].line].line);
  fclose(f);
}

/* ------------------------------------------------------------ driver */

static void strip_comment(char *s) {
  char q = 0;
  for (char *p = s; *p; p++) {
    if (q) {
      if (*p == '\\' && p[1]) { p++; continue; }
      if (*p == q) q = 0;
      continue;
    }
    if (*p == '"' || *p == '\'') { q = *p; continue; }
    if (*p == ';' || *p == '#' || (p[0] == '/' && p[1] == '/')) { *p = 0; return; }
  }
}

static void run_pass(int p) {
  pass = p;
  for (int i = 0; i < NSECT; i++) { sects[i].loc = 0; sects[i].lo = UINT32_MAX; sects[i].size = 0; }
  sects[S_TEXT].loc = text_org;
  cs = S_TEXT;
  li_idx = 0;
  if (p == 1) nli = 0;
  for (int g = 0; g < ngroups; g++) gloc[g] = gbase[g];
  user_far_end = 0;
  for (int li = 0; li < nlines; li++) {
    cur_file = lines[li].file;
    cur_line = lines[li].line;
    cur_li = li;
    /* paged code: a .text line goes where its group is (pinned in .text, paged in .far) */
    int g = opt_paged && lreg[li] >= 0 ? rgroup[lreg[li]] : -1;
    uint32_t user_loc = 0;
    if (g >= 0) { cs = gsect[g]; user_loc = sects[cs].loc; sects[cs].loc = gloc[g]; }
    char buf[4096];
    snprintf(buf, sizeof buf, "%s", lines[li].text);
    strip_comment(buf);
    char *s = trim(buf);
    int start_sect = cs;
    uint32_t start_loc = sects[cs].loc;

    /* labels */
    for (;;) {
      char *q = s;
      if (!is_symstart((unsigned char)*q)) break;
      while (is_symchar((unsigned char)*q)) q++;
      if (*q != ':') break;
      *q = 0;
      sym_define(s, sects[cs].loc, cs);
      s = trim(q + 1);
    }
    if (*s) {
      /* name = expr */
      char *sp = s + strcspn(s, " \t");
      char *eq = s;
      while (is_symchar((unsigned char)*eq)) eq++;
      while (isspace((unsigned char)*eq)) eq++;
      if (is_symstart((unsigned char)*s) && *eq == '=' && eq[1] != '=') {
        *eq = 0;
        int u;
        int64_t v = eval(trim(eq + 1), &u);
        if (u && pass == 1) err("%s uses a symbol defined later", trim(s));
        else sym_define(trim(s), v, -1);
      } else {
        char *rest = sp;
        char m[64];
        snprintf(m, sizeof m, "%.*s", (int)(sp - s), s);
        for (char *c = m; *c; c++) *c = (char)tolower((unsigned char)*c);
        if (m[0] == '.') {
          if (!directive(m, rest)) err("unknown directive %s", m);
        } else {
          char *o[MAXOPS];
          int n = split_ops(rest, o);
          const Insn *in = find_insn(m);
          if (in) assemble_insn(in, o, n);
          else if (!pseudo(m, o, n)) err("unknown instruction %s", m);
        }
      }
    }

    if (pass == 2 && start_sect == cs && sects[cs].loc > start_loc) map_line(cs, start_loc, li);
    if (g >= 0) {
      if (cs == gsect[g]) { gloc[g] = sects[cs].loc; sects[cs].loc = user_loc; }
      else err("a section directive on a line with code (paged mode)");
      cs = S_TEXT;
    } else if (cs == S_FAR && sects[S_FAR].loc > user_far_end) user_far_end = sects[S_FAR].loc;
    if (pass == 2 && listing) {
      Section *sec = &sects[start_sect];
      uint32_t end = start_sect == cs ? sec->loc : start_loc;
      fprintf(listing, "%-8s %06x  ", sec->name, start_loc);
      int col = 0;
      for (uint32_t a = start_loc; a < end && a < sec->limit && col < 4; a += 4, col++) {
        uint32_t w = 0;
        for (int k = 0; k < 4 && a + k < end; k++) w |= (uint32_t)sec->buf[a + k] << (8 * k);
        fprintf(listing, "%08x ", w);
      }
      for (; col < 4; col++) fprintf(listing, "         ");
      fprintf(listing, " %s\n", lines[li].text);
    }
  }
  cur_li = nlines;
  if (opt_paged || opt_far) { /* the set-up stub after the pinned code, the cache after the data */
    cs = S_TEXT;
    sects[S_TEXT].loc = opt_paged ? pinned_end : sects[S_TEXT].size ? (sects[S_TEXT].size + 3) & ~3u : text_org;
    emit_stub();
    cs = S_DATA;
    sects[S_DATA].loc = sects[S_DATA].size;
    if (opt_far) emit_cache();
  }
  for (int g = 0; g < ngroups; g++) gsize[g] = gloc[g] - gbase[g];
}

static void report(void) {
    for (int g = 0; g < ngroups; g++) {
      int r0 = gfirst[g], r1 = g + 1 < ngroups ? gfirst[g + 1] : nregions, why = -1;
      const char *first = "(start)";
      for (int t = 0; t < ntlabs; t++)
        if (tlabs[t].region == r0) { first = tlabs[t].name; break; }
      for (int t = 0; t < ntlabs && why < 0; t++)
        if (tlabs[t].region >= r0 && tlabs[t].region < r1 && tlabs[t].taken) why = t;
      fprintf(stderr, "%-24s %5u bytes  %s %05x  %d region(s)%s%s%s%s\n", first, gsize[g],
              gpinned[g] ? "pinned" : "unit  ", gbase[g], r1 - r0,
              r0 == 0 ? "  (the entry)" : "", why >= 0 ? "  address taken: " : "", why >= 0 ? tlabs[why].name : "",
              gpinned[g] == 2 ? "  larger than a unit" : "");
      for (int r = r0; r + 1 < r1; r++)
        fprintf(stderr, "    joined at %s:%d: %s\n", lines[rwhy[r]].file, lines[rwhy[r]].line, trim(lines[rwhy[r]].text));
    }
}

static void wr32(FILE *f, uint32_t v) {
  uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
  fwrite(b, 1, 4, f);
}

static void usage(void) {
  fprintf(stderr, "usage: sasm [-o out.stx] [-l] [-g out.map] [-T text-origin] [-I dir] [-r] [-n] [-u KIB] [-c KIB] file.s\n");
  exit(2);
}

int main(int argc, char **argv) {
  const char *in = NULL, *out = NULL, *map = NULL;
  int want_list = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "-l")) want_list = 1;
    else if (!strcmp(argv[i], "-g") && i + 1 < argc) map = argv[++i];
    else if (!strcmp(argv[i], "-T") && i + 1 < argc) text_org = (uint32_t)strtoul(argv[++i], NULL, 0);
    else if (!strcmp(argv[i], "-I") && i + 1 < argc) { if (nincdirs < 16) incdirs[nincdirs++] = argv[++i]; }
    else if (!strcmp(argv[i], "-r")) opt_paged = 0;
    else if (!strcmp(argv[i], "-v")) opt_report = 1;
    else if (!strcmp(argv[i], "-n")) opt_far = 0;
    else if (!strcmp(argv[i], "-u") && i + 1 < argc) {
      int k = atoi(argv[++i]);
      if (k != 1 && k != 2 && k != 4) usage();
      ulg = k == 1 ? 10 : k == 2 ? 11 : 12;
    } else if (!strcmp(argv[i], "-c") && i + 1 < argc) {
      cache_kib = atoi(argv[++i]);
      if (cache_kib < 1 || cache_kib > 16 || (cache_kib & (cache_kib - 1))) usage();
    }
    else if (argv[i][0] == '-') usage();
    else if (!in) in = argv[i];
    else usage();
  }
  if (!in) usage();

  char defout[1024];
  if (!out) {
    snprintf(defout, sizeof defout, "%s", in);
    char *dot = strrchr(defout, '.');
    if (dot && !strchr(dot, '/')) *dot = 0;
    strncat(defout, ".stx", sizeof defout - strlen(defout) - 1);
    out = defout;
  }

  read_file(in, 0);
  if (nerrors) return 1;
  prescan();
  if (nerrors) return 1;

  /* pass 1, again until the layout of paged code stops moving */
  for (int it = 0;; it++) {
    for (int i = 0; i < nsyms; i++) syms[i].defined = 0;
    run_pass(1);
    if (nerrors) return 1;
    if (!opt_paged) break;
    uint32_t *old = xmalloc(sizeof *old * (size_t)(ngroups + 1));
    memcpy(old, gbase, sizeof *old * (size_t)ngroups);
    uint32_t old_end = pinned_end, old_ub = ubase;
    layout(user_far_end);
    if (nerrors) { if (opt_report) report(); return 1; }
    int same = it > 0 && pinned_end == old_end && ubase == old_ub && !memcmp(old, gbase, sizeof *old * (size_t)ngroups);
    free(old);
    if (same) break;
    if (it == 20) { fprintf(stderr, "sasm: the paged layout does not settle\n"); return 1; }
  }
  if (opt_report && opt_paged) report();
  if (opt_paged && pinned_end + stub_size() + (2u << ulg) > 0x10000) {
    fprintf(stderr, "sasm: paged code: the pinned code (%u bytes) leaves no room for two %u-byte units\n",
            pinned_end + stub_size() - text_org, 1u << ulg);
    return 1;
  }
  if (opt_far && sects[S_DATA].size > 0xA000) {
    fprintf(stderr, "sasm: far data: the data section with its cache ends at 0x%x, past StrataOS's 0xA000 "
            "(a smaller cache with -c, or -n)\n", sects[S_DATA].size);
    return 1;
  }
  for (int i = 0; i < NSECT; i++) sects[i].buf = xmalloc(sects[i].limit);
  if (want_list) listing = stdout;
  run_pass(2);
  if (nerrors) { fprintf(stderr, "sasm: %d error(s)\n", nerrors); return 1; }

  FILE *f = fopen(out, "wb");
  if (!f) { fprintf(stderr, "sasm: cannot write %s: %s\n", out, strerror(errno)); return 1; }
  int count = 0;
  for (int i = 0; i < NSECT; i++) count += sects[i].size > 0;
  fwrite("STX2", 1, 4, f);
  wr32(f, (uint32_t)count);
  for (int k = 0; k < NSECT; k++) {
    int i = k == 0 ? S_UNITS : k - 1; /* the units first: their offsets are the file's */
    if (!sects[i].size) continue;
    uint32_t lo = sects[i].lo & ~7u, n, pad;
    if (i == S_UNITS) lo = 24;        /* (zeros up to the first unit) */
    n = sects[i].size - lo;
    pad = (8 - (n & 7)) & 7;
    wr32(f, (uint32_t)sects[i].kind);
    wr32(f, lo);
    wr32(f, n + pad);
    wr32(f, 0);
    fwrite(sects[i].buf + lo, 1, n, f);
    for (uint32_t k = 0; k < pad; k++) fputc(0, f);
  }
  fclose(f);
  if (map) write_map(map, out);
  return 0;
}
