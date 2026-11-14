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

## Not done (candidates for a next step)
- [ ] The stream fetch in `rtl/strata_core.sv` itself (the first prototype the report recommends)
- [ ] A single-port `strata_ram` with the Transfer Unit taking refusals, run through `make test`
- [ ] A liberty-based timing run (no PDK is installed in this checkout; `sta/sta.py` is technology-independent)
- [ ] Macro areas from an SRAM compiler for GF180MCU (OpenRAM has a technology directory; no published macro)
