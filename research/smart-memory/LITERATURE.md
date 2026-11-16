# Smart memory: literature and memory-density facts

Sources for `REPORT.md`, collected 2026-11-13. Format: fact — number — URL. "(computed)" marks arithmetic on numbers at the cited URL (area = W x H from the LEF `SIZE` line; µm²/bit = area / (words x bits)). Every URL was read (LEF and README files as raw files, papers as PDF text) unless the line says "unverified".

Reference point: one Local Store = 8192 x 64 = 524,288 bits.

---

## A1. GF180MCU

- Foundry macro family `gf180mcu_fd_ip_sram` has exactly four macros: 64x8, 128x8, 256x8, 512x8, all single-port — https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/SRAM/gf180mcu_fd_ip_sram/index.html
- 512x8 datasheet: 6T bitcell 13.5 µm²; synchronous single-port (separate D/Q); 431.86 x 484.88 µm = 209,400 µm²; supply 1.62–5.5 V; typical Tcyc 6.08 ns @5 V, 9.24 ns @3.3 V, 23.56 ns @1.8 V — https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/SRAM/gf180mcu_fd_ip_sram/cells/gf180mcu_fd_ip_sram__sram512x8m8wm1/gf180mcu_fd_ip_sram__sram512x8m8wm1.html
- LEF sizes (all 431.86 µm wide): 64x8 height 232.88; 128x8 height 268.88; 256x8 height 340.88; 512x8 height 484.88 — https://raw.githubusercontent.com/google/globalfoundries-pdk-ip-gf180mcu_fd_ip_sram/main/cells/gf180mcu_fd_ip_sram__sram512x8m8wm1/gf180mcu_fd_ip_sram__sram512x8m8wm1.lef (same path pattern for the other three)
- Macro-level density (computed): 64x8 196 µm²/bit; 128x8 113 µm²/bit; 256x8 71.9 µm²/bit; 512x8 51.1 µm²/bit. Marginal cost 256->512 words = 30.4 µm²/bit vs a 13.5 µm² cell, i.e. the macro is periphery/width-dominated: the array is only 8 bits wide in a 432 µm wide frame — same LEF URLs
- **Open Circuit Design 3.3 V rework** `gf180mcu_ocd_ip_sram` (R. T. Edwards, Apache-2.0, 2025): 64x8, 256x8, 512x8 and a new **1024x8**; all 301.30 µm wide; heights 152.21 / 224.93 / 321.89 / 515.81 µm — https://raw.githubusercontent.com/RTimothyEdwards/gf180mcu_ocd_ip_sram/main/cells/gf180mcu_ocd_ip_sram__sram1024x8m8wm1/gf180mcu_ocd_ip_sram__sram1024x8m8wm1.lef (and sibling cell dirs)
- OCD density (computed): 64x8 89.6; 256x8 33.1; 512x8 23.7; **1024x8 19.0 µm²/bit** (2.7x denser than the 5 V 512x8). Still single-port. One Local Store = 64 x 1024x8 = 9.95 mm² vs 128 x fd 512x8 = 26.8 mm² (computed)
- OCD method: 5 V devices (0.6 µm) rescaled to 3.3 V (0.28 µm), core cell "approximately 0.7x the original size (which is about 1/2 area)" — https://raw.githubusercontent.com/RTimothyEdwards/gf180mcu_ocd_ip_sram/main/cells/gf180mcu_ocd_ip_sram__sram512x8m8wm1/README
- OpenRAM has a `gf180mcu` technology directory (alongside sky130, freepdk45, scn4m_subm) — https://api.github.com/repos/VLSIDA/OpenRAM/contents/technology . No published GF180 OpenRAM macro areas found: unverified.
- DFFRAM on `gf180mcuD`: "No (Hold violations in the Netlist)", not silicon-proven — https://raw.githubusercontent.com/AUCOHL/DFFRAM/main/Readme.md
- wafer.space Run 3 (GF180MCU, 1,000 dies per slot): full slot 3.93 x 5.12 mm = 20.12 mm² die, 12.92 mm² core inside default pad ring, $7,000 early-bird / $8,000 standard; half slots (1.94x5.12 or 3.93x2.53, ~9.9 mm²) $4,000 / $5,000; quarter slot 1.94 x 2.53 mm = 4.9 mm², $2,000 / $3,000. Purchase deadline 9 Dec 2026, GDS 16 Dec 2026, parts Q2 2027 — https://wafer.space/
- Consequence (computed): full slot = ~$348/mm² early-bird, but the largest die is 20.12 mm²; a 93.6 mm² core does not fit any slot, and one fd-macro Local Store (26.8 mm²) alone exceeds a full slot — https://wafer.space/

