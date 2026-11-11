/* strata-dbg: a gdb-like debugger for Strata programs, bare metal or under
 * StrataOS. A front-end of strata-emu's debug engine (emu/debug.c), over its
 * JSON-lines protocol (doc/debug-protocol.md).
 *
 *   strata-dbg [options] [emulator options] image.stx
 *                       starts build/strata-emu --debug stdio with the
 *                       emulator options and the image (STRATA_EMU or the
 *                       strata-emu next to this program)
 *   strata-dbg --connect HOST:PORT | unix:PATH
 *                       talks to an engine that is already running
 * Options:
 *   --console pty|FILE|-  where the guest's console goes: a new pseudo-terminal
 *                       (the default at a terminal: open it in another window,
 *                       e.g. `screen /dev/ttys012`; what is typed there is the
 *                       guest's input), a file (or another terminal's tty), or
 *                       `-`: this terminal, every line marked `console|` (the
 *                       default for scripts)
 *   --tui               start in the split-screen view (`tui` toggles it)
 *   -x FILE             run the commands in FILE first
 *   --batch             no prompt; exit at the end of the commands
 * `help` lists the commands. Commands come from the terminal, or from stdin
 * when it is not one (scripts, tests: tools/test-dbg.sh). */
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>

#include "../common/json.h"

/* ------------------------------------------------------------ the connection */

static int eng_in = -1, eng_out = -1; /* read from / write to the engine */
static int eng_err = -1;              /* the emulator's stderr (when we started it) */
static pid_t eng_pid;
static char ibuf[1 << 20];
static size_t ilen;
static int next_id = 1;
static FILE *out;                     /* what the debugger prints */
static bool batch, tui;
static int cur = 0;                   /* the current core */
static int ncores = 1;
static bool os_aware;
static volatile sig_atomic_t interrupted;

/* the console */
static int con_fd = -1;               /* where console output goes (-1: inline) */
static int con_pty = -1;              /* the pty master: input from it too */
static bool con_inline;
static char con_tail[8][256];         /* the last lines, for the TUI */
static int con_ntail;
static char con_line[256];
static size_t con_linel;

static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "strata-dbg: ");
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(2);
}

static void con_put(const char *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (c == '\n' || con_linel == sizeof con_line - 1) {
      con_line[con_linel] = 0;
      if (con_ntail == 8) { memmove(con_tail[0], con_tail[1], sizeof con_tail[0] * 7); con_ntail = 7; }
      snprintf(con_tail[con_ntail++], sizeof con_tail[0], "%s", con_line);
      if (con_inline && !tui) fprintf(out, "console| %s\n", con_line);
      con_linel = 0;
      if (c == '\n') continue;
    }
    con_line[con_linel++] = c;
  }
  if (con_fd >= 0) {
    for (size_t i = 0; i < n; i++) {
      if (s[i] == '\n' && con_fd == con_pty) (void)!write(con_fd, "\r", 1);
      (void)!write(con_fd, s + i, 1);
    }
  }
}

/* the emulator's own messages (halts, faults) */
static void drain_stderr(void) {
  if (eng_err < 0) return;
  static char eb[4096];
  static size_t el;
  for (;;) {
    struct pollfd p = {eng_err, POLLIN, 0};
    if (poll(&p, 1, 0) <= 0 || !(p.revents & (POLLIN | POLLHUP))) return;
    ssize_t r = read(eng_err, eb + el, sizeof eb - 1 - el);
    if (r <= 0) { close(eng_err); eng_err = -1; return; }
    el += (size_t)r;
    char *nl;
    while ((nl = memchr(eb, '\n', el))) {
      *nl = 0;
      if (!tui) fprintf(out, "[emu] %s\n", eb);
      size_t k = (size_t)(nl + 1 - eb);
      memmove(eb, nl + 1, el - k);
      el -= k;
    }
  }
}

/* the stop the engine last reported, and the cores' summary in it */
static JVal *last_stop;
static bool done_flag;

static void show_stop(const JVal *ev);

static void on_event(JVal *ev) {
  const char *k = json_str(json_get(ev, "ev"), "");
  if (!strcmp(k, "console")) {
    const JVal *d = json_get(ev, "data");
    if (d && d->t == J_STR) con_put(d->s, d->len);
    json_free(ev);
    return;
  }
  if (!strcmp(k, "stopped") || !strcmp(k, "done")) {
    done_flag = !strcmp(k, "done");
    json_free(last_stop);
    last_stop = ev;
    return;
  }
  json_free(ev);
}

/* the next complete line from the engine, waiting up to ms (-1 forever); NULL on timeout */
static char *eng_line(int ms) {
  for (;;) {
    char *nl = memchr(ibuf, '\n', ilen);
    if (nl) {
      size_t n = (size_t)(nl - ibuf);
      char *l = malloc(n + 1);
      memcpy(l, ibuf, n);
      l[n] = 0;
      memmove(ibuf, nl + 1, ilen - n - 1);
      ilen -= n + 1;
      return l;
    }
    struct pollfd p[3] = {{eng_in, POLLIN, 0}, {eng_err, POLLIN, 0}, {con_pty, POLLIN, 0}};
    int r = poll(p, 3, ms);
    if (r < 0 && errno == EINTR) { if (ms >= 0) return NULL; continue; }
    if (r <= 0) return NULL;
    if (p[1].revents) drain_stderr();
    if (con_pty >= 0 && (p[2].revents & POLLIN)) {
      /* typed into the console pty: the guest's input */
      char b[512];
      ssize_t n = read(con_pty, b, sizeof b);
      if (n > 0) {
        JW w = {0};
        jw_reset(&w);
        jw_obj(&w, NULL);
        jw_int(&w, "id", 0);
        bool brk = memchr(b, 3, (size_t)n) != NULL;
        jw_str(&w, "cmd", brk ? "ctrl-c" : "input");
        if (!brk) jw_strn(&w, "data", b, (size_t)n);
        jw_oend(&w);
        jw_raw(&w, "\n", 1);
        (void)!write(eng_out, w.p, w.n);
        free(w.p);
      }
    }
    if (p[0].revents & (POLLIN | POLLHUP)) {
      if (ilen == sizeof ibuf) die("a line from the engine is too long");
      ssize_t n = read(eng_in, ibuf + ilen, sizeof ibuf - ilen);
      if (n <= 0) {
        drain_stderr();
        die("the engine has gone");
      }
      ilen += (size_t)n;
    }
  }
}

/* Sends a request (a JSON object written by the caller into w, without id)
 * and returns the answer; events that come meanwhile are handled. */
static JVal *request(JW *w) {
  int id = next_id++;
  char head[32];
  snprintf(head, sizeof head, "{\"id\":%d,", id);
  JW m = {0};
  jw_reset(&m);
  jw_puts(&m, head);
  jw_raw(&m, w->p + 1, w->n - 1); /* the caller's object minus its '{' */
  jw_raw(&m, "\n", 1);
  if (write(eng_out, m.p, m.n) != (ssize_t)m.n) die("cannot write to the engine");
  free(m.p);
  for (;;) {
    char *l = eng_line(-1);
    JVal *v = json_parse(l, strlen(l));
    free(l);
    if (!v) continue;
    if (json_get(v, "ev")) { on_event(v); continue; }
    if (json_int(json_get(v, "id"), -1) == id) return v;
    json_free(v);
  }
}

/* a request built from key/value pairs: "k=s" strings, "k#n" numbers, "k?b" booleans */
static JVal *req(const char *cmd, ...) {
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "cmd", cmd);
  va_list ap;
  va_start(ap, cmd);
  const char *k;
  while ((k = va_arg(ap, const char *))) {
    const char *eq = k + strcspn(k, "=#?");
    char key[64];
    snprintf(key, sizeof key, "%.*s", (int)(eq - k), k);
    if (*eq == '=') jw_str(&w, key, va_arg(ap, const char *));
    else if (*eq == '#') jw_int(&w, key, va_arg(ap, long long));
    else jw_bool(&w, key, va_arg(ap, int));
  }
  va_end(ap);
  jw_oend(&w);
  JVal *r = request(&w);
  free(w.p);
  return r;
}

static bool ok(JVal *r) {
  if (json_bool(json_get(r, "ok"), false)) return true;
  if (!tui) fprintf(out, "error: %s\n", json_str(json_get(r, "error"), "?"));
  return false;
}

