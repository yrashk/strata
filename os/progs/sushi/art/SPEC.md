# SushiBelt: art specification

The art of `sushi` (os/progs/sushi.s), a game set in a small conveyor-belt
sushi bar. Three cooks behind a counter make sushi and put each piece on a
plate on the belt. The plates ride round the belt past a row of customers.
The player gives each customer's order to a cook. The customer takes their
piece when it passes in front of them. A plate that goes round too long
goes stale.

All of the art is original and is drawn by one deterministic script,
`tools/sushi-art.py` (Python 3, standard library only, no external files,
no randomness that is not seeded). It writes the PNG files named below into
this directory. A later `tools/sushi-assets.py` converts them for the game.

## Originality and taste

- SushiBelt has its own look. Do not imitate the art, characters or layout
  of any existing sushi or cooking game, card game or mascot.
- No brand names and no logos except the game's own `SUSHIBELT`.
- No Japanese script (kana or kanji), real or fake, anywhere. Decoration
  uses patterns instead: waves (seigaiha), hemp leaf (asanoha), simple
  fish and wave motifs, plain stripes.
- The people are ordinary, friendly and varied. No ethnic caricature:
  every face uses the same eye style (two small dark eyes, two pixels tall,
  with a one-pixel highlight), with no slanted lines for eyes and no
  protruding teeth. Nobody looks mean, even when angry; an angry customer
  is grumpy and red-faced, as in a children's cartoon.

## How the art is shown

The game's screen is **320 x 200** pixels of 8-bit palette indices. Rows 0
to 167 are the **view** and rows 168 to 199 are the **bar**. The window
server scales the screen by whole factors, usually 3 (960 x 600), so every
pixel becomes a 3 x 3 block.

Draw pixel art: crisp, warm, readable at 1x and lovely at 3x. Use no
anti-aliasing, no dithering noise and no gradients made of many colours.
Shade each material with a ramp of 3 or 4 colours. Light comes from the
top left.

**Mood.** A cosy, busy evening in a small family sushi bar:

- pale hinoki wood with darker walnut trim;
- cream plaster walls;
- an indigo noren curtain and indigo cushions;
- red paper lanterns that glow warm;
- a sea-blue tiled kitchen floor;
- a dark slate belt with stainless rails;
- cooks in white.

The colours are saturated but not neon. The food is the brightest, most
appetising thing on screen: glossy coral salmon, deep red tuna, yellow
egg, orange roe, green cucumber and black-green nori.

## Rules for every file

- PNG, 8-bit RGBA, exactly the size given. Alpha is 0 or 255, nothing in
  between.
- One master palette of **at most 200 opaque colours** across all files
  together. The script also writes `palette.png` (one pixel per colour,
  16 colours a row) and `palette.txt` (one `RRGGBB name` line per colour).
- `palette.txt` must contain these named colours, which the game draws with
  directly:
  - `white` FFFFFF and `black` 000000;
  - `ink`, the darkest outline colour;
  - `patience_green`, `patience_yellow` and `patience_red`, for the bars
    under the order bubbles;
  - `progress`, the bar under a cook's slot while they work;
  - `gold`, for points;
  - `select`, the selection frame colour.
- **Sprites** have a transparent background and a dark outline. The outline
  is never pure black: use a dark shade of the neighbouring colour, or
  `ink`. Each sprite is anchored at its bottom centre unless said
  otherwise.
- Animation frames of one subject keep the same size, anchor and outline.
  Only what moves changes between frames.
- **Whole pictures** (the room, the title, the bar, the panel) are opaque
  and **flat-shaded**: large areas of one colour and clean edges, at most
  64 colours each. They are stored run-length coded.

## The room: `room.png` (320 x 168, opaque)

The fixed background of the view. All coordinates are inclusive (x, y),
with (0, 0) at the top left. The game draws everything that moves over this
picture, so these regions must be exactly where they are stated.

**The back wall (rows 0 to 37).**
- Rows 0 to 11 are a dark walnut beam. Five red paper lanterns hang from
  it, each about 10 x 14, centred at x = 32, 96, 160, 224 and 288, with
  their bottoms at about row 22. They have a warm glow: a lighter centre,
  with no halo of many colours.
- Below the beam is cream plaster with a few thin vertical wood battens.
- At the far left (x 0 to 27, rows 0 to 69) is an indigo noren curtain in
  a doorway, split into two flaps with a white wave motif and no letters.
- At the far right (x 292 to 319, rows 12 to 60) is a small price board:
  five plates stacked from top to bottom (green, blue, red, gold, black)
  with nothing written beside them. The game may draw digits there.
