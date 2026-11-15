# A city-building game for the window server (proposal)

A proposal and a checkbox plan for a city-building simulation as a client
of `ws`, in the genre the 1989 classic began: the player zones land, lays
roads and power lines, and a city grows by itself from what it is given.
The game has its own name, art, text and identity: it is **Plat**, the
program `plat`, drawn in bright top-down pixel art (style B below).

Nothing here is built yet. The open questions are at the end.

## What is free to use, and what is not

The genre's ideas are general: nobody owns them, and every game of the
kind since 1989 uses them.

- **Free:** a grid map seen from above; three kinds of zone (where people
  live, where they shop and work in offices, where they make things);
  roads, rail and power lines; power plants; growth driven by demand;
  taxes and a yearly budget; city services (police, fire, parks); land
  value, pollution, crime and traffic as maps; time that runs at chosen
  speeds and can be paused; disasters as an idea; a bulldozer; a query
  tool; a mini-map; a demand indicator.
- **Not to be copied:** the original's name, or any name built like it
  (the `Sim-` prefix belongs to its owner's family of trademarks;
  `Micropolis`, the name of the open-source release of its code, is that
  project's own); its logo and box art; its tile graphics and icons; its
  text (messages, the newspaper, the manual, the help); its named
  characters and advisers; its scenarios (their cities, years and goals)
  and the wording or look of its disasters (no city-wrecking monster);
  its sounds; its exact formulas and tables.
- **No code from the open-source release.** That code is GPL-3 with
  terms of its own on the name; the game is designed from the genre's
  general ideas and written here from scratch. Its formulas are our own,
  tuned by playing.
- **The name** is checked against the games and trademarks it might be
  confused with (a web search of the stores and the trademark registers)
  once one is chosen, before anything is published with it.

## Name and identity

Four ideas; each is short enough for an 8-byte window title and a
program name:

| Name | Program | The idea |
|---|---|---|
| **Plat** | `plat` | A plat is the surveyed map of a town's lots and streets. The game looks like a town plan that comes alive: the player draws it, the town fills it in. |
| **Gridley** | `gridley` | A made-up town name that says grid; friendly, a little old-fashioned. The town is called Gridley until the player renames it. |
| **Boroughs** | `boroughs` | The city as its neighbourhoods; the advisers are the borough's own people. |
| **Lampton** | `lampton` | A town whose lights come on as it grows; dusk falls on the map when a year ends and the lit windows are its population. |

**Visual style**, two options (the art decides the game's look more than
anything else, so this is the first thing shown before any building):

- **A. The living town plan** (goes with Plat): ground as warm paper with
  a faint survey grid; water in ink-blue hatching; zones as soft coloured
  washes edged in ink while empty; buildings drawn straight from above as
  roofs with a short shadow to the south-east, in a limited palette
  (brick, slate, sand, sage, ochre); roads as ink-edged grey bands with
  dashed centre lines; power lines as thin dark lines with poles. The
  overlay maps are coloured inks over the same plan. Distinctive, calm,
  readable at 16 pixels, and nothing like the original's look.
- **B. Bright top-down pixel art**: grass, trees and water with texture;
  buildings slightly from above with their front faces showing; brighter
  colours. Closer to what players of the genre expect, and therefore
  closer to the original; easier to drift into imitation.

Chosen: **Plat, with style B**, made our own by its palette, its
buildings and its icons (`os/progs/plat/art/SPEC.md`).

**Voice:** messages come from a small cast of our own (a town clerk who
reports the numbers, an engineer for power and roads, a shopkeeper for
the economy, a resident who writes letters), in short plain sentences
with some dry humour. A yearly front page of the town's own paper sums up
the year.

## Core loop

The player has funds and an empty piece of land with water and woods.

- **Zones** of three kinds, 3 x 3 cells each: homes, shops and offices,
  industry. A zone needs power and a road within reach; then it grows
  (more density, a new building drawn) or declines by demand, land value,
  pollution, crime and traffic.
- **Building:** roads, power lines, a coal plant and later a clean but
  costly plant, police and fire stations, parks, rail later. Each costs
  money; the bulldozer clears.
- **Demand:** three bars (homes, shops, industry). Homes want jobs; shops
  want residents and industry; industry wants workers and a market
  outside the town. Taxes push all three down.
- **Money:** a month's taxes come in; roads and services cost upkeep. At
  the end of a year the budget opens: the tax rate and how much of what
  each service asks for it gets.
- **Maps** (overlays the player switches on): power, land value,
  pollution, crime, traffic, population density, police and fire cover.
- **Time:** pause, slow, normal, fast. A month is a fixed number of
  simulation steps; the date and population are always on the bar.
- **Messages** in the town's voice: no power, a jammed road, high crime,
  the first thousand residents, a budget that will not balance.

## Scope tiers

Each tier ships in stages, each stage playable, tested and landed.

**Tier 1: the first playable town** (about 5,000 lines of assembly, the
art, an asset tool, a test; four or five stages):
- a 128 x 128 map made from a seed (land, a river or lake, woods);
- the view with scrolling (drag with the right button, the arrow keys,
  the wheel) and two zooms (16 and 32 screen pixels a cell);
- a tool column and a status bar (funds, date, population, demand bars);
- tools: bulldoze, road, power line, the three zones, coal plant, query;
- simulation: power, zone growth and decline by demand and road access,
  the census, monthly taxes at a rate set with two keys, upkeep, a
  yearly summary;
- pause and three speeds, a dozen messages, a few sounds;
- saving and loading one city to the file system;
- `plat demo N` and the test.

**Tier 2: the fuller city** (about 5,000 lines more; three or four
stages; needs code paging, see below):
- traffic: trips from each zone along the roads to a zone of the kind it
  needs, traffic density, jams; rail;
- pollution, land value and crime as maps that feed growth;
- police and fire stations with funding and cover, parks;
- the overlay maps and a mini-map that jumps the view;
- the budget window at the year's end; the clean power plant;
- advisers and the town paper; an opinion of the mayor; graphs of the
  last years;
- several saved cities, each file with attributes (name, population,
  year, funds).

**Tier 3: stretch goals** (each a stage of its own, roughly 1,000 to
2,000 lines):
- events that hit the town, named and written our own way: fire that
  spreads, flood, earthquake, a plant failure, a storm (no monster);
- scenarios: our own invented towns, each with a problem and a goal;
- a terrain editor (land, water, woods) before the first building;
- a city gallery: the saved cities found with a query on their tag and
  sorted by their attributes, each with a small map;
- the town's history through the file system's snapshots: go back to
  any year's end;
- the pointer seen without a button held (a small change in `ws` for a
  window that asks for it), so the cell under the pointer is outlined
  before a click;
- dusk at the end of a year with lit windows (style "Lampton");
- the play page preset (could also come with tier 1, see the
  questions).

## The machine's limits that shape it

From `wdoom` and `kira` (`PLAN-wdoom.md`, `PLAN-kira.md`) and the
library:

| Limit | Value | Consequence |
|---|---|---|
| D-LS for a program's data | 40 KiB, of which `sys.s` takes 13 KiB | The map (32 KiB) and the coarse maps (about 25 KiB) live in far memory; a step fetches the rows it works on. |
| I-LS for code | 32 KiB from 0x8000; `sys.s` and `wsclient.s` take 7 KiB | Tier 1 fits (kira is 4,700 lines and 23.7 KiB of code). Tier 2 will not: the simulation's passes, the budget, saving and the events become code units paged in by the kernel (`os/progs/units.s` shows how: `.far`, `xcall`, about 600 cycles a miss on the RTL, nothing after that). |
| The arena (c0) | 832 KiB | The data file's far block (177 KiB) and the map (32 KiB) are at its top; the rest is the band, 124 rows of a 1280-pixel window. If the coarse maps of tier 2 make the band too small, they go into an extra arena from `proc` (MORE). |
| DAMAGE | a rectangle (x, y, w, h, stride) of the band | Changed cells are sent as rectangles, not whole rows; a step that changes ten buildings sends ten small rectangles, not the window. |
| Pointer | presses, releases, moves while a button is held, the wheel | Tools act on press and drag; no outline under a pointer that is only moving (see tier 3). |
| Keyboard | a byte stream, no key-up | Everything the mouse does the keys do too: arrows move a cell cursor, Space applies the tool. |
| Speed | the emulator runs hundreds of millions of instructions a second; the RTL on an FPGA would run 20 million | The simulation is cheap; a full redraw is not on the RTL (below). |

## Technical design

**View.** Straight from above, cells of 16 x 16 pixels in the art, drawn
at 1x or 2x (the zoom). In a full-size tile of a 1280 x 800 screen, less
a 64-pixel tool column and a 32-pixel bar, that is about 75 x 46 cells at
1x and 37 x 23 at 2x. Isometric was weighed and not chosen: drawing order
over neighbouring cells, picking the cell under the pointer and redrawing
one changed cell all get harder, and the plan style wants a map seen from
above.

**Drawing.** The game draws XRGB8888 at the window's own size (not
wdoom's and kira's 320 x 200 scaled up: a city needs the pixels). Cells
are palette indices (256 bytes a cell picture, at most 1,024 pictures,
256 KiB at the most, far); a row of cells is drawn into a D-LS strip of
16 rows, turned into pixels through the palette (or an overlay's palette:
a map overlay is a second palette and a tint, not new art) and sent into
the band with `tput`. Three ways a frame starts:
- a scroll or zoom: everything, in pieces of as many rows of cells as the
  band holds (seven at 16 pixels a cell: seven DAMAGE rectangles for a
  full window);
