/* The debug engine on the desktop: its transports and its main loop. Part
 * of emu/debug.c (which includes this file outside the browser build).
 *
 *   --debug PORT | HOST:PORT   a TCP port (127.0.0.1 unless HOST is given).
 *                              Each connection is detected by its first bytes:
 *                              an HTTP request is either a WebSocket upgrade
 *                              (the web debugger: one text message per JSON
 *                              line) or a GET of a file of the --www tree
 *                              (default site/: http://localhost:PORT/debug/);
 *                              anything else is raw JSON lines.
 *   --debug unix:PATH          raw JSON lines on a Unix-domain socket
 *   --debug stdio              raw JSON lines on stdin / stdout (strata-dbg
 *                              starts the emulator this way); stdout is
 *                              moved to stderr so nothing else can reach it
 * Every client gets every event. */
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>

enum { CL_NEW, CL_LINES, CL_WS };
typedef struct {
  int rfd, wfd, kind;
  char *in;
  size_t inl, incap;
} Client;
#define DBG_MAXCL 8
static Client dbg_cl[DBG_MAXCL];
static int dbg_ncl;
static int dbg_lfd = -1; /* the listening socket */
static int dbg_errp = -1, dbg_err0 = -1; /* socket transports: our stderr, read back; the real one */

static void cl_close(int i) {
  if (dbg_cl[i].rfd >= 0) close(dbg_cl[i].rfd);
  if (dbg_cl[i].wfd >= 0 && dbg_cl[i].wfd != dbg_cl[i].rfd) close(dbg_cl[i].wfd);
  free(dbg_cl[i].in);
  dbg_cl[i] = dbg_cl[--dbg_ncl];
}

static bool write_all(int fd, const void *p, size_t n) {
  const char *s = p;
  while (n) {
    ssize_t w = write(fd, s, n);
    if (w < 0 && (errno == EINTR || errno == EAGAIN)) {
      struct pollfd q = {fd, POLLOUT, 0};
      poll(&q, 1, 100);
      continue;
    }
    if (w <= 0) return false;
    s += w;
    n -= (size_t)w;
  }
  return true;
}

/* one message (a JSON line) to client i */
static bool cl_send(int i, const char *p, size_t n) {
  Client *c = &dbg_cl[i];
  if (c->kind == CL_LINES) return write_all(c->wfd, p, n) && write_all(c->wfd, "\n", 1);
  if (c->kind != CL_WS) return true;
  uint8_t h[10];
  size_t hl = 2;
  h[0] = 0x81; /* FIN, text */
  if (n < 126) h[1] = (uint8_t)n;
  else if (n < 65536) { h[1] = 126; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hl = 4; }
  else { h[1] = 127; for (int k = 0; k < 8; k++) h[2 + k] = (uint8_t)((uint64_t)n >> (56 - 8 * k)); hl = 10; }
  return write_all(c->wfd, h, hl) && write_all(c->wfd, p, n);
}

/* the events gathered so far, to every client */
static void flush_events(void) {
  if (!dbg_out.n) return;
  for (int i = 0; i < dbg_ncl; i++) {
    if (dbg_cl[i].kind == CL_NEW) continue;
    const char *p = dbg_out.p, *end = dbg_out.p + dbg_out.n;
    while (p < end) {
      const char *nl = memchr(p, '\n', (size_t)(end - p));
      if (!nl) nl = end;
      if (!cl_send(i, p, (size_t)(nl - p))) { cl_close(i); i--; break; }
      p = nl + 1;
    }
  }
  dbg_out.n = 0;
  dbg_out.p[0] = 0;
}

static JW dbg_resp;

static void handle_line(int i, const char *line, size_t n) {
  while (n && (line[n - 1] == '\r' || line[n - 1] == ' ')) n--;
  if (!n) return;
  dbg_request(line, n, &dbg_resp);
  if (!cl_send(i, dbg_resp.p, dbg_resp.n)) return;
  flush_events();
}

/* ------------------------------------------------------------ WebSocket and HTTP */

