# os/ws: the window server's renderers

Everything the StrataOS window server (`ws`, spec 2.8) draws, used
unchanged by the real server (`ws.s`, below) and its clients, and by a
bare-metal demo with a pretend OS:

```bash
make ws-demo     # in a window: splash, four tiles, palette; keys below
make ws-shots    # build/ws-shots/*.png: splash, slide, desktop, focus, palette
make ws-perf     # instruction counts (= emulator cycles), see below
make ws-check    # damage-driven frames == full redraws, at every shot frame
```

Demo keys (Alt = ESC prefix, spec 1.4): Alt+P or Alt+Space palette (type, Tab,
Up/Down, Enter launches wmandel / wclock / a terminal), Alt+1..4 and
Alt+arrows focus, Alt+Enter a terminal, Alt+Q close the focused tile,
Alt+Shift+Q quit. Other keys are echoed by the focused terminal.

## The idea: draw rows in the Local Store, send them out

Memory is explicit I/O: no store can reach the framebuffer. So nothing is
drawn "in place". The screen (and every client surface) is described by a
*display list* of items; to draw a rectangle, `gfx_render` walks it strip
by strip: the items that meet the strip are collected (an item that covers
the whole strip opaquely drops everything under it), each item's handler
draws its part of each row into a D-LS strip buffer, and the strip leaves
with one `tput` (one per row when the rows are not contiguous). A blit is
a `tget` of the source row straight into the strip: no pixel of a client's
surface ever passes through a register. Damage decides which rectangles
are drawn; every frame is: update the model, clients draw into their
surfaces, damage, rebuild the list (cheap), draw the damage, one PRESENT.

`make ws-check` proves the incremental path: at each checked frame the
picture drawn from damage alone is byte-identical to a full redraw.

## Modules

| File | What | Depends on |
|---|---|---|
| `os/lib/gfx.s` | Surfaces (descriptor: capability register *as data*, offset, w, h, stride), `gfx_render` (strips, active list, occlusion, slices for wide rects, read-back for odd edges), spans (fill, 2-pixel SWAR alpha blend), standard items: rect/blend, vertical gradient, 1-px edge with 45° cut corners, cut-corner panel, grid with crosses, text (8x16 / mini, bold), scaled text, blit; list builder; immediate `gfx_fill` / `gfx_text`; `gfx_lerp` | nothing (a client library) |
| `os/lib/font/gen_font.py` → `font.s` | Two original public-domain fonts: 8x16 body (terminal, palette, clock) and 5x7 small caps (HUD), ASCII + ▸ · › ◂ ■ ▴ ▾ ‹ at 0x80..0x87 | — |
| `theme.s` | palette and metrics | — |
| `model.s` | **the renderers' only input**: cores (pid, flags, pulse), processes (name, hue, core, KiB moved), clock / uptime / switches per second, windows (kind, pid, core, name, surface, current / from / to rects, slide, fade, events), palette state | — |
| `fmt.s` | numbers and strings into HUD buffers | — |
| `damage.s` | damage list (merge on overlap, bounded), `dmg_commit` = draw all + one PRESENT; counters | gfx, model, hw |
| `layout.s` | 1–4 tiles (1 full; 2 side by side; 3 left + two right; 4 2x2), 6-px gaps, even x; slides (12 frames, ease-out) and fade-in; damage exactly old ∪ new places; WE_RESIZE to the client when a slide ends | model, damage |
| `frame.s` | a tile: glow (focused), panel, client blit, fade veil, edge, inner line, tag `▸ TERM · PID 7 · CORE 3`, readout `CTX · 148.2 KIB` | gfx, model, layout |
| `lattice.s` | status strip: wordmark, one cell per core (hue, K = system core, server mark, pulse + halo), window list, UP / PROC / SW/S, clock | gfx, model |
| `palette.s` | Alt+Space overlay: dim, `launch ›` line, prefix completion, selection, key hints | gfx, model |
| `splash.s` | STRATA in eight bands that slide in alternately with trails and settle; rule and subtitle; grid fades in | gfx, model |
| `scene.s` | model → display list (grid, strip, tiles, palette; or the splash); `scn_frame` | all of the above |
| `term.s` | terminal surface: ring grid, spec 2.6 subset parser, dirty rows, resize with history, `term_render` into any surface (the `term` client reuses it) | gfx, font |
| `wmandel.s` | the Mandelbrot client's renderer: `md_step` draws N rows into its surface (a row item), returns what to DAMAGE | gfx |
| `wclock.s` | the clock client's renderer: segment digits with cut ends, 60 second ticks, a line; redraws only its changing band | gfx, fmt |
| `hw_bare.s` | **machine layer**: framebuffer from the platform table, PRESENT, VSYNC, NOW, keyboard reads | — |
| `fake.s` | **data source** for the demo: a pretend 12-core StrataOS with a scheduler | model |
| `wsdemo.s`, `demo_script.s` | the demo's main loop, timeline, scripted shell sessions, keys, perf | everything |

What the real `ws` keeps unchanged: gfx.s, the fonts, theme, model,
fmt, damage, layout, frame, lattice, palette, splash, scene, term (in
`term`), wmandel/wclock renderers (in their clients). What it replaces:
`hw_bare.s` (→ GRANT_FB capabilities, the clock in c7), `fake.s` (→
STATS / PS / INFO), and the demo's main loop (→ a message loop).

## Look: what changed from the brief

