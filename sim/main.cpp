// strata-rtl: runs an .stx image on the Verilated Strata RTL.
//
//   strata-rtl [-t trace.txt] [-m max_cycles] [-d disk.img] [-i input.txt] [-b cycles]
//              [-T real|virtual] [-g none] [-F frame.ppm] [-z scale] [-r WxH] [-H] [-N mode] image.stx
//
// Console output goes to stdout; console input comes from the -i file or
// stdin (an interactive terminal is put in character mode) and from the
// window's keyboard, without ever blocking the simulation: a console read
// with no byte there yet is retried by the RTL. Per-core halt/fault reports
// and statistics go to stderr. Ctrl-C typed at an interactive terminal or in
// the window (or simulated with -b after that many cycles) is delivered
// through the console break port. The timer counts host microseconds
// (-T real, the default) or clock cycles / 100 (-T virtual). The first
// write into the framebuffer window (or the first PRESENT) opens a window
// that scans out the framebuffer memory live (common/display.h); closing it
// ends the run. The network interface's link (-N: none, loop, or a UDP
// cable to another simulator) is the host side in common/net.h, shared with
// the emulator. Exit status: 0 if every core halted (or the window was
// closed), 1 on a fault or timeout.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

#include "Vstrata_top.h"
#include "Vstrata_top__Dpi.h"
#include "svdpi.h"
#include "verilated.h"

#include "../common/stx.h"
#include "../common/platform.h"
#include "../common/display.h"
#include "../common/net.h"

#ifndef NXMAP
#define NXMAP NXMAP_DEF /* the RTL's NXMAP parameter (the Makefile passes both) */
#endif
#ifndef DLS_KIB
#define DLS_KIB LS_DEF_KIB /* the RTL's DLS_KIB / ILS_KIB parameters (the Makefile passes them) */
#endif
#ifndef ILS_KIB
#define ILS_KIB LS_DEF_KIB
#endif
#ifndef NCORES
#define NCORES 4
#endif
#ifndef DISK_WORDS
#define DISK_WORDS 2097152
#endif

static StxImage img;
static FILE *trace_file = nullptr;
static bool faulted = false;
static uint8_t *disk;
static uint64_t disk_blocks;
static const char *disk_out;            // -w: the disk is written here at the end
static uint8_t plat[PLAT_LEN];
static bool virtual_time;
static svScope t3_scope;

// The model and the run's counters are file-scope so that the browser build
// (web/web_rtl.cpp, which includes this file) can clock the same machine a
// slice at a time; on the desktop main() below runs it to the end.
static std::unique_ptr<VerilatedContext> ctx;
static std::unique_ptr<Vstrata_top> top;
static unsigned long long cycles;       // clock cycles so far
static unsigned long long max_cycles;   // -m: 0 = no limit
static unsigned long long break_at;     // -b: press Ctrl-C after this many cycles (for tests)
static int halts_seen;                  // cores that have reported their halt
#ifdef __EMSCRIPTEN__
static int web_start(void);             // (web/web_rtl.cpp) takes over in front of the run loop
#endif

// One clock cycle, and what is due after it (-b, -P).
static inline void sim_cycle() {
  top->clk = 1;
  top->eval();
  top->clk = 0;
  top->eval();
  cycles++;
  if (break_at && cycles == break_at) host_breaks++;
  host_ptr_script_run(cycles);   // -P (N = clock cycles)
}

extern "C" long long img_word(int kind, int widx) {
  switch (kind) {
  case SK_ILS: return widx < (int)(ILS_KIB * 128) ? (long long)stx_word(img.ils, (uint32_t)widx) : 0;
  case SK_DLS: return widx < (int)(DLS_KIB * 128) ? (long long)stx_word(img.dls, (uint32_t)widx) : 0;
  case SK_T3: return widx < (int)(T3_BYTES / 8) ? (long long)stx_word(img.t3, (uint32_t)widx) : 0;
  case SK_T2: return widx < (int)(T2_BYTES / 8) ? (long long)stx_word(img.t2, (uint32_t)widx) : 0;
  }
  return 0;
}

