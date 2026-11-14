# Princess Kira: art specification

The art of `kira` (os/progs/kira.s), a game for a five-year-old: four gentle
activities with no enemies, nothing frightening and no way to lose. All of
it is original and is drawn by one deterministic script, `tools/kira-art.py`
(Python 3, standard library only), which writes the PNG files named below
into this directory. `tools/kira-assets.py` converts them into `kira.dat`.

## How the art is shown

The game's screen is 320 x 200 logical pixels, shown at three times the
size (960 x 600): every source pixel is a 3 x 3 block. It is pixel art:
crisp, bright, rounded, friendly, readable at that size. No anti-aliasing,
no dithering noise, no gradients made of many colours.

## Rules for every file

- PNG, 8-bit RGBA, exactly the size given. Alpha is 0 or 255, nothing between.
- One master palette of **at most 200 opaque colours** for all files
  together (the colouring pages excepted: they are pure black and white).
  The script also writes `palette.png` (one pixel per colour, 16 a row).
- Sprites have a transparent background and a dark outline (not pure black:
  a dark shade of the neighbouring colour) so that they read on any ground.
  They are anchored at the bottom centre unless said otherwise: the figure
  stands on the bottom row and is centred horizontally.
- Animation frames of one subject keep the same size and anchor.
- Tiles, flats and wall textures are opaque and tile seamlessly.
- Style: soft pastel castle (cream, pink, lilac), fresh greens outdoors,
  light sky blue; big eyes, small smiles. Nothing with teeth or claws
  showing, nothing dark or sad.

## Kira

A little princess of about six: a **purple dress**, **very long hair worn in
one long braid** that reaches below her waist (deep violet), a small gold
tiara, a friendly round face. An original design, not a likeness of any
existing character.

| File | Size | What |
|---|---|---|
| `kira_td_down_0.png` `_1` | 16 x 24 | walking towards the viewer, two frames (three-quarter top view, as in a 16-bit adventure game) |
| `kira_td_up_0.png` `_1` | 16 x 24 | walking away: the braid shows |
| `kira_td_left_0.png` `_1` | 16 x 24 | walking left |
| `kira_td_right_0.png` `_1` | 16 x 24 | walking right |
| `kira_face_0.png` `_1` `_2` | 28 x 28 | portrait for the bar: smiling; blinking; delighted (open smile) |
| `kira_big_0.png` `_1` `_2` | 64 x 96 | full figure from the front: standing; waving; both arms up, cheering |

## The seven friends

`cat` (an orange kitten), `dog` (a brown and white puppy), `bunny` (white),
`duck` (a yellow duckling), `pony` (a small white pony with a pink mane),
`bird` (a round bluebird), `frog` (green). Each is unmistakable in
silhouette and colour.

| File | Size | What |
|---|---|---|
| `<name>_fp_0.png` `_1` | 48 x 48 | sitting or standing, facing the viewer; frame 1 is a small idle movement (a blink, a hop, a wagging tail) |
| `<name>_td_0.png` `_1` | 16 x 16 | the same animal in the three-quarter top view, two idle frames |
| `<name>_icon.png` | 20 x 20 | its head, for the bar |

## The world (one map, seen from above and through Kira's eyes)

Seen from above a cell is a 16 x 16 tile; in the first-person view a wall
is a 64 x 64 texture and a floor a 32 x 32 flat. The first-person textures
are drawn evenly lit (the game darkens them with distance).

Walls, each as `wall_<name>_fp.png` (64 x 64) and `wall_<name>_td.png`
(16 x 16, the wall seen from above with its front face showing):
`stone` (pink-cream castle stone), `window` (the stone with an arched window
and blue sky in it), `banner` (the stone with a heart banner), `shelf` (a
bookshelf with colourful books and toys), `hedge` (a clipped green hedge),
`roses` (the hedge with pink roses).

Floors, each as `floor_<name>_fp.png` (32 x 32) and `floor_<name>_td.png`
(16 x 16): `castle` (cream and pink checker tiles), `carpet` (lilac with a
small pattern), `grass`, `path` (sandy stones), `water` (a pond: light
blue with a few ripples). And `ceil_castle_fp.png` (32 x 32, a pale lilac
ceiling with small stars).

