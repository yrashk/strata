# Strata on FPGAs

Status: the RTL in `rtl/` is synthesizable and is the same code the
Verilator simulator runs (`make test` compares it, instruction by
instruction, with the C emulator, including a full StrataOS boot). Nothing
here has run on a real board yet.

## What changes between simulation and hardware

| Simulation (`-DSIMULATION`) | Hardware |
|---|---|
| Local Stores loaded through simulator hooks | Boot ROM in the Local Stores' block RAM via `$readmemh` (`ILS_INIT`, `DLS_INIT`) |
| Console through simulator hooks | `rtl/strata_uart.sv` (115200 8N1) |
| System memory (T3): a 64 MiB array | External DRAM through `T3_EXT` and `fpga/rtl/strata_t3_litedram.sv` |
| Disk: the `-d` image | Block-RAM disk initialised from `disk.hex` (`DISK_INIT`) |
| Platform table from the harness | `plat.hex` (`PLAT_INIT`) from `mkhex plat` |

`make fpga-images` builds the four `.hex` files for a 2-core machine with a
128 KiB disk holding StrataOS, `motd`, `rc`, `hello` and `mandel`. Its
platform table gives T2 as 64 KiB (`mkhex plat ... 16 65536`): the FPGA
tops build a 64 KiB cluster store (`T2_W = 8192`) behind a reset capability
that still says 256 KiB, and StrataOS sizes its use of T2 from the table.
There the kernel shared table (32 KiB) goes into T2 but the kernel's code
units (64 KiB) stay in system memory; with the simulator's 256 KiB T2 both
are in T2 (`doc/strataos.md`, 2.1 and 2.9).

## Synthesis numbers

`fpga/synth.sh xc7|ecp5 [NCORES]` synthesizes the system with Yosys 0.70
(through `sv2v`): a 64 KiB cluster store (T2), a 128 KiB block-RAM disk and
a 32 KiB block-RAM stand-in for system memory, which is external DRAM on a
board. It prints the cell counts and checks the log for latches and for
memories built from flip-flops; everything is in `fpga/build/<family>-<n>/`.