extern "C" long long disk_word(int widx) {
  return (uint64_t)widx < disk_blocks * 64 ? (long long)stx_word(disk, (uint32_t)widx) : 0;
}
extern "C" void disk_write(int widx, long long v) { // the device wrote a word: kept for -w
  if ((uint64_t)widx < disk_blocks * 64)
    for (int i = 0; i < 8; i++) disk[(size_t)widx * 8 + i] = (uint8_t)((uint64_t)v >> (8 * i));
}
extern "C" char plat_byte(int idx) { return (char)plat[idx]; }
extern "C" char ident_byte(int) { return 0; }

extern "C" void sim_putc(char c) {
  fputc(c, stdout);
  fflush(stdout);
}

extern "C" int sim_break() {
  if (!host_breaks) return 0;
  host_breaks--;
  return 1;
}

// console input: a byte, 4 at the end of the input, or -1 if nothing yet
extern "C" int sim_getc() {
  fflush(stdout);
  return host_getc();
}

// network interface: TX bytes, the next RX packet, STATUS (common/net.h)
static uint8_t net_cur[NET_MTU]; // the packet an RX read is being served from
static unsigned net_curlen;
extern "C" void sim_net_tx(int idx, char b, int last) {
  net_tx_put((uint64_t)idx, (uint8_t)b);
  if (last) net_tx_done((uint64_t)idx + 1);
}
extern "C" int sim_net_rx_take() {
  if (!net_rx_count()) return -1;
  unsigned n;
  const uint8_t *p = net_rx_head(&n);
  memcpy(net_cur, p, n);
  net_curlen = n;
  net_rx_pop();
  return (int)n;
}
extern "C" char sim_net_rx_byte(int idx) { return idx >= 0 && (unsigned)idx < net_curlen ? (char)net_cur[idx] : 0; }
extern "C" long long sim_net_status() { return (long long)net_status(); }
// the pointer: the next queued event (-1: none), the state now
extern "C" long long sim_ptr_pop() { return host_ptr_ready() ? (long long)host_ptr_pop() : -1; }
extern "C" long long sim_ptr_state(int touch) {
  return (long long)(touch ? host_ptr_state() : host_ptr_peek()); // (only a guest read hides the cursor)
}

extern "C" long long sim_time_us() { return virtual_time ? -1 : (long long)host_us(); }

// The display's copy of the scanned-out framebuffer, read out of the
// system-memory model: the byte range [lo, hi) of it.
static uint8_t scan_fb[FB_SIZE];
static void scan_fetch(uint32_t lo, uint32_t hi) {
  if (!t3_scope) return;
  svScope old = svSetScope(t3_scope);
  for (uint32_t w = lo / 8; w < (hi + 7) / 8; w++) {
    uint64_t v = (uint64_t)sim_mem_word((int)(FB_BASE / 8 + w));
    memcpy(scan_fb + 8 * w, &v, 8);
  }
  svSetScope(old);
}

// live scanout: a word of the framebuffer window was written (only the
// dirty range is read back at the next repaint)
extern "C" void sim_fb_write(int widx) { host_fb_touch((uint32_t)widx * 8 - FB_BASE, 8); }

// PRESENT: the whole scanned-out region, read now, is the complete frame
extern "C" void sim_fb_present() {
  scan_fetch(0, host_fb_bytes());
  host_present(scan_fb);
}

extern "C" void sim_halt(int core, long long code, long long cyc, long long instret, long long stalls) {
  fprintf(stderr, "core %d: halt a0=%lld instret=%lld cycles=%lld stalls=%lld\n", core, code, instret,
          cyc, stalls);
  halts_seen++;
}

