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
| System memory (T3): a 16 MiB array | External DRAM through `T3_EXT` and `fpga/rtl/strata_t3_litedram.sv` |
| Disk: the `-d` image | Block-RAM disk initialised from `disk.hex` (`DISK_INIT`) |
| Platform table from the harness | `plat.hex` (`PLAT_INIT`) from `mkhex plat` |

`make fpga-images` builds the four `.hex` files for a 2-core machine with a
128 KiB disk holding StrataOS, `motd`, `rc`, `hello` and `mandel`.

## Synthesis numbers

`fpga/synth.sh xc7 2` and `fpga/synth.sh ecp5 2` synthesize the 2-core
system with Yosys (through `sv2v`), with a 32 KiB block-RAM stand-in for
system memory. Results are in `fpga/build/<family>-2/stat.txt`; see the
summary below.

| 2 cores, Yosys | LUTs | Flip-flops | Block RAM | DSP |
|---|---|---|---|---|
| Xilinx 7-series (`synth_xilinx`) | 90,420 | 22,916 | 120 RAMB36 | 60 DSP48E1 |
| Lattice ECP5 (`synth_ecp5`) | @ECP5@ |

Yosys counts LUTs before packing, so Vivado usually reports somewhat fewer.
Most of the logic is not the datapath: it is the 16 overlay map entries
(each matched with 64-bit range comparisons, twice per core), the banked
supervisor/user CSRs, the capability register file and save table, the
per-sender inbox queues and the revocation-domain table.

That is more than the Arty A7-100T's XC7A100T has (63,400 LUTs), so the
2-core system needs a larger part. The **Digilent Nexys Video** (XC7A200T:
134,600 LUTs, 365 RAMB36, 740 DSP slices, 512 MB DDR3, USB UART) holds it
with room to spare, and the Arty top below carries over almost unchanged:
the same DDR3 family through LiteDRAM (`litedram_gen` has a Nexys Video
configuration) and a different pin constraint file.

## Board targets

### Arty A7-100T (too small for 2 cores as built; the reference top)

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
   reset button: the boot ROM prints the platform inventory and boots
   StrataOS from the block-RAM disk.

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
`nextpnr-ecp5 --85k --json fpga/build/ecp5-2/strata.json --placed-svg
placed.svg --routed-svg routed.svg` (with a pin constraint file). Building
nextpnr-ecp5 was not possible in this session.
