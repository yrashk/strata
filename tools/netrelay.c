/* netrelay: puts a browser's Strata machine (the play page, network mode
 * "relay") on the real network through the user-mode NAT of the simulators
 * (common/netnat.h: -N nat semantics: the guest is 10.0.2.15, the gateway
 * 10.0.2.2 = this host, DNS 10.0.2.3).
 *
 *   netrelay [-p PORT] [-a ADDRESS] [-f HOSTPORT:GUESTPORT]...
 *
 * A WebSocket server (RFC 6455, no extensions) on ADDRESS:PORT (default
 * 127.0.0.1:8765): one binary message is one raw IPv4 packet, both ways.
 * One page at a time (a new connection replaces the old one; the NAT's
 * state stays). -f forwards host connections to 127.0.0.1:HOSTPORT to the
 * guest's GUESTPORT, as -N nat,fwd= does. Everything that machine sends
 * leaves from this host: run it only for pages you trust. No dependencies:
 * `make build/netrelay` (part of `make all`). */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include "../common/netnat.h"

static int ws = -1; /* the page's connection, once it is a WebSocket */

/* ------------------------------------------------------------ SHA-1, base64 (the handshake) */
static void sha1(const uint8_t *m, size_t n, uint8_t out[20]) {
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
static void b64(const uint8_t *in, size_t n, char *out) {
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

/* ------------------------------------------------------------ frames */
static void ws_send(const uint8_t *p, unsigned n) {
  if (ws < 0) return;
  uint8_t h[4];
  unsigned hl = 2;
  h[0] = 0x82;                         /* FIN, binary */
  if (n < 126) h[1] = (uint8_t)n;
  else { h[1] = 126; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hl = 4; }
  uint8_t f[4 + NAT_MTU];
  memcpy(f, h, hl);
  memcpy(f + hl, p, n);
  size_t left = hl + n, o = 0;
  while (left) {                       /* (small: it fits in the socket's buffer; wait if not) */
    ssize_t w = send(ws, f + o, left, 0);
    if (w < 0 && (errno == EAGAIN || errno == EINTR)) { struct pollfd q = {ws, POLLOUT, 0}; poll(&q, 1, 100); continue; }
    if (w <= 0) { close(ws); ws = -1; return; }
    o += (size_t)w;
    left -= (size_t)w;
  }
}
static void out_fn(const uint8_t *p, unsigned n) { ws_send(p, n); }
static int room_fn(void) { return ws >= 0 ? 16 : 0; }

static uint8_t inb[1 << 17];
static size_t inl;

/* The bytes received so far: complete frames are handled, the rest kept. */
static void ws_frames(void) {
  for (;;) {
    if (inl < 2) return;
    unsigned op = inb[0] & 15, masked = inb[1] >> 7;
    uint64_t len = inb[1] & 127;
    size_t o = 2;
    if (len == 126) { if (inl < 4) return; len = (uint64_t)inb[2] << 8 | inb[3]; o = 4; }
    else if (len == 127) { if (inl < 10) return; len = 0; for (int i = 0; i < 8; i++) len = len << 8 | inb[2 + i]; o = 10; }
    uint8_t mk[4] = {0, 0, 0, 0};
    if (masked) { if (inl < o + 4) return; memcpy(mk, inb + o, 4); o += 4; }
    if (len > sizeof inb - o) { close(ws); ws = -1; inl = 0; return; }
    if (inl < o + len) return;
    uint8_t *d = inb + o;
    for (uint64_t i = 0; i < len; i++) d[i] ^= mk[i & 3];
    if (op == 2 || op == 0) nat_input(d, (unsigned)len);   /* a packet from the guest */
    else if (op == 8) { uint8_t c[2] = {0x88, 0}; (void)!send(ws, c, 2, 0); close(ws); ws = -1; inl = 0; return; } /* close: answered */
    else if (op == 9) {                                    /* ping -> pong */
      uint8_t f[2 + 125];
      if (len <= 125) { f[0] = 0x8a; f[1] = (uint8_t)len; memcpy(f + 2, d, len); (void)!send(ws, f, 2 + len, 0); }
    }
    memmove(inb, inb + o + len, inl - o - len);
    inl -= o + len;
  }
}

/* The HTTP upgrade request in inb: answer it; false if it is not one. */
static bool ws_handshake(int fd) {
  inb[inl] = 0;
  char *k = strcasestr((char *)inb, "sec-websocket-key:");
  if (!k) return false;
  k += 18;
  while (*k == ' ') k++;
  char key[128];
  size_t n = 0;
  while (k[n] && k[n] != '\r' && k[n] != '\n' && n < 100) { key[n] = k[n]; n++; }
  key[n] = 0;
  strcat(key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
  uint8_t dig[20];
  char acc[64], resp[256];
  sha1((uint8_t *)key, strlen(key), dig);
  b64(dig, 20, acc);
  snprintf(resp, sizeof resp,
           "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Accept: %s\r\n\r\n", acc);
  return send(fd, resp, strlen(resp), 0) == (ssize_t)strlen(resp);
}

int main(int argc, char **argv) {
  unsigned port = 8765;
  const char *addr = "127.0.0.1";
  signal(SIGPIPE, SIG_IGN);
  nat_init(out_fn, room_fn);
  for (int i = 1; i < argc; i++) {
    unsigned hp, gp;
    if (!strcmp(argv[i], "-p") && i + 1 < argc) port = (unsigned)atoi(argv[++i]);
    else if (!strcmp(argv[i], "-a") && i + 1 < argc) addr = argv[++i];
    else if (!strcmp(argv[i], "-f") && i + 1 < argc && sscanf(argv[++i], "%u:%u", &hp, &gp) == 2) nat_forward(hp, gp);
    else { fprintf(stderr, "usage: netrelay [-p PORT] [-a ADDRESS] [-f HOSTPORT:GUESTPORT]...\n"); return 2; }
  }
  int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, addr, &a.sin_addr) != 1 || bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 4)) {
    fprintf(stderr, "netrelay: cannot listen on %s:%u: %s\n", addr, port, strerror(errno));
    return 1;
  }
  fprintf(stderr, "netrelay: ws://%s:%u/ (the guest: 10.0.2.15, DNS 10.0.2.3); every packet the page's machine sends leaves from here\n", addr, port);
  int pend = -1; /* a connection still in its HTTP handshake */
  for (;;) {
    struct pollfd p[3] = {{ls, POLLIN, 0}, {pend, POLLIN, 0}, {ws, POLLIN, 0}};
    poll(p, 3, 10);                    /* (the NAT's sockets are polled below, at least every 10 ms) */
    if (p[0].revents & POLLIN) {
      int fd = accept(ls, NULL, NULL);
      if (fd >= 0) { if (pend >= 0) close(pend); pend = fd; inl = 0; }
    }
    if (pend >= 0 && (p[1].revents & (POLLIN | POLLHUP))) {
      ssize_t r = recv(pend, inb + inl, sizeof inb - 1 - inl, 0);
      if (r <= 0) { close(pend); pend = -1; }
      else {
        inl += (size_t)r;
        inb[inl] = 0;
        if (strstr((char *)inb, "\r\n\r\n")) {
          if (ws_handshake(pend)) {
            if (ws >= 0) close(ws);
            ws = pend;
            fprintf(stderr, "netrelay: a page connected\n");
          } else close(pend);
          pend = -1;
          inl = 0;
        }
      }
    }
    if (ws >= 0 && (p[2].revents & (POLLIN | POLLHUP))) {
      ssize_t r = recv(ws, inb + inl, sizeof inb - inl, 0);
      if (r <= 0) { close(ws); ws = -1; inl = 0; fprintf(stderr, "netrelay: the page left\n"); }
      else { inl += (size_t)r; ws_frames(); }
    }
    nat_poll();
  }
}