These are for the RTL after the core-size work of 2026-11-10 (plan (a),
microarchitecture only, then plan (b), two small ISA changes: slot-aligned
`xmap` and the overlay map's size as a platform parameter); the runs'
summaries, cell counts and logs are kept in `fpga/results/`:

| Yosys, after synthesis | Logic | Flip-flops | Block RAM | Multipliers |
|---|---|---|---|---|
| Xilinx 7-series, 1 core | 30,011 LUTs | 6,869 | 88 RAMB36 + 4 RAMB18 | 4 DSP48E1 |
| Xilinx 7-series, 1 core, 8 overlay map entries (`fpga/synth.sh xc7 1 8`) | 29,078 LUTs | 6,495 | 88 RAMB36 + 4 RAMB18 | 4 DSP48E1 |
| Xilinx 7-series, 2 cores | 58,066 LUTs | 11,713 | 120 RAMB36 + 7 RAMB18 | 8 DSP48E1 |
| Xilinx 7-series, 6 cores | 168,694 LUTs | 31,102 | 248 RAMB36 + 19 RAMB18 | 24 DSP48E1 |
| Lattice ECP5, 1 core | 35,473 LUT4 + 2,873 carry cells = 41,219 LUT4 sites | 6,831 | 180 DP16KD | 4 MULT18X18D |

Before it (commit 0a4bd8a, with the 256-entry save table): 1 core 50,606
LUTs, 12,638 FF, 30 DSP48E1; 2 cores 94,130 LUTs; 6 cores 290,431 LUTs,
73,775 FF; ECP5 1 core 80,999 LUT4 sites, 12,866 FF (an 85F almost
full: it did not route).

The steps, one core on xc7 (`fpga/synth.sh xc7 1` after each commit):

| Step | LUTs | FF | DSP | Block RAM |
|---|---|---|---|---|
| before (0a4bd8a) | 50,606 | 12,638 | 30 | 88 RAMB36 + 1 RAMB18 |
| overlay map: far addresses in 27 bits, I-LS addresses in 16, one subtract per entry | 41,150 | 11,276 | 30 | same |
| capability base / length in 27 bits; two capability read ports; one write each to cd and cs | 36,426 | 9,654 | 30 | same |
| save table in block RAM (+1 cycle for csave / crestore and the x forms); integer registers in LUT-RAM; a reset sequencer | 32,728 | 7,360 | 30 | +3 RAMB18 |
| ltag / linst entry address in its own cycles (+2); a 4-cycle 32 x 32 multiplier | 32,321 | 7,673 | 4 | same |
| Transfer Unit ranges in 17 bits; one adder for addresses and branches; narrow pc + 4 / branch targets | 30,752 | 7,193 | 4 | same |
| inboxes: one small RAM per core, one gift per cycle (end of plan (a)) | 30,530 | 6,871 | 4 | same |
| ISA: slot-aligned `xmap` (the match is an equality under the slot mask); NXMAP a platform parameter | 30,011 | 6,869 | 4 | same |
| the same with NXMAP = 8 | 29,078 | 6,495 | 4 | same |

At the end of plan (a): 2 cores 59,213 LUTs (11,713 FF), 6 cores 172,984 LUTs
(31,104 FF), ECP5 1 core 42,608 LUT4 sites. Plan (b) then took 1.7% off
one core (4.8% with 8 map entries) and 2.5% off six cores: after (a) the
overlay map's range matches were already single 27-bit subtracts, so
making them equalities saved less than it would have before.

The cost in cycles (no instruction's result changes): `csave`,
`crestore`, `csavex`, `crestorex` +1 (4 cycles); `ltag` / `linst` +2;
`mul` 6 cycles (was 3), `mulhu` 7; 256 cycles after reset. Everything
else is unchanged (3 cycles, loads 4). The examples run 0.03% (`parsum`)
to 2.2% (`swcache`, which is mostly `ltag`) more cycles, and the scripted
StrataOS boot and session 1.0% more.

The ltag / linst entry address (a 64 x 64 multiply into the hazard check)
was the longest path; the 64 x 64 single-cycle multiplier was the other.
Both are gone. Placed and routed on an ECP5-85F, one core now runs at
20.0 MHz ("Place and route" below).

Notes on reading the table:

- These are synthesis estimates, not placed-and-routed results. Yosys counts
  LUTs before packing; Vivado usually reports somewhat fewer. On the ECP5 a
  carry cell (CCU2C) takes both LUT4 sites of a slice, so the number to
  compare with a device's size is the "LUT4 sites" sum.
- No latches are inferred. The Local Stores, T2, the T3 stand-in, the
  disk and each core's save table are block RAM on both families; the
  integer registers, the granule-table copies and the inbox queues are
  LUT-RAM. The memories that stay in flip-flops are the small ones that
  are read in parallel: the capability registers, the overlay map and the
  Transfer Unit queue.
- Block RAM: each core has two 64 KiB Local Stores (32 RAMB36, or 64
  DP16KD) and its save table (3 RAMB18); T2 takes 16 RAMB36 (32 DP16KD),
  the disk 32 (64) and the T3 stand-in 8 (16).
- One more core costs about 28,000 LUTs, 4,800 flip-flops, 32 RAMB36 + 3
  RAMB18 and 4 DSP slices on 7-series.
- The overlay map's size is a parameter of `strata_core` / `strata_top`
  (`NXMAP`, 4..16, 16 by default) that the platform table publishes;
  `fpga/synth.sh FAMILY N NXMAP` synthesizes another size. 8 entries are
  enough for StrataOS (`make test-small` boots it that way) and save about
  120 LUTs per entry.

### Where the LUTs went, and what is left

Before this work the overlay map was about 12,000 LUTs of a 47,000-LUT
core: sixteen entries, each with two 64-bit range matches, two 64-bit
subtract-and-add paths and an invalidation compare. The capability
registers were 158 bits wide with three read ports and some twenty-five
write statements, every bounds check a 64-bit adder; the integer register
file was 2,048 flip-flops with three 32-way multiplexers; the save table
was 155 RAM256X1S cells plus 256 valid bits with their own multiplexer.

What made it smaller, in order of effect:

1. **Narrow fields where the architecture guarantees narrow values.** Every
   capability has base + length within its space, so bases, lengths, far
   addresses and overlay entries need 27 bits (the largest space, system
   memory, is 2^26 bytes); Local Store addresses and lengths need 17. A
   64-bit register compared with a narrow length is "any high bit set, or
   the narrow compare", so the 64-bit trap values stay exact.
2. **One port where there were many.** One write port per capability
   register index and one for the integer registers (so they map to
   LUT-RAM); two capability read ports instead of four; one adder in the
   ALU for addresses, branches and comparisons.
3. **RAM for tables that are read one entry at a time.** The save table,
   the integer registers, the inboxes.
4. **Cycles for logic where an instruction is rare.** The save table's
   registered read, the ltag entry address, the multiplier.

What is left, roughly: the capability registers in flip-flops, execute's
result multiplexers and the banked trap CSRs, the Transfer Unit's queue and
hazard compares, the per-core granule-table copy, and in the overlay map
the I-LS-side compares (the link's "is the pc in this slot" and the tgetx
invalidation, 17-bit subtracts per entry; requiring the I-LS slot to be
aligned too would make the first an equality).

### The reset request and the block device's sender binding

The core-control reset request (a core restarted in any mode, its Local
Stores rewritten with the boot ROM) and the block device's pairing of a
buffer only with its submitter's command (manual, "core control" and
"block device") cost, on 7-series with one core (`synth_xilinx`, the
boot ROM images as initial contents, before / after):

| | LUT | FF | RAMB36 | LUT-RAM |
|---|---|---|---|---|
| before | 30047 | 6871 | 88 | 173 |
| after | 31568 (+1521, +5.1%) | 7269 (+398) | 90 (+2) | 159 |

The two RAMB36 are the boot ROM, 4 KiB per Local Store, which each core
keeps to rewrite its stores (a ROM shared by all cores would cost two per
machine, at the price of an arbiter); the reset sequencer's Local Store
write port shares the Transfer Unit's port B (muxes), and the Transfer
Unit's quiet / flush logic is small. Most of the FF increase is the block
device's capability queue, which now moves entries up when one from the
middle is taken (a submitter's buffer behind another core's), so it left
LUT-RAM for flip-flops, plus each queued command's and buffer's core
number. The device's part is per machine; the ROMs and the reset path are
per core.

### What fits where

| System | Board | Use of the device (synthesis estimate) |
|---|---|---|
| 1 core | Digilent Arty A7-100T (XC7A100T: 63,400 LUTs, 135 RAMB36) | 47% of the LUTs, 82 RAMB36 equivalents |
| 1 core | Radiona ULX3S 85F (LFE5U-85F: 83,640 LUT4, 208 DP16KD) | placed and routed: 52.9% of the logic cells, 180 DP16KD (86.5%), **20.0 MHz** (see "Place and route") |
| 2 cores | any ECP5 | does not fit: 81,654 LUT4 sites pack into 86,932 logic cells (103% of an 85F) and need 247 DP16KD (118%) |
| 2 cores | Digilent Arty A7-100T | 92% of the LUTs: on paper only, too full to route comfortably |
| 2 cores | Digilent Nexys Video (XC7A200T: 134,600 LUTs, 365 RAMB36) | 43% of the LUTs, 116 RAMB36 equivalents |
| 6 cores | Kintex-7 325T (203,800 LUTs, 445 RAMB36) | 83% of the LUTs |

The block RAM counts here leave out the T3 stand-in. There is no ECP5
board top or SDRAM adapter in this repository; the ECP5 rows are placed
and routed with the ULX3S pins of `fpga/ecp5/ulx3s.lpf`, but no bitstream
has been made or run.

Two limits apply:

- **StrataOS needs at least six cores** (the system core and five
  servers). A 6-core system is now 168,694 LUTs: still more than any
  Artix-7 (the largest, the 200T, has 134,600), but within a Kintex-7
  325T. The 1- and 2-core systems run bare-metal programs and the boot
  ROM; `make fpga-images` still writes a StrataOS disk image for the
  2-core Arty top, which that machine cannot run.
- **There is no video output on FPGA yet.** The framebuffer window is
  ordinary system memory and nothing scans it out; the console on the UART
  is the only output.

## Board targets

### Arty A7-100T (the reference top; holds one core, not the two it instantiates)

`fpga/arty/strata_arty.sv` is the board top: two cores, the cluster store
(64 KiB) and the disk in block RAM, the USB UART as console, and system
memory in the board's 256 MB DDR3.

1. Generate the DDR3 controller (LiteDRAM, from the LiteX project):
   `pip install litex litedram` then
   `litedram_gen fpga/arty/litedram.yml --name litedram_core`.
   The configuration follows LiteDRAM's own `examples/arty.yml`, with one
   128-bit native user port. Check the port names in the generated
   `litedram_core.v` against `strata_arty.sv`.
2. `make fpga-images`, then copy `fpga/build/images/*.hex` next to the
   synthesis project.
3. Convert the RTL with `sv2v` (or use Vivado's SystemVerilog front end
   directly), add `fpga/rtl/strata_t3_litedram.sv`, `fpga/arty/strata_arty.sv`,
   `litedram_core.v` and `fpga/arty/arty.xdc` (plus the DDR3 pin constraints
   from LiteX's `digilent_arty` platform), and build with Vivado.
4. Connect a terminal at 115200 baud to the board's USB UART and press the
   reset button: the boot ROM prints the platform inventory and loads the
   kernel from the block-RAM disk. (StrataOS itself then needs more cores
   than this top has; see "What fits where".)

On a Nexys Video, take the same steps with LiteDRAM's Nexys Video
configuration, the board's own pin constraints and its 100 MHz clock.

Open items before this can work on a board:
- **Timing closure.** The core is not pipelined and has 64-bit adders and
  comparators in single cycles (the 64×64 multiplier and the ltag entry
  address no longer are). 100 MHz is unlikely; a slower Strata clock with a
  clock-domain crossing to LiteDRAM's user clock may be needed.
- **The DRAM adapter.** It performs one access per 8-byte beat; correct, but
  slow. Bursts would help.
- **Never run on hardware.**

## Place and route (ECP5, nextpnr)

`fpga/ecp5-runs.sh N...` does it all for an N-core system: `fpga/synth.sh
ecp5 N`, `fpga/pnr.sh` (nextpnr), the pictures (`fpga/render.py`), and it
replaces `fpga/results/ecp5-N/` with the results and the wall-clock time of
every stage (`times.txt`). Several N run in parallel; each nextpnr gets
4 threads (`THREADS`), so two runs take under half of an 18-core machine.

`fpga/pnr.sh` places and routes on an LFE5U-85F, CABGA381, speed grade 6
(the Radiona ULX3S part; the LFE5UM-85F has the same fabric), with the
pins in `fpga/ecp5/ulx3s.lpf`: clock, reset, the UART and one LED. The
external system-memory port (`ext_t3_*`, unused with `T3_EXT = 0`) is
taken off the netlist first, which removes ports and no cells. Placer:
nextpnr's static placer (the default HeAP placer could not legalise the
old, nearly full core, and its placements routed far worse); router:
router1; clock target 10 MHz (`CLK_MHZ`; against 50 MHz every path is
critical and the router gains nothing).

Tools: nextpnr-ecp5 `nextpnr-0.11.1-89-g445e2a65` from YosysHQ's OSS CAD
Suite 2026-11-10 for macOS arm64 (no Homebrew formula has nextpnr-ecp5),
unpacked under `build/tools/oss-cad-suite/` (the scripts use it from there
when it is present); Yosys 0.70 and sv2v from Homebrew for the netlists.

Results, RTL of commit d70790f (the core after the size work), 2026-11-11,
an arm64 Mac with 18 cores (other jobs running alongside):

| | 1 core (`ecp5-1`) | 2 cores (`ecp5-2`) |
|---|---|---|
| synthesis | 41,219 LUT4 sites, 6,831 FF, 180 DP16KD, 4 MULT18X18D | 81,654 LUT4 sites, 11,683 FF, 247 DP16KD, 8 MULT18X18D |
| after packing | 44,253 of 83,640 logic cells (52.9%), 180 of 208 DP16KD (86.5%) | 86,932 logic cells (103%), 247 DP16KD (118%): does not fit |
| synthesis time | 98 s | 208 s |
| placement | 71 s (static placer 23 s, refinement 48 s) | not legal; stopped after 538 s |
| routing | 288 s (router1), no congestion left | — |
| nextpnr in all | 366 s | — |
| pictures | 17 s for both (5 s more to write the extract) | — |
| **Fmax** | **20.02 MHz** (estimate after placement: 14.5 MHz) | — |

So one core fits an 85F with room to spare in logic but not in block RAM
(each core's two 64 KiB Local Stores are 64 DP16KD, the cluster store 32,
the disk 64, the T3 stand-in 16): no ECP5 holds two cores, by memory as
much as by logic. The xc7 flow has no timing from open tools: the OSS CAD
Suite's nextpnr has no Xilinx support, and openXC7 (nextpnr-xilinx with a
Project X-Ray chip database) has to be built separately.

