# Plat: art specification (first playable version)

The art of `plat` (os/progs/plat.s), a city-building game: the player
zones land, lays roads and power lines, and a town grows by itself. All
of it is original and is drawn by one deterministic script,
`tools/plat-art.py` (Python 3, standard library only, no external files,
no randomness that is not seeded), which writes the PNG files named
below into this directory. `tools/plat-assets.py` will later convert them.

This file covers the first playable version. Later versions add rail,
services, overlays and events in the same style.

## Originality

Plat has its own look. Do not imitate the tiles, icons, colours or
layouts of any existing city-building game; in particular nothing may
resemble the 1989 classic of the genre or the open-source release of its
code. No text in the art except the `PLAT` logo.

## How the art is shown

The map is a grid of **cells of 16 x 16 pixels**, seen from above. The
game shows it at 1x (a cell is 16 x 16 screen pixels) and at 2x (32 x 32,
every pixel a 2 x 2 block). It is pixel art: crisp, readable at 1x, no
anti-aliasing, no dithering noise, no gradients of many colours.

**View:** straight from above with a slight tilt: roofs are seen from
above, and a building shows its south face (the face towards the bottom
of the screen) as a strip 2 to 8 pixels tall, taller for taller
buildings. Light comes from the top left: every building and tree casts
a short shadow (1 to 3 pixels, longer for taller buildings) to the
right and down, painted as a darker shade of the ground it falls on.
Everything stays inside its own footprint: nothing overhangs into the
neighbouring cells.

**Mood:** a bright, sunny, tidy small town; fresh and cheerful, not
cartoonish. Distinctive colour choices:
- ground: a warm, slightly yellow spring green with sparse small tufts
  and tiny flowers (two or three shades);
- water: deep teal blue, lighter near the shore, a few short white-blue
  ripple marks; the shore is a 2-pixel band of pale sand on the water
  side;
- roads: warm grey asphalt with a cream kerb line, a dashed pale-yellow
  centre line on straight pieces;
- homes: terracotta, coral and slate-blue roofs, cream and white walls,
  green gardens;
- shops and offices: teal glass, cream stone, striped awnings in
  mustard, coral and mint, paved lots;
- industry: ochre, rust and concrete grey, round tanks, saw-tooth roofs,
  chimneys, packed-earth yards.

## Rules for every file

- PNG, 8-bit RGBA, exactly the size given. Alpha is 0 or 255, nothing
  between. Cell pictures and zone pictures are **opaque**; only icons,
  the logo and the marks are transparent where said.
- One master palette of **at most 200 opaque colours** for all files
  together (the game needs the rest of its 256 for map overlays). The
  script also writes `palette.png` (one pixel per colour, 16 a row) and
  prints how many colours it used.
- Dark outlines are a dark shade of the neighbouring colour, never pure
  black.
- Pieces that join (water, roads, lines, ground) must join seamlessly
  with each other and with plain ground on every side.

## Terrain

| File | Size | What |
|---|---|---|
| `ground_0.png` .. `ground_3.png` | 16 x 16 | plain ground, four variants that tile with each other in any arrangement |
| `dirt.png` | 16 x 16 | bulldozed, cleared earth (light brown, a few pebbles) |
| `rubble_0.png` `rubble_1.png` | 16 x 16 | broken bricks and dust on cleared earth |
| `woods_0.png` .. `woods_3.png` | 16 x 16 | the cell covered by round tree crowns (two or three trees, varied), ground showing between; any arrangement of the four next to each other and next to plain ground looks natural |
| `water.png` | 16 x 47*16 | 47 water cells in one column, top to bottom, see below |

**Water joins.** For a water cell, let the mask be the sum of these bits
for each neighbour that is also water: N = 1, NE = 2, E = 4, SE = 8,
S = 16, SW = 32, W = 64, NW = 128, where a diagonal bit counts only if
both cardinal neighbours beside it are water (otherwise it is cleared).
That leaves 47 distinct masks. `water.png` holds them in ascending order
of the mask value (mask 0, a lone pond cell, first; mask 255, open water,
last). Each is drawn so that the shore (sand, then grass) appears on the
sides and corners where the neighbour is land, and open water continues
where it is water; mask 255 has no shore at all. The script also writes
`water_masks.txt`: one line per tile, the mask in decimal.

## Roads and power lines

For roads and lines the mask is 4 bits, one for each cardinal neighbour
that connects: N = 1, E = 2, S = 4, W = 8.

| File | Size | What |
|---|---|---|
| `road.png` | 16 x 16*16 | 16 road cells in a column, mask 0 to 15 in order: mask 0 a short stub, 5 (N+S) and 10 (E+W) straight, the rest bends, T-junctions and the crossing; on plain ground at the edges not used by the road |
| `bridge.png` | 32 x 16 | two cells side by side: a road bridge over open water running E-W, then N-S (railings, the water showing beside) |
| `line.png` | 16 x 16*16 | 16 power-line cells in a column, mask 0 to 15: thin dark cables with a wooden pole (a small cross-arm seen from above, its short shadow) at the centre of the cell, on plain ground |
| `line_road.png` | 32 x 16 | a line crossing a road: the line runs N-S over an E-W road, then E-W over a N-S road (poles beside the road, not on it) |
| `line_water.png` | 32 x 16 | a line over open water, E-W then N-S (no pole, only the cables) |

## Zones and buildings

Zones are 3 x 3 cells (48 x 48 pixels); the coal plant is 4 x 4 (64 x
64). The game cuts each picture into cells. Every picture is opaque and
its outer pixels look right next to plain ground, roads and each other.

