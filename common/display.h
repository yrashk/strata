/* Strata prototype: the host side of the console input, the timer clock and
 * the framebuffer window, shared by the emulator (emu/emu.c) and the RTL
 * harness (sim/main.cpp) so both machines behave identically. Header-only;
 * include it from exactly one translation unit.
 *
 * Console input. Bytes come from one input source (the -i file, or stdin,
 * which is put in character mode when it is a terminal) and from the
 * window's keyboard, into one queue. Nothing here ever blocks: the source is
 * polled with select(). When the source is exhausted and the queue is empty
 * the console reads 0x04 forever. At a terminal or in the window, Ctrl-C is
 * not input: it is counted in host_breaks for the console break port.
 *
 * Display (live scanout). The first write into the framebuffer window
 * (host_fb_touch, called by the simulator's write path) or the first
 * host_present() opens a window (SDL2) unless the display is off (-g none,
 * or the build has no SDL: -DNO_SDL). The window shows the framebuffer
 * memory as it is now, scaled by -z: host_pump() repaints it from the live
 * memory (host_scan, kept current by the optional host_scan_fetch hook) at
 * most every host_scan_us of host wall-clock time, and only when something
 * was written since the last repaint; it is also repainted on expose and at
 * once on PRESENT ("this frame is complete"). Closing it sets host_quit.
 * host_finish() (registered with atexit by host_display_init) writes the
 * last presented frame as a binary PPM when -F was given.
 *
 * Keyboard (window focused), as a terminal would send it: printable
 * characters as themselves; Enter 0x0A, Backspace 0x7F, Tab 0x09, Escape
 * 0x1B; arrows ESC [ A/B/C/D (up, down, right, left); Home ESC [ H; End
 * ESC [ F; Delete ESC [ 3 ~; Page Up/Down ESC [ 5 ~ / ESC [ 6 ~; Ctrl+letter
 * 1..26 except Ctrl+C, which is the break key; Alt+key = ESC, then the key.
 *
 * Pointer. The host side of the pointer device (DEV_POINTER, see
 * platform.h): the current position and buttons, and a bounded queue of
 * events fed by the window's mouse, the browser page (web/web.c) or a
 * script (-P file). Consecutive moves coalesce into one, consecutive wheel
 * turns add up, and when the queue is full the oldest move makes room, so
 * button and wheel events are never dropped before moves. The host cursor
 * is hidden over the window once the guest has read the device (software
 * that uses the pointer draws its own). */
#ifndef STRATA_DISPLAY_H
#define STRATA_DISPLAY_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/select.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "platform.h"

#ifndef NO_SDL
#define SDL_MAIN_HANDLED
#include <SDL.h>
#endif

/* ------------------------------------------------------------ time */

static struct timespec host_t0;

/* Host wall-clock microseconds since host_clock_start(). */
static inline uint64_t host_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)(t.tv_sec - host_t0.tv_sec) * 1000000u + (uint64_t)((t.tv_nsec - host_t0.tv_nsec) / 1000);
}
static inline void host_clock_start(void) { clock_gettime(CLOCK_MONOTONIC, &host_t0); }

/* ------------------------------------------------------------ console input */

#define HOST_INQ 4096
static uint8_t host_inq[HOST_INQ];
static int host_in_head, host_in_cnt;
static int host_in_fd = -1;      /* the input source, -1 once exhausted */
static bool host_in_tty;         /* the source is an interactive terminal */
static int host_breaks;          /* Ctrl-C presses not yet given to the break port */
#ifdef __EMSCRIPTEN__
static bool host_in_page;        /* console input comes from the page, not from a file */
#endif
static volatile bool host_quit;  /* the window was closed: end the run */
static uint64_t host_in_taken;   /* console bytes the guest has taken so far (pointer scripts: kN) */

static struct termios host_saved_tio;
static bool host_tio_changed;

static void host_restore_tty(void) {
  if (host_tio_changed) tcsetattr(STDIN_FILENO, TCSANOW, &host_saved_tio);
}

