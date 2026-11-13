// strata-rtl in the browser (Emscripten): the Verilated RTL, driven by the
// play page's Web Worker (site/play/worker.js) and by node (the tests,
// tools/wasm-run.js) through the same calls as the emulator's web build
// (web/web.c). The page can so run a program on the emulator or on the
// SystemVerilog itself.
//
// This file includes sim/main.cpp, so it sees the model and the harness's
// DPI functions. The worker calls main() (Module.callMain) with the usual
// strata-rtl flags; main() loads the image, resets the model and, built
// with Emscripten, returns through web_start() in front of its run loop.
// From then on the worker calls web_run(ms) again and again: it clocks the
// model for up to `ms` milliseconds and returns
//   - WEB_BUSY (0) when the time is up: the worker handles its messages
//     and calls again at once;
//   - WEB_DONE (-1) once the machine has stopped (web_stat(5) says how).
// The RTL never reports "idle": a core that waits for a device retries its
// read every few cycles, as the hardware would, so a waiting machine keeps
// being clocked (and keeps a CPU busy).
//
// Differences from the emulator's module, which the worker allows for:
//   - web_stat(0) counts clock cycles, not instructions;
//   - there is no JIT, no debugger and no network far end (the network
//     interface is there, with no cable: -N none).
//
// Build: make wasm-rtl (needs verilator and em++).
#include <emscripten.h>

#include "../sim/main.cpp"

enum { WEB_RUNNING, WEB_HALTED, WEB_DEADLOCK, WEB_STOPPED, WEB_TIMEOUT };
#define WEB_BUSY 0.0
#define WEB_DONE -1.0
static int web_state = WEB_STOPPED;
static bool web_painted;          // the canvas has had its first (whole) frame
static uint8_t *web_rgba;         // RGBA copy of the scanned-out rows
static char web_outbuf[1 << 16];

extern "C" {

// Clocks the machine for up to `ms` milliseconds; see the top of this file.
EMSCRIPTEN_KEEPALIVE double web_run(double ms) {
  if (web_state != WEB_RUNNING) return WEB_DONE;
  double end = emscripten_get_now() + ms;
  for (;;) {
    for (int k = 0; k < 512; k++) {   // the clock is read every 512 cycles
      sim_cycle();
      if (top->all_halted) { web_state = WEB_HALTED; break; }
      if (max_cycles && cycles >= max_cycles) {
        fprintf(stderr, "timeout after %llu cycles\n", cycles);
        web_state = WEB_TIMEOUT;
        break;
      }
    }
    if (web_state != WEB_RUNNING || emscripten_get_now() >= end) break;
  }
  if (web_state == WEB_HALTED) fprintf(stderr, "total cycles: %llu\n", cycles);
  fflush(stdout);
  fflush(stderr);
  return web_state == WEB_RUNNING ? WEB_BUSY : WEB_DONE;
}

// Hands the framebuffer rows that changed since the last call to the
// worker (Module.webPaint): they are read out of the model's system memory
// (scan_fetch) and converted from XRGB8888 to RGBA. Returns false if there
// was nothing to paint.
EMSCRIPTEN_KEEPALIVE int web_paint(void) {
  if (!host_want_window && !host_presented) return 0; // nothing was ever drawn
  uint32_t lo = host_dirty_lo, hi = host_dirty_hi;
  if (!web_painted) { lo = 0; hi = host_fb_bytes(); }
  if (lo >= hi) return 0;
  web_painted = true;
  host_dirty_lo = UINT32_MAX;
  host_dirty_hi = 0;
  uint32_t stride = host_fb_w * 4;
  uint32_t y0 = lo / stride, y1 = (hi + stride - 1) / stride;
  if (y1 > host_fb_h) y1 = host_fb_h;
  scan_fetch(y0 * stride, y1 * stride);
  if (!web_rgba && !(web_rgba = (uint8_t *)malloc(host_fb_bytes()))) return 0;
  const uint32_t *src = (const uint32_t *)(scan_fb + (size_t)y0 * stride); // B, G, R, unused
  uint32_t *dst = (uint32_t *)(web_rgba + (size_t)y0 * stride);            // R, G, B, A
  for (size_t n = (size_t)(y1 - y0) * host_fb_w; n; n--) {
    uint32_t v = *src++;
    *dst++ = 0xff000000u | (v & 0xff00u) | (v >> 16 & 0xffu) | (v & 0xffu) << 16;
  }
  EM_ASM({ if (Module.webPaint) Module.webPaint($0, $1, $2, $3, $4); },
         web_rgba + (size_t)y0 * stride, y0, y1 - y0, host_fb_w, host_fb_h);
  return 1;
}

// Console input bytes (the terminal, the canvas keyboard).
EMSCRIPTEN_KEEPALIVE void web_input(const uint8_t *p, int n) {
  for (int i = 0; i < n; i++) host_in_push(p[i]);
}

// Ctrl-C: the console's break port sees it at its next look (sim_break).
EMSCRIPTEN_KEEPALIVE void web_break(void) { host_breaks++; }

// The canvas's mouse (the PTR_* kinds, as in web/web.c).
EMSCRIPTEN_KEEPALIVE void web_pointer(int op, int a, int b) {
  switch (op) {
  case PTR_MOVE: host_ptr_move(a, b); break;
  case PTR_BUTTON: host_ptr_button(a, b != 0); break;
  case PTR_WHEEL: host_ptr_wheel(a, b); break;
  case PTR_ENTER: host_ptr_enter(true); break;
  case PTR_LEAVE: host_ptr_enter(false); break;
  }
}

// True once the guest has read the pointer device: the page hides its cursor.
EMSCRIPTEN_KEEPALIVE int web_pointer_used(void) { return host_ptr_used; }

// Stops the machine for good (Reset loads a fresh instance).
EMSCRIPTEN_KEEPALIVE void web_stop(void) { web_state = WEB_STOPPED; }

// What the desktop does at exit: flushes the console and writes the last
// presented frame (-F). For the tests under node.
EMSCRIPTEN_KEEPALIVE void web_finish(void) {
  fflush(stdout);
  fflush(stderr);
  if (trace_file) fclose(trace_file);
  host_write_ppm();
}

// Status, as web/web.c: 0 clock cycles (the emulator: steps), 1 the same,
// 2 cores, 3 live cores, 4 machine time (timer ticks, µs), 5 state,
// 6 queued input bytes, 7 a core faulted, 8 the JIT is on (never),
// 9 this is the RTL (the emulator's module has no 9: 0).
EMSCRIPTEN_KEEPALIVE double web_stat(int what) {
  switch (what) {
  case 0: return (double)cycles;
  case 1: return (double)cycles;
  case 2: return NCORES;
  case 3: return NCORES - halts_seen;
  case 4: return virtual_time ? (double)cycles / 100.0 : (double)host_us();
  case 5: return web_state;
  case 6: return host_in_cnt;
  case 7: return faulted;
  case 9: return 1;
  default: return 0;
  }
}

} // extern "C"

// Called by sim/main.cpp's main() in front of its run loop.
static int web_start(void) {
  setvbuf(stdout, web_outbuf, _IOFBF, sizeof web_outbuf);
  web_state = WEB_RUNNING;
  return 0;
}
