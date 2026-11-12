# Strata roadmap

Strata is a research prototype: an instruction set architecture in which
memory is explicit I/O, carried far enough to boot an operating system and
to find out what such a machine is like to program. This page says what
exists today, what is known to be missing or rough, and what is planned.

## What exists

**The architecture**
- A 64-bit ISA: Local Stores instead of caches (their sizes a platform
  parameter, 4 to 64 KiB each), a Transfer Unit with completion tags, far
  atomics, linear capabilities, revocation by address, endpoints,
  supervisor and user modes, explicit code paging, `tany` instead of
  interrupts, core control as the one forced preemption (and a reset that
  supervisor code cannot ignore).
- The Architecture Reference Manual (built by CI from `doc/manual/`).

**Two implementations, held together by tests**
- `rtl/`: a synthesizable SystemVerilog implementation, simulated with
  Verilator, up to 15 cores.
- `emu/`: the C reference emulator, with a JIT for arm64 and x86-64 hosts.
- Every example runs on both and is compared instruction by instruction;
  two StrataOS sessions are compared by what they print.
- `conformance/`: a self-checking suite run on the interpreter, the JIT and
  the RTL, and a differential fuzzer across the three.
- Devices on both: console with a break key, block device, timer,
  framebuffer with live scanout, a pointer (mouse and wheel), a network
  interface, and a platform table that describes them.

**In hardware**
- One core placed and routed on a Lattice ECP5-85F at 20 MHz with open
  tools (Yosys, nextpnr), and drawn from nextpnr's output.
- One core laid out on GlobalFoundries' 180 nm GF180MCU with LibreLane:
  93.6 mm², 24.5 MHz with the 3.3 V cells. A measurement, not a tapeout.

**Software**
- `sasm`, a two-pass assembler, and `as`, a second implementation written
  in Strata assembly that produces byte-identical images and runs on the
  machine itself.
- A boot ROM and firmware library.
- StrataOS 0.1: a microkernel (a system core and per-core dispatchers) that
  pages its own code; the servers `proc`, `dev`, `fs`, `tty`, `pipe` and
  `net` as user processes; preemptive multitasking with a configurable time
  slice and the cost of every context switch on display; a shell with
  editing, history, completion, job control and a current tag path;
  utilities; a file system of tags instead of directories; TCP/IP with DNS,
  `ping`, `nc` and an HTTP server; a window server with a terminal and
  demonstration clients; a text editor (`vi`); and guests, other operating
  systems given whole cores beside StrataOS.
- Strata Forth: native code generation, with capabilities, transfers and
  cores as words; on the bare machine, as a StrataOS program (new code in
  code units the kernel pages) and as a StrataOS guest. Network words and an
  HTTP server, 22 of the utilities ported, and `vi.fs`, the editor in Forth.
- Eleven commented example programs.

**On the web**
- The emulator compiled to WebAssembly, with a JIT, a terminal, a canvas for
  the framebuffer and networking (the guest's web server shown in the page).
- A browser for all the sources, the instruction set and architecture
  outline from the manual, the Forth reference with a playground, the
  hardware results, and the web debugger.

**Debuggers**
- A debug engine in the emulator (`strata-emu --debug`): breakpoints and
  watchpoints that know the machine (transfers at issue and completion,
  tags, capability operations, far ranges, processes), the state decoded
  (tags in flight, pending device reads, stall reasons, capabilities and
  their provenance, the save table, inboxes, the overlay map), an event
  log, and time travel on deterministic runs. One JSON-lines protocol
  (`doc/debug-protocol.md`) over stdio, TCP, WebSocket or the browser.
- `strata-dbg`, a gdb-like text debugger with a split-screen view, and a
  web debugger (`site/debug/`) with a transfer timeline, a Local Store map,
  a provenance graph and a time slider, in the page or against the
  desktop engine, with StrataOS's console and screen. Symbol and line maps
  from `sasm -g`; StrataOS and Forth awareness.

## Known limitations

**Hardware**
- The design has never run on a board: there is no ECP5 board top and no
  bitstream yet. The core is multi-cycle, not pipelined; one core routes
  at 20 MHz on the ECP5-85F, whose critical path runs from the D-LS block
  RAM's read port to the trap cause register. Two cores do not fit the
  85F.
- One core is about 32k LUTs on 7-series, each further core about 28k: two
  cores fit an XC7A200T, but the six StrataOS needs (168,694 LUTs) need a
  Kintex-7 325T or larger.
- The GF180MCU layout uses a single-port stand-in for the Local Stores
  (the RTL's are dual-port), has no timing repair and no signoff, and 59%
  of its area is SRAM: no denser memory exists for that process with open
  tools.
- On FPGA there is no video output; the framebuffer is memory only.
- The DRAM adapter makes one access per 8-byte beat.

**The machine and its simulators**
- User mode can reach every Local Store address. Under StrataOS a program
  shares its core's Local Stores with the dispatcher, so a hostile program
  can read or overwrite the kernel's data and code on its core. Capabilities
  cannot be forged (they never live in Local Store bytes), but kernel code
  a program has overwritten runs with the kernel's capabilities.
- The emulator accepts several pending device reads per core where the
  architecture allows one break read.
- The JIT translates only the plain integer instructions; a core with a
  device read pending is interpreted; the x86-64 backend keeps guest
  registers in memory and has run only under Rosetta.

**StrataOS**
- A worker core holds at most 16 threads: a switched-out thread's memory
  capabilities live in the core's capability save table (256 entries; a
  pool of slots shared with the queues; endpoints and device capabilities
  are rebuilt instead), 10 slots reserved per thread: all it can hold. With
  a 64-entry table (a platform parameter) 11 threads, 4 slots each.
- Capability registers c8..c15 do not survive a context switch.
- It needs at least 6 cores and Local Stores of 64 KiB; at most 64
  processes and 64 arenas, in a 46 MiB arena pool; a program's code is
  32 KiB (more through code paging), its data 40 KiB.
- Fixed-size queues: a server's core queues 16 requests (more are refused
  with an error), and a core queues 16 capabilities in transit between
  threads; a flood beyond that loses capabilities. (With a 64-entry save
  table all queues share 12 slots, and a thread holding more than 4 memory
  capabilities takes its extra slots from them; when none is left it is
  not switched out until one frees up.)
