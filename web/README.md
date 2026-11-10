# web: strata-emu in the browser

The play page (`site/play/`, https://yrashk.com/strata/play/) runs the same
C emulator as the desktop, compiled to WebAssembly with Emscripten, with a
WebAssembly JIT. Nothing is simulated in JavaScript: the page paints and
forwards input, a Web Worker runs the machine.

```bash
make wasm           # build/web/: strata-emu.js/.wasm, images/, demos/
make web-site       # build/web-site/: the whole site, the play page under play/
python3 -m http.server --directory build/web-site   # then /play/ (?run=os|osws|ws|gfx|forth|hello|mandel, ?jit=0)
make test-wasm      # the wasm build under node against the native interpreter, and the JIT fuzzer
```

## Structure

- **`web/web.c`** includes `emu/emu.c` (one translation unit: it sees the
  whole machine). `emu.c`'s `main()` sets the machine up with the desktop
  flags and returns through `web_start()` in front of its run loop. From
  then on the worker calls `web_run(ms)`: it runs `machine_round()` (the
  desktop loop's round) for a slice and returns 0 (call again at once), a
  number of milliseconds to sleep (every core waits on a device: the next
  timer or VSYNC deadline), or < 0 (stopped). Exports: `web_input`,
  `web_break`, `web_pointer` (the canvas's mouse), `web_pointer_used`,
  `web_paint` (changed rows as RGBA to `Module.webPaint`), `web_stop`,
  `web_finish`, `web_stat`.
- **`site/play/worker.js`** owns the module and talks to the page with
  postMessage: output bytes, painted rows (transferred), status one way;
  input, Ctrl-C, pointer events the other. Idle is a `setTimeout` to the
  next deadline; busy is a MessageChannel hop (not clamped to 4 ms).
- **`site/play/play.js`** paints and sends input only: an xterm terminal,
  the canvas keyboard (the desktop window's key mapping) and mouse, the
  presets, Reset (a fresh worker), the JIT toggle. The framebuffer is
  scaled by whole device pixels where it can (Auto/Fill/1x/2x, full
  screen); StrataOS presets get a framebuffer size that fits the panel.
  Asset URLs carry the build's commit (`tools/web-stamp.sh`) so a browser
  never mixes two deploys.
- **`common/display.h`**, under `__EMSCRIPTEN__`: no stdin (the page pushes
  keys); input and the break key are always live. Built with `-DNO_SDL`.
- **`tools/wasm-run.js`** runs the same module under node with the desktop
  flags (the tests).

## Networking

The page's Network menu sets the network interface's far end
(`common/net.h` under `__EMSCRIPTEN__`, `site/play/net.js`, shared by the
worker and the node tests):

- **test peer + DNS over HTTPS** (`-N peer`, the default): the built-in
  peer answers pings and its `*.test` names; every other DNS query the
  guest sends goes to the page (`Module.webDns`), which asks Cloudflare's
  JSON API (`https://cloudflare-dns.com/dns-query`, else Google's
  `https://dns.google/resolve`) and builds a real DNS answer (A and CNAME
  records) for `web_net_dns`. So `host example.com` works in the page;
  pings and TCP go to the peer.
- **link to my other tabs** (`-N web`): every packet the guest sends goes
  to `Module.webNetTx`, which posts it on a `BroadcastChannel`; the page's
  other tabs that chose the same receive it (`web_net_rx`). The tabs agree
  on host numbers first (a hello and a 300 ms wait: the lowest number
  nobody has) and pass it to the guest (`web_net_hint`, STATUS bits
  31..26), so the machines are 10.0.0.1, 10.0.0.2, ...
- **relay** (`-N web,nat`): a WebSocket to the URL the user types (none by
  default; the page says that every packet goes through it), one binary
  message per IPv4 packet both ways. `tools/netrelay` (built by `make`) is
  such a relay: the simulators' user-mode NAT (`common/netnat.h`) behind a
  small WebSocket server on 127.0.0.1:8765 (`-p`, `-a`, `-f
  HOSTPORT:GUESTPORT`), so the browser's machine is 10.0.2.15 on the real
  network, DNS at 10.0.2.3.

`make test-wasm` checks the first with a stubbed fetch and the third
against a local `netrelay`; the tab link was checked by hand in a browser.

## Speed

The emulator has three gears, all exact (the reference interleaving is kept
with `-j -T virtual`):

1. A **predecoded fast loop** (`run_fast` in `emu.c`) for the plain integer
   subset, with a per-core decoded I-LS cache invalidated by `tgetx`; it
   also runs while device reads are pending (it checks their D-LS hazard
   range). User-mode cores run ahead in bursts and sit out the rounds they
   used (`user_burst`), so a StrataOS boot keeps its exact interleaving.
2. **`step()`** for everything that meets other cores or devices.
3. The **WebAssembly JIT** (`emu/jit/jit_wasm.c`, see `emu/jit/README.md`):
   regions of hot basic blocks become one wasm function each, instantiated
   against the emulator's own memory; tail calls when the browser has them.

Measured on an M-series Mac in Chromium: the Forth gfx demo (335M
instructions) in 0.07 s with the JIT (about 5,100 MIPS), 0.43 s
interpreted; StrataOS `spin` at about 4,700 MIPS; the ws demo at 60 paints
per second. The status line's MIPS is instructions per wall second, so an
idle, VSYNC-paced machine shows little.

## Limitations

- Regions are found per hot pc and may overlap; past a per-core limit the
  core's translations are flushed.
- Without tail calls every region-to-region transfer returns to the C
  dispatcher (correct, slower).
- The Pages workflow pins Emscripten 3.1.74; local builds have used newer
  ones.
