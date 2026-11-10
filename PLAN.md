# Strata: working plan

**Start with [HANDOFF.md](HANDOFF.md)**: it says where things stand right now.

The state of the project and everything left to do, as checklists, so work
can resume from any point. Tick a box as soon as its item is done and
verified, and add an item whenever new work appears.

**Normative spec:** `doc/strataos-0.2.md`. It covers the devices, graphics,
memory, the microkernel, the servers, the shell, the window server and its
look-and-feel, boot, and the tests. When code and spec disagree, fix one of
them.

---

## Decisions (made by the user; do not reopen)

- [x] **Version:** the first release is StrataOS **0.1** ("0.2" in older notes and file names means this same release).

- [x] **Name:** Strata, image format `.stx`. Repo `yrashk/strata` (public).
  The local directory is still `~/Projects/IStrata`.
- [x] **No conventional interrupts:** devices complete transfers and `tany`
  waits on them. Core-control stop is the only forced preemption.
- [x] **StrataOS 0.2 is a microkernel with preemptive multitasking:**
  - a minimal kernel API (4 ops + `svc`); the servers are `proc`, `dev`,
    `fs`, `tty`, `pipe`, `ws`;
  - the kernel pages its own code; the shell and the window server are
    programs.
- [x] **UI:** a window server plus client programs (`term`, `wmandel`,
  `wclock`). The look is futuristic, not a desktop clone (spec 2.8).
- [x] **Screen:** default 1280x800 (`-r WxH`). System memory is 64 MiB; the
  framebuffer is the window [48, 64) MiB.
- [x] **Manual PDF:** never committed. CI builds it, it is served from
  GitHub Pages, and the README links to it.
- [x] **GitHub Pages:** a site at yrashk.github.io/strata with UI
  screenshots.
- [x] **Forth:** a modern Forth in `lang/forth/`, runnable bare metal *and*
  in StrataOS.
- [x] Internal review notes are kept outside the repo; the manual never refers to them.

---

## 1. ISA phases 1–3 (supervisor/user, revocation, endpoints, paging, tany) — DONE

- [x] Implemented in the emulator and the RTL.
- [x] All 9 examples match instruction by instruction (emu vs RTL).
- [x] The StrataOS 0.1 demo boot matches (2.25M instructions).
- [x] Ctrl-C test (`tools/test-break.sh`).
- [x] Fixes found along the way:
  - [x] the TU rotates a retried device transfer to the back of the queue;
  - [x] hand-over (cgive/cshare/catomic/tamo) waits for far-memory
    transfers only;
  - [x] cdom/crevoke/cundom error paths match the emulator;
  - [x] cjoin traps across revocation domains;
  - [x] a release write with no break read pending is dropped.
- [x] Self-hosted `as` knows every new mnemonic and CSR; `tools/test-as.sh`
  passes.

## 2. Manual for phases 1–3 — DONE

- [x] `doc/manual/` rewritten (157 pages); no review mentions.
- [ ] Update it for 0.2 (see step 7).

## 3. Devices and the machine — DONE

- [x] Timer at 0x3000: NOW / FREQ / DEADLINE / WAIT, 1 µs ticks.
  `-T real|virtual`.
- [x] Framebuffer: PRESENT at 0x4000, VSYNC at 0x4008, XRGB8888 in T3
  [48, 64) MiB.
- [x] Platform table: PT_FB (5) and PT_TIMER (6), geometry in the info
  word.
- [x] SDL2 window opened on the first PRESENT; keyboard mapping (Alt =
  ESC prefix, Ctrl-C = break).
  - [x] Flags `-g none`, `-F frame.ppm`, `-z N`, `-H`, `-r WxH`.
- [x] Shared host code in `common/display.h`. The emulator still builds with
  `-DNO_SDL`.
- [x] Console input is a non-blocking pending read on both machines.
- [x] `svc` (cause 14) and the user-mode inbox rule (corecount = 0 → priv),
  in emu and RTL.
- [x] MAXCORES 15; NCORES default 8; T3 = 64 MiB.
- [x] New examples:
  - [x] `examples/clock.s` (timer + `tany`);
  - [x] `examples/gfx.s` (multi-core Mandelbrot into the framebuffer,
    geometry from the platform table).
- [x] `tools/test-fb.sh`: emulator and RTL frames are byte-identical at
  1280x800. `tools/compare.sh` runs at `-r 640x480 -T virtual`.
- [x] `make show-NAME` / `make show-rtl-NAME` keep the window open.
- [x] `svc` in `sasm` and in `os/progs/as.s` (plus its feature test).
  `as.s` T3 is 64 MiB.

## 4. StrataOS 0.2 microkernel — IN PROGRESS (agent)

Owns: os/, firmware/, tools/mkdisk.c, tools/compare-boot.sh,
tools/test-break.sh, the StrataOS part of tools/test-as.sh, and the OS rules
of the Makefile.

- [x] **Boot**
  - [x] Boot header: far-image LBA/blocks (offsets 44/48). `mkdisk` writes
    the kernel's `.far` section.
  - [x] The boot ROM loads the far image to 0xF30000 and gives core 0 c12
    (R+X).
  - [x] The boot ROM also gives c13 = [16, 48) MiB and c14 = the
    framebuffer window (core 0).
  - [x] The directory has 128 entries (8 blocks).
  - [x] Firmware inventory prints the PT_FB / PT_TIMER entries.