- Rows 14 to 37 between x = 32 and x = 287 stay calm (plain plaster and
  battens only). The order bubbles are drawn there.

**The customers' row (rows 38 to 69).** Behind the belt and in front of the
wall, the customers sit on stools hidden by the belt. Put a low wooden
back-bench or wainscot here (the wall's lower part: hinoki panelling from
row 50 to 69). The game draws eight customers here, centred at
x = 48 + 32 i (i = 0..7), with their bottom row at y = 69. Keep the region
behind those x positions calm and mid-toned, so customers read against it.

**The belt.** A racetrack-shaped loop around the kitchen. The belt surface
is slate grey with fine darker slats every 4 pixels, running across the
direction of travel. The game animates the slats by redrawing the surface,
so draw it here as the still frame. Each lane has a 1-pixel stainless rail
on both edges (light grey with a white highlight).
- Top lane: the surface is x 16..303, y 71..82; the rails are rows 70 and
  83.
- Bottom lane: the surface is x 16..303, y 141..152; the rails are rows 140
  and 153.
- Left lane: the surface is x 3..14, y 71..152; the rails are columns 2 and
  15, between the top and bottom lanes.
- Right lane: the surface is x 305..316, y 71..152; the rails are columns
  304 and 317.
- The four corners, where the lanes meet, are rounded on the outside with
  a radius of 6.
- Below the bottom lane, rows 154 to 159 are the front of the belt's
  housing (walnut, with a lighter top edge). Rows 160 to 167 are the
  dining-room floor (dark wood planks).

**The kitchen, inside the loop (x 16..303, y 84..139).**
- Rows 84 to 111 are the kitchen's back: a sea-blue tiled floor seen from
  above, with a stainless back counter along rows 84 to 92. Put a rice
  cooker, a kettle and a stack of clean plates on it, all small and away
  from x = 60..100, 140..180 and 220..260, where the cooks' heads are.
- Rows 112 to 139 are the **work counter**: a pale hinoki top seen from
  above (rows 112 to 135), with a darker front edge (rows 136 to 139).
- At each of the three cook stations, centred at x = 80, 160 and 240, the
  counter shows:
  - a cutting board 28 x 9 at rows 118 to 126, centred on the station;
  - a round wooden rice tub 12 x 7 to its left;
  - a small green wasabi dish 4 x 3 to its right.
- Between the stations, rows 128 to 134 are clear. The game shows a plate
  there while a cook puts it on the belt.

## The belt surface: `belt_h_<f>.png` and `belt_v_<f>.png`, f = 0..3

- `belt_h_<f>.png` is 8 x 12, opaque: an 8-pixel piece of a horizontal
  lane surface, slats vertical.
- `belt_v_<f>.png` is 12 x 8, opaque: the same piece for a vertical lane,
  slats horizontal.
- Frame f is frame 0 shifted by f pixels in the direction of travel, so the
  four frames tile seamlessly in both directions and loop. Use the same
  colours as the surface in `room.png`.

## Plates and sushi

A plate on the belt is a plate sprite with a piece of sushi drawn over it.
Both are seen from the front and a little above (a three-quarter view).

**Plates.** `plate_<c>.png` is 18 x 8: an oval plate with a coloured rim
and a white inner circle, and a short dark under-shadow on its bottom row.
The colours are:

| c | colour | rim |
|---|---|---|
| `green` | green | |
| `blue` | blue | |
| `red` | red | |
| `gold` | gold | |
| `black` | black | a thin gold edge |

**Sushi.** `sushi_<k>_<s>.png` is 14 x 10. The sushi sits on the plate,
with its bottom centre 2 rows above the plate's bottom centre. The kinds
are:

| k | what |
|---|---|
| `salmon` | salmon nigiri: coral salmon with white fat lines on a rice block |
| `tuna` | tuna nigiri: deep red, glossy |
| `tamago` | a yellow egg slab on rice, with a black nori band across it |
| `ebi` | shrimp nigiri: orange and white stripes with a red tail fan |
| `kappa` | cucumber maki: two round rolls side by side, black-green nori outside, white rice ring, green centre |
| `ikura` | salmon roe gunkan: a nori-wrapped rice oval topped with shiny orange beads |
| `unagi` | eel nigiri: brown glazed eel with a darker sauce sheen and a nori belt |
| `uramaki` | an inside-out roll: two slices with rice and sesame outside, orange and green centre |

Each kind is unmistakable at 1x by its silhouette and colour. The states
are:

| s | state |
|---|---|
| `0` | fresh: glossy, a one-pixel highlight |
| `1` | tired: duller colours, no highlight, the topping drooping a pixel |
| `2` | stale: greyed and greenish, drooped, a dried edge |