## A2. SKY130

- Foundry bitcells used by OpenRAM: single-port 1RW 6T = 1.896 µm² (1.58 µm tall); dual-port 1RW1R = 6.162 µm² (1.975 µm tall); cell ratio 3.25x (computed) — https://par.nsf.gov/servlets/purl/10495552
- OpenRAM LEF sizes: `sky130_sram_1kbyte_1rw1r_32x256_8` 479.78 x 397.5 µm; `sky130_sram_2kbyte_1rw1r_32x512_8` 683.1 x 416.54 µm; `sky130_sram_1kbyte_1rw1r_8x1024_8` 455.3 x 446.46 µm — https://raw.githubusercontent.com/VLSIDA/sky130_sram_macros/main/sky130_sram_1kbyte_1rw1r_32x256_8/sky130_sram_1kbyte_1rw1r_32x256_8.lef (same pattern for others)
- MPW2 test-chip table (W x H µm): 1RW1R 4kbyte 32x1024 693.9 x 668.8; 1RW1R 8kbyte 32x2048 1093.8 x 720.5; 1RW 1kbyte 32x256 478.4 x 223.4; 1RW 2kbyte 32x512 481.1 x 322.7; 1RW 4kbyte 32x1024 806.9 x 351.2; 1RW 4kbyte 64x512 828.6 x 339.0; 1RW 8kbyte 830.7 x 541.7 — https://par.nsf.gov/servlets/purl/10495552
- Macro density (computed from the two sources above), 1RW1R: 1 kB 23.3; 2 kB 17.4; 4 kB 14.2; 8 kB 12.0 µm²/bit. 1RW: 1 kB 13.0; 2 kB 9.5; 4 kB 8.6; 8 kB 6.9 µm²/bit. Macro-level 1RW1R / 1RW ratio = 1.6–1.8x
- Measured silicon: read capture delay swept 6.6–11 ns at 10–45 MHz (slow; these are not fast macros) — https://par.nsf.gov/servlets/purl/10495552
- Known issue: SKY130 dual-port bitcell had LVS-model problems (two disconnected devices) found after tapeouts — https://www.escholarship.org/content/qt6118z9jc/qt6118z9jc.pdf?t=s7ppep ; a 1 kB dual-port OpenRAM macro there is 207,840 µm² (25.4 µm²/bit computed)
- `sky130_sram_1rw_tiny`: not present in VLSIDA/sky130_sram_macros today — dimensions unverified.
- DFFRAM (sky130, 32-bit words, historical compiler with custom placer): 512 B 396.52 x 388.96 µm, 26,557 bits/mm²; 1 kB 792.58 x 397.12, 26,027; 2 kB 26,297; 4 kB 26,196; 8 kB 1,589 x 1,572, 26,229 bits/mm² = ~38 µm²/bit (computed). Same table: OpenRAM raw 1 kB 46,541, 2 kB 62,372, 4 kB 75,014 bits/mm²; plain RTL through OpenLane 7,360–9,043 bits/mm² (110–136 µm²/bit computed) — https://raw.githubusercontent.com/AUCOHL/DFFRAM/main/Readme.md
- DFFRAM status: sky130A latch version signoff-clean and silicon-proven; DFF version signoff-clean, not silicon-proven — same URL
- ORRAM (OpenROAD-integrated standard-cell RAM generator, 2026): ~28,000 bits/mm² DFF, 31,000–32,000 bits/mm² latch (latch +15%); "current" DFFRAM flow only ~14,000–15,000 bits/mm²; OpenRAM up to ~148,000 bits/mm² at 8 kB (64-bit words); RTL+ORFS ~15,200–15,650 bits/mm² — https://arxiv.org/pdf/2607.12244
- Efabless shut down in 2025 Q1 after a funding round fell through; SKY130 shuttles restarted by ChipFoundry (chipfoundry.io) — https://docs.google.com/document/d/12KPutDPBst7FF0ncB1qyxErDYeATmXoQLGjRq38dfjU/mobilebasic
- ChipFoundry chipIgnite: $14,950 per tapeout; "up to 15 mm²" with standard I/O ring; 38 I/Os; 100 QFN parts or bare die; shuttles CI2612 (tapeout 7 Dec 2026), CI2705 (19 May 2027), CI2709 (22 Sep 2027) — https://chipfoundry.io/
- Cadence SKY130 MPW alternative: 40 dies per slot, no packaging — https://docs.google.com/document/d/12KPutDPBst7FF0ncB1qyxErDYeATmXoQLGjRq38dfjU/mobilebasic

