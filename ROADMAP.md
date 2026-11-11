# Strata roadmap

Strata is a research prototype: an instruction set architecture in which
memory is explicit I/O, carried far enough to boot an operating system and
to find out what such a machine is like to program. This page says what
exists today, what is known to be missing or rough, and what is planned.

## What exists

**The architecture**
- A 64-bit ISA: Local Stores instead of caches, a Transfer Unit with
  completion tags, far atomics, linear capabilities, revocation by address,
  endpoints, supervisor and user modes, explicit code paging, `tany`
  instead of interrupts, core control as the one forced preemption.
- The Architecture Reference Manual (built by CI from `doc/manual/`).

**Two implementations, held together by tests**
- `rtl/`: a synthesizable SystemVerilog implementation, simulated with
  Verilator, up to 15 cores.
- `emu/`: the C reference emulator, with a JIT for arm64 and x86-64 hosts.
- Every example runs on both and is compared instruction by instruction.
- `conformance/`: a self-checking suite run on the interpreter, the JIT and
  the RTL, and a differential fuzzer across the three.
- Devices on both: console with a break key, block device, timer,
  framebuffer with live scanout, a platform table that describes them.

**Software**
- `sasm`, a two-pass assembler, and `as`, a second implementation written
  in Strata assembly that produces byte-identical images and runs on the
  machine itself.
- A boot ROM and firmware library.
- StrataOS 0.1: a microkernel (a system core and per-core dispatchers) that
  pages its own code; the servers `proc`, `dev`, `fs`, `tty` and `pipe` as
  user processes; preemptive multitasking with a configurable time slice
  and the cost of every context switch on display; a shell with editing,
  history, completion and job control; utilities; and a window server with
  a terminal and two demonstration clients.
- Strata Forth: native code generation, with capabilities, transfers and
  cores as words.
- Eleven commented example programs.

**On the web**
- The emulator compiled to WebAssembly, with a terminal and a canvas for
  the framebuffer, and a browser for all the sources.

## Known limitations

**Hardware**
- The design has never run on a board. The core is multi-cycle, not
  pipelined, with 64-bit adders, comparators and a multiplier in single
  cycles, so timing closure at a useful clock is an open question.
- It is large: the two-core system needs a bigger FPGA than the common
  hobby boards carry. Most of the logic is not the datapath but the code
  map, the banked CSRs, the capability register file and save table, the
  inbox queues and the granule table (revocation by address).
- On FPGA there is no video output; the framebuffer is memory only.
- The DRAM adapter makes one access per 8-byte beat.

**The machine and its simulators**
- A console input read cannot be cancelled. A core that waits for a key
  cannot halt until one arrives (or the input ends).
- The emulator accepts several pending device reads per core where the
  architecture allows one break read, and its `ltag` / `linst` do not check
  ranges that a device read still has in flight.
- The JIT translates only the plain integer instructions; a core with a
  device read pending is interpreted; the x86-64 backend keeps guest
  registers in memory.
- The in-browser emulator is an interpreter.

**StrataOS**
- A worker core holds at most 16 threads: a switched-out thread's memory
  capabilities live in the core's capability save table (256 entries; a
  pool of slots shared with the queues; endpoints and device capabilities
  are rebuilt instead), 10 slots reserved per thread: all it can hold. With
  a 64-entry table (a platform parameter) 11 threads, 4 slots each.
- Capability registers c8..c15 do not survive a context switch.
- It needs at least 6 cores; at most 32 processes and 24 arenas of 1 MiB;
  a program's code is 32 KiB (more through code paging), its data 40 KiB.
- Fixed-size queues: a server's core queues 16 requests (more are refused
  with an error), and a core queues 16 capabilities in transit between
  threads; a flood beyond that loses capabilities. (With a 64-entry save
  table all queues share 12 slots, and a thread holding more than 4 memory
  capabilities takes its extra slots from them; when none is left it is
  not switched out until one frees up.)
- `halt` waits for a pending console read (see above).
- The file system is flat: contiguous files, 128 directory entries, files
  being written held in a 128 KiB region.
- The shell has no globbing, no `2>` and no `cd`; its line editor assumes
  an 80-column terminal.
- Under StrataOS the self-hosted assembler reads at most 256 KiB of source
  and writes at most 64 KiB, so it cannot assemble the kernel there (it
  does on the bare machine).
- The window server holds four windows, on a screen of at most 4 MiB of
  pixels (the default 1280 × 800 fits).
- There is no calendar time, no networking, no persistent state beyond the
  disk image, and no protection between a user and another: it is a
  single-user system.

**Testing**
- With timer-driven preemption the emulator and the RTL have different
  time bases, so an OS boot is compared by console output, not trace for
  trace. The examples and the conformance suite are compared exactly.

**Forth**
- It runs on the bare machine only, in supervisor mode: nothing can
  interrupt a runaway word.

## Next

**Forth as a StrataOS program.** The kernel already has what a program
that generates code needs (a code mirror reloaded on every switch-in).
What remains is the platform layer: `key` / `emit` through the console
server, `include` through the file server, multi-core words on
time-shared threads, and loading the tools (`see`, `words`, `dump`) on
demand to fit the 32 KiB instruction store.

**An ahead-of-time compiler for Forth.** Forth already emits native code
into a far-memory mirror of the instruction store; writing that out as a
program is the next step.
- Turnkey images: `' main save" name"` writes an image with the compiled
  code at the same addresses (so nothing needs relocating), the data space
  and an entry stub; the result runs as an ordinary StrataOS program.
- A batch mode from the shell: `forth -c prog.fs -o prog`.
- Tree-shaking: record calls and references while compiling, and save only
  the words reachable from `main`.
- Large programs: rarely used words as code units, paged on demand.

**More threads per core.** Done: the save table is a pool of slots shared
by the threads and the queues, a switched-out thread keeps only its memory
capabilities there (endpoints and device capabilities are rebuilt on
switch-in), and the table has 256 entries (a platform parameter; `csavex` /
`crestorex` reach slots past 63), so a core holds 16 threads instead of 3,
each with its worst case reserved. Still open:
- servers sharing cores (a request addressed to a process, not to a core),
  so that StrataOS runs on fewer than 6 cores;
- sealed capabilities that the kernel can spill to memory it alone can
  reach: the largest change and the most general;
- two-level scheduling: user-level threads inside one process sharing its
  capability registers, switched by a library without the kernel.

**Cancellable console reads.** An architectural way to withdraw a pending
device read (or to complete it from another core, as the release port does
for the break key), so that halting never waits for a key and a server can
give the keyboard up cleanly.

**A smaller FPGA footprint.** Find what the synthesis numbers are made of
and reduce it: the code map's range comparators, memories that should
infer as block RAM on every family, the save table and queues in LUT RAM.
Then timing: pipeline the long paths or run a slower core clock beside the
memory controller's. Then a first board bring-up.

**Video on FPGA.** Scan the framebuffer window out over HDMI/DVI, with
PRESENT and VSYNC tied to the real display, and a keyboard, so that the
window server runs on hardware.

## In progress

- **Pointer device.** A mouse with buttons and a scroll wheel: an event port
  whose read completes when something happens, like every other device. The
  host side (window, browser, scripted input) is written; the device model in
  the emulator and the RTL, and the window server's cursor, click-to-focus
  and wheel scrolling, are not.
- **FPGA numbers.** The synthesis figures in `fpga/README.md` predate the
  timer, framebuffer controller and later changes; block-RAM inference on
  ECP5 needs fixing before its numbers mean anything.
