/* Strata prototype: a user-mode NAT between a guest that speaks raw IPv4 and
 * the host's sockets, like QEMU's user networking but written from scratch
 * (no libslirp, no privileges, nothing blocks). Shared by the simulators'
 * network interface (common/net.h, -N nat) and the browser relay
 * (tools/netrelay.c). Header-only; include it from exactly one translation
 * unit.
 *
 * The guest's side of the link:
 *   10.0.2.15   the guest (any source address is accepted; replies go back to it)
 *   10.0.2.2    the gateway: the host itself (a connection to 10.0.2.2:P
 *               reaches 127.0.0.1:P; it answers pings itself)
 *   10.0.2.3    DNS: UDP to port 53 there goes to 8.8.8.8, or to 1.1.1.1 when
 *               8.8.8.8 did not answer the previous query in time
 *   anything else: the real Internet address
 *
 * UDP: one host socket per guest flow (guest address and port, destination
 *   address and port); replies come back as datagrams from that destination.
 *   A flow idle for NAT_UDP_IDLE seconds (DNS: 10) is closed.
 * TCP: terminated on the host. A guest SYN starts a non-blocking connect();
 *   the guest gets a SYN-ACK when it succeeds, a RST when it fails. Bytes are
 *   relayed both ways with our own sequence numbers: data from the host is
 *   kept until the guest acknowledges it and sent again on a timer (the
 *   device's queue holds 16 packets and may drop), within the guest's window
 *   and MSS; data from the guest is written to the socket as it comes, in
 *   order (what the socket does not take is not acknowledged, so the guest
 *   sends it again). FIN both ways (shutdown), RST both ways. NAT_TCP
 *   connections at most.
 * Inbound: nat_forward(hostport, guestport) listens on 127.0.0.1:hostport;
 *   each connection accepted there becomes a guest connection from
 *   10.0.2.2:<ephemeral> to the guest's guestport.
 * ICMP echo: through an unprivileged ICMP datagram socket (macOS allows it;
 *   Linux when net.ipv4.ping_group_range includes the user's group). Without
 *   one, echo requests to the Internet are dropped (pings to 10.0.2.2/.3 are
 *   answered by the NAT itself).
 *
 * Virtual connections: the embedder itself can be the host end of an inbound
 * connection (the browser's page showing the guest's web server: no host
 * socket at all). nat_vopen(guest, port) starts one (a SYN from
 * 10.0.2.2:<ephemeral>), nat_vsend / nat_vrecv / nat_vclose move its bytes,
 * nat_vtake(packet) takes the guest's packets that belong to one (call it
 * first for everything the guest sends), and nat_vprobe(guest, port) says
 * whether something listens there: a SYN whose SYN-ACK is answered with a
 * RST, so the guest's listener never sees a connection.
 *
 * Interface: nat_init(out, room) (out: deliver a packet to the guest; room:
 * how many it can take now), nat_input(packet, length) for every packet the
 * guest sends, nat_poll() now and then (it never blocks), nat_live() = it may
 * still produce packets. */
#ifndef STRATA_NETNAT_H
#define STRATA_NETNAT_H

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

#define NAT_MTU 1500
#define NAT_UDP 32            /* UDP flows */
#define NAT_TCP 16            /* TCP connections */
#define NAT_FWD 8             /* inbound forwards */
#define NAT_PING 16           /* echo requests in flight */
#define NAT_TXCAP 65536       /* bytes from the host kept per connection until the guest has them */
#define NAT_MSS 1024          /* segments toward the guest (its MSS caps it further) */
#define NAT_UDP_IDLE 60
#define NAT_GUEST 0x0a00020fu /* 10.0.2.15 */
#define NAT_GW 0x0a000202u    /* 10.0.2.2 */
#define NAT_DNS 0x0a000203u   /* 10.0.2.3 */

typedef void (*nat_out_fn)(const uint8_t *p, unsigned n);
typedef int (*nat_room_fn)(void);
static nat_out_fn nat_out;
static nat_room_fn nat_room;
static uint32_t nat_guest = NAT_GUEST; /* the guest's address, as last seen */
static uint16_t nat_ipid = 1;
static uint32_t nat_iss = 0x1000;

