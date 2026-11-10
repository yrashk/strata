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

enum { NET_NONE, NET_LOOP, NET_UDP };
static int net_mode = NET_NONE;
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
  fprintf(stderr, "bad -N (none, loop or udp:LPORT:HOST:RPORT)\n");
  return false;
}

/* A packet arrived on the link: into the receive queue, or dropped. */
static inline void net_rx_push(const uint8_t *p, unsigned n) {
  if (net_qcnt == NET_QLEN) { net_drops++; return; }
  int i = (net_qhead + net_qcnt) % NET_QLEN;
  memcpy(net_q[i], p, n);
  net_qlen[i] = n;
  net_qcnt++;
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
  if (net_mode == NET_LOOP) net_rx_push(net_txb, (unsigned)n);
#ifndef __EMSCRIPTEN__
  else if (net_mode == NET_UDP) (void)!send(net_fd, net_txb, (size_t)n, 0);
#endif
}

/* Now and then: datagrams that have arrived from the peer. */
static inline void net_host_poll(void) {
#ifndef __EMSCRIPTEN__
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
static inline bool net_live(void) { return net_mode == NET_UDP; }

static inline int net_rx_count(void) { return net_qcnt; }
static inline const uint8_t *net_rx_head(unsigned *n) { *n = net_qlen[net_qhead]; return net_q[net_qhead]; }
static inline void net_rx_pop(void) { net_qhead = (net_qhead + 1) % NET_QLEN; net_qcnt--; }

/* The STATUS register: next length | queued << 16 | link << 24 | drops << 32. */
static inline uint64_t net_status(void) {
  uint64_t len = net_qcnt ? net_qlen[net_qhead] : 0;
  return len | (uint64_t)net_qcnt << 16 | (uint64_t)(net_mode != NET_NONE) << 24 | (uint64_t)net_drops << 32;
}

#endif
