# Web/WASM: strata-emu in the browser — working plan

**Superseded in part by web/PLAN-fast.md (PLAN.md section X):** the
emulator now runs in a Web Worker (site/play/worker.js) driven by
`web_run()`, not from `emscripten_set_main_loop`; there is a WebAssembly
JIT (emu/jit/jit_wasm.c); the build targets worker + node. The notes
below describe the first version.

Summary in PLAN.md section W. Fold this into the docs (README, site) when
integrated, then delete it.

## Structure

- `web/web.c` includes `emu/emu.c` (one translation unit, so it sees the
  machine), stubs out the JIT (`jit_init` returns false; `emu/jit/` is not
  compiled), and drives the rounds from `emscripten_set_main_loop`:
  ~10 ms of interpreter rounds per animation frame, and the frame ends early
  when every live core is blocked. Exports `web_input`, `web_break`,
  `web_stop`, `web_set_budget`, `web_stat`.
- `emu/emu.c`: one guarded hook (`#ifdef __EMSCRIPTEN__ return web_start();`)
  in front of main's run loop. Nothing else changes for the desktop build.
- `common/display.h`, guarded by `__EMSCRIPTEN__`: no stdin (the page pushes
  keys), input and break are always live; plus a `host_presents` counter
  (all builds) so the page repaints after a PRESENT.
- Built with `-DNO_SDL`: the canvas path is in web.c (dirty rows →
  RGBA → `Module.webPaint` → `putImageData`).
- `site/play/`: `index.html`, `play.css`, `play.js` (xterm.js 5.3.0 +
  xterm-addon-fit 0.8.0 from jsdelivr). Each run / Reset is a fresh module
  instance (compiled wasm cached); images are fetched from `images/` and
  written to MEMFS, then `callMain` with the desktop flags.
- Makefile: `web-assets`, `wasm` (→ `build/web/`), `web-site`
  (→ `build/web-site/` = site + play, for local preview).
- CI (`.github/workflows/pages.yml`): setup-emsdk 3.1.74, `make web-assets
  wasm`, `cp -r build/web/. public/play/`.

## Checklist

- [x] emcc build of web.c (no warnings), no JIT, no SDL
- [x] run loop yields every frame; blocked machine idles at ~0 CPU
- [x] stdout byte stream via FS.init → xterm; stderr in amber
- [x] input: xterm onData (CR → LF, ^C → break), canvas keydown (spec 1.4
  mapping), JS-side queue fed as the 4 KiB guest queue drains (paste demos)
- [x] presets os / gfx / forth (+ demo dropdown) / hello / mandel; Reset;
  Ctrl-C; status (MIPS, live/total cores, machine time, instructions)
- [x] terminal sizing: the site's `.terminal` class collided with xterm's
  root element (margin/clip-path) — undone in play.css; fit after the web
  font loads, ResizeObserver, scroll to bottom on output/input
- [x] verified: hello, gfx, Forth REPL + gfx demo, StrataOS boot + ls/ps/
  uptime + Ctrl-C on spin; canvas keyboard; narrow and wide layouts
- [x] native build and compare.sh unaffected
- [ ] first CI deploy checked (emsdk 3.1.74 vs local emcc 7.0.0)

## Run locally

    make web-site && python3 -m http.server --directory build/web-site
    # http://localhost:8000/play/   (?run=os|gfx|forth|hello|mandel)