The three kinds of zone each have their own colour, used for the empty
lot's markings and as an accent in its buildings:
- **homes:** green (a fresh leaf green, distinct from the ground);
- **shops and offices:** blue (a clear sky blue);
- **industry:** amber (a warm yellow-orange).

| File | Size | What |
|---|---|---|
| `zone_<k>_empty.png` | 48 x 48 | the zoned, empty lot: the ground with a dashed boundary 1 pixel inside the edge in the zone's colour, small stakes at the corners, and in the centre a 12 x 12 emblem in the zone's colour on a pale disc: a house for homes, a shopping bag for shops, a cog for industry |
| `zone_<k>_site.png` | 48 x 48 | building under way: the lot with foundations, a little scaffold, a pile of materials, the zone's colour on a fence or barrier |
| `zone_<k>_<n>_a.png`, `_b.png`, n = 1..4 | 48 x 48 | the lot built up to density n, in two different designs a and b |

`<k>` is `res`, `com` and `ind`. The four densities:

- **res:** 1: four or five small detached houses with gardens and a tree
  or two; 2: a terrace of townhouses and small houses, a little shared
  green; 3: two or three low apartment blocks with balconies and a
  courtyard; 4: one or two tall apartment towers (long south faces and
  long shadows) with a small plaza.
- **com:** 1: a corner shop and a café with awnings, a few parked cars;
  2: a row of shops and a small office building, a car park; 3: a mid-rise
  office block and a department store with a roof garden; 4: one or two
  glass towers with a forecourt and a fountain.
- **ind:** 1: a small workshop and a yard with crates; 2: a warehouse with
  a saw-tooth roof, a loading bay, a lorry; 3: a factory with a chimney
  and two round tanks; 4: a big plant with several chimneys, tanks and
  pipes.

Each density should be visibly denser and taller than the one before,
and a and b clearly different buildings in the same spirit.

| File | Size | What |
|---|---|---|
| `coal_0.png` `coal_1.png` | 64 x 64 | the coal power plant: a boiler hall, two tall chimneys, a coal heap, a fence; frame 1 differs only in the smoke puffs over the chimneys (they drift), so the two frames alternate as an animation |

## Marks (transparent, drawn over cells by the game)

| File | Size | What |
|---|---|---|
| `nopower.png` | 16 x 16 | a lightning bolt in yellow inside a red circle with a diagonal bar: the zone has no power (it blinks) |
| `noroad.png` | 16 x 16 | a small road sign shape with a red cross: no road reaches the zone |

## The tool column and the bar

The tool column is 64 pixels wide, on the left of the window; the bar is
32 pixels tall at the bottom. The game draws their flat backgrounds; the
script writes the colours it chose for them into `ui_colours.txt`
(lines `name RRGGBB`: `panel`, `panel_light`, `panel_dark`, `text`,
`text_dim`, `good`, `bad`, `res`, `com`, `ind`), from the master palette.
The panel is a calm, slightly warm off-white or pale stone; the text dark.

| File | Size | What |
|---|---|---|
| `button.png` `button_down.png` | 28 x 28 | a tool button, raised and pressed (rounded, 1-pixel light top-left edge, dark bottom-right edge); transparent outside the rounded corners |
| `tool_<name>.png` | 20 x 20 | transparent icons drawn on the button; `bulldoze` (a small yellow bulldozer), `road` (a piece of road with a centre line), `line` (a power pole with cables), `res` (a house, green accent), `com` (a shop front, blue accent), `ind` (a factory, amber accent), `coal` (a chimney with smoke and a lightning bolt), `query` (a magnifying glass) |
| `speed_<name>.png` | 12 x 12 | transparent: `pause` (two bars), `slow` (one triangle), `normal` (two), `fast` (three) |
| `icon_funds.png` `icon_date.png` `icon_pop.png` | 12 x 12 | transparent: a coin, a calendar page, a little figure |
| `logo.png` | 160 x 48 | transparent: the word `PLAT` in chunky, friendly capitals of the game's own design (not a font copied from anywhere), with a small street-grid motif worked into it, in road grey, ground green and the three zone colours |
| `app.png` | 32 x 32 | the game's icon: a tiny town block from above |

## Contact sheets (for looking the art over)

The script also writes, each with the file names under the pictures:
- `sheet_terrain.png`: ground, dirt, rubble, woods, all 47 water cells
  (with their masks), the roads, bridges and lines, at 2x;
- `sheet_zones.png`: every zone picture and the plant at 2x, a row per
  kind;
- `sheet_ui.png`: the buttons with each tool icon on them, the speeds,
  the bar icons, the marks, the logo and the app icon, at 3x, on the
  panel colour;
- `sample_town.png`: **a small town composed from the cells**, 40 x 24
  cells (640 x 384 pixels) at 1x: a lake with a shore and a bridge
  across a narrow arm of it, woods, a road grid, power lines from the
  coal plant along the roads, homes at every density, shops in the
  middle, industry beside the plant, one empty lot of each kind, one
  site of each kind, a `nopower` mark on one zone, some bulldozed
  ground and rubble; plus the tool column (64 pixels, the eight tool
  buttons in two columns, `road` pressed) on its left and the bar (32
  pixels, with the speed and bar icons and a demand indicator of three
  short bars in the zone colours) below, so the whole is 704 x 416;
- `sample_town_2x.png`: the middle 20 x 12 cells of the same town at 2x.

The sample towns must be built only from the cell pictures above, cut
and placed as the game will place them: they are the proof that the
pieces join.
