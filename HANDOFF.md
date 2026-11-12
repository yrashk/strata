# Hand-off

Where the project stands on 2026-11-12 (main at the commit that adds this
file), for whoever continues. Read this first, then `PLAN.md` (decisions,
per-step history, design notes such as sections R and P) and the READMEs
listed under "Where things are written down". `ROADMAP.md` is the public
summary, and is partly stale (see "Docs that lag").

## What this is

Strata: a prototype 64-bit ISA where memory is explicit I/O. Each core has
two Local Stores (D-LS for data, I-LS for code, 4..64 KiB each, a platform
parameter) instead of caches; everything else is reached through a Transfer
Unit, with capabilities for authority. The tree has:
- `emu/`: the C reference emulator (interpreter with a predecoded fast loop,
  native JIT for arm64 and x86-64, WebAssembly JIT in the browser) and the
  debug engine (`emu/debug*.c`).
- `rtl/`: the synthesizable SystemVerilog, simulated with Verilator (`sim/`).
  Every example, the conformance suite and two StrataOS sessions run on
  both and are compared.
- `os/`: StrataOS 0.1. A microkernel (core 0 plus a dispatcher per worker
  core) that pages its own code units from T2; user-mode servers (`proc`,
  `dev`, `fs`, `tty`, `pipe`, `net`); a shell with job control and `cd`;
  utilities; a tag file system; TCP/IP with DNS and `httpd` (the emulator
  gives it a user-mode NAT with `-N nat`, the browser a relay); the window
  server `ws` with a terminal and demo clients; `vi`; guests (co-existing
  OSes on whole cores, `os/guests/`, `guest` command).
- `firmware/`: boot ROM and firmware library.
- `lang/forth/`: Strata Forth, native code, on bare metal, as a StrataOS
  program (new code goes into kernel-paged code units) and as a StrataOS
  guest (`lang/forth/guest/`). `lang/forth/progs/` has 22 of the os/progs
  ported to Forth; `vi.fs` is the editor in Forth.
- `dbg/` and `site/debug/`: the text debugger `strata-dbg` and the web
  debugger, both on the engine's JSON-lines protocol (`doc/debug-protocol.md`).
- `conformance/`: 32 self-checking tests run on the interpreter, the JIT and
  the RTL, plus a differential fuzzer.
- `fpga/`: Yosys synthesis for Xilinx 7-series and ECP5, nextpnr place and
  route on ECP5, the die drawing. `asic/`: LibreLane on GF180MCU.
- `doc/manual/`: the Architecture Reference Manual (LaTeX, built by CI);
  `doc/strataos.md`: the OS spec.
- `site/`: https://yrashk.com/strata/ (landing page, the manual's ISA and
  architecture pages, Forth reference and playground, Play (the emulator in
  the browser, with networking), Debug, Hardware, the source browser),
  deployed by `.github/workflows/pages.yml` on every push to main.

## State

Verified on 2026-11-12 on an arm64 Mac, NCORES=8, at the last code commit
(9894636): the full `make test` passed (exit 0), and the Pages deploy
succeeded. `make test` builds everything and runs, in order:
- the examples, emulator against RTL instruction by instruction;
- two StrataOS sessions in lockstep with the RTL (`os/demo.txt` and the
  guest session `os/guest-demo.txt`);
- the OS tests: break, shell, vi, vi.fs, the Forth ports, network, HTTP,
  window server, preemption, isolation, guests, process limits, boot under
  the JIT, the framebuffer;
- the JIT, the debuggers, the conformance suite;
- `test-small` (the 8-entry overlay map), `test-ls` (Local Stores at 32/32,
  16/4 and 4/32 KiB, and StrataOS refusing them);
- `test-wasm` (needs node and emcc).

It takes around an hour, more when the machine is busy. `make lint`,
`make manual` and `make wasm` also build. `make manual` prints a warning,
"Object @table.D.1 already defined", that nobody has looked at.

Not verified:
- Nothing has run on a board: there is no ECP5 board top and no bitstream.
- The x86-64 JIT has only run under Rosetta.

## How the work is done

