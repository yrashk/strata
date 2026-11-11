# Hand-off

Where the project stands at the first push, for whoever continues. Read
this first, then `PLAN.md` (the full checkbox plan, decisions and history)
and the per-area plans listed below. `ROADMAP.md` is the public summary.

## What this is

Strata: a prototype 64-bit ISA where memory is explicit I/O, with
- a C reference emulator (`emu/`: interpreter with a predecoded fast loop,
  native JIT for arm64 and x86-64, WebAssembly JIT),
- a synthesizable SystemVerilog implementation (`rtl/`, Verilator harness
  in `sim/`),
- StrataOS 0.1 (`os/`: microkernel, servers, shell, utilities, the window
  server `ws` and its clients), firmware (`firmware/`),
- Strata Forth (`lang/forth/`, bare metal and as a StrataOS program),
- the debuggers: a debug engine in the emulator (`emu/debug*.c`,
  `strata-emu --debug`, protocol in `doc/debug-protocol.md`), the text
  debugger `strata-dbg` (`dbg/`) and the web debugger (`site/debug/`),
- a conformance suite (`conformance/`), the manual (`doc/manual/`, LaTeX),
- the website (`site/`: landing page, in-browser emulator `play/`, source
  browser `code/`), deployed by `.github/workflows/pages.yml`.

The design spec is `doc/strataos.md` (the OS is **StrataOS 0.1**).

## State at the push

Verified just before the push (on an arm64 Mac, NCORES=8):
- `make all os examples` builds; `make lint` is clean.
- `make conformance`: 21 tests pass on interpreter, JIT and RTL.
- `make test-forth`: bare metal (emulator = RTL), under StrataOS, and the
  preemption test pass.
- `tools/test-sh.sh`, `tools/test-ws.sh`: pass.
- The full `make test` finished green (exit 0) right after the first push.

Not verified:
- The Pages workflow's first run failed on Linux: the emulator did not
  compile with `-std=c11` (`clock_gettime`, `usleep`); `CFLAGS` now uses
  `-std=gnu11`. Whether the rest of the workflow passes is not yet known. It pins Emscripten 3.1.74 while all
  local builds used a much newer emcc; if the wasm build fails in CI, bump
  the pin in `pages.yml`.
- `ws` was only driven with scripted input (`-i`), never by hand in the SDL
  window.
- The x86-64 JIT was tested only under Rosetta.

## To finish the release

1. `make test` green (see above).
2. GitHub Pages: done. The `pages` workflow is green and the site, `/play/`,
   `/code/` and the manual PDF are live at https://yrashk.com/strata/
   (yrashk.github.io/strata redirects there).
3. License: done. MIT OR Apache-2.0 (`LICENSE-MIT`, `LICENSE-APACHE`).
4. Spec renamed: `doc/strataos.md`.
5. Fold the per-area plan files into their READMEs and delete them (see
   "Plans" below).

## Unfinished work (in order of how close it is)

### Pointer device (mouse + wheel) — started, not functional
- Design: `PLAN.md` has no section for it yet; the brief is: device window
  0x4100 (EVENT 0x4100: a read that completes on an event, packed u16 x,
  u16 y, u8 buttons, s8 wheel_y, s8 wheel_x, u8 kind; STATE 0x4108),
  platform entry type 7, host input from SDL / the browser canvas / a `-P`
  script, handed to `ws` by the `dev` server; in `ws`: cursor,
  click-to-focus, palette click, wheel = terminal scrollback, client event
  kinds 6 (pointer) and 7 (wheel), `wmandel` zoom/pan.
- Done: the host side in `common/display.h` (event queue, coalescing,
  script parser) and the constants in `common/platform.h`.
- **Withdrawn for the push**: the platform-table entry (`PLAT_ENTRIES` is
  back to 7 in `common/platform.h`) because the emulator device, the RTL
  and the tests did not exist yet and `conformance/tests/plat.s` failed.
  Re-add it together with the device.
- Not started: the device in `emu/emu.c` and `rtl/strata_dev.sv`, the `-P`
  flag, `dev` server, `ws`, clients, tests, docs.

### FPGA — numbers are real now; the design is big
- Both families synthesize with every large memory in block RAM
  (`fpga/README.md` has the tables and a per-module breakdown; the ECP5
  problem was the D-LS: fixed with `(* no_rw_check *)` in
  `rtl/strata_ram.sv`). No place-and-route, so no timing.
- About 47k LUTs per core on xc7. One core fits the Arty A7-100T, two need
  an XC7A200T (Nexys Video). **StrataOS needs 6 cores (~293k LUTs): more
  than any Artix-7.** `make fpga-images` still builds a StrataOS disk for
  the 2-core Arty top, which cannot boot it.
- Where to cut (measured): the overlay map is ~30% of a core (16 entries of
  64-bit range compares), the capability registers ~14%.
- The numbers predate the pointer device; rerun `fpga/synth.sh` after it
  lands (2-core runs ~12 min, 6-core ~55 min).