/* After a command that runs the machine: wait for it to stop (Ctrl-C pauses it). */
static void wait_stop(void) {
  json_free(last_stop);
  last_stop = NULL;
  bool paused = false;
  while (!last_stop) {
    if (interrupted && !paused) {
      interrupted = 0;
      paused = true;
      JW w = {0};
      jw_reset(&w);
      jw_obj(&w, NULL);
      jw_int(&w, "id", 0);
      jw_str(&w, "cmd", "pause");
      jw_oend(&w);
      jw_raw(&w, "\n", 1);
      (void)!write(eng_out, w.p, w.n);
      free(w.p);
    }
    char *l = eng_line(100);
    if (!l) continue;
    JVal *v = json_parse(l, strlen(l));
    free(l);
    if (v && json_get(v, "ev")) on_event(v);
    else json_free(v);
  }
  drain_stderr();
}

/* ------------------------------------------------------------ formatting */

static uint64_t hexv(const JVal *v) { return json_u64(v, 0); }
static const char *S(const JVal *o, const char *k) { return json_str(json_get(o, k), ""); }

static const char *const xr[32] = {
  "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

/* "0x5c <print_str> (print.s:34)" for a core summary or a disassembly line */
static void where(char *b, size_t n, const JVal *o, const char *pck) {
  const char *f = S(o, "file");
  const char *base = strrchr(f, '/') ? strrchr(f, '/') + 1 : f;
  int k = snprintf(b, n, "0x%llx", (unsigned long long)hexv(json_get(o, pck)));
  if (*S(o, "sym")) k += snprintf(b + k, n - (size_t)k, " <%s>", S(o, "sym"));
  if (*f && k < (int)n) snprintf(b + k, n - (size_t)k, " (%s:%d)", base, json_int(json_get(o, "line"), 0));
}

static const JVal *core_of(const JVal *stop, int c) {
  const JVal *a = json_get(stop, "cores");
  for (const JVal *e = a ? a->kid : NULL; e; e = e->next)
    if (json_int(json_get(e, "core"), -1) == c) return e;
  return NULL;
}

static void cap_line(char *b, size_t n, const JVal *k) {
  if (!json_bool(json_get(k, "valid"), false)) { snprintf(b, n, "-"); return; }
  int m = snprintf(b, n, "%s %s 0x%llx+0x%llx %s", json_bool(json_get(k, "live"), false) ? "live" : "DEAD", S(k, "space"),
                   (unsigned long long)hexv(json_get(k, "base")), (unsigned long long)hexv(json_get(k, "len")), S(k, "perms"));
  if (json_bool(json_get(k, "rv"), false) && m < (int)n) m += snprintf(b + m, n - (size_t)m, " rv gen %d", json_int(json_get(k, "gen"), 0));
  if (*S(k, "port") && m < (int)n) m += snprintf(b + m, n - (size_t)m, " (%s)", S(k, "port"));
  if (json_get(k, "id") && m < (int)n) snprintf(b + m, n - (size_t)m, " #%d", json_int(json_get(k, "id"), 0));
}

static void tui_draw(void);

static void show_stop(const JVal *ev) {
  if (!ev) return;
  if (tui) { tui_draw(); return; }
  if (con_inline && con_linel) { /* a line the guest has not finished yet */
    fprintf(out, "console| %.*s\n", (int)con_linel, con_line);
    con_linel = 0;
  }
  bool dn = !strcmp(S(ev, "ev"), "done");
  int c = json_int(json_get(ev, "core"), -1);
  if (c >= 0 && c < ncores) cur = c;
  if (dn) fprintf(out, "the machine has stopped: %s%s (tick %llu, round %llu)\n", S(ev, "why"),
                  json_bool(json_get(ev, "faulted"), false) ? ", a core faulted" : "",
                  (unsigned long long)json_u64(json_get(ev, "tick"), 0), (unsigned long long)json_u64(json_get(ev, "round"), 0));
  else
    fprintf(out, "stopped: %s (tick %llu, round %llu)\n", S(ev, "reason"), (unsigned long long)json_u64(json_get(ev, "tick"), 0),
            (unsigned long long)json_u64(json_get(ev, "round"), 0));
  const JVal *co = core_of(ev, cur);
  if (co && !json_bool(json_get(co, "halted"), false)) {
    char w[256];
    where(w, sizeof w, co, "pc");
    fprintf(out, "core %d: %s  %s\n", cur, w, S(co, "insn"));
  } else if (co) fprintf(out, "core %d: halted\n", cur);
}

/* ------------------------------------------------------------ the split screen */

static int term_w = 160, term_h = 48;

static void term_size(void) {
  struct winsize ws;
  if (!ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) && ws.ws_col) { term_w = ws.ws_col; term_h = ws.ws_row; }
}

typedef struct { char l[64][128]; int n; } Col;
static void col_add(Col *c, const char *fmt, ...) {
  if (c->n == 64) return;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(c->l[c->n++], sizeof c->l[0], fmt, ap);
  va_end(ap);
}

/* one core's column: disassembly around pc, registers, capabilities, busy tags */
static void tui_core(Col *col, int c, int w, int ndis) {
  JVal *r = req("disasm", "core#", (long long)c, "before#", (long long)(ndis / 3), "n#", (long long)ndis, NULL);
  const JVal *co = core_of(last_stop, c);
  col_add(col, "\x1b[1;36mcore %d\x1b[0m %s%s %s%s", c, co ? S(co, "mode") : "", co && json_get(co, "pid") ? "" : "",
          co && *S(co, "proc") ? S(co, "proc") : "", co && json_bool(json_get(co, "halted"), false) ? " HALTED" : "");
  const JVal *st = co ? json_get(co, "stall") : NULL;
  if (st) col_add(col, "\x1b[33mstall: %.*s\x1b[0m", w - 7, S(st, "why"));
  const JVal *lines = json_get(r, "lines");
  for (const JVal *e = lines ? lines->kid : NULL; e; e = e->next) {
    bool pc = json_bool(json_get(e, "pc"), false);
    if (*S(e, "label")) col_add(col, "\x1b[35m%s:\x1b[0m", S(e, "label"));
    col_add(col, "%s%c%c%04llx %s\x1b[0m", pc ? "\x1b[7m" : "", json_get(e, "bp") ? '*' : ' ', pc ? '>' : ' ',
            (unsigned long long)hexv(json_get(e, "addr")), S(e, "text"));
  }
  json_free(r);
  r = req("regs", "core#", (long long)c, NULL);
  const JVal *x = json_get(r, "x");
  int i = 0;
  char row[160] = "";
  for (const JVal *e = x ? x->kid : NULL; e; e = e->next, i++) {
    if (!i) continue;
    char cell[48];
    snprintf(cell, sizeof cell, "%-4s%16llx ", xr[i], (unsigned long long)hexv(e));
    strcat(row, cell);
    if (strlen(row) + 22 > (size_t)w || i == 31) { col_add(col, "%s", row); row[0] = 0; }
  }
  json_free(r);
  r = req("caps", "core#", (long long)c, NULL);
  const JVal *caps = json_get(r, "caps");
  i = 0;
  for (const JVal *e = caps ? caps->kid : NULL; e; e = e->next, i++) {
    if (!json_bool(json_get(e, "valid"), false)) continue;
    char b[160];
    cap_line(b, sizeof b, e);
    col_add(col, "c%-2d %s", i, b);
  }
  json_free(r);
  r = req("tags", "core#", (long long)c, NULL);
  const JVal *cs = json_get(r, "cores");
  const JVal *tg = cs && cs->kid ? json_get(cs->kid, "tags") : NULL;
  for (const JVal *e = tg ? tg->kid : NULL; e; e = e->next) {
    if (!json_get(e, "op")) continue;
    bool busy = json_bool(json_get(e, "busy"), false);
    col_add(col, "%stg%-2d %-5s %s:%llx ls %llx+%llx r%llu%s\x1b[0m", busy ? "\x1b[33m" : "\x1b[2m", json_int(json_get(e, "tag"), 0),
            S(e, "op"), S(e, "space"), (unsigned long long)hexv(json_get(e, "far")), (unsigned long long)hexv(json_get(e, "ls")),
            (unsigned long long)hexv(json_get(e, "len")), (unsigned long long)json_u64(json_get(e, "issued"), 0), busy ? " BUSY" : "");
  }
  json_free(r);
}

