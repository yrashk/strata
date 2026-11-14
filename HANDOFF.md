# Hand-off

Where the project stands on 2026-11-12 (main at the commit that adds this
file), for whoever continues. Read this first, then `PLAN.md` (decisions,
per-step history, design notes such as sections R and P) and the READMEs
listed under "Where things are written down". `ROADMAP.md` is the public
summary: what exists, the known limitations, what is next.

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
- `lang/cc/`: `cc`, a C99 compiler that runs in StrataOS (`cc file.c`
  writes a program image; it needs `/bin/cc.lib` and `/bin/cc.u`). The
  compiler is `cc.c`; `cc.s` is the bootstrap compiler in assembly (`cc0`)
  that compiles it, and `make test-cc-boot` checks that `cc.c` then
  reproduces itself. `build/strata-cc` is `cc.c` built for the host, a cross
  compiler, and what the Makefile makes the disk's `cc` with. Also here: the
  run-time library and headers, and a ladder of 521 C test programs (`make
  test-cc`: all pass). `asm("...")` and intrinsics reach the machine from
  C. The disk also has `cc0` and `/src/cc.c`. State and
  open items: `lang/cc/PLAN-cc.md`.
- `dbg/` and `site/debug/`: the text debugger `strata-dbg` and the web
  debugger, both on the engine's JSON-lines protocol (`doc/debug-protocol.md`).
- `conformance/`: 32 self-checking tests run on the interpreter, the JIT and
  the RTL, plus a differential fuzzer.
- `formal/`: SymbiYosys proofs of the RTL (added 2026-11-13, see below).
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

## The RTL in the browser (added 2026-11-13, not yet deployed)

`make wasm-rtl` builds `build/web/strata-rtl.js/.wasm`: Verilator's C++ of
`rtl/` (8 cores, `WEB_RTL_CORES`) compiled with em++ together with
`web/web_rtl.cpp`, which includes `sim/main.cpp` and answers the same calls
as the emulator's module (`web/web.c`). The play page has a "Machine"
choice (`?machine=rtl`); the worker loads either module. `sim/main.cpp` got
file-scope model/counters and a `sim_cycle()` for this.
- Verified: `make test-wasm-rtl` (wasm RTL = native RTL, same output, cycle
  counts and frame on 7 examples); in a browser: hello, gfx (live scanout),
  the Forth REPL. The native examples comparison still passes. The full
  `make test` was not re-run after this change.
- StrataOS boots on it to the shell prompt under node (4.7M cycles, about
  15 s). Not verified: StrataOS on it in the browser itself,
  the pointer, and the CI step: `pages.yml` installs the distribution's
  Verilator, which may be too old for the RTL; the step then only warns and
  the page hides the choice (it probes for `strata-rtl.wasm`).
- Limits: no idle detection (a waiting machine keeps a CPU busy), no
  network far end, `-T virtual` only (machine time = cycles / 100).

## kira (added 2026-11-13)