## A3. IHP SG13G2

- Open PDK ships 20 single-port (`RM_IHPSG13_1P_*`) and 10 **dual-port** (`RM_IHPSG13_2P_*`) macro LEFs. Largest 1P: 8192x32_c4, 2048x64, 1024x64, 4096x16. Largest 2P: 1024x32 (no 64-bit-wide or >1024-word 2P) — https://api.github.com/repos/IHP-GmbH/IHP-Open-PDK/contents/ihp-sg13g2/libs.ref/sg13g2_sram/lef
- 2P is true dual-port by interface: ports A and B each have CLK, MEN, WEN, REN, ADDR, DIN, DOUT, BM — https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/main/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_2P_1024x32_c2_bm_bist.v
- 1P LEF sizes (µm): 64x64 784.48 x 64.36; 256x64 784.48 x 118.78; 512x64 784.48 x 191.34; 1024x64 784.48 x 336.46; 2048x64 784.48 x 626.7; 4096x16 416.64 x 618.3; 8192x32_c4 1520.16 x 618.3; 1024x32 416.64 x 336.46; 512x32 416.64 x 191.34; 256x32 416.64 x 118.78 — https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/main/ihp-sg13g2/libs.ref/sg13g2_sram/lef/RM_IHPSG13_1P_1024x64_c2_bm_bist.lef (same pattern)
- 1P density (computed): 64x64 12.3; 256x64 5.69; 1024x64 4.03; 2048x64 3.75; **8192x32 3.59 µm²/bit**. One Local Store = 2 x 8192x32 = 1.88 mm² single-port (14x smaller than GF180 fd, 5.3x smaller than GF180 ocd)
- 2P LEF sizes (µm): 1024x32 685.49 x 385.37; 1024x16 402.61 x 385.37; 512x32 685.49 x 219.77; 256x32 702.83 x 136.97; 64x32 702.83 x 74.87 — https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/main/ihp-sg13g2/libs.ref/sg13g2_sram/lef/RM_IHPSG13_2P_1024x32_c2_bm_bist.lef (same pattern)
- 2P density (computed): 1024x32 8.06; 512x32 9.19; 256x32 11.75 µm²/bit. **2P / 1P macro area ratio at equal size = 1.88x, 1.89x, 1.95x.** Dual-port Local Store from 16 x 2P 1024x32 = 4.23 mm²
- Europractice 2026 price: SG13G2 MPW 7,300 EUR/mm² standard, 6,205 discounted; mini@sic 6,205 / 5,110; minimum 0.8 mm² — https://europractice-ic.com/schedules-prices-2026/
- IHP open-source MPW offer (Aug 2025 post): SG13G2 "approx. 2800 EUR/mm²", ~8 months turnaround, 20 bare dies, 20% discount for OpenMPW participation — https://groups.google.com/g/mos-ak/c/ggijtHMlmfo
- Tiny Tapeout IHP shuttles: chips on loan, shippable only to EU and Switzerland (as of 2025) — https://docs.google.com/document/d/12KPutDPBst7FF0ncB1qyxErDYeATmXoQLGjRq38dfjU/mobilebasic

## A4. 65 / 40 / 28 / 22 nm via shuttles