static inline uint64_t nat_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000u + (uint64_t)t.tv_nsec / 1000000u;
}
static inline uint16_t nat_be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static inline uint32_t nat_be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static inline void nat_put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static inline void nat_put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static inline uint32_t nat_sum(const uint8_t *p, unsigned n, uint32_t s) {
  for (unsigned i = 0; i + 1 < n; i += 2) s += (uint32_t)p[i] << 8 | p[i + 1];
  if (n & 1) s += (uint32_t)p[n - 1] << 8;
  return s;
}
static inline uint16_t nat_fold(uint32_t s) {
  while (s >> 16) s = (s & 0xffff) + (s >> 16);
  return (uint16_t)~s;
}
#ifdef MSG_NOSIGNAL
#define NAT_NOSIG MSG_NOSIGNAL
#else
#define NAT_NOSIG 0
#endif
/* Non-blocking, and no SIGPIPE when the far end has gone (macOS: per socket). */
static inline void nat_nonblock(int fd) {
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
#ifdef SO_NOSIGPIPE
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
}
static inline struct sockaddr_in nat_sa(uint32_t ip, uint16_t port) {
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(ip);
  return a;
}
/* The host address a guest destination stands for. */
static inline uint32_t nat_real(uint32_t ip) { return ip == NAT_GW ? 0x7f000001u : ip; }

/* Sends an IPv4 packet to the guest: header + payload (pl bytes at p + 20). */
static inline void nat_ip_out(uint8_t *p, uint8_t proto, uint32_t src, uint32_t dst, unsigned pl) {
  unsigned n = 20 + pl;
  p[0] = 0x45; p[1] = 0;
  nat_put16(p + 2, n);
  nat_put16(p + 4, nat_ipid++);
  nat_put16(p + 6, 0x4000);
  p[8] = 64; p[9] = proto;
  p[10] = p[11] = 0;
  nat_put32(p + 12, src);
  nat_put32(p + 16, dst);
  nat_put16(p + 10, nat_fold(nat_sum(p, 20, 0)));
  if (nat_out) nat_out(p, n);
}
static inline uint16_t nat_l4sum(uint8_t proto, uint32_t src, uint32_t dst, const uint8_t *p, unsigned n) {
  uint32_t s = (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff) + proto + n;
  return nat_fold(nat_sum(p, n, s));
}
/* A UDP datagram to the guest. */
static inline void nat_udp_out(uint32_t src, uint16_t sport, uint32_t dst, uint16_t dport, const uint8_t *d, unsigned n) {
  static uint8_t p[NAT_MTU];
  if (n > NAT_MTU - 28) return;
  uint8_t *u = p + 20;
  nat_put16(u, sport); nat_put16(u + 2, dport); nat_put16(u + 4, 8 + n); nat_put16(u + 6, 0);
  memcpy(u + 8, d, n);
  uint16_t c = nat_l4sum(17, src, dst, u, 8 + n);
  nat_put16(u + 6, c ? c : 0xffff);
  nat_ip_out(p, 17, src, dst, 8 + n);
}

/* ------------------------------------------------------------ UDP */
typedef struct {
  bool on;
  uint32_t gip, dip;   /* the guest, and the destination it names */
  uint16_t gport, dport;
  int fd;
  uint64_t last;       /* ms of the last activity */
  bool dns, waiting;   /* a flow to 10.0.2.3:53; a query not answered yet */
  uint64_t sent;       /* ms the last query went */
  int alt;             /* 0: 8.8.8.8, 1: 1.1.1.1 */
} NatUdp;
static NatUdp nat_udp[NAT_UDP];

static inline void nat_udp_in(uint32_t src, uint32_t dst, const uint8_t *u, unsigned n) {
  if (n < 8) return;
  unsigned ul = nat_be16(u + 4);
  if (ul < 8 || ul > n) return;
  uint16_t sport = nat_be16(u), dport = nat_be16(u + 2);
  NatUdp *f = NULL, *free_ = NULL;
  for (int i = 0; i < NAT_UDP; i++) {
    NatUdp *g = &nat_udp[i];
    if (!g->on) { if (!free_) free_ = g; continue; }
    if (g->gip == src && g->gport == sport && g->dip == dst && g->dport == dport) { f = g; break; }
  }
  uint64_t now = nat_ms();
  if (!f) {
    if (!free_) { /* full: the oldest goes */
      free_ = &nat_udp[0];
      for (int i = 1; i < NAT_UDP; i++) if (nat_udp[i].last < free_->last) free_ = &nat_udp[i];
      close(free_->fd);
    }
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    nat_nonblock(fd);
    f = free_;
    memset(f, 0, sizeof *f);
    *f = (NatUdp){true, src, dst, sport, dport, fd, now, dst == NAT_DNS && dport == 53, false, 0, 0};
  }
  uint32_t real = nat_real(dst);
  if (f->dns) {
    if (f->waiting && now - f->sent > 900) f->alt ^= 1; /* the last one went unanswered: the other */
    real = f->alt ? 0x01010101u : 0x08080808u;
    f->waiting = true;
    f->sent = now;
  }
  struct sockaddr_in a = nat_sa(real, f->dport);
  (void)!sendto(f->fd, u + 8, ul - 8, 0, (struct sockaddr *)&a, sizeof a);
  f->last = now;
}