- **Tests gate every push.** Run the full `make test` and push only if it
  exits 0 (chain the push behind it with `&&`; a push once went out after
  a failing test because it was not).
- **Git LFS:** `fpga/results/` and `asic/results/` keep logs, netlists and
  full-size die pictures in LFS. Run `git lfs push origin main` before
  `git push origin main`.
- **One change, every place.** When an ISA rule changes, change the
  emulator (interpreter and fast loop; the JITs' bounds masks), the RTL,
  the debug engine (disassembler, `pre_decode`, `stall_reason`,
  `prov_after`, the snapshot's `Misc` in `emu/debug_tt.c`), conformance
  tests (checked to fail without the change), the manual and the spec
  together.
- **House style:** every assembly line has a comment. The lockstep tests
  depend on `-j` / `-T virtual` behaving exactly the same on both machines.
- **Parallel agents** worked in git worktrees (`.claude/worktrees/`), each on
  its own branch, merged into main by hand after review and a full test.
  When two branches touch `os/kernel.s`, check the worker's resident code
  still ends below K0TEXT (0x7700): it ends at 0x76E8 now, 24 bytes to spare.
  Anything new on the worker side should go into a kernel unit
  (`os/kunits/`), not the resident part.
- Commit messages end with a `Co-Authored-By:` line naming the model that
  made the commit.

## Hardware

**FPGA** (`fpga/README.md`, `fpga/results/`)
- One core is placed and routed on a Lattice LFE5U-85F (Radiona ULX3S part)
  at 20.0 MHz with nextpnr-ecp5 0.11.1: 52.9% of the logic cells, 180 of 208
  block RAMs. The critical path runs from the D-LS block RAM's read port to
  the trap cause register. Two cores do not fit the 85F (103% logic, 118%
  block RAM).
- On Xilinx 7-series (Yosys, no place and route): one core about 32k LUTs,
  each further core about 28k. Two fit an XC7A200T; the six StrataOS needs
  (168,694 LUTs) need a Kintex-7 325T.
- The Local Store size moves block RAM, not logic: about one RAMB36 per
  4 KiB saved (88 at 64/64 KiB, 59 at 4/4).
- Scripts: `fpga/synth.sh FAMILY N [NXMAP [D I]]`, `fpga/pnr.sh`,
  `fpga/ecp5-runs.sh`; the die picture is drawn from nextpnr's output.

**ASIC** (`asic/README.md`, `asic/results/`, site page `hardware/asic/`)
- One core through LibreLane 3.0.17 (its arm64 Docker image, run under
  OrbStack) on GF180MCU: a 10.34 × 9.05 mm die (93.6 mm²), 59% of it SRAM
  (the PDK's 512 × 8 macros; no denser memory exists for GF180 with open
  tools). With the 3.3 V cells (`gf180mcu_as_sc_mcu7t3v3`), 24.5 MHz
  typical and 30.4 MHz fast, in 1 h 58 min. With the 5 V cells, 11.9 MHz,
  in 2 h 47 min.
- Not a tapeout. The Local Stores are a single-port stand-in for the RTL's
  dual-port RAM. There is no timing repair (OpenROAD's `repair_timing`
  crashed), hold is not fixed, and there is no DRC/LVS signoff.
- LibreLane runs need a lot of memory: one run at a time, and watch swap.

## Open work

**Waiting on a decision**
- *User-mode Local Store protection* (an ISA change). In user mode a load,
  store or transfer can reach any Local Store address, including the
  dispatcher's data (D-LS 0xA000..0xDFFF) and the kernel's code (I-LS
  0x4000..0x7FFF), so a hostile program can take over its core's kernel.
  Capabilities themselves are safe (they never live in Local Store bytes).
  The proposal: supervisor-only bounds registers, a user window per Local
  Store, checked on every user-mode access and transfer range; nestable
  (any mode may narrow, only the outer level widens, a trap restores the
  outer window). Not started.
- *ASIC with two and six cores*: scripted (`asic/run.sh N`), paused by the
  user.

**Ready to do**
- ASIC runs with smaller Local Stores (16 and 8 KiB per store, about two
  hours each), to see whether a core fits a wafer.space slot (~20 mm²). It
  needs the sizes wired into the flow first: `-set DLS_KIB d -set ILS_KIB i`
  in `asic/run.sh`'s `chparam`, `DLS_KIB=d`, `ILS_KIB=i` in
  `asic/mkconfig.py`'s `SYNTH_PARAMETERS`, and the floorplan (`ROWS = 16`
  and the die arithmetic in `mkconfig.py`) following the row count, which
  is KiB/4 per store.
- ECP5 synthesis numbers at the smaller Local Store sizes (only xc7 was run).
- A StrataOS (and Forth) layout for 32 KiB stores. It needs a new program
  ABI: today's layout fills both 64 KiB stores (`os/kernel.s`'s header).

