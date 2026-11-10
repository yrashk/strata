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
128 KiB disk holding StrataOS, `motd`, `rc`, `hello` and `mandel`.

## Synthesis numbers

`fpga/synth.sh xc7|ecp5 [NCORES]` synthesizes the system with Yosys 0.70
(through `sv2v`): a 64 KiB cluster store (T2), a 128 KiB block-RAM disk and
a 32 KiB block-RAM stand-in for system memory, which is external DRAM on a
board. It prints the cell counts and checks the log for latches and for
memories built from flip-flops; everything is in `fpga/build/<family>-<n>/`.

These are for the RTL of 2026-11-10, before the pointer device was added:

| Yosys, after synthesis | Logic | Flip-flops | Block RAM | Multipliers |
|---|---|---|---|---|
| Xilinx 7-series, 1 core | 47,449 LUTs | 12,675 | 88 RAMB36 | 30 DSP48E1 |
| Xilinx 7-series, 2 cores | 94,658 LUTs | 23,624 | 120 RAMB36 | 60 DSP48E1 |
| Xilinx 7-series, 6 cores | 292,670 LUTs | 73,737 | 248 RAMB36 | 180 DSP48E1 |
| Lattice ECP5, 1 core | 54,947 LUT4 + 9,405 carry cells = 73,757 LUT4 sites | 12,866 | 181 DP16KD | 30 MULT18X18D |
| Lattice ECP5, 2 cores | 106,472 LUT4 + 18,025 carry cells = 142,522 LUT4 sites | 24,028 | 250 DP16KD | 60 MULT18X18D |

Notes on reading the table:

- These are synthesis estimates, not placed-and-routed results. Yosys counts
  LUTs before packing; Vivado usually reports somewhat fewer. On the ECP5 a
  carry cell (CCU2C) takes both LUT4 sites of a slice, so the number to
  compare with a device's size is the "LUT4 sites" sum.
- No latches are inferred. The Local Stores, T2, the T3 stand-in and the
  disk are all block RAM on both families. The memories that stay in
  flip-flops are the small ones that are read in parallel: the integer and
  capability registers, the overlay map, the Transfer Unit queue and the
  inbox queues.
- Block RAM: each core has two 64 KiB Local Stores (32 RAMB36, or 64
  DP16KD); T2 takes 16 RAMB36 (32 DP16KD), the disk 32 (64) and the T3
  stand-in 8 (16). On the ECP5 the capability save table is 5 more per core.
- One more core costs about 47,000 LUTs, 11,000 flip-flops, 32 RAMB36 and
  30 DSP slices on 7-series.

### Where the LUTs go

Per module, from a 2-core 7-series run without flattening (95,142 LUTs in
all; the flattened run above is a little smaller):

| Module | LUTs | Flip-flops | Notes |
|---|---|---|---|
| `strata_core`, each of 2 | 44,190 | 9,590 | |
| - the core's own logic | 39,570 | 8,355 | registers, CSRs, capabilities, overlay map, execute |
| - `strata_tu` | 2,704 | 838 | 4-entry queue with hazard range compares |
| - `strata_alu` | 1,304 | 0 | plus 16 DSP48E1 |
| - `strata_div` | 452 | 396 | iterative |
| - `strata_decode` | 142 | 0 | |
| `strata_top` | 3,278 | 2,267 | inbox queues, domain table, core control |
| `strata_dev` | 1,440 | 1,578 | console UART, disk, timer, framebuffer registers |
| `strata_mem`, T2 and T3 | 1,181 | 419 | |
| `strata_bus` | 846 | 170 | |

So 93% of the logic is the two cores, and inside a core the decoder, ALU,
divider and Transfer Unit together are only a tenth. Synthesizing one core
with a constant changed shows what the rest is:

1. **The overlay map: about 12,000 LUTs per core (30%).** With 4 entries
   instead of 16 the core is 8,900 LUTs smaller, about 740 LUTs per entry.
   Each entry has a 64-bit range match on the call target, a second one on
   the PC (for the return link), two 64-bit subtract-and-add paths and an
   invalidation compare against every transfer into the I-LS: nine or ten
   64-bit carry chains. A core has 179 64-bit adders and comparators before
   mapping, and about 150 of them are here.
   *To shrink it:* fewer entries; store and compare the I-LS side in 16
   bits (the I-LS is 64 KiB, and `xm_ils` is a 64-bit register today);
   require slot-aligned mappings, so that a match is an equality on the
   upper address bits instead of two magnitude compares and an adder (a
   change to the ISA); do the lookup in two cycles, so that one set of
   adders serves the matching entry instead of sixteen sets in parallel.