static void dsha1(const uint8_t *m, size_t n, uint8_t out[20]) {
  uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
  size_t total = ((n + 8) / 64 + 1) * 64;
  uint8_t *b = calloc(1, total);
  memcpy(b, m, n);
  b[n] = 0x80;
  uint64_t bits = (uint64_t)n * 8;
  for (int i = 0; i < 8; i++) b[total - 1 - i] = (uint8_t)(bits >> (8 * i));
  for (size_t o = 0; o < total; o += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)b[o + 4 * i] << 24 | (uint32_t)b[o + 4 * i + 1] << 16 | (uint32_t)b[o + 4 * i + 2] << 8 | b[o + 4 * i + 3];
    for (int i = 16; i < 80; i++) { uint32_t x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = x << 1 | x >> 31; }
    uint32_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; i++) {
      uint32_t f, k;
      if (i < 20) { f = (bb & c) | (~bb & d); k = 0x5A827999; }
      else if (i < 40) { f = bb ^ c ^ d; k = 0x6ED9EBA1; }
      else if (i < 60) { f = (bb & c) | (bb & d) | (c & d); k = 0x8F1BBCDC; }
      else { f = bb ^ c ^ d; k = 0xCA62C1D6; }
      uint32_t t = (a << 5 | a >> 27) + f + e + k + w[i];
      e = d; d = c; c = bb << 30 | bb >> 2; bb = a; a = t;
    }
    h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e;
  }
  free(b);
  for (int i = 0; i < 20; i++) out[i] = (uint8_t)(h[i / 4] >> (24 - 8 * (i % 4)));
}
static void db64(const uint8_t *in, size_t n, char *out) {
  static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    uint32_t v = (uint32_t)in[i] << 16 | (i + 1 < n ? (uint32_t)in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
    out[o++] = t[v >> 18 & 63];
    out[o++] = t[v >> 12 & 63];
    out[o++] = i + 1 < n ? t[v >> 6 & 63] : '=';
    out[o++] = i + 2 < n ? t[v & 63] : '=';
  }
  out[o] = 0;
}

static const char *mime(const char *path) {
  const char *e = strrchr(path, '.');
  if (!e) return "application/octet-stream";
  if (!strcmp(e, ".html")) return "text/html; charset=utf-8";
  if (!strcmp(e, ".js")) return "text/javascript; charset=utf-8";
  if (!strcmp(e, ".css")) return "text/css; charset=utf-8";
  if (!strcmp(e, ".svg")) return "image/svg+xml";
  if (!strcmp(e, ".png")) return "image/png";
  if (!strcmp(e, ".json")) return "application/json";
  if (!strcmp(e, ".wasm")) return "application/wasm";
  return "text/plain; charset=utf-8";
}

/* An HTTP request from a browser: a WebSocket upgrade, or a file. Returns
 * false when the connection is done with. */
