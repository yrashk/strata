# Strata on an open-source ASIC flow (GF180MCU)

An experiment, not a tapeout: what one Strata core, and the 2- and 6-core
systems, look like when pushed through an open-source RTL-to-GDS flow on
GlobalFoundries' open 180 nm PDK (GF180MCU, the process wafer.space runs
shuttles on). The numbers below are what the tools report; nothing here has
been signed off (no DRC/LVS run), and the memories are a physical stand-in
(see "Caveats").

## Results: one core

`asic/results/gf180mcu-1/` (`summary.txt` is the short form; the pictures
are in LFS). Two and six cores are scripted (`asic/run.sh 2`, `6`) but not
run to the end: the 2-core run was stopped after placement.

| | |
|---|---|
| Die | 10.34 x 9.05 mm = 93.6 mm2 |
| SRAM | 267 macros, 55.2 mm2 (59% of the die): 256 x 512x8 for the I-LS and D-LS (53.6), 11 x 256x8 for the save table (1.6) |
| Logic | 4.3 mm2: 11,363 flip-flops (0.72), 127,634 combinational cells (2.00), 68,972 buffers and inverters (1.48, of which 1.14 from design repair), clock tree (0.10) |
| Other cells | well taps, end caps, antenna diodes 1.08 mm2; the rest is filler |
| Pins | 711 |
| Routing | 0 DRC violations after 17 detailed-routing passes; 1 antenna violation |
| Clock, typical (25 C, 5.0 V) | 84.1 ns = 11.9 MHz (target 40 ns, worst setup slack -44.1 ns); register to register 83.9 ns |
| Clock, slow (125 C, 4.5 V) / fast (-40 C, 5.5 V) | 146.8 ns = 6.8 MHz / 56.1 ns = 17.8 MHz |
| Hold | worst -5.9 ns (typical), not repaired |
| Critical path | flip-flop -> `am_req` (the atomic request to the far bus), 95 cells, 70 ns of cell delay and 1.7 ns of wire: slow edges on long nets that nothing resized for timing |
| Flow time | 2 h 47 min for the successful run's steps (8 threads): synthesis 5:39, placement and repair 6:35, CTS 3:22, global routing 4:08, detailed routing 50:01, STA 1:35 (9 corners after routing: 1:20) |

Against the FPGA (`fpga/README.md`): the same core is 30,011 LUTs and
6,869 flip-flops on Xilinx 7-series, and 44,253 logic cells routed at
20.0 MHz on an ECP5-85F. Here it has 11,363 flip-flops (the granule-table
copy and the registers are flip-flops, LUT-RAM there) and 11.9 MHz without
timing repair.

The real wall time was more than a day: the first floorplans did not
route, and several steps had to be worked around (below).

## What it took

Each of these is a setting in `asic/mkconfig.py` with a comment:

- ABC: LibreLane's default `AREA 0` script ran over 75 minutes on one core
  without finishing; `AREA 3` (strash; dch; map) takes 3 minutes. The flat
  2- and 6-core netlists ran ABC out of the container's 16 GB, so several
  cores synthesise module by module (`deferred_flatten`).
- The save table as 20,736 flip-flops made design repair run for hours; in
  SRAM (as block RAM on the FPGA) the core is 3.0 mm2 of cells after
  synthesis instead of 5.7.
- The resizer buffered with delay cells (`dlyb_1`, 1.6 ns a stage):
  `gf180mcu_fd_sc_mcu7t5v0__dly*` are excluded.
- Global placement with its routability and timing loops oscillated for 90
  minutes; both are off.
- `repair_timing` after CTS died without a message (three times), so it is
  off; the pre-placement STA's clock-skew report ran 25 minutes, so that
  step is off too.
- Routing: with every macro row over a 36 um pin channel and the logic
  packed at 60%, then 30%, detailed routing started at 400,000 to 1,100,000
  shorts and diverged. What routed: macro rows in pairs facing a 120 um
  channel, a 3 mm logic strip, 22% placement density with two sites of
  padding per cell; detailed routing went 212,000 -> 0 in 17 passes.