static inline void host_in_push(uint8_t b) {
  if (host_in_cnt == HOST_INQ) return; /* typed far ahead: drop */
  host_inq[(host_in_head + host_in_cnt) % HOST_INQ] = b;
  host_in_cnt++;
}

/* Input from `path`, or from stdin when path is NULL (a terminal is put in
 * character mode and the guest does the echoing; Ctrl-C becomes the break
 * key). Returns false if the file cannot be opened. */
static inline bool host_input_open(const char *path) {
#ifdef __EMSCRIPTEN__
  if (!path) { host_in_page = true; return true; } /* the page pushes keys (web/web.c); no stdin */
#endif
  if (path) {
    host_in_fd = open(path, O_RDONLY);
    return host_in_fd >= 0;
  }
  host_in_fd = STDIN_FILENO;
  if (isatty(STDIN_FILENO) && !tcgetattr(STDIN_FILENO, &host_saved_tio)) {
    struct termios t = host_saved_tio;
    t.c_lflag &= ~(tcflag_t)(ECHO | ECHONL | ICANON | ISIG); /* bytes as typed; Ctrl-C is ours */
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    if (!tcsetattr(STDIN_FILENO, TCSANOW, &t)) {
      host_tio_changed = true;
      host_in_tty = true;
      atexit(host_restore_tty);
    }
  }
  return true;
}

/* Takes whatever the input source has ready, without waiting. */
static inline void host_poll_input(void) {
#ifdef __EMSCRIPTEN__
  if (host_in_fd < 0) return; /* the page is the input source: nothing to poll */
#endif
  while (host_in_fd >= 0 && host_in_cnt < HOST_INQ) {
    fd_set fs;
    struct timeval tv = {0, 0};
    FD_ZERO(&fs);
    FD_SET(host_in_fd, &fs);
    if (select(host_in_fd + 1, &fs, NULL, NULL, &tv) <= 0) return;
    uint8_t buf[256];
    int room = HOST_INQ - host_in_cnt;
    ssize_t n = read(host_in_fd, buf, (size_t)(room < 256 ? room : 256));
    if (n <= 0) { /* end of the input */
      if (host_in_fd != STDIN_FILENO) close(host_in_fd);
      host_in_fd = -1;
      return;
    }
    for (ssize_t i = 0; i < n; i++) {
      if (host_in_tty && buf[i] == 3) host_breaks++; /* Ctrl-C is not input */
      else host_in_push(buf[i]);
    }
    if (host_in_tty) return; /* a terminal: one read per poll is plenty */
  }
}

/* ------------------------------------------------------------ display */

static uint8_t host_frame[FB_SIZE]; /* the last presented framebuffer contents (for -F) */
static unsigned host_fb_w = FB_DEF_WIDTH, host_fb_h = FB_DEF_HEIGHT; /* the geometry (-r) */
static bool host_presented;         /* anything presented yet */
static unsigned host_presents;      /* PRESENTs so far (the browser build repaints on a change) */
static bool host_gfx = true;        /* false: -g none */
static int host_scale = 1;          /* -z */
static const char *host_ppm;        /* -F */

/* Live scanout. host_scan points at the framebuffer window's memory (the
 * emulator's T3 + FB_BASE), or at a copy that host_scan_fetch(lo, hi)
 * brings up to date for the byte range [lo, hi) of it (the RTL harness).
 * The write path reports writes with host_fb_touch(); the dirty byte range
 * [host_dirty_lo, host_dirty_hi) is what changed since the last repaint. */
static const uint8_t *host_scan;
static void (*host_scan_fetch)(uint32_t lo, uint32_t hi);
static uint32_t host_dirty_lo = UINT32_MAX, host_dirty_hi;
static bool host_want_window;       /* something was drawn: open the window at the next pump */
static uint64_t host_scan_us = 20000; /* minimum host time between live repaints */
static uint64_t host_scan_next;     /* host_us() of the earliest next live repaint */