Things that stand in a cell, each as `<name>_fp.png` (size below, anchored
at the bottom centre; 64 pixels are one cell's height) and `<name>_td.png`:

| Name | fp size | td size | What |
|---|---|---|---|
| `tree` | 64 x 112 | 16 x 24 | a round tree with red apples |
| `bush` | 48 x 32 | 16 x 16 | a flowering bush |
| `fountain` | 64 x 56 | 16 x 16 | a small stone fountain |
| `bed` | 64 x 48 | 16 x 16 | a princess's bed, pink covers |
| `table` | 48 x 48 | 16 x 16 | a small table with a cake |
| `throne` | 48 x 72 | 16 x 24 | a little golden throne with a purple cushion |
| `chest` | 40 x 32 | 16 x 16 | a toy chest, a teddy bear looking out |
| `picnic` | 64 x 20 | 16 x 16 | a red and white checked picnic blanket with a basket, lying on the ground |

## Small sprites

| File | Size | What |
|---|---|---|
| `heart_0.png` `_1` | 9 x 9 | a pink heart, and a smaller one (it pops) |
| `star_0.png` `_1` | 9 x 9 | a yellow sparkle, two frames |
| `note_0.png` `_1` | 9 x 12 | a musical note in two colours |
| `butterfly_<c>_0.png` `_1`, c = `a` `b` `c` | 16 x 12 | wings open, wings closed; three colourings |
| `cursor.png` | 16 x 16 | a pointing hand, white glove with outline; the fingertip is at pixel (3, 1); anchored top left |
| `select.png` | 28 x 28 | a hollow rounded frame, gold, 2 pixels thick, transparent inside |
| `num_1.png` .. `num_7.png` | 24 x 32 | big friendly numerals, each a different bright colour, white outline then dark outline |
| `word_<name>.png` for the seven friends | height 24, width as needed, at most 120 | the animal's name in capitals (`CAT`, `DOG`, `BUNNY`, `DUCK`, `PONY`, `BIRD`, `FROG`): chunky rounded letters, white with a dark outline, on a rounded lilac plate |
| `word_picnic.png` | at most 200 x 24 | `PICNIC TIME!` in the same lettering |
| `word_hooray.png` | at most 160 x 32 | `HOORAY!` larger, rainbow letters |

## The bar (the bottom 32 rows of the screen)

| File | Size | What |
|---|---|---|
| `bar.png` | 320 x 32 | a plain decorative panel (lilac, a lighter top edge, small corner ornaments); icons are drawn over it, so the middle stays calm |
| `icon_home.png` | 24 x 24 | a little house: back to the menu |
| `icon_eyes.png` | 24 x 24 | a pair of eyes: look through Kira's eyes |
| `icon_map.png` | 24 x 24 | a small map: look from above |
| `icon_tulip.png` `icon_daisy.png` `icon_sunflower.png` `icon_rose.png` | 24 x 24 | seed packets with the flower on them |
| `icon_can.png` | 24 x 24 | a watering can |
| `icon_next.png` | 24 x 24 | an arrow to the right on a round button |
| `icon_song.png` | 24 x 24 | a round button with a note and a play triangle |
| `pot_0.png` .. `pot_9.png` | 20 x 24 | a paint pot of each of the ten paint colours: red, orange, yellow, green, sky blue, blue, purple, pink, brown, white |

## The garden

| File | Size | What |
|---|---|---|
| `plant_<kind>_1.png` `_2` `_3`, kind = `tulip` `daisy` `sunflower` `rose` | 32 x 48 | a sprout; a taller plant with a bud; in full bloom. Anchored at the bottom centre |
| `drop.png` | 7 x 9 | a water drop |

## Whole pictures (320 x 168, opaque)

These are stored run-length coded, so they must be **flat-shaded**: large
areas of one colour, clean edges, few colours (at most 48 each).

- `menu.png`: the title `PRINCESS KIRA` in the top 44 rows (rainbow or gold
  lettering on sky, a castle tower or two, stars), and four big buttons
  with exactly these rectangles (left, top, right, bottom, inclusive):
  (8, 48, 155, 103), (164, 48, 311, 103), (8, 108, 155, 163),
  (164, 108, 311, 163). Each button is a rounded panel with a 2-pixel
  frame, a picture at its left and a word in big capitals at its right:
  `FRIENDS` (Kira and a kitten), `GARDEN` (flowers and a watering can),
  `PAINT` (a brush and a rainbow), `MUSIC` (a xylophone and notes).
- `garden.png`: sky, a smiling sun, a few clouds, the castle small in the
  distance, a lawn from row 70 down, and twelve patches of brown soil,
  ellipses 40 wide and 14 high, centred at x = 40, 88, 136, 184, 232, 280
  and y = 104 (back row) and y = 150 (front row). The plants are drawn over
  the picture with their bottom centre 4 rows below each centre.
- `music.png`: a cheerful room or stage. Rows 4 to 56 are a calm shelf or
  balcony on which the seven friends sit (the game draws them there,
  48 x 48 each, at x = 4 + 45 i). Below it a xylophone on a stand: eight
  bars in rainbow order (red, orange, yellow, green, sky blue, blue,
  purple, pink), bar i (0..7) exactly the rectangle x = 28 + 34 i ..
  57 + 34 i, y = 64 + 3 i .. 160 - 3 i, each a flat colour with a lighter
  left edge and two round pegs.
- `xylo_hit_<i>.png`, i = 0..7: 30 wide, 97 - 6 i high: bar i as it looks
  when struck (much brighter, a white sparkle), drawn over the bar's
  rectangle.

## Colouring pages (320 x 168, opaque, pure black and pure white only)

`paint_1.png`: a castle on a hill with a rainbow, a sun and clouds.
`paint_2.png`: Kira with her kitten among flowers.
`paint_3.png`: a pony and butterflies in a meadow.

Black outlines exactly 2 pixels thick on white, every region closed (no
gaps: the game fills a region where it is touched), between 25 and 60
regions a page, no region smaller than about 10 x 10 pixels except eyes
and such, which are solid black instead. A 2-pixel black frame around the
whole page.

## Contact sheets

The script also writes `sheet_sprites.png`, `sheet_world.png` and
`sheet_pictures.png` (everything at three times the size, sprites on a
mid-green and a cream ground, with file names) for looking the art over.