- Drawn 6T bitcell sizes (Mentor/Novelics quote): 65 nm 0.525 µm²; 40 nm 0.299 µm²; 28 nm 0.198 µm² (0.1566 ultra-high-density); 22 nm 0.108 µm²; 16 nm FinFET 0.07 µm² — https://semiengineering.com/moore-memory-problems
- 28 nm HD 6T bitcell 0.12 µm² used in a 128 kb research macro — https://eecsg.mit.edu/chips/a-28nm-high-density-6t-sram-with-optimized-peripheral-assist/
- TSMC 28 nm 0.127 µm² and "40 nm 0.242 µm²": unverified from a page that could be read (search snippets attribute 0.242 µm² to TSMC 45 nm, not 40 nm; the semiwiki table page returned 403).
- Compiled-macro density for ~8k x 64 at 28/40/65 nm: no public datasheet found — unverified.
- Europractice 2026 mini@sic prices (EUR, standard / discounted): TSMC 65 LP 4,491 / 3,691 for the 1 mm² minimum + 419 / 360 per extra 0.1 mm²; TSMC 40 LP 21,386 / 18,386 for the 3 mm² minimum + 664 / 602 per 0.1 mm²; TSMC 28 HPC+ 10,609 / 8,509 for 1 mm² + 919 / 834 per 0.1 mm²; TSMC 16 FFC 30,592 / 26,592 for 1 mm² + 2,827 / 2,568 per 0.1 mm² — https://europractice-ic.com/schedules-prices-2026/
- Same page: GF 22FDX MPW 17,820 / 16,200 EUR/mm² (min 4 mm²), mini@sic 23,980 / 21,800 (min 1 mm²); GF 55 BCDlite 5,170 / 4,700 (min 9 mm²); UMC 65 43,750 / 41,580 per 4x4 mm block; UMC 40 70,500 / 66,980 per 4x4 mm block; X-FAB 0.18 µm 1,314 / 1,260 EUR/mm² (min 10 mm²) — https://europractice-ic.com/schedules-prices-2026/
- Discounted tier requires academic/research institution, Europractice membership, publicly funded research; GF mini@sic only for universities/research institutes — same URL
- Memory compilers via Europractice/TSMC: "SRAM compilers" listed for 65 nm and 40 nm; 28 nm "by TSMC, ARM, Synopsys"; 16 nm "by TSMC, ARM_Artisan, ARM ltd, GUC, Synopsys"; back-end views require "a firm tape out plan" and TSMC review (up to 3 months) — https://europractice-ic.com/technologies/asics/tsmc/
- Whether an individual/hobby team (non-university, no NDA) can obtain these compilers: unverified; the page describes institutional access only.

## A5. Two-port / dual-port vs single-port area

- SKY130 bitcell: 1RW1R 6.162 µm² vs 1RW 1.896 µm² = 3.25x; macro level 1.6–1.8x (computed, see A2) — https://par.nsf.gov/servlets/purl/10495552
- IHP SG13G2 macro level: true dual-port 2P vs 1P = 1.88–1.95x at 256–1024 x 32 (computed, see A3) — LEF URLs in A3
- Patent statement: "existing two-port SRAM circuits require approximately double the area of one-port SRAM circuits" — https://patents.google.com/patent/US7643330
- 28 nm FD-SOI 32 kb SRAM getting dual-port behaviour from foundry HD 6T cells (dual-rail, wordline boost): array area "62% lower" than 8T two-port/dual-port arrays — https://lup.lub.lu.se/record/8b32eb8d-6b4e-481c-ad3b-429a2962e870
- Double-pumped single-port (1R/1W per cycle): wordline pulses twice per external clock, read in first half, write in second half, shared decoder, one precharge per cycle; ports must be mutually synchronous; a plain 1-port run at 2x clock "generally requires substantial additional power" and may be infeasible at aggressive clocks — https://patents.google.com/patent/US7643330
- Cell SPE precedent: Local Store is single-ported; fetch, load/store and DMA are arbitrated onto one port (see B) — https://archive.decromancer.ca/bitsavers.org/pdf/ibm/IBM_Journal_of_Research_and_Development/515/riley.pdf
- Post-layout area/timing numbers for a 2x-clocked single-port vs an 8T dual-port compiled macro: unverified (none found).

