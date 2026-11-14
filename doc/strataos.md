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
  queued packet (0: none), u8 packets queued, u8 flags: bit 0 = link up,
  bit 1 = the far end is a user-mode NAT (the guest should be 10.0.2.15),
  bits 2..7 = a host number the link suggests (n: 10.0.0.n; 0 = none: the
  browser's tab link sets it), u32 packets dropped (queue full, or too long
  to send).
- **CANCEL** (0x4218, write, any value): completes every RX read waiting at
  that moment, on every core, with zeros, and takes no packet (the release
  rule of the break port). The kernel writes it when halting.
- The device queues 16 received packets; one that finds the queue full is
  dropped and counted.
- What is on the other end is the simulators' `-N MODE` (both simulators,
  host side in `common/net.h`): `none` (the default: no link, packets sent
  are dropped, nothing arrives), `loop` (every packet sent is received back
  at once: deterministic, used by the conformance test `net`), `peer` (a
  built-in test host at every address but the sender's own and
  192.0.2.0/24, where nothing answers: it answers ICMP echo requests,
  echoes UDP datagrams sent to port 7, and answers DNS queries for its
  names: `peer.test` = 10.0.0.2, `two.test` = 10.0.0.2 and 10.0.0.3,
  `www.peer.test` = a CNAME for `peer.test`, any other `*.test`: no such
  name; other names are looked up for real through the NAT's UDP, or with
  `peer,nodns` do not exist either: fully deterministic, the tests use
  it), `nat[,fwd=HOSTPORT:GUESTPORT]...` (the real network through a
  user-mode NAT, below), or `udp:LPORT:HOST:RPORT` (a cable to another
  simulator: one packet per host UDP datagram, sent from LPORT to
  HOST:RPORT, received only from that peer; two instances with mirrored
  ports are two machines on one link). None needs privileges. On FPGA
  there is no PHY yet: TX is dropped, RX waits for a CANCEL, STATUS reads
  0. The browser's modes are in 2.10.
- **The user-mode NAT** (`-N nat`, `common/netnat.h`, written from scratch:
  no libslirp; nothing blocks, its sockets are polled with the rest of the
  host's input). The guest is 10.0.2.15; 10.0.2.2 is the gateway and the
  host itself (a connection to 10.0.2.2:P reaches 127.0.0.1:P; it answers
  pings itself); 10.0.2.3 is DNS (UDP to port 53 there goes to 8.8.8.8, or
  1.1.1.1 when 8.8.8.8 left the previous query unanswered); every other
  address is the real one. UDP: one host socket per guest flow (32 flows,
  idle ones closed after 60 s, DNS after 10 s), replies wrapped back as
  datagrams. TCP is terminated on the host (16 connections): a guest SYN
  starts a non-blocking `connect()`, answered with SYN-ACK when it
  succeeds and RST when it fails; bytes are relayed both ways with the
  NAT's own sequence numbers, the host's data kept (64 KiB per connection)
  until the guest acknowledges it and sent again on a timer (300 ms,
  doubling to 4 s, 10 times, then RST), within the guest's window and
  MSS, and only while the device's queue has room; the guest's data goes
  to the socket in order (what it does not take is not acknowledged); FIN
  both ways is `shutdown()`, RST both ways. ICMP echo goes through an
  unprivileged ICMP datagram socket (macOS; Linux when
  `net.ipv4.ping_group_range` allows it); where there is none, pings to
  the Internet are dropped (a message says so). `fwd=HOSTPORT:GUESTPORT`
  (repeatable) listens on 127.0.0.1:HOSTPORT; each connection there becomes
  a guest connection from 10.0.2.2:<ephemeral> to GUESTPORT; a busy port is
  reported and skipped. `make boot` uses `-N nat,fwd=8080:80,fwd=8000:8000`
  (`BOOT_NET`), so a web server in the guest is http://localhost:8080/.

#### Sound (0x4300)

A PCM output: a queue of mono, signed 16-bit samples that the device plays
at a set rate. It is **optional**: a machine that has it lists it in the
platform table (type 9, a tenth entry), and software asks `dev` for it
(GETSND) and goes without when the answer is -1. The emulator has it with
`-a` or `-A FILE` and the play page always; the RTL does not (the sessions
that compare the two machines run without it).

- **PCM** (0x4300, write): a transfer's bytes are samples, low byte first,
  appended to the queue (16384 samples). What does not fit is dropped and
  counted.
- **RATE** (0x4308, read / write): samples per second, 8000..48000
  (clamped); 11025 at power-on.
- **STATUS** (0x4310, read): u32 samples queued and not yet played, u32
  samples dropped since power-on.
- The queue empties at RATE in timer time; an empty queue is silence.
  Software paces itself with STATUS: it keeps a fraction of a second queued
  (so a slow frame leaves no gap) and never fills the queue. Several
  programs may write: their samples are queued in the order they arrive.
- `strata-emu -a`: the samples go to the host's audio (SDL, opened at
  RATE) unless `-g none`. `-A FILE` also writes everything played from the
  first sample on, silences included, to FILE as a WAV at exit
  (deterministic with `-T virtual`). In the browser the worker posts the
  samples to the page, which schedules them with WebAudio (after the first
  key or click: browsers do not let a page sound before).

### 1.3 Platform table

Four new entry types; `PLAT_ENTRIES` grows by four (to 9, 320 bytes). A
machine with the sound device has a tenth entry (352 bytes).

| Type | Name | space | base | size | info |
|---|---|---|---|---|---|
| 5 | PT_FB | SP_T3 (3) | 0x3000000 | 0x1000000 | width \| height<<16 \| stride<<32 \| format<<48 (format 1 = XRGB8888) |
| 6 | PT_TIMER | SP_DEV (4) | 0x3000 | 0x20 | ticks per second (1000000) |
| 7 | PT_POINTER | SP_DEV (4) | 0x4100 | 0x10 | buttons (bits 0..7: left, right, middle) \| wheels << 8 (bit 8 y, bit 9 x): 0x0307 |
| 8 | PT_NET | SP_DEV (4) | 0x4200 | 0x20 | the MTU (1500) |
| 9 | PT_SOUND | SP_DEV (4) | 0x4300 | 0x18 | samples the queue holds (16384); only on a machine that has the device |

All have node = 0xffff (nothing to `cgive` to). The framebuffer
controller's ports are at the fixed device address 0x4000.

