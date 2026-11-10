ws: runnable (`make boot`, type `ws`; Alt = Esc prefix: Alt+Enter term, Alt+P palette, Alt+1..4 focus, Alt+Q close, Alt+Shift+Q quit)

# WS design: the rendering half of the window server (working plan)

Owner: the "WS design" agent. Owns os/lib/gfx.s, os/lib/font/, os/ws/,
site/img/ws-*.png and the `ws-*` block of the Makefile. Scratch:
`build/ws/`, `build/ws-shots/` (see PLAN.md
"Agent working locations").

## Plan

- [x] Font: os/lib/font/gen_font.py (own design, public domain): an 8x16
  body font (ASCII 32..126 + ▸ · › ◂ ■ and a few HUD glyphs), a 5x7 small-caps
  HUD font, generated into os/lib/font/font.s.
- [x] os/lib/gfx.s: surface descriptors, transfer stubs (cap register as
  data), the strip renderer (display list of items, active list per strip,
  double-buffered D-LS strips, one tput per strip when rows are contiguous),
  standard items (fill, blend, chamfered edge, chamfered panel, text,
  scaled text, blit, grid, vertical gradient), immediate wrappers.
- [x] os/ws/theme.s: palette and metrics.
- [x] os/ws/model.s: the data the renderers read (cores, processes,
  windows, focus, palette state); filled by a data source.
- [x] os/ws/layout.s: 1–4 tiles, gaps, status strip; slide interpolation.
- [x] os/ws/damage.s: damage rect list (merge, overflow → bounding box);
  commit = render every rect through the scene, one PRESENT.
- [x] os/ws/scene.s: builds the display list from the model (background,
  lattice strip, tiles, overlay).
- [x] os/ws/frame.s: tile frame (cut corners, luminous edge, amber focus
  glow, HUD tag with ▸ and KiB moved).
- [x] os/ws/lattice.s: core cells, hues, pulses; clock, uptime, procs, sw/s.
- [x] os/ws/palette.s: dimmed screen, `launch ›` line, completion list.
- [x] os/ws/splash.s: STRATA as layered bands that settle.
- [x] os/ws/term.s: terminal grid, the 2.6 subset, renderer into a surface.
- [x] os/ws/wsdemo.s: bare-metal demo with fake data (term transcript,
  wmandel, wclock, 4th tile), timeline, keys, SHOT mode.
- [x] Makefile block: `make ws-demo`, `make ws-shots`.
- [x] Iterate on the visuals (look at the PNGs).
- [x] Performance numbers: full frame, terminal line, lattice pulse.
- [x] Copy the best shots to site/img/ws-*.png.
- [x] os/ws/README.md: module boundaries, what remains for the kernel.
- [x] Tick the rendering-side boxes of PLAN.md step 6; the "WS design" row
  in PLAN.md now lists only build/ws*, this file (scratch deleted).

## Kernel integration (done; os/ws/README.md "The real server")

- [x] hw layer from GRANT_FB / the clock / tty raw; CATCH. (hw_os.s)
- [x] data source from proc CORES / PS / SCHED (ws.s ds_*; fake.s stays for the demo).
- [x] protocol 40–46 and the message loop (ws.s); clients term / wmandel /
  wclock (os/progs/), client library os/lib/wsclient.s.
- [x] disk + Makefile (WSPROGS), tools/test-ws.sh in `make test`,
  site/img/ws-real-{desktop,palette,focus}.png.
- [ ] not exercised yet: TEXT / FILL / TITLE (no client uses them), Alt+arrows,
  the interactive SDL window (only scripted -i input was run), the RTL.
- [ ] fold this file into os/ws/README.md and delete it.

## Notes

- GFX_STRIPB is 2560 now (two 2.5 KiB strips; a full-width row is two slices):
  `ws` and `term` need the D-LS. Frames are identical to the 5120 ones.
- `make ws-check` must stay green: damage-driven frames == full redraws.
- Fonts: original designs (gen_font.py), public domain.
- OS version shown everywhere: StrataOS 0.1 (user decision).