static inline void nat_udp_poll(void) {
  uint8_t b[NAT_MTU];
  uint64_t now = nat_ms();
  for (int i = 0; i < NAT_UDP; i++) {
    NatUdp *f = &nat_udp[i];
    if (!f->on) continue;
    for (int k = 0; k < 8; k++) {
      if (nat_room && nat_room() < 2) break;
      struct sockaddr_in a;
      socklen_t al = sizeof a;
      ssize_t n = recvfrom(f->fd, b, sizeof b, 0, (struct sockaddr *)&a, &al);
      if (n < 0) break;
      f->last = now;
      f->waiting = false;
      nat_udp_out(f->dip, f->dport, f->gip, f->gport, b, (unsigned)n);
    }
    if (now - f->last > (uint64_t)(f->dns ? 10 : NAT_UDP_IDLE) * 1000) { close(f->fd); f->on = false; }
  }
}

/* ------------------------------------------------------------ TCP */
enum { NT_FREE, NT_CONNECTING, NT_SYNACK, NT_SYNSENT, NT_EST };
typedef struct {
  int st;
  uint32_t gip, dip;    /* the guest; the far end as the guest sees it */
  uint16_t gport, dport;
  int fd;
  uint32_t rcv;         /* next sequence number expected from the guest */
  uint32_t iss, una, nxt; /* ours toward the guest */
  uint32_t gwnd, gmss;
  uint8_t *buf;         /* bytes from the host from una on */
  unsigned len;
  bool heof, finsent, gfin, rst;
  uint64_t rto_at, rto;
  int tries;
  bool inbound;
  int vs;               /* a virtual connection: its slot + 1 (0: a host socket) */
  bool probe;           /* a listening probe: SYN-ACK -> RST */
} NatTcp;
#define NAT_VS 8
typedef struct {
  bool used, closed, eof_in;
  uint8_t *in;          /* bytes for the guest, not yet sent */
  size_t inlen, inoff;
  uint8_t *out;         /* bytes from the guest, not yet taken */
  size_t outlen, outcap;
} NatVs;
static NatVs nat_vs[NAT_VS];
typedef struct { uint16_t port; int state; uint64_t at; bool busy; } NatProbe; /* state: 1 listening, 0 not, -1 unknown */
static NatProbe nat_probes[4];
static NatTcp nat_tcp[NAT_TCP];
typedef struct { int fd; uint16_t hport, gport; } NatFwd;
static NatFwd nat_fwd[NAT_FWD];
static int nat_nfwd;
static uint16_t nat_eport = 40000;

/* The host end of a connection: a socket, or a virtual one's buffers. */
static inline ssize_t nat_s_send(NatTcp *c, const uint8_t *d, size_t n) {
  if (!c->vs) return send(c->fd, d, n, NAT_NOSIG);
  NatVs *v = &nat_vs[c->vs - 1];
  if (v->outlen + n > v->outcap) {
    size_t cap = v->outcap ? v->outcap * 2 : 65536;
    while (cap < v->outlen + n) cap *= 2;
    uint8_t *b = (uint8_t *)realloc(v->out, cap);
    if (!b) { errno = EAGAIN; return -1; }
    v->out = b;
    v->outcap = cap;
  }
  memcpy(v->out + v->outlen, d, n);
  v->outlen += n;
  return (ssize_t)n;
}
static inline ssize_t nat_s_recv(NatTcp *c, uint8_t *b, size_t n) {
  if (!c->vs) return recv(c->fd, b, n, 0);
  NatVs *v = &nat_vs[c->vs - 1];
  size_t k = v->inlen - v->inoff;
  if (!k) { if (v->eof_in) return 0; errno = EAGAIN; return -1; }
  if (k > n) k = n;
  memcpy(b, v->in + v->inoff, k);
  v->inoff += k;
  return (ssize_t)k;
}
static inline void nat_s_shut(NatTcp *c) { if (!c->vs) shutdown(c->fd, SHUT_WR); }