- a tool or a simulation step: only the cells it changed, as the one
  rectangle that holds them all;
- the bar and the tools: their own rectangles.
Nothing is drawn when nothing changed.

What it costs, from wdoom's measurements (a 960 x 600 frame: 1.8 million
instructions in the game, 6.2 million in `ws`): a full 1216 x 768 redraw
about 2 million in the game and 10 million in `ws`, a few hundred frames a
second with the JIT, a few a second without it, steady in the browser; on
the RTL at 20 MHz under one full redraw a second, but a month's changed
cells are a small fraction of that.

**The map.** 128 x 128 cells of 16 bits (32 KiB): the cell's picture (10
bits) and flags (conducts power, powered, the centre of a zone or a
building, burns, can be bulldozed, has a road). Zone and building centres
keep their state in their picture number, as the genre does, so that a
zone is one cell to read. The coarse maps are bytes at a half (64 x 64:
population density, traffic, pollution, land value, crime; 4 KiB each)
and an eighth (16 x 16: police and fire cover, growth); the power map is
a bit a cell, 2 KiB, resident.

**The simulation.** Deterministic: one random generator seeded at the
start, saved with the city, never read from the clock during a step. A
month is sixteen steps; each step runs one slice of the work, so no step
is long:
- steps 1 to 8: the map in eight bands of 16 rows: each zone centre is
  updated (powered? a road in reach? a trip that finds its destination
  in tier 2? grow, decline or stay, from the demand of its kind and the
  coarse maps); building animations;