**Plate stacks.** `plate_side_<c>.png` is 14 x 3: the plate seen edge-on,
for stacks of eaten plates beside a customer.

## The cooks

There are three cooks, all different in silhouette and colour, all in a
white cook's jacket:

- `cook0`, the owner: an older man with a white headband tied at the side,
  a short grey moustache and a dark blue apron.
- `cook1`: a young woman with a red headscarf, a short ponytail and an
  indigo apron.
- `cook2`: a tall young man with a round white cook's cap, a cheerful wide
  face, rosy cheeks and a dark green apron.

**Body sprites.** `<cook>_<frame>.png` is 40 x 48, anchored at its bottom
centre on (station x, 123), so the sprite covers y = 76..123.
- Rows 0 to 35 are the cook from the head down to the waist, facing the
  viewer. Row 35 is level with the back edge of the work counter.
- Rows 36 to 47 are over the counter top. They show only the cook's
  forearms and hands and what they hold, reaching forward. Every other
  pixel in those rows is transparent.

The frames:

| frame | what |
|---|---|
| `idle_0` | standing ready, hands resting on the counter edge |
| `idle_1` | the same, blinking, with a slight nod |
| `slice_0` | a long knife raised in the right hand, the left hand on a block of fish on the board |
| `slice_1` | the knife down through the fish, with a slice cut |
| `rice_0` | the left hand holding a ball of rice, the right hand reaching to the tub |
| `rice_1` | both hands pressing a nigiri together (two fingers on top) |
| `roll_0` | both hands on a green bamboo mat rolled half-way |
| `roll_1` | the mat closed, squeezed, with the roll inside |
| `place_0` | leaning forward a little, both hands holding a plate (green rim) with sushi out over the counter |
| `place_1` | arms stretched further, the plate lower and further forward, with a small smile |
| `cheer` | eyes closed in a big smile and one fist up: a customer loved it |
| `oops` | a sweat drop and both hands up: the queue is full |

**Faces.** `<cook>_face.png` is 20 x 20: the cook's head and shoulders for
the bar, on a transparent background.

## The customers

There are eight customers, with different silhouettes, hair, clothes and
colours, all friendly:

| name | who |
|---|---|
| `office` | a man in a blue suit with a loosened red tie and neat black hair |
| `granny` | an older woman with a grey hair bun, round glasses and a lilac cardigan |
| `student` | a teenager with big headphones round the neck, a yellow hoodie and messy brown hair |
| `tourist` | a woman with a wide straw sun hat, sunburnt cheeks, a camera on a strap and a turquoise top |
| `artist` | a young person with a green bob haircut, a paint-flecked denim jacket and a small earring |
| `builder` | a broad cheerful man with a short beard, an orange safety vest and a towel round the neck |
| `kid` | a small child with a backwards red cap who barely reaches over the belt (the figure is only about 22 rows tall within the frame) |
| `chef_fan` | an elegant woman with long dark hair, a burgundy dress and pearl earrings |

**Sprites.** `cust_<name>_<frame>.png` is 24 x 32, anchored at its bottom
centre on (seat x, 69). Each customer is seen from the waist up, facing
the viewer and sitting behind the belt. The bottom row is the waist and
the counter edge, with both forearms resting on it.

The frames:

| frame | what |
|---|---|
| `sit_0` | waiting calmly, holding chopsticks |
| `sit_1` | the same, blinking |
| `want` | leaning forward, eyes wide and up, a little open mouth: hungry, looking at the belt |
| `eat_0` | chopsticks raised to the mouth with a piece of sushi |
| `eat_1` | chewing, eyes closed happily, cheeks puffed |
| `happy` | both hands up, a big smile: delicious |
| `angry` | arms crossed, red cheeks, a scowl: they are leaving |

The customers arrive and leave by rising from, and sinking behind, the
belt rail. The game clips them at row 69, so they need no walking frames.

## Small sprites

