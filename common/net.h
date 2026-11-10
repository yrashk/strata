/* Strata prototype: the host side of the network interface (DEV_NET, see
 * platform.h), shared by the emulator (emu/emu.c) and the RTL harness
 * (sim/main.cpp) so both machines behave identically. Header-only; include
 * it from exactly one translation unit.
 *
 * The device sends and receives raw IPv4 packets: no link-layer framing, no
 * addresses below IP. What is on the other end of the "cable" is chosen with
 * the simulators' -N option:
 *   -N none   (the default) no link: transmitted packets are dropped and
 *             nothing ever arrives; STATUS says the link is down.
 *   -N loop   a loopback plug: every transmitted packet is queued for
 *             receive on the same machine at once. Deterministic, so runs
 *             that compare machines (conformance, -T virtual) can use it.
 *   -N peer   a built-in test peer on the other end, at every address but
 *             the sender's own and 192.0.2.0/24 (TEST-NET-1: nothing there
 *             answers, so tests have an address that times out): it answers
 *             ICMP echo requests (ping), echoes UDP datagrams sent to port
 *             7 and answers DNS queries (UDP port 53) for the names of its
 *             table: peer.test = 10.0.0.2, two.test = 10.0.0.2 and 10.0.0.3,
 *             www.peer.test = a CNAME for peer.test, other *.test: no such
 *             name. Other names are looked up for real through the NAT's UDP
 *             (common/netnat.h), unless `-N peer,nodns`: then they do not
 *             exist either, and the peer is fully deterministic. TCP needs a
 *             second machine (or -N nat).
 *   -N nat[,fwd=HOSTPORT:GUESTPORT]...
 *             the real network through a user-mode NAT (common/netnat.h):
 *             the guest is 10.0.2.15, the gateway (the host) 10.0.2.2, DNS
 *             10.0.2.3; UDP, TCP and ICMP echo go out through host sockets
 *             (no privileges). Each fwd= listens on 127.0.0.1:HOSTPORT and
 *             passes connections to the guest's GUESTPORT; a port that is
 *             busy is reported and skipped. STATUS bit 25 tells the guest.
 *   -N udp:LPORT:HOST:RPORT
 *             a cable to another simulator over host UDP: each packet is one
 *             datagram, sent from local port LPORT to HOST:RPORT; datagrams
 *             from that peer (and only from it) arrive as packets. Two
 *             instances with mirrored ports are two machines on one link:
 *               strata-emu -N udp:9001:127.0.0.1:9002 ...
 *               strata-emu -N udp:9002:127.0.0.1:9001 ...
 *             Needs no privileges; nothing here ever blocks (the socket is
 *             polled by net_host_poll).
 *
 * Transmit: the device hands each byte of a transfer that starts at the TX
 * port to net_tx_put(i, b) and calls net_tx_done(n) after the last one; the
 * packet is sent if 1 <= n <= NET_MTU, otherwise dropped (counted).
 * Receive: a bounded queue (NET_QLEN packets); a packet that finds it full is
 * dropped and counted. The device takes the head packet for a waiting RX
 * read (net_rx_head / net_rx_pop). */
#ifndef STRATA_NET_H
#define STRATA_NET_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "platform.h"

#ifndef __EMSCRIPTEN__
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include "netnat.h"                             /* (the browser uses its virtual connections) */

enum { NET_NONE, NET_LOOP, NET_UDP, NET_PEER, NET_NAT, NET_WEB };
static int net_mode = NET_NONE;
static bool net_nodns;                          /* -N peer,nodns: the peer's names only */
static unsigned net_hint;                       /* STATUS bits 31..26: a host number the link suggests (0: none) */
static inline void net_rx_push(const uint8_t *p, unsigned n);
static inline int net_room(void);