- [x] **Kernel: system core**
  - [x] Event loop around `tany`; process table; placement on cores.
  - [x] Kernel ops: 1 CREATE, 2 DESTROY (dissolve domain), 3 MEMORY
    (arena in a fresh domain), 4 STATS.
  - [x] The timer owner: a 10 ms preemption tick that stops (core control)
    workers with more than one runnable process; timeouts of timed waits.
  - [x] Configurable time slice: default 2 ms, 100 µs..100 ms; kernel op 5 TUNE, proc op 30 SCHED, a `sched` program, settable from `rc` (spec 2.1 / 2.4).
  - [x] Self-paging: the resident part is in I-LS 0x4000..0x7FFF; units in
    `.far` are called via c12 and paged into I-LS 0x8000.. by core 0's own
    xmiss handler. Count the unit loads.
- [x] **Kernel: worker dispatcher**
  - [x] Run queue; context switch:
    - [x] drain transfers;
    - [x] save registers and CSRs;
    - [x] save c0..c7 into the save table (8 slots per process);
    - [x] save only the used D-LS (data extent + live stack) to the save
      area in the arena;
    - [x] reload code from the image.
  - [x] Count switches and KiB moved per process.
  - [x] Demultiplex every inbox arrival: a message-buffer base means a
    reply; anything else is a request for the core's server.
  - [x] Doorbells: wake a busy destination through core control.
  - [x] `svc` 1 WAIT_REPLY, 2 RECEIVE, 3 REPLY, 4 YIELD, 5 EXIT,
    6 NOTIFY_WAIT, with timeouts (-8 = timed out).
  - [x] No exclusive cores: `-n N` = N time-shared threads on N contiguous cores; user `ctake`/`cpoll`/`tany`-inbox trap and are emulated by the dispatcher from the process's gift queue; demux by arena ownership (spec 2.0/2.1/2.3). The ISA side is done (emu + RTL: user-mode inbox ops always trap).
  - [x] Demand paging of program code units still works (`units`).
- [x] **Servers** (user processes, each pinned to its own core)
  - [x] `proc` (pid 1):
    - [x] SPAWN (load via fs, then CREATE), WAIT, KILL, PS, INFO, SIGNAL,
      CATCH;
    - [x] LOOKUP / REGISTER;
    - [x] start dev, fs, tty, pipe, then `sh -l` (restart sh if it exits).
  - [x] `dev`: DEVS, GRANT_FB (framebuffer cap + controller ports cap),
    HALT; hands device caps to fs and tty. (Not yet: the framebuffer cap is
    given as is, not inside the caller's revocation domain, and dev does not
    check that the caller registered as "ws".)
  - [x] `fs`: OPEN (read / write / append), READ, WRITE, CLOSE, DIR,
    UNLINK, STAT, LOADIMG; reference-counted handles.
  - [x] `tty`: cooked/raw (CONMODE), SETFG, break port → SIGNAL of the
    foreground process.
  - [x] `pipe`: PIPE, READ, WRITE, CLOSE with EOF and broken-pipe rules.
  - [x] Interrupts: deliver to processes that CATCH (blocking call → -2);
    kill the others.
- [x] **Program interface**
  - [x] `os/lib/sys.s`: wrappers for every op in spec 2.4 (system, proc,
    dev, fs, tty, pipe, ws 40–46); handle routing to the owning server;
    the clock through c7.
  - [x] Startup capabilities: c0 arena, c1 proc, c2 fs, c3 tty, c4 pipe,
    c5 buffer, c7 timer.
- [x] **Programs**
  - [x] A basic `sh`:
    - [x] pipelines, `<` `>` `>>`, `&`, `-n N`, `run` prefix;
    - [x] builtins;
    - [x] Ctrl-C handling;
    - [x] rc, scripts, `-c`.
  - [x] New utilities: ls, rm, df, ps (shows switches and KiB moved), free,
    uptime, devs, hexdump, cores.
  - [x] Existing programs still work: cat seq grep wc upper spin as units
    and the examples (`clock`/`gfx` need bare-metal caps: exclude them from
    the disk or give them what they need as programs, and document which).
- [x] **Tests**
  - [x] `os/demo.txt` updated: pipelines, redirects, a background job +
    wait, ps, kill, a multi-core run, `as < hello.s > hi`, files.
  - [x] `tools/compare-boot.sh`:
    - [x] uses `-T virtual -g none`, loops over NCORES;
    - [x] compares console output (plus traces where deterministic), with a
      documented reason.
  - [x] `tools/test-break.sh` passes under 0.2 (Ctrl-C kills `spin`, the
    shell survives).
  - [x] Preemption test: two spinning processes on one core both progress;
    `ps` shows switches.
  - [x] `tools/test-as.sh` passes, including its StrataOS part.
  - [x] `make boot-demo` (emulator, 12 cores) runs end to end; `make test`
    is green.

## 5. Advanced shell `sh` (spec 2.7) — DONE (agent; plan in os/progs/PLAN-sh.md)

