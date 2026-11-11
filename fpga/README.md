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
Both are gone; nothing has been placed and routed, so no clock frequency
is known yet.

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

### What fits where

| System | Board | Use of the device (synthesis estimate) |
|---|---|---|
| 1 core | Digilent Arty A7-100T (XC7A100T: 63,400 LUTs, 135 RAMB36) | 47% of the LUTs, 82 RAMB36 equivalents |
| 1 core | Radiona ULX3S 85F (LFE5U-85F: 83,640 LUT4, 208 DP16KD) | 49% of the LUT4 sites, 164 DP16KD: not placed and routed |
| 2 cores | Digilent Arty A7-100T | 92% of the LUTs: on paper only, too full to route comfortably |
| 2 cores | Digilent Nexys Video (XC7A200T: 134,600 LUTs, 365 RAMB36) | 43% of the LUTs, 116 RAMB36 equivalents |
| 6 cores | Kintex-7 325T (203,800 LUTs, 445 RAMB36) | 83% of the LUTs |

The block RAM counts here leave out the T3 stand-in. There is no ECP5
board top, pin file or SDRAM adapter in this repository; the ECP5 row is
a size check only.

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

`fpga/pnr.sh` places and routes the 1-core ECP5 netlist with nextpnr-ecp5 on
an LFE5U-85F, CABGA381, speed grade 6 (the Radiona ULX3S part; the
LFE5UM-85F has the same fabric), with the pins in `fpga/ecp5/ulx3s.lpf`:
clock, reset, the UART and one LED. The external system-memory port
(`ext_t3_*`, unused with `T3_EXT = 0`) is taken off the netlist first, which
removes ports and no cells. The clock target is 50 MHz (`CLK_MHZ=10` for
10 MHz); the placer is nextpnr's static placer (`PLACER=heap` for the
default).

Tools: nextpnr-ecp5 `nextpnr-0.11.1-89-g445e2a65` and Yosys 0.70+368 from
YosysHQ's OSS CAD Suite 2026-11-10 for macOS arm64 (no Homebrew formula has
nextpnr-ecp5), unpacked under `build/tools/oss-cad-suite/`; `fpga/pnr.sh`
uses it from there when it is present. The netlists are from Yosys 0.70
(Homebrew), as in the synthesis table, and all of commit 0e51b8f: before
revocation by address, which changes the capability checks and the top
level (rerun `fpga/synth.sh ecp5 1` and `fpga/pnr.sh` for the current RTL).

What happened (2026-11-10, an arm64 Mac with 18 cores):

| Netlist | Logic cells after packing | Placement | Routing (router1) | Fmax |
|---|---|---|---|---|
| 1 core as synthesized (`ecp5-1`) | 83,345 of 83,640 (99.6%) | default HeAP placer: "unable to find legal placement"; SA placer: stalled at 85,500 of 96,594 cells (stopped after 10 minutes); **static placer: placed** in 5.5 minutes | not finished: 158,000 of 322,499 arcs still unrouted after 64 minutes | 9.8 MHz estimated after placement |
| overlay map 12 entries (`ecp5-1-xmap12`) | 76,462 (91%) | static, 3 minutes | **routed** in 77 minutes | **14.5 MHz** |
| overlay map 4 entries (`ecp5-1-xmap4`) | 65,247 (78%) | static, 3 minutes | **routed** in 33 minutes | **15.5 MHz** |

With nextpnr's default HeAP placer neither reduced netlist routed in about
40 minutes (router1 stalled with 140,000 to 220,000 arcs left; router2's
overuse stopped falling), nor did an 8-entry variant (78,397 cells: Yosys
made it larger than the 12-entry one); the static placer's placements are
much easier to route, so `fpga/pnr.sh` uses it. The routed runs had a
10 MHz target (`CLK_MHZ=10`): against 50 MHz every path is critical and
the router gains nothing from it.

The reduced netlists come from `NXMAP=N fpga/synth.sh ecp5 1`: the overlay
map is a package constant, so the script edits a copy of `strata_pkg.sv`;
`rtl/` is untouched. Fewer overlay entries is an architectural change (the
emulator and the manual say 16), so these are size and speed experiments,
not a Strata that runs the conformance tests. Nothing else was cut.

**How fast: about 14 MHz.** The critical path of the 12-entry run is
69.1 ns: 16.9 ns in logic and 52.2 ns in routing (76%), 73 logic stages (carry cells included). It
starts at the decoded instruction register (`u_dec`), goes through the
operand logic to the tag-lookup setup of `ltag`/`linst`
(`lt_ebase_c = csr_ttag + lt_set_c * lt_span`: a MULT18X18D, 3.9 ns, then
a 64-bit carry chain), the bounds check `lt_ok` (another carry chain) and
the trap decision, and ends at the clock enable of a trap register
(`u_epc`). The 4-entry run's path (64.5 ns) is the same one, ending at
`s_tval`. (The cells on it carry `xm_v` names: Yosys's names for logic are
the nearest named signal, see `fpga/classify.py`; the path follows the
`lt_*` registers.) So the limit is the multi-cycle core doing a whole
instruction's datapath in one cycle, with long wires between the large
blocks, as the "Timing closure" note above expected. Registering the
tag-lookup address (one more cycle for `ltag`/`linst`, which are already
multi-cycle) is the first fix; after it the next paths are the same kind
(address adders, bounds checks and the overlay compares into the trap and
next-state logic). The critical paths are in `fpga/results/*/timing.txt`.

**Why the full core does not route:** routing demand more than logic. At
99.6% of the logic cells there is no slack to spread congestion, and the
design is dominated by 64-bit-wide muxes and compares that all meet in the
execute state (three 32-way register read ports, the 158-bit capability
file, the overlay map) on a fabric whose general routing spans 1, 2 or 6
tiles. The cuts listed under "Where the LUTs go" (overlay lookup in two
cycles, one shared bounds adder, LUT-RAM register files) reduce exactly
this wiring, not only the LUT count.

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

```
python3 -m venv build/venv && build/venv/bin/pip install numpy pillow
fpga/pnr.sh                         # or: gunzip -k fpga/results/ecp5-1/placed-static.json.gz
build/venv/bin/python fpga/render.py PLACED_OR_ROUTED.json die.png \
    --report REPORT.json --web die-1600.webp --note "a line under the title"
```

The fonts are the site's (Space Grotesk, JetBrains Mono) if they are in
`build/fonts/`, else the system's. Pictures (5200×3900 PNG in LFS, a
1600-pixel WebP beside each):

- `fpga/results/ecp5-1-xmap12/die.png`: the 12-entry system, placed and
  routed, with the wiring;
- `fpga/results/ecp5-1/die-placed.png`: the full 1-core system, placed
  only. In it the overlay map takes about 42% of the LUT4 sites in use,
  execute with its registers and CSRs 26%, the capability registers,
  checks and revocation domains 16%, the Transfer Unit 7%.

`doc/figures/` has Yosys schematics: the divider and the UART at gate level,
and the system top level.
