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
- [ ] Stage 2: **Friends through Kira's eyes** (the raycaster, per-cell
      floors, the sky)
- [ ] Stage 3: **Garden**, kept in a file
- [ ] Stage 4: **Paint**
- [ ] Stage 5: **Music**
- [ ] A screenshot, README and site entries, the play page preset
- [ ] Measurements

## Sizes (stage 1)

The program is 48.7 KiB on the disk: 15 KiB of code (of the 32 KiB a
program may have; 7 KiB of it `sys.s` and `wsclient.s`) and 33.7 KiB of
D-LS data (of 40 KiB): the library 13 KiB, the resident block of
`kira.dat` 10 KiB, the slab 5.4 KiB, a 2 KiB buffer for a coded picture
slab. `kira.dat` is 352 KiB: sprites 161 KiB, sounds 88 KiB, the six
pictures 51 KiB coded (they would be 315 KiB plain), tiles, textures, flats
and the bar 43 KiB. The art has 55 colours; the palette 68.
