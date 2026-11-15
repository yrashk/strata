# Smarter memory for Strata: what it could buy

2026-11-13. A research note, not a design: the RTL in `rtl/` is unchanged.
The question is whether moving computation and structure into or next to
the Local Store memories can substantially raise the core's speed (clock,
cycles per instruction, throughput) or cut its area, with 10 or more cores
on an affordable process as the goal.

**The answer in five lines.**

1. The Local Stores are 59% of the GF180MCU die, and they are not on the
   critical path anywhere. So memory ideas can win area, and they can win
   cycles; none of them raises the clock of today's core.
2. The largest speed gain is at the I-LS: 62% of the busy cycles are the two
   fetch cycles every instruction pays. An I-LS that keeps its 64-bit word
   (two instructions) and reads the following word by itself takes the
   scripted StrataOS session from 3.22 to about 1.92 cycles per instruction
   (1.7x), the examples 1.7x to 2.0x, for about 160 flip-flops and no ISA
   change.
3. The largest area gain that is a design decision is one single-port memory
   for both stores. The core never uses the I-LS and the D-LS in the same
   cycle, and the Transfer Unit collides with it in 0.1% of the live cycles
   of the StrataOS session, so the second port (1.6x to 1.9x of the macro
   area where a dual-port macro exists, and nonexistent on GF180MCU) buys
   almost nothing.
4. The largest area factor of all is not a design decision: the macro. The
   512 x 8 foundry macro costs 51 µm²/bit; a 1024 x 8 macro for the same
   process costs 19, IHP's open 130 nm 3.6. Ten cores with 128 KiB each are
   536 mm² of SRAM in the first and 38 mm² in the last.
5. An ALU at the store, memory inside the logic and bit-line computing each
   bring a few percent at best here, or cost area, or need custom memory
   that no affordable process offers.

Since this was written the first recommendation has been built
(`STREAM` in `rtl/strata_core.sv`, since made the default) and measured:
section 9. The StrataOS session runs at 1.75 cycles per instruction, 1.84x.
The second has been built too (`LS_1P`, off by default): section 10. It
costs 1.3% of that (5% as first built).

Which numbers are measured, estimated or from the literature is stated per
table and collected in the last section.

## 1. Baseline

### 1.1 How the Local Stores are built and used

Both stores are `strata_ram` (`rtl/strata_ram.sv`): 8,192 words of 64 bits
(64 KiB; `DLS_KIB`, `ILS_KIB` from 4 to 64), true dual-port, synchronous
read (data the cycle after the address), byte write enables.

| | Port A (the core) | Port B (the Transfer Unit; the reset sequencer) |
|---|---|---|
| I-LS | read only: the fetch, in `S_F0` | write only: `tgetx` beats |
| D-LS | read or write: loads and stores in `S_EX`, `ltag`/`linst` in `S_LT`/`S_LW` | read (`tput`, through a two-word prefetch buffer) and write (`tget`) |

On 7-series a 64 KiB store is 16 RAMB36, on ECP5 32 DP16KD. On GF180MCU
(`asic/`) it is 128 foundry macros of 512 x 8, which are single-port: the
ASIC run shares one port with priority to the core, so it measures the area
and wiring of a design that is not yet correct (`asic/README.md`, Caveats).

Cycles, from the state machine (`rtl/strata_core.sv`; the core is
multi-cycle, one instruction at a time):

| Operation | Cycles | Local Store use |
|---|---|---|
| Fetch | 2 (`F0` address, `F1` latch `ir`) | one I-LS read of a 64-bit word, of which 32 bits are used |
| ALU, branch, jump, CSR, capability operation | 3 (fetch + `EX`) | none |
| Load | 4 (`EX` address, `LD` data to the register) | one D-LS read |
| Store | 3 (written in `EX`) | one D-LS write |
| `mul` / `mulhu` / divide | 6 / 7 / iterative | none |
| `csave`, `crestore` | 4 (`CT`) | the save table (its own memory) |
| `ltag` | 3 + 2 (`LG`) + 2 per way probed (+2 on a miss) | one D-LS read per two cycles |
| `linst` | as an `ltag` miss + 2 (`LW`) | two D-LS writes |
| `tget` / `tput` / `tgetx`, the instruction | 3 when the queue (4 entries) has room | none |
| ... the transfer of n words | about n + 3: idle, request, one beat per cycle at best, retire | one port-B access per beat |
| `xcall` / `xret`, mapped | 3 | none |
| ... on a miss | a trap; the handler's `tgetx` (n + 3 cycles for n words), `xmap`, and the call again | n I-LS writes |
| Context switch (StrataOS, software) | about 10,000 dispatcher cycles and 75 KiB moved (measured, below) | the used D-LS out; D-LS and code in |
| Core-control reset | 8,193 | every word of both stores, port B |

The Transfer Unit's data path is already memory to memory: a beat goes from
the far bus to port B (or back) and never crosses the core's datapath.

### 1.2 Area

**GF180MCU, one core, placed and routed** (`asic/results/gf180mcu-1/`,
measured by the kept run; 5 V cells):

| | mm² | of the die |
|---|---|---|
| Die | 93.6 | |
| Local Stores: 256 macros of 512 x 8 (0.2094 mm² each) | 53.6 | 57% |
| Save table: 11 macros | 1.6 | 2% |
| Logic: flip-flops 0.72, combinational 2.00, buffers and inverters 1.48, clock tree 0.10 | 4.3 | 5% |
| Taps, end caps, diodes | 1.1 | 1% |
| Filler: the channels between 267 macros whose pins are on one edge, and the logic strip at 22% density | 29.3 | 31% |

So the memory is the die: the macros, and a third again in the space their
wiring needs. The logic is 5%.

**The logic by module** (measured here: Yosys on `strata_core` alone,
generic NAND / NOR / NOT gates, about one minute, no place and route;
`build/syn/stat-cmos.txt`). The flip-flop total, 11,303, agrees with the
ASIC run's 11,363.

| Module | Transistors in gates | Share | Flip-flops |
|---|---|---|---|
| `strata_core` itself (execute, registers, capabilities, overlay map, CSRs) | 757,000 | 85% | 10,272 |
| `strata_mul` | 68,700 | 7.7% | 133 |
| `strata_tu` | 29,200 | 3.3% | 566 |
| `strata_alu` | 17,100 | 1.9% | 0 |
| `strata_div` | 16,500 | 1.9% | 396 |
| `strata_decode` | 1,900 | 0.2% | 0 |
| the two `strata_ram` wrappers (without the arrays) | 1,700 | 0.2% | 0 |