/* Bytes of the framebuffer window the display scans out. */
static inline uint32_t host_fb_bytes(void) { return host_fb_w * 4 * host_fb_h; }

/* A write of `len` bytes at byte offset `off` of the framebuffer window. */
static inline void host_fb_touch(uint32_t off, uint32_t len) {
  if (!host_gfx) return;
  host_want_window = true;
  uint32_t end = host_fb_bytes();
  if (off >= end) return; /* outside the scanned-out part */
  uint32_t hi = len > end - off ? end : off + len;
  if (off < host_dirty_lo) host_dirty_lo = off;
  if (hi > host_dirty_hi) host_dirty_hi = hi;
}

/* Brings the scanout copy up to date (the dirty range); clears the range. */
static inline void host_scan_sync(void) {
  if (host_dirty_lo < host_dirty_hi && host_scan_fetch) host_scan_fetch(host_dirty_lo, host_dirty_hi);
  host_dirty_lo = UINT32_MAX;
  host_dirty_hi = 0;
}

/* ------------------------------------------------------------ pointer */

static uint64_t host_ptr_q[PTR_QLEN]; /* queued events, packed as the EVENT port returns them */
static int host_ptr_head, host_ptr_cnt;
static unsigned host_ptr_x, host_ptr_y, host_ptr_btn; /* the pointer now */
static bool host_ptr_in;         /* the pointer is over the display */
static bool host_ptr_used;       /* the guest has read the device: hide the host cursor */

static inline uint64_t host_ptr_pack(int kind, int wy, int wx) {
  return (uint64_t)host_ptr_x | (uint64_t)host_ptr_y << 16 | (uint64_t)host_ptr_btn << 32 |
         (uint64_t)(uint8_t)wy << 40 | (uint64_t)(uint8_t)wx << 48 | (uint64_t)kind << 56;
}
static inline int host_ptr_kind(uint64_t e) { return (int)(e >> 56); }

/* Removes the oldest queued move, if there is one. */
static inline bool host_ptr_drop_move(void) {
  for (int i = 0; i < host_ptr_cnt; i++)
    if (host_ptr_kind(host_ptr_q[(host_ptr_head + i) % PTR_QLEN]) == PTR_MOVE) {
      for (int k = i; k + 1 < host_ptr_cnt; k++)
        host_ptr_q[(host_ptr_head + k) % PTR_QLEN] = host_ptr_q[(host_ptr_head + k + 1) % PTR_QLEN];
      host_ptr_cnt--;
      return true;
    }
  return false;
}

/* Queues an event of `kind` at the current position and buttons. */
static inline void host_ptr_event(int kind, int wy, int wx) {
  if (host_ptr_cnt) {
    uint64_t *last = &host_ptr_q[(host_ptr_head + host_ptr_cnt - 1) % PTR_QLEN];
    if (kind == PTR_MOVE && host_ptr_kind(*last) == PTR_MOVE) { *last = host_ptr_pack(kind, 0, 0); return; }
    if (kind == PTR_WHEEL && host_ptr_kind(*last) == PTR_WHEEL &&
        ((*last ^ host_ptr_pack(kind, 0, 0)) & 0xffffffffffull) == 0) { /* same place and buttons: add up */
      int y = (int8_t)(*last >> 40) + wy, x = (int8_t)(*last >> 48) + wx;
      y = y > 127 ? 127 : y < -127 ? -127 : y;
      x = x > 127 ? 127 : x < -127 ? -127 : x;
      *last = host_ptr_pack(kind, y, x);
      return;
    }
  }
  if (host_ptr_cnt == PTR_QLEN && !host_ptr_drop_move()) return; /* (sixteen button and wheel events unread) */
  host_ptr_q[(host_ptr_head + host_ptr_cnt) % PTR_QLEN] = host_ptr_pack(kind, wy, wx);
  host_ptr_cnt++;
}