| File | Size | What |
|---|---|---|
| `bubble.png` | 22 x 20 | a white speech bubble with an `ink` outline, rounded, with a 3-pixel tail at the bottom centre. The game puts a sushi sprite inside at (4, 3). Anchored at the bottom centre on (seat x, 37) |
| `bubble_sel.png` | 22 x 20 | the same bubble with a 1-pixel `select` colour frame inside the outline: the chosen order |
| `select_cook.png` | 44 x 52 | a hollow rounded frame, 2 pixels thick, in the `select` colour, transparent inside, drawn round a cook's sprite. Anchored top left at (station x - 22, 74) |
| `select_seat.png` | 28 x 36 | the same frame round a customer. Anchored top left at (seat x - 14, 36) |
| `cursor.png` | 16 x 16 | a pair of chopsticks, wood coloured with dark tips, held in a small white glove-less hand drawn simply. The tip is at pixel (1, 1); anchored top left |
| `fly_0.png` `fly_1.png` | 7 x 5 | a small cartoon fly, dark body, wings up and wings down |
| `stink_0.png` `stink_1.png` | 10 x 8 | two wavy greenish odour lines, two phases |
| `steam_0.png` `steam_1.png` | 12 x 10 | a puff of angry steam (white), two phases |
| `heart_0.png` `heart_1.png` | 9 x 9 | a pink heart, and a smaller one (it pops) |
| `poof_0.png` .. `poof_2.png` | 16 x 16 | a dust cloud, growing then breaking up: a plate swept off the belt |
| `coin.png` | 8 x 8 | a gold coin with a tiny yen-style mark that is not a letter (a stroke cross) |
| `star_0.png` `star_1.png` | 9 x 9 | a yellow sparkle, two frames |
| `bell_0.png` `bell_1.png` | 12 x 12 | a small brass door bell, still and swinging: a customer arrives |

## Lettering

The game writes numbers and short words with these fonts. Each glyph is
drawn in a cell of a fixed size with a transparent background. The cells
are laid out in one row in the order of the string below.

- `font_small.png`: cells 6 x 8 (glyphs 5 x 7 plus 1 column of spacing).
  The glyphs are ` 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-x:!?.%/` plus
  a yen mark (Y with two bars) as the last glyph. They are cream white with
  a 1-pixel `ink` outline on the right and the bottom (a drop shadow),
  inside the cell. The image is 6 x (number of glyphs) wide and 8 high.
- `font_big.png`: cells 10 x 14, with the glyphs `0123456789+-x:` and the
  yen mark: chunky rounded gold digits with a white highlight and an
  `ink` outline, for the score.

## The bar: `bar.png` (320 x 32, opaque)

A dark walnut panel with a lighter top edge (rows 0 and 1), divided into
four boxes by inset frames:
- The money box is x 2..77, y 3..29: a darker inset where the game writes
  the yen with `font_big` and the clock (`18:30`) with `font_small`.
- The cook boxes are x 82 + 80 k .. 157 + 80 k, y 3..29, for k = 0..2.
  Each has:
  - a round cream face plate at x +2..+23, y 5..26 (relative to the box's
    left edge), where the game draws `<cook>_face.png` at (+3, +6);
  - three square queue slots of 16 x 16 at x +27, +43, +59 and y 6..21,
    each a lighter inset with a 1-pixel darker frame, where the game draws
    sushi sprites;
  - a 2-pixel groove along y 24..25, x +27..+74, which the game fills with
    `progress`.

## Whole pictures

- **`title.png`** (320 x 168, opaque): the sushi bar at night seen from the
  street. A wooden front with an indigo noren in the doorway, two glowing
  red lanterns and warm light from inside. The logo `SUSHIBELT` is in
  chunky rounded letters, cream with a coral salmon edge and a dark
  outline, arched over the door in rows 10 to 60. A few plates of sushi
  ride a short belt across the bottom (rows 130 to 150). Leave rows 152 to
  167 calm and dark, where the game writes `PRESS SPACE`.
- **`panel.png`** (200 x 120, opaque): a hanging wooden menu board with
  two cords at the top and a calm, pale centre (x 12..187, y 20..107)
  where the game writes the evening's results with the fonts.

## A mock-up and contact sheets

The script also writes:

- **`mock.png`** (320 x 200, then the same at 3x as `mock_3x.png`): a
  composed frame of the game that follows the geometry above exactly:
  - the room;
  - plates with sushi on all four lanes, some tired and one stale with
    flies;
  - six customers in different frames, three of them with bubbles and
    patience bars;
  - the three cooks, in `slice_1`, `rice_1` and `place_1`, with
    `select_cook` round one;
  - the bar with faces, queued sushi, a progress bar, `¥ 1250` and
    `19:40`.

  The mock-up is how the look is judged, so make it look like a real,
  busy, cheerful moment of play.
- **`sheet_sprites.png`**: plates, sushi in all states, the small sprites
  and the fonts.
- **`sheet_cooks.png`**: every cook frame and the faces.
- **`sheet_customers.png`**: every customer frame.
- **`sheet_pictures.png`**: the room, the title, the bar and the panel.

The contact sheets show everything at 3 times the size. Sprites are shown
on a mid-grey and on a cream ground, each labelled with its file name (the
script may use its own tiny font for the labels).