/* A TCP segment to the guest. */
static inline void nat_tcp_seg(NatTcp *c, uint8_t flags, uint32_t seq, const uint8_t *d, unsigned n) {
  static uint8_t p[NAT_MTU];
  uint8_t *t = p + 20;
  unsigned hl = (flags & 2) ? 24 : 20;
  nat_put16(t, c->dport); nat_put16(t + 2, c->gport);
  nat_put32(t + 4, seq);
  nat_put32(t + 8, (flags & 16) ? c->rcv : 0);
  t[12] = (uint8_t)(hl << 2); t[13] = flags;
  nat_put16(t + 14, 32768);  /* what the host socket will take is its business */
  nat_put16(t + 16, 0); nat_put16(t + 18, 0);
  if (hl == 24) { t[20] = 2; t[21] = 4; nat_put16(t + 22, NAT_MSS); }
  if (n) memcpy(t + hl, d, n);
  nat_put16(t + 16, nat_l4sum(6, c->dip, c->gip, t, hl + n));
  nat_ip_out(p, 6, c->dip, c->gip, hl + n);
}
/* A reset for a segment no connection wants. */
static inline void nat_tcp_rst(uint32_t src, uint32_t dst, const uint8_t *t, unsigned n) {
  uint8_t fl = t[13];
  if (fl & 4) return;
  NatTcp c;
  memset(&c, 0, sizeof c);
  c.gip = src; c.dip = dst; c.gport = nat_be16(t); c.dport = nat_be16(t + 2);
  unsigned hl = (unsigned)(t[12] >> 4) * 4;
  uint32_t seq = nat_be32(t + 4), dl = n > hl ? n - hl : 0;
  if (fl & 16) nat_tcp_seg(&c, 4, nat_be32(t + 8), NULL, 0);
  else { c.rcv = seq + dl + ((fl & 2) ? 1 : 0) + (fl & 1); nat_tcp_seg(&c, 4 | 16, 0, NULL, 0); }
}
static inline void nat_probe_set(NatTcp *c, int st) {
  for (int i = 0; i < 4; i++)
    if (nat_probes[i].busy && nat_probes[i].port == c->gport) { nat_probes[i].busy = false; nat_probes[i].state = st; }
}
static inline void nat_tcp_free(NatTcp *c) {
  if (c->vs) nat_vs[c->vs - 1].closed = true;
  if (c->probe) nat_probe_set(c, 0);              /* (no SYN-ACK came: nothing listens) */
  if (c->fd >= 0) close(c->fd);
  free(c->buf);
  memset(c, 0, sizeof *c);
  c->fd = -1;
}
static inline void nat_tcp_reset(NatTcp *c) { nat_tcp_seg(c, 4 | 16, c->nxt, NULL, 0); nat_tcp_free(c); }
static inline void nat_tcp_arm(NatTcp *c) { if (!c->rto_at) c->rto_at = nat_ms() + c->rto; }

/* Data and FIN toward the guest, as far as its window allows. */
static inline void nat_tcp_output(NatTcp *c) {
  if (c->st != NT_EST) return;
  for (;;) {
    uint32_t fl = c->finsent ? 1 : 0;
    uint32_t inflight = c->nxt - c->una - fl;
    if (inflight >= c->len) break;
    if (inflight >= c->gwnd) { nat_tcp_arm(c); break; }
    if (nat_room && nat_room() < 3) { nat_tcp_arm(c); break; } /* the device's queue: leave it room */
    unsigned n = c->len - inflight, w = c->gwnd - inflight, m = c->gmss < NAT_MSS ? c->gmss : NAT_MSS;
    if (n > w) n = w;
    if (n > m) n = m;
    nat_tcp_seg(c, 16 | 8, c->nxt, c->buf + inflight, n);
    c->nxt += n;
    nat_tcp_arm(c);
  }
  if (c->heof && !c->finsent && c->nxt - c->una == c->len) {
    nat_tcp_seg(c, 1 | 16, c->nxt, NULL, 0);
    c->nxt++;
    c->finsent = true;
    nat_tcp_arm(c);
  }
}

static inline NatTcp *nat_tcp_new(void) {
  for (int i = 0; i < NAT_TCP; i++)
    if (nat_tcp[i].st == NT_FREE) {
      NatTcp *c = &nat_tcp[i];
      memset(c, 0, sizeof *c);
      c->fd = -1;
      c->buf = (uint8_t *)malloc(NAT_TXCAP);
      if (!c->buf) return NULL;
      c->rto = 300;
      c->gmss = 536;
      c->iss = nat_iss += 0x10000;
      c->una = c->iss;
      c->nxt = c->iss + 1;
      return c;
    }
  return NULL;
}