static inline void host_ptr_pos(int x, int y) {
  host_ptr_x = x < 0 ? 0 : x >= (int)host_fb_w ? host_fb_w - 1 : (unsigned)x;
  host_ptr_y = y < 0 ? 0 : y >= (int)host_fb_h ? host_fb_h - 1 : (unsigned)y;
}
/* The pointer entered (or left) the display. */
static inline void host_ptr_enter(bool in) {
  if (in == host_ptr_in) return;
  host_ptr_in = in;
  host_ptr_event(in ? PTR_ENTER : PTR_LEAVE, 0, 0);
}
/* The pointer is at (x, y), in framebuffer pixels. */
static inline void host_ptr_move(int x, int y) {
  unsigned ox = host_ptr_x, oy = host_ptr_y;
  host_ptr_pos(x, y);
  if (!host_ptr_in) { host_ptr_enter(true); return; } /* (the enter event carries the position) */
  if (ox != host_ptr_x || oy != host_ptr_y) host_ptr_event(PTR_MOVE, 0, 0);
}
/* Button b (0 left, 1 right, 2 middle) went down or up. */
static inline void host_ptr_button(int b, bool down) {
  unsigned nb = down ? host_ptr_btn | 1u << b : host_ptr_btn & ~(1u << b);
  if (b < 0 || b > 2 || nb == host_ptr_btn) return;
  host_ptr_btn = nb;
  host_ptr_event(PTR_BUTTON, 0, 0);
}
/* The wheel turned: dy > 0 away from the user (up), dx > 0 to the right. */
static inline void host_ptr_wheel(int dy, int dx) {
  dy = dy > 127 ? 127 : dy < -127 ? -127 : dy;
  dx = dx > 127 ? 127 : dx < -127 ? -127 : dx;
  if (dy || dx) host_ptr_event(PTR_WHEEL, dy, dx);
}

/* The device's side: an event is queued; take it; the STATE register. */
static inline bool host_ptr_ready(void) { return host_ptr_cnt > 0; }
static inline uint64_t host_ptr_pop(void) {
  uint64_t e = host_ptr_q[host_ptr_head];
  host_ptr_head = (host_ptr_head + 1) % PTR_QLEN;
  host_ptr_cnt--;
  host_ptr_used = true;
  return e;
}
/* STATE as the guest reads it; host_ptr_state() also notes that it did. */
static inline uint64_t host_ptr_peek(void) {
  return (uint64_t)host_ptr_x | (uint64_t)host_ptr_y << 16 | (uint64_t)host_ptr_btn << 32 |
         (uint64_t)host_ptr_cnt << 40 | (uint64_t)host_ptr_in << 56;
}
static inline uint64_t host_ptr_state(void) {
  host_ptr_used = true;
  return host_ptr_peek();
}

/* -P file: scripted pointer input, for tests. One event per line:
 *   WHEN move X Y | down B | up B | wheel DY [DX] | enter | leave
 * B is left, right, middle or 0, 1, 2. WHEN says when the event happens:
 * N = once the machine has run N steps (emulator) or clock cycles (RTL);
 * kN = once the guest has taken N bytes of console input (to follow a -i
 * script). Lines happen in file order, each as soon as its WHEN holds and
 * the lines before it have happened. '#' starts a comment. */
typedef struct { bool keyed; uint64_t at; int op, a, b; } HostPtrLine;
static HostPtrLine *host_ptr_script;
static int host_ptr_nscript, host_ptr_iscript;