- [x] Line editing (raw console only while a line is typed; jobs run cooked):
  - [x] left/right, Home/End, Backspace/Delete;
  - [x] Ctrl-A/E/K/U/W, Ctrl-L, Ctrl-D, Ctrl-C (also Ctrl-B/F/P/N).
- [x] History (32 lines in the arena, up/down); `history` builtin.
- [x] Tab completion of commands (builtins + STX2 programs on disk) and file
  names; common prefix; a second Tab lists in columns and redraws.
- [x] Syntax: quotes, `$?`, `$$`, `$NAME` (`set` / `unset`), `\x`, `;`, `&&`,
  `||`, pipelines (4 stages), `<` `>` `>>`, `&` (anywhere in a list), `#`.
- [x] Jobs: `jobs`, `fg [%n]`, `wait [%n|pid]`, `kill %n|pid`. SETFG for
  foreground jobs; SIGNAL on Ctrl-C; "[1] done  cmd" before the next prompt.
- [x] Builtins: help, echo, set, unset, history, jobs, fg, wait, kill, sleep
  (decimal), time, clear, source (nests), exit, halt, run (+ true, false).
  Builtins in a pipeline or in the background run as `sh -c 'w' 'w'...`.
- [x] Prompt shows a non-zero status. `-l` runs rc; `-i` forces
  interactive (for `term`); `-c`; script files (64 KiB, in the arena).
- [x] Tests: `tools/test-sh.sh` (scripted session with escape sequences,
  expected output in `tools/test-sh.out`; also identical under -J -T real).
- [x] `make test` runs tools/test-sh.sh (after test-break.sh).

## 6. Window server and clients (spec 2.8) — TODO (after 4)

- [x] **`ws`**
  - [x] Registration and resources:
    - [x] REGISTER "ws";
    - [x] GRANT_FB;
    - [x] becomes the tty foreground, raw console;
    - [x] CATCH.
  - [x] Look: grid background, floating cut-corner tiles with luminous
    edges, focused tile amber with glow, HUD tags
    (`▸ TERM · pid 7 · core 3` + KiB moved). (os/ws/frame.s; demo: `make ws-demo`)
  - [x] Core lattice status strip: one cell per core in the colour of the
    process running there, pulses on context switches; clock, uptime,
    process count, switches per second. (os/ws/lattice.s, rendering;
    real data from proc CORES / PS / SCHED: os/ws/ws.s ds_*; the time slice is shown too)
  - [x] Tiling: 1 / 2 / 3 / 4 layouts; tiles slide on re-tile (VSYNC-paced);
    boot splash with layered STRATA bands. (os/ws/layout.s, splash.s)
  - [x] Keys:
    - [x] Alt+Enter new `term`;
    - [x] Alt+Q close the focused window;
    - [x] Alt+arrows and Alt+1..4 focus;
    - [x] Alt+P or Alt+Space command palette (`launch ›`, with completion);
    - [x] ESC Q quit;
    - [x] Ctrl-C → SIGNAL the focused process.
  - [x] Protocol 40–46: CREATE, DAMAGE, TEXT, FILL, EVENT, DESTROY, TITLE.
    (Deviation: capabilities are linear, so there is no shared surface
    capability: surfaces live in the server, clients lend a band of their
    arena with DAMAGE (sys_msga); see os/ws/ws.s. TEXT, FILL and TITLE are
    implemented but no client or test uses them yet.)
  - [x] Redraws only damaged areas; one PRESENT per batch; never
    busy-waits. (os/ws/damage.s; `make ws-check` compares with full
    redraws; the message loop sleeps in RECEIVE with a timeout)
  - [x] 8x16 font (an original public-domain 8x16 design instead, plus a 5x7
    HUD font: os/lib/font/gen_font.py).
- [x] **`term`**:
  - [x] runs `sh -i` over two pipes;
  - [x] interprets the terminal subset (spec 2.6); (os/ws/term.s: grid,
    parser, rendering into a surface)
  - [x] forwards keys and Ctrl-C.
- [x] **`wmandel`**: renders into its surface, damages rows, re-renders on
  resize, quits on close / `q`.
- [x] **`wclock`**: a clock window updating every second.
- [x] **`os/lib/gfx.s`**: pixel, rectangle, line and text helpers into a
  surface. (display lists rendered in D-LS strips; see os/ws/README.md)
- [x] **Tests:** headless UI test (`-g none -F`) that starts `ws` with a
  `term` and a `wmandel`; check the frame (look at the PNG).
  (tools/test-ws.sh, in `make test`; screenshots site/img/ws-real-*.png)

## F. Modern Forth (`lang/forth/`) — IN PROGRESS (agent)

- [x] `forth.s`: an asm kernel (every line commented) and `core.fs`, the
  bootstrap of the rest of the language in Forth.
- [x] Native code generation, installed into the I-LS with `tgetx` (an
  explicit "JIT install"); `see`.
- [x] Words for tiers and capabilities: transfers with tags, capability
  register ops, a far `@`/`!` through a software cache (ltag/linst).
- [x] Multicore words (run an xt on another core, exchange buffers); a
  demo.
- [x] Demos: tiers/caps, multicore, framebuffer graphics.
- [x] Bare-metal backend; `make forth`, `forth-rtl`, `test-forth`
  (emulator and RTL outputs compared).