static inline void nat_tcp_in(uint32_t src, uint32_t dst, const uint8_t *t, unsigned n) {
  if (n < 20) return;
  unsigned hl = (unsigned)(t[12] >> 4) * 4;
  if (hl < 20 || hl > n) return;
  uint16_t sport = nat_be16(t), dport = nat_be16(t + 2);
  uint32_t seq = nat_be32(t + 4), ack = nat_be32(t + 8), wnd = nat_be16(t + 14);
  uint8_t fl = t[13];
  const uint8_t *d = t + hl;
  unsigned dl = n - hl;
  uint32_t mss = 536;
  for (unsigned i = 20; i + 1 < hl;) {
    if (t[i] == 0) break;
    if (t[i] == 1) { i++; continue; }
    if (t[i] == 2 && t[i + 1] == 4 && i + 3 < hl) mss = nat_be16(t + i + 2);
    if (t[i + 1] < 2) break;
    i += t[i + 1];
  }
  NatTcp *c = NULL;
  for (int i = 0; i < NAT_TCP; i++) {
    NatTcp *k = &nat_tcp[i];
    if (k->st != NT_FREE && k->gip == src && k->gport == sport && k->dip == dst && k->dport == dport) { c = k; break; }
  }
  if (!c) {
    if ((fl & (2 | 16 | 4)) != 2) { nat_tcp_rst(src, dst, t, n); return; }  /* only a SYN starts one */
    c = nat_tcp_new();
    if (!c) { nat_tcp_rst(src, dst, t, n); return; }
    c->gip = src; c->dip = dst; c->gport = sport; c->dport = dport;
    c->rcv = seq + 1; c->gwnd = wnd; c->gmss = mss;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { nat_tcp_reset(c); return; }
    nat_nonblock(fd);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct sockaddr_in a = nat_sa(nat_real(dst), dport);
    c->fd = fd;
    c->st = NT_CONNECTING;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0 && errno != EINPROGRESS) { nat_tcp_reset(c); return; }
    return;
  }
  if (fl & 4) { nat_tcp_free(c); return; } /* the guest reset it */
  if (c->st == NT_CONNECTING) return;      /* (a SYN again: the connect is still going) */
  if (c->st == NT_SYNACK && (fl & 2)) { nat_tcp_seg(c, 2 | 16, c->iss, NULL, 0); return; }
  if (c->st == NT_SYNSENT) {               /* inbound: the guest answers our SYN */
    if ((fl & 18) == 18 && ack == c->iss + 1 && c->probe) { /* a probe: it listens; the guest drops its half */
      nat_tcp_seg(c, 4, ack, NULL, 0);
      nat_probe_set(c, 1);
      c->probe = false;
      nat_tcp_free(c);
      return;
    }
    if ((fl & 18) == 18 && ack == c->iss + 1) {
      c->rcv = seq + 1; c->una = ack; c->gwnd = wnd; c->gmss = mss;
      c->st = NT_EST; c->rto_at = 0; c->tries = 0;
      nat_tcp_seg(c, 16, c->nxt, NULL, 0);
      nat_tcp_output(c);
    }
    return;
  }
  if (fl & 2) { nat_tcp_seg(c, 16, c->nxt, NULL, 0); return; }
  if (!(fl & 16)) return;
  if (c->st == NT_SYNACK) {
    if (ack != c->iss + 1) { nat_tcp_reset(c); return; }
    c->una = ack; c->st = NT_EST; c->rto_at = 0; c->tries = 0;
  }
  /* the acknowledgment */
  int32_t acked = (int32_t)(ack - c->una), beyond = (int32_t)(ack - c->nxt);
  if (beyond <= 0 && acked > 0) {
    uint32_t da = (uint32_t)acked;
    if (c->finsent && beyond == 0) da--;
    if (da > c->len) da = c->len;
    memmove(c->buf, c->buf + da, c->len - da);
    c->len -= da;
    c->una = ack;
    c->rto_at = 0; c->tries = 0; c->rto = 300;
    if (c->una != c->nxt) nat_tcp_arm(c);
  }
  c->gwnd = wnd;
  /* data, in order; off = how much of it was had already */
  bool want_ack = false;
  int32_t off = (int32_t)(c->rcv - seq);
  if (off < 0) want_ack = dl || (fl & 1);  /* ahead of what we expect: dropped, acknowledged */
  else if ((uint32_t)off > dl) want_ack = dl || (fl & 1); /* all old, its FIN too: acknowledge again */
  else {
    bool fin = fl & 1;
    unsigned rest = dl - (unsigned)off;
    if (rest && !c->gfin) {
      ssize_t w = nat_s_send(c, d + off, rest);
      unsigned took = w > 0 ? (unsigned)w : 0;
      c->rcv += took;
      if (took < rest) fin = false;          /* the rest (and a FIN after it) comes again */
    }
    if (dl) want_ack = true;
    if (fin) {
      if (!c->gfin) { c->rcv++; c->gfin = true; nat_s_shut(c); }
      want_ack = true;
    }
  }
  if (want_ack) nat_tcp_seg(c, 16, c->nxt, NULL, 0);
  nat_tcp_output(c);
  if (c->gfin && c->finsent && c->una == c->nxt) nat_tcp_free(c);
}