`kira` (`os/progs/kira.s`, `os/progs/kira/`, plan, decisions and sizes in
`os/progs/PLAN-kira.md`) is Princess Kira: four games for a five-year-old
as a window-server client, on the ordinary disk (`ws kira`, or `kira` from
the palette) and a preset on the play page (the page types `ws kira` at
the first prompt: a preset's `type`). Friends (a new world for every game,
`kira/world.s`; seen from above, or through Kira's eyes, `kira/eyes.s`),
Garden (kept in `/ws/kira.sav`), Paint, Music.
- The art is drawn by `tools/kira-art.py` into `os/progs/kira/art/` (the
  specification is `SPEC.md` there, with exact sizes and rectangles the
  program relies on); `tools/kira-assets.py` converts it and synthesises
  the sounds; `make kira-dat` runs both.
- `tools/test-kira.sh` (in `make test`) compares the last frame of each
  `kira demo N`. A change of art, of drawing, or of the order in which
  random numbers are drawn needs new checksums, and may need the demos'
  clicks moved (their worlds come from a fixed seed).
- Limits it is near: 36.9 of the 40 KiB of D-LS, 23.7 of the 32 KiB of
  code. Adding a file to the disk moves what `tools/test-files.sh` and
  `tools/test-http.out` check.
- Seen and heard: every game seen on the emulator and in a browser (the
  play page built here); the sounds are checked only as samples in a WAV
  file, not by ear.

## wdoom and the sound device (added 2026-11-13, not yet deployed)

`wdoom` (`os/progs/wdoom.s`, `os/progs/wdoom/`, plan and measurements in
`os/progs/PLAN-wdoom.md`) is a first-person shooter as a window-server
client, with a converted subset of Freedoom's art and sounds
(`tools/wdoom-assets.py`, `os/progs/wdoom/wdoom.dat`). `make boot-wdoom`
boots into it (`ws PROGRAM` is new); `tools/test-wdoom.sh` is in `make test`.
- The sound device (`common/sound.h`, spec 1.2) exists only in the emulator
  and only when asked for (`-a`, `-A FILE`; `make boot*` and the play page
  ask), because the RTL has none and the sessions compared with it must
  see the same platform table. Putting it into `rtl/strata_dev.sv` (a DPI
  sink, as for the pointer) and then making it unconditional is open.
- Heard in a browser (the play page): the sounds are right. The tests check
  that the pistol's samples reach a WAV file. Not verified: the SDL path
  beyond compiling.

## Formal verification (added 2026-11-13)

`formal/` holds SymbiYosys proofs of the RTL: `make formal` (all, about 15
minutes, not part of `make test`), `make formal-NAME`. `formal/README.md`
has the table of proofs, the assumptions and what is not covered;
`formal/FINDINGS.md` what was found.
- The RTL modules `strata_div`, `strata_mul`, `strata_bus`, `strata_tu`,
  `strata_mem`, `strata_dev`, `strata_core` and `strata_top` each end with three lines that include
  `formal/props/MODULE.svh` under `ifdef FORMAL`. Nothing else in `rtl/`
  knows about the proofs. A change to one of these modules should be
  followed by `make formal-NAME`; the properties name internal signals, so
  a rename breaks them (the error names the line in `formal/build/strata.v`).
- Two RTL bugs were found and fixed. FINDINGS F1 (`strata_top`): a
  revocation walk that outlived its core's reset gave its done to the
  core's next request; only reachable with both Local Stores at 4 KiB.
  F2 (`strata_core`): a store that a stop preempted in user mode had
  already written the D-LS, so the supervisor saw memory changed by an
  instruction that had not executed (it runs again on resume, which hid
  it). `formal/repro/run.sh` shows both on the emulator and the RTL (it
  builds `build-f44/`: two cores, 4/4 KiB). The emulator needed no change.
- Verified after the fix: `make lint`, `make conformance`,
  `BUILD=build NCORES=8 ./tools/compare.sh build/examples/*.stx`, the
  reproduction, and every proof. The full `make test` was not re-run.
- Also changed in the RTL: `ct_we` has `&& !rpend` (FINDINGS O7).
  `make test-ls` ends with `formal/repro/run.sh`.
- Not proved: what instructions compute (the emulator comparison's ground),
  what device ports return, `strata_uart`, the system-wide invariant that
  write access to a byte has one holder. `formal/README.md` lists them with reasons.

## The file system is a store (added 2026-11-14)

The disk is no longer a directory of fixed entries. `os/servers/fs.s` keeps
files, names, tags and indexes as trees of a copy-on-write B+tree store
(`store.s`, `storew.s`, `sblob.s`, `fsops.s`, all included by `fs.s`). The
design and its decisions are `doc/strata-fs-proposal.md`; the plan with what
is done and what is not is `os/servers/PLAN-fs.md`; the protocol is in
`doc/strataos.md` ("The disk is a store"). The format's reference is the C
in `tools/stdb/` (`store.c` has the layout at its top, `fsl.h` the file
system's trees), which `mkdisk` and `build/stdb` (check, dump, ls, get) are
built from. The kernel boots from a boot manifest (`u_disk` in
`os/kunits/boot.s`).
- Tests: `make test-stdb` (the C store against a model, with the device cut
  after every block), `tools/test-store.sh` (a disk the OS wrote: checked
  from outside, read back after a second boot, power cuts). The emulator
  and the RTL harness take `-w FILE` (the disk written back); the emulator
  `--disk-cut N` and `--disk-cache SEED`.
- What to know before changing the server: the library's
  three 4 KiB buffers serve as its own (see the top of `fs.s`). A page
  address from `P` is good only until the second `P` after it. Tree changes
  use static scratch and do not nest; reads (`st_get`, `st_seek`) may
  happen inside one.
- Inside the OS: `db` and `wdb` (a window) show the trees, read from the
  disk with READBLK (`os/lib/stview.s`); `snap` takes, lists, deletes and
  restores snapshots, read through `/@NAME/` paths.
- The server does not include `os/lib/sys.s` (it has its own three buffers
  and one start-up message); about 5 KiB of its I-LS and 1 KiB of its D-LS
  are free. Its small data must stay below 32 KiB (loads use absolute
  16-bit addresses), so the large buffers are declared last.
- Not done (the plan has the list): private namespaces and
  transactions over several requests for other programs, terms answered
  from the index, the Forth ports on the cursor calls (they
  still use DIR and TAGS, which cut names to 24 bytes), facets beyond 64
  tags.

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

**Formal**
- `formal/repro/stopstore.s` as a conformance test in the harness (stops
  at every cycle of an instruction, for more instructions than a store);
  what the device ports return and the block device's engine; the
  system-wide invariant that no two holders have write access to a byte.

**Smaller**
- The native JIT backends do not translate code while a device read is
  pending (they use the fast interpreter loop then).
- `conformance/FINDINGS.md` F7 and F8 (documentation) are open.

**Smaller, from PLAN.md's open boxes**
- `make test-forth` is not part of `make test`; run it on its own.
- The emulator does not enforce one break read per core.
- The manual's op tables (18.x) were never re-checked against the final
  kernel and servers.

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
| `lang/cc/DESIGN.md`, `lang/cc/PLAN-cc.md`, `lang/cc/tests/README.md` | The C compiler: design, state and scores, the test ladder |
| `emu/jit/README.md` | Native JIT |
| `web/README.md` | Browser build: worker, fast interpreter, wasm JIT, networking |
| `conformance/README.md`, `conformance/FINDINGS.md` | Conformance suite and what it found |
| `formal/README.md`, `formal/FINDINGS.md` | The formal proofs: what each covers and assumes; what they found |
| `fpga/README.md`, `asic/README.md` | Hardware flows, numbers, what was tried |

## Useful commands

```
make                  # sasm, strata-emu, strata-rtl
make test             # everything (about an hour)
make conformance      # the conformance suite on interpreter / JIT / RTL
make formal           # the SymbiYosys proofs (formal-NAME: one target)
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