extern "C" void sim_fault(int core, int cause, long long pc, long long tval, int dbl) {
  fprintf(stderr, "core %d: %sfault %s pc=0x%llx tval=0x%llx\n", core, dbl ? "double " : "",
          stx_cause_name(cause), (unsigned long long)pc, (unsigned long long)tval);
  faulted = true;
}

extern "C" int sim_trace_on() { return trace_file != nullptr; }

extern "C" void sim_trace(int core, long long pc, int ir) {
  if (trace_file) fprintf(trace_file, "%d %08llx %08x\n", core, (unsigned long long)pc, (unsigned)ir);
}

static void usage() {
  fprintf(stderr,
          "usage: strata-rtl [-t trace.txt] [-m max_cycles] [-d disk.img] [-i input.txt] [-b cycles]\n"
          "                  [-P pointer.txt]\n"
          "                  [-T real|virtual] [-g none] [-F frame.ppm] [-z scale] [-r WxH] [-H]\n"
          "                  [-N mode] image.stx\n"
          "  -t FILE     write an instruction trace\n"
          "  -m N        stop after N cycles (timeout)\n"
          "  -d FILE     block device image\n"
          "  -w FILE     at the end, write the disk as it then is to FILE\n"
          "  -i FILE     console input from FILE (default: the terminal / stdin)\n"
          "  -P FILE     scripted pointer input (common/display.h; N = clock cycles)\n"
          "  -b N        press Ctrl-C after N cycles\n"
          "  -T MODE     timer: real (host microseconds, default) or virtual (cycles / 100)\n"
          "  -g none     never open a window (PRESENT still records the frame)\n"
          "  -F FILE     at exit, write the frame as of the last PRESENT as a binary PPM\n"
          "  -z N        window scale (default 1)\n"
          "  -r WxH      framebuffer size (default 1280x800; width a multiple of 8, 320x200..2560x1600)\n"
          "  -H          when every core has halted, keep the window open until it is closed\n"
          "  -N MODE     network: none (default), loop, peer, udp:LPORT:HOST:RPORT (common/net.h)\n"
          "(%d cores in this build)\n", NCORES);
  exit(2);
}