/* Inbound: accept on the forwarded host ports, start guest connections. */
static inline void nat_fwd_poll(void) {
  for (int i = 0; i < nat_nfwd; i++) {
    for (;;) {
      int fd = accept(nat_fwd[i].fd, NULL, NULL);
      if (fd < 0) break;
      NatTcp *c = nat_tcp_new();
      if (!c) { close(fd); break; }
      nat_nonblock(fd);
      int one = 1;
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
      c->fd = fd;
      c->inbound = true;
      c->gip = nat_guest; c->gport = nat_fwd[i].gport;
      c->dip = NAT_GW; c->dport = nat_eport;
      nat_eport = nat_eport == 60999 ? 40000 : nat_eport + 1;
      c->st = NT_SYNSENT;
      nat_tcp_seg(c, 2, c->iss, NULL, 0);
      nat_tcp_arm(c);
    }
  }
}

static inline void nat_tcp_poll(void) {
  uint64_t now = nat_ms();
  for (int i = 0; i < NAT_TCP; i++) {
    NatTcp *c = &nat_tcp[i];
    if (c->st == NT_FREE) continue;
    if (c->st == NT_CONNECTING) {
      struct pollfd p = {c->fd, POLLOUT, 0};
      if (poll(&p, 1, 0) <= 0) continue;
      int err = 0;
      socklen_t el = sizeof err;
      getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &err, &el);
      if (err) { nat_tcp_reset(c); continue; } /* refused, unreachable: RST */
      c->st = NT_SYNACK;
      nat_tcp_seg(c, 2 | 16, c->iss, NULL, 0);
      nat_tcp_arm(c);
      continue;
    }
    if (c->st == NT_EST && !c->heof && c->len < NAT_TXCAP) { /* the host's bytes */
      ssize_t r = nat_s_recv(c, c->buf + c->len, NAT_TXCAP - c->len);
      if (r > 0) c->len += (unsigned)r;
      else if (r == 0) c->heof = true;
      else if (errno != EAGAIN && errno != EWOULDBLOCK) { nat_tcp_reset(c); continue; }
    }
    nat_tcp_output(c);
    if (c->st == NT_FREE) continue;
    if (c->rto_at && now >= c->rto_at) {   /* nothing came back in time: the oldest again */
      c->rto_at = 0;
      if (++c->tries > (c->probe ? 1 : 10)) { nat_tcp_reset(c); continue; }
      c->rto = c->rto * 2 > 4000 ? 4000 : c->rto * 2;
      if (c->st == NT_SYNACK) nat_tcp_seg(c, 2 | 16, c->iss, NULL, 0);
      else if (c->st == NT_SYNSENT) nat_tcp_seg(c, 2, c->iss, NULL, 0);
      else if (c->len) {
        unsigned m = c->gmss < NAT_MSS ? c->gmss : NAT_MSS, k = c->len < m ? c->len : m;
        nat_tcp_seg(c, 16 | 8, c->una, c->buf, k);
        if ((int32_t)(c->una + k - c->nxt) > 0) c->nxt = c->una + k;
      } else if (c->finsent && c->una != c->nxt) nat_tcp_seg(c, 1 | 16, c->nxt - 1, NULL, 0);
      nat_tcp_arm(c);
    }
    if (c->gfin && c->finsent && c->una == c->nxt) nat_tcp_free(c);
  }
}

/* ------------------------------------------------------------ ICMP echo */
typedef struct { bool on; uint32_t gip, dip; uint16_t id, seq; uint64_t at; } NatPing;
static NatPing nat_ping[NAT_PING];
static int nat_icmpfd = -2; /* -2: not tried yet, -1: not available */

