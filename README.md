# Strata

A prototype 64-bit instruction set architecture in which **memory is
explicit I/O** and **every storage tier is visible to software** — with a
Verilog implementation, a reference emulator with a JIT, a microkernel
operating system written in its assembly language, a native-code Forth, and
a conformance suite that holds them all to the same behaviour.

- **[Project site](https://yrashk.github.io/strata/)**
- **[Run it in your browser](https://yrashk.github.io/strata/play/)**: the
  emulator as WebAssembly; boot StrataOS, draw into the framebuffer, type
  Forth
- **[Architecture Reference Manual](https://yrashk.github.io/strata/Strata-Architecture-Reference-Manual.pdf)** (PDF)
- **[Source browser](https://yrashk.github.io/strata/code/)**: every
  assembly and Forth source, syntax-coloured

![The StrataOS window server: tiled terminals, a Mandelbrot set and a clock under the core lattice](site/img/ws-real-focus.png)

## The ideas

- **Local Stores, not caches.** Loads and stores reach only registers and a
  per-core 64 KiB data **Local Store**; instructions come only from a 64 KiB
  instruction Local Store. L1 is an architectural scratchpad, and software
  decides what lives there.
- **Everything else is a transfer.** The cluster store, system memory and
  devices are reached through a per-core **Transfer Unit** (`tget`, `tput`,
  `tgetx`, with completion tags) or **far atomics** (`tamo`). There are no
  hardware caches; `ltag` / `linst` help software build its own.
- **Transfers are as-if-synchronous.** Each takes effect at its issue
  point, and the hardware stalls any access to a Local Store range that is
  still in flight. Overlapping transfers with computation is purely a
  performance choice.
- **Capabilities name everything.** Far memory is reachable only through
  capabilities. Writable capabilities are linear: they can be split,
  joined, given to another core and taken back, never copied. A data race
  between cores cannot be written down.
- **No interrupts.** A device "interrupts" by completing a transfer;
  `tany` waits for any of a set of transfers, or for a capability to arrive
  in the inbox. Ctrl-C is a console read that completes when the key is
  pressed; the timer is a read that completes at a deadline. The only
  forced preemption is stopping a core through a core-control capability.
- **Revocation by address** (`cdom`, `crevoke`, `cundom`) lets a supervisor
  take back every capability derived from a region at once: memory is
  revoked in 256 KiB granules, each with a generation, so there is no fixed
  number of revocable regions; **endpoints**
  (`csend`, `crecv`) carry capabilities between supervisor and user code.
- **Code is paged explicitly.** `xmap` / `xcall` / `xret` run code units
  out of system memory, and a miss traps so that software loads the unit.

## Repository layout

| Path | What |
|---|---|
| `rtl/` | The SystemVerilog implementation: decoder, ALU, divider, Transfer Unit, far memory and arbiter, devices, the multi-cycle core, the multi-core top |
| `sim/` | The Verilator harness: runs an `.stx` image on the RTL (`strata-rtl`) |
| `emu/` | `emu.c`, the C architectural emulator and reference semantics (`strata-emu`); `emu/jit/`, its JIT for arm64 and x86-64 hosts |
| `asm/` | `sasm`, the two-pass assembler, and the shared encoding header `isa.h` |
| `common/` | The image loader, the platform description and the display / keyboard code shared by both simulators |
| `examples/` | Example programs for the bare machine, every line commented |
| `firmware/` | The boot ROM (`bootrom.s`) and the firmware interface library (`fw.s`) |
| `os/` | StrataOS 0.1: `kernel.s`, the resident kernel |
| `os/kunits/` | The rest of the kernel: code units the kernel pages into its own instruction store on demand |
| `os/servers/` | The servers, ordinary user processes: `proc`, `dev`, `fs`, `tty`, `pipe` |
| `os/lib/` | `sys.s` (the program library), `srv.s` (the server library), `gfx.s` (drawing), `wsclient.s` (the window server's protocol), the fonts |
| `os/progs/` | The shell `sh`, the utilities, the self-hosted assembler `as`, the window server's clients |
| `os/ws/` | The window server `ws`: main loop, protocol, renderers, and a bare-metal demo of them |
| `os/files/`, `os/demo.txt` | Files put on the disk (`motd`, `rc`); a scripted demo session |
| `lang/forth/` | Strata Forth: a kernel in assembly, the language in Forth, demos and tests |
| `conformance/` | The architectural conformance suite and a three-way differential fuzzer |
| `tools/` | Test scripts (`compare.sh`, `compare-boot.sh`, `test-*.sh`), `mkdisk` (bootable disks), `mkhex` (FPGA memory images), `bench-jit.sh`, `web-code.py` |
| `fpga/` | Synthesis script, LiteDRAM adapter, a board top, pin constraints |
| `web/` | The WebAssembly build of the emulator for the site's play page |
| `site/` | The project site: the landing page, `play/` (the in-browser emulator) and `code/` (the source browser) |
| `doc/` | The manual's LaTeX sources (`doc/manual/`), the StrataOS design specification (`doc/strataos.md`), schematics |
| `.github/workflows/` | CI: builds the manual, the WebAssembly emulator and the site, and publishes them |

## Building

| To build | You need |
|---|---|
| the assembler and the emulator | a C compiler (C11) |
| the RTL simulator | [Verilator](https://verilator.org) 5 (`brew install verilator`) |
| the framebuffer window | SDL2, found through `pkg-config` (optional: without it the simulators build headless and `-F` still writes frames) |
| the in-browser emulator and site (`make wasm`, `make web-site`) | Emscripten (`emcc`), node, python3 |
| the manual (`make manual`) | [tectonic](https://tectonic-typesetting.github.io/) |
| the fuzzers (`make fuzz`) | python3 |

## Quick start

```bash
make                # build/sasm, build/strata-emu, build/strata-rtl
make test           # everything below, compared across the machines (several minutes)
make show-gfx       # eight cores draw a Mandelbrot set into the framebuffer window
make boot           # boot StrataOS on the emulator (12 cores), on the real network (NAT)
make boot-ws        # the same, with the window server started at boot
make forth          # a Forth prompt on the bare machine
make ws-demo        # the window server's renderers against a simulated system
make conformance    # the conformance suite on the interpreter, the JIT and the RTL
make bench          # interpreter against JIT, wall time
make web-site       # build/web-site/: the site with the in-browser emulator
```

- `make` builds for 8 cores (`make NCORES=12` for more; the RTL's core
  count is fixed at build time, the emulator's is its `-c` flag, up to 15).
- `make test` runs every example on the emulator and the RTL and compares
  them **instruction by instruction**; boots StrataOS on both with a
  scripted session and compares the console output; stops a runaway program
  with Ctrl-C on both; runs a scripted interactive shell session, a
  preemption test, the session under the JIT, a framebuffer frame
  comparison, the JIT against the interpreter, and the conformance suite.
- `make run` / `make run-emu` show every example's output; `make run-NAME`
  runs one example on the RTL; `make show-NAME` (`show-rtl-NAME`) runs one
  and keeps its window open.
- `make boot` puts the machine on the network through the emulator's
  user-mode NAT and forwards host ports to it (`BOOT_NET`, default
  `-N nat,fwd=8080:80,fwd=8000:8000`; `make boot-net` is the same): type
  `httpd &` in the guest and open http://localhost:8080/ (the Forth
  `httpd.fs` on :8000). `ping example.com`, `host github.com`, `nc -H
  example.com 80 < request` reach the Internet. A busy host port is
  reported and skipped; `make boot BOOT_NET="-N peer"` stays offline.
- `make boot-demo` runs the scripted session (`os/demo.txt`);
  `make boot-rtl` and `make boot-rtl-demo` boot the Verilog simulator
  (slower).
- `make forth-demo-NAME` (`tiers`, `multicore`, `gfx`), `make test-forth`,
  `make test-jit`, `make fuzz SEEDS=N`, `make lint`, `make manual`.
- Preview the site: `python3 -m http.server --directory build/web-site`.

To assemble and run a program of your own:

```bash
build/sasm -o prog.stx prog.s && build/strata-emu -c 8 prog.stx
```

`sasm -l` prints a listing, `-T ADDR` sets the code origin and `-I DIR`
adds an include directory.

### Emulator and simulator flags

`build/strata-emu [flags] image.stx` and `build/strata-rtl [flags] image.stx`
take the same flags, except where noted.

| Flag | Meaning |
|---|---|
| `-c N` | cores, 1..15 (emulator only; default 4, the Makefile passes 8, and 12 for `make boot`) |
| `-d FILE` | block device image |
| `-i FILE` | console input from a file instead of the terminal |
| `-P FILE` | scripted pointer (mouse) input: `WHEN move X Y`, `down B`, `up B`, `wheel DY [DX]`, `enter`, `leave`; WHEN is a step (RTL: cycle) count, or `kN` after N console bytes |
| `-t FILE` | write an instruction trace |
| `-m N` | stop after N steps (emulator) or cycles (RTL) |
| `-b N` | press Ctrl-C after N steps / cycles (Ctrl-C at the terminal or in the window does the same) |
| `-T real\|virtual` | the timer: host microseconds (default), or machine time (deterministic; the tests use it) |
| `-r WxH` | framebuffer size, default 1280x800 (320x200 to 2560x1600, width a multiple of 8) |
| `-g none` | never open a window |
| `-F FILE` | at exit, write the last presented frame as a binary PPM |
| `-z N` | window scale |
| `-H` | keep the window open after every core has halted |
| `-J` / `-j` | force the JIT / the interpreter (emulator only) |
| `-N MODE` | the network interface's far end: `none` (default), `loop`, `peer[,nodns]` (an offline test host with DNS names `*.test`), `nat[,fwd=HOSTPORT:GUESTPORT]...` (the real network: guest 10.0.2.15, gateway/host 10.0.2.2, DNS 10.0.2.3), `udp:LPORT:HOST:RPORT` (a link to another simulator) |

A window opens the first time a program writes into the framebuffer. While
it has focus, keys go to the console input as a terminal would send them
(Alt sends an ESC prefix; Ctrl-C is the break key).

## Examples

| Example | Shows |
|---|---|
| `hello` | Local Stores, output as a transfer, a token passed down a chain of cores |
| `stream_sum` | Streaming far data; plain against double-buffered |
| `swcache` | A software-managed set-associative cache with `ltag` / `linst` |
| `overlay` | Code in system memory, loaded on demand through `xcall` misses |
| `faults` | Precise transfer faults and the capability rules |
| `pipeline` | A two-core zero-copy producer and consumer, passing buffer ownership |
| `parsum` | A parallel reduction on all cores: `csplit` the array, far atomics, `cjoin` it back |
| `mandel` | Every core renders a band of one frame it exclusively owns; the bands are collected in order |
| `race` | The lost update, use-after-give and stale-read races, all impossible |
| `clock` | The timer: finding a device in the platform table, and waiting with `tany` for a deadline or a capability from another core, whichever comes first |
| `gfx` | A colour Mandelbrot set in the framebuffer: each core owns one band through a capability; the frame is byte-identical on the emulator and the RTL |

All of them but `clock` and `gfx` (which need the device root) are also on
the StrataOS disk and run there unchanged as programs: `-n 3 mandel` runs
it as three threads on three cores.

Output lines that start with `@` contain cycle counts. They differ between
the emulator (which has no timing) and the RTL, and `compare.sh` ignores
them.

## StrataOS 0.1

A microkernel with preemptive multitasking, written in Strata assembly,
where the explicit machine shows through instead of being hidden.

```
strata$ seq 30 | grep 2 | wc        # three processes, two pipes
strata$ -n 3 mandel &               # a bare-metal program as three threads
strata$ as < hello.s > hi && hi     # the assembler, written in Strata assembly
strata$ ps                          # context switches and KiB moved, per process
strata$ sched 500us                 # change the time slice and watch the cost
strata$ ws                          # the window server takes the screen
```

- **The kernel is the system core plus a dispatcher on every worker core.**
  Core 0 runs only the kernel: it creates and destroys processes, hands out
  memory (arenas, 1 MiB by default, revoked by address when a process ends,
  so that ending a process takes back every capability it held or lent
  out), and owns the timer. Each
  worker core's dispatcher runs that core's threads and sorts every
  capability that arrives in its inbox.
- **The kernel pages itself.** A few kilobytes stay resident; the rest is
  code units it loads into its own instruction store on demand, with the
  same `xcall` / miss mechanism programs use.
- **Servers are processes.** `proc` (processes, names, signals), `dev`
  (devices), `fs` (files, with tags instead of directories; it drives the
  block device from user mode), `tty` (the console, Ctrl-C) and `pipe` run
  in user mode, one per core. A message
  is a lent buffer capability: a program gives its 4 KiB buffer to a server
  through an endpoint and gets it back with the answer. Nothing is copied
  between address spaces, because there are none.
- **Preemption with a visible cost.** The system core stops, through core
  control, every worker that has more than one runnable thread, each time
  slice: 2 ms by default, configurable from 100 µs to 100 ms (`sched`). A
  context switch copies out the part of the Local Store a program uses and
  reloads the next one's — the cache flush other machines hide. `ps`,
  `cores`, `uptime` and `sched` show switches and kilobytes moved.
- **Bare-metal programs run unchanged.** Inbox instructions trap in user
  mode and the dispatcher emulates them, so the examples run as
  time-shared threads on a window of cores.
- **The shell** (`sh`) has line editing, history, Tab completion of
  commands and file names, quoting and variables, `;` `&&` `||`, pipelines
  of up to four stages, redirection, background jobs (`jobs`, `fg`, `wait`,
  `kill`), scripts and an `rc` file, and a current tag path: `cd src/demo`,
  `cd ..`, `pwd`; names without a leading `/` are read under it (`ls`,
  `cat hello.s`, `echo hi > notes` tags the new file), programs started from
  there inherit it, and the prompt shows it (`strata:/src/demo$ `). Type
  `help`.
- **Utilities**: `ls cat cp mv rm touch df tag untag retag tags ps free
  uptime devs hexdump cores sched seq grep wc upper spin`, `units` (a program
  that pages its own code), and `as`.
- **Networking**: the `net` server (IPv4, ICMP, UDP, TCP, a DNS resolver)
  and `ping host nc tcpecho ifconfig netstat httpd`. `httpd &` serves the disk
  over HTTP: URLs are tag paths (`/src/demo/hello.s`, `/src/` lists the files
  tagged `src`), `/` is the small site tagged `www`, `/~ps` shows what the
  machine is doing (doc/strataos.md 2.11). With `-N nat` the machine is on the
  real network; `tools/netrelay` does the same for the browser's play page.
  The sources of the programs and examples are on the disk, so they can be
  rebuilt on the machine (each utility's with the library appended). The
  disk is 16 MiB.
- **Cores.** `make boot` boots 12 cores: the system core, five servers and
  six cores free for threads. The minimum is 6 (the shell then shares a
  server's core). A worker core holds up to three threads.

Boot goes: boot ROM (firmware) → platform table → block device → boot
header → the kernel into every core's Local Stores. The kernel loads
`proc`, `dev` and `fs` from the disk itself; `proc` starts `tty`, `pipe`
and the login shell.

The design, the message protocol and every operation number are in
[`doc/strataos.md`](doc/strataos.md) and in the manual's StrataOS chapter.

### The window server

`ws`, typed at the shell, starts the window server: an ordinary program
that becomes the server of a free core, takes the framebuffer and the
keyboard, and tiles up to four windows on a grid. It is the only process
that touches the framebuffer. No store can reach the framebuffer, so
nothing is drawn in place: the screen is a display list, rendered strip by
strip in the Local Store and sent out with transfers, and only damaged
rectangles are redrawn. The strip at the top has one cell per core, lit in
the colour of the process running there and pulsing on every context
switch; each window's tag shows the kilobytes its context switches have
moved.

Windows belong to client programs: `term` (a terminal running `sh -i`
behind two pipes), `wmandel` and `wclock`. Because memory capabilities are
linear, a client draws into a band of its own memory and *lends* it to the
server with each damage request; the server copies the rows into the
window's surface and gives the band back.

Keys (Alt is sent as an ESC prefix): Alt+Enter a new terminal, Alt+P (or
Alt+Space) the launch palette, Alt+1..4 and Alt+arrows focus, Alt+Q close,
Alt+Shift+Q back to the shell, Alt+? the key help (also shown when the
splash ends; any key or click dismisses it).

The mouse is the machine's pointer device (0x4100: a queue of move,
button and wheel events). `tty`, alone on its core, keeps its waiting read
and hands the events to `ws` with the keys. `ws` draws a cursor; a click
focuses the tile under it or runs a program from the palette; the window
under the pointer gets clicks, drags and the wheel, and `term` scrolls back
through its history with the wheel. `make boot-ws` boots straight into the
window server.


`make ws-demo` runs the same renderers on the bare machine against a
simulated twelve-core system (no OS needed), and the site's play page has
it as a preset. See [`os/ws/README.md`](os/ws/README.md).

### `as`: the assembler in Strata assembly

`os/progs/as.s` is a second implementation of `sasm`, written in Strata
assembly. It accepts the same language and writes byte-identical images, so
it can assemble programs (and itself) on the emulator, on the RTL, or as a
StrataOS program. `.include` lines are skipped (the program has no file
system of its own): put the included files into the input yourself.

```bash
build/sasm -o as.stx os/progs/as.s                   # bare metal build
cat prog.s lib.s > all.s
build/strata-emu -c 1 -i all.s as.stx > prog.stx     # source on the console in, image out
#   in StrataOS:  strata$ as < prog.s > prog
```

`tools/test-as.sh` checks it against `sasm` on every example, the kernel,
the boot ROM, itself, a feature test and a set of inputs both must reject,
and runs it under a StrataOS boot.

## Strata Forth

A Forth bootstrapped the classic way — a small kernel in assembly
(`lang/forth/forth.s`), the rest of the language in Forth (`core.fs`) —
whose words compile to **native Strata code**. Stores cannot write
instruction memory, so every definition is written to far memory and
installed with `tgetx`: a JIT whose install step you can watch (`see`,
`.jit`). Capabilities, transfers and tags are ordinary words; `far@` /
`far!` go through a software cache built on `ltag` / `linst`; `spawn` /
`await` run words on other cores; and it has locals, quotations and
`catch` / `throw`.

```bash
make forth              # the prompt, on the bare machine (emulator)
make forth-demo-gfx     # a parallel Mandelbrot set, drawn from Forth
make test-forth         # the regression test, emulator and RTL compared
```

It runs on the bare machine, on both the emulator and the RTL. See
[`lang/forth/README.md`](lang/forth/README.md).

## The emulator's JIT

`strata-emu` translates the plain integer instructions to host code
(`emu/jit/`, arm64 and x86-64 hosts; other hosts interpret) and runs each
core for a quantum of steps per turn; everything else — transfers,
capabilities, traps — is interpreted, and traps stay precise. The JIT is
the default, except with `-t` or `-T virtual`, which keep the reference
one-instruction interleaving that trace comparisons need. `-J` / `-j` force
one or the other. `make test-jit` checks the JIT against the interpreter on
every example and the Forth tests, and `make bench` compares their speed.
The in-browser build interprets.

## Conformance

`conformance/` is an architectural conformance suite: self-checking
assembly tests whose signature regions must be identical on three machines
— the emulator's interpreter, the emulator with the JIT, and the RTL. It
covers the integer instructions and their edge cases, every trap cause with
precise `epc` / `tval`, the capability rules (linearity, split / join /
restrict / share, revocation by address, endpoints, the save table), transfer
hazards and faults, the devices (timer, framebuffer controller, console,
block device, platform table) and multi-core behaviour (gifts, inbox
queues, `tany`, core-control stop).

```bash
make conformance        # the table: test x machine
make fuzz SEEDS=200     # random instruction streams on all three, compared
```

The discrepancies the suite found, and how each was decided, are recorded
in [`conformance/FINDINGS.md`](conformance/FINDINGS.md).

## FPGA

The RTL is synthesizable (Yosys via `sv2v`; `fpga/synth.sh xc7|ecp5`).
A core is about 47k LUTs on Xilinx 7-series: one core fits an Arty A7-100T,
and the 2-core system (about 95k LUTs) needs an XC7A200T board such as the
Digilent Nexys Video. On Lattice ECP5 one core takes about 74k of an
85F's 84k LUT4s, and two cores do not fit. `fpga/arty/` is the board top
(written for the Arty with two cores, which is too many for it), with
LiteDRAM for the DDR3. StrataOS needs six cores, which is about 293k LUTs: more than any Artix-7
or the common Kintex-7 boards hold. See
`fpga/README.md` for the numbers and where the logic goes. Nothing has been
placed and routed, and it has not yet run on hardware.

There is no video output on FPGA yet: the framebuffer is memory only, and
the console is a UART.

## Documentation

- The [Strata Architecture Reference Manual](https://yrashk.github.io/strata/Strata-Architecture-Reference-Manual.pdf):
  the architecture, every instruction, the platform and firmware, StrataOS,
  Forth and the toolchain. The PDF is not in the repository: CI builds it
  from `doc/manual/` and publishes it on
  [the project site](https://yrashk.github.io/strata/). To build it
  locally: `make manual` (needs tectonic).
- [`doc/strataos.md`](doc/strataos.md): the devices and StrataOS,
  as a specification.
- [`ROADMAP.md`](ROADMAP.md): what exists, what is missing, what is next.
- The sources: every line of assembly is commented, and each file starts
  with a description of what it does and why.

## Known limitations

Strata is a prototype. The longer list is in [`ROADMAP.md`](ROADMAP.md);
the main points:

- It has never run on hardware. The RTL is not pipelined, and the 2-core
  system is large for a hobby FPGA.
- A worker core holds at most three threads (the capability save table's
  budget), and StrataOS needs at least 6 cores. The number of processes is
  otherwise limited by memory (a 46 MiB arena pool, 1 MiB per process by
  default) and by 64-entry kernel and server tables: 15 cores run 35
  processes at once (`tools/test-procs.sh`).
- A console read cannot be cancelled, so `halt` may wait for one more key
  when a program was waiting for input.
- The file system has tags instead of directories (`ls /src/demo` lists
  the files tagged both `src` and `demo`, `ls /src/-demo` those tagged `src`
  but not `demo`; subdirectories are facets: `ls /src` ends with `demo/`), but files are contiguous runs of
  blocks, a deleted file's space comes back only if it was the last one, and
  a disk holds at most 128 files and 64 tags.
- The shell has no globbing and no `2>`.
- Strata Forth runs on the bare machine only, not yet as a StrataOS program.
- With timer-driven preemption, the emulator and the RTL cannot be compared
  instruction by instruction on an OS boot (their time bases differ); that
  comparison is of console output. The examples and the conformance suite
  are compared exactly.

## License

Licensed under either of

- Apache License, Version 2.0 ([`LICENSE-APACHE`](LICENSE-APACHE))
- MIT license ([`LICENSE-MIT`](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution
intentionally submitted for inclusion in this work, as defined in the
Apache-2.0 license, shall be dual licensed as above, without any additional
terms or conditions.
