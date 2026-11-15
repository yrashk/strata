# Pipelining the Strata core: what it would gain, cost and break

2026-11-14. A research note: `rtl/` is unchanged. The question is whether the
core should be pipelined, what that would buy in cycles per instruction,
clock frequency and area, and what in this instruction set it could break.
It builds on `research/smart-memory/REPORT.md` (branch
`claude/smart-memory-research-4e7a72`, not merged), whose stream fetch
(`STREAM`) already overlaps fetch with execute.

**Measured since (section 9):** the stream fetch and `LS_1P` are merged and
the parallel overlay search (stage 1 below) is in `rtl/`. In place and route
it did **not** raise the clock: on the ECP5 18.82 MHz before it and 18.93
after (the same run-to-run noise), on GF180MCU 3.3 V 22.4 MHz; on both the
critical path starts at the decoded instruction and does not touch the
overlay map, and on the ECP5 85% of it is wire. The gate model's clock
estimates (items 2 to 4 below, sections 2.3, 2.4 and the clock column of
section 3) do not hold for the real flows. The cycle estimates do: the
cycle model reproduces the measured core. Section 9 says what that changes.

**The answer in six lines** (as first written; see above).

1. "Not pipelined" was mostly a cycles-per-instruction problem, and `STREAM`
   has already solved most of it: the StrataOS session went from 3.22 to
   1.75 busy cycles per instruction. A classic 5-stage pipeline without
   branch prediction would do *worse* on the same code (1.89, model), and
   one with a predictor only somewhat better (1.28).
2. The clock is the real weakness, and its main cause is not the lack of
   stages but one structure: the overlay map's two 16-entry searches are
   written as serial priority chains inside the execute cycle. In a gate
   model of the core they are the deepest paths by far (290 FO4 against 150
   for everything else). Written as parallel searches (tried here: +1.5%
   gates, cycle for cycle the same machine on every example) the deepest
   path is 152 FO4: 1.3x to 1.9x more clock, with no pipeline at all.
3. A 3-stage pipeline (fetch, execute, load write-back) at that clock, with
   a small branch predictor, models at 1.20 cycles per instruction on the
   StrataOS session: 1.9x to 2.8x today's `STREAM` core in busy time, for
   a few percent of logic and no change to the architecture.
4. A 5-stage pipeline with prediction adds about 1.2x more clock (the execute
   stage is still 122 FO4: the trap and next-state logic) for a rewrite of
   the core and of its formal proofs. Not worth it before item 3.
5. Nothing in the manual has to change. Everything that leaves the core
   (gifts, takes, transfers, atomics, walks, stores, traps) must stay at one
   commit point, in order; capability registers need the same hazard
   handling as integer registers; `tgetx`, `xmap`, `csrw xslot/status/ipend`
   flush the fetched-ahead instructions; the trace must move from fetch to
   commit. Lockstep tests keep working; cycle counts and `-T virtual`
   interleavings change, as they did with `STREAM`.
6. Several hardware threads per core (barrel) fit this ISA well (no caches,
   fixed Local Store latency, every long wait explicit), but on GF180MCU the
   Local Stores are 59% of the die and each thread that is a core needs its
   own: a 4-thread core saves about a tenth of the area of four cores. It
   pays on dense memory (IHP) or on an FPGA, where StrataOS's six cores do
   not fit an XC7A200T today.

Which numbers are measured, modelled or estimated is said per table and
collected in section 8.

## 1. Baseline

### 1.1 The state machine, per instruction class

`rtl/strata_core.sv` runs one instruction at a time through `S_F0` (the pc
to the I-LS), `S_F1` (the word into `ir`) and `S_EX` (everything else), with
extra states for the instructions that need them. Busy cycles per
instruction (not counting waits for the world), with `STREAM = 0` (main) and
`STREAM = 1` (the smart-memory branch, where an instruction whose successor
is in the 64-bit word just read, or in the next one read ahead, goes from
its retire straight to `S_EX` of the successor):