Of the core's own flip-flops the largest groups are the granule table copy
(256 x 17 = 4,352, read through three asynchronous ports), the integer
registers (2,048), the capability registers (16 x 81 = 1,296) and the
overlay map (16 x 47 = 752). By the names of the placed cells
(`fpga/README.md`): execute with registers and trap CSRs about 60% of the
logic cells, capabilities and revocation 16%, overlay map 6%, Transfer Unit
3%. Everything that touches a Local Store port is a fraction of a percent.

**FPGA** (kept runs, `fpga/results/`): one core 30,011 LUTs and 6,869
flip-flops on 7-series; the store size moves block RAM only (about one
RAMB36 per 4 KiB; 31.5k to 32.1k LUTs from 4/4 to 64/64 KiB).

### 1.3 Timing

Post-route critical paths (measured by the kept runs):

| Run | Period | Critical path | Through a Local Store? |
|---|---|---|---|
| ECP5-85F, nextpnr | 49.9 ns (20.0 MHz), 69% wire | D-LS read port (5.8 ns clock to output) -> `ltag` victim compare -> register file -> trap logic -> `s_cause` | starts at the D-LS read |
| GF180MCU, 5 V cells | 84.1 ns (11.9 MHz) typical | flip-flop -> `am_req`, 95 cells | no |
| GF180MCU, 3.3 V cells | 40.8 ns (24.5 MHz) typical | `ir[29]` -> a flip-flop, 134 cells | no |

The foundry macro's typical cycle time is 6.08 ns at 5 V and 9.24 ns at
3.3 V (datasheet, LITERATURE A1): one seventh to one quarter of the
core's period. The memory is not what limits the ASIC clock.

To see where the Local Stores sit among all paths, `sta/sta.py` computes
the longest path between classes of start and end points over the mapped
netlist (`build/syn/sta.txt`; a logical-effort delay model, so the unit is
technology-independent). The mapping is area-oriented with ripple carries,
so the absolute depths are far above a timing-driven flow's; only the
ratios mean something:

| Path | Relative depth |
|---|---|
| overlay map / `pc` -> integer register (the link `xcall` writes) | 1.00 |
| `ir` -> `pc` (decode, register read, compare or add, next pc) | 0.73 |
| `ir` -> multiplier | 0.61 |
| `ir` -> D-LS port A address and write enable (register read, 64-bit add, bounds, hazard) | 0.51 |
| D-LS read data -> integer register (load: shift, sign-extend; `ltag`: compare, add) | 0.35 |
| save table read -> capability register | 0.24 |
| Transfer Unit -> D-LS port B | 0.11 |
| `pc` -> I-LS port A address (with the fetch hazard) | 0.09 |
| I-LS read data -> `ir` | 0.01 |

Paths that end at a store's address are about half the deepest logic; the
path that starts at D-LS read data about a third; the I-LS has no logic on
either side. On the FPGA the D-LS read heads the critical path only because
block RAM clock-to-output is 5.8 ns and `ltag` compares the data at once;
`ltag` already takes two cycles per way, so using the block RAM's output
register there costs nothing.

**Consequence.** Nothing that moves logic toward the memory shortens the
clock of this core. The clock is set by the execute cycle (overlay link,
next pc, traps). Memory-side ideas have to earn their keep in cycles or in
area.

### 1.4 Where the cycles go