static bool http_request(int i) {
  Client *c = &dbg_cl[i];
  c->in[c->inl] = 0;
  char *req = c->in;
  char *key = strcasestr(req, "sec-websocket-key:");
  if (key && strcasestr(req, "upgrade: websocket")) {
    key += 18;
    while (*key == ' ') key++;
    char k[160];
    size_t n = 0;
    while (key[n] && key[n] != '\r' && key[n] != '\n' && n < 100) { k[n] = key[n]; n++; }
    k[n] = 0;
    strcat(k, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    uint8_t dig[20];
    char acc[64], resp[256];
    dsha1((uint8_t *)k, strlen(k), dig);
    db64(dig, 20, acc);
    snprintf(resp, sizeof resp,
             "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", acc);
    char *end = strstr(req, "\r\n\r\n");
    size_t used = end ? (size_t)(end + 4 - req) : c->inl;
    memmove(c->in, c->in + used, c->inl - used);
    c->inl -= used;
    c->kind = CL_WS;
    return write_all(c->wfd, resp, strlen(resp));
  }
  /* GET path */
  char path[1024] = "/";
  sscanf(req, "GET %1023s", path);
  char *q = strchr(path, '?');
  if (q) *q = 0;
  const char *body = NULL;
  char hdr[512];
  if (!strcmp(path, "/dbg-info")) {
    char info[128];
    snprintf(info, sizeof info, "{\"engine\":true,\"version\":%d}", DBG_PROTO_VERSION);
    snprintf(hdr, sizeof hdr, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", strlen(info));
    write_all(c->wfd, hdr, strlen(hdr));
    write_all(c->wfd, info, strlen(info));
    return false;
  }
  if (!strcmp(path, "/")) {
    body = "HTTP/1.1 302 Found\r\nLocation: /debug/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    write_all(c->wfd, body, strlen(body));
    return false;
  }
  char file[2048];
  size_t pl = strlen(path);
  snprintf(file, sizeof file, "%s%s%s", dbg_www ? dbg_www : "site", path, pl && path[pl - 1] == '/' ? "index.html" : "");
  struct stat sb;
  FILE *f = strstr(path, "..") ? NULL : fopen(file, "rb");
  if (f && !fstat(fileno(f), &sb) && S_ISDIR(sb.st_mode)) {
    fclose(f);
    snprintf(hdr, sizeof hdr, "HTTP/1.1 301 Moved\r\nLocation: %s/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", path);
    write_all(c->wfd, hdr, strlen(hdr));
    return false;
  }
  if (!f) {
    body = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\nConnection: close\r\n\r\nnot found\n";
    write_all(c->wfd, body, strlen(body));
    return false;
  }
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  snprintf(hdr, sizeof hdr, "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %ld\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n", mime(file), sz);
  write_all(c->wfd, hdr, strlen(hdr));
  char buf[65536];
  size_t r;
  while ((r = fread(buf, 1, sizeof buf, f)) > 0) write_all(c->wfd, buf, r);
  fclose(f);
  return false;
}

/* WebSocket frames from client i: one request per text message */
static bool ws_frames(int i) {
  for (;;) {
    Client *c = &dbg_cl[i];
    uint8_t *b = (uint8_t *)c->in;
    if (c->inl < 2) return true;
    unsigned op = b[0] & 15, masked = b[1] >> 7;
    uint64_t len = b[1] & 127;
    size_t o = 2;
    if (len == 126) { if (c->inl < 4) return true; len = (uint64_t)b[2] << 8 | b[3]; o = 4; }
    else if (len == 127) { if (c->inl < 10) return true; len = 0; for (int k = 0; k < 8; k++) len = len << 8 | b[2 + k]; o = 10; }
    uint8_t mk[4] = {0, 0, 0, 0};
    if (masked) { if (c->inl < o + 4) return true; memcpy(mk, b + o, 4); o += 4; }
    if (c->inl < o + len) return true;
    for (uint64_t k = 0; k < len; k++) b[o + k] ^= mk[k & 3];
    if (op == 8) return false; /* close */
    if (op == 9) { uint8_t pong[2] = {0x8a, 0}; write_all(c->wfd, pong, 2); }
    else if (op == 1 || op == 0) handle_line(i, (char *)b + o, (size_t)len);
    c = &dbg_cl[i];
    memmove(c->in, c->in + o + len, c->inl - o - (size_t)len);
    c->inl -= o + (size_t)len;
  }
}

/* What client i has sent: requests, a handshake, or nothing yet. */
static bool cl_input(int i) {
  Client *c = &dbg_cl[i];
  if (c->incap - c->inl < 65536) {
    c->incap = c->incap * 2 + 131072;
    c->in = realloc(c->in, c->incap + 1);
  }
  ssize_t r = read(c->rfd, c->in + c->inl, c->incap - c->inl);
  if (r <= 0) return false;
  c->inl += (size_t)r;
  if (c->kind == CL_NEW) {
    if (c->inl < 4) return true;
    if (memcmp(c->in, "GET ", 4)) c->kind = CL_LINES;
    else {
      c->in[c->inl] = 0;
      if (!strstr(c->in, "\r\n\r\n")) return true;
      if (!http_request(i)) return false;
      c = &dbg_cl[i];
    }
  }
  if (c->kind == CL_WS) return ws_frames(i);
  /* lines */
  size_t start = 0;
  for (size_t k = 0; k < c->inl; k++)
    if (c->in[k] == '\n') {
      handle_line(i, c->in + start, k - start);
      c = &dbg_cl[i];
      start = k + 1;
    }
  memmove(c->in, c->in + start, c->inl - start);
  c->inl -= start;
  return true;
}

static void cl_add(int rfd, int wfd, int kind) {
  if (dbg_ncl == DBG_MAXCL) { close(rfd); return; }
  dbg_cl[dbg_ncl++] = (Client){rfd, wfd, kind, NULL, 0, 0};
}

static bool dbg_listen(const char *where) {
  if (!strcmp(where, "stdio")) {
    int out = dup(STDOUT_FILENO);
    dup2(STDERR_FILENO, STDOUT_FILENO); /* nothing else may write into the protocol */
    cl_add(STDIN_FILENO, out, CL_LINES);
    return true;
  }
  if (!strncmp(where, "unix:", 5)) {
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "%s", where + 5);
    unlink(a.sun_path);
    dbg_lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (dbg_lfd < 0 || bind(dbg_lfd, (struct sockaddr *)&a, sizeof a) || listen(dbg_lfd, 4)) {
      fprintf(stderr, "strata-emu: cannot listen on %s: %s\n", where, strerror(errno));
      return false;
    }
    fprintf(stderr, "strata-emu: debug engine on %s\n", where);
    return true;
  }
  char host[256] = "127.0.0.1";
  unsigned port = 0;
  const char *colon = strrchr(where, ':');
  if (!strncmp(where, "tcp:", 4)) where += 4;
  colon = strrchr(where, ':');
  if (colon) { snprintf(host, sizeof host, "%.*s", (int)(colon - where), where); port = (unsigned)atoi(colon + 1); }
  else port = (unsigned)atoi(where);
  if (!port) { fprintf(stderr, "strata-emu: --debug PORT, HOST:PORT, unix:PATH or stdio\n"); return false; }
  int one = 1;
  dbg_lfd = socket(AF_INET, SOCK_STREAM, 0);
  setsockopt(dbg_lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1 || bind(dbg_lfd, (struct sockaddr *)&a, sizeof a) || listen(dbg_lfd, 4)) {
    fprintf(stderr, "strata-emu: cannot listen on %s:%u: %s\n", host, port, strerror(errno));
    return false;
  }
  fprintf(stderr, "strata-emu: debug engine on %s:%u (JSON lines; the web debugger: http://%s:%u/debug/)\n", host, port, host, port);
  return true;
}

/* The emulator's own messages (a halt, a fault, a deadlock: written to
 * stderr) go to its terminal as before, and to the socket clients as
 * {"ev":"emu","text":...} events. */
static void err_capture(void) {
  int p[2];
  if (pipe(p)) return;
  fflush(stderr);
  dbg_err0 = dup(STDERR_FILENO);
  dup2(p[1], STDERR_FILENO);
  close(p[1]);
  dbg_errp = p[0];
  setvbuf(stderr, NULL, _IONBF, 0);
}
static void err_forward(void) {
  static char eb[4096];
  static size_t el;
  for (;;) {
    struct pollfd q = {dbg_errp, POLLIN, 0};
    if (dbg_errp < 0 || poll(&q, 1, 0) <= 0) return;
    ssize_t r = read(dbg_errp, eb + el, sizeof eb - 1 - el);
    if (r <= 0) return;
    if (dbg_err0 >= 0) write_all(dbg_err0, eb + el, (size_t)r);
    el += (size_t)r;
    char *nl;
    while ((nl = memchr(eb, '\n', el)) || el == sizeof eb - 1) {
      size_t n = nl ? (size_t)(nl - eb) : el;
      JW w = {0};
      jw_reset(&w);
      jw_obj(&w, NULL);
      jw_str(&w, "ev", "emu");
      jw_strn(&w, "text", eb, n);
      jw_oend(&w);
      out_line(&w);
      free(w.p);
      size_t k = nl ? n + 1 : n;
      memmove(eb, eb + k, el - k);
      el -= k;
    }
  }
}

/* The engine's loop, instead of main's: requests in, the machine run while
 * it is running, events out. Ends at `quit` or when a stdio client leaves. */
static int dbg_main(bool hold) {
  dbg_hold = hold;
  signal(SIGPIPE, SIG_IGN);
  if (!dbg_listen(dbg_where)) return 2;
  bool stdio = !strcmp(dbg_where, "stdio");
  if (!stdio) err_capture();
  double wait = -1;
  while (!dbg_quit) {
    struct pollfd p[DBG_MAXCL + 1];
    int np = 0;
    if (dbg_lfd >= 0) p[np++] = (struct pollfd){dbg_lfd, POLLIN, 0};
    int base = np;
    for (int i = 0; i < dbg_ncl; i++) p[np++] = (struct pollfd){dbg_cl[i].rfd, POLLIN, 0};
    int timeout = dbg_state == ST_RUNNING ? (wait > 0 ? (int)(wait + 0.999) : 0) : 200;
    poll(p, (nfds_t)np, timeout);
    if (dbg_lfd >= 0 && (p[0].revents & POLLIN)) {
      int fd = accept(dbg_lfd, NULL, NULL);
      if (fd >= 0) cl_add(fd, fd, CL_NEW);
    }
    for (int i = dbg_ncl - 1; i >= 0; i--) {
      if (base + i >= np || !(p[base + i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      if (!cl_input(i)) {
        cl_close(i);
        if (stdio) dbg_quit = true;
      }
    }
    if (dbg_state == ST_RUNNING) {
      host_poll_input();
      wait = dbg_run(20);
      if (host_quit) dbg_quit = true;
    } else host_pump();
    if (host_quit) dbg_quit = true; /* the window was closed (or SIGINT / SIGTERM through SDL) */
    con_flush();
    err_forward();
    flush_events();
  }
  fflush(stdout);
  err_forward();
  if (dbg_err0 >= 0) dup2(dbg_err0, STDERR_FILENO);
  if (dbg_lfd >= 0) close(dbg_lfd);
  if (dbg_hold && dbg_state == ST_DONE) host_hold();
  if (trace) fclose(trace);
  return faulted ? 1 : 0;
}