/* visible width of a string with ANSI escapes */
static int vis(const char *s) {
  int n = 0;
  for (; *s; s++) {
    if (*s == '\x1b') { while (*s && *s != 'm') s++; if (!*s) break; continue; }
    n++;
  }
  return n;
}
static void put_cell(const char *s, int w) {
  int n = 0;
  for (; *s && n < w; s++) {
    if (*s == '\x1b') { const char *e = s; while (*e && *e != 'm') e++; fwrite(s, 1, (size_t)(e - s + (*e ? 1 : 0)), out); s = *e ? e : e - 1; continue; }
    fputc(*s, out);
    n++;
  }
  fputs("\x1b[0m", out);
  for (; n < w; n++) fputc(' ', out);
}

static void tui_draw(void) {
  term_size();
  int colw = 44;
  int ncol = (term_w + 1) / (colw + 1);
  if (ncol < 1) ncol = 1;
  if (ncol > ncores) ncol = ncores;
  colw = (term_w - (ncol - 1)) / ncol;
  int first = cur - ncol / 2;
  if (first + ncol > ncores) first = ncores - ncol;
  if (first < 0) first = 0;
  static Col cols[16];
  int ndis = term_h > 40 ? 12 : 8;
  int rows = 0;
  for (int i = 0; i < ncol; i++) {
    cols[i].n = 0;
    tui_core(&cols[i], first + i, colw, ndis);
    if (cols[i].n > rows) rows = cols[i].n;
  }
  int room = term_h - 4 - (con_ntail ? (con_ntail < 4 ? con_ntail : 4) + 1 : 0);
  if (rows > room) rows = room;
  fputs("\x1b[H\x1b[2J", out);
  for (int r = 0; r < rows; r++) {
    for (int i = 0; i < ncol; i++) {
      if (i) fputs("\x1b[2m\xe2\x94\x82\x1b[0m", out);
      put_cell(r < cols[i].n ? cols[i].l[r] : "", i == ncol - 1 ? term_w - (colw + 1) * (ncol - 1) : colw);
    }
    fputc('\n', out);
  }
  if (con_ntail) {
    fprintf(out, "\x1b[2m-- console %.*s\x1b[0m\n", term_w - 12, "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------");
    for (int i = con_ntail > 4 ? con_ntail - 4 : 0; i < con_ntail; i++) fprintf(out, "%.*s\n", term_w, con_tail[i]);
  }
  if (last_stop) {
    bool dn = !strcmp(S(last_stop, "ev"), "done");
    fprintf(out, "\x1b[1m%s\x1b[0m  tick %llu  round %llu  core %d of %d%s\n", dn ? S(last_stop, "why") : S(last_stop, "reason"),
            (unsigned long long)json_u64(json_get(last_stop, "tick"), 0), (unsigned long long)json_u64(json_get(last_stop, "round"), 0),
            cur, ncores, ncol < ncores ? "  (core N: another view)" : "");
  }
  (void)vis;
  fflush(out);
}

/* ------------------------------------------------------------ commands */

static void refresh_stop(void) {
  JVal *r = req("cores", NULL);
  if (ok(r)) {
    /* make it look like a stop for the views */
    JW w = {0};
    jw_reset(&w);
    jw_obj(&w, NULL);
    jw_str(&w, "ev", "stopped");
    jw_str(&w, "reason", last_stop ? S(last_stop, "reason") : "");
    jw_uint(&w, "tick", json_u64(json_get(r, "tick"), 0));
    jw_uint(&w, "round", json_u64(json_get(r, "round"), 0));
    jw_oend(&w);
    JVal *s = json_parse(w.p, w.n);
    free(w.p);
    JVal *cs = json_get(r, "cores");
    if (s && cs) {
      /* move the cores array into s */
      JVal **tail = &s->kid;
      while (*tail) tail = &(*tail)->next;
      JVal **pp = &r->kid;
      while (*pp && *pp != cs) pp = &(*pp)->next;
      if (*pp) { *pp = cs->next; cs->next = NULL; *tail = cs; }
    }
    json_free(last_stop);
    last_stop = s;
  }
  json_free(r);
}

static const char *skipws(const char *s) { while (*s == ' ' || *s == '\t') s++; return s; }
static char *word(char **s) { /* the next word of *s */
  char *p = (char *)skipws(*s);
  if (!*p) return NULL;
  char *e = p;
  while (*e && *e != ' ' && *e != '\t') e++;
  if (*e) *e++ = 0;
  *s = e;
  return p;
}

/* "core N" and "if COND" anywhere in a breakpoint's words */
static void bp_extras(char *rest, int *core, char *cond, size_t nc) {
  *core = -1;
  cond[0] = 0;
  char *ifp = strstr(rest, " if ");
  if (!strncmp(rest, "if ", 3)) ifp = rest - 1;
  if (ifp) { snprintf(cond, nc, "%s", ifp + 4); *ifp = 0; }
  char *cp = strstr(rest, "core ");
  if (cp) { *core = atoi(cp + 5); *cp = 0; }
}

static void cmd_break(char *args, bool temp) {
  char cond[128];
  int core;
  bp_extras(args, &core, cond, sizeof cond);
  char *a = args, *k = word(&a);
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "cmd", temp ? "tbreak" : "break");
  if (!k) { snprintf(cond, sizeof cond, "0x%x", 0); k = NULL; }
  if (k && (!strcmp(k, "trap") || !strcmp(k, "svc") || !strcmp(k, "eret") || !strcmp(k, "halt") || !strcmp(k, "capop") ||
            !strcmp(k, "pid") || !strcmp(k, "process"))) {
    char *v = word(&a);
    jw_str(&w, "kind", !strcmp(k, "process") ? "pid" : k);
    if (!strcmp(k, "trap") && v) jw_str(&w, "cause", v);
    if (!strcmp(k, "capop") && v) jw_str(&w, "ops", v);
    if ((!strcmp(k, "pid") || !strcmp(k, "process")) && v) {
      if (isdigit((unsigned char)v[0])) jw_int(&w, "pid", atoi(v));
      else jw_str(&w, "name", v);
    }
  } else {
    jw_str(&w, "kind", "pc");
    if (k) jw_str(&w, "loc", k);
    else jw_str(&w, "loc", "0");
  }
  if (core >= 0) jw_int(&w, "core", core);
  if (cond[0]) jw_str(&w, "cond", cond);
  jw_oend(&w);
  JVal *r = request(&w);
  free(w.p);
  if (ok(r)) fprintf(out, "%s %d: %s\n", temp ? "Temporary breakpoint" : "Breakpoint", json_int(json_get(r, "bp"), 0), S(r, "desc"));
  json_free(r);
}

/* watch [dls|ils] LOC [LEN] | watch far|t2|t3|dev ADDR [LEN] | watch cap cN | watch tag tgN [issue|complete] */
static void cmd_watch(char *args, const char *access) {
  char cond[128];
  int core;
  bp_extras(args, &core, cond, sizeof cond);
  char *a = args, *k = word(&a);
  if (!k) { fprintf(out, "watch what?\n"); return; }
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "cmd", "watch");
  if (strcmp(k, "tag")) jw_str(&w, "access", access);
  if (!strcmp(k, "cap")) {
    char *r = word(&a);
    jw_str(&w, "kind", "cap");
    jw_int(&w, "reg", r ? atoi(r[0] == 'c' ? r + 1 : r) : 0);
    jw_int(&w, "core", core >= 0 ? core : cur);
  } else if (!strcmp(k, "tag")) {
    char *t = word(&a), *what = word(&a);
    jw_str(&w, "kind", "tag");
    jw_int(&w, "tag", t ? atoi(t[0] == 't' ? t + 2 : t) : 0);
    jw_str(&w, "access", what ? what : "both");
    if (core >= 0) jw_int(&w, "core", core);
  } else {
    bool far = !strcmp(k, "far") || !strcmp(k, "t2") || !strcmp(k, "t3") || !strcmp(k, "dev");
    const char *mem = "dls";
    if (!strcmp(k, "far")) k = word(&a);
    if (k && (!strcmp(k, "dls") || !strcmp(k, "ils"))) { mem = k; k = word(&a); }
    char *space = far ? k : NULL;
    if (far) k = word(&a);
    char *len = word(&a);
    if (!k) { fprintf(out, "watch where?\n"); free(w.p); return; }
    jw_str(&w, "kind", far ? "far" : "ls");
    if (far) jw_str(&w, "space", space);
    else jw_str(&w, "mem", mem);
    if (isdigit((unsigned char)k[0])) jw_str(&w, "addr", k);
    else jw_str(&w, "loc", k);
    if (len) jw_str(&w, "len", len);
    if (core >= 0) jw_int(&w, "core", core);
  }
  jw_oend(&w);
  JVal *r = request(&w);
  free(w.p);
  if (ok(r)) fprintf(out, "Watchpoint %d: %s\n", json_int(json_get(r, "bp"), 0), S(r, "desc"));
  json_free(r);
}