Measured with a profiler bound into every core of the Verilator model
(`prof/ls_prof.sv`; the console output of every example is identical to
`build/strata-rtl`'s) and a model over the instruction trace
(`model/fetch.py`). 8 cores, 64/64 KiB. "Busy" leaves out reset, halt and
cycles in which an instruction only waits (for a gift, `twait`, `tany`, a
device, a far atomic's turn); the StrataOS session is 82% such waiting
because its cores are mostly idle.

| | StrataOS session (`os/demo.txt`) | `mandel` | `pipeline` | `swcache` |
|---|---|---|---|---|
| Instructions | 62.4 M | 279 k | 42 k | 438 k |
| Busy cycles per instruction | 3.22 | 4.02 | 3.29 | 3.17 |
| Fetch (`F0` + `F1`) | 62.1% | 49.7% | 60.7% | 63.1% |
| `EX` | 31.0% | 24.9% | 30.4% | 31.5% |
| Load data (`LD`) | 3.3% | 0.1% | 3.0% | 0.3% |
| Multiply / divide | 1.4% | 25.2% | 5.9% | 1.9% |
| Tag lookup | 0 | 0 | 0 | 3.2% |
| Far atomic in flight | 2.2% | 0 | 0 | 0 |
| Loads / stores, of instructions | 10.8% / 5.3% | 0.5% / 0.6% | 9.7% / 9.9% | 0.9% / 15.0% |
| D-LS port A used, of busy cycles | 5.0% | 0.3% | 6.0% | 6.3% |
| Transfer Unit beats | 13.3 M | 2.0 k | 8.4 k | 77.8 k |
| Core and unit want a store in the same cycle (if the two stores were one memory) | 10.1% of the beats, 0.7% of busy cycles | 3.5% | 0.8% | 0.2% |

The StrataOS session in more detail (all measured):

- **Fetch.** The next instruction is in the 64-bit word just read 33% of the
  time, in the following word 40%, somewhere else 26% (short, branchy
  code). The examples: 40-47% / 40-46% / 7-20%.
- **Loads and stores.** 39.8% of loads are used by the very next
  instruction (ALU or branch); in 13.3% that instruction also overwrites
  the loaded register. Load, operate, store back to the same address: 4.8%
  of stores, nine in ten an `addi`. 43% of loads and 38% of stores are
  relative to `sp` or `gp`. 14.6% of stores follow a store 8 bytes away
  (register saves).
- **Locality.** The busiest 4 KiB of the D-LS take 52% of the core's
  accesses and 16 KiB take 84%; for the fetch 65% and 97% (all cores and
  processes together; 49 and 45 of the 64 one-KiB blocks are touched at
  all).
- **Transfers.** 105 MB moved: `put` 59.6 MB, `get` 38.2 MB, `getx`
  7.4 MB (0.93 M I-LS words; 554 kernel code units paged in, 7,650 `xcall`,
  12,536 `xmap`). 56% of the instructions run in supervisor mode.
- **Context switches** (the kernel's own counters, `uptime` and `cores`):
  716 switches, 53,780 KiB moved by them, about half of all bytes moved; 75
  KiB and 9,600 to 10,800 dispatcher cycles per switch. Together about 7.4 M
  dispatcher cycles and 6.9 M beats: 7% to 8% of the busy cycles of this
  session. At the session's time slices (1 and 2 ms of a 100-cycles-per-
  microsecond clock) that is small; at the 24.5 MHz of the GF180MCU run one
  switch (roughly 22,000 cycles with its transfers) is 0.9 ms.
- **Overlay paging**: under 0.5% of the busy cycles (0.93 M beats).

## 2. Direction 1: an ALU next to the Local Store

Four different things hide under this name.

**2.1 Address generation at the I-LS: the instruction stream.** The I-LS
port A is used in one cycle of three and delivers 64 bits of which the core
uses 32. Give the memory side a small sequencer: keep the word (the next
instruction is in it one time in three), and read the following word
whenever the port is free, with the incrementer at the memory. The core
then tells the store only where a transfer of control goes. Sequential code
has no fetch cycles at all; a taken branch, jump or trap costs the two
cycles it costs today, and one more when it lands on the second instruction
of a word.

- Gain (trace model, measured instruction streams): fetch cycles per
  instruction 2.00 -> 0.70 for StrataOS, 0.16 to 0.60 for the examples.
  Cycles per instruction: StrataOS 3.22 - 2.00 + 0.70 = 1.92, **1.68x**;
  `swcache` 3.17 -> 1.58 (2.0x); `mandel` 4.02 -> 2.18 (1.84x); `pipeline`
  3.29 -> 1.89 (1.74x). Keeping the word alone, without reading ahead:
  1.335 fetch cycles, 1.26x.
- Area: `exp/ls_unified.sv` (which also does 3.1) is 161 flip-flops and
  about 4,700 transistors of gates: about 0.02 mm² in the 5 V cells
  (10.98 µm² per NAND2, 63.6 µm² per flip-flop in the kept run), 0.5% of
  the logic.
- Clock: the new logic sits between `pc` and the I-LS address and between
  I-LS data and `ir`, the two shallowest paths of 1.3. Giving the branch
  target to the memory in `EX` itself would save one more cycle per taken
  branch (0.70 -> 0.44) but hangs the memory's address setup on the
  second-deepest path; not recommended.
- Costs and risks: `tgetx` over words the stream holds must empty it (done
  in the experiment; the architecture's fetch hazard covers only the pc);
  traps and stops take effect at the same instruction boundaries; the
  fetch-fault checks (`pc` outside the I-LS, unaligned) move to the
  redirect. Cycle counts change, no instruction's result does: the
  emulator stays the reference, but the timing-dependent sessions of
  `make test` will interleave differently.
- ISA: none.

**2.2 Memory-operand instructions and operate-in-place** (`add rd, rs,
[mem]`; `inc [mem]`). The second ALU would sit behind the D-LS read data.

- Gain: at most the 39.8% of loads used at once, 4.3% of instructions, save
  one instruction each: 4.3% x 3 / 3.22 = 4.0% of the cycles today; only
  the 13.3% whose register dies are certain: 1.3%. Increment in place:
  145,854 cases x 2 instructions = 0.5%. After 2.1 the percentages are
  about the same of a smaller total.
- Cost: one more 64-bit adder and operand mux (the ALU is 17,100
  transistors, 2% of the logic), and the load cycle's path becomes D-LS
  data -> ALU -> register (0.35 plus about 0.3 of the deepest path: it
  still fits). New encodings.
- ISA: new instructions. Not worth it for 1% to 4%.

**2.3 Address add inside the memory** (the Cell SPE's sum-addressed decoder,
LITERATURE B4, B9). It removes the 64-bit add from the path to the D-LS
address (0.51 of the deepest path: not critical here) and needs a custom
decoder. No foundry or OpenRAM macro offers one. Not realistic, and no gain
until the core is pipelined.

**2.4 Copy, fill, checksum at the store.** A sequencer on port B could copy
or fill inside the D-LS at one or two cycles per word, where a loop costs
about 16 (load, store, two `addi`, branch). It would be a Transfer Unit
command whose far side is the Local Store itself.

- Gain: unknown and probably small. The only trace evidence is stores 8
  bytes apart (14.6% of stores, 0.8% of instructions), and those are mostly
  register saves, not copies. The large copies of this system already go
  through the Transfer Unit.
- ISA: a new transfer kind. Keep as an idea; measure `memcpy`-like loops in
  the programs before building anything.

## 3. Direction 2: the D-LS and the I-LS closer together

**3.1 One single-port memory, shared in time.** The core uses the I-LS in
`F0` and the D-LS in `EX`, never both; the unit moves one word per cycle at
most. So one single-port array of 128 KiB can serve the fetch, the data
port and the unit by taking turns. The Cell SPE did exactly this with its
256 KiB store (single-ported; fetch, load / store and DMA arbitrated:
LITERATURE B4).

- Evidence: in the StrataOS session the core and the unit want the memory
  in the same cycle in 1.34 M cycles: 0.1% of the live cycles, 10.1% of the
  unit's beats. If each collision delays the unit by one cycle the cost is
  below 0.7% of the busy cycles, and nothing on the core's side. In the
  examples 0.2% to 3.5% of the beats.
- With the stream of 2.1 the memory is busier (a read per two instructions
  while the core executes). `exp/ls_unified.sv` implements both with the
  priority data > a starving stream > the unit > reading ahead; its test
  bench (random traffic, 400,000 cycles per mix, checked against an array,
  including unit writes over code about to run; no errors) gives, with a
  core that could run one instruction per cycle and jumps every eighth
  instruction: 0.92 cycles per instruction with the unit idle; 1.67 with
  the unit asking in every cycle, which is then served in 45% of them. A
  transfer slows the core and the core slows a transfer, each by about a
  factor of two in the worst case; both keep moving.
- Area: where a dual-port macro exists it costs 1.9x a single-port one
  (IHP SG13G2, at equal size) or 1.6x to 1.8x (SKY130 OpenRAM); a
  single-port design saves 40% to 47% of the memory, and with it of the
  die. On GF180MCU there is no dual-port macro: this is what makes the
  93.6 mm² design buildable at all, and one 16,384-word array needs fewer,
  larger macros than two of 8,192 words where larger macros exist (section
  5.1).
- Alternative with the same effect and no arbitration: two accesses per
  core clock through one port. The macro's cycle is 9.24 ns against a 40.8
  ns clock (3.3 V), so it fits with margin today; it would stop fitting if
  the core were pipelined to a much shorter cycle.
- Costs and risks: the Transfer Unit must accept a refusal on port B (a
  `tget` beat arriving from the bus needs a one-word buffer or bus
  back-pressure, which `tu_wready` / `b_rvalid` do not have in that
  direction today); the reset sequencer shares the port as now.
- ISA: none.

**3.2 A movable split.** With one array, where code ends and data begins is
a register rather than two fixed sizes. Both bounds checks exist; the split
would be a platform parameter or a supervisor CSR.

- Gain: no bits by itself. It lets a platform ship less memory per core
  (for example 64 KiB in all: half the SRAM, 26.8 mm² of the 53.6 on the
  foundry macros) and still run code-heavy and data-heavy programs. The
  floor today is software: StrataOS's ABI wants 64 + 64 KiB (and touches 49
  and 45 of the 64 one-KiB blocks of each store in the session), Forth
  likewise; the bare-metal examples run in 32/32 and several in 16/4 KiB
  (`make test-ls`).
- ISA: small (a CSR or platform-table field); the OS ABI is the real work.

**3.3 Several resident contexts in one store.** With a base and a limit per
store (addresses relative to the base), two or three small processes can
stay in a core's store at once, and switching between them moves no data.

- Gain: up to the whole 75 KiB and roughly 12,000 cycles of transfers per
  switch, for the switches between resident processes; in the session the
  switches are mostly servers woken by requests, which is the case that
  profits. At most the 7% to 8% of section 1.4 there, far more for a
  machine at 10 to 25 MHz with short time slices.
- Cost: an add of the base in the address path (the D-LS address path has
  slack, section 1.3), more memory per core or smaller processes, and an
  ABI in which programs say how much they need.
- ISA: supervisor CSRs, relative Local Store addresses in user mode. A
  large change; the idea to keep in mind when the ABI is next opened.

**3.4 Overlay paging and context switches under one store.** Paging is
unchanged (`tgetx` writes the instruction part). The cheap memory-side help
for the switch is a dirty map: one bit per KiB set by port-A writes, read
and cleared through a CSR, so the dispatcher writes back only blocks that
changed since they were loaded (today it saves the whole used data and the
live stack). 64 to 128 flip-flops. The saving is not measured: it needs the
count of blocks written per time slice, which the profiler does not yet
record. ISA: one supervisor CSR.

## 4. Direction 3: the memory inside the logic

Small distributed memories (latch or flip-flop arrays, register-file-like
banks) for a hot part, a dense macro for the rest.

- Density: standard-cell memory is 31 to 38 µm²/bit on SKY130, flat with
  size, against 6.9 to 13 for OpenRAM single-port macros (LITERATURE A2,
  A6). On GF180MCU a flip-flop alone is 63.6 µm²; with read muxes an array
  will not beat the 512 x 8 macro's 51 µm²/bit, only the 64 x 8 and 128 x 8
  macros (196 and 113). The crossover on that process is around one or two
  kilobits.
- The project's own evidence: the save table as 20,736 flip-flops made the
  core 5.7 mm² of cells instead of 3.0 and design repair run for hours
  (`asic/README.md`).
- Timing: nothing to win now. The macro cycles in 6 to 9 ns against a 41 to
  84 ns clock, and the paths that start or end at a store are a third to a
  half of the deepest logic (1.3).
- A hot tier would also be a poor fit: the busiest 4 KiB hold 52% of the
  data accesses and 65% of the fetches (1.4), so a small fast store would
  miss often.

Negative for area, neutral for speed. It becomes interesting only for a
pipelined core at a clock where a 64 KiB macro needs two cycles (the SPE's
needed six at 11 FO4, its register file three: LITERATURE B4), and then as
a small store in front, not as the Local Store spread through the logic.

## 5. Beyond the three

**5.1 What the macros really cost** (LITERATURE A1-A3; areas from LEF
files; per core = 2 x 64 KiB = 1,048,576 bits):

| Memory | Port | µm²/bit | 128 KiB per core | 10 cores |
|---|---|---|---|---|
| GF180MCU foundry 512 x 8 (5 V), used today | single | 51.1 | 53.6 mm² | 536 mm² |
| GF180MCU `gf180mcu_ocd_ip_sram` 1024 x 8 (3.3 V) | single | 19.0 | 19.9 mm² | 199 mm² |
| SKY130 OpenRAM, 8 kB class | single | 6.9 | 7.2 mm² | 72 mm² |
| SKY130 OpenRAM, 8 kB class | 1RW + 1R | 12.0 | 12.6 mm² | 126 mm² |
| IHP SG13G2 8192 x 32 | single | 3.59 | 3.8 mm² | 38 mm² |
| IHP SG13G2 1024 x 32 | true dual | 8.06 | 8.5 mm² | 85 mm² |
| 28 nm compiled (bitcell 0.12 to 0.20 µm²; macro density not public: assumed 0.3 to 0.4) | single | 0.3-0.4 | 0.3-0.4 mm² | 3-4 mm² |

The foundry GF180MCU macro is periphery: 8 bits wide in a 432 µm frame,
with a 13.5 µm² cell under 51 µm² per bit. The largest slot of the current
GF180MCU shuttle (wafer.space) is 20.1 mm² (12.9 inside the pad ring), so
one core with today's stores does not fit one, with either macro. The 1024 x 8 macro is also what
the 3.3 V cell run (24.5 MHz) would pair with. On IHP's process the stores
of one core are smaller than its logic is likely to be, and the question
turns into the cost per mm² (2,800 to 7,300 EUR). These are choices of
process and macro, not of architecture, but they are worth 2.7x to 14x, and
every design idea here is worth 2x at most. A macro compiler for GF180MCU
with 32- or 64-bit words (OpenRAM has a technology directory for it; no
published macro) would also remove most of the 29 mm² of channels that 267
narrow macros need.

**5.2 Computing in the memory array** (bit-line logic, configurable CAM:
Compute Caches, Neural Cache, Duality Cache, CAPE, EVE, Jeloka's 6T
BCAM/TCAM; LITERATURE B1, B6). All of it drives several word lines at once
and senses the bit lines differently, on push-rule foundry cells with
custom periphery; reported overheads are 3.5% to 15% of the array, the
gains are for data-parallel workloads on megabytes. None works with a
black-box macro and no open-PDK tapeout was found. Strata's would-be users
of a CAM are the overlay map (16 entries, already flip-flops with
comparators, 6% of the logic) and `ltag` (a software cache's tag search,
3.2% of `swcache`'s busy cycles, nothing in StrataOS). Not realistic on
GF180MCU, SKY130 or a shuttle with compiled macros, and not needed.

**5.3 Smaller or tiered stores.** A small fast store plus a large slow one
is section 4's idea and fails on the same locality numbers. Smaller stores
are 3.2.

**5.4 The Transfer Unit's path.** Already memory to memory (1.1). In the
examples a memory transfer runs at 1.1 to 1.5 cycles per beat including
request and retire. What is left to take is on the far side: bus width and
the far memory's beat rate.

**5.5 Capability checks and revocation in memory.** Every core holds a copy
of the granule table: 4,352 of its 11,363 flip-flops (0.28 mm² in 5 V
cells, plus three 256-to-1 read muxes of 17 bits), because three
capabilities are checked in the same cycle as the instruction executes. In
a memory it would be one 256 x 17 array per read port with a synchronous
read; the stream of 2.1 has the instruction a cycle before it executes, so
the operand capability's granule could be read ahead. Perhaps 0.3 to 0.4
mm² per core: 7% to 9% of the logic, 0.4% of today's die. It starts to
matter when the SRAM is small (IHP-class density), not before. CHERI's
practice is the same in spirit: checks ride with the access and the tables
live in memory behind small caches (LITERATURE B7).

**5.6 One port or two.** Section 3.1. Dual-port costs 1.6x to 1.9x where it
exists.

**5.7 Registers and tables in the Local Store.** The integer registers as
memory words (TMS9900 workspace, transputer: LITERATURE B3) would save
2,048 flip-flops (0.13 mm²) and make a context switch a pointer change, and
would cost two or three more reads per instruction on a single port:
against the goal. The save table (256 x 81 bits, 11 macros, 1.6 mm² at 78
µm²/bit) could be 512 words at the top of a unified store: its instructions
already take a cycle for the read. Saves about 1 mm² on the foundry
macros, less elsewhere. The overlay map belongs where it is.

## 6. Ranking

Area and speed are for one core; "today" is the GF180MCU run and the
StrataOS session. M = measured here or by a kept run, E = estimated from
measured numbers (arithmetic in the section), L = from the literature or
from published macro sizes.

| # | Idea | Area | Speed | Effort | ISA | Confidence |
|---|---|---|---|---|---|---|
| 1 | Instruction stream at the I-LS (2.1) | +0.02 mm² (M: gate count) | 1.68x StrataOS, 1.7x-2.0x examples, fewer cycles per instruction (E: trace model on M traces); clock unchanged | medium: the core's fetch states, `tgetx` invalidation, the timing-dependent tests | none | high |
| 2 | One single-port memory for both stores (3.1) | -40% to -47% of memory against a dual-port build (L); on GF180MCU makes today's area real (M) | -0.7% at most (M: collisions) | medium: Transfer Unit takes refusals, new `strata_ram` | none | high |
| 3 | Denser macro or process (5.1) | 2.7x (1024 x 8 on GF180MCU) to 14x (IHP) less memory (L) | none; 3.3 V cells go with it | flow work, no RTL | none | high for the arithmetic, medium for the flow |
| 4 | Dirty-block map at the D-LS (3.4) | +64-128 flip-flops (E) | part of 7-8% (switch traffic); not measured | low, plus the dispatcher | one CSR | medium-low |
| 5 | Movable split, less memory in all (3.2) | up to -50% of memory for software that fits (E) | none | medium RTL, large for the OS ABI | small | medium |
| 6 | Resident contexts: base and limit (3.3) | more memory, or smaller processes | removes up to 75 KiB and about 12,000 cycles per switch (E) | large (OS, ABI) | CSRs, relative addresses | low |
| 7 | Granule table in memory (5.5) | -0.3 to -0.4 mm² (E), 0.4% of the die | one more cycle unless read ahead | medium | none | low-medium |
| 8 | Save table inside the store (5.7) | about -1 mm² on foundry macros (E) | none | low | none | medium |
| 9 | Memory-operand ALU, operate in place (2.2) | +2% of logic (E) | +1.3% to +4% (E on M counts) | medium | new instructions | medium |
| 10 | Copy / fill at the store (2.4) | small | unknown, probably under 1% | low-medium | new transfer kind | low |
| 11 | Memory inside the logic, hot tier (4, 5.3) | worse: 2x to 5x per bit (L) | none at these clocks (M) | medium | none | high (that it does not pay) |
| 12 | Address add in the decoder (2.3) | none | none until pipelined | needs a custom macro | none | high (not available) |
| 13 | Bit-line computing, CAM in SRAM (5.2) | +3.5% to +15% of the array (L) | none for this workload | custom memory | new instructions | high (not available) |
| 14 | Registers in the Local Store (5.7) | -0.13 mm² (E) | slower: more reads per instruction | large | none | high (that it does not pay) |

## 7. Recommendation

Prototype these, in this order.

**First: the instruction stream at the I-LS.** It is the only idea that
changes throughput by a large factor (1.7x to 2.0x), it costs 0.5% of the
logic, and it needs nothing from the ISA or the process. The prototype:
`strata_core` with the fetch taken from a stream front end like
`exp/ls_unified.sv` (two-word buffer, read-ahead, redirect on a transfer of
control, emptied by an overlapping `tgetx`), behind a parameter that
defaults to today's fetch; then `make test`, the profiler's cycles per
instruction against the model's 1.92 for StrataOS, and one FPGA synthesis
of the core to confirm the fetch paths stay shallow.

**Second: one single-port memory for both stores.** It is what a correct
ASIC needs in any case (GF180MCU has no dual-port macro), it costs under 1%
in cycles, and with the first prototype it is the same front end. The
prototype: `strata_ram` replaced by one single-port array behind
`ls_unified`, the Transfer Unit accepting a refused beat, `make test`; then
the ASIC flow with honest single-port memory and the 1024 x 8 3.3 V macros
(item 3), which together should take the stores of one core from 53.6 to
about 20 mm² and the die with them. That run is the one that says what a
core really costs on GF180MCU. For 10 or more cores on one die the
arithmetic of 5.1 already says GF180MCU is not the process: with these two
changes and a 130 nm process with real macros (IHP: 3.8 mm² of memory per
core) the memory stops being the problem and the logic (about 3 mm² of
cells in 5 V GF180MCU) becomes the thing to shrink.

**Third, small and separable: measure before building.** Add to the
profiler the blocks written per time slice and the share of cycles in
copy-like loops; they decide whether the dirty-block map (item 4) and the
copy command (item 10) are worth an afternoon each. Item 5 (less memory per
core through a movable split) is the next real area step after the second
prototype, and is mostly an OS ABI question.

Not recommended: an ALU on the data path at the store, standard-cell or
tiered Local Stores, and anything that needs a custom memory array.

## 8. Measured, estimated, from the literature

**Measured in this work** (scripts in this directory; outputs under
`build/`, not kept in git):
- Cycle shares, port use, collisions, transfers, instruction mix, locality:
  `prof/build.sh`, `prof/run.sh`, `prof/report.py` on the examples and the
  scripted StrataOS session (8 cores, 64/64 KiB, one run each).
- Fetch-scheme cycle counts and instruction pairs: `model/fetch.py` on the
  instruction traces of the same runs. The cycle counts are a model applied
  to measured traces, not a run of a changed core.
- Per-module gate and flip-flop counts; the relative path depths of 1.3:
  one Yosys run on `strata_core` alone (`build/syn/`), `sta/sta.py`.
  Generic gates, area-oriented mapping, no wires: ratios only.
- `exp/ls_unified.sv`: correct under random traffic in its test bench;
  gate count. Not connected to the core.

**Measured by runs kept in the repository:** the GF180MCU die, its area by
class and its timing (`asic/results/`); FPGA sizes and the ECP5 critical
path (`fpga/results/`, `fpga/README.md`); the context-switch counters are
StrataOS's own.

**Estimated:** every gain in sections 2 to 5 and in the ranking marked E;
the area of small additions (cell areas from the kept run times gate
counts); the 28 nm row of 5.1; the logic area on other processes; the cost
of a context switch in cycles including its transfers (beats at the
examples' 1.1 to 1.5 cycles per beat).

**From the literature and published files** (`LITERATURE.md`, with links):
macro sizes and densities, bitcells, dual-port ratios, shuttle slots and
prices, the Cell SPE's Local Store, compute-in-memory overheads, standard-
cell memory densities, CHERI's tag and revocation mechanisms. Not verified
there, and so not relied on here: compiled-macro densities below 65 nm,
whether a small team can get a memory compiler for them, and any measured
double-pumped macro.

**Not done:** no place and route and no liberty-based timing (no PDK is
installed in this checkout, and whole-core runs were kept to one synthesis
on purpose); the profile is one session of one OS build, with idle cores.
Sections 1 to 8 describe the RTL before the change of section 9.

## 9. The first prototype: the stream fetch, measured

`rtl/strata_core.sv` has a parameter `STREAM`. It was added with the
default 0 (the fetch of sections 1 to 8, cycle for cycle) and measured
against it; it is now 1 by default, `make STREAM=0` builds the simulator
without it and `make test-nostream` keeps that setting tested.
`strata_top` passes it to every core.

**What it does.** The core keeps the I-LS word that `F1` read (`fb_cur`)
and reads the word after it through the idle port A while it executes
(`fb_nxt`). An instruction that retires to pc + 4 and finds its successor
in one of the two goes straight to `EX` with it. Everything else goes
through `F0` and `F1` as before, which keeps every check where it was:

- transfers of control and traps (a taken branch, `jal`, `jalr`, `xcall`,
  `xret`, `eret`);
- every transfer instruction, so the fetch hazard of an overlapping
  `tgetx` and the wait for a core-control write are still decided in `F0`;
- a pending stop (in user mode) or reset request.

Nothing is read ahead while a `tgetx` is in the Transfer Unit's queue (a
new output of `strata_tu`, `getx_busy`), so a word that is about to be
replaced is never held. The read-ahead is decided from registered state
only (the state, two flags, `pc`), so no execute-stage logic reaches the
I-LS address. This is simpler than `exp/ls_unified.sv`: there is no
redirect port, and a transfer of control costs exactly what it costs
today.

**Cycles per instruction** (profiler, busy cycles; the model is section
2.1's "stream"):

| | `STREAM = 0` | model | `STREAM = 1` | Speed-up |
|---|---|---|---|---|
| StrataOS session | 3.22 | 1.92 | 1.75 | 1.84x |
| `mandel` | 4.02 | 2.18 | 2.17 | 1.85x |
| `pipeline` | 3.29 | 1.89 | 1.69 | 1.95x |
| `swcache` | 3.17 | 1.58 | 1.56 | 2.03x |
| `gfx` | 3.60 | 1.79 | 1.74 | 2.07x |
| `parsum` | 3.21 | | 1.49 | 2.15x |
| `stream_sum` | 3.22 | | 1.50 | 2.15x |

The RTL beats the model where control often lands on the second
instruction of a word: the model charged a cycle there, but the read-ahead
issued in `F1` arrives in time. In the StrataOS session 26.6% of the
instructions still go through `F0` and `F1` (0.53 of the 1.75 cycles);
what is left is `EX` 57%, fetch 30%, load data 6%, far atomics 4%,
multiply and divide 2.5%.

**Whole runs** (clock cycles until every core halts, 8 cores; they
include waiting):

| | `STREAM = 0` | `STREAM = 1` | |
|---|---|---|---|
| StrataOS session | 148.2 M | 86.8 M | 1.71x |
| `mandel` | 241,785 | 127,506 | 1.90x |
| `parsum` | 884,515 | 448,575 | 1.97x |
| `swcache` | 1,479,898 | 783,968 | 1.89x |
| `pipeline` | 89,725 | 51,405 | 1.75x |
| `gfx` | 10.00 M | 6.67 M | 1.50x |

**One memory for both stores, again.** With the read-ahead the I-LS port
is busier: in the StrataOS session the core and the unit would want a
shared single-port memory in the same cycle in 1.43 M cycles (1.34 M
before): 11.3% of the unit's beats, 1.3% of the busy cycles. Section 3.1's
conclusion stands.

**Checked.** `make test` passed with `STREAM = 0` and with `STREAM = 1`
(each as a whole run, before the default changed): every
example in lockstep with the emulator (console, halt state, every core's
instruction trace), the scripted StrataOS and guest sessions, the break,
preemption, isolation, guest, network and window-server tests, the
conformance suite on interpreter, JIT and RTL, the 8-entry overlay map and
the smaller Local Store sizes, and the browser build against the native
one. (The browser build's rule had to be given the parameter too, or it
compares a default machine with a stream one.)

**Area and depth** (measured: `sta/core.sh 0` and `sta/core.sh 1`, one
core alone through Yosys to generic gates and `sta/sta.py`; no place and
route):

| | `STREAM = 0` | `STREAM = 1` | |
|---|---|---|---|
| Gates, in transistors | 730,340 | 759,286 | +4.0% |
| Flip-flops | 11,367 | 11,465 | +98 |
| Deepest path (overlay map -> integer register), relative | 1.00 | 1.005 | |
| `ir` -> `pc` | 0.72 | 0.74 | |
| `ir` -> `state` | 0.53 | 0.52 | |
| `ir` -> `ir` (new: the successor is chosen at the retire) | none | 0.50 | |
| `pc` -> I-LS port A address | 0.10 | 0.09 | |
| I-LS read data -> `ir` | 0.01 | 0.06 | |

The same RTL mapped twice differs by about 0.8% in gates, and the depths
by a few percent, so only the gate count's increase and the new `ir` path
are real differences. The increase is larger than section 2.1's estimate
(0.5%): the successor's 32 bits are multiplexed into `ir` at every place an
instruction retires. 98 flip-flops, not 130: the low half of the kept word
is never read again. In the 5 V cells of the kept ASIC run that is about
0.09 mm² (7,200 NAND2 equivalents at 10.98 µm², 98 flip-flops at 63.6
µm²), 3% of the core's cells and 0.1% of the die. No path became the
deepest: the new one into `ir` is as deep as the path into `state`, half
the deepest, and the I-LS address still comes from registers. A clock
figure needs place and route (`fpga/synth.sh` needs a `chparam` for
`STREAM` first).

## 10. The second prototype: one single-port memory, measured

`rtl/strata_core.sv` has a parameter `LS_1P` (default 0; `make LS_1P=1`).
With it both Local Stores are one single-port memory (`rtl/strata_ram1.sv`:
the I-LS in its low words, the D-LS above), one access per cycle:

1. the reset sequencer (the Transfer Unit is flushed then), the two
   stores' words in alternate cycles;
2. a beat arriving from the far bus (`tget`, `tgetx`): it is written at
   once, because the bus has no way to make a read beat wait. The core
   gives way for that cycle: a fetch, a load, a store or a tag-table
   access stays where it is, the read-ahead is skipped;
3. the core's data access, then its fetch in `F0`;
4. a `tput`'s read of the D-LS (the unit asks again when refused: a new
   input of `strata_tu`);
5. the read-ahead.

This is not `exp/ls_unified.sv`'s order in one respect: there the unit
could always be refused. In the real machine a beat from the bus cannot,
so it goes first.

**Cycles per instruction** (profiler, busy cycles, `STREAM = 1`
everywhere). "First" is the arbitration above as first built; "now" has
the changes described below. The last column is from the busy cycle
counts, not from the rounded figures:

| | two dual-port stores | one memory, first | one memory, now | |
|---|---|---|---|---|
| StrataOS session | 1.75 | 1.84 | 1.78 | +1.3% |
| `parsum` | 1.49 | 1.59 | 1.54 | +2.8% |
| `stream_sum` | 1.50 | 1.59 | 1.55 | +2.7% |
| `gfx` | 1.74 | 1.76 | 1.74 | +0.02% |
| `mandel` | 2.17 | 2.19 | 2.17 | none |
| `pipeline` | 1.69 | 1.70 | 1.69 | +0.02% |
| `swcache` | 1.56 | 1.56 | 1.56 | none |

The whole StrataOS session takes 88.5 M clock cycles (86.8 M with two
stores, 148.2 M before the stream fetch).

**Where the cost was.** Sections 3.1 and 9 predicted 0.7% to 1.3% by
counting the cycles in which the core and the unit want the memory
together. The first build cost 5%, and the profile shows why: almost none
of it is waiting for the memory. It is the stream fetch missing. With two
stores the read of the next word is issued in the first cycle of a word
and arrives exactly when the second instruction retires; there is no
slack. With one memory a store or load in that first cycle, or a beat from
the bus, takes the memory, the read-ahead is a cycle late, and the retire
found no successor and went back through `F0` and `F1`: two cycles lost
for one cycle of delay. 1.6 M more instructions went through `F1` in the
session.

**Four changes, measured** (the session's cycles per instruction after
each, in the order they were made):

- *A late read-ahead costs one cycle.* An instruction that retires into
  the next word while that word is only just being read goes to `F1`,
  which takes it from the memory in the next cycle as it does after `F0`.
  (This is in the core's fetch for both settings of `LS_1P`; with two
  stores it almost never happens, and the examples' cycle counts there are
  unchanged.) Session 1.84 -> 1.80.
- *The core and a burst take turns.* The far bus has a ready for read
  beats now (`rready`: `strata_bus`, `strata_mem`, `ext_t3_rready` on the
  top). The Transfer Unit lowers it for one cycle, never two running, when
  the core's state registers say it is about to use the memory (a fetch in
  `F0`, a load or store in `EX`, a tag-table access, a read-ahead), so no
  execute-stage logic reaches the bus. A core that turns out to be waiting
  (a load stalled on the very transfer) is not believed again until a beat
  has actually made it wait. Only memory targets hold a beat; device beats
  are taken as before, and every other master keeps `rready` high. By
  itself this won little (1.84 -> 1.82): the bursts were not the main
  cost.

- *Two words ahead.* With one memory the core also reads the word after
  the next (a third 64-bit register, `fb_nx2`; with two stores it is not
  there), so a read-ahead that is a cycle late is still in time. 1.80 ->
  1.78 (+1.5% against two stores).
- *The next word's read alternates with a `tput`.* The read-ahead used to
  give way to every waiting `tput` read, so for the length of a `tput` the
  stream got no words and every word came through `F0`. The read of the
  next word now goes first unless the `tput` read was refused in the cycle
  before; the read of the second word ahead still gives way. +1.5% ->
  +1.3%, and `gfx`, `mandel`, `pipeline` and `swcache` to the two-store
  figure within 0.02%.

What is left: 1.3% in the session, and 2.8% in the two examples that
compute while their data streams in, where a beat and the core's own
access to the memory fall into the same cycles by construction (the load
that waits for a word wants the memory just as the next beat arrives).

**A deadlock found on the way.** `F0` presents the fetch address in every
cycle, also while it waits for a core-control write to complete; with one
memory that held the port the write's own read of the D-LS needed, and
the multi-core conformance test and the StrataOS boot stopped there. The
fetch now leaves the memory alone while it waits for that write, and the
read-ahead gives way to a waiting `tput` read so that no loop of the core
can starve one. The lockstep examples did not show it; the conformance
suite and the OS boot did.

**Checked** with `LS_1P = 1`: every example in lockstep with the
emulator, the conformance suite, the scripted StrataOS session, and the
full `make BUILD=build/ls1p LS_1P=1 test`, which also runs the small
overlay map, the smaller store sizes and the fetch without the stream as
single-port builds; all pass. `make test` with the default passes.

**What it is worth.** A dual-port macro costs 1.6x to 1.9x a single-port
one where it exists (section 5.1), and GF180MCU has none: 1.3% of the cycles
for 40% to 47% of the memory area, or for a design that can be built at
all. `u_ils` and `u_dls` remain as two unused words each when `LS_1P = 1`
so that the names the FPGA and ASIC scripts rely on do not depend on the
parameter; an external system memory (`T3_EXT`, the board's DRAM adapter)
must honour `ext_t3_rready` before `LS_1P` is used with it, which
`fpga/arty/strata_arty.sv` does not yet; the ASIC flow's `strata_ram` replacement, its floorplan and the
1024 x 8 macros are the next step there (`asic/` is unchanged). Area and
clock of the change are not measured.

## 11. The ASIC flow with one memory and the 1024 x 8 macro: prepared

`asic/run.sh` takes `ASIC_LS1P=1` (the core with `LS_1P = 1`, its memory
from macros in `asic/rtl/gf180mcu/strata_ram1.sv`: the same RAM as the
RTL's, not a stand-in) and `ASIC_SRAM=ocd1024` (that memory from the 1024 x
8 macro of section 5.1). `ASIC_PREP=1` stops before LibreLane, and
`asic/area.sh` synthesizes the prepared netlist to the PDK's cells with
Yosys on the host. That is as far as this went: no placement, no routing,
no timing.

| One core | Local Store macros | Standard cells | Die (floorplan) |
|---|---|---|---|
| two stores (stand-in, the kept run's floorplan) | 256, 53.6 mm² | 2.507 mm² | 93.6 mm² |
| one single-port memory, 512 x 8 | 256, 53.6 mm² | 2.523 mm² | 93.6 mm² |
| one single-port memory, 1024 x 8 | 128, 19.9 mm² | 2.498 mm² | 53.5 mm² |

Measured: the cell areas (host synthesis, 5 V cells, minutes per run) and
the macro counts. Arithmetic: the die, from the macro sizes and the
floorplan rules of the run that routed (macro rows in pairs over a 120 µm
channel, a logic strip between the two blocks).

- Section 7 expected "about 20 mm²" of stores: 19.9. The die is 53.5 mm²
  and not smaller because the floorplan gives the logic the 26.4 mm² strip
  it had in the run that routed (22% placement density). With the dense
  macro the strip is half the die, the memory 40%. The next question for
  the area of a core is no longer the memory but how densely this logic
  places and routes, which needs a routed run.
- The single-port memory costs 0.7% of cells against the stand-in (67
  flip-flops: the second read-ahead word and the arbitration's flags).
- The synthesis found two things in the RTL, both fixed, neither visible
  in simulation: the second read-ahead word and its multiplexers stayed in
  the two-store core (its flag was not tied to the parameter), 65
  flip-flops for nothing; and a width cast inside the single-port
  memory's address multiplexer became a latch in sv2v's translation.
- Not done: LibreLane with either option (the container image is not on
  this machine; the 1024 x 8 macro's LEF, GDS and liberty are not in the
  PDK the scripts fetch); the reports' and pictures' scripts for the new
  instance names; the save table in the denser 256 x 8 macro.

## 12. The single-port core, placed and routed

`asic/results/gf180mcu-1-mcu7t3v3-1p/`: one core with `LS_1P = 1` and the
stream fetch, the 3.3 V cells, the PDK's 512 x 8 macros, the floorplan
and settings of the kept 3.3 V run (which is of the RTL before any of
this work, with the two-store stand-in). Measured by the flow:

| | kept 3.3 V run | single-port core |
|---|---|---|
| Die | 93.6 mm² | 93.6 mm² (the same floorplan) |
| Standard cells | 5.99 mm² | 6.48 mm² (+8%) |
| Routing | 0 DRC violations | 0 DRC violations |
| Clock, typical | 40.80 ns, 24.5 MHz | 41.86 ns, 23.9 MHz (-2.5%) |
| Clock, fast | 30.4 MHz | 30.0 MHz |
| Critical path | flip-flop to flip-flop | `ir` -> store data input of a memory macro |
| Cycles per instruction, StrataOS session | 3.22 | 1.78 |
| Instructions per second at the typical clock | 7.6 M | 13.4 M (1.76x) |

- The memory is now a real one (one port, as the macros have), it routes
  with no violations in the same floorplan, and the core is 1.76 times as
  fast as the kept run's in instructions per second.
- Section 1.3 said no path through a Local Store was critical and that the
  path to the D-LS address was half the deepest. With one port that is no
  longer so: the core's store data and address, the Transfer Unit's and
  the reset sequencer's go through one multiplexer to 256 macros, and the
  critical path ends at a macro's data input. The clock lost 2.5%. A
  register in front of the memory (stores one cycle later) or a dedicated
  write path would take it off the critical path; not tried.
- The 8% more cells are the stream fetch (section 9: 4% of gates), the
  single-port arbitration and second read-ahead word, and 0.3 mm² more
  timing-repair buffers.
- Not run: the 1024 x 8 macro (its views are not in the PDK), so the 53.5
  mm² die of section 11 is still a floorplan, not a routed result.