#ifdef __EMSCRIPTEN__
/* The browser (web/web.c, site/play/net.js): the page is the other end.
 *   -N web      every packet goes to the page (Module.webNetTx), which passes
 *               it to another tab (BroadcastChannel) or a relay (WebSocket);
 *               what comes back arrives through web_net_rx
 *   -N web,nat  the same, and STATUS says the far end is a user-mode NAT (a
 *               relay: tools/netrelay.c)
 *   -N peer     the built-in peer, its names for *.test, and every other DNS
 *               query answered by the page over HTTPS (Module.webDns; the
 *               answer comes back through web_net_dns) */
#include <emscripten.h>
static bool net_web_nat;
typedef struct { bool on; uint16_t id, gport; uint32_t gip, srv; } NetWebQ;
static NetWebQ net_webq[8];
static int net_webq_next;
static uint32_t net_ip4(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
/* A DNS query (the UDP datagram u of a packet p) for the page to answer. */
static void net_web_dns_ask(const uint8_t *p, const uint8_t *u, unsigned ul) {
  NetWebQ *q = &net_webq[net_webq_next];
  net_webq_next = (net_webq_next + 1) % 8;
  *q = (NetWebQ){true, (uint16_t)(u[8] << 8 | u[9]), (uint16_t)(u[0] << 8 | u[1]), net_ip4(p + 12), net_ip4(p + 16)};
  EM_ASM({ if (Module.webDns) Module.webDns($0, $1); }, u + 8, ul - 8);
}
/* The page's answer m (n bytes, a DNS message) to one of those: a UDP
 * datagram from the resolver that was asked to the guest that asked. */
/* The guest's address as the browser's page should reach it (its web server):
 * the last source address it used, or what the link has it take. */
static uint32_t net_web_seen;
static uint32_t net_web_guest(void) {
  if (net_web_seen) return net_web_seen;
  if (net_mode == NET_WEB && net_web_nat) return NAT_GUEST;
  return 0x0a000000u | (net_hint ? net_hint : 1);
}
static void net_web_dns_reply(const uint8_t *m, unsigned n) {
  static uint8_t r[NET_MTU];
  if (n < 12 || n > NET_MTU - 28) return;
  uint16_t id = (uint16_t)(m[0] << 8 | m[1]);
  for (int i = 0; i < 8; i++) {
    NetWebQ *q = &net_webq[i];
    if (!q->on || q->id != id) continue;
    q->on = false;
    uint8_t *u = r + 20;
    u[0] = 0; u[1] = 53; u[2] = (uint8_t)(q->gport >> 8); u[3] = (uint8_t)q->gport;
    u[4] = (uint8_t)((n + 8) >> 8); u[5] = (uint8_t)(n + 8); u[6] = u[7] = 0;
    memcpy(u + 8, m, n);
    unsigned t = 28 + n;
    r[0] = 0x45; r[1] = 0; r[2] = (uint8_t)(t >> 8); r[3] = (uint8_t)t; r[4] = r[5] = 0; r[6] = 0x40; r[7] = 0;
    r[8] = 64; r[9] = 17; r[10] = r[11] = 0;
    for (int k = 0; k < 4; k++) { r[12 + k] = (uint8_t)(q->srv >> (24 - 8 * k)); r[16 + k] = (uint8_t)(q->gip >> (24 - 8 * k)); }
    uint32_t sum = 0;
    for (int k = 0; k < 20; k += 2) sum += (uint32_t)r[k] << 8 | r[k + 1];
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    r[10] = (uint8_t)(~sum >> 8); r[11] = (uint8_t)~sum;
    net_rx_push(r, t);
    return;
  }
}
#endif
static int net_fd = -1;                         /* the UDP socket (NET_UDP) */
static uint8_t net_q[NET_QLEN][NET_MTU];        /* received packets */
static unsigned net_qlen[NET_QLEN];
static int net_qhead, net_qcnt;
static uint32_t net_drops;                      /* packets lost: queue full, or too long to send */
static uint8_t net_txb[NET_MTU];                /* the packet being transmitted */
static uint64_t net_txn;                        /* its bytes so far */

/* Parses -N MODE and opens what it needs; false (with a message) if it cannot. */
static inline bool net_host_open(const char *mode) {
  if (!strcmp(mode, "none")) { net_mode = NET_NONE; return true; }
  if (!strcmp(mode, "loop")) { net_mode = NET_LOOP; return true; }
#ifdef __EMSCRIPTEN__
  if (!strcmp(mode, "web") || !strcmp(mode, "web,nat")) { net_mode = NET_WEB; net_web_nat = mode[3] != 0; return true; }
#endif
  if (!strcmp(mode, "peer") || !strcmp(mode, "peer,nodns")) {
    net_mode = NET_PEER;
    net_nodns = mode[4] != 0;
#ifndef __EMSCRIPTEN__
    nat_init(net_rx_push, net_room);                   /* (names it does not know: the NAT's UDP) */
#endif
    return true;
  }
#ifndef __EMSCRIPTEN__
  if (!strncmp(mode, "nat", 3) && (mode[3] == 0 || mode[3] == ',')) {
    net_mode = NET_NAT;
    nat_init(net_rx_push, net_room);
    for (const char *o = strchr(mode, ','); o; o = strchr(o + 1, ',')) {
      unsigned hp, gp;
      if (sscanf(o, ",fwd=%u:%u", &hp, &gp) == 2 && hp && hp < 65536 && gp && gp < 65536) nat_forward(hp, gp);
      else { fprintf(stderr, "bad -N nat option %s (fwd=HOSTPORT:GUESTPORT)\n", o); return false; }
    }
    return true;
  }
#endif
#ifndef __EMSCRIPTEN__
  if (!strncmp(mode, "udp:", 4)) {
    char host[256];
    unsigned lport, rport;
    if (sscanf(mode + 4, "%u:%255[^:]:%u", &lport, host, &rport) != 3 || !lport || lport > 65535 || !rport ||
        rport > 65535) {
      fprintf(stderr, "bad -N udp:LPORT:HOST:RPORT\n");
      return false;
    }
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    char rp[16];
    snprintf(rp, sizeof rp, "%u", rport);
    if (getaddrinfo(host, rp, &hints, &res) || !res) { fprintf(stderr, "-N udp: cannot resolve %s\n", host); return false; }
    net_fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me;
    memset(&me, 0, sizeof me);
    me.sin_family = AF_INET;
    me.sin_port = htons((uint16_t)lport);
    me.sin_addr.s_addr = htonl(INADDR_ANY);
    int one = 1;
    if (net_fd >= 0) setsockopt(net_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (net_fd < 0 || bind(net_fd, (struct sockaddr *)&me, sizeof me) ||
        connect(net_fd, res->ai_addr, res->ai_addrlen)) { /* connected: only the peer's datagrams arrive */
      perror("-N udp");
      freeaddrinfo(res);
      return false;
    }
    freeaddrinfo(res);
    fcntl(net_fd, F_SETFL, fcntl(net_fd, F_GETFL) | O_NONBLOCK);
    net_mode = NET_UDP;
    return true;
  }
#endif
  fprintf(stderr, "bad -N (none, loop, peer[,nodns], nat[,fwd=H:G...] or udp:LPORT:HOST:RPORT)\n");
  return false;
}

/* A packet arrived on the link: into the receive queue, or dropped. */
static inline int net_room(void) { return NET_QLEN - net_qcnt; }
static inline void net_rx_push(const uint8_t *p, unsigned n) {
  if (net_qcnt == NET_QLEN) { net_drops++; return; }
  int i = (net_qhead + net_qcnt) % NET_QLEN;
  memcpy(net_q[i], p, n);
  net_qlen[i] = n;
  net_qcnt++;
}

/* The Internet checksum (ones' complement sum, folded) of n bytes, plus s. */
static inline uint16_t net_csum(const uint8_t *p, unsigned n, uint32_t s) {
  for (unsigned i = 0; i + 1 < n; i += 2) s += (uint32_t)p[i] << 8 | p[i + 1];
  if (n & 1) s += (uint32_t)p[n - 1] << 8;
  while (s >> 16) s = (s & 0xffff) + (s >> 16);
  return (uint16_t)s;
}

/* The peer's names (-N peer): the DNS answer (r, returned length) to the query
 * q of n bytes, or 0 if the name is not one of the peer's (and forwarding is
 * on: it is looked up for real). */
static inline unsigned net_dns_local(const uint8_t *q, unsigned n, uint8_t *r) {
  char name[128];
  unsigned o = 12, k = 0;
  if (n < 17) return 0;
  while (o < n && q[o]) {                              /* the question's name */
    unsigned l = q[o++];
    if (l > 63 || o + l > n || k + l + 1 >= sizeof name) return 0;
    if (k) name[k++] = '.';
    for (unsigned i = 0; i < l; i++) { char ch = (char)q[o++]; name[k++] = ch >= 'A' && ch <= 'Z' ? ch + 32 : ch; }
  }
  name[k] = 0;
  if (o + 5 > n) return 0;
  unsigned qend = o + 5, qtype = (unsigned)q[o + 1] << 8 | q[o + 2];
  bool test = k >= 5 && !strcmp(name + k - 5, ".test");
  if (!test && !net_nodns) return 0;
  static const struct { const char *name, *cname; uint32_t a[2]; } tab[] = {
    {"peer.test", NULL, {0x0a000002u, 0}},
    {"two.test", NULL, {0x0a000002u, 0x0a000003u}},
    {"www.peer.test", "peer.test", {0x0a000002u, 0}},
  };
  int e = -1;
  for (unsigned i = 0; i < sizeof tab / sizeof tab[0]; i++) if (!strcmp(name, tab[i].name)) e = (int)i;
  memcpy(r, q, qend);
  r[2] = (uint8_t)(0x80 | (q[2] & 1));                 /* a response; RD as asked */
  r[3] = (uint8_t)(0x80 | (e < 0 ? 3 : 0));            /* RA; NXDOMAIN if unknown */
  r[4] = 0; r[5] = 1; r[6] = r[7] = r[8] = r[9] = r[10] = r[11] = 0;
  if (e < 0 || (qtype != 1 && qtype != 255)) return qend;
  unsigned w = qend, an = 0, owner = 12;               /* answers: names by pointer */
  if (tab[e].cname) {
    r[w] = 0xc0; r[w + 1] = 12;
    r[w + 2] = 0; r[w + 3] = 5; r[w + 4] = 0; r[w + 5] = 1;
    r[w + 6] = 0; r[w + 7] = 0; r[w + 8] = 1; r[w + 9] = 44; /* TTL 300 */
    unsigned rd = w + 12, x = rd;
    for (const char *c = tab[e].cname; *c;) {
      const char *dot = strchr(c, '.');
      unsigned l = dot ? (unsigned)(dot - c) : (unsigned)strlen(c);
      r[x++] = (uint8_t)l;
      memcpy(r + x, c, l);
      x += l;
      c += l + (dot ? 1 : 0);
    }
    r[x++] = 0;
    r[w + 10] = 0; r[w + 11] = (uint8_t)(x - rd);
    owner = rd;
    w = x;
    an++;
  }
  for (int i = 0; i < 2 && tab[e].a[i]; i++) {
    r[w] = (uint8_t)(0xc0 | owner >> 8); r[w + 1] = (uint8_t)owner;
    r[w + 2] = 0; r[w + 3] = 1; r[w + 4] = 0; r[w + 5] = 1;
    r[w + 6] = 0; r[w + 7] = 0; r[w + 8] = 1; r[w + 9] = 44;
    r[w + 10] = 0; r[w + 11] = 4;
    uint32_t a = tab[e].a[i];
    r[w + 12] = (uint8_t)(a >> 24); r[w + 13] = (uint8_t)(a >> 16); r[w + 14] = (uint8_t)(a >> 8); r[w + 15] = (uint8_t)a;
    w += 16;
    an++;
  }
  r[7] = (uint8_t)an;
  return w;
}

/* The built-in peer (-N peer) sees a packet: an ICMP echo request comes back
 * as a reply, a UDP datagram to port 7 comes back to its sender, a DNS query
 * is answered (or forwarded). */
static inline void net_peer(const uint8_t *p, unsigned n) {
  static uint8_t r[NET_MTU];
  if (n < 20 || (p[0] >> 4) != 4) return;
  unsigned hl = (p[0] & 15) * 4u, tl = (unsigned)p[2] << 8 | p[3];
  if (hl < 20 || tl > n || tl < hl + 8 || !memcmp(p + 12, p + 16, 4)) return;
  if (p[16] == 192 && p[17] == 0 && p[18] == 2) return; /* TEST-NET-1: nobody is there */
  if (p[9] == 17 && ((unsigned)p[hl + 2] << 8 | p[hl + 3]) == 53) { /* DNS */
    unsigned ul = (unsigned)p[hl + 4] << 8 | p[hl + 5];
    if (ul < 8 || hl + ul > tl) return;
    unsigned m = net_dns_local(p + hl + 8, ul - 8, r + hl + 8);
    if (!m) {
#ifndef __EMSCRIPTEN__
      nat_udp_in((uint32_t)p[12] << 24 | (uint32_t)p[13] << 16 | (uint32_t)p[14] << 8 | p[15],
                 (uint32_t)p[16] << 24 | (uint32_t)p[17] << 16 | (uint32_t)p[18] << 8 | p[19], p + hl, ul);
#else
      net_web_dns_ask(p, p + hl, ul);                  /* the page asks a DNS-over-HTTPS service */
#endif
      return;
    }
    memcpy(r, p, hl);                                  /* the answer, from the address asked */
    memcpy(r + 12, p + 16, 4);
    memcpy(r + 16, p + 12, 4);
    r[8] = 64;
    uint8_t *l = r + hl;
    l[0] = p[hl + 2]; l[1] = p[hl + 3]; l[2] = p[hl]; l[3] = p[hl + 1];
    l[4] = (uint8_t)((m + 8) >> 8); l[5] = (uint8_t)(m + 8); l[6] = l[7] = 0;
    unsigned t = hl + 8 + m;
    r[2] = (uint8_t)(t >> 8); r[3] = (uint8_t)t;
    r[10] = r[11] = 0;
    uint16_t c = (uint16_t)~net_csum(r, hl, 0);
    r[10] = (uint8_t)(c >> 8); r[11] = (uint8_t)c;
    net_rx_push(r, t);
    return;
  }
  memcpy(r, p, tl);
  memcpy(r + 12, p + 16, 4); /* from the address it was sent to */
  memcpy(r + 16, p + 12, 4);
  r[8] = 64;
  uint8_t *l = r + hl;
  unsigned ll = tl - hl;
  if (p[9] == 1 && l[0] == 8) {                       /* echo request -> echo reply */
    l[0] = 0;
    l[2] = l[3] = 0;
    uint16_t c = (uint16_t)~net_csum(l, ll, 0);
    l[2] = (uint8_t)(c >> 8);
    l[3] = (uint8_t)c;
  } else if (p[9] == 17 && ((unsigned)l[2] << 8 | l[3]) == 7) { /* UDP echo */
    uint8_t a = l[0], b = l[1];
    l[0] = l[2];
    l[1] = l[3];
    l[2] = a;
    l[3] = b;
    l[6] = l[7] = 0;                                  /* (no checksum) */
  } else return;
  r[10] = r[11] = 0;
  uint16_t c = (uint16_t)~net_csum(r, hl, 0);
  r[10] = (uint8_t)(c >> 8);
  r[11] = (uint8_t)c;
  net_rx_push(r, tl);
}

/* Byte i of the packet being transmitted. */
static inline void net_tx_put(uint64_t i, uint8_t b) {
  if (i < NET_MTU) net_txb[i] = b;
  net_txn = i + 1;
}

/* The transfer that carried the packet is complete: n bytes. */
static inline void net_tx_done(uint64_t n) {
  net_txn = 0;
  if (n == 0 || n > NET_MTU) { net_drops++; return; }
#ifdef __EMSCRIPTEN__
  if (n >= 20 && (net_txb[0] >> 4) == 4) net_web_seen = net_ip4(net_txb + 12);
  if (nat_vtake(net_txb, (unsigned)n)) return;           /* the page's own connections to the guest */
#endif
  if (net_mode == NET_LOOP) net_rx_push(net_txb, (unsigned)n);
  else if (net_mode == NET_PEER) net_peer(net_txb, (unsigned)n);
#ifndef __EMSCRIPTEN__
  else if (net_mode == NET_NAT) nat_input(net_txb, (unsigned)n);
#else
  else if (net_mode == NET_WEB) EM_ASM({ if (Module.webNetTx) Module.webNetTx($0, $1); }, net_txb, (unsigned)n);
#endif
#ifndef __EMSCRIPTEN__
  else if (net_mode == NET_UDP) (void)!send(net_fd, net_txb, (size_t)n, 0);
#endif
}

/* Now and then: datagrams that have arrived from the peer. */
static inline void net_host_poll(void) {
#ifndef __EMSCRIPTEN__
  if (net_mode == NET_NAT || (net_mode == NET_PEER && !net_nodns)) { nat_poll(); return; }
  if (net_mode != NET_UDP) return;
  uint8_t b[NET_MTU + 1];
  for (;;) {
    ssize_t n = recv(net_fd, b, sizeof b, 0);
    if (n < 0) return;                          /* nothing more (or the peer is not there yet) */
    if (n == 0 || n > (ssize_t)NET_MTU) { net_drops++; continue; }
    net_rx_push(b, (unsigned)n);
  }
#endif
}

/* Packets can still arrive from outside (an idle machine is not deadlocked). */
static inline bool net_live(void) {
#ifdef __EMSCRIPTEN__
  if (net_mode == NET_WEB || (net_mode == NET_PEER && !net_nodns)) return true; /* the page may bring one */
#endif
  return net_mode == NET_UDP || net_mode == NET_NAT || (net_mode == NET_PEER && !net_nodns);
}

static inline int net_rx_count(void) { return net_qcnt; }
static inline const uint8_t *net_rx_head(unsigned *n) { *n = net_qlen[net_qhead]; return net_q[net_qhead]; }
static inline void net_rx_pop(void) { net_qhead = (net_qhead + 1) % NET_QLEN; net_qcnt--; }

#ifdef __EMSCRIPTEN__
static inline bool net_web_isnat(void) { return net_mode == NET_WEB && net_web_nat; }
#else
static inline bool net_web_isnat(void) { return false; }
#endif
/* The STATUS register: next length | queued << 16 | link << 24 | NAT link
 * (the guest is 10.0.2.15) << 25 | a suggested host number << 26 | drops << 32. */
static inline uint64_t net_status(void) {
  uint64_t len = net_qcnt ? net_qlen[net_qhead] : 0;
  return len | (uint64_t)net_qcnt << 16 | (uint64_t)(net_mode != NET_NONE) << 24 | (uint64_t)(net_mode == NET_NAT || net_web_isnat()) << 25 |
         (uint64_t)(net_hint & 63) << 26 | (uint64_t)net_drops << 32;
}

#endif