static inline bool host_ptr_script_open(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return false;
  char line[256];
  int ln = 0;
  while (fgets(line, sizeof line, f)) {
    char when[32], op[16], a[16] = "", b[16] = "";
    ln++;
    char *hash = strchr(line, '#');
    if (hash) *hash = 0;
    int n = sscanf(line, "%31s %15s %15s %15s", when, op, a, b);
    if (n <= 0) continue;
    HostPtrLine l = {when[0] == 'k', strtoull(when + (when[0] == 'k'), NULL, 0), 0, 0, 0};
    static const char *const btn[] = {"left", "right", "middle"};
    l.a = atoi(a);
    l.b = atoi(b);
    for (int i = 0; i < 3; i++)
      if (!strcmp(a, btn[i])) l.a = i;
    if (n >= 4 && !strcmp(op, "move")) l.op = PTR_MOVE;
    else if (n >= 3 && !strcmp(op, "down")) l.op = PTR_BUTTON, l.b = 1;
    else if (n >= 3 && !strcmp(op, "up")) l.op = PTR_BUTTON, l.b = 0;
    else if (n >= 3 && !strcmp(op, "wheel")) l.op = PTR_WHEEL;
    else if (n >= 2 && !strcmp(op, "enter")) l.op = PTR_ENTER;
    else if (n >= 2 && !strcmp(op, "leave")) l.op = PTR_LEAVE;
    else { fprintf(stderr, "%s:%d: not a pointer event\n", path, ln); fclose(f); return false; }
    host_ptr_script = (HostPtrLine *)realloc(host_ptr_script, (size_t)(host_ptr_nscript + 1) * sizeof l);
    host_ptr_script[host_ptr_nscript++] = l;
  }
  fclose(f);
  return true;
}

/* Lines of the script still to happen; the next one waits for a step count. */
static inline bool host_ptr_script_left(void) { return host_ptr_iscript < host_ptr_nscript; }
static inline bool host_ptr_script_stepped(void) {
  return host_ptr_script_left() && !host_ptr_script[host_ptr_iscript].keyed;
}
/* The step (cycle) count the next line waits for, 0 if it waits for none. */
static inline uint64_t host_ptr_script_at(void) {
  return host_ptr_script_stepped() ? host_ptr_script[host_ptr_iscript].at : 0;
}

static inline void host_ptr_script_do(void) {
  HostPtrLine *l = &host_ptr_script[host_ptr_iscript++];
  switch (l->op) {
  case PTR_MOVE: host_ptr_move(l->a, l->b); break;
  case PTR_BUTTON: host_ptr_button(l->a, l->b != 0); break;
  case PTR_WHEEL: host_ptr_wheel(l->a, l->b); break;
  case PTR_ENTER: host_ptr_enter(true); break;
  case PTR_LEAVE: host_ptr_enter(false); break;
  }
}
/* Lets every line whose time has come happen; `now` = steps or cycles so far. */
static inline void host_ptr_script_run(uint64_t now) {
  while (host_ptr_script_left()) {
    HostPtrLine *l = &host_ptr_script[host_ptr_iscript];
    if ((l->keyed ? host_in_taken : now) < l->at) return;
    host_ptr_script_do();
  }
}

#ifndef NO_SDL
static SDL_Window *host_win;
static SDL_Renderer *host_ren;
static SDL_Texture *host_tex;
static bool host_sdl_failed;
#endif

/* True while the window is open (so keys and Ctrl-C can still arrive). */
static inline bool host_window_open(void) {
#ifndef NO_SDL
  return host_win != NULL && !host_quit;
#else
  return false;
#endif
}

#ifdef __EMSCRIPTEN__
/* In the browser the page's terminal and canvas are always there (an input
 * file, -i, is for the tests under node and ends like any file). */
static inline bool host_input_live(void) { return host_in_page || host_in_fd >= 0; }
static inline bool host_break_live(void) { return host_in_page; }
static inline bool host_ptr_live(void) { return host_in_page || host_ptr_script_stepped(); }
#else
/* More console input may still arrive. */
static inline bool host_input_live(void) { return host_in_fd >= 0 || host_window_open(); }
/* A Ctrl-C may still arrive. */
static inline bool host_break_live(void) { return (host_in_tty && host_in_fd >= 0) || host_window_open(); }
/* A pointer event may still arrive (a script line that waits for console
 * input to be taken is not counted: only the guest can make it happen). */
static inline bool host_ptr_live(void) { return host_window_open() || host_ptr_script_stepped(); }
#endif

/* Console input byte for the guest: the next queued byte, 0x04 once the
 * input is exhausted, or -1 if nothing is there yet. */