| Class | States | `STREAM = 0` | `STREAM = 1` |
|---|---|---|---|
| ALU, `lui`, CSR, capability operation, `tpoll`, `xmap` | F0 F1 EX | 3 | 1 (sequential) |
| taken branch, `jal`, `jalr`, `eret` | F0 F1 EX | 3 | 3 (the target goes through F0, F1) |
| branch not taken | F0 F1 EX | 3 | 1 |
| load | F0 F1 EX LD | 4 | 2 |
| store | F0 F1 EX (written in EX) | 3 | 1 |
| `mul` / `mulhu` (`strata_mul`: one 32 x 32 partial product a cycle) | ... EX DV x3 / x4 | 6 / 7 | 4 / 5 |
| `div`, `rem` (`strata_div`: one quotient bit a cycle) | ... EX DV x65 | 68 | 66 |
| `csave`, `crestore` (+ `x` forms: the save table's registered read) | ... EX CT | 4 | 2 |
| `ltag` / `linst` (tag-lookup sequencer, two cycles a way) | ... EX LG LT (LW) | 3 + 2 + 2 per way (+2 miss); `linst` +2 | 2 less |
| `tget` / `tput` / `tgetx` (issue; the copy runs in the Transfer Unit) | F0 F1 EX | 3, if the 4-entry queue has room | 3 (transfers go through F0) |
| far atomic | ... EX AM | 3 + about 8 (measured mean) | 1 + 8 |
| `xcall` / `xret`, mapped | F0 F1 EX | 3 | 3 |
| `xcall` / `xret`, not mapped | trap `xmiss` | 3 + the handler | |
| a trap (any cause) | the instruction's EX, then the handler through F0 F1 | 3 | 3 |
| gifts, takes, `twait`, `tany`, walks | EX until the world answers | 3 + wait | 1 or 3 + wait |

Every check, every write and every request to the rest of the machine
happens in `S_EX` (or `S_CT`, `S_LD`, `S_DV`, `S_AM`, `S_LW` for the
instruction's last write). That single place is what makes the core simple
to reason about and to prove; it is also, as section 4 shows, the property a
pipeline must keep.

### 1.2 Cycles per instruction

Busy cycles per instruction. "Measured" is the cycle profiler of
`research/smart-memory/prof/` (not re-run here). "Model, today" is this
work's trace model (section 2.1) of the `STREAM = 0` core on fresh
instruction traces of the main branch: it reproduces the profiler to the
second decimal everywhere, which is the check that the model's
accounting of today's core is right.

| | `STREAM = 0`, measured | model, today | `STREAM = 1`, measured |
|---|---|---|---|
| StrataOS session (`os/demo.txt`, 8 cores) | 3.22 | 3.227 | 1.75 |
| `mandel` | 4.02 | 4.020 | 2.17 |
| `pipeline` | 3.29 | 3.293 | 1.69 |
| `swcache` | 3.17 | 3.172 | 1.56 |
| `parsum` | 3.21 | 3.209 | 1.49 |
| `stream_sum` | 3.22 | 3.218 | 1.50 |
| `gfx` | 3.60 | 3.602 | 1.74 |

The StrataOS trace of this work has 64.6 M instructions (62.4 M in the
smart-memory run: the session is timing-dependent and main has moved). The
mix: ALU 44%, branches 21% (65% taken; backward ones 94%, forward ones
43%), `jal` 8%, loads 11% (48% used by the very next instruction), `jalr`
3.5%, stores 6%, far atomics 0.8%, capability operations 1.3%; `xcall`,
`xret`, `xmap` together under 0.05%.

### 1.3 Critical path and clock

From the runs kept in the repository (place and route, measured):

| Run | Period | Critical path |
|---|---|---|
| GF180MCU, 3.3 V cells (`asic/results/gf180mcu-1-mcu7t3v3`) | 40.8 ns = 24.5 MHz typical (30.4 MHz fast corner) | from `ir[29]` (the opcode) to a flip-flop, 134 cells, 38.0 ns of cells and 2.1 ns of wire |
| GF180MCU, 5 V cells (`asic/results/gf180mcu-1`) | 84.1 ns = 11.9 MHz | a flip-flop to `am_req`, 95 cells; no timing repair |
| ECP5-85F, nextpnr (`fpga/results/ecp5-1`) | 49.96 ns = 20.0 MHz, 69% of it wire | D-LS read port (5.8 ns clock to output) -> `ltag`'s compare -> trap logic -> `s_cause` enable |

The netlists do not keep enough names to follow those paths through the
core, so this work measured where the depth is with a gate model
(`sta/core.sh`, `sta/sta.py`: one core through Yosys to a small generic
gate library, Kogge-Stone adders and a delay-oriented mapping, delays by
logical effort in FO4, no wires). Names that must survive mapping are kept,
and the arrival time of each is printed: where in the execute cycle a
signal is ready (FO4 from the clock edge; measured on the model):

| Signal | Ready at | Logic after it, to the worst end point |
|---|---|---|
| `d` (decoded instruction) | 34 | 201 |
| `ra`, `rb` (integer register reads) | 38 | 164, 116 |
| `cap_a` (the operand capability) | 40 | 162 |
| `g_a`, `live_a` (its granule; live?) | 55, 65 | 65, 55 |
| `alu_y`, `maddr` (ALU result, load/store address) | 95 | 57 |
| `br_taken` | 90 | 16 |
| `xf_fault` (transfer checks) | 84 | 21 |
| `mload` (load data aligned) | 108 | 4 |
| `xc_key` (the overlay search key: base + offset) | 66 | 136 |
| `xm_hit` (`xcall` target found in the map) | 145 | 32 |
| `xm_inslot` (the caller's pc is in a mapped slot) | **222** | 27 |
| `xm_link` (the link `xcall` writes) | **271** | 27 |

The longest paths of the whole core (model, FO4):

| From -> to | FO4 |
|---|---|
| pc / overlay map -> `xm_inslot` -> `xm_link` -> integer register | **290** |
| decoded instruction -> overlay search -> `xm_target` -> pc | 201 |
| decoded instruction -> ALU -> integer register | 179 |
| decoded instruction -> trap state (`epc`, `tval`, mode) | 165 |
| decoded instruction -> D-LS port A address | 148 |
| decoded instruction -> multiplier | 140 |

The deepest path computes, for an `xcall`, whether the caller's own pc lies
in a mapped slot, so that the link is a far address. The RTL writes that
search (and the target's, `xm_hit`) as a loop in which each entry's
condition includes "no earlier entry matched" (`!xm_inslot && ...`), so the
16 entries form a chain of 17-bit subtractions and compares one after
another: 200 FO4 for something a parallel compare and a priority encoder do
in about 40. With the area-oriented mapping of the smart-memory work
(ripple adders) the same path is 340 FO4 and the ALU paths about 30 FO4
longer; the ranking is the same.

How the model relates to the real runs: the GF180MCU 3.3 V run's critical
path starts at `ir`, not at `pc`, so in that timing-driven flow the overlay
chain was not the single worst path after resizing; the paths from `ir` (in
the model 179 to 201 FO4) were. The model is a ranking, not a clock. Section
2.2 therefore gives every clock gain as a range: the model's ratio against
its deepest path (290) at the top, against its deepest `ir` path (201) at
the bottom.

### 1.4 Area

Measured by the kept runs: one core on GF180MCU 3.3 V is a 93.6 mm² die of
which 55.2 mm² are the Local Store macros and 4.8 mm² logic (flip-flops
0.68, combinational 2.48, buffers and repair 1.55, inverters 0.12; 11,390
flip-flops); on Xilinx 7-series 30,011 LUTs and 6,869 flip-flops. Of the
core's own flip-flops the granule table copy is 4,352, the integer registers
2,048, the capability registers 1,296, the overlay map 752, the CSRs about
1,350, the Transfer Unit 566 (`research/smart-memory/REPORT.md` 1.2). The
gate model here: 148,739 cells (756,414 transistors in gates) with
Kogge-Stone adders, 144,277 cells with ripple adders. `STREAM` added 98 flip-flops and 4% of
the gates (measured on the smart-memory branch).

## 2. What pipelining would buy

### 2.1 The cycle model

`model/pipe.py` reads an instruction trace (`strata-rtl -t`: core, pc,
instruction, in the order instructions reach `S_F1`) and times each core's
stream through an in-order, single-issue pipeline: an instruction enters
execute when the one before lets it and its source registers and
capabilities are ready; it lets the next one in after its extra cycles and
its redirect penalty. Taken branches and traps are inferred from the next
pc. Waits for the world (gifts, `twait`, `tany`, a full transfer queue, a
load on an in-flight range) cost nothing in any design, like the
profiler's "busy" cycles; far atomics and the tag-lookup sequencer cost what
the profiler measured (8.0 and 8.05 cycles), equal everywhere. The designs:

| Design | Stages | Redirect (taken branch, `jalr`, `xcall`, trap) | Load used at once | mul / mulhu / div extra | Notes |
|---|---|---|---|---|---|
| p3 | F, X, W | 1 (the target goes to the I-LS address in X) | 1 | 3 / 4 / 65 | X = today's EX; W = a load's data |
| p3r | F, X, W | 2 (the target registered first) | 1 | 3 / 4 / 65 | `STREAM` with loads overlapped |
| p3f | F, X, W | 1 | 0 (D-LS data forwarded) | 3 / 4 / 65 | |
| p3b | F, X, W | right 0, wrong 1 | 1 | 3 / 4 / 65 | p3 with the predictor of p5b |
| p5 | F0, F1, D, E, M, W | 3 from E; `jal` 2 from D | 1 | 6 / 8 / 65 | capability RAW 1; save table read in D |
| p5s | as p5 | backward taken predicted in D: 2 right, 3 wrong | 1 | 6 / 8 / 65 | |
| p5b | as p5 | predictor in F: 256 two-bit counters, 64-entry target buffer, 8-entry return stack; right 0, wrong 3 | 1 | 6 / 8 / 65 | |
| bN | p5's stages, N threads in turn, no forwarding or interlocks | none (resolved before the thread's next turn) | none | max(N, 7 / 9 / 66) | per thread |

The p5 multiplier latencies double because at about twice the clock the 32 x
32 partial product of `strata_mul` would need two cycles; a fully
pipelined multiplier (the DSP blocks have the registers) would remove most
of that.

### 2.2 Cycles per instruction (model on measured traces)

`results/strataos.txt`, `results/examples.txt`; busy cycles per instruction;
`STREAM` measured, for comparison:

| | `STREAM` (measured) | p3r | p3 | p3f | p3b | p5 | p5s | p5b | b4, per thread |
|---|---|---|---|---|---|---|---|---|---|
| StrataOS session | 1.75 | 1.68 | 1.42 | 1.37 | **1.20** | 1.89 | 1.82 | **1.28** | 4.09 |
| `mandel` | 2.17 | 2.17 | 2.10 | 2.09 | 2.03 | 2.91 | 2.84 | 2.70 | 5.00 |
| `pipeline` | 1.69 | 1.69 | 1.49 | 1.40 | 1.30 | 1.89 | 1.70 | 1.30 | 4.19 |
| `swcache` | 1.56 | 1.54 | 1.35 | 1.35 | 1.17 | 1.77 | 1.61 | 1.24 | 4.13 |
| `parsum` | 1.49 | 1.30 | 1.16 | 1.16 | 1.02 | 1.45 | 1.31 | 1.02 | 4.02 |
| `stream_sum` | 1.50 | 1.32 | 1.17 | 1.17 | 1.03 | 1.46 | 1.32 | 1.03 | 4.03 |
| `gfx` | 1.74 | 1.74 | 1.67 | 1.66 | 1.61 | 2.40 | 2.35 | 2.22 | 4.60 |

Where the cycles above 1.0 go in the StrataOS session:

| Design | Control | Load use | mul / div | Atomics, `ltag` | Traps, serialising |
|---|---|---|---|---|---|
| p3 | 0.255 | 0.054 | 0.046 | 0.066 | 0.001 |
| p3b | 0.032 | 0.054 | 0.046 | 0.066 | 0.001 |
| p5 | 0.682 | 0.054 | 0.088 | 0.066 | 0.002 |
| p5b | 0.071 | 0.054 | 0.088 | 0.066 | 0.002 |

What this says:

- Control is everything. 21% of the instructions are branches and 65% of
  those are taken, `jal`/`jalr` add 12%: 16.5 M transfers of control in
  64.6 M instructions, one every 3.9. Every cycle of redirect penalty
  costs 0.25 cycles per instruction. That is why `STREAM` (two cycles per redirect) is at 1.75,
  and why a 5-stage pipeline that resolves control in E without prediction
  (three cycles) is *slower per instruction* than `STREAM`.
- Static prediction is weak on this code: forward branches are taken 43% of
  the time in the session (in the examples nearly all branches are loop
  branches, and it does well there). A small dynamic predictor removes
  almost all of the control cost: in the session it is right 14.5 M times,
  wrong 0.35 M times, and 1.7 M taken branches or `jal`s find no target in
  its buffer (they cost what static prediction costs).
- Loads matter little: 0.054 cycles per instruction even without forwarding
  the D-LS data, because 11% of instructions are loads and half of them are
  used at once. Forwarding (p3f) is not worth its path.
- Capability read-after-write is negligible (19,000 instructions read a
  capability written by the instruction just before: 0.03%).
- The examples are dominated by their loops: `parsum` and `stream_sum`
  reach 1.02 with a predictor; `mandel` and `gfx` are bound by the
  multiplier (one 32 x 32 product a cycle; `mul` is a third of `mandel`'s
  instructions).

### 2.3 Clock (model, with ranges)

`sta/core.sh ks TAG CUTS` removes the drivers of chosen signals (Yosys
`cutpoint`), so they become start points as if they were registers; the
longest remaining path is what a core cut into stages there would have per
stage. Measured on the model, FO4:

| Cut | Longest path left | What it means |
|---|---|---|
| none (today) | 290 | the `xcall` link |
| the overlay map's search results (`xm_hit`, `xm_i`, `xm_inslot`, `xm_li`) registered | **150** | a two-cycle `xcall`/`xret`; the rest of the core is at most 150 |
| decode, register and capability reads, granule lookups registered (a D/E boundary), overlay as today | 172 | the overlay search hangs on the operands |
| D/E boundary and the overlay registered | **122** in E; D is 65 (`live_a`); the overlay match alone 80 | a 5-stage core with a multi-cycle `xcall` |

And the parallel form of the overlay searches, which needs no extra cycle:
section 6.

From the deepest paths to clock ratios, with the range of section 1.3 (the
model's 290 at the top, its `ir` paths' 201 at the bottom), and what they
would be from the kept runs' 24.5 MHz (GF180MCU 3.3 V) and 20.0 MHz (ECP5):

| Design | Deepest stage | Clock vs today | GF180MCU 3.3 V | ECP5 |
|---|---|---|---|---|
| today, `STREAM` | 290 | 1 | 24.5 MHz | 20 MHz |
| overlay search out of the way: two cycles (150) or parallel (152, section 6) | 150-152 | 1.32x to 1.93x | 32 to 47 MHz | 26 to 39 MHz |
| p3 at that clock (the redirect into the I-LS address is the pc's own next-state logic, 148, plus the macro's setup) | 150 + setup | same | same | same |
| p5 (D 65, E 122) | 122 | 1.65x to 2.38x | 40 to 58 MHz | 33 to 48 MHz |

The Local Store macro is not on any of these paths: its cycle is 9.24 ns at
3.3 V (`research/smart-memory/LITERATURE.md` A1), so it allows about 100 MHz
with a single-cycle access. On the ECP5 the block RAM's 5.8 ns clock to
output starts today's critical path through `ltag`; `ltag` already takes two
cycles a way, so a register after the block RAM (which it has) removes it.

Not modelled: wires. On the ECP5 69% of the period is routing; deeper logic
mostly means longer routes, so the ratios should carry over roughly, but a
pipeline's forwarding paths add long wires of their own.

### 2.4 Throughput: both together

Busy time per instruction relative to the `STREAM` core (StrataOS session;
CPI from 2.2, clock from 2.3, ranges from 2.3):

| Design | CPI | Clock | Speed-up over `STREAM` |
|---|---|---|---|
| `STREAM` | 1.75 | 1 | 1 |
| `STREAM` + overlay search out of the cycle | 1.75 | 1.32 to 1.93 | **1.32x to 1.93x** |
| p3 + overlay | 1.42 | 1.32 to 1.93 | 1.63x to 2.38x |
| p3b + overlay | 1.20 | 1.32 to 1.93 | **1.92x to 2.81x** |
| p5 (no prediction) | 1.89 | 1.65 to 2.38 | 1.53x to 2.20x |
| p5b | 1.28 | 1.65 to 2.38 | 2.26x to 3.25x |
| b4, per thread | 4.09 | 1.65 to 2.38 | 0.71x to 1.02x each, four threads |

Against today's main branch (`STREAM = 0`, 3.22) multiply by 1.84.

The whole StrataOS session gains less than its busy time: 82% of its cycles
are waits (`tany` on idle cores, the timer). With `STREAM` the busy CPI
improved 1.84x and the whole session's clock cycles 1.71x.

## 3. The options

Area is for one core; "logic" is the core's 4.8 mm² of cells on GF180MCU
3.3 V (5% of the die) or its 30k LUTs on 7-series.

| # | Option | CPI (StrataOS) | Clock | Area | Effort | Risk | ISA / manual |
|---|---|---|---|---|---|---|---|
| 0 | `STREAM` (built, on the smart-memory branch) | 1.75 (M) | 1 | +98 FF, +4% gates (M) | done | done | none |
| 1 | Overlay searches as parallel compare + priority encoder | 1.75 | 1.32x-1.91x (E: deepest path 290 -> 152 FO4, M on the model) | +1.5% gates, no flip-flops (M, model) | small: two loops | low: cycle-identical (M, section 6) | none |
| 1b | ... or a two-cycle `xcall`/`xret` (registered search) | 1.75 + 0.0002 | 1.34x-1.93x (E: 290 -> 150 FO4) | +40 FF | small | low | none |
| 2 | p3: loads overlapped, redirect in one cycle | 1.42 (E) | as 1 | +100-200 FF, +2-3% logic (E) | medium: retire, fetch, W stage, trace at commit | medium | none |
| 3 | p3b: p3 + branch predictor | 1.20 (E) | as 1 | +1,100-2,400 FF on an ASIC (0.07-0.15 mm²), about 200 LUTs as LUT-RAM (E) | medium | medium | none |
| 4 | p5: six stages, forwarding, no prediction | 1.89 (E) | 1.65x-2.38x (E) | +800-1,000 FF, +5-8% logic (E) | large: a new core, new core proofs | high | none |
| 5 | p5b: p5 + predictor | 1.28 (E) | 1.65x-2.38x (E) | +10-15% logic (E) | large | high | none |
| 6 | Deeper (7-8 stages) | about 1.4-1.5 with a predictor (E) | up to 3x-4x (E), then the Local Store macro limits | more | very large | high | none |
| 7 | Barrel, 4 threads (each a core) | 4.09 per thread; 0.98 per cycle in all (E) | as 4 | +5,300-6,100 FF per thread (registers, capabilities, CSRs, overlay map, unit tags): +30% logic for four; and a Local Store per thread (E) | very large: the core, the top level, the platform | high | none if a thread is a core; platform table and OS see more cores |

M = measured, E = estimated (model on measured traces, gate model, or
arithmetic in the text).

Deeper pipelining (6): the 122-FO4 execute stage of p5 is about half ALU
and half the trap and next-state logic. Splitting it again (precomputing
from the decoded instruction which checks apply, so that E only combines
them) could reach 60-80 FO4 per stage, but control would cost 4-5 cycles
when mispredicted and loads 2, and from about 100 MHz on GF180MCU the Local
Store access needs two cycles. Explicit memory makes such a pipeline easier
than a cached one: no miss, no TLB, no variable latency, every long wait
explicit at one point. It is still a far larger design than this project
needs.

Barrel processing (7): with four threads in turn on p5's stages there is no
forwarding, no interlock and no prediction: each instruction's result and
redirect are there by the thread's next turn. The pipeline does 0.98
instructions per cycle when four threads are ready (multiply and divide
take longer than four turns). Each thread runs at a quarter of that: 0.7x
to 1.0x of today's `STREAM` core. What it costs:

- Per thread: the integer registers (2,048 bits), capability registers
  (1,296), CSRs and trap state (about 1,350), overlay map (752), pc, the
  Transfer Unit's queue and tags (566), an inbox at the top level, a save
  table (block RAM; 11 macros on GF180MCU, or a share of one), and its Local
  Stores. The granule table copy (4,352) and the datapath are shared.
- If a thread is an architectural core (its own core number, Local Stores,
  inbox, core control) nothing in the ISA changes and the emulator and the
  lockstep tests still describe it: the platform table lists more cores.
  The Local Stores dominate: on GF180MCU with today's macros four such
  threads need four times 55 mm² of SRAM, and the barrel saves only the
  logic of three cores, about a tenth of the area of four cores. With
  IHP's macros (3.8 mm² of SRAM per core) the saving is about a quarter.
- If threads share one core's Local Stores they are not cores in the
  manual's sense (the stores are private per core, the as-if-synchronous
  rule and the hazard table are per core); that is an architecture change.
- The case where it is clearly worth it is an FPGA: StrataOS needs six
  cores (168,694 LUTs on 7-series, a Kintex-7 325T), and its cores are idle
  82% of the session. Two physical cores of three or four threads would give
  it six to eight cores in the LUTs of about three; the block RAM (32
  RAMB36 per core's two 64 KiB stores) still fits an XC7A200T (365 RAMB36).
  A variant that switches threads on waits (`tany`, `ctake`, `twait`) rather
  than every cycle keeps single-thread speed and suits StrataOS's mostly
  waiting servers; it needs p5's interlocks back.

## 4. What could break, rule by rule

The principle that keeps all of it safe: **one commit point.** Every
instruction does everything that leaves the core or cannot be undone (a
register or capability write, a store, a transfer issue, a gift or a take, a
far atomic, a revocation walk, a CSR write, a trap) in one stage, in program
order, and only when no older instruction can still trap or redirect. In
today's core that stage is `S_EX`. In the 3-stage design below it is still the
execute stage (X), and nothing older than the instruction in X is left except
a load whose data is on its way, which can no longer trap. In the 5-stage
design it is E, with M and W holding only load data and results that cannot
fault. Everything younger than the commit point (in F, I, D) is speculative:
it may be thrown away, and it must not have done anything the machine can
see. Under that rule none of the following needs a change of the manual; the
table at the end says where the RTL needs care.

**Precise traps, their priority, `epc` and `tval`** (manual, Privilege, traps
and events: "Trap entry", "Priority", "The trap value"). Today `trap()` runs
in `S_EX` with the faulting instruction's own `pc`, `ir`, operands; the
priority is the order of the `if` chain. A pipeline keeps this if the chain
stays in the commit stage and the stage carries its instruction's `pc` (for
`epc`, the `utvec`/`stvec` double-fault test, `ifault`), its `ir` (`illegal`,
`priv` report the word) and its operands (the `tval` of transfers, loads,
capability faults). Two checks move earlier and must travel with the
instruction instead of trapping where they are found: the fetch fault
(`pc` outside the I-LS or unaligned, found in F) and `illegal` (found in D).
They become a "fault" bit and cause carried down the pipeline, taken in E in
the manual's order (stop, ifault, illegal, the instruction's own checks).
Younger instructions are flushed. A trap redirects like a jump: 1 to 3
cycles, on top of today's cost. `instret` counts at the commit point, as now.
Flush: yes. Manual: no change.

**A stop request (`ipend`) and the user-mode inbox rule.** Today a stop is
taken "at an instruction boundary, also while an instruction waits", in
`S_F0` and `S_EX`, and `held` keeps an instruction that a stop preempts in
`S_EX` from reaching the rest of the machine (the fix of a gift that was
delivered and also re-executed: the comment at `held` in
`rtl/strata_core.sv`). In a pipeline the stop is taken in the commit stage
against the oldest instruction there, `epc` = its `pc`, and every younger
one is flushed; `held` must gate exactly the same requests it gates now
(`give_valid`, `take_req`, `tu_iss_valid`, `am_req`, `dom_req`, the store's
write enable, the save-table write), and nothing younger may raise them.
The user-mode rules (`inbox_priv`: `ctake`, `cpoll`, `tany` with bit 16 trap
`priv`; CSR writes that are the supervisor's) are decided from `user`, which
only the commit stage changes (`eret`, a trap, a `csrw status` that takes
effect at the next `eret`). An instruction decoded under the old mode before
an `eret` commits is younger than the `eret` and is flushed with its redirect,
so mode is never stale where it is checked. `csrw ipend` and `csrw status`
are serialising (the model charges them a flush). Flush: yes. Manual: no
change.

**Capability linearity.** A linear capability must be in exactly one place.
Today an instruction reads `cs`, `cd`, the save-table slot and the inbox's
head in `S_EX` and writes `caps[cd]`, `caps[cs]` and the slot at the end of
the same cycle (or of `S_CT`), so nothing else can see the capability "in
flight". A pipeline that reads capability registers in D (to look the
granule up there, which is the point of moving that lookup out of E) has
a read-after-write hazard on capability registers like the one on integer
registers: `cmov c3, c2` followed by `tget ... c3` must see the moved `c3`
and, if `c2` was linear, an empty `c2`. Either the 81-bit capability is
forwarded from E to D *together with its liveness*, or D interlocks for one
cycle (the model charges this: 0.0% to 0.1% of instructions). A moved
capability is never duplicated as long as the write of both `cd` and `cs`
stays in the commit stage, as one event. A gift (`cgive`, `csend`) is the
dangerous one: the capability leaves the core when `give_ack` comes, and the
source register is cleared in the same cycle. That handshake must stay in
the commit stage, with `held`, as now; a pipeline must never start a gift
for an instruction that may still be flushed. `ctake`/`crecv` pop the inbox
(`take_pop`) only at commit, for the same reason. Interlock or forward:
yes. Manual: no change.

**Revocation between instructions.** `cdom`, `crevoke`, `cundom` start a
walk of the granule table at the top level (`dom_req`, held until
`dom_done`), and every core's copy of the table (`gt2`, `gt3`) is written by
the broadcast at any time. Today the liveness of a capability is evaluated
in the cycle it is used (`live_a`, `live_cd`, `live_ct` in `S_EX`). If a
pipeline looks the granule up in D and uses the answer in E one cycle later,
a broadcast between the two makes the answer one cycle stale. Architecturally
this is allowed: revocation is "an external event for the cores whose
capabilities die" (manual, Memory model, "What the model does not cover")
and a use that races it may trap or not. But the RTL must not let a stale
"live" answer authorise a transfer that the emulator, given the same order
of events, would refuse, or the lockstep comparisons go wrong where they
should not; the simple rule is to re-check the generation in E (one 16-bit
compare of the looked-up entry with the capability, with the entry
forwarded when the broadcast writes it), or to stall D while a broadcast is
in progress. The walk itself (`cdom`) stays a waiting instruction at the
commit point, as now. Manual: no change.

**Transfer ordering and the publication rule.** Transfers are issued to the
Transfer Unit in program order from the commit stage (`tu_iss_valid` in
`S_EX`), and the unit performs them in issue order. A pipeline keeps that by
issuing only at commit. The publication rule ("`cgive`, `csend`, `cshare`,
`catomic` and `tamo` take effect only when none of the issuing core's memory
transfers is in flight", WaitMemory in the pseudocode) is a wait on
`tu_mem_idle` / `tu_put_idle` evaluated at commit: an older transfer has
already been issued when a younger gift reaches commit, so the wait sees it.
The one new case is a transfer issued in the same cycle as the commit of
the gift behind it: impossible, since one instruction commits per cycle.
Core-control writes ("the next instruction waits for them": `tu_cc_busy` in
`S_F0` today) must hold the *next commit*, not the next fetch, once
instructions are fetched ahead. The as-if-synchronous hazards (a load or
store on a range a transfer is still filling or emptying, `hz_rd_stall`,
`hz_wr_stall`) are checked at commit as now; with PTRAP set they become
`pend` traps, which are timing-visible by definition. Manual: no change.

**`tany`, `twait`, `tpoll`.** They wait or sample `tag_busy` at commit, as
now. Their results are timing-visible (manual: "Timing-visible state"), so
any change in when they run is allowed; but a waiting instruction must
remain interruptible by a stop and a reset "while an instruction waits",
which in a pipeline means the commit stage, not a younger one, recognises
the request. A `tany` that waits for a gift (bit 16) must not let a younger
`ctake` behind it pop the inbox first: the younger one is not at commit, so
it cannot. Manual: no change.

**Overlay misses and `xslot`.** `xcall` and `xret` look the far address up
in the overlay map (`xm_hit`, `xm_target`) and either jump or trap `xmiss`;
`xmap` and `tgetx` change the map (`tgetx` forgets mappings into the range it
replaces, `xm_inv`); `csrw xslot` changes how every entry matches. A
pipeline that looked the map up in D for an `xcall` behind an `xmap`, a
`tgetx` or a `csrw xslot` in E would see the old map. These are rare in the
traces (`xmap`, `xcall`, `xret` together under 0.1% of the StrataOS
session's instructions), so the simple answer is the right one: look the map
up at commit as now (the `xcall` redirect is then resolved in E, which the
model charges as an indirect jump), and treat `csrw xslot` as serialising.
The overlay map's path to the link register is today's deepest path
(`xm_link` into `x`), and it is the one a 5-stage design must split; see the
timing section. Manual: no change.

**Self-modifying code: `tgetx` into the I-LS.** The architecture promises "a
program may jump to code immediately after issuing the `tgetx` that loads
it. There is no instruction-synchronisation barrier", with fetch stalling on
an overlapping in-flight `tgetx` (Table "Local Store hazards"). Today that
is `hz_fetch_stall` in `S_F0`; with `STREAM` the read-ahead is suppressed
while any `tgetx` is queued (`getx_busy`). A pipeline fetches ahead of
commit, so instructions younger than a `tgetx` may already be in F, I or D,
read from the old contents of a range the `tgetx` is about to replace.
They must be flushed and refetched after the `tgetx` commits, and the fetch
must then stall on the hazard as now: treat `tgetx` as serialising (the
model does: flush cost after every `tgetx`; 0.0% to 0.1% of instructions).
The same holds for a `tgetx` issued by the reset sequencer's reload and
for the I-LS writes of the Transfer Unit in general: only `tgetx` writes the
I-LS. Flush: yes. Manual: no change.

**Core control: stop and reset of another core mid-instruction.** A reset
request is taken "at its next instruction boundary, or while an instruction
waits, without doing anything of that instruction"; the core then waits for
its Transfer Unit to be quiet (`S_RQ`, `tu_quiet`), flushes it and reloads.
In a pipeline: the commit stage takes it (with `held` gating every request,
as now), every younger instruction is flushed, an older load in W may finish
(it only writes a register that the reset clears anyway), and the multiplier
or divider in flight is abandoned. Nothing changes in the top level. The
F1 / F2 findings of the formal work (`formal/FINDINGS.md`: a walk's `done`
taken by the next request after a reset; a gift both delivered and
re-executed) are exactly the class of bug a pipeline adds more places for:
every request line must be gated by "this instruction is at commit and not
held". Manual: no change.

**Determinism and the tests.** Pipelining changes cycle counts and nothing
an instruction computes, so:
- `tools/compare.sh` (every example, every core, every instruction against
  the emulator) keeps working only if the RTL's trace is written at commit,
  in program order, once per instruction, and never for a flushed one.
  Today `sim_trace` is called in `S_F1`, at fetch, which in a pipeline would
  list wrong-path instructions. Moving it to the commit stage is required
  (and also the right place for the debugger's single-step and breakpoints,
  `dbg/`). An instruction that traps is traced today (it reached `S_F1`);
  the emulator traces it too; the commit-stage trace must keep that.
- `tools/compare-boot.sh` (the StrataOS sessions) compares console output
  and the boot-ROM part of each core's trace, because with `-T virtual` the
  timer runs on cycles / 100 and the OS schedules by it. A pipelined core
  runs more instructions per timer tick, so preemption points, `ps`,
  `uptime` and `cores` numbers move, exactly as they moved when `STREAM`
  halved the cycle counts; the comparison already normalises them.
- Programs that print cycle counts (`@` lines) change; they are ignored.
- The conformance suite (`conformance/`) checks results, not cycles.
- Tests with timing-dependent expectations (preemption, Ctrl-C, the window
  server's frame pacing, the network tests' timeouts) can interleave
  differently; when `STREAM` was made the default they all passed
  unchanged, which is evidence that they are robust to a 1.8x change.
- The emulator stays the reference and needs no change. Its own timer
  (rounds / 100) is unrelated to the RTL's cycles.
- Formal proofs (`formal/`): the module proofs (ALU, decoder, multiplier,
  divider, bus, memory, devices, Transfer Unit) carry over unchanged unless
  a module is re-timed (a pipelined multiplier needs its `mul` proof
  redone). The core's own properties (`formal/props/strata_core.svh`, 527
  lines: five inductions of 5 to 8 minutes) are written against the state
  machine (`S_EX` preceded by `S_F1`, requests only in `S_EX`); they must be
  rewritten for the commit stage, and the inductions will be harder (more
  state). The top-level properties about requests and walks (`f_cont`)
  stay as they are and are the ones that would catch a pipeline issuing a
  request for a flushed instruction.

| Rule | Stall | Flush | Interlock / forward | Manual change | RTL care point |
|---|---|---|---|---|---|
| precise traps, priority, `epc`/`tval` | | younger | | none | fault bits carried from F and D; trap chain at commit |
| stop / reset request, `held` | | younger | | none | every request gated by "at commit and not held" |
| user-mode inbox, privileged CSRs | | after `eret`, `csrw status/ipend` | | none | mode read at commit only |
| capability linearity, gifts, takes | | | cap RAW: forward or 1-cycle interlock | none | `give_ack`/`take_pop` at commit only |
| revocation between instructions | while a broadcast hits a looked-up granule, or re-check in E | | granule entry forwarded | none | stale "live" must not authorise |
| transfer order, publication rule | WaitMemory at commit | | | none | core-control write holds the next *commit* |
| `twait` / `tany` / `tpoll` | at commit | | | none | waits interruptible at commit |
| overlay map, `xmap`, `xslot` | | after `xmap`, `csrw xslot` (or look up at commit) | | none | `xcall` link path split for 5 stages |
| `tgetx` into the I-LS | fetch hazard as now | after every `tgetx` | | none | prefetched words dropped |
| core control on another core | | | | none | abandon mul/div in flight |
| lockstep traces | | | | none | trace at commit, not at fetch |

## 5. Recommendation and a staged plan

Do the cheap thing that attacks the real weakness first, measure it with
the real flows, and only then decide on stages.

**Stage 1: the overlay searches in parallel (option 1).** Rewrite the two
loops of `rtl/strata_core.sv` that search the overlay map (the target
search, `xm_hit`/`xm_i`, and the caller's slot, `xm_inslot`/`xm_li`) as a
match vector, its lowest set bit, and AND-OR selection, exactly as
`exp/par_overlay.py` does. No ISA change, no cycle change (checked: section
6), +1.5% gates. Then run the kept flows again: `fpga/ecp5-runs.sh 1` and
`asic/run.sh` with the 3.3 V cells. The model says the deepest path goes
from 290 to 152 FO4; the real runs say how much of that becomes clock. If
the GF180MCU run goes from 24.5 MHz toward 32 MHz or more, this is the
largest single speed-up per line of RTL in the project. Merge `STREAM`
with it (or before it): the two are independent.

**Stage 2: p3 with a predictor (option 3), behind a parameter.** On top of
`STREAM`: a W stage for load data (the load retires and the next
instruction starts while its data comes back; an interlock when the next
instruction uses it), a one-cycle redirect (the next pc to the I-LS address
in the cycle it is computed; it is the pc's own next-state logic, 148 FO4
after stage 1, plus the macro's setup), and a predictor in the fetch (256
two-bit counters, a 32- to 64-entry target buffer, an 8-entry return stack;
LUT-RAM on an FPGA). Keep `S_EX` as the single commit point: every rule of
section 4 then holds as it does now, and most of the work is in the fetch
side, which `STREAM` has already opened up. Expected: 1.20 cycles per
instruction on the session against 1.75, at stage 1's clock, for a few
percent of logic. Guard it like `STREAM`: a parameter that defaults to off,
`make test` with both settings, a `test-*` target that keeps the old
setting tested, the profiler's cycles per instruction against the model's.

**Stage 3, only if the clock after stage 2 is still the problem: p5b.**
The model gives it about 1.2x more clock than stage 2 for the same CPI
range, at the cost of a new core and new core proofs. Before that, try the
cheaper middle: precompute in the fetch or decode cycle what does not depend
on operands (which checks and which trap causes apply, the next-state
choice), which shortens the 122-150 FO4 execute stage without adding a
stage.

**Separately, as research: hardware threads,** first on the FPGA, where
they would let StrataOS's six cores fit a board that exists, as threads
that are architectural cores (no ISA change). On GF180MCU they do not pay
until the SRAM is denser.

**Guards for every stage** (the details are in section 4):

- one commit point: every request out of the core (`give_valid`,
  `take_req`/`take_pop`, `tu_iss_valid`, `am_req`, `dom_req`, the store's
  and the save table's write enables) is raised only by the instruction at
  commit and gated by `held`; a property in `formal/props/strata_core.svh`
  that says so, before anything else is changed;
- the trace (`sim_trace`) written at commit, once per instruction, never
  for a flushed one; the debugger's stepping on the same point;
- `tgetx`, `xmap`, `csrw xslot/status/ipend` flush what was fetched after
  them; a fetch never runs ahead into a range a queued `tgetx` replaces
  (as `STREAM`'s `getx_busy` does now);
- capability registers forwarded or interlocked like integer registers,
  both of a moving instruction's writes in one commit;
- a stop or reset request taken at commit against the oldest instruction;
  the multiplier and divider abandoned;
- a test that runs the examples and the conformance suite with each new
  parameter off (as `test-nostream` does), and the full `make test` with it
  on, before any default changes.

## 6. The experiment: a parallel overlay search

`exp/par_overlay.py` writes a copy of `rtl/strata_core.sv` in which the two
searches compute every entry's match at once (`xm_m`, `xm_mi`), keep the
lowest matching entry as a one-hot vector (`m & (~m + 1)`) and select that
entry's fields by AND-OR. The lowest index still wins, as in the loop, so
the behaviour is the same by construction; `exp/check.sh` checks it:

- it builds the RTL simulator with that core and runs every example
  (`hello`, `mandel`, `pipeline`, `swcache`, `overlay`, `parsum`,
  `stream_sum`, `race`, `faults`, `clock`) on it and on `build/strata-rtl`:
  the console output and the full instruction trace are identical, cycle
  for cycle (measured);
- and the scripted StrataOS session, whose kernel pages its code units in
  through the overlay map (7,650 `xcall`s in the smart-memory run): the
  instruction trace of all eight cores (its MD5) and the console output are
  identical on both (measured).

Through the gate model (`CORE=... sta/core.sh ks par`):

| | today | parallel search |
|---|---|---|
| Cells (transistors in gates) | 148,739 (756,414) | 150,924 (764,294): +1.5% |
| Flip-flops | 11,371 | 11,371 |
| `xm_inslot` ready at | 222 FO4 | 35 FO4 |
| `xm_hit` ready at | 145 | 84 |
| `xm_link` ready at | 271 | 87 |
| Deepest path | 290 (pc -> `xm_link` -> register) | **152** (decoded instruction -> next pc / state / trap CSRs) |

The deepest path is now the execute cycle's ordinary work: decode, register
read, ALU or checks, and the trap and next-state choice. That is the wall a
pipeline would have to split next (section 2.3: 122 FO4 for E behind a D
stage).

## 7. Questions for you

1. **Stage 1 first?** It is a two-loop change with no cycle change and
   (on the model) half the critical depth. It needs the FPGA and ASIC runs
   to say what it is worth in MHz; they take about 15 minutes (ECP5) and
   3 hours (GF180MCU). Shall I do it on a branch, with those runs?
2. **Should `STREAM` (and `LS_1P`) be merged before any of this?** Every
   option here assumes `STREAM`'s fetch; stage 2 builds on its code.
3. **What is the target?** For many small cores on an affordable process
   the clock (stage 1) and the area (smart-memory's single-port stores and
   denser macros) matter most; for single-thread speed on an FPGA stage 2
   matters. That decides whether stage 2 is worth its weeks.
4. **Hardware threads**: is running StrataOS on a smaller FPGA (two
   physical cores of three or four threads each) a goal? It is the one case
   where threads clearly pay; it is a larger project than stages 1 and 2
   together.
5. **Prediction state**: a predictor is invisible architecturally, but its
   state survives a context switch and could leak a little timing between
   processes (as on any predicted core). Flush it on `eret` to user mode, on
   a core-control reset only, or accept it?

## 8. Measured, modelled, estimated

**Measured in this work** (scripts in this directory; outputs in
`results/`: the model's runs, `syn/` the gate model's tables, `par-check.txt`
the parallel search's check; the netlists and traces, not kept in git, in
`build/`):
- Instruction traces of six examples and the scripted StrataOS session on
  `build/strata-rtl` of the main branch (`-T virtual`, 8 cores, 64/64 KiB).
- The cycle model's results on them (`model/pipe.py`; `results/`), and its
  check against the profiler: today's core to the second decimal on all
  seven workloads. The model of the other designs is a model: no pipelined
  RTL exists.
- The gate model of the core (`sta/core.sh`, `sta/sta.py`): gate counts,
  arrival times of named signals, longest paths, the cut scenarios. Generic
  gates, logical-effort delays, no wires, no place and route: ratios and
  rankings, not nanoseconds.
- `exp/par_overlay.py` + `exp/check.sh`: the parallel overlay search, its
  gate count and depth, and its cycle-identical runs.

**Measured by runs kept in the repository or on the smart-memory branch**
(not re-run): the profiler's cycles per instruction with and without
`STREAM`; the GF180MCU and ECP5 periods, areas and critical paths; the
far-atomic and `ltag` cycle costs the model takes as constants.

**Estimated:** every clock in MHz (model ratios applied to the kept runs'
periods, as ranges); every area of a design that does not exist (flip-flop
counts from the state each needs, times the kept run's 59 µm² per
flip-flop at 3.3 V); the multiplier latencies at p5's clock; the barrel's
area and fit on an FPGA.

**Not done:** no pipelined RTL; no place and route of the parallel search
(stage 1's first step); no model of the barrel's Local Store port
contention (one fetch and about 0.17 data accesses per instruction for four
threads: two ports or banking by thread); the profile is one session of one
OS build, with mostly idle cores.

## 9. Measured: the merge and stage 1 in place and route

The stream fetch and `LS_1P` were merged into main (`STREAM = 1` by
default), and stage 1, the parallel overlay search, went into
`rtl/strata_core.sv` (cycle for cycle the same machine; `make test` and
`make formal` pass). Then the kept flows were run on it, and the ECP5 flow
also on the merge commit just before stage 1, so that the two differ in
the overlay search alone. One run each; the logs' timing parts are in
`results/runs/`.

| | ECP5-85F (nextpnr, routed) | GF180MCU 3.3 V cells (typical corner) |
|---|---|---|
| kept results: RTL before the stream fetch | 20.02 MHz, 44,253 logic cells | 24.5 MHz (40.8 ns) |
| merge commit 79bb1f9: `STREAM`, `LS_1P`, before stage 1 | **18.82 MHz**, 52,289 logic cells | not run |
| 858a4f7: with stage 1 | **18.93 MHz**, 52,992 logic cells | **22.4 MHz** (44.6 ns; worst slack -4.58 ns against 40 ns) |

- **Stage 1 bought nothing measurable.** 18.82 against 18.93 MHz is within
  what nextpnr varies between runs of the same design. The critical paths
  before and after start at the decoded instruction (`u_dec`, `d[72]` on
  GF180MCU) and run through the trap and next-state logic (`s_tval`,
  `u_cause`), the integer register file, the `ltag` sequencer and the
  stream fetch's buffers; none passes through the overlay map. On the ECP5
  44 to 45 ns of the 53 ns are wire.
- **Why the gate model was wrong.** It has no wires, and it maps without
  the timing-driven restructuring the real flows do. The chain it found
  deepest was deep in gates but short in distance; the real limit is how
  far the execute cycle's results and decisions travel across the core
  (register file, trap CSRs, fetch buffers, granule table copy). The
  paths the model ranked next (decoded instruction to pc, to the trap
  CSRs, 150 to 200 FO4) are the ones the real runs show, so the model is
  right about *which* logic is critical once the outlier is gone, and
  wrong about how much an outlier mattered.
- **The stream fetch costs clock**: 20.0 -> 18.8 MHz on the ECP5 (6%), with
  18% more logic cells (`STREAM`, the `LS_1P` paths that exist even when it
  is off, and what main gained since the kept run); 24.5 -> 22.4 MHz on
  GF180MCU (9%, without a clean baseline). Against 1.84x fewer cycles per
  instruction it is still a 1.7x gain in time.
- The published results (`fpga/results/`, `asic/results/`, the site, the
  manual's tables) are of the RTL before the stream fetch and say so; they
  were not replaced.

**What this changes in the recommendation.**

1. The cycle side stands: the trace model reproduces the measured cycles
   per instruction to the second decimal, and its gains do not depend on
   the clock. A 3-stage core (option 2/3) is still worth building, in the
   form that adds no long path: loads overlapped, the redirect registered
   (two cycles, as now) and a branch predictor. Estimated about 1.23
   cycles per instruction on the session against 1.75 (p3b with a
   two-cycle redirect: the predictor is wrong 0.35 M and misses its target
   buffer 1.68 M times in 64.6 M instructions, 2 cycles each, 0.063 against
   p3b's 0.032), about 1.4x at the same clock.
2. The 5-stage case rested on the clock, and nothing measured supports it
   now. Before any design work on it, one cheap experiment: register the
   operands and the operand capability before execute (as `ROADMAP.md`
   already suggests, as a throwaway change) and rerun the ECP5 flow; if the
   clock does not move clearly, deeper pipelining is not worth its cost
   here.
3. On the FPGA the clock is a placement and wire problem: the core is 63%
   of an 85F and its execute cycle fans out across all of it. Smaller
   logic (the granule table copy as block RAM, section 5.5 of the
   smart-memory report) or registering the trap and next-state decisions
   are the levers there, more than logic depth.
4. Stage 1 stays in: it costs nothing in cycles, little in gates, and
   removes a path that a timing-driven flow could otherwise hit after the
   others are fixed.