- [ ] StrataOS backend:
  - [ ] needs from step 4: `svc` 7 SET_MIRROR and `.far` placed in the arena (spec 2.2); the I-LS budget means `see`/disasm/`dump`/`words` move to an on-demand `tools.fs` (see lang/forth/PLAN-forth.md)
  - [ ] key/emit via sys.s;
  - [ ] `include FILE` via fs;
  - [ ] multicore with `-n N` (time-shared threads; ctake is emulated);
  - [ ] `build/prog/forth` + core.fs + demos on the disk. Do this after
    step 4 lands.
- [x] `lang/forth/README.md` (design, dialect, Strata words, session).
- [ ] Wire `test-forth` into `make test`.

## J. Emulator JIT (arm64 + x86-64) — DONE

- [x] Block translator in `emu/jit/`; translations invalidated on `tgetx`
  and loads; precise traps via side exits; exact instret.
- [x] arm64 backend (MAP_JIT, write-protect toggling, icache flush) and
  x86-64 backend; compile-time selection; interpreter fallback.
- [x] Flags `-J` / `-j`; `-t` forces the interpreter; trace tests keep the
  interpreter (default: JIT, except with `-t` or `-T virtual`).
- [x] `tools/test-jit.sh` (in `make test`, `make test-jit`): JIT and
  interpreter give identical output, halt codes and frames on every example
  plus the Forth tests; `emu/jit/fuzz.py` differential fuzzer.
- [x] `make bench` (`tools/bench-jit.sh`): arm64 gfx 1280x800 24x, Forth gfx
  demo 120x; x86-64 under Rosetta: Forth gfx demo 24x.
- [ ] OS bug found by the JIT's coarser interleaving: `os/kernel.s`
  `wpl_bounce` calls `w_ring`, which reuses c8 (crs8 T_CCTL / cclear c8),
  then `cgive c8, s1` faults capinv (demo, after `kill %1`). Also
  reproduces with quanta and no translation. For the OS owner.

## W. WebAssembly emulator on the site — DONE

Owns: web/ (wasm glue), site/play/, the `wasm` / `web-assets` Makefile
rules, the web part of `.github/workflows/pages.yml`. Detailed plan:
`web/PLAN-web.md`.

- [x] `make wasm` (Emscripten, interpreter only, no JIT) builds `build/web/`.
- [x] Never blocks the browser: `emscripten_set_main_loop`, ~10 ms of rounds
  per frame; console input from the page.
- [x] Framebuffer on a `<canvas>` (live scanout, pixelated scaling).
- [x] In-page terminal (xterm.js, pinned) with the desktop keyboard mapping.
- [x] Presets (StrataOS, gfx, Forth + demos, hello, mandel), Reset, Ctrl-C,
  status line (MIPS, cores, virtual time).
- [x] `site/play/index.html` and a "Try it in your browser" CTA on the site.
- [x] CI: emsdk, `make web-assets wasm`, copied into the site under play/.
- [ ] Check the first Pages deploy (CI pins emsdk 3.1.74; built locally with
  emcc 7.0.0) and the live page.
- [x] Verified in a browser; native build and examples unaffected.

## X. Fast browser emulator (worker, predecode, wasm JIT) — DONE

Owns: web/web.c, site/play/{worker.js,play.js}, emu/jit/jit_wasm.c,
tools/wasm-run.js, tools/test-wasm.sh, the fast loop and `machine_round()`
in emu/emu.c, the wasm rules of the Makefile. Detailed plan and numbers:
`web/PLAN-fast.md`.

- [x] **Worker.** The emulator runs in a dedicated Web Worker
  (`site/play/worker.js`), continuously; the page only paints and sends
  keys. postMessage with transferables (console batches, dirty framebuffer
  rows as RGBA, status); no SharedArrayBuffer. `web_run(ms)` in web/web.c
  replaces the emscripten main loop; an idle machine sleeps (setTimeout)
  until its next timer/VSYNC deadline or input. emu.c and web.c share one
  round function (`machine_round`).
- [x] **Faster interpreter (native too).** Predecoded I-LS cache per core
  and `run_fast()` for the plain integer subset; invalidated on tgetx with
  the JIT. The reference mode (`-j`, `-T virtual`) keeps the exact
  one-instruction interleaving (cores run plain bursts ahead and sit the
  rounds out: `lead[]`, `user_burst`); `-t` uses step() only. A hazard
  range (`hazard_set`) lets the fast paths run while device reads are
  pending. Byte-identical output and instret against a step()-only build
  (`cc -DNO_FAST`) on the examples, Forth, the ws demo and the OS demo boot.
- [x] **WebAssembly JIT** (`emu/jit/jit_wasm.c`, `jit_backend()` "wasm"):
  hot regions of basic blocks become one wasm function each (registers in
  locals, in-function loops and calls/returns, exact instret, quantum
  check, side exits to step()), compiled synchronously and installed in
  the module's function table; tail calls between regions when the engine
  has them; flushed on tgetx. Page: JIT checkbox (default on, `?jit=0`),
  MIPS and mode in the status line.