static inline int host_getc(void) {
  if (!host_in_cnt) host_poll_input();
  if (host_in_cnt) {
    int c = host_inq[host_in_head];
    host_in_head = (host_in_head + 1) % HOST_INQ;
    host_in_cnt--;
    host_in_taken++;
    return c;
  }
  return host_input_live() ? -1 : 0x04;
}

static void host_write_ppm(void) {
  if (!host_ppm) return;
  if (!host_presented) { fprintf(stderr, "no frame was presented; %s not written\n", host_ppm); return; }
  FILE *f = fopen(host_ppm, "wb");
  if (!f) { perror(host_ppm); return; }
  fprintf(f, "P6\n%u %u\n255\n", host_fb_w, host_fb_h);
  for (unsigned y = 0; y < host_fb_h; y++)
    for (unsigned x = 0; x < host_fb_w; x++) {
      const uint8_t *p = host_frame + y * host_fb_w * 4 + x * 4; /* B, G, R, unused */
      uint8_t rgb[3] = {p[2], p[1], p[0]};
      fwrite(rgb, 1, 3, f);
    }
  fclose(f);
}

static void host_finish(void) {
  host_write_ppm();
#ifndef NO_SDL
  if (host_win) {
    SDL_DestroyTexture(host_tex);
    SDL_DestroyRenderer(host_ren);
    SDL_DestroyWindow(host_win);
    host_win = NULL;
    SDL_Quit();
  }
#endif
}

static inline void host_display_init(bool gfx, int scale, const char *ppm, unsigned w, unsigned h) {
  host_fb_w = w;
  host_fb_h = h;
  host_gfx = gfx;
  host_scale = scale < 1 ? 1 : scale;
  host_ppm = ppm;
  atexit(host_finish);
}

#ifndef NO_SDL
static void host_paint(void) {
  if (!host_win) return;
  SDL_UpdateTexture(host_tex, NULL, host_scan ? host_scan : host_frame, (int)host_fb_w * 4);
  SDL_RenderClear(host_ren);
  SDL_RenderCopy(host_ren, host_tex, NULL, NULL);
  SDL_RenderPresent(host_ren);
}

static bool host_open_window(void) {
  if (host_win) return true;
  if (host_sdl_failed) return false;
  if (SDL_Init(SDL_INIT_VIDEO) != 0) {
    fprintf(stderr, "no window: %s\n", SDL_GetError());
    host_sdl_failed = true;
    return false;
  }
  host_win = SDL_CreateWindow("Strata", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                              (int)host_fb_w * host_scale, (int)host_fb_h * host_scale, SDL_WINDOW_ALLOW_HIGHDPI);
  if (host_win) host_ren = SDL_CreateRenderer(host_win, -1, 0);
  if (host_ren) {
    SDL_RenderSetLogicalSize(host_ren, (int)host_fb_w, (int)host_fb_h);
    host_tex = SDL_CreateTexture(host_ren, SDL_PIXELFORMAT_RGB888 /* XRGB8888 */, SDL_TEXTUREACCESS_STREAMING,
                                 (int)host_fb_w, (int)host_fb_h);
  }
  if (!host_tex) {
    fprintf(stderr, "no window: %s\n", SDL_GetError());
    if (host_ren) SDL_DestroyRenderer(host_ren);
    if (host_win) SDL_DestroyWindow(host_win);
    host_win = NULL;
    host_ren = NULL;
    host_sdl_failed = true;
    SDL_Quit();
    return false;
  }
  SDL_StartTextInput();
  return true;
}

static void host_key_bytes(const char *s, bool alt) {
  if (alt) host_in_push(0x1b);
  for (; *s; s++) host_in_push((uint8_t)*s);
}

