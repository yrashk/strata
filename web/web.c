/* strata-emu in the browser (Emscripten): the driver of emu/emu.c for the
 * play page's Web Worker (site/play/worker.js) and for node (the tests,
 * tools/wasm-run.js).
 *
 * This file includes emu/emu.c, so it sees the whole machine. The worker
 * calls main() (Module.callMain) with the usual flags; main() sets the
 * machine up and, built with Emscripten, returns through web_start() in
 * front of its run loop. From then on the worker calls web_run(ms) again
 * and again: it runs machine rounds (emu.c's machine_round(), the same
 * round the desktop loop runs) for up to `ms` milliseconds and returns
 *   - WEB_BUSY (0) when the time is up: the worker handles its messages
 *     (input, Ctrl-C) and calls again at once;
 *   - a positive number of milliseconds when every live core is blocked
 *     on a device read: the time until the next timer or VSYNC deadline
 *     (WEB_FOREVER when only input can wake the machine). The worker
 *     sleeps that long (setTimeout) or until input arrives;
 *   - WEB_DONE (-1) once the machine has stopped (web_stat(5) says how).
 * Nothing here ever blocks, and no emscripten main loop is involved: the
 * worker's event loop is the main loop.
 *   - console output (stdout) is flushed at the end of every slice; the
 *     worker's FS.init hook gets it byte by byte and posts it in batches;
 *   - console input comes from the page: web_input() queues bytes (the
 *     terminal and the canvas keyboard), web_break() is Ctrl-C;
 *   - the pointer comes from the canvas's mouse: web_pointer();
 *   - the framebuffer: web_paint() converts the rows written since the
 *     last call from XRGB8888 to RGBA and hands them to
 *     Module.webPaint(ptr, y0, rows, width, height); the worker copies
 *     them out and transfers them to the page's canvas.
 *
 * With the virtual timer (-T virtual, the tests) an idle machine skips
 * ahead to its next deadline instead of sleeping, like the desktop loop.
 *
 * Build: make wasm (needs emcc). */
#include <emscripten.h>

static int web_start(void);

#include "../emu/emu.c"

/* ------------------------------------------------------------ state */

enum { WEB_RUNNING, WEB_HALTED, WEB_DEADLOCK, WEB_STOPPED, WEB_TIMEOUT };
#define WEB_BUSY 0.0
#define WEB_DONE -1.0
#define WEB_FOREVER 1e9
static int web_state = WEB_STOPPED;
static bool web_painted;          /* the canvas has had its first (whole) frame */
static uint8_t *web_rgba;         /* RGBA copy of the scanned-out rows */
static char web_outbuf[1 << 16];

/* Runs the machine for up to `ms` milliseconds; see the top of this file. */
EMSCRIPTEN_KEEPALIVE double web_run(double ms) {
  if (web_state != WEB_RUNNING) return WEB_DONE;
  double end = emscripten_get_now() + ms, ret = WEB_BUSY;
  unsigned long long checked = mach_steps;
  for (unsigned k = 0;; k++) {
    rounds++;
    if (opt_break_at && mach_steps >= opt_break_at) { /* a simulated Ctrl-C (-b) */
      opt_break_at = 0;
      press_break();
    }
    host_ptr_script_run(mach_steps); /* -P (the tests under node) */
    if ((k & 63) == 0) nat_poll();    /* the page's connections to the guest: their timers */
    int r = machine_round();
    if (r == RND_HALTED) { web_state = WEB_HALTED; break; }
    if (r == RND_DEADLOCK) {
      fprintf(stderr, "deadlock: every live core is blocked\n");
      web_state = WEB_DEADLOCK;
      break;
    }
    if (opt_max_steps && mach_steps >= opt_max_steps) {
      fprintf(stderr, "timeout after %llu steps\n", mach_steps);
      web_state = WEB_TIMEOUT;
      break;
    }
    if (r == RND_IDLE && host_ptr_script_stepped()) { host_ptr_script_do(); continue; }
    if (r == RND_IDLE) {
      if (virtual_time && idle.timed && !idle.input) { rounds = idle.next * 100; continue; }
      if (!idle.timed) { ret = WEB_FOREVER; break; }
      uint64_t now = now_ticks();
      if (idle.next > now + 300) { ret = (double)(idle.next - now) / 1000.0; break; }
      /* a deadline this close: spin (the worker's timers are too coarse) */
    }
    /* the clock is read now and then: every 256 rounds, or 100k steps */
    if (((k & 255) == 255 || mach_steps - checked >= 100000 || r == RND_IDLE)) {
      checked = mach_steps;
      if (emscripten_get_now() >= end) break;
    }
  }
  fflush(stdout);
  fflush(stderr);
  return web_state == WEB_RUNNING ? ret : WEB_DONE;
}

