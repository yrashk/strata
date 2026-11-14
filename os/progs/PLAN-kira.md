# kira: Princess Kira, four gentle games in a window

A checkbox plan and the reasoning behind the design. The program is
`os/progs/kira.s` with its modules in `os/progs/kira/`; the art is drawn by
`tools/kira-art.py` into `os/progs/kira/art/` (specified in
`os/progs/kira/art/SPEC.md`) and converted, with the sounds, by
`tools/kira-assets.py` into `os/progs/kira/kira.dat`.

## What it is

A game for a five-year-old who reads a little. No enemies, nothing
frightening, no timer, no way to lose. One program, a menu and four
activities; one runs at a time and the menu switches between them:

- **Friends.** Kira walks through her castle and its garden and finds her
  seven animal friends (cat, dog, bunny, duck, pony, bird, frog). A friend
  that is found says hello, its name and the count so far appear, and it
  follows her in a parade. With all seven she walks to the picnic blanket:
  music, hearts, `HOORAY!`, and the friends hide somewhere else for the
  next game. The same world has two views, switched at any moment: from
  above (tiles), and through Kira's eyes (the raycaster of `wdoom`).
- **Garden.** Twelve patches of soil. Pick a seed, touch a patch: a sprout.
  The watering can makes it grow, twice, into a flower in bloom, and
  butterflies come to the flowers. The garden is kept in a file.
- **Paint.** Three colouring pages. Pick a paint pot, touch a region: it is
  filled.
- **Music.** A rainbow xylophone of eight bars, the seven friends who each
  make their sound, and a button that plays a song with the bars lighting
  up.

## Decisions

- **Movement is by whole cells**, in both views: a key or a click is one
  step (or a quarter turn), animated over eight tics. The keyboard has no
  key-up, so "held" keys stutter (see `PLAN-wdoom.md`); steps do not, and a
  step is easier for a small child than free movement. From above a click
  on a cell walks Kira there (a breadth-first search over the screen's
  20 x 10 cells); the world is four such screens and flips between them.
- **Every game of Friends has a new world.** `world.s` makes the castle
  (three rooms, the walls between them and their doors at random places,
  windows, banners, shelves, carpets, two gates) and the garden (paths, a
  pond, trees, bushes, a fountain, the blanket), and puts Kira and the
  friends into it. Nothing has to be checked afterwards: a thing or the
  pond goes only where every cell around it is free, so the cells around
  it are a ring to walk and no way is ever closed. A run's random numbers
  start from the clock; a demo's from a fixed seed.
- **Through her eyes the world is wdoom's raycaster** with 64-texel
  textures and four light levels (the palette has the darker shades of the
  world's colours, so a far wall is a shade of its own colour), a floor
  flat per cell by the cell's kind, and sky instead of a ceiling over
  grass, paths and water. Up is a step, Down a step back, Left and Right
  quarter turns; a press at the left or right of the picture turns, one in
  the middle steps.
- **Mouse and keyboard both do everything.** Where the mouse points and
  clicks (menu, garden, paint, music) the arrow keys move a hand and Space
  presses it.
- **The screen is wdoom's**: 320 x 200 palette indices drawn in ten slabs of
  32 columns, a 168-row view and a 32-row bar, pushed into the band at the
  largest whole factor. Every activity fills the slab its own way (a
  run-length-coded picture, tiles, or the raycaster) and the sprites, the
  messages and the hand go over it.
- **A frame is drawn only when something changed.** wdoom draws every tic;
  here most tics change nothing.
- **Whole pictures are run-length coded** per slab (flat-shaded art codes
  to a few hundred bytes a slab); a colouring page is a picture whose
  "colours" are region numbers, mapped through a table of 256 bytes, so
  filling a region is one store and no flood fill.
- **Text is art**: the few words (the friends' names, the menu) are
  sprites and parts of pictures; the program has no font.
- **Sounds are synthesised** by the asset tool (xylophone notes, the
  animals, chimes); songs are note lists played through wdoom's mixer.
- **`kira demo N`** plays a recorded list of keys one tic a frame and then
  stands still, for the test, as `wdoom demo` does.

## Plan

Each stage ends with a playable program and a commit. `kira` and its data
are on the ordinary disk (`make boot`, then `ws kira`, or `kira` from the
palette): there is no boot image of its own.

- [x] Read wdoom, the client library and the server's DAMAGE path
- [x] The art specification
- [x] `tools/kira-art.py`: the art
- [x] `tools/kira-assets.py`: palette, sprites, tiles, pictures, sounds, the
      world, `kira.dat` and `dat.s`
- [x] Stage 1: the frame (slabs, pictures, sprites, the bar, the hand),
      the menu, **Friends from above**, sound, `kira demo`, the program on
      the disk, `ws kira`, the shell's help, `tools/test-kira.sh` in `make test`
- [x] Stage 2: **Friends through Kira's eyes** (the raycaster, per-cell
      floors, the sky); a new world for every game
- [x] Stage 3: **Garden**, kept in a file
- [x] Stage 4: **Paint**
- [x] Stage 5: **Music**
- [x] A screenshot, README and site entries, the play page preset
- [x] Sizes

## What chance decides

A run's random numbers start from the clock, a demo's from a fixed seed.
- Friends: the whole world, where Kira starts, where each friend hides,
  where the blanket lies.
- Garden: the first garden (three patches planted already), where each
  butterfly flies next and how long it sits, which friend walks by and
  when.
- Paint: which page is open first.
- Music: which of the four songs the button plays, and which friend hops
  at each of its notes.

## Sizes

The program is 60.6 KiB on the disk: 23.7 KiB of code (of the 32 KiB a
program may have; 7 KiB of it `sys.s` and `wsclient.s`; about 4,700 lines
of assembly of its own) and 36.9 KiB of D-LS data (of 40 KiB): the library
13 KiB (its two 4 KiB buffers hold the floors' flats), the resident block
of `kira.dat` 9.5 KiB, the slab 5.4 KiB, a 2 KiB buffer for a coded
picture slab, the raycaster's depths and visible things 2.8 KiB.
`kira.dat` is 353 KiB: sprites 161 KiB, sounds 88 KiB, the six pictures
52 KiB coded (they would be 315 KiB plain), tiles, textures, flats and the
bar 43 KiB. The art has 55 colours; the palette 198, most of them the
darker shades of the world's colours for the view through Kira's eyes.

On the emulator with the JIT (an Apple M-series host, 2026-11-13) the
sixty games of demo 8, 5,249 tics with a frame drawn for nearly every
one, take 15 seconds: about 350 frames a second in a full-size tile. It
was played in a browser (the play page, JIT on); its rate there was not
measured.

## What is simple

- Through her eyes Kira moves by whole cells and quarter turns; walls
  are one height; things are flat pictures that face her.
- From above the screen flips at its edges and does not scroll.
- The friends walk straight to their places in the parade, through
  whatever is in the way.
- The garden is written when it is left or the program is quit with Q or
  by closing its tile; not when the machine is halted under it.
- The colouring pages keep their colours only while the program runs.
- There is no sound in a demo, and none on a machine without the sound
  device.
