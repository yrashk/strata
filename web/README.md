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

The same build runs the web debugger (`site/debug/`, /debug/ on the site):
see "The debugger" below.

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

## The debugger

The web debugger (`site/debug/`) uses the debug engine of `emu/emu.c`
(`emu/debug.c`, compiled into the same module) in one of two places:

- **In the page.** `site/debug/dbg-worker.js` loads `../play/strata-emu.js`,
  writes an example's image, its map (`sasm -g`) and the sources the map
  names into the module's file system (`make wasm` copies the examples of
  `DEBUG_EXAMPLES` to `build/web/debug/`), and starts it with `--debug wasm
  -j -T virtual` (deterministic, so time travel works). Then it relays the
  page's requests to `web_dbg(line)`, runs `web_dbg_run(ms)` while the
  machine runs (0: call again; > 0: idle; < 0: stopped) and posts
  `web_dbg_events()` (console output, stops) to the page. The protocol is
  the desktop's: [`doc/debug-protocol.md`](../doc/debug-protocol.md).
  `tools/wasm-dbg.js` drives the same exports under node (`make test-dbg`).
  **StrataOS** (the picker's first entry, `?ex=os`) boots the play page's
  `images/bootrom.stx` and `disk.img` on 8 cores with `--os /os`: `make
  wasm` copies the kernel's and every program's map to `build/web/debug/os/`
  (`prog.txt` lists them). The Run menu types a program's name at the shell,
  with a temporary `pid` breakpoint at its start when asked.
  The console is an xterm and the framebuffer a canvas that opens when the
  guest first draws (the worker calls `web_paint()` as the play page's
  does, and `web_dbg_repaint()` after time travel). Keys and the mouse go
  through the engine's `input`, `ctrl-c` and `pointer` requests, which log
  them, so a recorded GUI run replays with its clicks.
- **Against the desktop.** `strata-emu --debug PORT --www site` serves the
  page and upgrades a WebSocket on the same port; the page asks
  `/dbg-info`, finds the engine and talks to it (`make debug-web`, then
  http://localhost:4444/debug/). `?ws=HOST:PORT` names an engine elsewhere.
  The engine runs the one image it was started with, so the page has no
  program picker then (`make debug-web DEBUG_WEB=hello` for another); the
  picker is the in-page engine's, over the examples `make wasm` copies.
  `make debug-web-os` is the same with StrataOS (`--os build`).

`?ex=NAME&do=...` loads an example and runs a short script (`break:LOC`,
`continue`, `stepi:N`, `round`, `rstepi`, `rcontinue`, `goto:T`, `core:N`,
`watch:LOC:LEN`, `delete`, `wait:MS`): links and screenshots.

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

## The guest's web server in the page

Run `httpd &` in StrataOS on the play page and a panel opens with its site
(ports 80 and 8000 are watched while StrataOS runs). There is no backend:

- **`web/web.c`** exports `web_http_open(port)` (a connection from 10.0.2.2
  to the guest's port: one of `common/netnat.h`'s virtual connections, the
  same TCP relay as `-N nat,fwd=` with buffers instead of a host socket),
  `web_http_send`, `web_http_recv` (bytes, 0 = closed, -1 = not yet),
  `web_http_close` and `web_port_listening(port)` (1 / 0 / -1; a SYN probe
  every 2 s at most, answered with a RST at the SYN-ACK, so the guest's
  server never sees a connection). They work in every network mode; the
  guest's replies to them never leave the machine.
- **`site/play/worker.js`** takes `{t:"http", id, port, request}` and
  answers `{t:"http", id, response}` (or `error` 503: nothing listening,
  504: no answer in 30 s) once the guest closes or Content-Length is
  complete; `{t:"ports"}` answers which ports listen.
- **`site/play/sw.js`**, a Service Worker with scope `play/vm/`: a fetch of
  `vm/PORT/PATH` (`vm/PATH`: port 80) becomes a raw HTTP/1.0 request,
  posted to the play tab that runs the machine (clients.matchAll; the page
  relays it to its worker); the raw response is parsed into a Response.
  Root-relative URLs in HTML and CSS (and Location) are rebased under
  `vm/PORT/`. No play tab running a machine: 502; nothing listening: 503.
- **`site/play/play.js`** asks the worker every 3 s, opens the panel when a
  port starts listening (floating, draggable, resizable; a bottom sheet on
  a phone; reload / open in a new tab / close, which leaves a chip), and
  never takes the focus. The panel's URL opens in another tab of the same
  browser (the Service Worker serves it there too).

`make test-wasm` (web-http) fetches `/` from `httpd` through these calls
under node; the panel, the Service Worker, the rebased style sheet and links,
`/~ps`, a 320 KB file and the 503 for port 8000 were checked in Chrome.

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