- [x] `make test-wasm` (tools/test-wasm.sh, node): wasm interpreter and wasm
  JIT against the native interpreter on the examples, Forth, the ws demo,
  plus emu/jit/fuzz.py on the wasm build; in `make test` when node and emcc
  exist; in the Pages CI before the site is assembled.
- [x] Measured (M-series Mac): native `-j` gfx 0.28 s -> 0.02-0.04 s, Forth
  gfx 4.9 s -> 0.4 s; in the browser the Forth gfx demo ~20 s -> 0.43 s
  (interpreter) / 0.07 s (JIT, ~5000 MIPS); ws demo at a steady 60 fps.
- [ ] Not verified: the Pages CI run itself (emsdk 3.1.74; built and tested
  locally with emcc 7.0.0, no newer features used on purpose).
- [ ] Later: hazard-range checks in the native backends (a core with a
  pending device read runs the fast loop there, not translated code).

## C. Source browser on the site — DONE

Owns: site/code/, tools/web-code.py, the `web-code` Makefile rule, the
source-browser step of `.github/workflows/pages.yml`.

- [x] `tools/web-code.py`: copies every `.s`/`.fs` into `build/web-code/src/`
  and writes `manifest.json` (groups by glob, lines, header description,
  run links; mnemonic/CSR/register lists parsed from asm/sasm.c, Strata
  Forth words from lang/forth/README.md).
- [x] `site/code/` (index.html, code.css, code.js): tree, filter, deep links
  (`#path:42`, `#path:42-50`), keyboard, mobile drawer, assembly and Forth
  highlighters.
- [x] `make web-code`, `web-site` copies it to `code/`; CI publishes it.
- [x] "Source" links on the site and the play page; `?run=forth&demo=NAME`
  in play.js.
- [x] Verified in a browser (`make web-site`, served build/web-site): tree
  and filter, as.s / forth.s / alu.s (6075 lines) colour in ~10 ms,
  deep links and ranges, keyboard, mobile drawer, `?run=forth&demo=`
  queues the demo.
- [ ] Check it on the first Pages deploy.

## L. Live framebuffer scanout — DONE

- [x] The window opens on the first framebuffer write and repaints from
  memory at ~30–60 Hz host time; PRESENT = frame complete (`-F`
  captures it); emu + RTL harness; spec 1.2 / 1.4 updated.

## T. Conformance suite (CPU + devices) — DONE (F7/F8 docs open)

Runs on the emulator interpreter, emulator + JIT and the RTL; `make
conformance` (called by `make test`).

- [x] Per-instruction self-checking tests with a signature region compared
  across machines (ALU edge cases, shifts 0/63, div/rem corners, sign
  extension, immediates, branches, jal/jalr).
- [x] Traps: every cause, precise epc/tval, supervisor/user routing, `svc`,
  the user-mode inbox rule, `eret`, halt in user mode.
- [x] Capabilities: linearity, overwrite traps, split / join / restrict /
  share / atomic, revocation domains (cdom / crevoke / cundom),
  endpoints, the save table.
- [x] Transfers: hazards (load vs get, store vs get/put, fetch vs tgetx),
  tag reuse, faults, device byte transfers, tamo.
- [x] Devices: timer latch / deadline / WAIT, VSYNC, PRESENT + frames,
  console in / break / release, block device commands and errors, the
  platform table.
- [x] Multicore: gifts, per-sender queues, cpoll / ctake-from, tany,
  core-control stop.
- [x] Differential fuzzer: random valid instruction streams; compare
  registers + D-LS across interpreter / JIT / RTL.
- `conformance/`: 21 tests (`tests/*.s`, three generated by `gen/*.py`),
  `run.sh` (table test x machine, `xfail.txt`), `fuzz/fuzz.py`
  (`make fuzz SEEDS=N`). Presented frames stay with `tools/test-fb.sh`.
  Findings (F1 RTL cgive tval and F2 emu PTRAP fixed; F7/F8 docs open):
  `conformance/FINDINGS.md`.
- [x] ISA decisions F3–F6 applied (emu, RTL, tests, doc/strataos-0.2.md 1.2
  and 1.5; `xfail.txt` empty): halt drains device reads (emu); one release
  completes every break read (RTL); a transfer overlapping an in-flight
  device read waits at issue / traps pend with PTRAP (both); capabilities
  are 8-byte aligned, csplit traps capop otherwise (both). The manual's
  share is listed in FINDINGS F8.
- [x] **OS (owner: OS agent): a core must not halt with a break read in
  flight.** FIXED (os/PLAN-os.md "Halt"): tty does not re-arm after a
  release; the kernel waits for every dispatcher, then writes the release
  port and DEADLINE 0; `make boot-demo` exits 0. Was: tty (os/servers/tty.s) keeps its break read (tag 1) always
  armed and re-arms after a release; on `halt` the tty's core reaches
  `w_halt` (os/kernel.s) and now waits forever: the emulator reports
  "deadlock" (exit 1) after "StrataOS: all cores halted", and the RTL runs
  to its -m limit (compare-boot is slow; the greps still pass).

## 7. Integration — TODO

- [ ] `make lint` clean (both configurations); `make test` green at
  NCORES=8; `tools/test-as.sh` green.
- [ ] Self-hosted `as` assembles the new kernel and programs (test-as covers
  os/kernel.s).