- The file system keeps contiguous files in a 128-entry directory, with 64
  tags, and holds files being written in 128 KiB regions.
- The shell has no globbing and no `2>`.
- Under StrataOS the self-hosted assembler reads at most 256 KiB of source
  and writes at most 256 KiB, so it cannot assemble the kernel there (it
  does on the bare machine).
- The window server holds four windows, on a screen of at most 4 MiB of
  pixels (the default 1280 × 800 fits).
- Guests: `halt` does not stop the cores a guest runs on (stop guests
  first), a guest without the console can still write to it, and a guest
  has no framebuffer, files or network.
- There is no calendar time, no persistent state beyond the disk image,
  and no protection between a user and another: it is a single-user
  system.

**Testing**
- With timer-driven preemption the emulator and the RTL have different
  time bases, so an OS session is compared by console output, not trace
  for trace. The examples and the conformance suite are compared exactly.

**Forth**
- On the bare machine it runs in supervisor mode: nothing can interrupt a
  runaway word. (Under StrataOS it is preempted, and Ctrl-C ends it.)

**The debuggers**
- The emulator completes memory transfers at issue, so the debuggers see
  only device reads in flight; a timeline of the RTL's real transfer
  latencies would need the RTL simulator behind the same protocol.
- Time travel needs a deterministic run (`-T virtual`, no JIT, no
  network); the JIT is used only for a plain `continue` with no
  breakpoints on a run that is not recorded.
- The backtrace is a heuristic (there are no frame pointers); the
  StrataOS view reads `proc`'s table only while `proc` owns its core's
  Local Store (it is alone on its core).

## Next

**User-mode Local Store protection.** A window per Local Store that only
supervisor mode sets, checked on every user-mode load, store, fetch and
transfer range, and nestable: any mode may narrow its window, only the
level outside widens it, and a trap restores the outer level's. It closes
the gap above, and would let a guest run its own user programs within a
core. A small ISA change, not yet decided.

**An ahead-of-time compiler for Forth.** Forth already emits native code
into a far-memory mirror of the instruction store; writing that out as a
program is the next step.
- Turnkey images: `' main save" name"` writes an image with the compiled
  code at the same addresses (so nothing needs relocating), the data space
  and an entry stub; the result runs as an ordinary StrataOS program.
- A batch mode from the shell: `forth -c prog.fs -o prog`.
- Tree-shaking: record calls and references while compiling, and save only
  the words reachable from `main`.

**A smaller StrataOS.** Two limits keep it off small machines:
- Local Stores below 64 KiB need a new program ABI (programs linked below
  I-LS 0x8000, less data, a dispatcher placed by the size);
- fewer than 6 cores needs servers sharing cores (a request addressed to a
  process, not to a core).

**More threads per core, further.** Sealed capabilities that the kernel can
spill to memory it alone can reach (the largest change and the most
general); two-level scheduling: user-level threads inside one process
sharing its capability registers, switched by a library without the kernel.

**Hardware.** A board top and a bitstream for the ECP5-85F, then a first
bring-up; timing work (registering the capability operand before EX, or a
slower core clock beside the memory controller's); scanning the
framebuffer out over HDMI/DVI with a keyboard, so the window server runs on
hardware. On GF180MCU: smaller Local Stores (now possible with the size
parameter) to see whether a core fits a shared-wafer slot, then two and six
cores, and a real answer for the dual-port Local Stores.

**The debuggers, further.** The RTL simulator behind the debug protocol
(real transfer latencies on the timeline; the same front-ends); a timing
model for the emulator that keeps memory transfers in flight as the
hardware would (legal under the as-if-synchronous rule: stalls only); data
breakpoints on Forth's dictionary words; source-level stepping by line.

**StrataOS as a guest of StrataOS.** A second, smaller StrataOS on whole
cores beside the first, through the same guest grant.