/* Hands the framebuffer rows that changed since the last call to the
 * worker (Module.webPaint). Returns false if there was nothing to paint. */
EMSCRIPTEN_KEEPALIVE int web_paint(void) {
  if (!host_want_window && !host_presented) return 0; /* nothing was ever drawn */
  uint32_t lo = host_dirty_lo, hi = host_dirty_hi;
  if (!web_painted) { lo = 0; hi = host_fb_bytes(); }
  if (lo >= hi) return 0;
  web_painted = true;
  host_dirty_lo = UINT32_MAX;
  host_dirty_hi = 0;
  uint32_t stride = host_fb_w * 4;
  uint32_t y0 = lo / stride, y1 = (hi + stride - 1) / stride;
  if (y1 > host_fb_h) y1 = host_fb_h;
  if (!web_rgba && !(web_rgba = malloc(host_fb_bytes()))) return 0;
  const uint32_t *src = (const uint32_t *)(t3 + FB_BASE + (size_t)y0 * stride); /* B, G, R, unused */
  uint32_t *dst = (uint32_t *)(web_rgba + (size_t)y0 * stride);                 /* R, G, B, A */
  for (size_t n = (size_t)(y1 - y0) * host_fb_w; n; n--) {
    uint32_t v = *src++;
    *dst++ = 0xff000000u | (v & 0xff00u) | (v >> 16 & 0xffu) | (v & 0xffu) << 16;
  }
  EM_ASM({ if (Module.webPaint) Module.webPaint($0, $1, $2, $3, $4); },
         web_rgba + (size_t)y0 * stride, y0, y1 - y0, host_fb_w, host_fb_h);
  return 1;
}

/* Called by emu.c's main() in front of its run loop. */
static int web_start(void) {
  nat_init(net_rx_push, net_room);  /* (its virtual connections, in every network mode) */
  setvbuf(stdout, web_outbuf, _IOFBF, sizeof web_outbuf);
  web_state = WEB_RUNNING;
  return 0;
}

/* ------------------------------------------------------------ the worker's calls */

/* Console input bytes (the terminal, the canvas keyboard, pasted demos). */
EMSCRIPTEN_KEEPALIVE void web_input(const uint8_t *p, int n) {
  for (int i = 0; i < n; i++) host_in_push(p[i]);
}

/* Ctrl-C: completes the oldest pending break read, or is remembered. */
EMSCRIPTEN_KEEPALIVE void web_break(void) { press_break(); }

/* The canvas's mouse: op 1 move to (a, b) in framebuffer pixels, 2 button a
 * down (b = 1) or up (b = 0), 3 wheel (a = y, b = x), 4 enter, 5 leave (the
 * PTR_* kinds). Completes waiting EVENT reads at once. */
EMSCRIPTEN_KEEPALIVE void web_pointer(int op, int a, int b) {
  switch (op) {
  case PTR_MOVE: host_ptr_move(a, b); break;
  case PTR_BUTTON: host_ptr_button(a, b != 0); break;
  case PTR_WHEEL: host_ptr_wheel(a, b); break;
  case PTR_ENTER: host_ptr_enter(true); break;
  case PTR_LEAVE: host_ptr_enter(false); break;
  }
  pend_service();
}

/* True once the guest has read the pointer device: the page hides its cursor. */
EMSCRIPTEN_KEEPALIVE int web_pointer_used(void) { return host_ptr_used; }

/* The network (common/net.h, site/play/net.js): a packet for the guest
 * (from another tab or a relay), the page's answer to a DNS query
 * (Module.webDns), the host number this tab's guest should take
 * (10.0.0.n, STATUS bits 31..26). */
EMSCRIPTEN_KEEPALIVE void web_net_rx(const uint8_t *p, int n) {
  if (n > 0 && n <= (int)NET_MTU) net_rx_push(p, (unsigned)n);
  pend_service();
}
EMSCRIPTEN_KEEPALIVE void web_net_dns(const uint8_t *p, int n) {
  if (n > 0) net_web_dns_reply(p, (unsigned)n);
  pend_service();
}
EMSCRIPTEN_KEEPALIVE void web_net_hint(int n) { net_hint = (unsigned)n & 63; }