- [ ] Manual (subagent; doc/ only; no review mentions):
  - [ ] timer, framebuffer and keyboard;
  - [ ] `svc` and the inbox rule;
  - [ ] 64 MiB memory map;
  - [ ] StrataOS 0.2 chapter: microkernel, servers, preemption with
    explicit switch cost, messages and demux, the window server and its
    protocol;
  - [ ] Forth appendix or chapter;
  - [ ] toolchain flags.
- [ ] README: 8 cores default / 12 for boot; the flags `-T -g -F -z -H -r`;
  `show-NAME`; StrataOS 0.2 overview; ws; Forth; link to the site and the
  PDF.
- [x] `fpga/README.md`:
  - [x] ECP5: the D-LS (`strata_ram`, written through both ports) was not inferred as block RAM, because ECP5 EBR does not define a cross-port read-during-write and Yosys kept the simulated "old data" behaviour by building it from flip-flops (2 × 524k). Fixed with `(* no_rw_check *)` on the array; the hazard stalls make the collision data unobservable (checked with a simulator build that poisons collided bytes: examples, conformance and the OS boot unchanged). ILS, T2, T3 stand-in and disk were already block RAM;
  - [x] numbers for both families, 1 and 2 cores (xc7: 47.4k / 94.7k LUTs; ecp5: 73.8k / 142.5k LUT4 sites), per-module breakdown and the top consumers; `fpga/synth.sh` now prints a summary and the latch / FF-memory checks;
  - [x] boards: 1 core fits the Arty A7-100T (and, on paper, an ECP5-85F); 2 cores need the XC7A200T; StrataOS needs 6 cores, which no board named here holds;
  - [x] note that there is no video output on FPGA yet.
- [ ] Update `doc/strataos-0.2.md` wherever the implementation deviated.
- [x] Manual updated for the release (179 pages, builds clean): svc, inbox rule, capability alignment, device-read rules, timer, framebuffer, 64 MiB map, a rewritten StrataOS chapter (op tables 18.x), a Forth chapter.
- [ ] Reconcile after the OS and ws agents finish (found by the manual pass):
  - [ ] the manual's op tables 18.x vs the final kernel/servers (kernel op 10 FBLEND, dev 30/31, proc 39 WHOIS, fs 32–35, ws 46 TITLE);
  - [ ] the window-surface model: the spec says ws allocates surfaces in its own revocation domain, but `cdom` is privileged, so clients lend drawing bands instead. Fix spec 2.8 and the manual to what ws really does;
  - [x] the FPGA numbers in `doc/manual/ch-impl.tex` now match `fpga/README.md` (47k LUTs per core; rerun after the pointer device lands if its logic matters);
  - [ ] `lang/forth/README.md` still says "StrataOS 0.2" and "exclusive process";
  - [ ] `os/lib/sys.s` header: c0 is 832 KiB for one thread, not 768;
  - [ ] wire `tools/test-sh.sh` into `make test`;
  - [ ] emulator: enforce one break read per core, and check `ltag`/`linst` against pending device reads (FINDINGS F2 remainder), or document it.
- [x] README rewritten for the release; `ROADMAP.md` written; the spec's section 2 and 3 now describe what was built; manual op tables updated (docs pass).
- [ ] Coordinator TODOs left by the docs pass: README ~line 258 (confirm `make boot` + `ws`, delete the comment), README "License: TBD" (ask the user), spec end of 2.8 (ws keys and limits vs final sources), spec section 3 (the ws test), manual ch-os.tex prose "The client protocol" (surface model: clients lend bands), `lang/forth/README.md` StrataOS section, `os/ws/README.md` (still "renderers"), Makefile help header (ws-demo, forth, web-site, web-code), fpga/README `@ECP5@`.
- [ ] Versioning: the first release is **StrataOS 0.1** (nothing has been released yet). Rename `doc/strataos-0.2.md` → `doc/strataos.md`, update every reference (PLAN.md, agent plans, Makefile, scripts, manual, site, README), and sweep user-visible "0.2" (banners, help, ws status bar, `uname`/INFO, site) to 0.1.

## 8. Publish — TODO

- [ ] Every location in "Agent working locations" is cleaned up and its row
  removed; no stray files are left in the repo (`git status --ignored`
  reviewed).
- [ ] `git status` has no build output (`build/`, `fpga/build/`), no PDF,
  no LaTeX artifacts, no review files.
- [ ] Commit with the trailer
  `Co-Authored-By: Claude <noreply@anthropic.com>`.
- [ ] `gh repo create yrashk/strata --public --source . --push`.
- [ ] Tell the user the local directory is still named IStrata.

## 9. GitHub Pages — TODO

- [ ] Screenshots taken with `-F` and converted to PNG with `sips`:
  - [ ] the ws desktop with term + wmandel + wclock;
  - [ ] the boot splash;
  - [ ] the command palette;
  - [ ] the gfx Mandelbrot.
