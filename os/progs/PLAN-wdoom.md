# wdoom: a first-person shooter as a window-server client

A checkbox plan and the reasoning behind the design. The program is
`os/progs/wdoom.s` with its modules in `os/progs/wdoom/`; the data file is
made by `tools/wdoom-assets.py`.

## The limits that shaped it

| Limit | Value | Consequence |
|---|---|---|
| D-LS for a program's data | 40 KiB (0..0x9FFF), of which `sys.s` takes 13 KiB | A 320 x 168 view of 8-bit pixels is 54 KiB: it cannot be resident. The view is drawn in ten **slabs** of 32 columns (5.4 KiB). |
| I-LS for a program's code | 32 KiB from 0x8000, `sys.s` + `wsclient.s` take 7 KiB | No code paging was needed: the game is about 10 KiB of code. |
| The arena (c0) | 832 KiB, all far memory | It holds the assets (421 KiB at its top) and the band (430 KiB). Every texel read is a `tget` of a whole texture column (128 bytes) or sprite column into the D-LS. |
| The band | what is left of the arena | A 2x frame is 860 KiB of XRGB8888, a 3x frame 1.9 MiB: neither fits, so a frame goes to the server in several DAMAGE rectangles: 1 at 1x, 2 at 2x (five slabs each), 5 at 3x (two slabs each). The band holding exactly five 2x slabs is why the far block must stay under 421,888 bytes. |
| The keyboard | a byte stream, no key-up | A key counts as held for a few tics after each byte; the host's key repeat keeps it held. |
| The pointer | events only while a button is held (and presses) | A left press fires; dragging turns. |
| Instructions | the emulator runs hundreds of millions a second; the RTL on an FPGA would run 20 million | Speed on the emulator is not the limit; the figures below say what a frame costs in instructions. |

## Decisions

- **Engine: a grid raycaster**, not a sector engine. Walls are the faces of
  a 32 x 32 grid of cells, all of one height; floor and ceiling are textured
  (one flat each); doors are planes in the middle of a cell that slide
  sideways. A sector engine (floors and ceilings of varying height, BSP or
  portals, visplanes) needs span buffers and clipping arrays for the whole
  view width at once, which the slab scheme does not give, and its code
  would not have left room in the I-LS without paging. A raycaster's column
  is independent of every other, so a slab needs nothing but its own 5 KiB.
- **Resolution: 320 x 200** (a 320 x 168 view over a 32-row status bar, as
  Doom's), scaled by the largest whole factor that fits the tile: 3 in a
  full-screen tile (960 x 600), 1 in half and quarter tiles. Higher
  resolutions are possible on the emulator but the cost is all in pixels
  pushed: a 3x frame is 2.3 MiB written by the client and copied twice more
  by the server.
- **Textures 128 texels to a cell**, stored column-major so that a wall
  column is one transfer. Uniform ones are 64 columns wide and repeat.
- **Light**: a 16-level colour map (4 KiB resident) made from the palette, as
  Doom's COLORMAP; walls and sprites by distance, floor rows by a table.
- **Language: assembly.** The inner loops are a dozen instructions per
  pixel; Forth would have multiplied that.
- **The two flats live in `sys.s`'s `out_buf` and `in_buf`** (4 KiB each):
  the program writes nothing to standard output and never reads standard
  input, and 8 KiB of D-LS is what a second flat pair would have cost.
- **`wdoom demo`** plays a recorded sequence of keys one tic per frame,
  whatever the clock says, and then stands still: the last frame is the
  same on every run, which is what the test compares.

## Plan

- [x] Read the clients, the library and the server's DAMAGE path; measure
- [x] Verify Freedoom's licence (BSD 3-clause, `COPYING.adoc`); choose the subset
- [x] `tools/wdoom-assets.py`: PNG reader, palette matching, textures,
      sprites, flats, the bar, messages in Freedoom's font, palettes,
      sounds, the level, the tables; `wdoom.dat` and `dat.s`
- [x] Renderer: walls, doors, floor and ceiling, light, sprites with a
      depth buffer, the weapon, the bar, scaling, slabs into the band
- [x] Game: movement and collision, doors (with a key), pistol, three
      monsters, fireballs, pickups, messages, death, the exit switch
- [x] `ws`: `ws PROGRAM` starts with that program; the palette knows wdoom
- [x] `wdoom demo`
- [x] A sound device in the machine (`common/sound.h`: `strata-emu -a`, `-A
      FILE`, SDL, the wasm build and the play page; `dev`'s GETSND); a
      four-channel mixer and sixteen sounds in the game
- [x] `make boot-wdoom`, the shell's help, `tools/test-wdoom.sh` in `make test`
- [x] A screenshot, README and site entries, the play page preset
- [x] Frame rates: emulator with and without the JIT, the wasm build

## Measurements

Sizes: the program is 54.6 KiB on the disk: 17.7 KiB of code (10.6 KiB of
it the game: about 2,650 instructions; the rest `sys.s` and `wsclient.s`)
and 36.7 KiB of D-LS data (of the 40 KiB a program may have). `wdoom.dat`
is 431 KiB: 10 KiB resident (tables, directories, the level), 421 KiB far
(textures 192 KiB, sprites 129 KiB, sounds 66 KiB, the bar, flats and
palettes 23 KiB).

Frame rates, `wdoom demo` (one tic a frame, as fast as it goes) in a
full-size tile of a 1280 x 800 screen (the picture three times: 960 x 600),
12 cores, on an Apple M-series host, 2026-11-13:

| Machine | Frames a second |
|---|---|
| `strata-emu`, JIT | 220 to 300 |
| `strata-emu -j` (interpreter) | 3.4 |
| the wasm build under node, JIT | 142 |
| the wasm build under node, interpreter | 3.8 |

In a browser (the play page, JIT on) the game keeps its 35 tics a second
with a frame for each; the machine then runs about 290 million
instructions a second.

What a 3x frame costs in instructions (the difference between two demo
lengths, per frame): about **1.8 million in wdoom** (casting, texturing,
sprites, turning 54,000 indices into 484,000 pixels) and about **6.2
million in `ws`**, which copies the five DAMAGE rectangles into the
window's surface and from there to the screen. On the RTL at an FPGA's 20
MHz that would be 11 frames a second for the game alone and under 3 with
the server's copies: the style fits the machine's memory, but at this
resolution not its speed without the emulator.

## What did not fit, and what is simple

- No varying floor and ceiling heights, no stairs, no sky: a grid
  raycaster (see Decisions). One floor flat and one ceiling flat for the
  whole level: each further pair is 8 KiB of D-LS.
- Monsters have one view (the front): the other rotations of their
  walking and attacking frames would have taken some 350 KiB more of
  sprites, and the arena has none to spare beside the band.
- One weapon, one level. Monsters walk straight at the player and do not
  find their way around walls; they do not block one another.
- Scaling is by whole factors, so the picture is small (320 x 200) in a
  half-width tile of a 1280 x 800 screen.
- The game draws a frame every tic even when nothing moves.
- With no key-up events, a first key press moves for nine tics and then
  waits for the host's key repeat; turning by the pointer needs a button
  held (the server sends moves only then).
- No sound on the RTL (it has no sound device); none during the demo.