- `ERROR_ON_TR_DRC` is off (`ASIC_DRT_STRICT=0`) so a run with violations
  still gets its STA and pictures; the 1-core run had none left.

## Flow and tools

| | |
|---|---|
| Flow | [LibreLane](https://github.com/librelane/librelane) 3.0.17, "Classic" flow (the FOSSi successor to OpenLane 2) |
| Container | `ghcr.io/librelane/librelane:3.0.17` (arm64 image, run with Docker / OrbStack on an Apple-silicon Mac) |
| Synthesis | Yosys 0.62 (in the container), after `sv2v` on the host, as `fpga/synth.sh` does |
| Place and route | OpenROAD (build of 2026-02-17): floorplan, PDN, global / detailed placement, CTS, global / detailed routing, OpenRCX |
| Timing | OpenSTA 2.7.0 (in OpenROAD), three corners: tt 25 C 5.0 V, ss 125 C 4.5 V, ff -40 C 5.5 V |
| Layout | KLayout 0.30.7 (stream-out, the pictures) |
| PDK | `gf180mcuD` from open_pdks commit `54435919` (the version LibreLane 3.0.17 pins), fetched with `ciel` |
| Cells | `gf180mcu_fd_sc_mcu7t5v0` (7-track, 5 V) |
| SRAM | `gf180mcu_fd_ip_sram__sram512x8m8wm1` (512 x 8, 431.86 x 484.88 um = 0.2094 mm2) and `__sram256x8m8wm1` (256 x 8, 431.86 x 340.88 um = 0.1472 mm2), both single-port |

## How to run it

Install (no root; everything under `build/asic/`):

    python3 -m venv build/asic/venv
    build/asic/venv/bin/pip install librelane==3.0.17 pillow   # for ciel and the pictures
    asic/pdk.sh gf180mcu                                       # the PDK into build/asic/pdk (about 1 GB)
    docker pull ghcr.io/librelane/librelane:3.0.17             # about 7 GB unpacked

`sv2v` and `yosys` on the host (Homebrew) are needed too, as for the FPGA
flow. Then:

    asic/run.sh 1            # one core, 40 ns clock target
    asic/run.sh 2            # strata_top with 2 cores and T2
    asic/run.sh 6            # 6 cores
    asic/render.sh N         # the pictures: asic/results/gf180mcu-N/ (full size), site/hardware/asic/img/ (WebP)
    asic/collect.sh N        # the reports into asic/results/gf180mcu-N/

`ASIC_THREADS` (default 8) is both the container's CPU quota and the thread
count of every OpenROAD step (`asic/bin/openroad-mt` adds `-threads`;
LibreLane by itself runs OpenROAD single-threaded except detailed routing).
`ASIC_TO=Step.Id` stops after a step, `ASIC_FROM=Step.Id` resumes the run
from one (the later step directories are removed first, because LibreLane
resumes from the newest state it finds). Everything lands in
`build/asic/gf180mcu-N/` (`runs/run/NN-step/` per step, `runs/run/final/`).

## What is in the chip

**One core** (`asic/run.sh 1`): `strata_core` itself, with its Transfer Unit,
multiplier, divider and decoder, `NCORES = 1`, the default 16-entry overlay
map. Its two 64 KiB Local Stores and its capability save table are SRAM
macros; the integer registers (3 read ports), the granule-table copy (3
asynchronous read ports), the capability registers, the overlay map and the
Transfer Unit's queue are flip-flops. Everything a core talks to through its
ports (the far bus for transfers and atomics, gift / take, the granule
broadcast, stop) is a pin of the chip: 711 of them.

**N cores** (`asic/run.sh 2`, `asic/run.sh 6`): `strata_top` as
`fpga/synth.sh` builds it (the cores, the far bus, the inbox network, the
revocation-granule walker, core control, a 64 KiB T2), with system memory
(T3) and the device block (`strata_dev`: console, timer, block device,
platform table) off-chip: T3 through the existing `T3_EXT` port, the device
block by turning its instance's ports into pins (`asic/mktop.py top`).

How the RTL gets there, without changing `rtl/`:

| File | What |
|---|---|
| `asic/rtl/gf180mcu/strata_ram.sv` | replaces `rtl/strata_ram.sv` (the Local Stores): 16 rows x 8 byte-wide 512 x 8 macros per 64 KiB |
| `asic/rtl/gf180mcu/strata_sram_w.sv` | 256 x W from ceil(W/8) 256 x 8 macros: the save table (81-bit capabilities, 11 macros) |
| `asic/rtl/gf180mcu/strata_sram_sp.sv` | single-port N x 64 from 512 x 8 macros: T2 |
| `asic/mktop.py core` | `strata_core` with `ctab` replaced by `strata_sram_w` (read in S_EX, written in S_RST / S_CT: never both, so this is exact) |
| `asic/mktop.py mem` | `strata_mem` with its array replaced by `strata_sram_sp` (one read or one write per cycle: exact) |
| `asic/mktop.py top` | `strata_asic_top`: `strata_top` with `T3_EXT = 1`, T2 64 KiB, the device block's ports as pins |
| `asic/mkconfig.py` | the LibreLane configuration and the macro placement |
| `asic/pdn_cfg.tcl` | LibreLane's PDN plus a Metal3-Metal4 connection for the macros' power pins |
| `asic/bin/openroad-mt` | OpenROAD with `-threads` |
| `asic/render.py`, `asic/render.sh`, `asic/annotate.py` | the die pictures (KLayout in the container, Pillow on the host) |
| `asic/summarize.py`, `asic/collect.sh` | the reports |

Floorplan (`asic/mkconfig.py`): a core is a tile 8.8 mm tall, its I-LS (8 x
16 macros, 3.6 x 8.8 mm) on the left, a 3 mm strip for its logic in the
middle with the save table's 11 macros at its foot, the D-LS on the right.
The macros' pins are all on one edge, so the rows go in pairs: the lower
row flipped (pins up), a 120 um channel, the upper row (pins down).
Several cores: tiles in rows of up to three, T2 (8 x 16 macros) and the
system logic in a band below.

## Caveats

- **The Local Stores are not the same RAM.** `rtl/strata_ram.sv` is a true
  dual-port RAM (FPGA block RAM is). GF180MCU's SRAM macros are single-port;
  the stand-in shares one port and gives port A priority, so a Transfer
  Unit access in the same cycle as the core's is lost. A real design needs
  dual-port SRAM (an OpenRAM 1rw1r macro is roughly 1.5-2x the area per
  bit), two banks with a stall, or a double-pumped port. The area and the
  wiring here are of single-port macros. The save table and T2 are exact.
- **The SRAM is large.** The 512 x 8 macro is 0.21 mm2 for 4 Kbit: 128 of
  them per 64 KiB store, 26.8 mm2. Two thirds or more of every die is SRAM.
- **Timing is not optimised.** OpenROAD's post-CTS `repair_timing` died
  without a message in its first iteration (three times), so the runs skip
  it (`RUN_POST_CTS_RESIZER_TIMING`): the clock reported is what synthesis,
  placement, design repair (slew, capacitance, long wires) and CTS give,
  and hold violations are not repaired. Global placement runs without its
  routability and timing loops (with them one core's placement did not
  converge in 90 minutes). Timing-driven placement, post-CTS and
  post-route repair, and a tighter maximum slew than LibreLane's 3 ns are
  the obvious next steps.
- **Signoff steps are off**: no Magic / KLayout DRC, no LVS, no XOR, no
  IR-drop analysis, no antenna sign-off beyond the router's repair (one
  antenna violation is left). The GDS
  is KLayout's stream-out.
- I/O delays are 5% of the period (LibreLane's default is 20%): the pins
  are the far bus and inbox ports, wires to neighbours on a real chip.
- Off-chip in every run: T3 (system memory, DRAM on a board), the device
  block; with one core also the bus, the inboxes and the granule walker.