**The critical path, 1 core:** 49.9 ns, 15.4 ns of logic and 34.6 ns of
wire (69%), 79 stages (carry cells included). It starts at a read port of
the D-LS block RAM (5.8 ns clock-to-output: the DP16KD's output register
is not used), runs through the `ltag`/`linst` victim compare (a carry
chain), the register file and the trap logic, and ends at the trap cause
register `s_cause` (`fpga/results/ecp5-1/timing.txt`; the cell names on it
are Yosys's nearest named signals). The size work removed the paths that
were longest before: the ltag set address through a multiplier (69 ns on
the old core with 12 overlay entries, 14.5 MHz) and the single-cycle
64 x 64 multiplier. Next would be registering the Local Store read (one
more cycle for loads, or using the DP16KD's output register) and the trap
decision.

Before the size work (commit 0e51b8f) the 1-core system packed into
99.6% of the logic cells: the static placer placed it but router1 had not
finished after an hour; with the overlay map cut to 12 entries it routed
in 77 minutes at 14.5 MHz, with 4 entries in 33 minutes at 15.5 MHz.
Those results are in the history of `fpga/results/` (commit 5b4fcf0).

### Pictures

`fpga/render.py` draws a placed or routed nextpnr design as a die shot: the
fabric (logic tiles as four slices of two LUTs over two flip-flops, block
RAM and multiplier rows, I/O pads) with every placed cell coloured by the
part of the design it belongs to (`fpga/classify.py`: by the RTL signal
Yosys named the cell after; exact for registers and memories, the nearest
named signal for logic), and, for a routed design, every routed wire along
its real span as a glow in its net's colour. The fabric comes from
`fpga/ecp5/lfe5u-85f-bels.json`, which `fpga/ecp5/bels.py` writes from
nextpnr's chip database.

`fpga/results/ecp5-1/` keeps what is needed to draw them again without
placing and routing: `die-data.json.gz` (2.7 MB), an extract of nextpnr's
routed JSON (`fpga/render.py ROUTED.json --extract`) with every cell's
site and group and every routed wire's name and group; nextpnr's own
routed JSON is 130 MB (10.6 MB compressed) and is not kept. To redraw
(17 s for both pictures; the LFS files first, with `git lfs pull`):

```
python3 -m venv build/venv && build/venv/bin/pip install numpy pillow
fpga/ecp5-runs.sh render 1          # die.png, die-placed.png and their WebPs
```

The pictures, 5200x3900 PNG (in LFS) with a 1600-pixel WebP beside each:
`fpga/results/ecp5-1/die.png` (routed) and `die-placed.png` (the cells
only). The fonts are the site's (Space Grotesk, JetBrains Mono) if they are
in `build/fonts/`, else the system's. By the cells' names, of the 1-core
system's logic cells execute with its registers and trap CSRs is about
60%, the capability registers, checks and revocation 16%, the devices and
core control 8.5%, the overlay map 6%, the bus and memories 4%, the
Transfer Unit 3%, the ALU, multiplier, divider and decoder 3%.

The site's hardware page (`site/hardware/`, https://yrashk.com/strata/hardware/)
shows them from copies that are ordinary files, because the Pages workflow
checks out without LFS: `die-ecp5-1.webp` and `die-ecp5-1-placed.webp` are
the 1600-pixel WebPs, the `-2800` ones the same pictures 2800 pixels wide
(from the PNGs, Pillow, WebP quality 88). After a new run, copy them again
and update the page's numbers, which name the commit they are from.

`doc/figures/` has Yosys schematics: the divider and the UART at gate level,
and the system top level.