static void run_cmd(JW *w) {
  JVal *r = request(w);
  bool good = ok(r);
  json_free(r);
  if (!good) return;
  wait_stop();
  show_stop(last_stop);
}

static void run_simple(const char *cmd, int core, long long n) {
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "cmd", cmd);
  if (core >= 0) jw_int(&w, "core", core);
  if (n > 0) jw_int(&w, "n", n);
  jw_oend(&w);
  run_cmd(&w);
  free(w.p);
}

/* commands that the engine answers with a stop of its own (reverse execution, goto) */
static void travel(const char *cmd, int core, long long n, const char *extra_k, long long extra) {
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "cmd", cmd);
  if (core >= 0) jw_int(&w, "core", core);
  if (n > 0) jw_int(&w, "n", n);
  if (extra_k) jw_int(&w, extra_k, extra);
  jw_oend(&w);
  json_free(last_stop);
  last_stop = NULL;
  JVal *r = request(&w);
  free(w.p);
  bool good = ok(r);
  json_free(r);
  if (!good) return;
  if (!last_stop) wait_stop();
  show_stop(last_stop);
}

static void info_regs(int c) {
  JVal *r = req("regs", "core#", (long long)c, NULL);
  if (!ok(r)) { json_free(r); return; }
  char w[256];
  where(w, sizeof w, r, "pc");
  fprintf(out, "core %d  pc %s  %s\n", c, w, json_bool(json_get(r, "halted"), false) ? "(halted)" : "");
  const JVal *x = json_get(r, "x");
  int i = 0;
  for (const JVal *e = x ? x->kid : NULL; e; e = e->next, i++) {
    uint64_t v = hexv(e);
    fprintf(out, "%-4s 0x%016llx %-20lld%s", xr[i], (unsigned long long)v, (long long)v, i % 2 ? "\n" : "  ");
  }
  const JVal *csr = json_get(r, "csr");
  fprintf(out, "mode %s  instret %llu  ccr %s  cause %s epc %s tval %s tvec %s\n", S(csr, "mode"),
          (unsigned long long)json_u64(json_get(csr, "instret"), 0), S(csr, "ccr"), S(csr, "cause"), S(csr, "epc"), S(csr, "tval"),
          S(csr, "tvec"));
  fprintf(out, "ucause %s uepc %s utval %s utvec %s  corebase %s corecount %s  xslot %s\n", S(csr, "ucause"), S(csr, "uepc"),
          S(csr, "utval"), S(csr, "utvec"), S(csr, "corebase"), S(csr, "corecount"), S(csr, "xslot"));
  const JVal *st = json_get(r, "stall");
  if (st) fprintf(out, "stalled since round %llu: %s\n", (unsigned long long)json_u64(json_get(st, "since"), 0), S(st, "why"));
  json_free(r);
}

static void info_caps(int c) {
  JVal *r = req("caps", "core#", (long long)c, NULL);
  if (!ok(r)) { json_free(r); return; }
  const JVal *a = json_get(r, "caps");
  int i = 0;
  for (const JVal *e = a ? a->kid : NULL; e; e = e->next, i++) {
    char b[200];
    cap_line(b, sizeof b, e);
    fprintf(out, "c%-2d %s\n", i, b);
  }
  json_free(r);
}

static void info_tags(int c, bool all) {
  JVal *r = all ? req("tags", NULL) : req("tags", "core#", (long long)c, NULL);
  if (!ok(r)) { json_free(r); return; }
  const JVal *cs = json_get(r, "cores");
  for (const JVal *co = cs ? cs->kid : NULL; co; co = co->next) {
    const JVal *tg = json_get(co, "tags");
    int n = 0;
    for (const JVal *e = tg ? tg->kid : NULL; e; e = e->next) {
      if (!json_get(e, "op") && !all) continue;
      if (!json_get(e, "op")) continue;
      if (!n++) fprintf(out, "core %d:\n", json_int(json_get(co, "core"), 0));
      bool busy = json_bool(json_get(e, "busy"), false);
      fprintf(out, "  tg%-2d %-4s %-5s %s 0x%llx  ls 0x%llx len %llu  issued round %llu", json_int(json_get(e, "tag"), 0),
              busy ? "BUSY" : "idle", S(e, "op"), S(e, "space"), (unsigned long long)hexv(json_get(e, "far")),
              (unsigned long long)hexv(json_get(e, "ls")), (unsigned long long)hexv(json_get(e, "len")),
              (unsigned long long)json_u64(json_get(e, "issued"), 0));
      if (!busy) fprintf(out, ", completed round %llu", (unsigned long long)json_u64(json_get(e, "completed"), 0));
      if (*S(e, "port")) fprintf(out, "  (%s)", S(e, "port"));
      fputc('\n', out);
    }
    if (!n && !all) fprintf(out, "core %d: no transfer yet on any tag\n", json_int(json_get(co, "core"), 0));
    const JVal *st = json_get(co, "stall");
    if (st) fprintf(out, "  core %d stalled since round %llu: %s\n", json_int(json_get(co, "core"), 0),
                    (unsigned long long)json_u64(json_get(st, "since"), 0), S(st, "why"));
  }
  json_free(r);
}

static void info_cores(void) {
  JVal *r = req("cores", NULL);
  if (!ok(r)) { json_free(r); return; }
  fprintf(out, "tick %llu  round %llu  steps %llu\n", (unsigned long long)json_u64(json_get(r, "tick"), 0),
          (unsigned long long)json_u64(json_get(r, "round"), 0), (unsigned long long)json_u64(json_get(r, "steps"), 0));
  const JVal *cs = json_get(r, "cores");
  for (const JVal *e = cs ? cs->kid : NULL; e; e = e->next) {
    int c = json_int(json_get(e, "core"), 0);
    char w[256];
    where(w, sizeof w, e, "pc");
    fprintf(out, "%c core %-2d %-5s %s", c == cur ? '*' : ' ', c, S(e, "mode"), json_bool(json_get(e, "halted"), false) ? "halted" : w);
    if (json_get(e, "pid")) fprintf(out, "  pid %d %s", json_int(json_get(e, "pid"), 0), S(e, "proc"));
    if (!json_bool(json_get(e, "halted"), false)) fprintf(out, "  %s", S(e, "insn"));
    const JVal *st = json_get(e, "stall");
    if (st) fprintf(out, "\n      stalled since round %llu: %s", (unsigned long long)json_u64(json_get(st, "since"), 0), S(st, "why"));
    fputc('\n', out);
  }
  json_free(r);
}

