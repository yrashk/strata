# StrataOS 0.1 and the timer / framebuffer devices: design

This is the design specification of the machine's devices and of StrataOS
0.1, the first release. It describes what was built: where the
implementation departed from the original design, this document has been
brought in line with it. Every number here is normative: the emulator, the
RTL, the firmware, the kernel, the programs and the manual all follow it.
When the code and this document disagree, fix one of them; do not leave
them apart.

## 1. Machine

### 1.1 Cores

- The emulator supports up to 15 cores (`MAXCORES 15`; 15 cores + the block
  device = 16 inbox senders, the width of `cpoll`/`tany` masks).
- `NCORES` in the Makefile defaults to **8** (examples, tests, RTL build).
- `make boot` / `make boot-demo` boot the emulator with **12** cores;
  `make boot-rtl*` use the RTL build (`NCORES`, 8).

### 1.2 Device space map (SP_DEV)

| Window | Device | Ports |
|---|---|---|
| 0x0000 | console | 0x00 output, 0x08 input, 0x10 break, 0x18 release (unchanged) |
| 0x1000 | platform table | read-only (unchanged) |
| 0x2000 | block device 0 | unchanged |
| 0x3000 | **timer** | 0x00 NOW, 0x08 FREQ, 0x10 DEADLINE, 0x18 WAIT |
| 0x4000 | **framebuffer controller** | 0x00 PRESENT, 0x08 VSYNC |
| 0x4100 | **pointer** | 0x00 EVENT, 0x08 STATE |
| 0x4200 | **network interface** | 0x00 TX, 0x08 RX, 0x10 STATUS, 0x18 CANCEL |

`DEV_SPACE_LEN` becomes 0x5000.

Device registers are 8 bytes wide, little endian, at 8-byte-aligned ports.
Device transfers move one byte per beat to consecutive ports, so an 8-byte
register is read or written by an 8-byte transfer at its port. A multi-byte
register value is **latched when its byte 0 is read** (no tearing) and a
written value **takes effect when its byte 7 is written**.

**Console input (changed behaviour, same port).** A read of the input port
waits until a byte is available, without blocking the rest of the machine:
other cores keep running, the timer keeps counting, the window keeps
refreshing. In the emulator it is a pending device read like the break port
(satisfied from an input queue fed by the `-i` file, the terminal, or the
window's keyboard); in the RTL it is the existing retry. At the end of a
`-i` file the port returns 0x04 forever, as now.

**Device reads that wait** (console input, the break port, timer WAIT,
VSYNC, the pointer's EVENT, the network's RX) follow three rules, the same on the emulator and the RTL (conformance
tests `brkrel`, `pendxfer`, `haltdrain`):
- **One release completes every break read.** A write to the release port
  (0x18) completes, with 0, every break read waiting at that moment, on
  every core. A break read issued after the release waits for the next
  Ctrl-C or release; a release with no break read waiting does nothing. A
  core has at most one break read in flight. The release also completes
  every console input read waiting for its first byte (its bytes read 0;
  no input is taken), so a core waiting for a key can be stopped too
  (conformance test `inrel`).
- **Transfers are ordered after an in-flight device read.** A transfer
  (`tget`, `tput`, core-control `tput`; not `tgetx`, which writes the I-LS)
  whose D-LS range overlaps the destination of a device read still in
  flight on the same core waits at issue until that read completes, as
  loads and stores do. With CCR.PTRAP set it traps `pend` instead (tval =
  its D-LS address).
- **Halt drains.** `halt` (also in user mode, before it traps to the
  supervisor) waits until every transfer of the core has completed, device
  reads included. Software must not halt a core with a read that may never
  complete (a break read: write the release port first).

#### Timer (0x3000)

- **NOW** (0x3000, read): ticks since power-on. **1 tick = 1 µs.**
- **FREQ** (0x3008, read): 1000000.
- **DEADLINE** (0x3010, read/write): an absolute tick count. Reset value 0.
- **WAIT** (0x3018, read): completes when NOW ≥ DEADLINE and returns NOW
  (latched at completion). Until then it is pending (emulator) / retried
  (RTL), like the break port. Writing DEADLINE re-evaluates pending waits;
  writing 0 completes them at once. Several cores may wait at once; each
  sees the single DEADLINE.

Time base:
- Emulator: `-T real` (default) = host wall-clock µs since start;
  `-T virtual` = executed machine rounds / 100 (a nominal 100 MHz machine
  where a round is every core doing one step). Tests that compare traces or
  outputs use `-T virtual`.
- RTL: a 64-bit counter of clock cycles / `CLK_MHZ` (parameter, default
  100). Under `SIMULATION`, the harness flag `-T real` (default) makes NOW
  come from the host clock through a DPI call (`sim_time_us`), `-T virtual`
  uses the cycle counter.

#### Framebuffer

- **System memory (T3) grows to 64 MiB** (`T3_BYTES` 0x4000000). The
  framebuffer is a fixed **16 MiB window at 0x3000000..0x4000000** of it
  (the top quarter); the display scans out the first height × stride bytes
  of the window. The boot load area stays at 0xF00000..0x1000000.
- Geometry is a property of the machine, reported by the platform table
  (software must not hard-code it): **default 1280 × 800**, 4 bytes per
  pixel, stride = width × 4, format XRGB8888 (bytes in memory: B, G, R,
  unused). Both simulators take **`-r WxH`** (width a multiple of 8, from
  320 × 200 up to 2560 × 1600, which still fits the window).
- **Scanout is live**, as on real framebuffer hardware: the display
  continuously shows what is in the region's memory, so a write into it
  becomes visible at the next refresh without anything else. (Software that
  must not show a half-drawn frame draws off-screen and copies.)
- **PRESENT** (0x4000, write): "this frame is complete". The display is
  refreshed at once, and this is the frame the simulators' `-F` captures
  (see 1.4). The written value is ignored.
- **VSYNC** (0x4008, read): completes at the next display refresh (every
  16667 ticks, i.e. 60 Hz of timer time) and returns the frame number.
- On FPGA there is no video output (yet): PRESENT does nothing, VSYNC still
  paces at 60 Hz of timer time.

#### Pointer (0x4100)

A mouse (or touchpad) with three buttons and a wheel, over the display.

- **EVENT** (0x4100, read): completes with the next queued event (waiting,
  like the other device reads, while none is queued), 8 bytes: u16 x, u16
  y (framebuffer pixels), u8 buttons (bit 0 left, 1 right, 2 middle), s8
  wheel y (> 0: away from the user), s8 wheel x (> 0: right), u8 kind (1
  move, 2 button, 3 wheel, 4 enter, 5 leave). Every event carries the
  position and buttons as they were. **A write** to EVENT (any value)
  completes every EVENT read waiting at that moment, on every core, with 0
  (kind 0: no event), the release rule of the break port.
- **STATE** (0x4108, read): u16 x, u16 y, u8 buttons, u8 events queued,
  u8 0, u8 bit 0 = the pointer is over the display. Reading it changes
  nothing.
- The device queues 16 events. Consecutive moves become one (the last
  position), consecutive wheel turns at the same place add up, and when the
  queue is full the oldest move makes room: button and wheel events are not
  dropped for moves. The first move of a pointer that was not over the
  display is an enter.
- The simulators feed it from the window's mouse (the host cursor is
  hidden once software has read the device), the play page from the
  canvas, and tests from a script (`-P file`, both simulators: one event
  per line, `WHEN move X Y | down B | up B | wheel DY [DX] | enter |
  leave`, WHEN = a step count on the emulator, a cycle count on the RTL,
  or `kN` = once N bytes of console input have been taken). On FPGA there
  is no pointer yet: STATE reads 0 and EVENT waits for a release.

#### Network interface (0x4200)

A network interface that carries raw **IPv4 packets**: no link-layer
framing, no hardware addresses (so no ARP). It is a stream device like the
console, with one waiting read:

- **TX** (0x4200, write): **one transfer is one packet**: the bytes of a
  `tput` that starts at TX are sent as one packet when the transfer ends.
  A transfer longer than the MTU (1500 bytes, the platform entry's info) is
  dropped and counted.
- **RX** (0x4208, read): waits, like the other device reads, until a packet
  is queued, then completes with it: byte i of the transfer is byte i of
  the packet, bytes past the packet's end are zero, and the packet leaves
  the queue (a part of it past the transfer's length is lost). Software
  reads the IPv4 header's total length. Oldest read first.
- **STATUS** (0x4210, read, latched at byte 0): u16 length of the next
  queued packet (0: none), u8 packets queued, u8 bit 0 = link up, u32
  packets dropped (queue full, or too long to send).
- **CANCEL** (0x4218, write, any value): completes every RX read waiting at
  that moment, on every core, with zeros, and takes no packet (the release
  rule of the break port). The kernel writes it when halting.
- The device queues 16 received packets; one that finds the queue full is
  dropped and counted.
- What is on the other end is the simulators' `-N MODE` (both simulators,
  host side in `common/net.h`): `none` (the default: no link, packets sent
  are dropped, nothing arrives), `loop` (every packet sent is received back
  at once: deterministic, used by the conformance test `net`), `peer` (a
  built-in test host at every address but the sender's own: it answers
  ICMP echo requests and echoes UDP datagrams sent to port 7, at once), or
  `udp:LPORT:HOST:RPORT` (a cable to another simulator: one packet per host
  UDP datagram, sent from LPORT to HOST:RPORT, received only from that
  peer; two instances with mirrored ports are two machines on one link;
  needs no privileges). On FPGA there is no PHY yet: TX is dropped, RX
  waits for a CANCEL, STATUS reads 0. The browser build has no link.

### 1.3 Platform table

Four new entry types; `PLAT_ENTRIES` grows by four (to 9, 320 bytes).

| Type | Name | space | base | size | info |
|---|---|---|---|---|---|
| 5 | PT_FB | SP_T3 (3) | 0x3000000 | 0x1000000 | width \| height<<16 \| stride<<32 \| format<<48 (format 1 = XRGB8888) |
| 6 | PT_TIMER | SP_DEV (4) | 0x3000 | 0x20 | ticks per second (1000000) |
| 7 | PT_POINTER | SP_DEV (4) | 0x4100 | 0x10 | buttons (bits 0..7: left, right, middle) \| wheels << 8 (bit 8 y, bit 9 x): 0x0307 |
| 8 | PT_NET | SP_DEV (4) | 0x4200 | 0x20 | the MTU (1500) |

All have node = 0xffff (nothing to `cgive` to). The framebuffer
controller's ports are at the fixed device address 0x4000.

### 1.4 Graphics mode and the keyboard (emulator and RTL simulator)

- Both `strata-emu` and `strata-rtl` open a **window** (SDL2) the first time
  software writes into the framebuffer window of system memory (any `tput`,
  `tamo` or block-device read landing in 0x3000000..0x4000000) or writes
  PRESENT, whichever comes first. Before that they are plain terminal
  programs.
- `-g none`: never open a window (headless; PRESENT is still accepted).
- `-F frame.ppm`: at exit, write the frame as of the last PRESENT as a
  binary PPM (for tests and screenshots); writes after it do not change the
  file.
- `-z N`: window scale (default 1; 2 on a high-DPI display is fine).
- The window scans out the framebuffer memory live (height × stride bytes,
  geometry from `-r`): it is repainted from the current memory contents
  about 30–60 times per second of host wall-clock time (whatever `-T` says;
  only when something was written since the last repaint; `strata-rtl`
  reads back only the range written since then and repaints at most ~30 Hz,
  less often if that read-back is slow), on expose, and at once on PRESENT.
- `-H`: when every core has halted, keep the window open (showing the
  final memory contents) until it is closed.
- Closing the window ends the simulation (like every core halting).
- **Keyboard**: while the window has focus, keys are fed into the console
  input stream as a terminal would send them:
  - printable characters as themselves (with shift/caps applied);
  - Enter 0x0A, Backspace 0x7F, Tab 0x09, Escape 0x1B;
  - arrows ESC [ A/B/C/D (up, down, right, left); Home ESC [ H; End ESC [ F;
    Delete ESC [ 3 ~; Page Up/Down ESC [ 5 ~ / ESC [ 6 ~;
  - Ctrl+letter = 1..26, **except Ctrl+C, which is the break key** (exactly
    like Ctrl-C at the terminal: it completes a pending break read);
  - Alt+key = ESC followed by the key's bytes (xterm "meta sends escape").
  The terminal keeps working as an input source at the same time.

### 1.5 ISA rules clarified by conformance

- **Capabilities are 8-byte aligned.** Every capability's base is a
  multiple of 8: `csplit` traps `capop` (tval = the offset register) unless
  the split offset is a multiple of 8, and nothing else makes a base (boot
  capabilities start at 0; `cjoin`, `crestrict`, `cshare`, `catomic`,
  `cdom` and `crevoke` keep a base; `cmkep` makes an endpoint, whose base is
  a node number). The rule is the same in every space: device ports are
  8-byte aligned (1.2) and transfers still address single device bytes by
  offset. Lengths need not be multiples of 8. So a transfer at offset `o`
  reaches exactly the bytes at base + `o` (conformance test `capalign`).
- The device-read rules of 1.2 (release completes every break read,
  transfers ordered after in-flight device reads, halt drains).

## 2. StrataOS 0.1: a microkernel with preemptive multitasking

The sources state the details: the header of `os/kernel.s` (design
summary, memory maps, shared state), `os/kunits/ops.s` (the kernel's
operations), the headers of `os/servers/*.s` (each server's operations),
`os/lib/sys.s` (the program library) and `os/lib/srv.s` (the server
library). Chapter "StrataOS" of the manual describes the same system at
greater length.

### 2.0 ISA additions this needs

- **`svc`** (SYS group, imm16 = 2; the encoding `isync` used to have): in
  user mode it traps to the **supervisor** with cause **14 `svc`**, `epc` =
  the address of the `svc` (the handler returns with `epc + 4`). It never
  goes to a user trap handler. In supervisor mode it is illegal (cause 1).
  This is a process's explicit "kernel, act for me now" (block, yield,
  receive).
- **No inbox access from user mode.** In user mode, `ctake` (any or named
  sender), `cpoll`, and `tany` with bit 16 set always trap with cause 11
  `priv`, and `crecv` through an endpoint traps `capinv` unless the endpoint
  has R (the kernel never gives user processes receive rights). The core's
  inbox belongs to the core's kernel, which **emulates** these instructions
  for the process (trap-and-emulate), so programs written for bare metal
  run unchanged. `cgive` from user mode stays a plain instruction (through
  the `corebase`/`corecount` window).
- Unchanged and relied on: a core-control stop that arrives while the core
  is in supervisor mode stays pending (`ipend`) and is taken on the next
  return to user mode.
- Unchanged and relied on: the revocation instructions (`cdom`, `crevoke`,
  `cundom`) are privileged. Only the kernel makes revocation domains; a
  server cannot put memory it hands out under a domain of its own (this
  shapes the window server's surfaces, 2.8).

### 2.1 Shape

- **Kernel = the system core (core 0) + a dispatcher on every worker core.**
  - The **system core** does only what nothing else can: it creates and
    destroys processes (placing them on cores), hands out memory (1 MiB
    arenas, each in its own revocation domain), owns the timer (the only
    DEADLINE register) and drives preemption: every **time slice (default
    2 ms, configurable from 100 µs to 100 ms with TUNE)** it stops, through
    core control, each worker that has more than one runnable thread; a
    core running a single thread is never interrupted. It also runs the
    timeouts of timed waits. Its message interface is the ten operations
    of 2.4. Policy lives in servers. Core 0 runs no programs.
  - Each worker's **dispatcher** (supervisor code on that core) runs that
    core's threads: a run queue, context switches, receiving every
    capability that arrives in the core's inbox and handing it to the right
    process, and the core's demand paging of code units.
- **The kernel pages its own code.** Resident: I-LS 0x4000..0x7FFF on every
  core (core 0's own resident code, the event loop and the paging trap,
  sits at 0x7000 and up; workers never run that part). Everything else
  (start-up, the operations of 2.4, exits, ticks) is **kernel code units**
  of 2 KiB in the kernel image's `.far` section (`os/kunits/*.s`), called
  with `xcall` through c12 and paged by the system core's own supervisor
  trap handler into a kernel code cache of 16 slots at I-LS 0x8000..0xFFFF
  of the system core, with the same `xslot`/`xmiss`/`xret` mechanism
  programs use. The kernel counts the unit loads (INFO, `uptime`).
- **Shared state.** The system core and the dispatchers share one 32 KiB
  table at the bottom of system memory (the KST), accessed only with far
  atomics: per-core counters, the published state of each core's thread
  slots, exit events, job records for threads being created, deadlines of
  timed waits. Commands from the system core to a worker are a job record
  plus a doorbell.
- **Servers are processes** (user mode, scheduled like any other, each the
  server of one core; at most one server per core):
  - `proc` (pid 1) — the process server: spawning (loading images through
    `fs`, then asking the kernel to create the process), the process tree,
    exit statuses and WAIT, KILL, signals, `ps`, scheduling figures, and
    the **name registry** (the one endpoint every process is born with).
    It is the only holder of the kernel's endpoint apart from `dev`.
  - `dev` — the device manager: holds the device root capability,
    describes the platform, hands out device capabilities (the console's
    ports to `tty`, the disk's ports and node to `fs`, the framebuffer and
    its controller to `ws`), halts the machine.
  - `fs` — the file server. Owns the block device. Files, directory,
    program images.
  - `tty` — the console server. Owns the console device (output, input,
    break). Line discipline (cooked/raw), the foreground process, Ctrl-C.
    Because it keeps device reads in flight, it is alone on its core.
  - `pipe` — pipes.
  - `ws` — the window server (2.8), started on demand from a shell. Owns
    the framebuffer and, while it runs, the keyboard.
  - `net` — the network server (2.10), started on demand (`net ADDRESS`,
    or by the first program that uses the network). Owns the network
    interface; alone on its core, like `tty`.
- **Boot order.** The kernel itself loads `proc`, `dev` and `fs` from the
  disk (with the firmware's block routines: `fs` must exist before anything
  can be loaded through it) and creates them on cores 1, 2 and 3. `proc`
  then starts `tty` and `pipe` as servers on the next free cores, then
  `sh -l` (restarted, with the console back in cooked mode, whenever it
  exits). So the system needs **at least 6 cores**: the system core and
  five server cores; the shell and other programs share server cores when
  there are no others. `make boot` uses 12.
- **Every process time-shares worker cores**, preemptively; there are no
  exclusive cores. A StrataOS program (second code word `"SYS2"`) is one
  thread with no core window. A **multi-threaded process** (`-n N`, and
  the bare-metal examples run as programs) has N threads (at most 6) on N
  distinct, contiguous worker cores that host no server, addressed through
  the `corebase`/`corecount` window as on the bare machine; each thread is
  scheduled on its core like any process (no gang scheduling). Threads
  `cgive` to each other directly; the receiving core's dispatcher queues
  the capability for the owning process and emulates the thread's
  `ctake`/`cpoll`/`tany` (blocking the thread and running something else
  while it waits; the instruction is retried on wake).
- **Placement.** A server goes on the lowest core that has none. A
  one-thread process goes on the least loaded worker core, preferring cores
  that host a server (so server-free cores stay available for threads); N
  threads go on the run of N contiguous server-free cores whose busiest
  core is least loaded. SPAWN can pin a process to a core (the shell's
  `-c N`).
- **Three threads per worker core.** A core's capability save table has 64
  slots: 24 hold c0..c7 of three resident threads, 6 their save areas and
  image shares, 16 the server's queued and parked requests, 11 the queue
  of attachments and gifts, and 7 the dispatcher's own capabilities. A
  server counts as one of its core's three threads. Other limits: 32
  processes, 24 arenas, 8 handles per process.

### 2.2 Context switches: the cost is explicit

A thread's state is its registers, its capability registers, its CSRs,
and **the parts of its Local Stores it uses**. On a switch the dispatcher:
1. drains the thread's transfers (every tag but the dispatcher's own);
2. saves x1..x31 and the thread's CSRs into its record (on every trap);
3. saves the thread's capabilities. A thread owns **c0..c7** across
   switches; they go into the core's capability save table, 8 slots per
   resident thread. **c8..c15 are a thread's own only while it is not
   switched out** (the dispatcher borrows c8 and c9 during a trap and
   gives them back); they do not survive a switch;
4. copies the used D-LS out to the thread's **save area** in its arena:
   the data extent (a StrataOS program's data section; for a bare-metal
   program, which may use any address, all of 0..0x9FFF) and the live stack
   (sp..0x10000) — not the whole 64 KiB;
5. restores the next thread: D-LS back in, **code reloaded from the
   process's image** in its arena (code is never saved: it is read-only),
   code-cache units reloaded on demand, capabilities, registers, `eret`.

Two calls let a program reduce or correct what a switch does:

- **Scratch ranges.** `svc` 11 SET_SCRATCH (a1 = D-LS start, a2 = length;
  0 clears it) declares one range per thread, rounded inward to whole
  words, that is left out of the saved and restored data extent. Its
  contents are undefined after the thread has been switched out. The window
  server's strip buffers and display list are scratch.
- **Code mirrors.** Programs that generate code (JITs, e.g. Strata Forth)
  install code into their I-LS at run time with `tgetx` from their own
  arena. The I-LS cannot be read back, so the dispatcher cannot save it:
  such a program declares a **code mirror** with `svc` 7 SET_MIRROR (a1 =
  arena offset of a far copy of its I-LS program range [0x8000, 0x10000),
  a2 = length); from then on the dispatcher reloads the I-LS from the
  mirror instead of from the image on every switch-in. Keeping the mirror
  up to date is the program's job (it writes code there before installing
  it anyway).

**The arena** (1 MiB, one revocation domain, zeroed when handed out), for
a process with N threads, with P = 0xD0000 − (N−1) × 48 KiB:

| Arena offsets | Contents |
|---|---|
| [0, P) | the program's memory (thread 0's c0): 832 KiB with one thread. 0x7F000: the start-up block `proc` writes (pid, parent, handles, command line), read once by `sys_init`. The image's **`.far` section is loaded here at its own offsets** (`.far` labels are arena offsets) |
| [P, 0xD0000) | the save areas of threads N−1 .. 1 (48 KiB each) |
| [0xD0000, 0xF0000) | the program image as `fs` loaded it (128 KiB at most); each thread's dispatcher keeps a read-only share and reloads code from it |
| [0xF0000, 0xFC000) | thread 0's save area |
| [0xFF000, 0x100000) | the message buffer (c5) |

A save area holds the data extent at 0.. (40 KiB at most) and the live
stack at 0xA000.. (8 KiB at most).

The kernel counts switches and bytes moved per process and per core
(shown by `ps`, `cores`, `uptime`, `sched`, and drawn by the window
server). Memory map of a worker core: I-LS 0x0000 boot ROM, 0x4000 kernel,
0x8000.. program code (+ code cache); D-LS 0x0000..0x9FFF program data,
0xA000 kernel data, 0xE000..0xFFFF the program's stack (the kernel uses a
stack of its own in its data).

### 2.3 Messages

A message is a **lent buffer capability**. A program owns a 4 KiB message
buffer (the last 4 KiB of its arena, `c5`): request header 0 op, 8 handle,
16 length, 24 mode, 32 result, **40 the sender's pid** (stamped by the
receiving core's dispatcher, so servers can trust it), 48..63 reserved,
data from 64 (≤ 4032 bytes). A reply is the same buffer coming back with
the result filled in.

- **Sending** is a user instruction: `csend c5, cE` through a send-only
  endpoint capability cE the kernel gave the process. Endpoints name a core;
  the kernel mints them (`cmkep`) for the core where the target server (or
  the system core) runs. The `svc` that follows rings the destination's
  doorbell and waits.
- **Attachments.** A request may carry one capability (an arena lent to
  `fs`, a band of pixels lent to `ws`) and a reply up to two. A request's
  attachment reaches the server in c7; a reply's capabilities arrive in the
  caller's c6 and then c7 (the second one replaces the clock; CLOCK gets it
  back). A client attaches with `svc` SEND, which sends the attachment and
  then the buffer with nothing of that core in between. (Sending the
  attachment with a `csend` of one's own before the message is reliable
  only for a process alone on its core: another process of the same core
  could send in between, and the attachment would ride with its message.)
  A linear capability left in c6 while a call is out makes the reply's
  attachment undeliverable: keep c6 free.
- **Supervisor calls** (a0 = function; timeouts in ticks, -1 = none;
  result in a0, -2 = interrupted, -8 = timed out):

  | a0 | name | arguments and result |
  |---|---|---|
  | 1 | WAIT_REPLY | a1 = core to ring first (the destination of a message just sent), a2 = timeout, a3 = base of the capability awaited (0 = the own buffer; -1 = nothing: a sleep), a4 = the register it arrives in → 0, -2, -8 |
  | 2 | RECEIVE | servers. a1 = a mask of transfer tags to wait for as well, a2 = timeout → a reply token, the request in c6 and its attachment in c7; or -1 with a1 = the idle tags; or -8 |
  | 3 | REPLY | servers. a1 = token; a2 bit 0: send c7 with the reply, bit 2: send c4 first, bit 1 (`proc` and `dev` only): mint an endpoint for core a3 and send it. Gives the buffer in c6 back to its owner |
  | 4 | YIELD | let the core's other runnable threads run |
  | 5 | EXIT | a1 = exit code (`halt` also exits, with the code in a0) |
  | 6 | NOTIFY_WAIT | a2 = timeout: block until a notification (an interrupt; a child's exit for `proc`) → its bits, or -8 |
  | 7 | SET_MIRROR | a1 = arena offset of the code mirror, a2 = its length (2.2) |
  | 8 | PARK | servers. The kernel keeps the request in c6 → its park id |
  | 9 | UNPARK | servers. a1 = park id: the request returns to c6 |
  | 10 | CLOCK | the clock capability is put in c7 again |
  | 11 | SET_SCRATCH | a1 = D-LS start, a2 = length (0: none) (2.2) |
  | 12 | SEND | a1 = endpoint register (1..7), a5 = attachment register (0..7, -1 none), a2..a4 as WAIT_REPLY: the dispatcher sends the attachment and then c5 through the endpoint, rings the doorbell and waits like WAIT_REPLY; -1 (nothing sent) if a register is empty or not a send endpoint |

  A server that cannot answer a request yet PARKs it and answers after a
  later UNPARK (a reader of an empty pipe, a WAIT for a running child, an
  EVENT with no event).
- **Demultiplexing.** Every capability arriving at a worker's inbox is taken
  by its dispatcher (whenever it runs: on `svc`, on a preemption stop, on a
  doorbell, on an emulated `ctake`, when idle in `tany`). The rules, in
  order:
  1. a piece of the arena of a process being created on this core (its
     base is known from the job record the system core posted): installed
     in the new thread;
  2. a capability whose base is a local process's message buffer: that
     process's reply;
  3. a capability whose base a local process named in WAIT_REPLY (a3): it
     goes to that process;
  4. a capability sent by a core inside the window of a local
     multi-threaded process: a gift between its threads, queued (with its
     sender) for the emulated `ctake`;
  5. a 4 KiB memory capability otherwise: a request for the core's server.
     It is queued (8 at most) with any attachment waiting from the same
     sender, and the sender's pid is stamped into its header. On a core
     without a server, or with a full queue, it is given back at once with
     result -1;
  6. anything else: an attachment. It travels with the next message from
     the same sending core.

  Who sent a capability and what memory it is decide everything; arena
  containment is not used. A process cannot forge a reply or a request of
  another process, because it does not hold the memory that identifies
  them.
- **When a party dies.** A request whose owner is killed while a server
  works on it dies with the owner's revocation domain: the server's next
  transfer through it faults, and the server library's guard (`srv_guard`)
  drops the request and returns to the loop. When a *server* ends (the
  window server is started and stopped by the user), the requests still
  queued or parked at it go back to their senders with result -1. (A
  request the server holds in c6 at that moment is not answered: servers
  reply before they exit.)
- **Waking a busy core.** After a send, the sender's dispatcher writes a
  stop request into the destination core's core-control word (dispatchers
  hold a core-control capability), so the destination's dispatcher runs
  within microseconds instead of at the next tick. A core idle in `tany`
  wakes on its inbox anyway.
- **The system core** has an endpoint too, but ordinary processes never
  get it: only `proc` holds it, and `dev` (to halt the machine and to lend
  the framebuffer).

### 2.4 Services

Common error results: -1 failed / invalid, -2 interrupted, -3 would block,
-4 no such file or program, -5 no free core / not allowed, -6 no memory,
-7 busy, -8 timed out. An operation a server does not know answers -1.

**The kernel (system core)** — ten operation numbers, used by `proc`
(HALT and FBLEND by `dev`):

| op | name | in | out |
|---|---|---|---|
| 1 | CREATE | attachment: an arena from MEMORY already holding the program image at 0xD0000 (as `fs` loaded it) and the start-up block at 0x7F000. Data: u64 pid (`proc` allocates pids), thread count (0 = one time-shared thread), flags (server 2, privileged 8, device capabilities 16, alone on its core 32, give the arena to `proc` at exit 64), a core to pin to or -1, the *core numbers* of the endpoints for c1..c4 (one byte each, 255 = none; the dispatcher mints the endpoints), a0, a1, a2 | 0, data[0] = the first core; the process starts. A server's reply carries a send endpoint to its core. On failure the arena comes back as an attachment |
| 2 | DESTROY | handle = pid | 0: stopped, its revocation domain dissolved (every capability it held or derived dies); `proc` later gets EXITED with the killed bit |
| 3 | MEMORY | | 0 and a zeroed 1 MiB arena in a fresh revocation domain as an attachment (the kernel keeps its revoker), data[0] = its base; -6 |
| 4 | STATS | | the process count; data: 8 words (cores, free heap, total heap, kernel units loaded, switches, KiB moved, processes, 0), then 32 bytes per core (pid running, runnable, processes, flags; switches; KiB moved), then 32 bytes per process (pid, core, state, flags; threads; switches; bytes moved) |
| 5 | TUNE | length = the time slice in ticks (100..100000) | 0: the preemption time slice from now on; -1 out of range |
| 6 | FREE | attachment: an arena (unused from MEMORY, or returned with EXITED) | 0 |
| 7 | EXITED | sent *by* the kernel to `proc` when a process ends: handle = pid, length = exit status; the arena is attached if CREATE asked for it | |
| 8 | HALT | (`dev`) | stops every core (see "Halting" below) |
| 9 | NOTIFY | handle = pid, length = notification bits | 0: wakes its NOTIFY_WAIT or timed sleep |
| 10 | FBLEND | (`dev` only) handle = pid | 0 and the framebuffer memory as an attachment: every older capability of the framebuffer's revocation domain is revoked and that process is its holder until it ends, when the kernel revokes it again; -7 while a live process holds it; -1 no framebuffer / bad pid |

**`proc` (endpoint c1 of every process: the one it is born with)**

| op | name | in | out |
|---|---|---|---|
| 5 | SPAWN | data: u64 thread count (0 or 1 = one thread, N = N threads on N cores), three handle descriptors (server register << 32 \| server id; the caller's handles that become the child's 0/1/2; -1 none), then "prog args...\0"; length = the text's length; mode bit 0 = no server endpoints (a sandboxed child), bit 1 = pin to core mode >> 8 | pid; -4 no such program, -5 no free core, -6 no memory. A program whose name is exactly `ws` is created as the server of the lowest empty core (-5 if there is none) |
| 6 | WAIT | handle = pid (0 = any child), mode bit 0 = do not block | exit status (bits 0..31 code, bit 62 killed, bit 63 faulted with the cause in 0..7), data[0] = pid; -3 still running, -2 interrupted, -1 no child |
| 7 | KILL | handle = pid | 0 |
| 9 | PS | | count; data: 32-byte records u8 pid, state (1 running, 2 ready, 3 blocked, 4 zombie), core, parent, flags (2 = server), threads; 2 reserved; u32 switches, u32 KiB moved by switches; 16 bytes name |
| 16 | INFO | | data: u64 cores, free heap, total memory, processes, kernel units loaded, context switches, KiB moved |
| 17 | SIGNAL | handle = pid | 0 (2.5) |
| 22 | CATCH | handle = 1 / 0 | 0 |
| 25 | LOOKUP | data = a server's name ("fs", "tty", "pipe", "dev", "ws") | 0, and a send-only endpoint to that server arrives with the reply (in c6; `sys_lookup` puts it where the caller asks); -4 none |
| 29 | REGISTER | data = name | 0: the caller is now that server; the entry dies with the process. -5 unless the caller was started as its core's server (the boot servers, and `ws`); -7 if another live process holds the name |
| 30 | SCHED | handle = 0 read / 1 set (length = slice in ticks, 100..100000) | read: data u64 slice, switches per second (all cores), KiB moved per second, both since the last read; set forwards to the kernel's TUNE: 0 / -1 |
| 31 | CORES | | count; data: 32-byte records u8 core, pid running (0 none), runnable, processes, flags (2 server, 4 alone); 3 reserved; u32 switches, u32 KiB moved |
| 39 | WHOIS | data = name | the pid registered under it (0 for the boot servers); -4 none. `dev` asks it before GRANT_FB |

Three more operations go from `proc` to every server that keeps handles:
36 DUPS (data: owner pid, count, ids: that process now holds these handles
too), 37 CLEANUP (handle = pid: it ended, drop everything it held) and
38 CANCEL (handle = pid: answer the requests held for it with -2).

**Spawning**: MEMORY (an arena) → the start-up block written into it → fs
LOADIMG (the image read straight into the arena) → DUPS at the servers of
the handles passed → CREATE. While it waits for those answers `proc` keeps
the caller's request parked. **Exits**: the dispatcher reports the exit,
the system core dissolves the domain and sends EXITED; `proc` sends
CLEANUP to the servers and completes the parent's WAIT.

**`dev`** (via LOOKUP)

| op | name | out |
|---|---|---|
| 23 | DEVS | count; data: the platform table's 32-byte entries |
| 24 | HALT | asks the kernel to stop every core (does not return) |
| 26 | GRANT_FB | 0, the framebuffer memory (the whole 16 MiB window) in the caller's c6 and a device capability for the controller's ports 0x4000..0x400F in c7. -5 unless the caller is the process registered as "ws" (`dev` asks `proc`: WHOIS); -7 while a live process holds it; -1 if the machine has none. There is no operation to give it back: the kernel revokes it when the holder ends, however it ends, and the next `ws` gets a fresh one |
| 30 | GETDISK | (for `fs`) a window on the block device's ports (c6) and a send-only endpoint to the device's node (c7) |
| 31 | GETCON | (for `tty`) a window on the console's ports 0x0000..0x00FF (c6) |
| 21 | GETPTR | (for `tty`) a window on the pointer's ports 0x4100..0x410F (c6); -1 if the machine has none |
| 59 | GETNET | (for `net`) a window on the network interface's ports 0x4200..0x421F (c6); -5 unless the caller is the process registered as "net" (WHOIS); -1 if the machine has none |

The framebuffer memory is the kernel's: at boot it puts the window in a
revocation domain of its own and **lends** it through FBLEND; the
controller's capability is cut by `dev` from the device root.

**Halting** (ISA rule: `halt` drains a core's pending device reads, 1.2).
`dev` HALT → kernel HALT: the system core marks the machine as stopping
and wakes every worker; each dispatcher stops its threads and counts
itself in before its own `halt`; the system core waits (bounded) for all
of them, so that no process can start another read, then writes the
console's release port (completing every break read and a waiting input
read), the pointer's EVENT
port (completing `tty`'s EVENT read), the network interface's CANCEL
(completing `net`'s RX read) and DEADLINE 0 (completing its own
timer WAIT), and halts. `tty` arms its break read
again only after a real Ctrl-C, not after a release; an input read it had
in flight (a reader was waiting for a key) is completed by the same
release, so `halt` typed in a terminal under `ws` stops the machine at
once.

**Time needs no call.** Every process starts with a read-only device
capability to the timer's NOW and FREQ registers (c7): reading the clock is
an 8-byte `tget`. Sleeping is `svc` WAIT_REPLY with a timeout and nothing
awaited (or NOTIFY_WAIT with a timeout).

Every StrataOS program starts with: c0 its arena's program memory, **c1 the
`proc` endpoint**, c5 its message buffer, c7 the clock, and endpoints to
`fs`, `tty` and `pipe` in c2, c3, c4 (absent in a child spawned with SPAWN
mode bit 0); c6 is empty. A bare-metal program run as a process sees
what it would see on the bare machine: its memory in c0 on its core 0 and
the console's output in c2, inside its core window.

**Handles** are per process (8 at most): 0 stdin, 1 stdout, 2 stderr (= the
console by default); each handle names (server, server-side id). The
program library (`os/lib/sys.s`) sends READ/WRITE/CLOSE for a handle to the
server that owns it; SPAWN passes handles to the child (the servers keep
reference counts per process).

**fs (c2)**: 3 OPEN (mode 0 read, 1 write/truncate, 2 append; data = path)
→ id; 1 READ (0 at the end of the file), 2 WRITE, 4 CLOSE (a written file is
saved to disk when its last reference closes; files being written are held
in a 128 KiB region); 10 DIR (data = a tag path, none = every file) → count
+ 32-byte records (24 bytes name, u64 size; 126 at most), and in the reply's
mode word the *facets*: a tag set (bit t = tag number t) of the other tags
the matching files carry; -4 no such tag; 11 UNLINK;
12 TAG / 13 UNTAG (data = path, a zero byte, a tag name) → 0, -4, -6 (64
tags in use), -1 (bad tag name); 14 TAGS (data = a path, none = every tag)
→ count + 32-byte records (16 bytes name, u64 files carrying it, u64 tag
number); 15 RENAME (data = path, a zero byte, a new path) → 0, -4, -6, -1
(bad new name): the file takes the new path's name and gains its tags
(created if new), keeping its own tags, its blocks and its directory entry;
another file of the new name is deleted; 27 STAT (data = path) → size; 28 LOADIMG (from `proc` when
spawning: data = path, handle = most bytes, mode = arena offset, the arena
as attachment: fs copies the program image into it and the arena goes back
with the reply) → size; 32 STATFS → data: u64 total blocks, used blocks,
files; 33 READBLK (handle = block) → the raw 512-byte block; 34 READALL
(handle = id, mode = arena offset, length = most bytes, the arena as
attachment) → size, the whole file copied in; 35 WRITEALL (handle = id,
mode = arena offset, length, the arena as attachment) → bytes appended to
the file; 36–38 from `proc`. Files are contiguous runs of blocks in a
128-entry directory.

**Tags instead of directories.** A file has one name, unique on the disk,
and carries any number of the disk's 64 tags (names of 1–16 bytes, no
`/`). A "directory" is a set of tags, so one file shows up in several
directories at once, without copies or links. Every name `fs` takes is a
*path*: components separated by `/` (empty ones are skipped). The last
component is the file's name; the ones before it are tags the file must
carry. So `motd`, `/motd` and `/doc/motd` all open motd when it carries
`doc`, and `/bin/motd` is "no such file" (-4). Opening for writing (or
appending) gives the file the path's tags, creating tags that do not exist
yet: `echo hi > /notes/todo` makes `todo` tagged `notes`; a file replaced by
a write keeps its tags. DIR takes a path of tags and lists the files that
carry all of them (`/` or nothing: every file); when its last component is
not a tag but names a file carrying the others, it lists that file. UNLINK
through a path deletes the file (to take it out of a directory, untag it).
A tag that no file carries any more disappears. A component `-tag` (before
the name; in DIR also last) *excludes*: the file must not carry that tag, so
`ls /src/-demo` lists the sources that are not demos and `ls /-bin` every
file not tagged bin (excluding a tag that does not exist excludes nothing).
A path that creates (opening for writing, RENAME's new path) cannot exclude
(-1), and a tag name cannot start with `-`.

**Subdirectories are facets.** DIR also answers the other tags that at least
one matching file carries: the OR of their tag sets, without the path's own
tags (one loop over the 128 sets; nothing on the disk changes). These are
the ways to narrow the listing further, as subdirectories would be: `ls /src`
shows the files tagged src, then `demo/`; `ls /src/demo` narrows to both;
`ls /` shows every file, then every tag in use. A path naming one file has
no facets. The shell's Tab completes facets in a path like folders (`cat
/sr` Tab gives `/src/`, with no space after it).

Utilities: `ls [-t] [PATH]` (files, then facets as `tag/`; `-t` adds each
file's tags), `cat`, `cp [-t] SRC DST` (a copy; DST's path gives it tags,
`-t` also copies SRC's; names are unique, so DST must name another file),
`mv SRC DST` (RENAME; `mv notes /todo/notes` or `mv notes /todo/` keeps the
name and adds the tag), `rm FILE...`, `touch FILE...` (creates empty files;
an existing file the path does not name gets the path's tags), `tag FILE
TAG...`, `untag FILE TAG...`, `retag FILE [TAG...]` (exactly these tags),
`tags [FILE...]`, `df`; the shell completes file names and facets behind a
tag path (`cat /doc/mo` Tab).

**Bare-metal programs and redirection.** A program without the marker has
no library, so `prog < in > out` uses 34/35: `proc` has `fs` copy the
input file into the arena at 0x80000 (a0 = its length, a1 = 1; 256 KiB at
most); at exit the arena comes back to `proc` with EXITED, and `proc`
appends arena[0xC0000, + exit code) (64 KiB at most) to the output file;
the status becomes 0. `as < hello.s > hi` works this way.

**tty (c3)**: 1 READ (mode bit 0 = do not block; cooked: echo, Backspace,
returns one line or what was typed before 0x04, 0 = end of input; raw: no
echo, whatever bytes are there, at least one; CR → LF in both), 2 WRITE,
4 CLOSE (0), 18 SETFG (handle = pid), 19 CONMODE (0 cooked, 1 raw); 36–38
from `proc`. READ mode bit 1 (raw, for `ws`) asks for the pointer's events
too: the READ is also answered when events wait, the answer's mode field
says how many (up to 8), and they follow the data at offset 32, 8 bytes
each as the device gives them; the result counts key bytes only, so 0 with
events is not the end of input. `tty` owns the pointer because a device
read that waits may only be kept by a process alone on its core (the
dispatcher saves a switched-out program's D-LS, and that save would wait
for the read); it reads the pointer only once a reader has asked for its
events, and drains the device's queue (STATE) when an event arrives. The
tty never blocks on its device: the break read is always
in flight and one byte of console input is read only while a reader waits
(so type-ahead is not echoed early), and its RECEIVE names both tags.
Ctrl-C: "^C" is echoed, a partial line is dropped and `proc` is asked to
SIGNAL the foreground process.

**pipe (c4)**: 8 PIPE → read id | write id << 8; 1 READ (mode bit 0 = do
not block; waits while empty; 0 at the end, when no writer is left),
2 WRITE (returns the bytes taken, at least 1: the library writes the rest;
waits while full; -1 with no reader), 4 CLOSE; 36–38 from `proc`. Up to 8
pipes of 2 KiB; one waiting reader and one waiting writer per pipe (another
gets -7).

**Waiting on several things.** A process blocks in one `svc` at a time.
To wait on several sources, a client sends a request that the server holds
until something arrives (through a second message buffer if needed) and
waits with WAIT_REPLY / NOTIFY_WAIT with a timeout; a server's RECEIVE
takes a timeout and a tag mask. `ws` and `sh` never busy-wait the CPU.
(POLL is not an operation.)

### 2.5 Ctrl-C and interrupts

- The tty server has a foreground process (SETFG; initially pid 1). Ctrl-C
  → the tty server asks `proc` to SIGNAL it. (It does not wait for the
  answer: `proc` may itself be calling the tty.)
- An interrupt to a process that does not catch interrupts kills it
  (DESTROY). To one that catches them (CATCH 1): `proc` answers the WAIT it
  holds for that process with -2, or remembers the interrupt for its next
  WAIT; sends CANCEL to `tty` and `pipe`, whose held reads return -2; and
  sends NOTIFY to the kernel, which wakes a sleep or NOTIFY_WAIT.
- The shell catches interrupts, gives the console to a foreground job with
  SETFG and takes it back after, and SIGNALs the job when interrupted while
  waiting for it. The window server catches interrupts and forwards them
  to the focused window's process.

### 2.6 Terminal output subset

Programs write plain bytes to stdout. The console passes them to the host
terminal; `term` windows interpret this subset and ignore other
escape sequences: `\n`, `\r`, `\b`, `\t`; ESC [ K; ESC [ n C / D; ESC [ 2 J;
ESC [ H; ESC [ r ; c H; ESC [ ... m with 0, 1, 30–37, 90–97, 40–47.

### 2.7 The shell (`sh`)

- `sh [-l] [-i] [-c "command"] [FILE]`: `-l` login (runs `rc` first; at the
  end of console input it halts the machine), `-i` interactive even if
  stdin is not the console (`term` uses it), `-c` one command line, FILE a
  script (64 KiB at most; `source` nests three deep). Without any of these
  and with stdin not the console it reads commands without a prompt.
- Line editing: left/right, Home/End, Backspace, Delete, Ctrl-A/E/K/U/W
  (also Ctrl-B/F/P/N), up/down history (32 lines), Tab completion of
  commands (builtins and the programs on the disk) and file names (the
  common prefix; a second Tab lists the candidates), Ctrl-L clear, Ctrl-D on
  an empty line exits, Ctrl-C abandons the line. The prompt (`strata$ `)
  shows a non-zero last status. The console is raw only while a line is
  being typed; jobs run with it cooked.
- Syntax: quotes, `\x`, `$?`, `$$`, `$NAME` (`set`/`unset`), `;`, `&&`,
  `||`, pipelines up to 4 stages, `<`, `>`, `>>`, `&` (anywhere in a list),
  `#` comments; `-n N prog` (or `run -n N prog`) runs N threads on N cores;
  `-c N prog` pins the program to core N.
- Jobs: `jobs`, `fg [%n]`, `wait [%n|pid]`, `kill %n|pid`; a finished
  background job is reported before the next prompt.
- Builtins: help, echo, set, unset, history, jobs, fg, wait, kill, sleep
  (decimal seconds), time, clear, source, exit, halt, run, true, false.
  A builtin in a pipeline or in the background runs in a child shell.
- Programs on disk: ls, cat, cp, mv, rm, touch, df, tag, untag, retag,
  tags, ps, free, uptime,
  devs, hexdump, cores,
  sched (`sched` shows the slice and switch rates; `sched 500us` / `sched 5ms`
  sets it; `rc` may set it at boot),
  seq, grep, wc, upper, spin, as, units, and the examples (all but `clock`
  and `gfx`, which need the device root that only `dev` holds).
- Not there: `cd` (directories are tags: there is no current one),
  globbing, `2>`; completion
  assumes an 80-column terminal, and a line longer than the terminal's
  width redraws wrongly.

### 2.8 The window server (`ws`) and its clients

The graphical UI is a **window server** plus **client programs**. The
window server is the only process that touches the framebuffer and the
keyboard; it draws the desktop (tiles, edges, the status strip) and
composites what clients draw. Clients never see the framebuffer.

**`ws`, the window server** (`os/ws/ws.s`; started by running `ws` from a
shell):
- `proc` creates a program named `ws` as the **server of the lowest empty
  core** (-5 "no free core" if every core has a server). It stays an
  ordinary child of the shell (WAIT, `kill` and Ctrl-C work; `ps` shows it
  as a server). Other processes may time-share its core. When it ends,
  the kernel clears the core's server slot and revokes the framebuffer,
  its registry name goes, clients blocked in a call get -1, the console
  returns to the shell, and `ws` can be run again.
- It registers as "ws", takes the framebuffer (GRANT_FB: the memory
  capability and a device capability for the controller's PRESENT/VSYNC
  ports) and the keyboard (it becomes the tty foreground and switches the
  console to raw), and catches interrupts.
- **The keyboard without polling.** `ws` lends a second message buffer to
  `tty` as a READ. The answer is not its own c5, so its core's dispatcher
  queues it as a request for the core's server, which is `ws` itself: a
  key wakes its RECEIVE exactly as a client's request does. The same READ
  brings the pointer's events (mode bit 1, above).
- **The pointer.** `ws` draws a cursor over everything. A press focuses
  the tile under it; in the palette a click on a program runs it, a click
  outside closes it, and the wheel moves the selection. The window under
  the pointer gets events: presses and releases, moves while a button is
  held, the wheel (EVENT kinds 6 pointer and 7 wheel: value = u16 x, u16 y
  in the surface, then the device's bytes 4..7). `term` scrolls back
  through its history with the wheel (three rows a notch; output returns
  it to the bottom).
- **Key help.** When the splash ends a panel lists the key bindings over a
  dimmed desktop; any key (a whole Alt+key or escape sequence) or click
  dismisses it and is not passed on (Alt+Shift+W, the scripts' pause, still
  works). Alt+? shows it again.
- One loop: wait (RECEIVE with a timeout: a request, a key, or the next
  thing due), serve, tick (slides, fades, pulses; every 250 ms the cores,
  processes and slice from `proc`), deliver events to waiting clients
  (parked EVENT requests), draw the damaged rectangles, one PRESENT. It
  never busy-waits. Its strip buffers and scene (24 KiB of D-LS) are a
  scratch range (SET_SCRATCH).
- **Drawing through transfers.** No store can reach the framebuffer. The
  screen is a display list; the renderer (`os/lib/gfx.s`) walks each
  damaged rectangle strip by strip, drawing rows into a D-LS strip buffer
  that leaves with one `tput`; a blit of a window's surface is a `tget` of
  the source row straight into the strip.
- Draws a 28-pixel **status strip** (below) and **tiles** the windows under
  it: 1 window full; 2 side by side; 3 one left, two stacked right; 4 a
  2 × 2 grid (at most 4).
- Text drawing uses an original public-domain 8 × 16 cell font (plus a
  5 × 7 small-caps font for labels) and is available to clients (TEXT).
- Keys (Alt = ESC prefix): Alt+Enter starts a new `term` window; Alt+Q
  closes the focused window (its client gets a close event, and is killed
  after 400 ms if it does not go away); Alt+arrows / Alt+1..4 move focus;
  Alt+P or Alt+Space opens the command palette; Alt+Shift+Q quits the window server
  (the console returns to the shell); Alt+Shift+H halts the machine;
  Alt+Shift+W makes the server ignore the keyboard for a second (for
  scripted input in tests and demos); Alt+? shows the key help. Every
  other key is an event for the focused window. Ctrl-C closes the palette, or SIGNALs the focused
  window's process.
- Redraws only damaged areas and writes PRESENT once per batch.
- With no window it opens a `term`.

**Look and feel: futuristic, not a desktop clone.** No title bars with
buttons, no overlapping windows, no mouse metaphors. The screen reads as an
instrument panel of the machine itself, and makes the machine's explicitness
visible:
- **Palette**: near-black blue background (#070A12) with a faint 16-pixel
  grid (#0C1320) and small crosses every 64 pixels; edges in deep teal
  (#1F6F8B); accent cyan (#4DE1FF); focus amber (#FFB347); text pale
  blue-white (#CFE8FF); dim text (#5B7088); terminal colours are a matching
  neon set.
- **Tiles float** on the grid with 6-pixel gaps between them. Each has a
  1-pixel luminous edge with a faint inner line and **cut corners** (45°
  chamfers of 6 pixels); the focused tile's edge is amber with a soft outer
  glow. Instead of a title bar, a small **tag** is cut into the top edge:
  `▸ TERM · PID 7 · CORE 3`, in small caps.
- **The core lattice** (the 28-pixel status strip at the top): the STRATA
  wordmark; one cell per core, lit by what it is doing: the colour of the
  process running on it (each process gets a hue), dark when idle, the
  system core marked `K` and server cores with a corner mark; a context
  switch on a core makes its cell **pulse** briefly. Then the window list
  (the focused one in amber), uptime, process count, context switches per
  second and the clock. It is the machine's heartbeat, the explicit cost of
  multitasking made visible.
- **A switch-cost readout**: a second tag at the right end of each tile's
  top edge (`CTX · 148.2 KIB`): KiB moved by context switches for that
  process, updating live.
- **Command palette**: Alt+P (or Alt+Space, which host systems often
  take) opens a centred input line over a dimmed
  screen (`launch ›`), with completion of program names; Enter starts the
  program in a new tile (`term`, `wmandel` and `wclock` make their own
  window; anything else runs as `term COMMAND`).
- **Motion**: when the layout changes, tiles slide to their new places over
  twelve frames; a new tile fades in. Only damaged areas are redrawn.
- **Boot splash** when `ws` starts: the word STRATA drawn as horizontal
  layered bands (strata) that settle into place, then the first tile opens.

**Surfaces: the server keeps them, clients lend bands.** Memory
capabilities are linear, so a surface cannot be writable by a client and
readable by the server at once; and revocation domains are the kernel's
alone (2.0), so the server cannot hand a client memory that it could later
take back. The model is therefore the reverse of "the server lends a
surface":
- Each window's surface (tile width × tile height × 4 bytes, XRGB8888)
  lives **in the server**, in the framebuffer window after the screen's
  pixels: 2 MiB per window, or the last 4 MiB for a single full-size tile.
  (So the screen itself may take at most 4 MiB; the default 1280 × 800 fits.) The
  server can redraw any window at any time (slides, the palette's dim)
  without asking its client.
- A client draws into a **band**: memory of its own arena used as a strip
  of the window, full width and as many rows as fit. To show what it drew
  it lends the band to the server as the attachment of a DAMAGE request
  (`svc` SEND); the server copies those rows into the surface (`tget`,
  `tput`), composes the screen, and gives the band back with the reply.
  While the band is lent the client cannot write it, so the server never
  reads a half-drawn row.
- A resize changes only the numbers: the client learns the new width and
  height from the resize event and draws again. Nothing is revoked.

**The protocol** (ops sent to the "ws" endpoint from LOOKUP; client
library `os/lib/wsclient.s`):

| op | name | in | out |
|---|---|---|---|
| 40 | CREATE | mode bit 0 = interrupt me (SIGNAL) when events wait and I am not in EVENT; data: u64 width, u64 height (ignored: the tile decides), title (8 bytes) | window id; data: u64 width, u64 height of the surface. -7 no room (4 windows) |
| 41 | DAMAGE | handle = window; data: u64 x, y, w, h, stride; attachment: the band holding those w × h pixels from its offset 0 (rows `stride` bytes apart; 0 = w × 4). Without a band: just redraw the rectangle | 0; the band comes back with the reply |
| 42 | TEXT | handle = window; data: u64 x, y (pixels), fg, bg (XRGB; -1 = no background), then the string (length = 32 + its bytes) | 0: drawn into the surface by the server, 8 × 16 font |
| 43 | FILL | handle = window; data: u64 x, y, w, h, colour | 0 |
| 44 | EVENT | handle = window; mode bit 0 = do not block; length = timeout in ticks (0 = none) | 0; data: u64 kind (1 key, 2 resize, 3 close, 4 focus in, 5 focus out, 6 pointer, 7 wheel), u64 value (key bytes, first in the low byte; pointer and wheel: u16 x, u16 y in the surface, u8 buttons, s8 wheel y, s8 wheel x, u8 the device's kind), u64 width (for keys: the number of bytes), u64 height. -3 none (mode bit 0), -8 the timeout passed |
| 45 | DESTROY | handle = window | 0 |
| 46 | TITLE | handle = window; data = title (8 bytes) | 0 |

Every operation answers -1 for a window that is not the caller's. A
window whose process ends is removed.

**Clients**
- **`term`**: a terminal emulator client. Creates a window and runs `sh -i`
  with one pipe as its standard input and another as its output
  (`term COMMAND` types COMMAND into that shell first). It interprets the
  terminal subset of 2.6 (`os/ws/term.s` is its grid, parser and renderer),
  writes key events to the shell's input pipe, and turns Ctrl-C into SIGNAL
  to the shell. It blocks in READ on the output pipe and asks the server
  (CREATE mode bit 0) to interrupt it when events wait: the READ returns
  -2 and the events are fetched without blocking. Nothing is polled.
- **`wmandel`**: renders the Mandelbrot set, DAMAGEs rows as they finish,
  re-renders on resize, quits on close or `q` (renderer: `os/ws/wmandel.s`).
- **`wclock`** (small): a clock window updating every second, to show
  timers + damage (renderer: `os/ws/wclock.s`).
- Any program can do the same through `os/lib/wsclient.s` and
  `os/lib/gfx.s` (surfaces, display lists, spans, text).
- `make ws-demo` runs the same renderers on the bare machine against a
  simulated 12-core system (`os/ws/wsdemo.s`, `fake.s`).

`ws`, `term`, `wmandel` and `wclock` are programs on the disk
(`os/progs/ws.s`, `term.s`, `wmandel.s`, `wclock.s`, built from the modules
in `os/ws/`).


### 2.9 Boot and disk

- Boot header (block 0): offset 44 u32 kernel far-image LBA, offset
  48 u32 far-image blocks (0 if none). `mkdisk -k kernel.stx` writes the
  kernel's SK_T3 section(s) as the far image (its `.far` section starts at
  offset 0 of the image).
- The boot ROM loads the far image into the load area at 0xF30000 (at most
  0xD0000 bytes) and gives core 0 a read+execute share of exactly that range
  in **c12** (other cores do not get it).
- The directory has 128 entries (8 blocks) of {name[24], u32 first block,
  u32 size}; files are contiguous runs of blocks. Header offset 52: u32 LBA
  of the tag table (4 blocks, right after the directory; 0 = none): 64 tag
  names of 16 bytes (zero-padded; a zero first byte = a free slot), then 128
  u64 tag sets, one per directory entry (bit t of set f = entry f carries
  tag t). `mkdisk -t tag,tag...` tags the files named after it (a tag name
  has no `/` and does not start with `-`).
- Memory handed over by the boot ROM: c0 = [0, 15 MiB), and **c13 =
  [16 MiB, 48 MiB)**: system memory above the load area and below the
  framebuffer window; and core 0 also gets **c14 = the framebuffer window
  [48 MiB, 64 MiB)** (read/write).
- The kernel's use of system memory: [0, 32 KiB) the shared table (KST);
  [32 KiB, 64 KiB) the system core's own message buffers; the arenas, 1 MiB
  each, from c13 (on a machine with 16 MiB, from [1 MiB, 15 MiB)); the
  framebuffer window in a revocation domain of its own.
- Start-up: core 0 becomes the system core, sets up paging of its own code
  and calls the start-up unit: the shared table, a copy of it and a
  core-control capability for every worker, the arenas, the directory.
  The workers become dispatchers and wait in `tany`. Then the servers, as
  in 2.1.


### 2.10 The network server (`net`) and its programs

TCP/IP is a server, `os/servers/net.s`, like `fs`, `tty` and `pipe`:

- **Starting it.** `net ADDRESS` (e.g. `net 10.0.0.1 &`) runs it: `proc`
  creates a program named exactly `net` as the server of the lowest empty
  core, **alone on it** (it keeps the RX read in flight, like `tty`'s break
  read; flag "alone on its core" of CREATE). It registers "net", gets the
  interface's ports from `dev` (GETNET: only for the process registered as
  "net") and prints `net: 10.0.0.1, link up` (or `no link`). The first
  program that needs the network starts one with the address 10.0.0.1 if
  none runs (`net_init`, below), so `ping 127.0.0.1` works on a fresh boot.
  It needs a free core: with 8 cores it takes core 6 (multi-threaded
  programs then have one server-free core fewer).
- **The loop.** RECEIVE with a tag mask (the RX read) and a timeout (the
  next TCP or ping timer, from the clock in c7): a request, a packet or a
  timer, never a busy wait. Halting: the kernel's CANCEL completes the RX
  read with zeros (an all-zero header); `net` then stops reading.
- **IPv4**: one interface, static address (SETIP changes it), no routing
  (every address is on the link), no fragments, header checksums made and
  checked. Packets to 127.0.0.0/8 and to the interface's own address never
  reach the device: they go through a local queue (16 packets in the
  server's arena) and are handled as if received, so a machine can talk to
  itself with no link at all.
- **ICMP**: echo requests are answered; echo replies complete PINGs.
- **UDP**: sockets bound to a port; datagrams up to 1472 bytes, queued in
  the socket's 2 KiB ring with their sender.
- **TCP**: 4 sockets in all (TCP or UDP); each has a 2 KiB receive ring
  (the window it advertises) and a 2 KiB send buffer; segments of at most
  1024 bytes (MSS option); in-order receive (out-of-order segments are
  dropped and acknowledged); the oldest unacknowledged segment is sent
  again after 250 ms, doubling up to 8 s, at most 8 times, then the
  connection is reset; a closed window is probed by the same timer;
  TIME-WAIT 500 ms; FIN-WAIT-2 gives up after 10 s; listen/accept,
  connect, half-close (CLOSE mode bit 0).
- **Ownership.** A socket belongs to the process that made it (ACCEPT: the
  one that accepted it); others get -1. `proc` does not send CLEANUP to
  `net`, so every 2 s while sockets are open `net` asks `proc` for the
  process list (PS) and closes the sockets of processes that have ended.
- D-LS: 37,216 bytes of data with the library, measured (rings, send buffers and
  packet buffers), under the 40 KiB data extent.

**Requests** (endpoint from LOOKUP "net"; handle = socket id unless said
otherwise):

| op | name | in | out |
|---|---|---|---|
| 1 | READ | TCP: length = most bytes, mode bit 0 = do not block | bytes; 0 once the peer has closed and all was read; waits while nothing is there; -3 (mode bit 0); -1 after a reset |
| 2 | WRITE | TCP: the data | bytes taken (at least 1; the library writes the rest); waits while the send buffer is full; -1 if closed |
| 4 | CLOSE | mode bit 0 = only stop sending | 0. TCP: buffered data is sent, then FIN; the connection finishes on its own |
| 50 | STAT | | sockets in use; data: u64 address, u64 device STATUS, u64 packets in, out, dropped, u64 socket slots, 2 reserved, then 32 bytes per socket (u8 id, state, protocol, flags; u16 local, remote port; u32 remote address, owner pid, bytes received not read, bytes not acknowledged, peer window, retransmissions) |
| 51 | SETIP | handle = address | 0 |
| 52 | PING | handle = address, length = payload bytes (<= 1400), mode = timeout (0: 1 s) | round trip in ticks; -8 |
| 53 | CONNECT | handle = address, length = port | socket id once established; -1 refused, -8 no answer, -6 no free socket |
| 54 | LISTEN | handle = port | socket id; -7 port in use |
| 55 | ACCEPT | handle = listening socket, mode bit 0 = do not block | the next established connection's id (now the caller's) |
| 56 | UDP | handle = port (0: any) | socket id; -7 |
| 57 | SENDTO | data: u64 address, u64 port, payload (length = 16 + payload, <= 1488) | payload bytes |
| 58 | RECVFROM | length = most bytes, mode bit 0 = do not block | bytes; data: u64 address, u64 port, payload; waits while none |

Addresses are u32 (a.b.c.d = a << 24 | ... | d). 36–38 from `proc` as for
the other servers (CLEANUP closes the pid's sockets, CANCEL answers its
waiting requests with -2). Op 59 is `dev`'s GETNET.

**The library** (`os/lib/sys.s`): `net_init` (LOOKUP "net" into **c6**,
starting the server if none runs), `net_connect`, `net_listen`,
`net_accept`, `net_shutdown`, `net_udp`, `net_sendto`, `net_recvfrom`,
`net_ping`, `net_stat`, `net_setip`, `net_aton`, `out_ip`. TCP sockets are
**handles** (server register 6), so `sys_read`, `sys_write` and `sys_close`
work on them as on files and pipes; they are not passed to children.

**Programs**: `ping [-c N] [-s BYTES] ADDRESS` (a line per reply with its
round trip in ms, a summary; until Ctrl-C or N requests), `nc ADDRESS
PORT` (send standard input, then print what comes back until the peer
closes; a refused connection is tried again for 10 s), `nc -l PORT`
(receive one connection), `nc -u ADDRESS PORT` / `nc -u -l PORT` (UDP),
`tcpecho [PORT [COUNT]]` (a TCP echo server, port 7), `ifconfig [ADDRESS]`,
`netstat` and `httpd` (2.11).

**In Forth** (`lang/forth/README.md`, "Networking"): `net.fs` and `udp.fs`
give Strata Forth the same calls as words (`tcp-listen`, `tcp-accept`,
`tcp-connect`, `sock-read`, `sock-write`, `sock-close`, `udp-open`,
`udp-send`, `udp-recv`, `ping`, `ip>str`, `str>ip`), written in Forth on
one kernel word that sends a message, `(msg)`; Forth keeps the endpoint
in c1 (where `proc`'s was: LOOKUP's arrives in c6, its far heap, which
waits in c7 meanwhile). `forth httpd.fs [PORT [COUNT]]` is an HTTP/1.0
server written with them (port 8000, next to `httpd`'s 80; 2.11): GET and
HEAD of the tag file system, URL paths as tag paths, listings of tag paths,
`index.html`.

### 2.11 The HTTP server (`httpd`)

`httpd [-p PORT] [-c CONNS]` (`os/progs/httpd.s`, tagged `bin,net`) serves
the file system over HTTP/1.0 and 1.1: GET and HEAD, one response per
connection (`Connection: close`, no keep-alive). `httpd &` at the shell;
with the emulator's port forwarding (`-N nat,fwd=8080:80`) a browser on the
host opens `http://localhost:8080/`.

- **URLs are tag paths.** `/TAG/TAG/NAME` opens NAME through that path (the
  file must carry the tags, as `cat /TAG/TAG/NAME` would); `/TAG/TAG/` (a
  trailing slash) is a generated listing of the files carrying every tag
  (DIR; `-TAG` excludes, as in `ls`): name, size and the file's tags as
  links to `/TAG/`, and DIR's facets as links that narrow the listing
  (`/src/` links `/src/demo/`). `/` is the file named `index.html` (any
  tags) if there is one, else the listing of every file, which is always at
  `/~/`. `/TAG` without the slash, when no file has that name but the path
  is a tag path, is a 301 to `/TAG/`. `/~ps` is generated from `proc`'s
  INFO, CORES and PS: uptime, cores, processes, context switches and the
  KiB they moved. `%XX` is decoded; a query (`?...`) is ignored.
- **Responses.** `Content-Type` from the extension (`html`/`htm`, `txt`,
  `css`, `js`, `json`, `png`, `jpg`, `gif`, `svg`, `ico`; `s`, `fs`, `md`,
  `c`, `h` as `text/plain`; no extension: `text/plain` if the first chunk
  looks like text, else `application/octet-stream`) and `Content-Length`
  for files; generated pages end with the connection (no
  `Content-Length`). Files of any size go out in chunks of 4032 bytes, one
  `sys_read` and one `sys_write` each (the socket's 2 KiB send buffer paces
  them). Errors are small HTML pages: 400 (a malformed request line, a bad
  `%XX`, a path over 256 bytes), 404, 405 (other methods; `Allow: GET,
  HEAD`).
- **Connections.** No connection open: `httpd` blocks in ACCEPT. Some
  open: it polls them (non-blocking READ and ACCEPT, a 5 ms sleep when
  nothing happened), up to CONNS at a time (1..3, default 3; `net` has 4
  sockets and the listener takes one). A request is complete at the blank
  line after its headers (or when the client half-closes); only the
  request line and the last bytes are kept once 1 KiB has arrived, so
  headers of any length are fine. A connection that sends no complete
  request in 10 s is closed. A response is written to the end before
  other connections are read again; after it `httpd` closes, so its side
  of each connection spends `net`'s 500 ms TIME-WAIT on a socket.
- **Log**: a line per request on standard output, `METHOD TARGET STATUS
  BYTES` (BYTES: the body sent), before the connection is closed.
- **The site** on the disk is tagged `www`: `index.html` (about the
  machine, with links to the tag listings, some sources and `/~ps`) and
  `style.css`, which the generated pages use too. A file written under
  `/www/` is at that URL at once.
- D-LS: 31,280 bytes of data with the library (the response buffer, a
  4 KiB buffer shared by DIR records, file chunks and PS records, the tag
  tables, 3 KiB of requests); code: 12.3 KiB of the 32 KiB I-LS.

## 3. Tests

- `make test` compares every example on the emulator and the RTL
  instruction by instruction (`tools/compare.sh`, `-T virtual`), and a
  scripted StrataOS session (`os/demo.txt`) on both
  (`tools/compare-boot.sh`: console output, normalised where it shows
  timing, the boot ROM's traces, and exit status 0). With timer-driven
  preemption the two machines' event orders differ (emulator rounds and
  RTL cycles are different time bases), so the OS run cannot be compared
  trace for trace.
- `tools/test-break.sh`: Ctrl-C kills a runaway program and the shell
  survives, on both machines. `tools/test-sh.sh`: a scripted interactive
  shell session with editing keys, compared with `tools/test-sh.out`.
  `tools/test-preempt.sh`: two `spin` processes on one core both make
  progress; `ps` shows context switches. `tools/test-boot-jit.sh`: the
  demo session three times under the JIT's coarser interleaving.
- `tools/test-fb.sh`: frames written with `-F` are byte-identical on the
  emulator and the RTL. `tools/test-jit.sh`: the JIT against the
  interpreter. `conformance/run.sh`: the conformance suite on the
  interpreter, the JIT and the RTL (`net`: the network interface on the
  loopback link).
- `tools/test-net.sh`: TCP/IP. One machine with the test peer (`-N peer`,
  `-j -T virtual`): ping over loopback and to the peer, TCP through
  `tcpecho` (a 300 KB file compared with itself), UDP, a refused connection,
  `netstat`, compared with `tools/test-net.out`; then two emulators linked
  over host UDP: ping, TCP both ways, UDP.
- `tools/test-http.sh`: `httpd`. One machine (`-j -T virtual`) fetches
  pages over loopback with `echo REQUEST | nc 127.0.0.1 80`: the index, a
  listing and its facets, files by tag path, `%XX` and a query, HEAD, 301,
  400, 404, 405, `/~ps`, a 300 KB file (sizes against `wc` and the host),
  `/` without `index.html`, and browser-style requests (CR LF, a 3 KB
  Cookie header) from the test disk `build/http-test/disk.img`, compared
  with `tools/test-http.out`; then two emulators over host UDP: a quick
  request is answered while a slow connection waits.
- `tools/test-as.sh` (run on its own, not by `make test`): the self-hosted
  assembler against `sasm`, including a StrataOS boot that assembles and
  runs a program.
- 