## A6. Standard-cell / latch memories (SCM) vs SRAM macros

- SKY130 data points (A2): latch SCM ~31–32 µm²/bit, DFF SCM ~36–38 µm²/bit, flat across 512 B–8 kB; OpenRAM 1RW ~13 µm²/bit at 1 kB falling to ~6.9 at 8 kB. So on SKY130 OpenRAM wins from 1 kB up; SCM density is size-independent — https://arxiv.org/pdf/2607.12244 and https://par.nsf.gov/servlets/purl/10495552
- GF180 foundry macros: 64x8 costs 196 µm²/bit and 128x8 113 µm²/bit (A1), so for <= ~1 kbit an SCM is plausibly competitive on GF180; no measured GF180 SCM density found — unverified.
- Teman et al. (ASP-DAC 2015, 28 nm FD-SOI): controlled placement gives ~100% utilization; up to 22% area, 57% switching-power, 42% leakage reduction vs unstructured SCM; up to 88% lower switching power than equal-size foundry SRAM IP; works well below SRAM Vmin — https://cris.biu.ac.il/en/publications/controlled-placement-of-standard-cell-memory-arrays-for-high-dens-2/
- Teman TODAES 2016 claim "controlled SCMs smaller than SRAM macros up to 1 kbyte" and "average 25% area reduction": unverified (search snippet only; infoscience.epfl.ch returned 429).
- Meinerzhagen et al. (JETCAS 2011, 65 nm): SCM proposed as alternative to full-custom sub-VT SRAM for small blocks; abstract has no area numbers — https://cris.biu.ac.il/en/publications/benchmarking-of-standard-cell-based-memories-in-the-sub-vrm-t-dom/
- "SCM area/bit incl. periphery ~10x a 6T SRAM macro" (Andersson et al., 28 nm 8 kb): unverified (search snippet only).
- Timing benefit of SCM-in-logic: not quantified in any page that could be read — unverified. Related hard number: Cell SPE register file (128 x 128 b, 6R/2W, custom) takes 3 cycles vs 6 cycles for the 256 KB LS at the same 11 FO4 clock — https://archive.decromancer.ca/bitsavers.org/pdf/ibm/IBM_Journal_of_Research_and_Development/515/riley.pdf

---

## B1. Compute in SRAM (bit-line computing family)

- Jeloka et al. (28 nm FD-SOI, push-rule 6T): BCAM/TCAM/SRAM configurable; array area 2–5x smaller than conventional 10T/16T CAM cells; 64x64 (4 kb) BCAM 370 MHz @1 V, 0.6 fJ/search/bit. Needs: foundry push-rule 6T cell with split wordlines + modified sense/periphery (custom array, not a compiled macro) — https://manuscript.isc.ac/Inventory/49/735280.htm
- Logic op between two 64-bit words at 787 MHz @1 V (JSSC version): unverified (search snippet only).
- Compute Caches (Aga et al., HPCA 2017): in-place bit-line ops on cache sub-arrays; ~8% cache-area overhead; operands must share bit-lines (same sub-array; page-offset alignment); sense-amp result can be driven back onto bit-lines for copy — https://hackmd.io/@yaohsiaopid/SkMnzfzKH (reading note; paper PDF not retrievable)
- Compute Caches 1.9x performance / 2.4x energy, 54x micro-benchmark throughput: unverified (search snippet only).
- Neural Cache (Eckert et al., ISCA 2018): bit-serial arithmetic on transposed data in standard-cell-count 6T cache arrays; extra bit-line peripheral logic + extra decoder = 7.5% per 8 KB array, <2% of processor die; needs 8T transpose memory units (TMU, 0.019 mm² each); 28 nm circuit sim, 22 nm Xeon model; 18.3x vs CPU and 7.7x vs GPU on Inception v3 latency — https://arxiv.org/pdf/1805.03718
- Duality Cache (Fujiki et al., ISCA 2019): 1,146,880 bit-line ALUs in a 35 MB LLC; 3.5% die-area cost (15.8 mm² in 22 nm); 72.6x vs CPU on Rodinia; TMU based on 8T array — https://par.nsf.gov/servlets/purl/10122498
- CAPE (Caminal et al., HPCA 2021): associative (search/update, bit-serial, element-parallel) engine from push-rule 6T arrays after Jeloka; RISC-V vector ISA; average 14x (up to 254x) over an area-equivalent (~9 mm² at 7 nm) out-of-order tile — https://www.csl.cornell.edu/~cbatten/pdfs/caminal-cape-hpca2021.pdf
- EVE (Al-Hawaj et al., HPCA 2023): 6T bit-line-compute SRAM as ephemeral vector engine; layout based on an OpenRAM-generated SRAM; 8.2% area overhead vs vanilla 28 nm SRAM for the circuits, 9.0% (bit-serial) / 15.6% (bit-hybrid) / 12.6% (bit-parallel) per design; "as little as 11.7%" system-level; ~8x over an OoO core — https://www.csl.cornell.edu/%7Ecbatten/pdfs/alhawaj-eve-hpca2023.pdf
- Common process requirement: all need custom sense-amp/decoder periphery and multi-wordline activation on a foundry 6T (or 8T) cell; none is achievable with a black-box compiled or foundry hard macro.