int main(int argc, char **argv) {
  const char *path = nullptr, *disk_path = nullptr, *in_path = nullptr, *ppm = nullptr;
  bool gfx = true, hold = false;
  unsigned fb_w = FB_DEF_WIDTH, fb_h = FB_DEF_HEIGHT;
  int scale = 1;
  for (int i = 1; i < argc; i++) {
    bool more = i + 1 < argc;
    if (!strcmp(argv[i], "-t") && more) {
      trace_file = fopen(argv[++i], "w");
      if (!trace_file) { perror("trace"); return 2; }
    } else if (!strcmp(argv[i], "-m") && more) {
      max_cycles = strtoull(argv[++i], nullptr, 0);
    } else if (!strcmp(argv[i], "-b") && more) {
      break_at = strtoull(argv[++i], nullptr, 0);
    } else if (!strcmp(argv[i], "-d") && more) {
      disk_path = argv[++i];
    } else if (!strcmp(argv[i], "-w") && more) {
      disk_out = argv[++i];
    } else if (!strcmp(argv[i], "-i") && more) {
      in_path = argv[++i];
    } else if (!strcmp(argv[i], "-P") && more) {
      if (!host_ptr_script_open(argv[++i])) { perror(argv[i]); return 2; }
    } else if (!strcmp(argv[i], "-T") && more) {
      const char *m = argv[++i];
      if (!strcmp(m, "virtual")) virtual_time = true;
      else if (!strcmp(m, "real")) virtual_time = false;
      else usage();
    } else if (!strcmp(argv[i], "-g") && more) {
      const char *m = argv[++i];
      if (!strcmp(m, "none")) gfx = false;
      else if (!strcmp(m, "window") || !strcmp(m, "sdl")) gfx = true;
      else usage();
    } else if (!strcmp(argv[i], "-F") && more) {
      ppm = argv[++i];
    } else if (!strcmp(argv[i], "-r") && more) {
      if (!fb_parse_geometry(argv[++i], &fb_w, &fb_h)) usage();
    } else if (!strcmp(argv[i], "-z") && more) {
      scale = atoi(argv[++i]);
      if (scale < 1 || scale > 8) usage();
    } else if (!strcmp(argv[i], "-N") && more) {
      if (!net_host_open(argv[++i])) return 2;
    } else if (!strcmp(argv[i], "-H")) {
      hold = true;
    } else if (argv[i][0] != '-' && !path) {
      path = argv[i];
    } else {
      usage();
    }
  }
  if (!path) usage();
  stx_load(path, &img);
  if (img.dls_size > DLS_KIB * 1024 || img.ils_size > ILS_KIB * 1024) {
    fprintf(stderr, "strata-rtl: %s needs %u KiB of D-LS and %u KiB of I-LS; this build has %u and %u\n", path,
            (img.dls_size + 1023) / 1024, (img.ils_size + 1023) / 1024, DLS_KIB, ILS_KIB);
    return 2;
  }
  disk = stx_disk_load(disk_path, &disk_blocks);
  if (disk_blocks > DISK_WORDS / 64) {
    fprintf(stderr, "disk image has %llu blocks; this build holds %d\n", (unsigned long long)disk_blocks,
            DISK_WORDS / 64);
    return 2;
  }
  plat_build_fb(plat, NCORES, DISK_WORDS / 64, fb_w, fb_h, CTAB_DEF, NXMAP, DLS_KIB, ILS_KIB); /* rtl/strata_pkg.sv CTAB */
  if (!host_input_open(in_path)) { perror("input"); return 2; }
  host_clock_start();
  host_display_init(gfx, scale, ppm, fb_w, fb_h);
  host_scan = scan_fb;
  host_scan_fetch = scan_fetch;
  host_scan_us = 33333; // repaints read memory through DPI: at most ~30 Hz

  ctx = std::make_unique<VerilatedContext>();
  top = std::make_unique<Vstrata_top>(ctx.get());

  top->uart_rxd = 1;
  top->ext_t3_wready = 0;
  top->ext_t3_rvalid = 0;
  top->ext_t3_rdata = 0;
  top->ext_t3_done = 0;
  top->clk = 0;
  top->rst = 1;
  for (int i = 0; i < 4; i++) {
    top->clk = !top->clk;
    top->eval();
  }
  top->rst = 0;

  t3_scope = svGetScopeFromName("TOP.strata_top.g_t3_int.u_t3");
  if (!t3_scope) fprintf(stderr, "warning: no system-memory scope; PRESENT will show nothing\n");

#ifdef __EMSCRIPTEN__
  (void)hold;
  return web_start();             // the browser's worker clocks the machine from here on
#endif
  while (!top->all_halted && (!max_cycles || cycles < max_cycles)) {
    sim_cycle();
    if ((cycles & 8191) == 0) {   // now and then: terminal input, window events
      host_poll();
      net_host_poll();
      if (host_quit) break;
    }
  }
  if (hold && top->all_halted) host_hold();
  top->final();
  fflush(stdout);
  if (trace_file) fclose(trace_file);
  bool all_halted = top->all_halted;
  if (disk_out) stx_disk_save(disk_out, disk, disk_blocks);
  top.reset();   // (the model goes before its context, and both before the
  ctx.reset();   // run time's own statics: not left to the exit-time destructors)

  if (host_quit) {
    fprintf(stderr, "window closed after %llu cycles\n", cycles);
    return faulted ? 1 : 0;
  }
  if (!all_halted) {
    fprintf(stderr, "timeout after %llu cycles\n", cycles);
    return 1;
  }
  fprintf(stderr, "total cycles: %llu\n", cycles);
  return faulted ? 1 : 0;
}