/* A key press that SDL_TEXTINPUT does not cover. */
static void host_keydown(const SDL_KeyboardEvent *k) {
  SDL_Keycode sym = k->keysym.sym;
  Uint16 mod = k->keysym.mod;
  bool ctrl = mod & KMOD_CTRL, alt = mod & KMOD_ALT, shift = mod & KMOD_SHIFT;
  if (mod & KMOD_GUI) return; /* Cmd/Win combinations belong to the host */
  const char *seq = NULL;
  switch (sym) {
  case SDLK_RETURN: case SDLK_KP_ENTER: seq = "\n"; break;
  case SDLK_BACKSPACE: seq = "\x7f"; break;
  case SDLK_TAB: seq = "\t"; break;
  case SDLK_ESCAPE: seq = "\x1b"; break;
  case SDLK_UP: seq = "\x1b[A"; break;
  case SDLK_DOWN: seq = "\x1b[B"; break;
  case SDLK_RIGHT: seq = "\x1b[C"; break;
  case SDLK_LEFT: seq = "\x1b[D"; break;
  case SDLK_HOME: seq = "\x1b[H"; break;
  case SDLK_END: seq = "\x1b[F"; break;
  case SDLK_DELETE: seq = "\x1b[3~"; break;
  case SDLK_PAGEUP: seq = "\x1b[5~"; break;
  case SDLK_PAGEDOWN: seq = "\x1b[6~"; break;
  default: break;
  }
  if (seq) { host_key_bytes(seq, alt); return; }
  if (ctrl && sym >= SDLK_a && sym <= SDLK_z) {
    if (sym == SDLK_c) { host_breaks++; return; } /* the break key */
    char b[2] = {(char)(sym - SDLK_a + 1), 0};
    host_key_bytes(b, alt);
    return;
  }
  if (alt && !ctrl && sym >= 32 && sym < 127) { /* text input is suppressed while Alt is held */
    static const char plain[] = "`1234567890-=[]\\;',./", shifted[] = "~!@#$%^&*()_+{}|:\"<>?";
    char ch = (char)sym;
    bool caps = (mod & KMOD_CAPS) != 0;
    if (ch >= 'a' && ch <= 'z') { if (shift != caps) ch = (char)(ch - 'a' + 'A'); }
    else if (shift) {
      const char *p = strchr(plain, ch);
      if (p) ch = shifted[p - plain];
    }
    char b[2] = {ch, 0};
    host_key_bytes(b, true);
  }
}

/* The mouse, in framebuffer pixels whatever the window's scale. */
static void host_mouse_at(void) {
  int mx, my, ww, wh;
  SDL_GetMouseState(&mx, &my);
  SDL_GetWindowSize(host_win, &ww, &wh);
  if (ww > 0 && wh > 0) host_ptr_move(mx * (int)host_fb_w / ww, my * (int)host_fb_h / wh);
}
static void host_mouse_button(const SDL_MouseButtonEvent *b) {
  int n = b->button == SDL_BUTTON_LEFT ? 0 : b->button == SDL_BUTTON_RIGHT ? 1 : b->button == SDL_BUTTON_MIDDLE ? 2 : -1;
  host_mouse_at();
  if (n >= 0) host_ptr_button(n, b->state == SDL_PRESSED);
}
#endif

/* Live scanout: opens the window once something was drawn, and repaints it
 * from the framebuffer memory if it changed and the last repaint is at
 * least host_scan_us old (`now` forces it). */
static inline void host_scan_out(bool now) {
#ifndef NO_SDL
  if (!host_gfx) return;
  if (!host_win) {
    if (!host_want_window || !host_open_window()) return;
    now = true;
  }
  if (!now && host_dirty_lo >= host_dirty_hi) return;
  uint64_t t = host_us();
  if (!now && t < host_scan_next) return;
  host_scan_sync();
  host_paint();
  uint64_t cost = host_us() - t; /* a slow fetch (the RTL's DPI reads) repaints less often */
  host_scan_next = host_us() + (host_scan_us > 4 * cost ? host_scan_us : 4 * cost);
#else
  (void)now;
#endif
}

/* Handles window events: keys, repaint, close; repaints the live
 * framebuffer now and then. Call it regularly. */