**Guests**
- `halt` does not stop cores a guest is running; stop guests first.
- A guest whose console is not attached can still write to it.
- `lang/forth/demos/gfx.fs` cannot run in a guest (no framebuffer).
- StrataOS as a guest of StrataOS: not done (it was the optional second
  part of the guest work, skipped).

**Debuggers**
- The RTL behind the same protocol; a timing model; per-line stepping; the
  timeline's axis is rounds, which jump when an idle machine skips time.

**Smaller**
- The native JIT backends do not translate code while a device read is
  pending (they use the fast interpreter loop then).
- `conformance/FINDINGS.md` F7 and F8 (documentation) are open.

**Docs that lag**
- `ROADMAP.md` "Known limitations" predates several fixes: console reads
  can be cancelled (the release port completes them), the emulator's
  `ltag`/`linst` wait for pending device reads, the shell has `cd`, the file
  system has tags and subdirectories, and the core is placed and routed.
- `PLAN.md`'s section headings still say TODO or IN PROGRESS for work that
  is done (4, 6, 7, 8, 9, F), with unticked boxes; its "Resuming" section is
  from before the first push.

## Where things are written down

| File | Covers |
|---|---|
| `PLAN.md` | Decisions (do not reopen), per-step history, design notes (R: revocation by address, P: Local Store sizes) |
| `doc/strataos.md` | The OS spec, incl. guests, code paging, the switch work's numbers |
| `doc/debug-protocol.md` | The debug engine's protocol |
| `os/PLAN-os.md` | Kernel and servers: decisions, deviations from the spec |
| `os/progs/PLAN-sh.md` | The shell |
| `os/ws/README.md` | The window server |
| `lang/forth/README.md` | Forth: bare metal, StrataOS, code paging, as a guest |
| `emu/jit/README.md` | Native JIT |
| `web/README.md` | Browser build: worker, fast interpreter, wasm JIT, networking |
| `conformance/README.md`, `conformance/FINDINGS.md` | Conformance suite and what it found |
| `fpga/README.md`, `asic/README.md` | Hardware flows, numbers, what was tried |

## Useful commands

```
make                  # sasm, strata-emu, strata-rtl
make test             # everything (about an hour)
make conformance      # the conformance suite on interpreter / JIT / RTL
make boot             # StrataOS on the emulator; boot-ws: with the window server
make show-gfx         # an example's framebuffer in a window (show-NAME)
make forth            # Forth on bare metal; test-forth: its tests
make debug-pipeline   # strata-dbg on an example (debug-NAME); debug-os: StrataOS
make debug-web        # the web debugger on the desktop engine; debug-web-os: with StrataOS
make web-site         # the site incl. the wasm emulator -> build/web-site
make manual           # the PDF (needs tectonic)
make DLS_KIB=16 ILS_KIB=16 all   # an RTL with smaller Local Stores (strata-emu -L 16)
```

Rules that bit us:
- sv2v/yosys: never put a `for` loop inside an `if` in `always_comb`.
- `strata_ram` carries `(* no_rw_check *)`: keep the hazard stalls that
  make same-cycle read-after-write through the other port unobservable.
- The emulator-vs-RTL OS comparison can only compare what programs print:
  emulator rounds and RTL cycles are different time bases, so preemption
  points differ. Timing bugs show up as a hang on one side (the duplicated
  capability send fixed on 2026-11-12 looked like that).