- step 9: power, a flood fill from the plants over conducting cells into
  the power bitmap;
- steps 10 to 13: the coarse maps, each from the census of the scan and
  smoothed once (traffic decays, pollution spreads, land value from
  distance to the centre, water, woods, pollution and crime);
- step 14: service cover (each station's radius, scaled by its funding);
- step 15: the census, demand, the month's money;
- step 16: messages; at the end of a year, the budget and the summary.
Each step works on a band of map rows fetched with `tget` (256 bytes a
row) and writes them back with `tput`. An estimate for a full month on a
grown 128 x 128 town: a few million instructions, a millisecond on the
emulator, a fraction of a second on the RTL. At "fast" a month passes in
about a second.

**Tools and keys.** The tool column holds icons; the left button applies
the tool (a click for a building, a drag for a road or a line, cell by
cell, a dragged rectangle for zones), the right button drags the map, the
wheel scrolls, and a click on the mini-map jumps. Keys: arrows move the
cell cursor (the view follows it), Space applies the tool once, Enter
puts the pen down (the tool is applied on every cell the cursor moves
to) or lifts it, `B` bulldoze, `R` road, `L` power line, `I` or `?` ask,
`1` `2` `3` the zones, `P` plant, `Z` zoom, `Tab` the next overlay, `0`
pause, `-` `=` slower and faster, `S` save, `Q` quit (as in wdoom and
kira; Esc is the start of the arrows' sequences and cannot be a key of
its own).

**Text.** Numbers, messages and the budget need words: the server's font
(`wc_text`), over the panel's colour, in the bar; only the text that
changed is sent. The icons carry no text.

**Sound.** Synthesised by the asset tool, as kira's: a tool click, a
road's crunch, a zone placed, the bulldozer, coins at a month's end, a
chime for a milestone, a warning tone, later a siren. Played through
wdoom's mixer (`os/progs/wdoom/sound.s`); none on a machine without the
sound device, none in a demo.

**Saving.** A city is one file in the `city` directory (tagged `city`),
named by the player (default: the town's name): a header (format
version, the seed and the generator's state, the date, funds, tax rate,
funding, the last years' history) and the 32 KiB map; the coarse maps
are computed again on loading. The file gets attributes: the town's
name, population, year, funds. Writing follows kira's garden (`kira/garden.s`,
`gd_save`): look up `fs`, write, close, back to `ws`. The gallery
(tier 3) is a QUERY on the tag with those attributes.

**Code.** Assembly, as wdoom and kira, in `os/progs/plat.s` and
`os/progs/plat/`; the art drawn by `tools/plat-art.py`, converted with
the sounds and tables by `tools/plat-assets.py` into `plat.dat` and
`dat.s`. From tier 2 the passes of the simulation, the budget, saving
and loading, and the events are code units in `.far`.

## Art

Original pixel art made for this game, drawn by one deterministic script
(`tools/plat-art.py`, Python 3, standard library), as kira's is. The
specification is written first (`os/progs/plat/art/SPEC.md`: sizes,
palette, style, every picture and its frames, contact sheets), and the
script is made from it by Codex with the Astra model (`codex exec -m
gpt-6-astra`), asked for high precision and quality. The contact sheets
(at 1x and 2x, on plain ground and in a sample town) are shown to the
user and approved **before any game code is built on them**; then the
asset tool converts them.

What the art has (tier 1 about 250 cell pictures, tier 2 about 450): the
ground, water edges and woods (with the transitions between them), roads
in their 16 joins and their crossings with lines and rail, power lines,
three zones each at an empty stage and four or five sizes of building
(several pictures of each size so streets do not repeat), plants, the
services, the tool icons, the cursor, the bar's parts, overlay legends.

Permissively licensed sets (some city tiles are released as CC0) were
weighed: they would not have this game's look, rarely cover all the
transitions, and each needs its licence checked and kept with the files.
Original art avoids both.

## Testing

- **Deterministic simulation.** `plat demo N` starts from a fixed seed,
  plays a recorded list of keys (a cell cursor and tool keys, so the
  keyboard builds the town) one per frame, then runs a given number of
  months as fast as it goes, prints the census (residents, shops,
  industry, funds, date) to standard output, and stands still.
  `tools/test-plat.sh` (one line in `tools/tests.sh`) builds a small
  town (a road grid, power, zones), checks the census after a year and
  after five, and the CRC of the window in the frame, as the wdoom and
  kira tests do.
- **Saving round-trips.** A demo that saves, quits, starts again, loads,
  and prints the census and a checksum of the map and the state: the same
  as before saving, and after N more months the same as a run that never
  saved.
- **Same result everywhere.** The census line is the same under the
  interpreter, the JIT and the wasm build.
- **The pointer and sound**, as kira's second session: a scripted drag
  that draws a road, a sound in the WAV.
- **Measured and written here:** frame rates (JIT, interpreter, wasm),
  the cost of a month in instructions, sizes.

## Tier 1 as built

- The map is 16-bit cells: a picture's number in the low ten bits, flags
  the simulation keeps in the top ones (power; a zone's road and its
  mark). The kind of a picture (road, water, zone, ...) is a table in the
  data file. A road's or a line's picture is chosen by the neighbours it
  joins (16 of each; lines join zones and plants), and water's by its
  eight neighbours (47 pictures); a tool remakes the cell and its
  neighbours. Bridges and lines over the water have a picture for each of
  the 47 water cells (the asset tool lays the bridge's or the line's own
  pixels over each), so a crossing keeps its banks.
- A road crosses a power line, and a line a road, only where the other
  runs straight, and across it.
- The land: a river from the top edge to the bottom one, one to three
  lakes, 16 to 25 clumps of woods; the random numbers start from the
  clock, a demo's from a fixed seed.
- Zones are 3 x 3 on clear land (woods are cleared with them), the coal
  plant 4 x 4; the bulldozer clears a whole zone or plant.
- Once a month (`plat/sim.s`): power spreads breadth first from the
  plants over lines, zones and plants (a ring of 2,048 cells in the D-LS
  the land's bitmaps used; a coal plant powers 50 zones); each zone's
  middle is visited: with power and a road on the ring two cells out, an
  empty zone becomes a site when its kind is in demand, a site its first
  density, a built zone grows by chance with the demand and declines
  without power or a road or when it is little wanted; the census counts
  residents (homes) and jobs (shops and offices, industry) by density;
  demand: homes want twice the jobs, shops a quarter of the residents and
  a fifth of the industry's jobs, industry a third of the residents and a
  market outside the town; taxes above 7 % lower all three. Taxes (tax /
  40 a resident and tax / 60 a job each month) and upkeep (a road 1 a
  year, a bridge 5, a line 1, a plant 112) move the treasury; January says
  last year's; milestones at 500, 2,000, 10,000 and 50,000 residents.
- A zone without power or a road has a mark over its middle (no road
  first); the bar shows the three demands as bars.
- Zoom: cells of 4, 8, 16, 32 and 64 pixels (every fourth, every second,
  each pixel once, twice, four times); at 4 the whole map is in view; the
  map is centred in the window when it is smaller.
- Tooltips: the window asks `ws` for the pointer's moves with no button
  held (CREATE mode bit 1, new in `ws`); over a button or a part of the
  bar a tooltip says what it is and its key, drawn by the server's font
  beside it, and the cells under it are drawn again when it goes.
- The town is kept in `/ws/plat-N.sav` (a header and the map), loaded at
  the start and saved on quit or with S; the file gets the attributes
  population, year and funds (`attr /ws/plat-1.sav`).
- Sizes: the program is 59 KiB on the disk: 24.5 KiB of code (of 32; tier
  2 needs code units, as planned) and 34.4 KiB of D-LS data (of 40).
  `plat.dat` is 179 KiB: 582 cell pictures 146 KiB, sprites 17 KiB, six
  sounds 14 KiB. About 4,700 lines of assembly of its own.

## Plan

- [x] Read wdoom, kira, the client library, DAMAGE, code units; this
      proposal
- [x] The name (Plat) and the style (B)
- [x] The map size (128 x 128) and the play page (a preset)
- [x] `os/progs/plat/art/SPEC.md`
- [x] `tools/plat-art.py` by Codex (Astra); contact sheets shown
- [x] The art approved
- [x] `tools/plat-assets.py`: palette, cell pictures, icons, sounds,
      tables, demos; `plat.dat`, `dat.s`
- [x] Stage 1: the window, the map from a seed, scrolling and zoom, the
      tool column and the bar; roads (bridges), lines, bulldozer; funds;
      the calendar at three speeds and the pause; `plat demo`;
      `tools/test-plat.sh`; `ws plat`, the palette, the shell's help, the
      play page's preset
- [x] Stage 2: zones, power plants, power, growth and decline, the
      census, demand bars; zoom from 4 to 64 pixels a cell
- [x] Stage 3: taxes, upkeep, the yearly summary, messages, sounds
- [x] Stage 4: saving and loading one city, with attributes; the round
      trip in the test
- [x] Tooltips on the buttons and the bar; zoom buttons
- [x] Tier 1 done: screenshot, README and site entries, the shell's
      help, the palette's entry in `ws`, sizes here
- [ ] Frame rates measured on a quiet machine (JIT, interpreter, wasm)
- [x] The art of tier 2 (`SPEC-2.md`) drawn by Codex (Astra); shown
- [x] The art of tier 2 in use (kept unless asked otherwise)
- [x] Tier 2, first part: code units (the simulation, the tools, the
      file, the budget: 2 KiB each, paged in by the kernel; the band moved
      above them, the arena split for DAMAGE); rail and its crossings;
      police and fire stations, parks, the solar plant; maps of pollution,
      crime, traffic, land value and cover feeding growth; roads showing
      their traffic; the maps over the town; the minimap; the budget
- [x] Tier 2, second part: advisers with their portraits in the bar; the
      Plat Ledger at every year's end (a headline from the town's worst
      trouble, the mayor's approval); the town's history (H)
- [ ] Several saved cities (with the gallery of tier 3)
- [x] Tier 3: the cell under the pointer outlined (the pointer's moves
      with no button held, from `ws`); fires that start by chance, spread,
      burn out to rubble, kept down by fire cover, put out by the bulldozer
- [x] The D-LS freed: the work buffers in the library's standard input
      and output buffers (plat reads none, and writes unbuffered)
- [x] The placement's preview: the tool's footprint at the cursor or the
      pointer, green if it can be used there (and paid for), red if not
- [x] Several towns: four places (/ws/plat-1.sav .. -4.sav) and a
      gallery (O): how many are kept (a query, /ws/year>0) and each
      one's attributes (GETATTR)
- [x] Other events (`plat/events.s`, two code units): a flood (the water
      nearest a zone rises over the land beside it, three times; flood
      water is water with an age in the flags, as a fire's, and after
      three months it is cleared land), a storm (from an edge, through
      the town, drifting: lines, trees, buildings and parks to rubble),
      an earthquake (round a zone: what is built falls, a quarter of it
      burns), a coal plant's failure (the whole plant burns). Each month
      3 in 1,000 brings one by chance; V opens a panel that calls one
      down (or a fire) and turns the chance off or on; demo 10
- [x] The terrain editor: three tools without buttons, W water dug, F
      woods planted, A plain land, on open land, woods and water (20 a
      cell, dragged or with the pen); the water's edges, bridges and
      lines over it are drawn again round the cell
- [x] History through snapshots (`plat/years.s`): at each year's end
      (and at S) the town is saved and the disk kept as the snapshot
      platN-YYYY (one of the same year is replaced; a town keeps its last
      eight, the older are deleted); Y lists the town's years (SNAP, mode
      2) and 1..8 reads that year's town from /@platN-YYYY/ws/plat-N.sav;
      demo 11
- [x] Dusk: in December the map is drawn with a second palette from the
      data file (darker, bluer; the windows' glass lit warm)
- [ ] Tier 3, still open: scenarios