static void info_list(const char *cmd, int c) {
  JVal *r = c >= 0 ? req(cmd, "core#", (long long)c, NULL) : req(cmd, NULL);
  if (!ok(r)) { json_free(r); return; }
  if (!strcmp(cmd, "ctab")) {
    const JVal *a = json_get(r, "entries");
    fprintf(out, "core %d save table (%d entries):\n", c, json_int(json_get(r, "size"), 0));
    for (const JVal *e = a ? a->kid : NULL; e; e = e->next) {
      char b[200];
      cap_line(b, sizeof b, json_get(e, "cap"));
      fprintf(out, "  slot %-3d %s\n", json_int(json_get(e, "slot"), 0), b);
    }
  } else if (!strcmp(cmd, "inbox")) {
    const JVal *a = json_get(r, "from");
    if (!a || !a->kid) fprintf(out, "core %d: the inbox is empty\n", c);
    for (const JVal *e = a ? a->kid : NULL; e; e = e->next) {
      const JVal *ks = json_get(e, "caps");
      for (const JVal *k = ks ? ks->kid : NULL; k; k = k->next) {
        char b[200];
        cap_line(b, sizeof b, k);
        fprintf(out, "  from node %-2d %s\n", json_int(json_get(e, "node"), 0), b);
      }
    }
  } else if (!strcmp(cmd, "xmap")) {
    const JVal *a = json_get(r, "entries");
    fprintf(out, "core %d overlay map (%d entries, xslot %s):\n", c, json_int(json_get(r, "size"), 16), S(r, "xslot"));
    for (const JVal *e = a ? a->kid : NULL; e; e = e->next) {
      if (!json_bool(json_get(e, "valid"), false)) continue;
      fprintf(out, "  %2d  %s 0x%llx -> I-LS 0x%llx %s\n", json_int(json_get(e, "index"), 0), S(e, "space"),
              (unsigned long long)hexv(json_get(e, "far")), (unsigned long long)hexv(json_get(e, "ils")), S(e, "sym"));
    }
  } else if (!strcmp(cmd, "pending")) {
    const JVal *a = json_get(r, "reads");
    if (!a || !a->kid) fprintf(out, "no pending device reads\n");
    for (const JVal *e = a ? a->kid : NULL; e; e = e->next)
      fprintf(out, "core %d tg%d: %s (port 0x%llx) into D-LS 0x%llx+%llu, issued round %llu, waits for %s\n",
              json_int(json_get(e, "core"), 0), json_int(json_get(e, "tag"), 0), S(e, "name"), (unsigned long long)hexv(json_get(e, "port")),
              (unsigned long long)hexv(json_get(e, "ls")), (unsigned long long)hexv(json_get(e, "len")),
              (unsigned long long)json_u64(json_get(e, "issued"), 0), S(e, "waits"));
    const JVal *b = json_get(r, "blk");
    fprintf(out, "block device: %d command(s), %d capability(ies) given, %d completion(s) waiting\n",
            json_int(json_get(b, "commands"), 0), json_int(json_get(b, "caps"), 0), json_int(json_get(b, "completions"), 0));
    fprintf(out, "console input queued: %d byte(s); timer now %llu, deadline %s\n", json_int(json_get(r, "input_queued"), 0),
            (unsigned long long)json_u64(json_get(r, "now"), 0), S(r, "deadline"));
  } else if (!strcmp(cmd, "processes")) {
    const JVal *a = json_get(r, "procs");
    fprintf(out, "  pid parent state  core n  running  name\n");
    for (const JVal *e = a ? a->kid : NULL; e; e = e->next) {
      char run[64] = "";
      const JVal *rn = json_get(e, "running");
      for (const JVal *k = rn ? rn->kid : NULL; k; k = k->next) {
        size_t l = strlen(run);
        snprintf(run + l, sizeof run - l, "%s%d", l ? "," : "", json_int(k, 0));
      }
      fprintf(out, "%5d %6d %5d %5d %d  %-8s %s\n", json_int(json_get(e, "pid"), 0), json_int(json_get(e, "parent"), 0),
              json_int(json_get(e, "state"), 0), json_int(json_get(e, "core"), 0), json_int(json_get(e, "ncores"), 0),
              run[0] ? run : "-", S(e, "name"));
    }
  } else if (!strcmp(cmd, "granules")) {
    const JVal *a = json_get(r, "units");
    if (!a || !a->kid) fprintf(out, "no revocable regions yet\n");
    for (const JVal *e = a ? a->kid : NULL; e; e = e->next)
      fprintf(out, "  %s 0x%08llx +0x%llx  generation %d\n", S(e, "space"), (unsigned long long)hexv(json_get(e, "base")),
              (unsigned long long)hexv(json_get(e, "len")), json_int(json_get(e, "gen"), 0));
  } else if (!strcmp(cmd, "breakpoints")) {
    const JVal *a = json_get(r, "bps");
    if (!a || !a->kid) fprintf(out, "no breakpoints or watchpoints\n");
    for (const JVal *e = a ? a->kid : NULL; e; e = e->next)
      fprintf(out, "%-3d %-5s %s  %s  hits %llu%s\n", json_int(json_get(e, "id"), 0), S(e, "kind"),
              json_bool(json_get(e, "on"), false) ? "on " : "off", S(e, "desc"), (unsigned long long)json_u64(json_get(e, "hits"), 0),
              json_bool(json_get(e, "temp"), false) ? " (temporary)" : "");
  } else if (!strcmp(cmd, "history")) {
    const JVal *h = json_get(r, "history");
    fprintf(out, "time travel: ticks %llu..%llu, %d snapshot(s) every %llu ticks, %.1f MiB of %.0f, %llu input(s) logged\n",
            (unsigned long long)json_u64(json_get(h, "from"), 0), (unsigned long long)json_u64(json_get(h, "to"), 0),
            json_int(json_get(h, "snapshots"), 0), (unsigned long long)json_u64(json_get(h, "every"), 0),
            json_num(json_get(h, "bytes"), 0) / 1048576.0, json_num(json_get(h, "budget"), 0) / 1048576.0,
            (unsigned long long)json_u64(json_get(h, "inputs"), 0));
    if (json_u64(json_get(h, "diverged"), 0)) fprintf(out, "WARNING: %llu replay(s) diverged\n", (unsigned long long)json_u64(json_get(h, "diverged"), 0));
  }
  json_free(r);
}

static void disassemble(int c, const char *loc, int n, int before) {
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "cmd", "disasm");
  jw_int(&w, "core", c);
  if (loc) jw_str(&w, "loc", loc);
  jw_int(&w, "n", n);
  jw_int(&w, "before", before);
  jw_oend(&w);
  JVal *r = request(&w);
  free(w.p);
  if (!ok(r)) { json_free(r); return; }
  const char *lastfile = "";
  int lastline = -1;
  const JVal *lines = json_get(r, "lines");
  for (const JVal *e = lines ? lines->kid : NULL; e; e = e->next) {
    if (*S(e, "label")) fprintf(out, "%s:\n", S(e, "label"));
    const char *f = S(e, "file");
    int ln = json_int(json_get(e, "line"), 0);
    char src[64] = "";
    if (*f && (strcmp(f, lastfile) || ln != lastline)) {
      const char *b = strrchr(f, '/') ? strrchr(f, '/') + 1 : f;
      snprintf(src, sizeof src, "%s:%d", b, ln);
    }
    lastfile = f;
    lastline = ln;
    fprintf(out, "%c%c 0x%04llx  %s  %-36s %s\n", json_get(e, "bp") ? '*' : ' ', json_bool(json_get(e, "pc"), false) ? '>' : ' ',
            (unsigned long long)hexv(json_get(e, "addr")), S(e, "word"), S(e, "text"), src);
  }
  json_free(r);
}

/* x/NF [space:]ADDR|LOC: F = b, h, w, g (hex units), s (string), i (instructions) */
static void examine(const char *fmt, char *arg) {
  int n = 0;
  char f = 'b';
  if (fmt) {
    n = atoi(fmt);
    for (const char *p = fmt; *p; p++)
      if (isalpha((unsigned char)*p)) f = *p;
  }
  if (!arg) { fprintf(out, "x/N[bhwgsi] [dls:|ils:|t2:|t3:|disk:]ADDR\n"); return; }
  if (f == 'i') { disassemble(cur, arg, n ? n : 8, 0); return; }
  if (!n) n = f == 's' ? 64 : f == 'b' ? 16 : 4;
  int unit = f == 'h' ? 2 : f == 'w' ? 4 : f == 'g' ? 8 : 1;
  char space[16] = "";
  char *colon = strchr(arg, ':');
  if (colon && colon - arg < 6 && (strncmp(arg, "dls", 3) == 0 || !strncmp(arg, "ils", 3) || !strncmp(arg, "t2", 2) || !strncmp(arg, "t3", 2) || !strncmp(arg, "disk", 4))) {
    snprintf(space, sizeof space, "%.*s", (int)(colon - arg), arg);
    arg = colon + 1;
  }
  JW w = {0};
  jw_reset(&w);
  jw_obj(&w, NULL);
  jw_str(&w, "cmd", "mem");
  jw_int(&w, "core", cur);
  if (space[0]) jw_str(&w, "space", space);
  if (isdigit((unsigned char)arg[0])) jw_str(&w, "addr", arg);
  else jw_str(&w, "loc", arg);
  jw_int(&w, "len", (long long)n * unit);
  jw_oend(&w);
  JVal *r = request(&w);
  free(w.p);
  if (!ok(r)) { json_free(r); return; }
  const char *hex = S(r, "hex");
  uint64_t a = hexv(json_get(r, "addr"));
  size_t nb = strlen(hex) / 2;
  uint8_t *b = malloc(nb + 1);
  for (size_t i = 0; i < nb; i++) { unsigned v; sscanf(hex + 2 * i, "%2x", &v); b[i] = (uint8_t)v; }
  if (f == 's') {
    fprintf(out, "%s:0x%llx: \"", S(r, "space"), (unsigned long long)a);
    for (size_t i = 0; i < nb && b[i]; i++) fputc(b[i] >= ' ' && b[i] < 127 ? b[i] : '.', out);
    fprintf(out, "\"\n");
  } else {
    int per = 16 / unit;
    for (size_t i = 0; i < nb; i += (size_t)unit) {
      if ((i / (size_t)unit) % (size_t)per == 0) fprintf(out, "%s%s:0x%08llx:", i ? "\n" : "", S(r, "space"), (unsigned long long)(a + i));
      uint64_t v = 0;
      for (int k = unit - 1; k >= 0; k--) v = v << 8 | b[i + (size_t)k];
      fprintf(out, " %0*llx", unit * 2, (unsigned long long)v);
    }
    fputc('\n', out);
  }
  free(b);
  json_free(r);
}