## B2. DRAM / module-level PIM

- RowClone (MICRO 2013): in-DRAM copy via back-to-back activations; 4 KB copy latency 11.6x lower, energy 74.4x lower; zeroing 6.0x / 41.5x; inter-bank mode 1.9x / 3.2x — https://arxiv.org/pdf/1805.03502
- Ambit: bulk AND/OR/NOT by triple-row activation + dual-contact cells; <1% DRAM chip area — https://arxiv.org/pdf/1905.09822
- UPMEM PIM-DIMM: 8 DPUs per chip; each DPU has 64 MB DRAM (MRAM), 24 KB instruction RAM, **64 KB SRAM working RAM (WRAM)**; 14-stage pipeline; 350 MHz (267 MHz older) — https://arxiv.org/pdf/2105.03814 (structure close to Strata's split I/D Local Stores + bulk store)
- FlexRAM (ICCD 1999): 64 nodes per chip, each a 2-issue 800 MHz processor with 1 MB DRAM (12 clocks; row buffers 6 clocks) — https://courses.grainger.illinois.edu/CS533/sp2023/notes/pim2.pdf
- Active Pages / RADram (ISCA 1998): page of data + reconfigurable logic; "up to 1000X" in simulation — https://www.sciweavers.org/node/169299
- IRAM / Computational RAM: logic in a DRAM process (slow logic, high bandwidth); replacing embedded SRAM by eDRAM gives "~3x area savings" — https://en.wikipedia.org/wiki/Computational_RAM
- DRISA numbers (8.8x vs ASIC etc.): unverified (search snippet only).

## B3. Registers / workspaces living in RAM (historical)

- TMS9900: "memory-to-memory architecture"; 16 workspace registers are 16 contiguous memory words addressed by the Workspace Pointer; context switch exchanges only PC, ST, WP — https://ftp.mirrorservice.org/sites/www.bitsavers.org/components/ti/TMS9900/TMS_9900_Microprocessor_Data_Manual_May76.pdf
- Inmos transputer: three-register evaluation stack; locals addressed by 4-bit-nibble offsets from the workspace pointer (LDL/STL); on-chip RAM 2 KB (T212, T414), 4 KB (T222, T800) — https://en.wikipedia.org/wiki/Transputer
- Sun MAJC / SPARC register windows in SRAM: unverified (no citable source read).

## B4. Cell BE SPE Local Store (closest prior art)