- **Status strip 28 px**, not 16: room for the lattice cells (24x14), the
  STRATA wordmark, the window list (`1 TERM 2 WMANDEL ...`, focused in
  amber) and the figures; it ends in a teal line with a faint glow.
- **The KiB-moved readout is a second tag** at the right end of the top
  edge (`CTX · 503.2 KIB`) rather than part of the left tag: the left tag
  stays short and the readout lines up across tiles.
- Tags are **gaps cut into the edge** (background colour behind small caps),
  so the edge appears to pass behind them.
- A faint **inner line** one pixel inside every edge makes it read as lit;
  the focused tile has two outer amber lines (alpha 110, 40) as its glow.
- The grid has small **crosses every 64 px**, aligned with the tile area.
- The **8x16 font is original** (square shoulders, cut corners), not a
  doubled 8x8 font; a **5x7 small-caps font** for every HUD label.
- Splash: the bands **leave faint trails** while travelling; an amber rule
  and the subtitle `STRATAOS 0.1 · WINDOW SERVER · MEMORY IS EXPLICIT I/O`
  appear when they land, and the desktop grid fades in under them.
- Terminal colours: a neon set matched to the palette (bright cyan is the
  accent); the cursor is a cyan block in the focused terminal, teal in the
  others.
- The system core's lattice cell is outlined and marked `K`; a server's
  core has a white corner mark.

## Performance (`make ws-perf`, 1280x800, instructions = emulator cycles)

| Update | Instructions | Pixels |
|---|---|---|
| Full frame (every item: grid, strip, 4 tiles, blits) | 4.55 M | 1 024 000 |
| A terminal line (write, render 2 rows into the surface, composite) | 181 k | 22 104 |
| A lattice pulse (one cell and its halo) | 8.7 k | 504 |

A full frame is 1600 `tput`s of 2.5 KiB plus one `tget` per client row. A
typical desktop frame is a few pulses, a readout and (once a second) the
clock: tens of thousands of instructions.

D-LS: two 2.5 KiB strip buffers (rects wider than 640 pixels are drawn in slices),
the active list 1.5 KiB, the scene 15 KiB (160 items), fonts 2.6 KiB, the
model ~3.3 KiB, strings and damage list ~2 KiB: about 33 KiB for the real `ws` (measured), inside the 40 KiB program
data window of spec 2.2. Code: ~14 KiB for gfx.s and the ws modules (I-LS
programs get 32 KiB from 0x8000).

## The real server (`make boot`, then `ws`)

| File | What |
|---|---|
| `ws.s` | the server: main loop (RECEIVE with a timeout), protocol 40–46, keys, events, windows, the data source (proc CORES / PS / SCHED) |
| `hw_os.s` | machine layer on StrataOS: REGISTER, GRANT_FB, the keyboard buffer (which brings the pointer's events too), and ws's own small kernel interface (it does not include sys.s: no room) |
| `pointer.s` | the cursor and the key help (drawing; also in the demo) |
| `os/lib/wsclient.s` | the protocol for clients: wc_open, wc_band, wc_damage, wc_event, wc_text, wc_fill, wc_title, wc_close |
| `os/progs/{ws,term,wmandel,wclock}.s` | the programs on the disk |

Keys (Alt = ESC prefix): Alt+Enter a terminal; Alt+P or Alt+Space the
palette; Alt+1..4 and Alt+arrows focus; Alt+Q close; Ctrl-C interrupts
the focused window's program; Alt+Shift+Q quit to the shell; Alt+Shift+H
halt; Alt+? the key help (shown when the splash ends; any key or click
dismisses it and goes no further); Alt+Shift+W pauses the keyboard for a
second (scripted input: tools/test-ws.sh).

The pointer: a cursor; a click focuses the tile under it; in the palette a
click runs a program (outside it: closes it) and the wheel moves the
selection; the window under the pointer gets presses, releases, drags and
the wheel (EVENT kinds 6, 7); `term` scrolls back with the wheel.

How it differs from spec 2.8 (the implementation wins):

- **No surface capability.** Memory capabilities are linear, so a surface
  cannot be the client's to write and the server's to read. Surfaces live
  in the server, in the framebuffer window after the screen (2 MiB per
  window; the last 4 MiB for a single full-size tile; the screen must fit
  in 4 MiB). A client draws into a *band* (its whole arena, c0: 168 rows of
  a full-width window) and lends it with DAMAGE through `sys_msga`; the
  server blits it into the surface and returns it with the reply. CREATE
  answers the id and the size only; a resize event carries the new size.
- **Keys reach the server as requests.** ws keeps a second message buffer
  out at tty as a raw READ; its answer is queued by the kernel as a request
  for the core's server (ws), so a key wakes RECEIVE. No polling.
- **Events for a client that blocks elsewhere.** `term` blocks in READ on
  its shell's pipe; it asks (CREATE mode bit 0) to be SIGNALled when events
  wait: the READ returns -2 and it fetches them without blocking. Ctrl-C
  reaches it as the key 0x03 and it SIGNALs its shell. EVENT also takes a
  timeout (length, in ticks): `wclock` sleeps in it until the next second.
- Frames are paced by the RECEIVE timeout (15 ms), not by VSYNC reads.
- The lattice shows what proc's CORES reports four times a second; proc
  itself (running only because it was asked) is not shown, ws's core is.
  No calendar: the clock is the time since boot.
- SET_SCRATCH covers the strips and the scene (24 KiB) only while ws waits
  in RECEIVE: a preemption in the middle of a frame must keep them.
- TEXT, FILL and TITLE are used by `wmandel` (its zoom label and title).