### Forth under StrataOS — works; docs/cleanup open
- `forth`, `forth file.fs`, `forth -n N` run under the OS; tests pass.
- The agent was cut off near the end: check `lang/forth/PLAN-forth.md`,
  `lang/forth/README.md` (the StrataOS section may be stale), and that
  `lang/forth/demos/gfx.fs` runs (it once failed with `.cap: undefined
  word` when tools moved to `tools.fs` / `see.fs`).

### The debuggers — done; what is open
- Built: the engine (control, breakpoints and watchpoints, state, event
  log, capability provenance, time travel with bounded memory, StrataOS
  and Forth awareness), `sasm -g` maps for every image, `strata-dbg`
  (gdb-like commands, `tui`, a pty for the guest's console), the web
  debugger (in the page or over a WebSocket to `strata-emu --debug PORT`).
  `tools/test-dbg.sh` (in `make test`) drives them.
- The engine is included by `emu/emu.c` and observes from outside
  `step()`; the only hooks in emu.c are in `far_wrote`, the block
  device's disk write, `trap`, the console output port, and the halt /
  fault messages (`emu/debug.h`). `Cap` got a 32-bit `id` (in its padding:
  still 32 bytes); emu.c disables -Wmissing-field-initializers for the
  capability literals that leave it 0. `machine_round` lost its idle
  computation to `round_idle()`, which the engine shares.
- When the ISA changes, the engine follows in three places: the
  disassembler (`emu/debug_sym.c`), `pre_decode` / `stall_reason` /
  `prov_after` (`emu/debug.c`) and the snapshot's list of machine state
  (`Misc` in `emu/debug_tt.c`: every static that a run depends on must be
  in it, or replays diverge; `info history` counts divergences).
- Open: the RTL behind the same protocol; a timing model; per-line
  stepping; the timeline's axis is rounds, which jump when an idle
  machine skips time (StrataOS).

### Smaller open items
- Console input reads cannot be cancelled: `halt` typed in a `term` under
  `ws` takes effect at the next key. Needs a small ISA change (e.g. the
  release port also completing input reads).
- `ws`: TEXT/FILL/TITLE protocol calls are implemented but unused and
  untested; Alt+arrows and `q` in `wmandel`/`wclock` were not exercised.
- The emulator accepts 4 pending device reads per core; the manual says
  one break read per core. `ltag`/`linst` do not check pending device
  reads (`conformance/FINDINGS.md` F2 remainder).
- The native JIT backends do not translate code while a device read is
  pending (they use the fast interpreter loop then).
- Manual: `doc/manual/ch-os.tex` prose in "The client protocol" still
  describes window surfaces as client memory; the implementation keeps
  surfaces in the server and clients lend bands (the tables are right).
- `os/ws/README.md` still has a "what remains" section from before the
  integration.
- Stretch goals: `PLAN.md` section S (Forth ahead-of-time compiler, more
  than 3 threads per core: done as the save-table pool and a 256-entry table, 16 per core).

## Plans and notes in the tree

| File | Covers |
|---|---|
| `PLAN.md` | Everything: decisions, per-step checklists, file ownership, history |
| `os/PLAN-os.md` | Kernel, servers: decisions, deviations from the spec, requests R1–R3, halt |
| `os/progs/PLAN-sh.md` | The shell |
| `os/ws/PLAN-ws.md`, `os/ws/README.md` | The window server |
| `lang/forth/PLAN-forth.md` | Forth |
| `emu/jit/PLAN-jit.md` | Native JIT |
| `web/PLAN-fast.md`, `web/PLAN-web.md` | Browser build: worker, fast interpreter, wasm JIT |
| `conformance/PLAN-conformance.md`, `conformance/FINDINGS.md` | Conformance suite and what it found |

`PLAN.md` also has "Agent history": the work was done by parallel agents
whose transcripts are on the original machine only; the plan files above
are the portable record.

## Useful commands

```
make                 # sasm, strata-emu, strata-rtl
make test            # everything (slow: the RTL boot comparison takes ~25 min)
make conformance     # 21 tests x interpreter / JIT / RTL (~15 s)
make boot            # StrataOS on the emulator (12 cores); type `ws`
make show-gfx        # the framebuffer window
make ws-demo         # the window server's drawing code with a simulated OS
make forth           # Forth on bare metal
make web-site        # the site incl. the wasm emulator -> build/web-site
make debug-pipeline   # strata-dbg on an example (debug-NAME); debug-os: StrataOS
make debug-web        # the web debugger on the desktop engine: localhost:4444/debug/
make manual          # the PDF (needs tectonic)
```

Rules that bit us:
- sv2v/yosys: never put a `for` loop inside an `if` in `always_comb`.
- Every assembly line is commented (house style); tests compare emulator
  and RTL instruction by instruction, so keep `-j` / `-T virtual` exact.
- When ISA rules change, change emulator, RTL, conformance tests, spec and
  manual together.
