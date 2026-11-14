# Smart memory research: plan

Question: can moving computation and structure into or next to the Local
Store memories raise the RTL's speed or cut its area? The answer is
`REPORT.md`; sources are in `LITERATURE.md`.

## Baseline
- [x] Read `rtl/strata_core.sv`, `rtl/strata_tu.sv`, `rtl/strata_ram.sv`: how the stores are built and used, cycles per operation
- [x] Area: the kept ASIC run (`asic/results/gf180mcu-1*`), the kept FPGA runs (`fpga/results/`), one generic-gate synthesis of `strata_core` per module (`build/syn/`, Yosys, no place and route)
- [x] Timing: the kept post-route critical paths (ECP5, GF180MCU), and a start-class / end-class longest-path table over a mapped netlist (`sta/sta.py`, `sta/mini.lib`)
- [x] Dynamic: a profiler bound into every core (`prof/ls_prof.sv`, `prof/build.sh`, `prof/run.sh`, `prof/report.py`); examples and the scripted StrataOS session
- [x] Instruction-trace model: fetch schemes, load/use pairs (`model/fetch.py`)

## Directions
- [x] 1. An ALU at the Local Store
- [x] 2. D-LS and I-LS as one memory
- [x] 3. Local Store memory inside the logic
- [x] Beyond: compute-in-memory literature, tiered stores, the Transfer Unit's path, capability checks, port counts, bitcells and macros, registers and tables in memory

## Experiments
- [x] `exp/ls_unified.sv`: one single-port memory for both stores, instruction stream generated at the memory; random-traffic test bench, gate count (`exp/run.sh`)
- [x] Single-port feasibility from the profile (core and unit in the same cycle)
- [x] Fetch-cost model on traces of the examples and of StrataOS

## Report
- [x] `REPORT.md`: baseline, one section per direction, ranking table, recommendation, measured / estimated / literature
- [x] `LITERATURE.md`

## First prototype: the stream fetch (REPORT.md section 9)
- [x] `STREAM` parameter in `rtl/strata_core.sv` (default 0: today's fetch), `getx_busy` from `rtl/strata_tu.sv`, passed through `rtl/strata_top.sv`; `make STREAM=1`
- [x] `make lint`; `make test` with the default: passes
- [x] `make BUILD=build/stream STREAM=1 test`: passes (the browser RTL rule now takes `STREAM` too)
- [x] Profiler follows the retired instruction under `STREAM` (`prof/build.sh 8 64 64 1`, `prof/run.sh all -stream`)
- [x] Measured: StrataOS session 3.22 -> 1.75 busy cycles per instruction (model 1.92), examples 1.85x to 2.15x
- [x] Area and depth of the change, core only, generic gates (`sta/core.sh 0`, `sta/core.sh 1`): +4.0% gates, +98 flip-flops, no new deepest path
- [x] `STREAM` is 1 by default; `make test-nostream` (part of `make test`) and a lint line keep `STREAM=0` built and compared; the manual's implementation chapter and its cycle table say so; `make test` passes
- [ ] Its clock: place and route with `STREAM = 1` (`fpga/synth.sh` needs a `chparam` for it)
- [ ] `fpga/README.md`'s cycle table for `STREAM = 1`, once it is synthesized

## Second prototype: one single-port memory (REPORT.md section 10)
- [x] `LS_1P` parameter in `rtl/strata_core.sv` (default 0), `rtl/strata_ram1.sv`, `get_beat` / `put_want` / `ls_gnt` in `rtl/strata_tu.sv`, `make LS_1P=1`; `make lint` covers it
- [x] Deadlock found by the conformance suite and the OS boot (the fetch held the memory while waiting for a core-control write) and fixed; the read-ahead gives way to a waiting `tput` read
- [x] `make BUILD=build/ls1p LS_1P=1 test`: passes (with it `test-small`, `test-ls` and `test-nostream` in single-port builds)
- [x] `make test` with the default: passes
- [x] Measured: StrataOS session 1.75 -> 1.84 busy cycles per instruction (+5%); streaming examples +6%, the others 1% or less
- [ ] The core and an arriving burst sharing the memory cycle by cycle (a two-word buffer for beats, or a ready for read beats on the far bus)
- [ ] `asic/`: a single-port `strata_ram1` replacement, one store array in the floorplan, the 1024 x 8 3.3 V macros
- [ ] Area and clock of the change

## Not done (candidates for a next step)
- [ ] A liberty-based timing run (no PDK is installed in this checkout; `sta/sta.py` is technology-independent)
- [ ] Macro areas from an SRAM compiler for GF180MCU (OpenRAM has a technology directory; no published macro)