- LS = 256 KB SRAM, **one-third of total SPE area**; macro = sum-address decoder (SAD) + four 64 KB sub-arrays + write and read accumulation buffers — https://archive.decromancer.ca/bitsavers.org/pdf/ibm/IBM_Journal_of_Research_and_Development/515/riley.pdf
- Timing: **writes complete in 4 cycles, reads in 6 cycles**, at full core clock. Cycle 1 SAD adds operands (address add fused into decode); 2 distribute predecoded indices to the four sub-arrays; 3 finish decode, select wordline; 4 access sub-array; sense amp holds value into read latch; 6 forward to execution units — same URL
- Access width 16 bytes or 128 bytes (line) per access; single-ported, shared by fetch (128 B via instruction line buffer), load/store (16 B) and DMA — https://old.hotchips.org/wp-content/uploads/hc_archives/hc17/2_Mon/HC17.S1/HC17.S1T1.pdf
- Contrast, same chip: PPE 32 KB L1 read latency 3 cycles (SAD / array / data); SPE register file 128 x 128 b, 6R+2W, 3 cycles — riley.pdf URL above
- SPE: 11 FO4, dual-issue, 4-way SIMD, IBM 90 nm SOI (Flachs et al., JSSC 41(1) 2006) — https://manuscript.isc.ac/inventory/49/777320.htm
- LS array uses conventional 6T cell + sense amp, six-stage pipelined, 4.8 GHz (Dhong et al., ISSCC 2005); cell area, LS mm², SPE mm² (2.54 x 5.81 mm / 14.5 mm² figures): unverified (PDFs returned 403).
- Lesson for Strata: IBM chose single-port + priority arbitration and pipelined the RAM (6-cycle load-use) rather than pay for a 2-port array; the address add was merged into the decoder.

## B5. Open-PDK demonstrations

- OpenRAM silicon on SKY130: OR1 (one 1 kB dual-port macro) and MPW2 (5 dual- + 5 single-port macros, 1–8 kB) taped out and measured — https://par.nsf.gov/servlets/purl/10495552
- OpenRAM-derived layouts used for (non-open-PDK, 28 nm) compute-SRAM estimation in EVE — https://www.csl.cornell.edu/%7Ecbatten/pdfs/alhawaj-eve-hpca2023.pdf
- Open-source bit-line-computing SRAM on SKY130 (Politecnico di Torino thesis), OpenCache, any OpenRAM CAM tapeout: unverified (thesis PDF did not download; no tapeout evidence found).
- IHP SG13G2 is the only open PDK found shipping a foundry true-dual-port SRAM macro (A3).

## B6. CAM cost

- Conventional BCAM/TCAM use 10T/16T cells; 6T push-rule approach is 2–5x smaller in array area — https://manuscript.isc.ac/Inventory/49/735280.htm
- Other CAM cell options in the literature: 9T CAM cell, precharge-free 10T BCAM; 6T split-wordline CAM removes the in-cell XNOR — https://past.date-conference.com/proceedings-archive/2023/DATA/762.pdf
- "TCAM >50% larger than BCAM", µm² per CAM bit, small standard-cell CAM areas: unverified.

## B7. Capability tags and revocation (CHERI)

- Tags: 1 tag bit per capability-sized word held out of band; tag controller/tag cache next to DRAM; hierarchical tag table reduces DRAM traffic overhead to below 5%, below 1% for most applications; a prior non-hierarchical design (HDFI, 1 KiB tag cache) showed 37.9%–373% DRAM access overhead — https://www.cl.cam.ac.uk/research/security/ctsrd/pdfs/201711-iccd2017-efficient-tags.pdf
- CHERIvoke (MICRO 2019): shadow map with 1 bit per 16-byte granule (<1% of heap); quarantine then sweep all memory; average 4.7% runtime overhead; `CLoadTags` instruction returns tags of a line without loading data so tag-free lines/pages are skipped — https://www.cl.cam.ac.uk/~tmj32/papers/docs/xia19-micro.pdf
- Cornucopia (S&P 2020): concurrent sweep using per-page capability-dirty tracking (a store-side check in the MMU); <2% average, 8.9% worst-case on compatible SPEC CPU2006 — https://www.cl.cam.ac.uk/research/security/ctsrd/pdfs/2020oakland-cornucopia.pdf
- Cornucopia Reloaded (ASPLOS 2024): per-PTE "capability load generation" bit compared with an in-core generation bit; mismatch traps on capability load (load barrier), so revocation starts by toggling only the core bit; in Morello and CHERI-RISC-V; median 87% of Cornucopia's DRAM traffic overhead on SPEC CPU2006, <50% for pgbench; re-measured Cornucopia cost 4% cycles / 9% bus traffic geomean — https://microsoft.com/en-us/research/uploads/prod/2024/02/revocation3-paper.pdf
- Where checks sit: tag read with the data word (memory/cache side); dirty bit on capability store and generation compare on capability load (both in the translation/PTE path, not in the RAM).