static inline void nat_echo_reply(uint32_t src, uint32_t dst, const uint8_t *m, unsigned n, uint16_t id) {
  static uint8_t p[NAT_MTU];
  if (n < 8 || n > NAT_MTU - 20) return;
  memcpy(p + 20, m, n);
  p[20] = 0; p[21] = 0;
  nat_put16(p + 24, id);
  nat_put16(p + 22, 0);
  nat_put16(p + 22, nat_fold(nat_sum(p + 20, n, 0)));
  nat_ip_out(p, 1, src, dst, n);
}
static inline void nat_icmp_in(uint32_t src, uint32_t dst, const uint8_t *m, unsigned n) {
  if (n < 8 || m[0] != 8) return;
  if (dst == NAT_GW || dst == NAT_DNS) { nat_echo_reply(dst, src, m, n, nat_be16(m + 4)); return; }
  if (nat_icmpfd == -2) {
    nat_icmpfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (nat_icmpfd >= 0) nat_nonblock(nat_icmpfd);
    else { nat_icmpfd = -1; fprintf(stderr, "nat: no unprivileged ICMP socket here: pings to the Internet are dropped\n"); }
  }
  if (nat_icmpfd < 0) return;
  NatPing *s = &nat_ping[0];                 /* a free slot, or the oldest */
  for (int i = 0; i < NAT_PING && s->on; i++)
    if (!nat_ping[i].on || nat_ping[i].at < s->at) s = &nat_ping[i];
  *s = (NatPing){true, src, dst, nat_be16(m + 4), nat_be16(m + 6), nat_ms()};
  struct sockaddr_in a = nat_sa(dst, 0);
  (void)!sendto(nat_icmpfd, m, n, 0, (struct sockaddr *)&a, sizeof a);
}
static inline void nat_icmp_poll(void) {
  if (nat_icmpfd < 0) return;
  uint8_t b[NAT_MTU + 60];
  for (;;) {
    struct sockaddr_in a;
    socklen_t al = sizeof a;
    ssize_t n = recvfrom(nat_icmpfd, b, sizeof b, 0, (struct sockaddr *)&a, &al);
    if (n < 8) break;
    uint8_t *m = b;
    if ((b[0] >> 4) == 4 && n >= 28) { unsigned hl = (unsigned)(b[0] & 15) * 4; m = b + hl; n -= hl; } /* (macOS: with its IP header) */
    if (m[0] != 0) continue;
    uint32_t from = ntohl(a.sin_addr.s_addr);
    uint16_t seq = nat_be16(m + 6);
    for (int i = 0; i < NAT_PING; i++) {
      NatPing *s = &nat_ping[i];
      if (s->on && s->dip == from && s->seq == seq) {
        s->on = false;
        nat_echo_reply(from, s->gip, m, (unsigned)n, s->id);
        break;
      }
    }
  }
}

/* ------------------------------------------------------------ virtual connections */
static uint16_t nat_vport = 61000;
static inline NatTcp *nat_vstart(uint32_t guest, uint16_t port) {
  NatTcp *c = nat_tcp_new();
  if (!c) return NULL;
  c->inbound = true;
  c->gip = guest; c->gport = port;
  c->dip = NAT_GW; c->dport = nat_vport;
  nat_vport = nat_vport == 65000 ? 61000 : nat_vport + 1;
  c->st = NT_SYNSENT;
  nat_tcp_seg(c, 2, c->iss, NULL, 0);
  nat_tcp_arm(c);
  return c;
}
/* A connection from the embedder to the guest's port -> its id, or -1. */
static inline int nat_vopen(uint32_t guest, uint16_t port) {
  for (int i = 0; i < NAT_VS; i++) {
    NatVs *v = &nat_vs[i];
    if (v->used) continue;
    NatTcp *c = nat_vstart(guest, port);
    if (!c) return -1;
    free(v->in);
    free(v->out);
    memset(v, 0, sizeof *v);
    v->used = true;
    c->vs = i + 1;
    return i;
  }
  return -1;
}
static inline NatTcp *nat_vconn(int id) {
  for (int i = 0; i < NAT_TCP; i++) if (nat_tcp[i].st != NT_FREE && nat_tcp[i].vs == id + 1) return &nat_tcp[i];
  return NULL;
}
/* Bytes for the guest (n = 0: the end: FIN once they are sent). */
static inline void nat_vsend(int id, const uint8_t *d, size_t n) {
  if (id < 0 || id >= NAT_VS || !nat_vs[id].used) return;
  NatVs *v = &nat_vs[id];
  if (!n) { v->eof_in = true; return; }
  uint8_t *b = (uint8_t *)realloc(v->in, v->inlen + n);
  if (!b) return;
  v->in = b;
  memcpy(v->in + v->inlen, d, n);
  v->inlen += n;
}
/* Bytes from the guest -> how many (0: it closed and all were taken; -1: none yet). */
static inline long nat_vrecv(int id, uint8_t *b, size_t max) {
  if (id < 0 || id >= NAT_VS || !nat_vs[id].used) return 0;
  NatVs *v = &nat_vs[id];
  if (!v->outlen) {
    if (v->closed) return 0;
    NatTcp *c = nat_vconn(id);
    return c && c->gfin ? 0 : -1;
  }
  size_t k = v->outlen < max ? v->outlen : max;
  memcpy(b, v->out, k);
  memmove(v->out, v->out + k, v->outlen - k);
  v->outlen -= k;
  return (long)k;
}
static inline void nat_vclose(int id) {
  if (id < 0 || id >= NAT_VS || !nat_vs[id].used) return;
  NatTcp *c = nat_vconn(id);
  if (c) nat_tcp_reset(c);
  NatVs *v = &nat_vs[id];
  free(v->in);
  free(v->out);
  memset(v, 0, sizeof *v);
}
/* A packet the guest sent: true if it belongs to a virtual connection (or a probe), and was used. */
static inline bool nat_vtake(const uint8_t *p, unsigned n) {
  if (n < 40 || (p[0] >> 4) != 4 || p[9] != 6) return false;
  unsigned hl = (unsigned)(p[0] & 15) * 4;
  if (n < hl + 20) return false;
  uint32_t src = nat_be32(p + 12), dst = nat_be32(p + 16);
  uint16_t sport = nat_be16(p + hl), dport = nat_be16(p + hl + 2);
  for (int i = 0; i < NAT_TCP; i++) {
    NatTcp *c = &nat_tcp[i];
    if (c->st != NT_FREE && (c->vs || c->probe) && c->gip == src && c->gport == sport && c->dip == dst && c->dport == dport) {
      unsigned tl = nat_be16(p + 2);
      nat_tcp_in(src, dst, p + hl, (tl < n ? tl : n) - hl);
      return true;
    }
  }
  return false;
}
/* Something listens on the guest's port? 1 yes, 0 no, -1 not known yet. A
 * probe goes now and then (every 2 s at most per port). */