- [x] `.github/workflows/pages.yml` written (tectonic → `make manual` → site + PDF → deploy-pages).
- [x] `site/index.html` + `site/style.css` (ws look: grid, cyan/amber, cut corners, layered bands); `site/img/` has gfx-mandelbrot.png and forth-mandelbrot.png. Preview with `python3 -m http.server --directory site`.
- [x] Window-server section on the site (ws-desktop / palette / splash shots) and a "Window server demo" preset on the play page (`play/?run=ws`, runs build/ws/wsdemo.stx; built by `web-assets`). Not yet checked in a browser.
- [x] Site and README now use the real-OS screenshots (`site/img/ws-real-*.png`); the StrataOS preset on the play page mentions `ws`.
- [x] Site screenshots are taken through the window server: once the real `ws` runs on StrataOS, replace the demo shots with `site/img/ws-real-*.png` and make the play page's StrataOS preset mention `ws`.
- [ ] Add the UI screenshots (ws desktop, splash, palette) and replace the StrataOS terminal sample with a real session once 0.2 runs.
- [ ] `site/`: one page introducing Strata (the idea: memory as explicit
  I/O, capabilities, no interrupts), StrataOS 0.2, the UI, Forth, with
  screenshots and links to the PDF and the repo.
- [ ] `.github/workflows/pages.yml`:
  - [ ] install tectonic;
  - [ ] `make manual`;
  - [ ] copy the PDF + site into the artifact;
  - [ ] deploy to Pages.
- [ ] Enable Pages (source: GitHub Actions); check that
  https://yrashk.github.io/strata/ and the PDF link work.

---

## S. Stretch goals (after publishing, step 8)

### S1. Forth ahead-of-time compiler

The Forth JIT already emits native Strata code into a far-memory mirror of
the I-LS; AOT means writing that out as a program. Needs the Forth StrataOS
backend (section F) first.
- [ ] Turnkey images: `' main save" name"` writes an `.stx` with the code
  mirror (kernel + compiled words, same I-LS addresses, so no relocation),
  the data space (dictionary, variables, strings) and an entry stub calling
  `main`. The result runs as an ordinary StrataOS program. The file is
  written through fs OPEN/WRITE.
- [ ] Batch mode from the shell: `forth -c prog.fs -o prog`.
- [ ] Tree-shaking: record calls and absolute references while emitting (a
  relocation and dependency table), save only the words reachable from
  `main` plus the primitives they use, packed and patched.
- [ ] Large programs: put rarely used words in the `.far` section as code
  units (xcall / xmiss paging) so images fit the 32 KiB program I-LS.
- [ ] Tests: AOT-compiled programs give the same output as running the same
  source in the REPL; image sizes recorded.

### S2. More threads per core (research, then suggest)

Today a worker core holds at most 3 threads: each time-shared thread's
capability registers c0..c7 go into the core's 64-entry capability save
table, and the dispatcher keeps the rest. Research the options, measure, and
write up a recommendation (doc note + PLAN items) before changing anything.
Ideas to evaluate:
- [ ] **Park capabilities off-core.** A switched-out thread's capabilities
  are given to a per-core (or system-core) "keeper" through the inbox / a
  server and taken back on switch-in. Unbounded, but costs messages per
  switch; measure.
- [ ] **Fewer live capabilities per thread.** Let the dispatcher save only
  the valid registers (cvalid), and encourage programs to keep spares in
  their own save slots or joined into c0. Most threads hold 3–5.
- [ ] **A bigger or per-thread save table (ISA/RTL).** Grow the table
  (LUT-RAM cost), or bank it per hardware context. Weigh the FPGA cost
  (the 2-core xc7 build is already ~90k LUTs).
- [ ] **Capabilities in memory, sealed (ISA).** A `cseal`/`cunseal` pair
  that stores a capability into a kernel-only T2/T3 region (a tagged-memory
  page or a kernel table indexed by handle) so the kernel can spill any
  number of them. The biggest change; the most general.
- [ ] **Threads that don't hold capabilities while blocked.** A thread blocked
  in `svc` has lent its buffer away; formalize "blocked threads hold at most
  N capabilities", and spill the rest into the process's own capability
  table kept by `proc`.
- [ ] **Two-level scheduling.** Many user-level threads (green threads)
  inside one process share its 8 capability registers. A runtime in
  `os/lib` switches stacks without the kernel. Pairs well with Forth
  multitasking.
- [ ] Prototype the most promising one or two; report the switch cost (KiB
  moved, cycles) and how many threads per core each one gives.

## File ownership while agents run in parallel

- **Step 4 (OS):** os/, firmware/, tools/mkdisk.c,
  tools/compare-boot.sh, tools/test-break.sh, the StrataOS part of
  tools/test-as.sh, and the OS rules of the Makefile.
- **Forth:** lang/forth/ only; small local Makefile additions (re-read the
  Makefile before editing).
- **Machine (done; edit only for bugs):** emu/, rtl/, sim/, common/,
  asm/, examples/.
- **Steps 5 and 6:** new files in os/progs/ and os/lib/gfx.s. They need the
  sys.s API from step 4.

## Agent working locations (scratch, temp and build dirs)

Every agent also keeps its own detailed checkbox plan in the folder it works
in (`os/PLAN-os.md`, `lang/forth/PLAN-forth.md`, and the same for later
agents). It is fine-grained enough to resume that agent's work. When the
work is integrated, its useful content is folded into the docs and the file
is deleted.