2. **The capability registers: about 5,400 LUTs per core (14%).** With 4
   registers instead of 16 the core is 4,000 LUTs and 1,900 flip-flops
   smaller. A capability is 158 bits, the file has three read ports and is
   written from many places in the execute state, and every use checks
   bounds with 64-bit adders and compares.
   *To shrink it:* one write port fed by a result mux, LUT-RAM for the
   fields that are not needed in parallel, and base and length fields no
   wider than the largest space of the platform.
3. **Execute, the integer registers and the CSRs: the remaining 22,000
   LUTs or so.** This is one large multi-cycle state machine in which every
   instruction has its own 64-bit operators and result paths, the integer
   register file is 2,048 flip-flops with three 32-way read muxes (its reset
   loop keeps it out of LUT-RAM), and the trap CSRs are banked.
   *To shrink it:* drop the register reset so the file becomes LUT-RAM;
   share one 64-bit adder/comparator among the address, bounds and branch
   computations; mux operands into the shared ALU instead of one operator
   per instruction.

The capability save table is not a consumer: it is LUT-RAM (block RAM on
the ECP5), and shrinking it from 64 to 16 entries changes nothing visible.
The Transfer Unit's hazard checks (four queue entries, each compared with
the PC and the current access) cost about 2,700 LUTs.

### What fits where

| System | Board | Use of the device (synthesis estimate) |
|---|---|---|
| 1 core | Digilent Arty A7-100T (XC7A100T: 63,400 LUTs, 135 RAMB36) | 75% of the LUTs, 80 RAMB36 |
| 1 core | Radiona ULX3S 85F (LFE5U-85F: 83,640 LUT4, 208 DP16KD) | 88% of the LUT4 sites, 165 DP16KD: fits on paper, not placed and routed |
| 2 cores | Digilent Nexys Video (XC7A200T: 134,600 LUTs, 365 RAMB36) | 71% of the LUTs, 112 RAMB36 |
| 2 cores | any ECP5 | does not fit: 142,522 LUT4 sites, and the largest ECP5 has 83,640 |

The block RAM counts here leave out the T3 stand-in. The 2-core system does
not fit the Arty A7-100T (94,658 LUTs against 63,400), so the earlier
statement stands: two cores need an XC7A200T. There is no ECP5 board top,
pin file or SDRAM adapter in this repository; the ECP5 row is a size check
only.

Two limits apply to every row:

- **StrataOS does not boot on one or two cores.** It needs at least six
  (the system core and five servers). A 6-core system is 292,670 LUTs:
  more than twice an XC7A200T, more than the Kintex-7 325T (203,800) and
  410T (254,200), and 98% of a 480T; it needs a Virtex-7 or UltraScale
  part of 350,000 LUTs or more, or a smaller core. The 1- and 2-core
  systems run bare-metal programs and the boot ROM; `make fpga-images`
  still writes a StrataOS disk image for the 2-core Arty top, which that
  machine cannot run.
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
- **Timing closure.** The core is not pipelined and has 64-bit adders,
  comparators and a 64×64 multiplier in single cycles. 100 MHz is unlikely;
  a slower Strata clock with a clock-domain crossing to LiteDRAM's user
  clock may be needed.
- **The DRAM adapter.** It performs one access per 8-byte beat; correct, but
  slow. Bursts would help.
- **Never run on hardware.**

## Pictures

`doc/figures/` has Yosys schematics: the divider and the UART at gate level,
and the system top level. A picture of the chip itself, meaning placed and
routed logic on the FPGA fabric, needs nextpnr. For the ECP5 (ULX3S) that is
`nextpnr-ecp5 --85k --json fpga/build/ecp5-1/strata.json --placed-svg
placed.svg --routed-svg routed.svg` (with a pin constraint file), for the
1-core system only: two cores are larger than the device. nextpnr is not
installed on the machine these numbers come from, so nothing here has been
placed or routed, and no maximum clock frequency is known.