static void cmd_list(const char *loc) {
  /* the source around the current core's pc (or LOC) */
  JVal *r = loc ? req("disasm", "core#", (long long)cur, "loc=", loc, "n#", 1LL, NULL) : req("disasm", "core#", (long long)cur, "n#", 1LL, NULL);
  if (!ok(r)) { json_free(r); return; }
  const JVal *l = json_get(r, "lines");
  const JVal *e = l ? l->kid : NULL;
  if (!e || !*S(e, "file")) { fprintf(out, "no source for that address\n"); json_free(r); return; }
  char file[1024];
  snprintf(file, sizeof file, "%s", S(e, "file"));
  int line = json_int(json_get(e, "line"), 1);
  json_free(r);
  r = req("source", "file=", file, "from#", (long long)(line > 5 ? line - 5 : 1), "n#", 11LL, NULL);
  if (!ok(r)) { json_free(r); return; }
  int no = line > 5 ? line - 5 : 1;
  const JVal *ls = json_get(r, "lines");
  for (const JVal *k = ls ? ls->kid : NULL; k; k = k->next, no++) fprintf(out, "%c%5d  %s\n", no == line ? '>' : ' ', no, k->s);
  json_free(r);
}

static void cmd_log(int n) {
  JVal *st = req("status", NULL);
  uint64_t last = json_u64(json_get(st, "events"), 0);
  json_free(st);
  uint64_t since = last > (uint64_t)n ? last - (uint64_t)n : 0;
  JVal *r = req("log", "since#", (long long)since, "limit#", (long long)n, NULL);
  if (!ok(r)) { json_free(r); return; }
  const JVal *a = json_get(r, "events");
  for (const JVal *e = a ? a->kid : NULL; e; e = e->next) {
    const char *k = S(e, "kind");
    fprintf(out, "r%-8llu core %-2d %-6s", (unsigned long long)json_u64(json_get(e, "round"), 0), json_int(json_get(e, "core"), 0), k);
    if (!strcmp(k, "xfer"))
      fprintf(out, " tg%d %s %s 0x%llx <-> ls 0x%llx len %llu%s %s", json_int(json_get(e, "tag"), 0), S(e, "op"), S(e, "space"),
              (unsigned long long)hexv(json_get(e, "far")), (unsigned long long)hexv(json_get(e, "ls")), (unsigned long long)hexv(json_get(e, "len")),
              json_bool(json_get(e, "pending"), false) ? " pending" : "", S(e, "port"));
    else if (!strcmp(k, "xdone")) fprintf(out, " tg%d %s completed (issued round %llu)", json_int(json_get(e, "tag"), 0), S(e, "port"), (unsigned long long)json_u64(json_get(e, "issued"), 0));
    else if (!strcmp(k, "trap")) fprintf(out, " %s tval %s at %s%s", S(e, "cause"), S(e, "tval"), S(e, "pc"), json_bool(json_get(e, "user"), false) ? " (user)" : "");
    else if (!strcmp(k, "give") || !strcmp(k, "send")) fprintf(out, " -> node %d: %s 0x%llx+0x%llx %s #%d", json_int(json_get(e, "to"), 0), S(e, "space"), (unsigned long long)hexv(json_get(e, "base")), (unsigned long long)hexv(json_get(e, "len")), S(e, "perms"), json_int(json_get(e, "cap"), 0));
    else if (!strcmp(k, "take") || !strcmp(k, "recv")) fprintf(out, " <- node %d: %s 0x%llx+0x%llx %s #%d", json_int(json_get(e, "from"), 0), S(e, "space"), (unsigned long long)hexv(json_get(e, "base")), (unsigned long long)hexv(json_get(e, "len")), S(e, "perms"), json_int(json_get(e, "cap"), 0));
    else if (!strcmp(k, "stall")) fprintf(out, " rounds %llu..%llu %s", (unsigned long long)json_u64(json_get(e, "from"), 0), (unsigned long long)json_u64(json_get(e, "to"), 0), S(e, "reason"));
    else if (!strcmp(k, "eret")) fprintf(out, " %s -> %s%s", S(e, "from"), S(e, "to"), json_bool(json_get(e, "user"), false) ? " (user)" : "");
    else if (!strcmp(k, "halt")) fprintf(out, " a0 %s", S(e, "a0"));
    else if (!strcmp(k, "dom") || !strcmp(k, "revoke") || !strcmp(k, "undom")) fprintf(out, " %s 0x%llx+0x%llx gen %d", S(e, "space"), (unsigned long long)hexv(json_get(e, "base")), (unsigned long long)hexv(json_get(e, "len")), json_int(json_get(e, "gen"), 0));
    if (json_get(e, "pid")) fprintf(out, "  [pid %d]", json_int(json_get(e, "pid"), 0));
    fputc('\n', out);
  }
  json_free(r);
}

static void cmd_prov(const char *arg) {
  JVal *r;
  if (arg && arg[0] == 'c') r = req("prov", "core#", (long long)cur, "reg#", (long long)atoi(arg + 1), NULL);
  else if (arg && arg[0] == '#') r = req("prov", "id#", (long long)atoi(arg + 1), NULL);
  else { fprintf(out, "prov cN | prov #ID\n"); return; }
  if (!ok(r)) { json_free(r); return; }
  const JVal *a = json_get(r, "chain");
  int depth = 0;
  for (const JVal *e = a ? a->kid : NULL; e; e = e->next, depth++) {
    char w[256] = "";
    if (json_get(e, "pc")) where(w, sizeof w, e, "pc");
    fprintf(out, "%*s#%d %s %s 0x%llx+0x%llx %s  by core %d", depth * 2, "", json_int(json_get(e, "id"), 0), S(e, "op"), S(e, "space"),
            (unsigned long long)hexv(json_get(e, "base")), (unsigned long long)hexv(json_get(e, "len")), S(e, "perms"),
            json_int(json_get(e, "core"), -1));
    if (json_get(e, "from")) fprintf(out, " from node %d", json_int(json_get(e, "from"), 0));
    fprintf(out, " round %llu%s%s\n", (unsigned long long)json_u64(json_get(e, "round"), 0), w[0] ? " at " : "", w);
  }
  json_free(r);
}

static void cmd_bt(int c) {
  JVal *r = req("backtrace", "core#", (long long)c, NULL);
  if (!ok(r)) { json_free(r); return; }
  const JVal *a = json_get(r, "frames");
  int i = 0;
  for (const JVal *e = a ? a->kid : NULL; e; e = e->next, i++) {
    char w[256];
    where(w, sizeof w, e, "pc");
    fprintf(out, "#%d  %s%s%s\n", i, w, *S(e, "via") ? "  via " : "", S(e, "via"));
  }
  json_free(r);
}

/* a string with C escapes (\n, \t, \\, \xNN) */
static size_t unescape(const char *s, char *o, size_t n) {
  size_t k = 0;
  for (; *s && k < n; s++) {
    if (*s != '\\' || !s[1]) { o[k++] = *s; continue; }
    s++;
    switch (*s) {
    case 'n': o[k++] = '\n'; break;
    case 't': o[k++] = '\t'; break;
    case 'r': o[k++] = '\r'; break;
    case 'x': { unsigned v = 0; sscanf(s + 1, "%2x", &v); o[k++] = (char)v; s += 2; break; }
    default: o[k++] = *s;
    }
  }
  return k;
}