Every agent records here every place it writes outside its owned source
files: scratch directories, temp files, extra build directories, logs. Each
entry is removed once its work is integrated, and the location is cleaned
up before step 8.

| Agent / step | Location | Purpose | Clean up? |
|---|---|---|---|
| main session | `/private/tmp/claude-501/-Users-yrashk--claude-spares-spare-bGJEvr/e68fc47f-3893-447c-8c69-38177da41a1b/scratchpad/` | patch scripts, test frames, traces | delete before publish |
| main session | `build/`, `build-as/`, `fpga/build/` | build output (gitignored) | `make clean`, `rm -rf build-as fpga/build` before publish |
| step 4 (OS) | (scratch files removed, `build-fb/` deleted) | — | — |
| step 4 (OS) | `os/PLAN-os.md` | the OS agent's detailed working plan | fold into docs, then delete |
| step 4 (OS) | `build/` (kernel.stx, bootrom.stx, disk*.img, prog/, src/), `build-as/` (test-as) | build output (gitignored) | `make clean` |
| WS design | `build/ws/`, `build/ws-shots/` (demo images, screenshots), `os/ws/PLAN-ws.md` | window-server rendering; kernel integration next | `make clean`; fold the plan into os/ws/README.md, then delete |
| F (Forth) | `build/forth/`, `build/forth.stx`, `build/forth-test/` (later `build/prog/forth`) | generated core.fs embedding, image, test outputs (gitignored build/) | `make clean` |
| F (Forth, OS backend) | `/private/tmp/claude-501/-Users-yrashk--claude-spares-spare-bGJEvr/e68fc47f-3893-447c-8c69-38177da41a1b/scratchpad/` (forth.s.orig, core.fs.orig, size probes, OS test inputs), `build/forth-os/` (generated embedding), `build/forth-test/` | StrataOS backend work | delete when integrated |
| F (Forth) | `lang/forth/PLAN-forth.md` | detailed working plan of the Forth agent | fold into lang/forth/README.md, then delete |
| JIT | `emu/jit/PLAN-jit.md` | the JIT agent's detailed working plan | fold into docs, then delete |
| Shell (step 5) | `os/progs/PLAN-sh.md` (scratch dir deleted) | the shell agent's working plan | fold into docs, then delete |
| X (fast browser emulator) | `web/PLAN-fast.md` (scratch `build-fast/` removed) | the detailed working plan of section X | fold into docs, then delete |

## Agent history (for takeovers)

Subagents now run on Fable (`model: "fable"`). A new agent taking over
reads its predecessor's plan file and, for detail, mines its transcript
(JSONL; query with python/jq, never read whole). The Write/Edit inputs in a
transcript contain full file contents, so lost work can be recovered.
Transcripts are in
`~/.claude/projects/-Users-yrashk-Projects-IStrata/e68fc47f-3893-447c-8c69-38177da41a1b/subagents/agent-<id>.jsonl`:

| Work | Agent id |
|---|---|
| Microkernel, servers (stopped mid GRANT_FB / halt fix) | afb3f477ed53a3af3 |
| Advanced shell (9/10 done) | a85c3d4b2b55a67d9 |
| Window-server rendering (done) | abfc278a2cf1712a8 |
| Window-server integration (stopped; ws.s etc. not on disk) | a509e01ab51c3c09e |
| Manual for release (stopped early) | a58a8fd7c1aedf271 |
| Devices / machine | a6a713e22c0a3f55a |
| Forth | a30cdc8684c814d9a |
| JIT | a0c7b136268744fa9 |
| Conformance | a99fbd829db2cf7aa |
| ISA fixes F3–F6 | a26aa826ab9a27215 |
| WebAssembly play page | a8e955078f3536719 |
| Fast browser emulator (section X) | (see web/PLAN-fast.md) |
| Source browser | a0766fbc2be127933 |

## Resuming

1. **Check the build:** run `make && make test`. If the OS build fails,
   step 4 was interrupted: read spec section 2 and os/kernel.s's header,
   then finish to spec; don't restart from scratch.
2. **Look at the machine:** `make show-gfx` (1280x800 window); `make boot`
   (StrataOS on the emulator).
3. **Steps 5, 6 and the OS part of F** can run in parallel once
   `make boot-demo` works and sys.s has every op of spec 2.4.
4. **Order of the rest:** step 7, then 8, then 9. Keep this file's boxes
   current.

## Known limitations / notes

- The RTL is ~47k LUTs per core on Xilinx 7-series (yosys): one core fits
  an Arty A7-100T, two need an XC7A200T (Nexys Video), and the six that
  StrataOS needs fit none of the boards considered. The overlay map is 30%
  of a core (fpga/README.md, "Where the LUTs go").
- `strata_ram` carries `(* no_rw_check *)`: FPGA block RAM does not define
  a read of a byte written in the same cycle through the other port, and
  the hazard stalls are what make that unobservable. Keep it that way when
  changing the TU or the core's Local Store accesses.
- The emulator-vs-RTL OS boot comparison can't stay exact with
  timer-driven preemption: emulator rounds and RTL cycles are different
  time bases.
- sv2v/yosys: never put a `for` loop inside an `if` in always_comb. Put the
  condition inside the loop.
- `make test` at NCORES=8 takes several minutes.