static inline int nat_vprobe(uint32_t guest, uint16_t port) {
  NatProbe *e = NULL;
  for (int i = 0; i < 4; i++) if (nat_probes[i].port == port) e = &nat_probes[i];
  if (!e) {
    e = &nat_probes[0];
    for (int i = 0; i < 4; i++) if (!nat_probes[i].port || nat_probes[i].at < e->at) e = &nat_probes[i];
    *e = (NatProbe){port, -1, 0, false};
  }
  uint64_t now = nat_ms();
  if (!e->busy && now - e->at >= 2000) {
    NatTcp *c = nat_vstart(guest, port);
    if (c) { c->probe = true; c->rto = 500; e->busy = true; e->at = now; }
  }
  return e->state;
}

/* ------------------------------------------------------------ the interface */
static inline void nat_init(nat_out_fn out, nat_room_fn room) {
  nat_out = out;
  nat_room = room;
  for (int i = 0; i < NAT_TCP; i++) nat_tcp[i].fd = -1;
}

/* Listens on 127.0.0.1:hport for connections to the guest's gport; false
 * (after a warning) if that port cannot be had. */
static inline bool nat_forward(unsigned hport, unsigned gport) {
  if (nat_nfwd == NAT_FWD) { fprintf(stderr, "nat: at most %d forwards\n", NAT_FWD); return false; }
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  if (fd >= 0) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = nat_sa(0x7f000001u, (uint16_t)hport);
  if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 16)) {
    fprintf(stderr, "nat: cannot listen on 127.0.0.1:%u (%s); no forward to guest port %u\n", hport,
            strerror(errno), gport);
    if (fd >= 0) close(fd);
    return false;
  }
  nat_nonblock(fd);
  nat_fwd[nat_nfwd++] = (NatFwd){fd, (uint16_t)hport, (uint16_t)gport};
  return true;
}

/* A packet the guest sent. */
static inline void nat_input(const uint8_t *p, unsigned n) {
  if (n < 20 || (p[0] >> 4) != 4) return;
  unsigned hl = (unsigned)(p[0] & 15) * 4, tl = nat_be16(p + 2);
  if (hl < 20 || tl > n || tl < hl || (nat_be16(p + 6) & 0x3fff)) return;
  uint32_t src = nat_be32(p + 12), dst = nat_be32(p + 16);
  nat_guest = src;
  if ((dst >> 8) == (NAT_GW >> 8) && dst != NAT_GW && dst != NAT_DNS) return; /* no one else on the link */
  if ((dst >> 24) == 127 || dst == 0xffffffffu) return;
  const uint8_t *l = p + hl;
  unsigned ll = tl - hl;
  if (p[9] == 17) nat_udp_in(src, dst, l, ll);
  else if (p[9] == 6) nat_tcp_in(src, dst, l, ll);
  else if (p[9] == 1) nat_icmp_in(src, dst, l, ll);
}

/* Now and then: whatever the host has for the guest. */
static inline void nat_poll(void) {
  nat_udp_poll();
  nat_fwd_poll();
  nat_tcp_poll();
  nat_icmp_poll();
}

#endif