static void help(void) {
  fputs("Running\n"
        "  continue (c)            run until a breakpoint, a watchpoint or Ctrl-C\n"
        "  fast (ff)               the same, not recorded (the JIT, without breakpoints): the\n"
        "                          history restarts where it stops (catching up: a boot, a splash)\n"
        "  stepi (si) [N]          N instructions of the current core (other cores run their rounds)\n"
        "  next (ni)               one instruction, stepping over a call\n"
        "  finish                  until the current function returns (pc = ra)\n"
        "  step-round (sr) [N]     N whole machine rounds\n"
        "  until LOC | advance LOC run to LOC (any core)\n"
        "  core N                  make core N the current core\n"
        "  follow PID              stepi follows this process across switches and cores (0: off)\n"
        "Time travel (deterministic runs: -T virtual)\n"
        "  reverse-stepi (rsi) [N] back N instructions of the current core\n"
        "  reverse-continue (rc)   back to the last breakpoint or watchpoint hit\n"
        "  reverse-step-round (rsr) [N]   back to the start of the round, or N rounds\n"
        "  reverse-tag tgN         back to the issue of the current core's tag N\n"
        "  goto TICK               to any tick of the recorded run (info history)\n"
        "Breakpoints and watchpoints\n"
        "  break (b) LOC [core N] [if REG OP VALUE]   LOC: address, label, label+N, file.s:LINE, prog:label\n"
        "  tbreak LOC              the same, once\n"
        "  break trap [CAUSE] | svc | eret | halt | capop [give,take,send,recv,dom,revoke,...]\n"
        "  break process NAME|PID  when the process starts running on a core (StrataOS)\n"
        "  watch [dls|ils] LOC [LEN] [core N]   Local Store bytes written (rwatch: read, awatch: both)\n"
        "  watch t2|t3|dev ADDR [LEN]           far memory touched by transfers (and devices' ports)\n"
        "  watch cap cN [core N]   a capability register changes\n"
        "  watch tag tgN [issue|complete] [core N]\n"
        "  delete [N], enable N, disable N, info breakpoints\n"
        "State\n"
        "  info registers (i r) | caps | ctab | inbox | xmap | tags [all] | pending | cores\n"
        "  info processes | granules | history\n"
        "  x/N[bhwgsi] [dls:|ils:|t2:|t3:|disk:]ADDR|LOC\n"
        "  disassemble (disas) [LOC] [N],  list [LOC],  backtrace (bt)\n"
        "  log [N]                 the last N events (transfers, traps, gifts, stalls)\n"
        "  prov cN | prov #ID      where a capability came from\n"
        "  set REG VALUE           change a register of the current core (set pc 0x100)\n"
        "Console\n"
        "  input TEXT              console input (\\n, \\t, \\xNN escapes); ctrl-c: the break key\n"
        "  tui                     the split screen on / off;  refresh\n"
        "  quit (q)\n", out);
}

static int follow_pid;

/* one command line; false at quit */
static bool command(char *line) {
  line[strcspn(line, "\r\n")] = 0;
  char *s = (char *)skipws(line);
  if (!*s || *s == '#') return true;
  char *rest = s;
  char *c = word(&rest);
  char *slash = strchr(c, '/');
  char *fmt = NULL;
  if (slash && c[0] == 'x') { *slash = 0; fmt = slash + 1; }
  rest = (char *)skipws(rest);
  char *arg1 = NULL;
  {
    char tmp[1024];
    snprintf(tmp, sizeof tmp, "%s", rest);
    char *t = tmp;
    char *a = word(&t);
    static char a1[1024];
    if (a) { snprintf(a1, sizeof a1, "%s", a); arg1 = a1; }
  }
  long long n = arg1 && isdigit((unsigned char)arg1[0]) ? strtoll(arg1, NULL, 0) : 0;
#define IS(a) (!strcmp(c, a))
  if (IS("q") || IS("quit")) return false;
  else if (IS("help") || IS("h")) help();
  else if (IS("c") || IS("continue")) run_simple("continue", -1, 0);
  else if (IS("ff") || IS("fast")) { /* continue, not recorded, at full speed: recording starts again where it stops */
    JW w = {0};
    jw_reset(&w);
    jw_obj(&w, NULL);
    jw_str(&w, "cmd", "continue");
    jw_bool(&w, "fast", true);
    jw_oend(&w);
    run_cmd(&w);
    free(w.p);
  }
  else if (IS("si") || IS("stepi")) {
    if (follow_pid) {
      JW w = {0};
      jw_reset(&w);
      jw_obj(&w, NULL);
      jw_str(&w, "cmd", "stepi");
      jw_int(&w, "pid", follow_pid);
      if (n) jw_int(&w, "n", n);
      jw_oend(&w);
      run_cmd(&w);
      free(w.p);
    } else run_simple("stepi", cur, n);
  } else if (IS("ni") || IS("next")) run_simple("next", cur, 0);
  else if (IS("finish")) run_simple("finish", cur, 0);
  else if (IS("sr") || IS("step-round")) run_simple("step-round", -1, n);
  else if (IS("until") || IS("advance")) {
    if (!arg1) { fprintf(out, "until LOC\n"); return true; }
    JW w = {0};
    jw_reset(&w);
    jw_obj(&w, NULL);
    jw_str(&w, "cmd", "until");
    jw_str(&w, "loc", arg1);
    jw_oend(&w);
    run_cmd(&w);
    free(w.p);
  } else if (IS("rsi") || IS("reverse-stepi")) travel("reverse-stepi", cur, n, NULL, 0);
  else if (IS("rc") || IS("reverse-continue")) travel("reverse-continue", -1, 0, NULL, 0);
  else if (IS("rsr") || IS("reverse-step-round")) travel("reverse-step-round", -1, n, NULL, 0);
  else if (IS("reverse-tag")) travel("reverse-tag", cur, 0, "tag", arg1 ? atoi(arg1[0] == 't' ? arg1 + 2 : arg1) : 0);
  else if (IS("goto")) travel("goto", -1, 0, "tick", n);
  else if (IS("core")) {
    if (arg1 && n >= 0 && n < ncores) cur = (int)n;
    fprintf(out, "current core: %d\n", cur);
    if (tui) tui_draw();
  } else if (IS("follow")) {
    follow_pid = (int)n;
    fprintf(out, follow_pid ? "stepi follows pid %d\n" : "stepi steps the current core\n", follow_pid);
  } else if (IS("b") || IS("break")) cmd_break(rest, false);
  else if (IS("tbreak")) cmd_break(rest, true);
  else if (IS("watch")) cmd_watch(rest, "w");
  else if (IS("rwatch")) cmd_watch(rest, "r");
  else if (IS("awatch")) cmd_watch(rest, "rw");
  else if (IS("delete") || IS("d") || IS("enable") || IS("disable")) {
    JVal *r = arg1 ? req(IS("d") ? "delete" : c, "bp#", n, NULL) : req(IS("d") ? "delete" : c, NULL);
    ok(r);
    json_free(r);
  } else if (IS("i") || IS("info")) {
    char *w = rest, *what = word(&w), *a2 = word(&w);
    if (!what) { fprintf(out, "info what?\n"); return true; }
    int core = a2 && isdigit((unsigned char)a2[0]) ? atoi(a2) : cur;
    if (!strcmp(what, "r") || !strncmp(what, "reg", 3)) info_regs(core);
    else if (!strncmp(what, "cap", 3)) info_caps(core);
    else if (!strcmp(what, "tags")) info_tags(core, a2 && !strcmp(a2, "all"));
    else if (!strcmp(what, "cores") || !strcmp(what, "threads")) info_cores();
    else if (!strcmp(what, "ctab") || !strcmp(what, "inbox") || !strcmp(what, "xmap")) info_list(what, core);
    else if (!strcmp(what, "pending") || !strcmp(what, "granules") || !strcmp(what, "history")) info_list(what, -1);
    else if (!strncmp(what, "proc", 4)) info_list("processes", -1);
    else if (!strncmp(what, "break", 5) || !strcmp(what, "b") || !strncmp(what, "watch", 5)) info_list("breakpoints", -1);
    else fprintf(out, "info registers, caps, ctab, inbox, xmap, tags, pending, cores, processes, granules, history, breakpoints\n");
  } else if (IS("x")) examine(fmt, arg1);
  else if (IS("disassemble") || IS("disas")) {
    char *w = rest, *loc = word(&w), *cnt = word(&w);
    if (loc && isdigit((unsigned char)loc[0]) && !cnt && strlen(loc) < 4) { cnt = loc; loc = NULL; }
    disassemble(cur, loc, cnt ? atoi(cnt) : 16, loc ? 0 : 4);
  } else if (IS("list") || IS("l")) cmd_list(arg1);
  else if (IS("bt") || IS("backtrace") || IS("where")) cmd_bt(cur);
  else if (IS("log")) cmd_log(n ? (int)n : 20);
  else if (IS("prov")) cmd_prov(arg1);
  else if (IS("input")) {
    char buf[4096];
    size_t k = unescape(rest, buf, sizeof buf);
    JW w = {0};
    jw_reset(&w);
    jw_obj(&w, NULL);
    jw_str(&w, "cmd", "input");
    jw_strn(&w, "data", buf, k);
    jw_oend(&w);
    JVal *r = request(&w);
    free(w.p);
    ok(r);
    json_free(r);
  } else if (IS("ctrl-c")) { JVal *r = req("ctrl-c", NULL); ok(r); json_free(r); }
  else if (IS("set")) {
    char *w = rest, *reg = word(&w), *val = word(&w);
    if (val && !strcmp(val, "=")) val = word(&w);
    if (!reg || !val) { fprintf(out, "set REG VALUE\n"); return true; }
    if (reg[0] == '$') reg++;
    JVal *r = req("set-reg", "core#", (long long)cur, "reg=", reg, "value=", val, NULL);
    ok(r);
    json_free(r);
  } else if (IS("tui")) {
    tui = !tui;
    if (tui) { refresh_stop(); tui_draw(); }
    else fputs("\x1b[H\x1b[2J", out);
  } else if (IS("refresh")) { refresh_stop(); if (tui) tui_draw(); else show_stop(last_stop); }
  else if (IS("echo")) fprintf(out, "%s\n", rest);
  else if (IS("console")) {
    JVal *r = req("console", NULL);
    if (ok(r)) fputs(S(r, "data"), out);
    json_free(r);
  } else fprintf(out, "unknown command %s (help lists them)\n", c);
#undef IS
  fflush(out);
  return true;
}