static inline void host_pump(void) {
#ifndef NO_SDL
  host_scan_out(false);
  if (!host_win) return;
  static bool hidden;
  if (host_ptr_used && !hidden) { /* the guest draws its own cursor from now on */
    hidden = true;
    SDL_ShowCursor(SDL_DISABLE);
  }
  SDL_Event e;
  while (SDL_PollEvent(&e)) {
    switch (e.type) {
    case SDL_QUIT: host_quit = true; break;
    case SDL_WINDOWEVENT:
      if (e.window.event == SDL_WINDOWEVENT_CLOSE) host_quit = true;
      else if (e.window.event == SDL_WINDOWEVENT_EXPOSED || e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED ||
               e.window.event == SDL_WINDOWEVENT_RESTORED)
        host_paint();
      else if (e.window.event == SDL_WINDOWEVENT_ENTER) host_mouse_at();
      else if (e.window.event == SDL_WINDOWEVENT_LEAVE) host_ptr_enter(false);
      break;
    case SDL_MOUSEMOTION: host_mouse_at(); break;
    case SDL_MOUSEBUTTONDOWN: case SDL_MOUSEBUTTONUP: host_mouse_button(&e.button); break;
    case SDL_MOUSEWHEEL: {
      int f = e.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1;
      host_mouse_at();
      host_ptr_wheel(f * e.wheel.y, f * e.wheel.x);
      break;
    }
    case SDL_TEXTINPUT:
      if (SDL_GetModState() & (KMOD_CTRL | KMOD_ALT | KMOD_GUI)) break; /* handled as key presses */
      for (const char *s = e.text.text; *s; s++) host_in_push((uint8_t)*s);
      break;
    case SDL_KEYDOWN: host_keydown(&e.key); break;
    default: break;
    }
  }
#endif
}

/* PRESENT, "this frame is complete": records the frame (for -F) and
 * repaints the window at once. `fb` holds the scanned-out part of the
 * framebuffer window: the emulator's live memory, or the RTL harness's
 * scanout copy right after a full read (so nothing in it is stale). */
static inline void host_present(const uint8_t *fb) {
  memcpy(host_frame, fb, host_fb_bytes());
  host_presented = true;
  host_presents++;
#ifndef __EMSCRIPTEN__ /* (the browser's painter, web_paint, takes the dirty range itself) */
  if (fb == host_scan) {
    host_dirty_lo = UINT32_MAX;
    host_dirty_hi = 0;
  }
#endif
#ifndef NO_SDL
  if (host_gfx) {
    host_want_window = true;
    host_scan_out(true);
    host_pump();
  }
#endif
}

/* -H: once the machine has stopped, keep the window up (repainting it when
 * asked) until the user closes it or presses Escape or q in it. */
static inline void host_hold(void) {
#ifndef NO_SDL
  if (host_quit) return;
  host_scan_out(true); /* the final memory contents (opens the window if something was drawn) */
  if (!host_window_open()) return;
  fflush(stdout);
  fprintf(stderr, "all cores halted; close the window (or press Escape or q in it) to exit\n");
  while (!host_quit) {
    SDL_Event e;
    if (!SDL_WaitEventTimeout(&e, 100)) continue;
    switch (e.type) {
    case SDL_QUIT: host_quit = true; break;
    case SDL_WINDOWEVENT:
      if (e.window.event == SDL_WINDOWEVENT_CLOSE) host_quit = true;
      else host_paint();
      break;
    case SDL_KEYDOWN:
      if (e.key.keysym.sym == SDLK_ESCAPE || e.key.keysym.sym == SDLK_q) host_quit = true;
      break;
    default: break;
    }
  }
#endif
}

/* Everything the host does now and then: input, window events. Cheap to
 * call often: it does the work at most every 2 ms. */
static inline void host_poll(void) {
  static uint64_t last;
  uint64_t t = host_us();
  if (t - last < 2000) return;
  last = t;
  host_poll_input();
  host_pump();
}

#endif
