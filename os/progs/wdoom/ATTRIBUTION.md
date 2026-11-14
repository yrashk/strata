# wdoom's art and sounds: Freedoom

Everything in `wdoom.dat` that is a picture or a sound comes from the
**Freedoom** project, https://github.com/freedoom/freedoom (commit
`21d783c481af9233fa72305b40eb247fa966b49a`), which is distributed under the
3-clause BSD licence reproduced in `LICENSE-freedoom` in this directory:

> Copyright © 2001-2024 Contributors to the Freedoom project. All rights
> reserved.

The contributors are listed in Freedoom's `CREDITS` file. Neither the name
of the Freedoom project nor the names of its contributors endorse this
program.

`wdoom.dat` is a converted subset, not a WAD: `tools/wdoom-assets.py` reads
the files below from a Freedoom source checkout, maps them to Freedoom's
palette, crops and re-arranges them (textures and sprites column by
column), halves the sounds' sample rate and keeps their first 0.4 s. The
level, the lookup tables and the colour map in the file are made by that
script and are part of this project.

| What | Freedoom files |
|---|---|
| The palette | `lumps/playpal/playpal-base.lmp` (the red and gold palettes are computed from it) |
| Wall textures | `patches/`: `aqconc16`, `aqpanl01`, `aqpanl02`, `aqmetl13`, `aqconc13`, `aqconc14`, `brick1`, `brick`, `arock2`, `aqpipe10`, `rw13_1`, `door9_1`, `aqdoor02`; the exit switch is `aqconc16` with `sw1s0` / `sw1s1` and `exit1` drawn on it |
| Floor and ceiling | `flats/`: `aqf050`, `ceil5_1` |
| The zombie | `sprites/`: `possa1` `possb1` `possc1` `possd1` `posse1` `possf1` `possg1`, `possh0` .. `possl0` |
| The imp | `sprites/`: `trooa1` .. `trooh1`, `trooi0` .. `troom0` |
| The demon | `sprites/`: `sarga1` .. `sargh1`, `sargi0` .. `sargn0` |
| Pickups, the fireball | `sprites/`: `clipa0`, `stima0`, `media0`, `bkeya0`, `bal1a0`, `bal1b0`, `bal1c0` |
| The pistol | `sprites/`: `pisga0`, `pisgb0`, `pisgc0`, `pisfa0` |
| The status bar | `graphics/`: `stbar`, `starms`, `sttnum0` .. `sttnum9`, `sttprcnt`, `stfst00` `stfst10` `stfst20` `stfst30` `stfst40`, `stfdead0`, `stkeys0` |
| Messages | drawn with the font `graphics/stcfn033` .. `stcfn095` |
| Sprite offsets | `buildcfg.txt` |
| Sounds | `sounds/`: `dspistol`, `dsdoropn`, `dsdorcls`, `dsposit1`, `dspopain`, `dspodth1`, `dsbgdth1`, `dssgtdth`, `dsplpain`, `dsitemup`, `dsfirsht`, `dssgtatk`, `dsswtchn`, `dsnoway`, `dspldeth`, `dsfirxpl` |

To make the file again:

    git clone https://github.com/freedoom/freedoom
    python3 tools/wdoom-assets.py freedoom os/progs/wdoom
