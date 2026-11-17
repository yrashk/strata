# sushi: SushiBelt, a conveyor-belt sushi bar in a window

A checkbox plan and the reasoning behind the design. The program is
`os/progs/sushi.s` with its modules in `os/progs/sushi/`; the art is drawn
by `tools/sushi-art.py` into `os/progs/sushi/art/` (specified in
`os/progs/sushi/art/SPEC.md`) and converted, with the sounds, by
`tools/sushi-assets.py` into `os/progs/sushi/sushi.dat`.

## What it is

A small sushi bar in the evening. Three cooks stand behind a counter in
the middle; a belt runs round them; customers sit behind the belt. The
player is the head of the kitchen:

- A customer comes in, sits down and wants a piece of sushi: a bubble over
  their head shows which, and a bar under it how much patience they have
  left.
- The player gives the order to one of the cooks (1 2 3, or a click on the
  bubble and then on the cook). Each cook has a queue of three orders and
  makes them one after another: nigiri are sliced and pressed, rolls
  rolled in the mat, gunkan pressed and wrapped. The owner is quick with
  nigiri, the cook in the red headscarf with rolls, the young cook is
  even.
- The cook puts the plate on the belt in front of them. It rides round,
  and the first customer who wants that piece takes it as it passes, eats
  and pays: the plate's price (its colour), a tip by how much patience was
  left, and ten yen for every piece served in a row before it.
- A customer who waits too long leaves, cross. A plate that rides too long
  tires (no tip) and then goes stale (flies): a customer who takes a stale
  plate leaves without paying. A click on a plate, or Z for the oldest
  stale one, sweeps it off the belt, at the cost of its fish.
- An evening runs from 17:00 to 22:00 (about three minutes); customers come
  more often and are less patient as it goes on; the results are shown on
  a board when the last one has gone.

## Decisions

- **The game is direction A of four proposed** (the head chef, with stale
  plates); the others were routing plates with switches, combos with plate
  towers, and days with rush hours and upgrades, which is to wrap A in the
  later parts.
- **The screen is kira's**: 320 x 200 palette indices drawn in ten slabs
  of 32 columns, a 168-row view and a 32-row bar, pushed into the band at
  the largest whole factor; the room is a run-length-coded picture, all
  else sprites. The belt moves every tic, so while the evening runs every
  tic is a frame (on the title and the results only the blinking text
  makes one).
- **The belt is a path**: a plate's place is a number 0 .. 743 that grows
  by one a tic; `plate_xy` turns it into a lane's middle on the screen.
  The slats are drawn by the program over the room's plain belt (dark
  every fourth pixel, shifted by the belt's phase), so the picture codes
  small and the belt moves without art of its own.
- **Customers sit behind the belt, cooks stand in front of it**: the
  customers rise from behind the belt's edge as they sit down and sink
  behind it as they go (sprites are clipped at row 70), so no walking is
  drawn. The plates on the top lane are behind the cooks' heads, those on
  the bottom lane in front of the counter.
- **One chosen order at a time**: there is always one (the first not yet
  given to a cook, unless the player chose another; its bubble is framed
  and bobs), so the keyboard needs only 1 2 3 and the arrows. An order
  given shows the cook's number on its bubble; it can be given again (a
  second plate is a gamble on the belt).
- **What is going on is shown where it happens**: the cooks' numbers are
  painted on the wall beside them and on their boxes in the bar; the piece
  a cook is making stands beside them with how far it is made under it.
  Before the evening a card says how to play, in three pictures and seven
  lines.
- **Text is sprites**: two fonts from the art (6 x 8, and 10 x 14 digits
  for the money), and `$` in a string is the yen mark.
- **Sounds are synthesised** by the asset tool (the door bell, the knife,
  a plate set down, coins, a grumble, a sweep, a gong at closing time)
  and played through wdoom's mixer.
- **`sushi demo N`** plays recorded keys and clicks one tic a frame, as
  kira's demos do; a `>` in a demo runs the tics after it without drawing
  them, so a whole evening is a test of a second.

## Plan

Each part ends with a playable program and a commit. `sushi` and its data
are on the ordinary disk (`make boot`, then `ws sushi`, or `sushi` from the
palette): there is no boot image of its own.

- [x] Mechanics proposed; direction A with stale plates chosen
- [x] The art specification (`os/progs/sushi/art/SPEC.md`)
- [x] `tools/sushi-art.py`: the art; contact sheets and a mock-up shown
      and approved
- [x] `tools/sushi-assets.py`: palette, sprites, fonts, pictures, the bar,
      sounds, the sushi and the cooks' times, the demos
- [x] Part 1: **one evening**: three cooks, five kinds of sushi, customers
      who come, wait, eat, pay or leave; stale plates and sweeping; the
      title, how to play, and the results; sound; `sushi demo`; on the disk, `ws sushi`,
      the palette, the shell's help; `tools/test-sushi.sh` in `make test`;
      the play page's preset
- [ ] Part 2: **rush hours** (the day in parts, a sign over the door and a
      crowd when a rush begins), customers who order a set of pieces at
      once, and VIPs who pay double and wait half as long; the plates a
      customer has eaten stacked beside them
- [ ] Part 3: **days and upgrades**: the takings spent between evenings
      (a faster belt, a fourth cook, a rice cooker, a tea station, a new
      fish: unagi, ikura, uramaki are drawn already), the restaurant kept
      in a file

## What chance decides

A run's random numbers start from the clock, a demo's from a fixed seed:
when the next customer comes in and at which seat, who they are (nobody
already sitting there), how many pieces they want and which.

## Sizes

The program is 47 KiB on the disk: 18 KiB of code (of the 32 KiB a
program may have; about 2,750 lines of assembly of its own, the frame
much as kira's) and 29.5 KiB of D-LS data (of 40 KiB): the library 13
KiB, the resident block of `sushi.dat` 5 KiB, the slab 5.4 KiB, a 3 KiB
buffer for a coded picture slab. `sushi.dat` is 235 KiB: 213 sprites,
ten sounds, the room and the title coded, the bar. The art has 64
colours, and so has the palette.

On the emulator with the JIT (an Apple M-series host, 2026-11-17) an
evening's tics drawn at three times the size run at about 250 frames a
second, and a whole evening not drawn (demo 8) takes a third of a second.