## B8. Memory-to-memory copy engines

- RowClone figures in B2 — https://arxiv.org/pdf/1805.03502
- Compute Caches copy: sense-amp output fed back to bit-lines copies one wordline to another without latching — https://hackmd.io/@yaohsiaopid/SkMnzfzKH
- Cell: LS write/read accumulation buffers assemble 128-byte line transfers for DMA/fetch over the 16-byte datapath — https://archive.decromancer.ca/bitsavers.org/pdf/ibm/IBM_Journal_of_Research_and_Development/515/riley.pdf ; EIB carries up to 96 B/cycle, each SPE port 16 B/cycle — https://old.hotchips.org/wp-content/uploads/hc_archives/hc17/2_Mon/HC17.S1/HC17.S1T1.pdf

## B9. Small L0 / tiered local memories and early address generation

- Filter cache (Kin et al., MICRO 1997): 256-byte direct-mapped L0 in front of L1; 58% power reduction, 21% performance loss, 51% energy-delay improvement — https://www.sciweavers.org/node/172994
- Scratchpad memory (Banakar et al., CODES 2002): average 40% energy reduction vs cache; area-time product 46% of the cache's — https://ls12-www.cs.tu-dortmund.de/daes/media/documents/publications/downloads/2002-codes.pdf
- Zero-cycle loads (Austin & Sohi, MICRO 1995): predecode + base-register cache (BRIC) + fast address calculation complete loads up to 2 cycles early; run-time-weighted speedup 1.45 (integer) / 1.26 (FP) with an 8-entry BRIC; 64-entry BRIC barely better — https://ftp1.cs.wisc.edu/sohi/papers/1995/micro.zcl.pdf
- Fast address calculation (Austin et al., ISCA 1995): predicts the effective address with carry-free (OR-style) composition so cache access starts before the add finishes — https://ftp1.cs.wisc.edu/sohi/papers/1995/isca.fast.pdf
- Sum-addressed decode (address add inside the RAM decoder) is used in both the PPE L1 and the SPE LS — https://archive.decromancer.ca/bitsavers.org/pdf/ibm/IBM_Journal_of_Research_and_Development/515/riley.pdf
- Stack cache / stack value file: unverified (no citable source read).

---

## Not verified

- Compiled SRAM macro density (µm²/bit) for ~8k x 64 single- or dual-port at 65/40/28/22 nm — vendor datasheets are NDA-only; nothing public found.
- TSMC 28 nm HD cell 0.127 µm² and the "40 nm 0.242 µm²" figure (search snippets say 0.242 is TSMC 45 nm; a Mentor quote that was read gives 40 nm 0.299, 28 nm 0.198/0.1566).
- Whether a non-institutional team can obtain TSMC/GF memory compilers; MOSIS/Muse and TSMC University FinFET terms and prices.
- Cell SPE: 6T cell area, LS area in mm², SPE dimensions/area/transistor count (Flachs JSSC 2006 and Dhong ISSCC 2005 full texts returned 403). The "one-third of SPE area", 6-cycle read and 4-cycle write are verified.
- Compute Caches headline 1.9x / 2.4x / 54x and Jeloka 787 MHz logic-op figure (paper PDFs unreachable; only the 8% area note and the 2–5x / 370 MHz abstract verified).
- DRISA speedups; "TCAM >50% larger than BCAM"; any µm²-per-CAM-bit figure; small standard-cell CAM areas.
- Teman TODAES 2016 "SCM smaller than SRAM up to 1 kbyte" crossover; Andersson "10x area/bit" figure; any quantified timing benefit of SCM placed inside logic.
- Measured area/timing of a double-pumped single-port macro vs an 8T dual-port macro.
- OpenRAM GF180 macro areas; `sky130_sram_1rw_tiny` dimensions; OpenCache; any open-PDK compute-in-SRAM or CAM tapeout.
- Sun MAJC / SPARC register-window SRAM implementation; stack cache / stack value file results.
- ChipFoundry usable user-project area (page says only "up to 15 mm²" with standard I/O ring); wafer.space Run 3 Crowd Supply page itself (403; figures taken from wafer.space).