/* ------------------------------------------------------------ start */

static void on_sigint(int sig) { (void)sig; interrupted = 1; }

static void connect_to(const char *where) {
  int fd;
  if (!strncmp(where, "unix:", 5)) {
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "%s", where + 5);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a)) die("cannot connect to %s: %s", where, strerror(errno));
  } else {
    char host[256] = "127.0.0.1", port[16];
    const char *colon = strrchr(where, ':');
    if (colon) { snprintf(host, sizeof host, "%.*s", (int)(colon - where), where); snprintf(port, sizeof port, "%s", colon + 1); }
    else snprintf(port, sizeof port, "%s", where);
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res)) die("cannot resolve %s", where);
    fd = socket(res->ai_family, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen)) die("cannot connect to %s: %s", where, strerror(errno));
    freeaddrinfo(res);
  }
  eng_in = eng_out = fd;
}

/* Starts strata-emu --debug stdio with the emulator's arguments. */
static void launch(char **args, int nargs, const char *argv0) {
  const char *emu = getenv("STRATA_EMU");
  char path[4096];
  if (!emu) {
    const char *sl = strrchr(argv0, '/');
    if (sl) snprintf(path, sizeof path, "%.*s/strata-emu", (int)(sl - argv0), argv0);
    else snprintf(path, sizeof path, "strata-emu");
    emu = path;
  }
  int to[2], from[2], err[2];
  if (pipe(to) || pipe(from) || pipe(err)) die("pipe: %s", strerror(errno));
  eng_pid = fork();
  if (eng_pid < 0) die("fork: %s", strerror(errno));
  if (!eng_pid) {
    dup2(to[0], 0);
    dup2(from[1], 1);
    dup2(err[1], 2);
    close(to[1]);
    close(from[0]);
    close(err[0]);
    char **av = calloc((size_t)nargs + 4, sizeof *av);
    int k = 0;
    av[k++] = (char *)emu;
    av[k++] = "--debug";
    av[k++] = "stdio";
    for (int i = 0; i < nargs; i++) av[k++] = args[i];
    execvp(emu, av);
    fprintf(stderr, "strata-dbg: cannot run %s: %s\n", emu, strerror(errno));
    _exit(127);
  }
  close(to[0]);
  close(from[1]);
  close(err[1]);
  eng_out = to[1];
  eng_in = from[0];
  eng_err = err[0];
}

static void console_open(const char *how) {
  if (!strcmp(how, "-")) { con_inline = true; return; }
  if (!strcmp(how, "none")) return;
  if (!strcmp(how, "pty")) {
    int m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0 || grantpt(m) || unlockpt(m)) { fprintf(stderr, "strata-dbg: no pty (%s): the console is inline\n", strerror(errno)); con_inline = true; return; }
    const char *name = ptsname(m);
    con_fd = con_pty = m;
    fprintf(out, "The guest's console is %s: open it in another terminal (screen %s, or cat %s);\n"
                 "what you type there is its input. (--console FILE or --console - put it elsewhere.)\n", name, name, name);
    return;
  }
  con_fd = open(how, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (con_fd < 0) die("cannot open console %s: %s", how, strerror(errno));
}

int main(int argc, char **argv) {
  out = stdout;
  const char *conn = NULL, *console = NULL, *script = NULL;
  char **eargs = calloc((size_t)argc + 1, sizeof *eargs);
  int ne = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--connect") && i + 1 < argc) conn = argv[++i];
    else if (!strcmp(argv[i], "--console") && i + 1 < argc) console = argv[++i];
    else if (!strcmp(argv[i], "-x") && i + 1 < argc) script = argv[++i];
    else if (!strcmp(argv[i], "--tui")) tui = true;
    else if (!strcmp(argv[i], "--batch")) batch = true;
    else if (!strcmp(argv[i], "--help")) {
      fprintf(stderr, "usage: strata-dbg [--console pty|FILE|-] [--tui] [-x FILE] [--batch] [emulator options] image.stx\n"
                      "       strata-dbg [options] --connect HOST:PORT | unix:PATH\n");
      return 0;
    } else eargs[ne++] = argv[i];
  }
  bool interactive = isatty(STDIN_FILENO) && !batch;
  if (!interactive) tui = false;
  if (conn) connect_to(conn);
  else if (ne) launch(eargs, ne, argv[0]);
  else die("an image to debug, or --connect (strata-dbg --help)");
  console_open(console ? console : interactive ? "pty" : "-");
  signal(SIGINT, on_sigint);
  signal(SIGPIPE, SIG_IGN);
  JVal *h = req("hello", NULL);
  if (!ok(h)) return 1;
  ncores = json_int(json_get(h, "ncores"), 1);
  os_aware = json_bool(json_get(h, "os"), false);
  if (interactive) {
    fprintf(out, "strata-dbg: %s on %d core(s)%s%s%s\n", S(h, "image"), ncores, json_bool(json_get(h, "timetravel"), false) ? ", time travel on" : "",
            os_aware ? ", StrataOS aware" : "", json_bool(json_get(h, "jit"), false) ? ", JIT for fast continues (ff)" : "");
    const JVal *maps = json_get(h, "maps");
    for (const JVal *m = maps ? maps->kid : NULL; m; m = m->next)
      fprintf(out, "  map %s (%s%s)\n", S(m, "path"), S(m, "scope"), json_bool(json_get(m, "forth"), false) ? ", Forth words" : "");
  }
  json_free(h);
  refresh_stop();
  if (tui) tui_draw();
  char line[4096];
  if (script) {
    FILE *f = fopen(script, "r");
    if (!f) die("cannot open %s", script);
    while (fgets(line, sizeof line, f)) {
      if (!interactive) fprintf(out, "(sdb) %s", line);
      if (!command(line)) { fclose(f); goto end; }
    }
    fclose(f);
  }
  for (;;) {
    if (interactive) { fprintf(out, "(sdb) "); fflush(out); }
    interrupted = 0;
    if (!fgets(line, sizeof line, stdin)) {
      if (interactive && errno == EINTR) { clearerr(stdin); fputc('\n', out); continue; }
      break;
    }
    if (!interactive) fprintf(out, "(sdb) %s", line);
    if (!command(line)) break;
    drain_stderr();
  }
end:
  {
    JVal *r = req("quit", NULL);
    json_free(r);
  }
  drain_stderr();
  if (eng_pid) waitpid(eng_pid, NULL, 0);
  drain_stderr();
  if (tui) fputs("\x1b[0m\n", out);
  return 0;
}