The header's u16 fields at 20..27: CTAB (save-table entries), NXMAP
(overlay map entries), the D-LS and the I-LS size in KiB (0 in an older
table: 64, 16, 64, 64); 28..31 reserved.

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
  - Alt+key in the xterm modified-key forms: Alt+ a character is
    ESC [ 27 ; 3 ; *code* ~, *code* the character's code in decimal (Shift
    and Caps Lock are in the character: Alt+Shift+Q is 81, `Q`; Alt+Enter
    is 13); Alt+arrows ESC [ 1 ; 3 A/B/C/D, Alt+Home / End ESC [ 1 ; 3 H / F;
    Alt+Delete, Page Up / Down ESC [ 3 ; 3 ~, ESC [ 5 ; 3 ~, ESC [ 6 ; 3 ~.
    Not ESC followed by the key ("meta sends escape"): that is also what Esc
    and then the key sends, and the input is a byte stream, so a program
    could only tell them apart by time, and the bytes of one key can arrive
    apart under load. Nobody types these forms by hand, so the window server
    (2.8) takes only them as its Alt bindings, and Esc and then `p` is just
    Esc and `p`. (Ctrl+Alt+letter is Alt with the control character, codes
    1 to 26, except Ctrl+Alt+C, which is the break key.)
  The terminal keeps working as an input source at the same time (its Alt,
  from the host's terminal, is whatever that terminal sends).

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
  `cundom`) are privileged. Only the kernel makes memory revocable; a
  server cannot make memory it hands out revocable on its own (this
  shapes the window server's surfaces, 2.8). Revocation works by address
  (256 KiB granules, a generation each): there is no fixed number of
  revocable regions, so the number of processes is limited by memory.

- **The overlay map's size, and aligned units.** Each core's overlay map
  has NXMAP entries, a platform parameter in the platform table's header
  (u16 at offset 22; 16 by default, 4..16; `strata-emu -X N`, the RTL's
  NXMAP parameter). An xmap / xunmap index >= NXMAP is an illegal
  instruction. With xslot = n != 0, xmap needs a far address that is a
  multiple of 2^n (xalign, tval = the offset, after the bounds check); a
  lookup matches far >> n, so a unit's address must be aligned: the kernel's
  units are 2 KiB-aligned in c12, and page_in refuses a program whose c0
  base is not slot-aligned. The kernel publishes NXMAP in the KST
  (G_NXMAP) for the workers' page_in.

- **The Local Stores' sizes.** Each core's D-LS and I-LS are powers of
  two from 4 to 64 KiB (64 by default, chosen independently), a platform
  parameter in the platform table's header (u16 KiB at offsets 24 and 26;
  0 in an older table means 64; `strata-emu -L D[,I]`, the RTL's DLS_KIB /
  ILS_KIB). Every Local Store check uses them (the same lsfault / ifault as
  past 64 KiB), and reset puts the D-LS size in sp. StrataOS 0.1's layout
  (below) needs 64 KiB of each: the boot ROM refuses an OS image that does
  not fit, and every core checks the table at kernel entry; on a smaller
  machine core 0 says so and every core halts. The kernel starts every
  thread with sp = 0x10000, so programs do not set it.

- **A bigger save table.** Each core's capability save table has CTAB
  slots, a platform parameter in the platform table's header (u16 at offset
  20; 256 by default, at least 64; `strata-emu -S N`). `csavex cs, rx` and
  `crestorex cd, rx` (CAP2 functions 6 and 7) take the slot from a register
  and reach all of them; `csave` / `crestore` keep their 6-bit immediate
  (slots 0..63). A slot >= CTAB traps capop with tval = x[rx], before any
  other check but privilege. Supervisor only, like the immediate forms.

### 2.1 Shape

- **Kernel = the system core (core 0) + a dispatcher on every worker core.**
  - The **system core** does only what nothing else can: it creates and
    destroys processes (placing them on cores), hands out memory (arenas,
    1 MiB by default, revoked by address when a process ends), owns the timer (the only
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
  sits at 0x7700 and up; workers never run that part). Everything else
  (start-up, the operations of 2.4, exits, ticks) is **kernel code units**
  of 2 KiB in the kernel image's `.far` section (`os/kunits/*.s`), called
  with `xcall` through c12 and paged by the system core's own supervisor
  trap handler into a kernel code cache of NXMAP slots (one per overlay map
  entry: 16 by default, read from the platform table's header at boot) from
  I-LS 0x8000 of the system core, with the same `xslot`/`xmiss`/`xret`
  mechanism programs use. The kernel counts the unit loads (INFO, `uptime`).
  Once start-up is over the units (64 KiB) are copied into T2 after the
  KST, bounced through core 0's D-LS (there is no far-to-far transfer),
  and c12 becomes a read+execute share of the copy (`u_fart2`, called from
  resident code so that no far link into the old image remains): a unit
  then starts arriving after T2's 4 bus cycles instead of T3's 20. Only if
  it fits beside the KST, decided from the platform table's T2 size: on
  the 64 KiB T2 of the FPGA builds it does not, and c12 stays in T3.
- **Shared state.** The system core and the dispatchers share one 32 KiB
  table at the bottom of the cluster store, T2 (the KST; in T3 if a
  platform's T2 is smaller), accessed only with far atomics (an atomic
  takes about 7 bus cycles in T2, 23 in T3): per-core counters, the published state of each core's thread
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
- **Sixteen threads per worker core.** A switched-out thread's capabilities
  must stay on its core (capabilities never live in memory), in the core's
  capability save table: 256 slots on the default platform (its size is in
  the platform table's header; `csavex` / `crestorex` reach every slot,
  `csave` / `crestore` with an immediate slots 0..63). Seven slots, 57..63,
  are the dispatcher's own; the other 249 are a **pool** shared by the
  threads and the queues (the server's queued and parked requests, the
  attachments and gifts waiting for their messages). A thread takes slots
  only for what cannot be rebuilt: memory capabilities (its memory c0, its
  message buffer c5, one capability for its image and save area, which are
  adjacent, or two for a thread of a multi-threaded process, and whatever
  memory it holds in c1..c7). Endpoints (a node and permissions) are minted
  again on switch-in and device capabilities (the clock in c7, a console
  port) are cut again from the device root, so a typical thread holds 3
  slots, a loaded one 1. Every thread record has **10 slots reserved**, all
  a thread can ever need (save area, image share, c0..c7): 16 × 10 = 160,
  and the 89 others, the **general part**, hold the queue entries (48 at
  most). Nothing runs out, so placing a thread on a core with a free record
  is placing it where its slots are. Core 0 places a thread only on a core
  with a free record and a free job record; CREATE fails with -5
  otherwise. `cores` shows each core's free slots.
  The kernel sizes the pool from the platform table at boot. With a 64-slot
  table (`strata-emu -S 64`) a core takes 11 threads with 4 slots reserved
  each (the server 5) and 12 general slots: a thread's extra slots (at most
  8, so the queues keep 4) and the queue entries share them, and a full
  general part refuses a request (back with -1, as a full queue does), a
  PARK (-1), drops an attachment, and keeps a thread whose extra capability
  finds no slot loaded until one frees up.
  Other limits: 64 processes and 64 arenas (the kernel's, `proc`'s, `fs`'s
  and `ws`'s tables), memory (a 46 MiB arena pool), 8 handles per process.
  With 15 cores memory binds first (`tools/test-procs.sh` runs 35 processes
  at once); with 6, the fewest StrataOS needs, the three cores that take
  programs (proc and tty are alone on theirs) hold 16 threads each, 50
  processes, so memory binds there too (the test runs 43 at once; 35 with
  a 64-slot table). With the fixed split of old (24 slots for c0..c7 of
  three threads, 16 for requests, 11 for attachments) a core held three
  threads, and 6 cores 11 processes.

### 2.2 Context switches: the cost is explicit

A thread's state is its registers, its capability registers, its CSRs,
and **the parts of its Local Stores it uses**. On a switch the dispatcher:
1. drains the thread's transfers (every tag but the dispatcher's own);
2. saves x1..x31 and the thread's CSRs into its record (on every trap);
3. saves the thread's capabilities. A thread owns **c0..c7** across
   switches; each one is either described (an endpoint: node and
   permissions; a device capability: base, length and permissions, cut
   from the device root again on switch-in, indistinguishable from the
   original) or put into a slot of the core's save-table pool (2.1).
   **c8..c15 are a thread's own only while it is not
   switched out** (the dispatcher borrows c8 and c9 during a trap and
   gives them back); they do not survive a switch;
4. copies the used D-LS out to the thread's **save area** in its arena:
   the data extent (a StrataOS program's data section; for a bare-metal
   program, which may use any address, all of 0..0x9FFF) and the live stack
   (sp..0x10000) — not the whole 64 KiB;
5. restores the next thread: D-LS back in, **code reloaded from the
   process's image** in its arena (code is never saved: it is read-only),
   the code units its cache held put back into their slots and mapped
   again, capabilities, registers, `eret`.

Nothing waits for the transfers of steps 4 and 5. A far atomic, `cgive`
and `csend` wait until none of the core's memory transfers is in flight
(the publication rule), so the dispatcher makes every atomic of a switch
(the switch and byte counters, the published slot states and runnable
count, the running pid) before its first transfer; the sizes are known by
then. The save is not waited for either: one core's transfers take
effect, on the Local Store side as well as the far side, in issue order
(invariant I2 of the manual's execution model), so the restore that
follows cannot overtake it, and a store that would overwrite bytes the
save still reads waits (I1). The next thread's code goes first (it is
the I-LS, which the save does not read), then the save (tg14 data, tg15
stack), then the restore (tg12 data, tg13 stack; a first load's data
and a code mirror on tg14); with tags of their own no issue waits for a
busy tag, only, past the fourth, for room in the Transfer Unit's
four-entry queue, i.e. for the code and then the save to have moved.
The thread then runs while its
D-LS and code stream in: by the as-if-synchronous rule it cannot tell,
since a load, store or fetch that touches bytes still arriving waits for
them. (A program that issues a transfer on one of those tags right after
a switch merely waits for the dispatcher's; `tpoll` may show it busy.)

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
  it anyway). A program whose generated code is paged (code units: Strata
  Forth) declares only its resident part: the code cache starts after the
  mirror.
- **Code units.** A program's code cache (the I-LS after its resident code
  or code mirror, slots of 2^xslot bytes into which the dispatcher pages
  code units on an `xmiss`) is part of its state like its D-LS. The record
  keeps the unit of every slot (PR_UNITS, written by `page_in`), and a
  switch-in clears the previous process's map, copies each recorded unit
  back into its slot and maps it again. Code in a unit calls resident code
  with a plain link (`jalr`) and is interrupted with its pc in a slot: both
  lead back into the slot, which must hold the same code then (before this,
  a unit interrupted while another program ran on its core resumed in that
  program's code). It costs the cache's bytes per switch-in, which the
  switch counts in its KiB moved; `units` and `forth units.fs` show it.

**What the next process may see.** What a switch leaves out (the D-LS
above the data extent, below the live stack, a scratch range) still
holds the previous thread's bytes. The dispatcher remembers whose bytes
its D-LS holds (`w_dpid`): when it loads a thread of another process, and
on a thread's first load, it restores the whole program D-LS,
[0, 0xA000) and [0xE000, 0x10000) (48 KiB in two `tget`s), from the save
area instead of only the extent and the stack. Outside those, the save
area holds zeros (the arena is scrubbed when MEMORY hands it out, CREATE
takes only such arenas, the program cannot reach its save area, and a
switch writes there only the extent and the live stack) or older bytes of
the same thread: never another process's. A first load takes the zeros
and then the image's data section on top (transfers act in issue order),
replacing a 40 KiB store loop (about 46,000 RTL cycles). A thread that
returns to a core where nothing else ran meanwhile gets back only its
extent and stack, as before. `tools/test-isolate.sh` checks it: two
copies of `tools/dlsgap.s` pinned to one core, one filling its gaps with
a pattern, the other looking for it in its own at its first load and
after each of 8 switches back.

Not covered, and why:
- **The I-LS** above a program's resident code and its code units still
  holds the previous program's code and code-cache units. Nothing can read it: loads and
  `tget` use the D-LS, `tgetx` only writes the I-LS, `ltag`/`linst` work
  on the D-LS tag table, and `xcall`/`xret` reach code only through the
  overlay map, which every switch-in clears. A program could only jump
  into it and execute it; overwriting it would cost up to 32 KiB of
  far-bus traffic per switch.
- **The Local Stores have no user/supervisor protection.** User-mode
  loads, stores and `tgetx` reach every address, including the
  dispatcher's data at 0xA000..0xDFFF (the records, and so the saved
  registers, of the other threads on the core) and its code. Isolation
  between the processes of one core is therefore against disclosure to
  programs that read memory they did not write, not against a hostile
  program; that needs a hardware bound on user-mode Local Store
  addresses, which the ISA does not have. Far memory is protected by
  capabilities either way.

**The arena** (1 MiB unless the spawner asked for more, whole 256 KiB
granules, zeroed when handed out), for a process with N threads, with
P = 0xD0000 − (N−1) × 48 KiB. The offsets are from the arena's **layout
base**, E bytes above its start for an arena of 1 MiB + E (a 1 MiB arena:
its start): the parts below sit at the arena's top, and the program's
memory is E bytes larger, [−E, P). The start-up block stays at offset
0x7F000 of c0.

| Arena offsets | Contents |
|---|---|
| [−E, P) | the program's memory (thread 0's c0): 832 KiB with one thread. 0x7F000: the start-up block `proc` writes (pid, parent, handles, command line), read once by `sys_init`. The image's **`.far` section is loaded here at its own offsets** (`.far` labels are arena offsets) |
| [P, 0xD0000) | the save areas of threads N−1 .. 1 (48 KiB each) |
| [0xD0000, 0xF0000) | the program image as `fs` loaded it (128 KiB at most); each thread's dispatcher keeps a read-only share and reloads code from it |
| [0xF0000, 0xFC000) | thread 0's save area (with one thread, the image and the save area are one capability, kept in one save-table slot) |
| [0xFF000, 0x100000) | the message buffer (c5) |

A save area holds the data extent at 0.. (40 KiB at most) and the live
stack at 0xA000.. (8 KiB at most).

The kernel counts switches and bytes moved per process and per core
(shown by `ps`, `cores`, `uptime`, `sched`, and drawn by the window
server). Each worker's dispatcher also times itself with the `cycle`
CSR, and `cores` shows the averages: **cycles per switch**, from deciding
to switch to having issued the next thread's restore (`w_out` + `w_in`),
and **cycles per trap**, from a trap's entry to the `eret` that resumes a
thread, its idle time not counted (on the emulator `cycle` counts
instructions). The sums and counts are published in the KST core area
(CA_SWCYC, CA_NSWP, CA_KCYC, CA_NTRAP) with the other per-core words.

Measured on the RTL (8 cores, `os/demo.txt`, `strata-rtl -T virtual -g
none`), one row per step of the 2026-11 switch work: the counters alone,
then the isolation fix (whole D-LS from the save area when another
process ran), the KST in T2, a switch that waits for none of its
transfers, and the kernel's code units in T2. Cores 3, 5 and 6 are the
ones that switch (fs and `sh`, pipe and the programs, the two `spin`s
pinned to core 6); per-core cycle and stall totals are dominated by idle
time and the session's fixed waits, so the session total moves little.

| Step | Total cycles | Switches | KiB moved | Cycles/switch (cores 3/5/6) | Cycles/trap (3/5/6) | First load (core 1) |
|---|---|---|---|---|---|---|
| counters only | 151,962,794 | 726 | 33,638 | 17,007 / 11,920 / 8,985 | 18,446 / 16,516 / 19,307 | 52,108 |
| + isolation | 154,186,031 | 738 | 55,116 | 14,403 / 14,294 / 12,654 | 18,226 / 16,942 / 22,751 | 12,860 |
| + KST in T2 | 148,860,825 | 738 | 55,129 | 14,039 / 13,962 / 12,500 | 16,978 / 16,040 / 21,742 | 12,860 |
| + no waiting | 147,362,921 | 728 | 54,699 | 10,674 / 10,355 / 9,589 | 16,449 / 14,670 / 15,379 | 12,201 |
| + units in T2 | 147,662,013 | 730 | 54,856 | 10,667 / 10,478 / 9,588 | 16,452 / 14,787 / 15,375 | 12,201 |

The isolation fix costs bus traffic (+64% KiB moved: 48 KiB in on every
switch between processes, against the extent and stack before) and
about 3,700 cycles per switch on core 6, but makes first loads four
times cheaper (a transfer instead of a 40 KiB store loop). The KST in T2
takes about 1,000 cycles off a trap (some 25 atomics at 7 bus cycles
instead of 23). Not waiting takes a quarter off a switch although the
publishing now counts inside it, and nearly a third off core 6's traps. The
units in T2 save 16 bus cycles per unit paged in (about 550 in the
session): too little to see here. Memory map of a worker core: I-LS 0x0000 boot ROM, 0x4000 kernel,
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
  | 7 | SET_MIRROR | a1 = arena offset of the code mirror, a2 = its length (2.2): the code cache starts after it, and is emptied; → 0, a1 = NXMAP (the overlay map's entries) |
  | 8 | PARK | servers. The kernel keeps the request in c6 → its park id |
  | 9 | UNPARK | servers. a1 = park id: the request returns to c6 |
  | 10 | CLOCK | the clock capability is put in c7 again |
  | 11 | SET_SCRATCH | a1 = D-LS start, a2 = length (0: none) (2.2) |
  | 12 | SEND | a1 = endpoint register (1..7), a5 = attachment register (0..7, -1 none), a2..a4 as WAIT_REPLY: the dispatcher sends the attachment and then c5 through the endpoint, rings the doorbell and waits like WAIT_REPLY; -1 (nothing sent) if a register is empty or not a send endpoint |
  | 13 | UNITS | → the code units the dispatcher paged in for this thread, a1 = the slots of its code cache that hold one |
  | 14 | PAGE | a1 = a missed far address (utval of an xmiss), a2 = the pc of the miss (uepc): a program with its own trap handler (which gets its misses) hands one over; the dispatcher pages the unit in as for its own miss and resumes it at once → 0, or 1 if it cannot (2.2) |

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
  works on it dies when the owner's arena is revoked: the server's next
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
| 2 | DESTROY | handle = pid | 0: stopped, its arena revoked (every capability it held, derived or lent out dies); `proc` later gets EXITED with the killed bit |
| 3 | MEMORY | length = the size wanted (0: 1 MiB; rounded up to whole 256 KiB granules, at least 1 MiB) | 0 and a zeroed arena with a fresh capability as an attachment, data[0] = its base, data[1] = its size; -6 (no memory, or all 64 arena slots in use) |
| 4 | STATS | | the process count; data: 8 words (cores, free heap, total heap, kernel units loaded, switches, KiB moved, processes, 0), then 32 bytes per core (pid running, runnable, processes, flags; switches; KiB moved), then 32 bytes per process (pid, core, state, flags; threads; switches; bytes moved) |
| 5 | TUNE | length = the time slice in ticks (100..100000) | 0: the preemption time slice from now on; -1 out of range |
| 6 | FREE | attachment: an arena (unused from MEMORY, or returned with EXITED) | 0 |
| 7 | EXITED | sent *by* the kernel to `proc` when a process ends: handle = pid, length = exit status; the arena is attached if CREATE asked for it | |
| 8 | HALT | (`dev`) | stops every core (see "Halting" below) |
| 9 | NOTIFY | handle = pid, length = notification bits | 0: wakes its NOTIFY_WAIT or timed sleep |
| 10 | FBLEND | (`dev` only) handle = pid | 0 and the framebuffer memory as an attachment: every older capability of the framebuffer is revoked and that process is its holder until it ends, when the kernel revokes it again; -7 while a live process holds it; -1 no framebuffer / bad pid |

**`proc` (endpoint c1 of every process: the one it is born with)**

| op | name | in | out |
|---|---|---|---|
| 5 | SPAWN | data: u64 thread count (0 or 1 = one thread, N = N threads on N cores), three handle descriptors (server register << 32 \| server id; the caller's handles that become the child's 0/1/2; -1 none), then "prog args...\0"; length = the text's length; mode bit 0 = no server endpoints (a sandboxed child), bit 1 = pin to core (mode >> 8) & 255, mode >> 16 = the arena's size in MiB (0: 1 MiB; the shell's `-m N`) | pid; -4 no such program, -5 no free core, -6 no memory. A program whose name is exactly `ws` is created as the server of the lowest empty core (-5 if there is none) |
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
the system core revokes the arena and sends EXITED; `proc` sends
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
| 22 | GETSND | (for any program) a window on the sound device's ports 0x4300..0x4317 (c6); -1 if the machine has none |
| 59 | GETNET | (for `net`) a window on the network interface's ports 0x4200..0x421F (c6); -5 unless the caller is the process registered as "net" (WHOIS); -1 if the machine has none |

The framebuffer memory is the kernel's: at boot it makes the window a
revocable region of its own and **lends** it through FBLEND; the
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
in a 128 KiB region); 10 DIR (data = a tag path, none = every file; handle
= matching files to skip) → count + 32-byte records (24 bytes name, u64
size; 126 at most: a longer listing is read in parts, skipping what came
already, as `ls` does; `sh`'s completion and `httpd`'s listings take the
first part only), and in the reply's
mode word the *facets*: a tag set (bit t = tag number t) of the other tags
the matching files carry; -4 no such tag; 11 UNLINK;
12 TAG / 13 UNTAG (data = path, a zero byte, a tag name) → 0, -4, -6 (64
tags in use), -1 (bad tag name); 14 TAGS (data = a path, none = every tag)
→ count + 32-byte records (16 bytes name, u64 files carrying it, u64 tag
number); 15 RENAME (data = path, a zero byte, a new path) → 0, -4, -6, -1
(bad new name): the file takes the new path's name and gains its tags
(created if new), keeping its own tags, its blocks and its directory entry;
another file of the new name is deleted; 20 CWD (mode 0 get → length, data
= the current tag path, "/" at the root; mode 1 set, data = a path → the new
one as get, -4 no such tag or no file in that view, -1 longer than 64
bytes, -6 table full; mode 2 from `proc` only, data = u64 parent pid, u64
child pid: the child starts in the parent's path); 27 STAT (data = path) → size; 28 LOADIMG (from `proc` when
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

**The current tag path** is the tag-system analogue of a working
directory. `fs` keeps one per process (a table of 32 entries of at most 64
bytes, one per live process that is not at `/`) and reads every path that
does not start with `/` under it: the requester's path (from the sender pid
the kernel stamps), a `/`, then the path. So in `/src/demo`, `cat hello.s`
opens `/src/demo/hello.s` (hello.s must carry src and demo), `ls` (DIR with
no path) lists the files carrying both and their facets, `ls x/` narrows to
`/src/demo/x`, and `echo hi > notes` creates notes tagged src and demo.
Every path is then normalized: `.` components go and `..` takes the one
before it away (never above `/`), so `cat ../f` works too. When creating,
exclusions that come from the current path are dropped (in `/notes/-work`,
`echo x > f` gives f the tag notes); one written in the path itself is -1
as before. CWD set takes a path relative to the current one (`..`, `a/b`,
`-x`, or absolute) whose every component is a tag that exists, or `-` and
one; at least one file must match the result, so that `cd` cannot leave a
process in an empty view (-4). If the tags of a current path go away later
(the last file carrying one is deleted), relative names in it answer -4
until the process changes it; `/` always works. **Inheritance**: `proc`
sends CWD mode 2 (parent, child) while it spawns, after LOADIMG and before
CREATE, so a child starts where its parent is before it can send anything;
CLEANUP (the process ended, or CREATE failed) frees the entry. `proc` itself
is at `/`, so program images (LOADIMG) are always found from the root.
Every client gets this without doing anything: the programs on the
library, Forth's file words and `include` (its platform layer talks to `fs`
directly), servers such as `httpd`. Names a program got from a listing are
unique on the disk, so such a program asks with `/NAME` (`ls -t`, the
shell's completion of programs).

**Subdirectories are facets.** DIR also answers the other tags that at least
one matching file carries: the OR of their tag sets, without the path's own
tags (one loop over the 128 sets; nothing on the disk changes). These are
the ways to narrow the listing further, as subdirectories would be: `ls /src`
shows the files tagged src, then `demo/`; `ls /src/demo` narrows to both;
`ls /` shows every file, then every tag in use. A path naming one file has
no facets. The shell's Tab completes facets in a path like folders (`cat
/sr` Tab gives `/src/`, with no space after it).

Utilities: `ls [-t] [PATH]` (files, then facets as `tag/`; `-t` adds each
file's tags; no PATH: the current tag path), `cat`, `cp [-t] SRC DST` (a copy; DST's path gives it tags,
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
echo, whatever bytes are there, at least one, and a READ that does not block
and finds nothing (-3) has one byte read ahead, so a program that polls sees
the rest of an escape sequence: `vi` telling Esc from an arrow's ESC [ A;
CR → LF in both), 2 WRITE,
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
  to the focused window's process. `vi` catches them: Ctrl-C reaches it as
  a read that returns -2, which it takes as the key Ctrl-C (2.12).

### 2.6 Terminal output subset

Programs write plain bytes to stdout. The console passes them to the host
terminal; `term` windows interpret this subset and ignore other
escape sequences: `\n`, `\r`, `\b`, `\t`; ESC [ K; ESC [ n C / D; ESC [ 2 J;
ESC [ H; ESC [ r ; c H; ESC [ ... m with 0, 1, 30–37, 90–97, 40–47;
ESC [ ? 25 l / h (the cursor off / on while a program draws); ESC [ 6 n
(where is the cursor: `term` answers ESC [ row ; column R on the program's
standard input, as a terminal would type it; `vi` learns the window's size
this way). Other sequences, private ones (ESC [ ? ...) too, are ignored
whole.

### 2.7 The shell (`sh`)

- `sh [-l] [-i] [-c "command"] [FILE]`: `-l` login (runs `rc` first; at the
  end of console input it halts the machine), `-i` interactive even if
  stdin is not the console (`term` uses it), `-c` one command line, FILE a
  script (64 KiB at most; `source` nests three deep). Without any of these
  and with stdin not the console it reads commands without a prompt.
- Line editing: left/right, Home/End, Backspace, Delete, Ctrl-A/E/K/U/W
  (also Ctrl-B/F/P/N), up/down history (32 lines), Tab completion of
  commands (builtins and the programs on the disk) and file names (the
  common prefix; a second Tab lists the candidates; under a current tag
  path its files and facets), Ctrl-L clear, Ctrl-D on
  an empty line exits, Ctrl-C abandons the line. The prompt (`strata$ `)
  shows a non-zero last status and the current tag path. The console is raw only while a line is
  being typed; jobs run with it cooked.
- Syntax: quotes, `\x`, `$?`, `$$`, `$NAME` (`set`/`unset`), `;`, `&&`,
  `||`, pipelines up to 4 stages, `<`, `>`, `>>`, `&` (anywhere in a list),
  `#` comments; `-n N prog` (or `run -n N prog`) runs N threads on N cores;
  `-c N prog` pins the program to core N; `-m N prog` gives it an arena of N MiB.
- Jobs: `jobs`, `fg [%n]`, `wait [%n|pid]`, `kill %n|pid`; a finished
  background job is reported before the next prompt.
- Builtins: help, echo, set, unset, history, jobs, fg, wait, kill, sleep
  (decimal seconds), time, clear, source, exit, halt, run, true, false,
  cd, pwd.
- `cd [PATH]` sets the current tag path (2.4): `cd TAG` appends a tag,
  `cd a/b` both, `cd -x` an exclusion, `cd /x/y` replaces, `cd ..` drops the
  last component, `cd` or `cd /` goes back to every file; a tag no file
  carries (or a view with no file) is refused: `sh: cd: no such tag: PATH`,
  status 1. `pwd` prints it (`/` at the root). Away from the root the
  prompt shows it: `strata:/src/demo$ ` (at the root it stays `strata$ `).
  A `cd` in a pipeline or in the background runs in a child shell and does
  not change the shell's own path.
  A builtin in a pipeline or in the background runs in a child shell.
- Programs on disk: ls, cat, cp, mv, rm, touch, df, tag, untag, retag,
  tags, ps, free, uptime,
  devs, hexdump, cores,
  sched (`sched` shows the slice and switch rates; `sched 500us` / `sched 5ms`
  sets it; `rc` may set it at boot),
  seq, grep, wc, upper, spin, as, units, vi (the editor, 2.12), and the
  examples (all but `clock` and `gfx`, which need the device root that only
  `dev` holds).
- **In Forth.** Most of these also exist as Strata Forth programs,
  `forth NAME.fs ARGS` (`lang/forth/progs/`, README "The ports of
  os/progs"): seq, cat, upper, wc, grep, hexdump, touch, rm, cp, mv, tag
  (untag, retag), tags, ls, df, free, uptime, devs, cores, ps, sched, spin
  and units, with the same arguments, output, errors and exit codes. They
  share `sys.fs` and are packed into one disk file, `progs.pk` (the
  directory had room for 128 files then), which Forth's `include` looks in for a
  name that is no file. A start costs about 2.5 M instructions more than the
  assembly program; long inputs about 1.1 to 1.8 times its instructions.
- Not there: globbing, `2>`; completion
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
- Keys (Alt+key as the window's keyboard sends it, 1.4: ESC [ 27 ; 3 ;
  code ~, Alt+arrows ESC [ 1 ; 3 X): Alt+Enter starts a new `term` window; Alt+Q
  closes the focused window (its client gets a close event, and is killed
  after 400 ms if it does not go away); Alt+arrows / Alt+1..4 move focus;
  Alt+P or Alt+Space opens the command palette; Alt+Shift+Q quits the window server
  (the console returns to the shell); Alt+Shift+H halts the machine;
  Alt+Shift+W makes the server ignore the keyboard for a second (for
  scripted input in tests and demos); Alt+? shows the key help. Every
  other key is an event for the focused window: Esc followed by a key is
  Esc and then that key, whatever the timing (an ESC with nothing after it
  for 100 ms is the Esc key, not the start of ESC [); an Alt+key the server
  does not bind reaches the window as ESC and the key (as a terminal's
  "meta sends escape"), Alt+Home, End, Delete, Page Up or Down as the key
  alone. Ctrl-C closes the palette, or SIGNALs the focused
  window's process.
- Redraws only damaged areas and writes PRESENT once per batch.
- With no window it opens a `term`. `ws PROGRAM` starts with that program
  in the first window instead (`ws wdoom`); when it ends, a `term` opens
  as usual.

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
readable by the server at once; and revocation is the kernel's
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
  to the shell; a cursor position report a program asks for (ESC [ 6 n)
  goes into that pipe too. It blocks in READ on the output pipe and asks the server
  (CREATE mode bit 0) to interrupt it when events wait: the READ returns
  -2 and the events are fetched without blocking. Nothing is polled.
- **`wmandel`**: renders the Mandelbrot set, DAMAGEs rows as they finish,
  re-renders on resize, quits on close or `q` (renderer: `os/ws/wmandel.s`).
- **`wclock`** (small): a clock window updating every second, to show
  timers + damage (renderer: `os/ws/wclock.s`).
- **`wdoom`**: a first-person shooter in the manner of Doom (a textured
  grid raycaster: walls, floor and ceiling, doors, three kinds of monster,
  a pistol, pickups, a status bar), with art and sounds from Freedoom in a
  data file, `/ws/wdoom.dat`. It draws the 320 x 200 picture in slabs of
  32 columns (the D-LS has no room for more), scales it by the largest
  whole factor that fits its tile, lends each group of slabs as a DAMAGE
  rectangle narrower than the window (x, w and stride of its own), pauses
  when it loses the focus, and mixes its sounds for the sound device when
  the machine has one. `wdoom demo` plays a recorded run one tic a frame
  and reports the frame rate. `os/progs/wdoom.s`, `os/progs/wdoom/`,
  `os/progs/PLAN-wdoom.md`.
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
- The directory has N entries of {name[24], u32 first block, u32 size}
  from block 1 on (N / 16 blocks); files are contiguous runs of blocks.
  N is in header offset 56 (u32): a multiple of 128, at most 1024, which is
  what `mkdisk` makes unless told otherwise (`-n N`; 0 in the header means
  128: a disk from before the field). Header offset 52: u32 LBA of the tag
  table (right after the directory; 0 = none): 64 tag names of 16 bytes
  (zero-padded; a zero first byte = a free slot), then N u64 tag sets, one
  per directory entry (bit t of set f = entry f carries tag t): 2 + N / 64
  blocks. `mkdisk -t tag,tag...` tags the files named after it (a tag name
  has no `/` and does not start with `-`).
- A directory of 1024 entries is 32 KiB, with 8 KiB of tag sets: more than
  the file server's D-LS can spare. `fs` keeps both in its I/O buffer (far
  memory) and works on a window of 128 entries in its D-LS, written back
  and fetched as it walks (`os/servers/fs.s`). The kernel, which loads the
  first servers before there is a file server, reads only the directory's
  first 8 blocks: the servers must be among the first 128 files, as they
  are when `mkdisk` is given them first. `tools/test-files.sh` runs a disk
  of 413 files.
- Memory handed over by the boot ROM: c0 = [0, 15 MiB), and **c13 =
  [16 MiB, 48 MiB)**: system memory above the load area and below the
  framebuffer window; and core 0 also gets **c14 = the framebuffer window
  [48 MiB, 64 MiB)** (read/write).
- The kernel's use of the cluster store (T2, c1 from the boot ROM, of the
  size the platform table gives): [0, 32 KiB) the shared table (KST); the
  rest holds a copy of the kernel's code units (64 KiB, if they fit: not
  in the FPGA builds' 64 KiB T2) and is otherwise unused. T2 is a single
  256 KiB revocation granule, so it can only be revoked whole: it holds
  only what is the kernel's for good. If T2 is smaller than the KST, the
  KST takes T3's first 32 KiB instead.
- The kernel's use of system memory: [0, 32 KiB) unused (the KST's place
  without T2); [32 KiB, 64 KiB) the system core's own message buffers; the **arena
  pool**: [1 MiB, 15 MiB) and c13 = [16 MiB, 48 MiB) (on a machine with
  16 MiB, only the first), each made one revocable region at boot, of
  which core 0 keeps only the revokers and a bitmap of the 256 KiB
  granules. An arena is the first free run of granules that is long
  enough; core 0 cuts the revoker at its bounds, `crevoke`s the piece (a
  fresh capability; everything an earlier owner had there dies) and joins
  the revoker again, and does the same when the process ends. The
  framebuffer window is a revocable region of its own.
- Start-up: core 0 becomes the system core, sets up paging of its own code
  and calls the start-up unit: the shared table, a copy of it and a
  core-control capability for every worker, the arena pool, the directory.
  The workers become dispatchers and wait in `tany`. Then the servers, as
  in 2.1.


### 2.10 The network server (`net`) and its programs

TCP/IP is a server, `os/servers/net.s`, like `fs`, `tty` and `pipe`:

- **Starting it.** `net [ADDRESS]` (e.g. `net 10.0.0.1 &`) runs it; without
  an address it takes 10.0.2.15 on a NAT link, 10.0.0.n when the link
  suggests a host number n, else 10.0.0.1 (STATUS). `proc`
  creates a program named exactly `net` as the server of the lowest empty
  core, **alone on it** (it keeps the RX read in flight, like `tty`'s break
  read; flag "alone on its core" of CREATE). It registers "net", gets the
  interface's ports from `dev` (GETNET: only for the process registered as
  "net"), reads its resolvers from the file `resolv` (tagged `etc`: the
  first two addresses in it; `#` comments) and prints `net: 10.0.0.1, link
  up` (or `no link`). The first program that needs the network starts one
  (`net`, no address) if none runs (`net_init`, below), so `ping 127.0.0.1`
  works on a fresh boot.
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
- **DNS** (op 60 RESOLVE): A records over UDP port 53, a random ID from a
  fresh port, the question echoed back and checked; CNAME chains in the
  answer are followed (up to 8); no answer in a second: the second
  resolver, then each once more (-8 after four tries); NXDOMAIN: -4.
  Defaults 8.8.8.8 and 1.1.1.1 (`resolv`, `ifconfig dns A B`). Answers are
  cached for their TTL (an hour at most) in 16 entries in the server's
  arena; dotted quads and `localhost` need no query (the library already
  answers those itself).
- **TCP**: 8 sockets in all (TCP or UDP); each has a 1 KiB receive ring
  (the window it advertises) and a 1 KiB send buffer; when none is free a
  socket in TIME-WAIT is taken over (so a listener keeps accepting a
  browser's quick connections); segments of at most
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
- D-LS: 39,096 bytes of data with the library, measured (0x98B8: rings,
  send buffers, packet buffers, the resolver's names), under the 40 KiB
  data extent; the loopback queue and the DNS cache are in the arena.

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
| 60 | RESOLVE | data = a host name, length = its bytes (<= 127) | its first IPv4 address; data: u64 count (<= 4), four u64 addresses, the canonical name (zero-terminated); -4 no such name, -8 no resolver answered |
| 61 | SETDNS | handle = the first resolver, length = the second (0: none) | 0 |

Addresses are u32 (a.b.c.d = a << 24 | ... | d). 36–38 from `proc` as for
the other servers (CLEANUP closes the pid's sockets, CANCEL answers its
waiting requests with -2). Op 59 is `dev`'s GETNET.

**The library** (`os/lib/sys.s`): `net_init` (LOOKUP "net" into **c6**,
starting the server if none runs), `net_connect`, `net_listen`,
`net_accept`, `net_shutdown`, `net_udp`, `net_sendto`, `net_recvfrom`,
`net_ping`, `net_stat`, `net_setip`, `net_aton`, `out_ip`, `net_resolve`
(name -> address; a buffer gets the count, the addresses and the canonical
name), `net_setdns`. TCP sockets are
**handles** (server register 6), so `sys_read`, `sys_write` and `sys_close`
work on them as on files and pipes; they are not passed to children.

**Programs** (hosts by name or a.b.c.d): `ping [-c N] [-s BYTES] HOST`
(`PING name (a.b.c.d)`, a line per reply with its round trip in ms, a
summary; until Ctrl-C or N requests; under `-N nat` the echo is real where
the host allows unprivileged ICMP, under `-N peer` the peer answers),
`host NAME` (its addresses, and the CNAME it is an alias for), `nc HOST
PORT` (send standard input, then print what comes back until the peer
closes; `-H`: without the half-close, for web servers that drop
half-closed connections; a refused connection is tried again for 10 s),
`nc -l PORT` (receive one connection), `nc -u HOST PORT` / `nc -u -l
PORT` (UDP), `tcpecho [PORT [COUNT]]` (a TCP echo server, port 7),
`ifconfig [ADDRESS | dns A [B]]` (also shows the resolvers),
`netstat` and `httpd` (2.11).

**In the browser** (`site/play/net.js`, `web/web.c`; the page's Network
menu): *test peer* (`-N peer`: the built-in peer and its names; every other
DNS query is answered by the page over HTTPS from Cloudflare's JSON API,
else Google's, as a real DNS answer); *link to my other tabs* (`-N web`:
the tabs of the page on one machine share a BroadcastChannel; they agree on
host numbers, 10.0.0.1, 10.0.0.2, ..., through STATUS's hint); *relay*
(`-N web,nat`: each packet is a binary WebSocket message to a URL the user
types, nothing by default; `tools/netrelay` is that relay: the same NAT
behind a small WebSocket server on 127.0.0.1:8765, `-f HOSTPORT:GUESTPORT`
for inbound).

**In Forth** (`lang/forth/README.md`, "Networking"): `net.fs` and `udp.fs`
give Strata Forth the same calls as words (`tcp-listen`, `tcp-accept`,
`tcp-connect`, `sock-read`, `sock-write`, `sock-close`, `udp-open`,
`udp-send`, `udp-recv`, `ping`, `ip>str`, `str>ip`), written in Forth on
one kernel word that sends a message, `(msg)`. Forth's c0..c7 are all in
use, so the endpoint is not kept: before each request `(msg)` asks `proc`
(c1) for it with LOOKUP (it arrives in c6, the far heap, which waits in c7
meanwhile) and drops it after the answer, a `proc` round trip per request.
`forth httpd.fs [PORT [COUNT]]` is an HTTP/1.0 server written with them
(port 8000, next to `httpd`'s 80; 2.11): GET and HEAD of the tag file
system, URL paths as tag paths, listings of tag paths, `index.html`, its
own home page `/www/forth.html` at `/`, and `/~ps` from `proc`'s INFO,
CORES and PS.

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
  `sys_read` and one `sys_write` each (the socket's 1 KiB send buffer paces
  them). Errors are small HTML pages: 400 (a malformed request line, a bad
  `%XX`, a path over 256 bytes), 404, 405 (other methods; `Allow: GET,
  HEAD`).
- **Connections.** No connection open: `httpd` blocks in ACCEPT. Some
  open: it polls them (non-blocking READ and ACCEPT, a 5 ms sleep when
  nothing happened), up to CONNS at a time (1..3, default 3; `net` has 8
  sockets in all, the listener takes one, and a socket in TIME-WAIT is
  reused when none is free). A request is complete at the blank
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

### 2.12 The editor (`vi`)

`vi [FILE]` (`os/progs/vi.s`) edits a file in the manner of vi, on the
console (an ANSI terminal: `make boot`, the browser's terminal) and in a
`term` window (`make boot-ws`, Alt+Enter), with Strata assembly and Strata
Forth in colour. FILE is a path (`/src/hello.s`, or a name under the current
tag path); one that does not exist is created by `:w`. The screen is the
text, a line a row (a long line scrolls the view sideways), and a status
line: `-- INSERT --`, the file name, `[+]` when modified, line,column;
messages and the `:` and `/` lines take its place.

- Moving: `h j k l` and the arrows, `w b e`, `0 ^ $`, `gg G`, `NG`, `%`,
  Enter `+ -`, Space, Backspace, Ctrl-D / Ctrl-U (half a screen), Ctrl-F /
  Ctrl-B (a screen), Home/End, PgUp/PgDn. A count repeats or scales: `5j`,
  `3dd`, `2dw`, `d3w`.
- Inserting: `i a I A o O`; in insert mode Enter splits the line,
  Backspace and Delete erase, the arrows move; Esc or Ctrl-C ends it.
- Changing: `x X r D C s S J`, `d c y` with a motion (`dw cw d$ c$ dG y3j`
  ...) or doubled for lines (`dd cc yy`), `Y`, `p P` (characters into the
  line, or lines below / above), `u` (undo, many levels), Ctrl-R (redo), `.`
  (the last change again: its keys are replayed). A motion to another line
  makes `d c y` linewise when it is a line motion (`j k G gg`); a character
  motion that leaves the line stops at its end or start (`dw` on the last
  word, `cw` changes to the end of the word).
- Searching: `/text` and `?text` (plain text), `n`, `N`; the search goes
  round the end of the file and says so.
- `:w`, `:w NAME` (the buffer keeps its name unless it had none), `:q`,
  `:q!`, `:wq`, `:x` and `ZZ` (written only if modified), `:e NAME`, `:e!`,
  `:N` (line N), `:set nu` / `:set nonu` (line numbers), `:syntax on` /
  `:syntax off`. Ctrl-L asks the terminal its size and draws everything
  again; Ctrl-G shows the file and its size.
- **Highlighting.** `.s` is Strata assembly, `.fs` Strata Forth; another
  name is plain unless the file carries the tag `src` (assembly) or `forth`.
  The rules are the site's (`site/hl.js`): for assembly, comment lines and
  `;` `#` `//` comments, labels, `NAME =` and CAPITALS, mnemonics by
  category (ALU, memory, branch, transfer, capability, system, paging,
  pseudo-instructions), directives (a word starting with "."), x and c
  registers and transfer tags, CSR names after `csrr` / `csrw`, numbers,
  strings and characters; for Forth, `\` and `( )` comments (a `(` comment
  may run over lines: the state at the start of each row is kept, and a
  change that alters it draws the rows below), `:` `;` and the defining
  words with the names they define, control words, the Strata words,
  numbers, strings and locals. The keyword tables are generated at build
  time (`tools/vi-syntax.py` -> `build/vi-syntax.s`) from the sources the
  site uses: `asm/sasm.c` and `lang/forth/README.md` through
  `tools/web-code.py`, and `site/hl.js`'s Forth word lists. The site's
  colours (`site/hl.css`) are mapped to the 16 SGR colours: comments 90,
  labels 97, constants 92, ALU 96, memory 94, branches 95, transfers 33,
  capabilities 93, system 31, paging 91, pseudo 36, directives 34, x
  registers 37, c registers 93, CSRs 91, numbers 32, strings 35; Forth
  definitions 31, names 97, control 95, defining words 34, Strata words 33,
  locals 93.
- **Screen size.** vi moves the cursor to row 999, column 999 and asks
  ESC [ 6 n; an ANSI terminal (and `term`, 2.6) answers ESC [ row ; column R
  with where the cursor stopped. Without an answer within 0.2 s, or when a
  key comes first (a script), it is 80 × 24 (at most 62 × 250 are used).
  Ctrl-L asks again; an answer is taken whenever it comes. A window that
  changes size is not noticed until Ctrl-L.
- **Keys.** The console delivers a key's bytes one at a time, so an Esc is
  told from an escape sequence by time: a `[` within 30 ms (vi polls with
  READs that do not block, which have `tty` read one byte ahead) makes a
  sequence (the arrows, Home, End, Delete, PgUp, PgDn).
- **Drawing.** Only what changed is sent: the rows of lines that changed
  (and the rows below when lines come or go), the status line, the
  cursor; the cursor is off while a frame is drawn. A scroll draws the
  text rows again: the console's and the window's terminals share no
  cheaper way to scroll (`term` redraws every row of its grid on a scroll
  anyway). On exit the screen is cleared.
- **Where the text lives.** In far memory (the arena), moved with
  transfers; the D-LS holds one 2 KiB chunk, the line being edited and the
  screen's state. Arena [0, 512 KiB): the text, in 256 chunks of 2 KiB,
  each a run of whole lines with their newlines, in the order of a chunk
  table (store number, bytes, lines) in the D-LS; a full chunk is split
  where a line goes in, an emptied one is freed, and a small one takes in
  the next. [512 KiB, 736 KiB): the undo history, a record per change (the
  first line, the old lines and the new ones, the cursor before it); the
  oldest records go when it is full. [736 KiB, 832 KiB): the register
  (what `y d c x` took).
- **Limits.** About 500 KiB of text (a file that does not fit is cut
  short, and vi says so); lines of 1000 bytes at most (a longer one is
  split when the file is read); 96 KiB in the register; a change bigger
  than the 224 KiB history cannot be undone (the history before it goes).
  `fs` holds a file being written in 128 KiB, so `:w` refuses a bigger
  buffer before the file is touched; `/src/sh.s` (333 KiB) opens, but
  cannot be written back. Every line is written with a newline after it.
  No counts on inserts, no `f t`, no marks or named registers, no regular
  expressions.
- **In Forth.** `forth vi.fs FILE` (or `include vi.fs` at the Forth prompt,
  then `vi FILE`) is the same editor written in Strata Forth
  (`lang/forth/vi.fs`, with `vi-text.fs` and `vi-edit.fs`; the README there
  has the details): the same keys, modes, highlighting and screen; given the
  same keys it writes the same files. Its code (about 60 KiB) is several
  times a program's I-LS: like everything Forth compiles, it is in code
  units the dispatcher pages into Forth's code cache (the units above, and
  the README's "Code paging"). Its text is in Forth's far heap:
  400 KiB of text at most, 96 KiB of undo history, 48 KiB in the register;
  `.` repeats up to 64 keys. Its keyword tables come from the same generator
  (`tools/vi-syntax.py` -> `vi-syntax.fs`). Every start compiles it (about
  6 M instructions); a 333 KiB file takes about 1.3 times vi's instructions
  to open, a key in normal mode about the same.

### 2.13 Guests: co-existing OSes at whole-core granularity

StrataOS can hand a bundle of its worker cores to a **guest**: a second
operating system that runs on those cores, in supervisor mode, beside
StrataOS. The guest is not trusted. It reaches only what it was given, and
StrataOS can end it at any time and get the cores back clean. There is no ISA
change for the grant itself; two small, general ISA additions make *ending* a
guest sound (below). Code: `os/kunits/guest.s` (the kernel units), the system
endpoint ops `GSTART`/`GSTOP`/`GINFO` (`os/kunits/ops.s`), `proc` ops 40/41/42
(`os/servers/proc.s`), the `guest` shell command (`os/progs/guest.s`), and
demo/test guest images (`os/guests/`).

#### The grant

`guest [-d] <image> [cores] [MiB]` asks `proc`, which gets an arena from the
kernel (`MEMORY`), loads the guest image (a bare STX: a disk file tagged
`guest`, named `<image>` or else `<image>.g`, so `guest forth` finds
`forth.g` beside the StrataOS program `forth`) into the top of it, and calls
the kernel's `GSTART`. The kernel:

- takes N free worker cores out of its own scheduling (it chooses a run of
  cores that hold no StrataOS thread — empty cores — and marks them `CF_GUEST`
  so placement skips them and `k_wake`/`k_ring` leave them alone);
- gives the guest, through a defined boot protocol, exactly:
  - **an arena** (its memory, sized by the request), which is **one revocation
    domain**: it is cut from the pool with `cdom` and every capability derived
    from it dies when the domain is revoked;
  - **a console endpoint** to the `tty` server (read and write) — see the
    console choice below;
  - **a read-only clock** (the timer's `NOW`/`FREQ`), cut from the device root;
  - **core control over its own cores only** (`[8·base, 8·(base+N))`,
    write-only), so it can run its own workers but can never touch a StrataOS
    core;
  - **nothing else**: no KST, no device root, no core control over StrataOS, no
    endpoint to `proc` or to the kernel.

**Why a console endpoint, not the raw console device.** The raw console
*output* port is copyable and several cores already hold it, so handing the
guest a copy would be sound for output. The console *input* port, however, is
owned exclusively by the `tty` server (which is `F_SOLO` on its own core and
keeps a read in flight); a second reader would race it for keystrokes. One
endpoint to `tty` carries both directions through the channel StrataOS already
gives its own programs, with line discipline, and makes the guest no more
privileged for I/O than a StrataOS process — the simplest sound choice. The
guest talks to `tty` with raw `csend`/`ctake` on the endpoint (it is a
supervisor, so it does not use `svc`); StrataOS routes and confines those sends
(below).

#### The console: input goes to one side at a time

A guest's requests carry its guest id (240..255; process pids are 4..239) as
their pid, so the `tty` tells them apart. Output is written as anyone's.
**Input** goes to one side at a time, StrataOS's processes or one guest:

- `guest <image>` (without `-d`) starts the guest and then **attaches** the
  console to it: a tty request (`ATTACH`, op 20, handle = the guest id) that
  the `tty` answers only when the console comes back. Meanwhile only that
  guest's `READ`s are answered; the shell's `READ` waits (the shell is
  waiting for `guest` anyway). `guest attach <id>` attaches it again later.
- The console comes back to StrataOS when **Ctrl-]** is typed (the `tty`
  echoes `^]`), when the guest `CLOSE`s the console (Forth's `bye`), when the
  guest is stopped (`proc` sends the `tty` a `CLEANUP` for the guest id), and
  when the `guest` command is interrupted (Ctrl-C ends it) or ends (`CANCEL`
  / `CLEANUP` for its pid). `guest` then says how it came back.
- While StrataOS has the console, a guest's `READ` waits in the `tty` (it is
  never answered with what the shell's user types), and while a guest has it,
  StrataOS's do. The `tty` reads input only while a reader *whose side has
  the console* waits, so nothing typed for one side is read ahead for the
  other.
- Only a StrataOS process may attach the console, and only one guest has it
  at a time (`-7` otherwise). A guest cannot take it: its `ATTACH` is refused
  (`-1`), and its `READ` is answered only while the console is attached to it.

The scripted tests and `os/guest-demo.txt` start their output-only guests
with `-d` (detached), so the shell keeps the console.

#### The boot protocol

The arena is split in two: the writable low part `[0, imgoff)` is the guest's
memory (relative core 0's `c0`); the high part `[imgoff, size)` is the image
plus a small **guest platform table** and is handed to every guest core as a
read+execute share (`c5`) so each core can load its own Local Stores. The
platform table (at `size − 0x1000`, inside the shared region) holds a magic,
`corebase`, `corecount` and `imgoff`.

Each guest core is woken out of StrataOS idle by a gift — a **loader** code
unit (`u_gload`) that the kernel's dispatcher (`w_guest`) copies into the I-LS
and jumps to. First the core is **scrubbed** of everything StrataOS kept on
it, which a supervisor-mode guest could otherwise take: the loader, while the
dispatcher is still resident, empties every save-table entry (a StrataOS
worker keeps the KST, core control over *every* core, the device root and the
console output there; there is no instruction that empties an entry, so each
is taken out — a linear capability leaves its entry — and overwritten with a
copy of the read-only clock, which the guest is granted anyway) and every
capability register, and zeroes the D-LS (the dispatcher's variables and the
saved registers of processes that ran on the core) but its own scratch page.
The loader then `ctake`s, in order: the image share (`c5`), the
console endpoint (`c1`), the clock (`c2`), core control (`c3`), and — on
relative core 0 only — the writable arena (`c0`). It reads the platform table,
sets `corebase`/`corecount` (so the guest sees itself as an N-core machine,
`coreid` 0..N−1, `ncores` = N), copies the image's sections into the core's
Local Stores (and, on core 0, the image's T3 section into the writable arena),
and jumps to the image entry in supervisor mode. A multi-core guest's workers
then wait for its own core 0, exactly as a bare-metal program does.

#### Ending a guest, and the two ISA additions

`guest stop <id>` (kernel `GSTOP`) revokes the guest's arena domain — one
`crevoke`, after which **everything the guest holds or lent out is dead**
(its memory, the message buffers it lent to `tty`, any block-device buffer it
submitted) — and then **resets each of its cores** and re-provisions them as
StrataOS workers. A guest that is halted by itself (`bye`) is reclaimed the
same way: the reset un-halts the core.

Reclaiming a *supervisor-mode* core needs two things the base ISA could not
do, so two small, general additions were made to the ISA and the platform
(emulator `emu/emu.c` and its JIT, the RTL `rtl/`, the debug engine; conformance
tests `conformance/tests/reset.s` and `blkpair.s`; the guest session runs in
lockstep on the emulator and the RTL, `tools/compare-boot.sh` with
`os/guest-demo.txt`):

1. **A core-control reset request.** A `tput` through a core-control
   capability that writes a doubleword with **bit 1** set (bit 0 is the
   existing stop request) resets the target core. Unlike a stop request, a
   reset is taken *in any mode*, so a supervisor that will not yield is stopped
   anyway, also by a halted core. A reset clears the core's registers,
   capability registers and save table, inbox, overlay map, transfer tags
   (device reads still waiting are abandoned), and CSRs, reloads the boot ROM
   (the first 4 KiB of each Local Store, from the boot image; the rest of both
   stores is cleared), and restarts it at the boot ROM entry (pc 0) in
   supervisor mode with the reset capabilities — as at power-on. It runs the
   boot ROM's secondary path and waits for core 0 to re-give it the OS shares,
   so core 0 re-provisions it like any worker. Who may issue it: a holder of
   core control over that core (the same right as a stop request). The inbox
   is emptied when the request arrives, so the gifts core 0 makes after its
   `tput` reach the restarted core; in hardware the restart takes 8192 cycles
   (the Local Stores are rewritten a doubleword per cycle from a 4 KiB ROM per
   store), and those gifts wait in the inbox meanwhile.

2. **The block device pairs a buffer only with a command from the same core.**
   The device records the submitting core of each queued command and pairs it
   only with an inbox buffer whose sender is that same core; a buffer whose
   sender has no pending command is an orphan (a stray gift, e.g. from a
   hostile guest) and is returned to its sender, from the device's node,
   rather than slipped under another core's command; a buffer always goes back
   to the core that lent it (the command's old "reply core" byte is ignored).
   A gift to the device waits for the giver's earlier device writes, so a
   command and its buffer always meet. This closes the one receiving-side channel a
   supervisor guest could otherwise abuse: without it, a guest could `cgive` a
   buffer into the block device's queue and have it paired with `fs`'s next
   command, corrupting `fs`'s I/O.

#### The isolation argument, and its limits

What a guest can *reach* is bounded by the capabilities it holds: a revocable
arena, a `tty` endpoint, a read-only clock, and core control over its own
cores. It holds no capability to any other memory, core or device, and no
instruction forges one, so every out-of-grant access faults
(`os/guests/ghostile.s` tries several and each is refused; it also checks that
no capability register but its grant holds anything and that every save-table
entry is empty or a copy of its clock — before the scrubbing above it found
the KST in c9, and core control over every core and the device root in the
save table).

What a guest can *send* is not bounded by its capabilities alone, because a
supervisor-mode `cgive` reaches any core's inbox and `cmkep` mints an endpoint
to any node. StrataOS therefore confines the guest on the **receiving** side:
a worker's dispatcher and core 0 drop everything arriving from a guest core
except a 4 KiB request to a server the guest was explicitly given (`G_GALLOW`),
and accept at most one such request outstanding (`G_GOUT`), so a guest can
never make a StrataOS core wait on its full inbox; the sender pid stamped on a
request is taken from the buffer's arena by the receiver, so it cannot be
forged; and the block-device rule above closes the device channel. Revoking
the arena kills every buffer the guest lent to a server, so a server holding a
guest's request when the guest is killed simply finds a dead capability.

**Known limit (availability, not integrity).** The block device gives an
orphan back by an ordinary gift, and a gift waits for room in the receiver's
inbox (two per sender). A guest that sends the device three orphans and never
takes them back therefore stalls the device until it does, or until StrataOS
stops it (the reset empties its inbox and the device carries on). It cannot
corrupt anyone's I/O this way, only delay it; dropping an orphan the lender has
no room for would close this, at the price of one more device rule.

**Known gap (user mode is not bounded in the Local Store).** Neither the
emulator nor the RTL checks the privilege mode on D-LS loads/stores or on the
Local-Store ranges of `tget`/`tput`/`tgetx`. A StrataOS *user* program can
therefore read or write the dispatcher's own area (D-LS `0xA000..0xDFFF`:
thread records, saved registers) and overwrite the dispatcher's code in the
I-LS with `tgetx` — i.e. take over its core in supervisor mode. This gap is
*within* a core, between StrataOS's dispatcher and the user programs that share
that core. It does **not** apply between StrataOS and a guest, because a guest
gets *whole cores*: there is no StrataOS dispatcher on a guest's core to
corrupt, and the guest cannot reach any other core's Local Store (it has no
far capability to it, and its `cgive`s are filtered on arrival). So a guest can
do anything it likes *inside its own cores and its own arena* and nothing
outside them; it cannot read or write StrataOS's memory, drive StrataOS's
devices, disturb StrataOS's cores, or outlast a `GSTOP`. The within-core grain
— a guest OS confining its *own* user-mode children on a shared core — is the
next step, and needs the Local-Store protection discussed in the design notes
(per-LS user-window bounds; see the report).

#### Forth as a guest

The bare-metal Strata Forth runs as a guest unchanged but for a small platform
layer, `lang/forth/guest/` over `lang/forth/bare/` (lang/forth/README.md, "As
a guest"): `guest forth 2 16` boots `forth.g` on 2 cores with a 16 MiB arena
and gives it the console. Its stub moves the granted capabilities to the
bare-metal places (console endpoint c2, clock c3, core control c4); plat_init
cuts the arena into the kernel's MiB, message buffers, the job board (made
atomic; there is no cluster store), worker pages and the far heap; `key` and
`emit` are tty `READ` (cooked: the tty echoes and edits) and `WRITE` sent by
hand (`csend c5, c2`, then `crecv c5, c2`, which takes only from the tty's
node, so a worker's doorbell is not mistaken for the answer), one 4 KiB buffer
per core as the receive-side filter wants; `ms` watches the clock's `NOW`;
`bye` closes the console and halts. The multicore words, `demos/multicore.fs`
and `demos/tiers.fs` run on its own cores; `demos/gfx.fs` cannot (no
framebuffer, no device space), nor can files or the network.
`tools/test-guest.sh` runs a session (arithmetic, a word on the worker,
multicore.fs, Ctrl-], `guest attach`, `bye`, `guest stop`, the cores reused).

#### Visibility

A guest's cores show in `cores` (and `ps`) as a guest's: they carry the
`CF_GUEST` flag and run no StrataOS pid. `guest` with no arguments (or
`guest list`) lists the running guests — id, cores, arena size, state — through
`proc` op 42 / kernel `GINFO`.

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
  progress; `ps` shows context switches. `tools/test-isolate.sh`: nothing
  one process leaves in its core's D-LS is visible to the next (2.2). `tools/test-boot-jit.sh`: the
  demo session three times under the JIT's coarser interleaving.
  `tools/test-guest.sh`: guests (2.13): a benign one, a hostile one (its
  attacks refused, nothing of StrataOS's left on its cores), and the Forth
  guest's session with the console attached, Ctrl-], `guest attach`, `bye`
  and `guest stop`; `os/guest-demo.txt` is a guest session on the emulator
  and the RTL in lockstep (`tools/compare-boot.sh`).
- `tools/test-fb.sh`: frames written with `-F` are byte-identical on the
  emulator and the RTL. `tools/test-jit.sh`: the JIT against the
  interpreter. `conformance/run.sh`: the conformance suite on the
  interpreter, the JIT and the RTL (`net`: the network interface on the
  loopback link).
- `tools/test-net.sh`: TCP/IP. One machine with the test peer (`-N
  peer,nodns`, `-j -T virtual`): ping over loopback and to the peer, TCP
  through `tcpecho` (a 300 KB file compared with itself), UDP, a refused
  connection, `netstat`, DNS (names, a CNAME, two addresses, no such name,
  the second resolver when the first does not answer, none answering),
  compared with `tools/test-net.out`; two emulators linked over host UDP:
  ping, TCP both ways, UDP; and the NAT offline, against TCP and UDP echo
  servers on 127.0.0.1 (`tools/net-echo.py`): TCP both ways with a 300 KB
  file, UDP, RST, three inbound connections through `fwd=`.
  `tools/test-wasm.sh` also runs StrataOS in the WebAssembly build with
  the page's DNS over HTTPS (a stubbed fetch) and through `tools/netrelay`.
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
- `tools/test-vi.sh`: the editor. A scripted session (`-j -T virtual`)
  edits files with inserts, motions, counts, operators, yank and put,
  undo, redo and `.`, searches, `:w NAME`, `:q!`, `:e`, options, a file
  bigger than the whole D-LS (`seq 15000`: 77 KiB) and the 333 KiB shell
  source; the files it wrote (`cat`, `wc`, `grep`), with vi's screens
  taken out, are compared with `tools/test-vi.out`, and the screens are
  checked for the SGR colours of an `.s` and an `.fs` file (a Forth `(`
  comment carried over a line). A second boot sends Ctrl-C (`-b`) while
  vi runs: it carries on. `tools/vi-shots.sh` (not run by `make test`)
  takes pictures of vi in the window server's terminal:
  `build/vi-shots/asm.png`, `forth.png` (`-f`: of `forth vi.fs`,
  `fs-asm.png`, `fs-forth.png`).
- `tools/test-vifs.sh`: the Forth editor (`forth vi.fs`) with the keys of
  `tools/test-vi.sh`; the files it writes are compared with
  `tools/test-vifs.out` and with `tools/test-vi.out` (the assembly vi's:
  they must be the same files), then the highlighting, a Ctrl-C while it
  runs, and `vi FILE` at the Forth prompt after `include vi.fs`.
- `tools/test-fs-progs.sh`: the Forth ports of the programs (`forth
  seq.fs 20`, ...) against the assembly programs in one session: 36 cases
  must give the same bytes on the console, 10 status reports (ps, cores,
  uptime, ...) are compared with `tools/test-fs-progs.out`, numbers masked;
  then a Ctrl-C and the ports at the Forth prompt.
- `tools/test-as.sh` (run on its own, not by `make test`): the self-hosted
  assembler against `sasm`, including a StrataOS boot that assembles and
  runs a program.
- 
