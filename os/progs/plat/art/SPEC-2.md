# Plat: art specification, second part (the fuller city)

The art the fuller city adds to `plat` (os/progs/plat.s): rail, city
services, parks, a clean power plant, traffic, fires, advisers, the town
paper's masthead and the new tools' icons. It is drawn by the same script
as the first part, `tools/plat-art.py`, and follows every rule of
`SPEC.md` beside this file (sizes, the 16 x 16 cell, the view from above
with a slight tilt, light from the top left, the colours, opaque cells,
alpha 0 or 255, outlines that are never pure black, originality: nothing
may resemble the 1989 classic of the genre or the open-source release of
its code).

**Everything the first part draws stays exactly as it is**: every file
`SPEC.md` names must come out byte for byte the same as before (the game's
tests compare pictures made from them). The palette may grow, but the
master palette stays at most 200 opaque colours in all, and the colours
already used keep their values. New contact sheets are new files.

## Rail

The mask is the one of roads and lines (N 1, E 2, S 4, W 8).

| File | Size | What |
|---|---|---|
| `rail.png` | 16 x 16*16 | 16 rail cells in a column, mask 0 to 15: two steel rails on dark wooden sleepers, on a pale grey gravel bed, on plain ground at the edges not used by the track; curves are smooth quarter circles; mask 0 a short stub with a buffer stop |
| `rail_bridge.png` | 32 x 16 | two cells: a rail bridge over open water running E-W, then N-S (girders at the sides, the water showing beside) |
| `rail_road.png` | 32 x 16 | a level crossing: rail N-S over an E-W road, then rail E-W over a N-S road (the rails set into the road, striped barriers folded up beside it) |
| `line_rail.png` | 32 x 16 | a power line N-S over an E-W track, then E-W over a N-S track (poles beside the track, as `line_road.png` does beside a road) |

## Traffic

| File | Size | What |
|---|---|---|
| `traffic_light.png` | 16 x 16*16 | the 16 road cells of `road.png` with light traffic: one or two small cars (about 3 x 5 pixels, bright colours, a darker roof) on the lanes; every pixel that is not a car is exactly `road.png`'s |
| `traffic_heavy.png` | 16 x 16*16 | the same with heavy traffic: cars nose to tail on both lanes |
| `jam.png` | 16 x 16 | transparent: a mark over a jammed road: two cars and a red exclamation sign |

## Services and parks

All opaque, lots in the same family as the zones' (`SPEC.md`), so that
they sit beside zones and roads.

| File | Size | What |
|---|---|---|
| `police.png` | 48 x 48 | a police station: a sturdy building with a slate-blue roof and a small beacon on it, a flagpole, two patrol cars (white and blue) in a little car park, a short hedge |
| `fire.png` | 48 x 48 | a fire station: red-brick hall with three large garage doors facing south, a hose tower, a red fire engine on the apron |
| `park_0.png` `park_1.png` | 16 x 16 | a small park: lawn, a curving gravel path, a bench, flowerbeds; two different designs; each looks right next to roads and other parks |
| `park_big.png` | 48 x 48 | a town square: paths meeting at a round fountain, trees, benches, flowerbeds |
| `solar_0.png` `solar_1.png` | 64 x 64 | the clean power plant: rows of tilted solar panels (deep blue with a light frame), a small control building, a fence; frame 1 differs only in a few bright glints that move along the panels |

## Fire (for later events)

| File | Size | What |
|---|---|---|
| `fire_0.png` .. `fire_3.png` | 16 x 16 | a cell on fire: flames (amber, orange, a bright yellow core) over scorched rubble, with smoke; four frames of one animation that loops |

## Advisers and the paper

| File | Size | What |
|---|---|---|
| `adv_clerk.png` `adv_engineer.png` `adv_shopkeeper.png` `adv_resident.png` | 32 x 32 | opaque head-and-shoulders portraits on a soft round plaque in the panel's colours: the town clerk (spectacles, a ledger), the engineer (a hard hat), the shopkeeper (an apron), a resident (a scarf). Friendly, varied in age and skin tone, original designs |
| `paper_head.png` | 240 x 32 | transparent: the masthead of the town's paper, the words `PLAT LEDGER` in bold capitals of the game's own design (not a copied font) with a thin rule under them |

## Icons for the new tools (transparent, drawn on `button.png`)

| File | Size | What |
|---|---|---|
| `tool_rail.png` | 20 x 20 | a short piece of track |
| `tool_police.png` | 20 x 20 | a police badge (a star in a shield) |
| `tool_fire.png` | 20 x 20 | a red fire helmet |
| `tool_park.png` | 20 x 20 | a round tree with a bench |
| `tool_solar.png` | 20 x 20 | a solar panel with a small sun |
| `tool_budget.png` | 20 x 20 | an open ledger with a coin |
| `tool_map.png` | 20 x 20 | a folded map with coloured patches (the overlays) |
| `tool_zoom_in.png` `tool_zoom_out.png` | 20 x 20 | a plus, and a minus, in a rounded square frame with four small corner ticks (clearly not the query tool's magnifying glass) |

## Contact sheets

- `sheet_tier2.png`: everything above at 2x (portraits and icons at 3x),
  with the file names, on the panel colour;
- `sample_town2.png`: a town of 40 x 24 cells at 1x built only from the
  cells (the first part's and these): a rail line with a level crossing,
  a bridge over water and a power line crossing it; roads with light and
  heavy traffic and one jam mark; the police and fire stations; small
  parks and the town square; the solar plant; one cell on fire; zones of
  every kind around them.