/* The page's connections to the guest's servers (its web server in a panel:
 * site/play/sw.js): common/netnat.h's virtual connections, from 10.0.2.2 to
 * the guest's address. open -> an id or -1; send (len 0: no more to send);
 * recv -> bytes, 0 once the guest has closed and all was taken, -1 not yet;
 * close: done (a reset if it is still open). listening -> 1 / 0 / -1 (not
 * known yet): a SYN probe now and then, which the guest's listener never
 * sees as a connection. */
EMSCRIPTEN_KEEPALIVE int web_http_open(int port) {
  int id = nat_vopen(net_web_guest(), (uint16_t)port);
  nat_poll();
  pend_service();
  return id;
}
EMSCRIPTEN_KEEPALIVE void web_http_send(int id, const uint8_t *p, int n) {
  nat_vsend(id, p, n > 0 ? (size_t)n : 0);
  nat_poll();
  pend_service();
}
EMSCRIPTEN_KEEPALIVE int web_http_recv(int id, uint8_t *p, int max) {
  nat_poll();
  pend_service();
  return (int)nat_vrecv(id, p, (size_t)max);
}
EMSCRIPTEN_KEEPALIVE void web_http_close(int id) { nat_vclose(id); pend_service(); }
EMSCRIPTEN_KEEPALIVE int web_port_listening(int port) {
  int r = nat_vprobe(net_web_guest(), (uint16_t)port);
  pend_service();
  return r;
}

/* ------------------------------------------------------------ the debugger (site/debug/) */

/* With --debug (any WHERE: the worker is the transport), the worker drives
 * the debug engine (emu/debug.c) instead of calling web_run():
 *   web_dbg(line)     one request (a JSON line); returns the answer, valid
 *                     until the next call;
 *   web_dbg_run(ms)   runs the machine while it is running: like web_run's
 *                     result, 0 = call again, > 0 = idle (sleep that long or
 *                     until input), < 0 = it is not running (stopped);
 *   web_dbg_events()  the events since the last call (JSON lines), then
 *                     forgotten: console output, stops;
 *   web_dbg_repaint() the next web_paint() sends the whole framebuffer.
 * Keys and the pointer go through the engine (its input and pointer
 * requests), which logs them for time travel, not web_input/web_pointer. */
static JW web_dbg_resp, web_dbg_ev;

EMSCRIPTEN_KEEPALIVE const char *web_dbg(const char *line) {
  dbg_request(line, strlen(line), &web_dbg_resp);
  return web_dbg_resp.p;
}
EMSCRIPTEN_KEEPALIVE double web_dbg_run(double ms) {
  double r = dbg_run(ms);
  con_flush();
  return r;
}
/* After the engine went to another point of the run (time travel), the
 * framebuffer may differ anywhere: web_paint() sends all of it next. */
EMSCRIPTEN_KEEPALIVE void web_dbg_repaint(void) { web_painted = false; }

EMSCRIPTEN_KEEPALIVE const char *web_dbg_events(void) {
  con_flush();
  jw_reset(&web_dbg_ev);
  jw_raw(&web_dbg_ev, dbg_out.p ? dbg_out.p : "", dbg_out.n);
  dbg_out.n = 0;
  if (dbg_out.p) dbg_out.p[0] = 0;
  return web_dbg_ev.p;
}

/* Stops the machine for good (Reset loads a fresh instance). */
EMSCRIPTEN_KEEPALIVE void web_stop(void) { web_state = WEB_STOPPED; }

/* What exit() does on the desktop: flushes the console and writes the
 * last presented frame (-F). For the tests under node. */
EMSCRIPTEN_KEEPALIVE void web_finish(void) {
  fflush(stdout);
  fflush(stderr);
  if (trace) fclose(trace);
  host_write_ppm();
}

/* Status: 0 steps, 1 rounds, 2 cores, 3 live cores, 4 machine time
 * (timer ticks, µs), 5 state, 6 queued input bytes, 7 a core faulted,
 * 8 the JIT is on. */
EMSCRIPTEN_KEEPALIVE double web_stat(int what) {
  switch (what) {
  case 0: return (double)mach_steps;
  case 1: return (double)rounds;
  case 2: return ncores;
  case 3: {
    int n = 0;
    for (int i = 0; i < ncores; i++) n += !cores[i].halted;
    return n;
  }
  case 4: return (double)now_ticks();
  case 5: return web_state;
  case 6: return host_in_cnt;
  case 7: return faulted;
  case 8: return use_jit;
  default: return 0;
  }
}
