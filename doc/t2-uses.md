# Designing for T2: uses that change how software is written

Status: proposal; the console rings of 4.1 (in T2) and the ring part of
4.2 are built, the rest is not. Written 2026-11-14. Builds on
`doc/t2-proposal.md` (what T2 holds and carries, measured; the ownership
models A to D; the T2 lane and finer granules), which this document does
not repeat.

## 1. Summary

- `doc/t2-proposal.md` showed that moving existing data into T2 saves at
  most 0.4% to 4.1% of a session's *bus* time: what is left in T3 is bulk.
  That is the wrong yardstick for the uses here. A message round trip
  costs 33,100 RTL cycles to an idle server on another core and 72,300 for
  an `fs` STAT (`doc/code-loading-proposal.md` 2.4); its bus part is a few
  hundred cycles. The cost of interaction between programs, servers and
  cores is **traps and dispatcher passes**, not transfers.
- A far atomic in T2 holds the bus for 7 cycles. A protocol of a handful
  of far atomics (a ring, a flag, a sequence number) moves a small request
  or a line of output between two running cores for some 50 to 100 bus
  cycles and a few hundred core cycles: **one to two orders of magnitude
  less than a message**. That is where T2 can change how software is
  written: small, frequent interactions go through shared words, and
  messages stay for what needs the kernel (capabilities, lending memory,
  blocking).
- Counted in the shell session (`os/demo.txt`, 12 cores): 1,658 requests
  to servers and about 90 to the kernel. **1,086 (65%) go to `tty`: 470
  WRITEs of about 26 bytes, 416 READs, the rest process control.** Each
  costs its sender at least 33,000 cycles of waiting, and four dispatcher
  passes (about 190 KST atomics, 1,300 bus cycles: round trips account for
  more than half of the session's KST traffic).
- Most of these protocols work in T3 as well, today, with no kernel
  change: a process can `catomic` a piece of its own arena and share it,
  and the revocation of its arena takes every copy back. In T3 an atomic
  holds the bus for 23 cycles instead of 7. **T2's part is a factor of
  about three on the protocol's bus cost, which matters most for polling;
  the factor of a hundred comes from the protocol.** Prototype in T3,
  move to T2.
- What stands between these designs and T2 is the same three things for
  every one of them: who owns a piece of T2 and how it comes back (one
  granule: section 3.1), how a core waits for a word without spinning on
  the one shared bus (3.2), and how bytes rather than words cross an
  atomic segment, read-only for some parties (3.3).
- **Recommendation** (section 6): a small channel library over atomic
  segments, prototyped in T3; console output through per-process rings
  drained by `tty` (no ISA change, the largest single gain); a per-process
  T2 cell taken back by confinement in the dispatchers (model E, no ISA
  change); then, if the measurements hold, one ISA addition, a watch on a
  T2 word that `tany` can wait for.

## 2. Costs used here

| Event | Cost | Source |
|---|---|---|
| T2 atomic, bus held | 7 cycles (T3: 23) | `doc/t2-proposal.md` 2 |
| T2 atomic, latency on a busy bus | some 50 cycles of waiting behind T3 bursts on average, an estimate (T3: the same wait + 16) | `doc/t2-proposal.md` 4.3 |
| burst of n bytes | T2 4 + n/8, T3 20 + n/8 | same |
| trap, entry to `eret` | 14,700 to 16,500 RTL cycles (cores 3/5/6) | `doc/strataos.md` 2.2 |
| message round trip, idle server on another core | 33,100 (18,900 with the stream fetch) | `doc/code-loading-proposal.md` 2.4 |
| the same, server on the caller's core | 61,500 | same |
| `fs` STAT of a missing name, another core / `fs`'s core | 72,300 / 101,800 | same |
| KST atomics per dispatcher pass | about 47 | `doc/t2-proposal.md` 4.4 |

Two consequences shape every design below:

- **Latency against occupancy.** On a busy bus a T2 atomic waits about as
  long as a T3 one (the wait is for whatever burst holds the bus), so T2
  buys a latency difference of about 25%, not 3x. What T2 does buy is
  occupancy: the bus is held 7 cycles instead of 23, and with one
  transaction at a time system-wide, that is time taken from every other
  core. With a T2 lane of its own (`doc/t2-proposal.md` 5.10) the wait
  goes too and a T2 atomic's latency drops to about 10 cycles: every
  protocol here gets five to seven times faster than in T3.
- **Spinning is expensive for everyone.** A core polling one T2 word in a
  tight loop issues an atomic every 13 cycles or so and holds the bus
  more than half of the time (in T3, about 80%). Two spinners saturate
  it. A poller must back off (one poll every 500 cycles is 1.4% of the
  bus in T2, 4.6% in T3) or sleep until the word changes (3.2).

The shell session's requests, from `strata-emu --bus-stats` (the
dispatcher's stamp of the sender's pid into each request, by server
core):

| Server | Requests | Mostly |
|---|---|---|
| `tty` | 1,086 | 470 WRITE (about 26 bytes), 416 READ, ~200 CLEANUP, SETFG, CONMODE |
| `fs` | 242 | OPEN, READ, STAT, LOADIMG |
| `pipe` | 198 | READ and WRITE of pipes |
| `proc` | 127 | SPAWN, WAIT, the registry |
| kernel (core 0) | about 90 | MEMORY, CREATE, INFO |
| `dev` | 5 | |

The other sessions' message transfers (`doc/t2-proposal.md` 4.2: window
server 19,567, `cc` 11,702, Kira 3,022) suggest some 3,300, 2,000 and 500
requests at the shell session's six transfers per request; not counted
per server.

## 3. What every design needs

### 3.1 Owning a piece of T2, and taking it back

T2 is one revocation granule, so a piece lent to a process cannot be
revoked alone (`doc/t2-proposal.md` 5.9, 6). Shared words need copyable
capabilities (`catomic` gives `A`+`D`), and a copyable capability can be
passed on. Four ways to make per-process T2 safe to reuse:

- **T3 stand-in (today, no change).** The process cuts a piece off its own
  arena, `catomic`s it and hands copies to its threads or to a server as
  an attachment. Every copy is revocable with the arena: when the process
  ends, the kernel's revocation kills them all, and a server's next atomic
  through one faults, exactly as a dead client's message buffer does
  today (`srv_guard`). This is the model to copy.
- **E. Confinement by the dispatchers (new, no ISA change).** A capability
  moves between cores only through an inbox, and every inbox is taken by
  a dispatcher (user mode cannot `ctake`, 2.0 of `doc/strataos.md`);
  `csave` is privileged. So the kernel can know every place a T2
  capability of a process can be: that process's registers and its save
  slots, and the inboxes it was sent to. The rule:
  - the kernel keeps a holder table for user T2 (in the KST: per slot of,
    say, 256 bytes, the pids allowed to hold it);
  - `svc` T2_GET gives a process a slot (an atomic capability, cut from
    the dispatcher's own capability for the pool), `svc` T2_SHARE adds a
    pid as a holder; the process then sends the capability with an
    ordinary message or reply;
  - a dispatcher demultiplexing its inbox drops (`cclear`) any T2
    capability whose slot does not list the receiving process (rule 6 of
    2.3 gains one test); like device capabilities, a thread's T2
    capabilities in c0..c7 are described on switch-out and cut again on
    switch-in, so they take no save slot;
  - when a process ends, it is removed from the table; a slot with no
    holder left is free. No copy can exist outside its holders, so none
    survives them.
  It costs a few dozen instructions on the receive path and an allocator.
  Its limit: the integrity of the shared words against a hostile holder
  is not given, but the Local Stores already give none against a hostile
  program on the same core (2.2 of `doc/strataos.md`).
- **D'. Finer T2 granules (ISA).** As `doc/t2-proposal.md` 5.9, but sized
  for this use: 1 KiB granules give T2 256 entries, as many as T3's table
  has, and every arena can take a 1 KiB **T2 cell** that is revoked with
  it (136 KiB free: 136 processes, more than the 64 the tables allow). It
  removes model E's table and filter; it costs the granule table's size in
  every core and the proofs.
- **B. A fixed range for a server's life** (`doc/t2-proposal.md` 6), for
  what a server publishes and never takes back.

### 3.2 Waiting for a word

Three ways, cheapest in hardware first:

- **Spin, then block** (no change). Poll with backoff for a bounded time,
  then set a "sleeping" flag in the channel, check once more and block in
  the kernel (an existing wait). The other side reads the flag after
  publishing and, only if it is set, wakes the sleeper with one `svc`
  (its dispatcher writes the sleeper's core-control word, as a send does
  now). The fast path has no trap; the slow path costs about what a
  message costs now.
- **Poll at a known moment** (no change). A consumer that has a natural
  beat checks its rings then: `tty` on every wake and every tick, `ws` once
  per frame. Output latency becomes at most a tick (2 ms), which is fine
  for a console and free for a compositor.
- **W. A watch on a T2 word (ISA, small).** A core arms one T2 doubleword
  (an instruction taking a capability that covers it, `R` or `A`), and
  `tany` gets an event bit "the watched word was written". Since exactly
  one transaction is on the far bus at a time, each core needs one
  comparator on the bus's address and write strobe; no coherence. In the
  dispatcher's idle `tany`, it lets a client wake an idle server's core
  with one atomic instead of a `svc` and a core-control write; and core 0
  could sleep until a worker publishes instead of polling the KST (595,000
  of its atomics in the window-server session, about 1% of that session's
  bus). It is timing-visible state, like `tany` and `tpoll` already are
  (Theorem 2, condition c).

### 3.3 Moving bytes through shared words

An atomic segment is reachable only with `tamo`, 8 bytes at a time, and
every holder can write it. That is fine for words, flags and short
records (a 64-byte record is 8 atomics, 56 bus cycles), and has two
limits:

- **No read-only sharing of mutable data.** A server cannot publish a
  table that clients read but cannot write: `cshare` consumes the writer
  for good, `catomic` lets everyone write. **O, an observe permission
  (ISA, small):** `crestrict` of an `A` capability to `O`, which allows
  only atomic reads (and, with the next item, short reads). The writer
  keeps its `A` copy. Same nondeterminism class as atomics.
- **No bulk.** **Short atomic bursts (ISA, medium):** `tget`/`tput` of up
  to 64 aligned bytes through an `A` (or `O`, reading) capability on T2,
  single-copy atomic. The bus already makes every burst indivisible; the
  ISA would promise it. A record then crosses in one transaction (12 bus
  cycles instead of 56), and a seqlock is not needed for records of up to
  64 bytes.

Bulk data (file blocks, bands of pixels) keeps the existing path: a lent
linear capability, which is what messages are good at.

**In T2, fine grain is free.** A burst's start-up in T2 is half a 64-byte
record; in T3 it is two and a half. Ten 400-byte reads cost 540 bus
cycles in T2 against 516 for one 4 KiB read; in T3, 700 against 532. So
"turn many small transfers into one" is advice for T3. In T2 a program
can chase pointers (an index tree, a hash chain, linked records) at
little extra cost, and short bursts also shorten the time an atomic
waits behind them.

## 4. Uses

Gains are per event and, where counted, for the shell session. "Waiting"
is time a client spends blocked on a reply: core time, not bus time, and
not all of it on a session's critical path.

### 4.1 Console output through rings (`tty`)

- **Now:** every `sys_write` to the console is a message to `tty` and a
  wait for its reply: 470 in the shell session (of 1,086 requests to
  `tty`), about 16 M cycles of waiting, plus four dispatcher passes each.
- **Design:** each process that writes to the console gets a ring of, say,
  256 to 1,024 bytes in T2 shared with `tty` (head and tail words, data in
  words). A write copies its bytes into the ring with atomics and returns;
  only a full ring blocks (spin, then a WRITE message as today, which
  `tty` answers once it has drained). `tty`, alone on its core, drains the
  rings when it wakes (any request, a tick, or with W the ring's tail
  word). Ordering: before `tty` acts on any message of a process (a READ, a
  mode change, its exit), it drains that process's ring, so a prompt is
  always out before the read that follows it. Ctrl-C drops the
  foreground process's ring.
- **Gain:** a 50-byte write becomes about 10 atomics: 70 bus cycles and a
  few hundred core cycles instead of 33,000; in the shell session, about
  16 M cycles of writers' waiting, about 1,900 dispatcher passes and
  90,000 KST atomics (0.6 M bus cycles, 4% of the session's bus;
  measured below: -14% to -17% of the KST atomics).
  In T3 the ring costs 230 bus cycles per write, still a hundred times
  cheaper than the message.
- **Ownership:** the ring is the writer's (T3 stand-in: a piece of its
  arena, attached to an OPEN-RING request; T2: model E or a T2 cell),
  revoked when it ends. `tty` holds a copy per client: at most 64.
- **ISA:** none (`tty` drains at a tick at worst). W makes output
  immediate without a tick.
- **In `os/`:** `sys.s` (the write path, a flush before reads and at
  exit), `tty.s` (ring table, drain points, OPEN-RING), the kernel for T2
  (model E).
- **Risk:** output semantics: `write` returns before the bytes are on the
  console; a program killed with output in its ring loses it unless the
  exit path drains it. Guests keep the message path.

- **Built.** First in T3, from `tty`'s memory, handed out with a WRITE's
  reply; then in T2, given to each program at its start
  (`doc/strataos.md` 2.3, "Console rings"). Differences from the design
  above: a program has no capability register that survives a switch and
  is free (c0..c7 are spoken for, c8..c15 are lost), so the ring lives in
  c6 and is checked before every use; a reply's attachment replaces it,
  and the next WRITE by message brings it back. The rings are the
  kernel's, one per arena slot, after the KST in the KST's atomic segment
  (model A for the memory, model B for `tty`, which gets all of them once
  through `dev`); a copy that outlives its process can do nothing a
  program cannot do anyway. The dispatcher's change fits in the resident
  code's last 24 bytes by reusing the framebuffer-piece branch of the job
  code, which no longer had a use.
- **Measured.** RTL, 8 cores, a 50-byte write, the writer's cycles:

  | | by message | ring in T3 | ring in T2, given at start |
  |---|---|---|---|
  | cycles per write | 37,134 / 35,353 | 2,134 | 1,995 |

  (the message column for each build). Shell session (emulator, 12
  cores): WRITE messages to `tty` 470, then about 20 (T3), then 5 (T2:
  outputs longer than a ring); all requests to `tty` 1,086, 639, 624: the
  rest are READs (416) and process control (CLEANUP at every exit, SETFG,
  CONMODE). KST atomics -14% to -17% (fewer dispatcher passes). The
  rings' own atomics: 8,725 in T3 (201,000 bus cycles), 23,836 in T2
  (167,000): `tty` reading one HEAD per ring handed out on every look,
  and setting all 64 SLEEP words when it sleeps, makes three times as
  many atomics, which T2's lower start-up latency more than pays for.
  An earlier reading of the T3 figures, that the requests left were
  first writes, was wrong: they were READs and control.
- **Found on the way:** the debugger named one of two labels at the same
  address by the order `qsort` happened to leave them in; it now keeps
  file order (`emu/debug_sym.c`).
- **Found on the way:** the system core gave a new process's arena pieces
  to its core before ringing that core's doorbell. An inbox holds two
  gifts from one sender, so with a busy single thread on the core (one
  that makes no calls) the third gift held the system core, and the whole
  machine, until that thread called the kernel. Fixed in `u_launch`'s
  path (`os/kunits/ops.s`): the doorbell goes before each gift.

### 4.2 A channel library

- **Design:** `os/lib/chan.s`: single-producer single-consumer rings of
  words and of short records over an atomic segment, with the
  spin-then-block protocol of 3.2 built in; creation from a piece of the
  process's arena (T3) or a T2 slot. It is the base for 4.1, 4.3 and 4.4,
  and on its own a fast path between the threads of a multi-threaded
  process, which today hand each other capabilities with `cgive` and an
  emulated `ctake` (a trap on the receiving core).
- **Gain:** a word between two running threads in about 5 atomics, 35 bus
  cycles in T2 (115 in T3), against a trap. No measured session has
  multi-threaded programs; `examples/` (`parsum`, `pipeline`, `mandel`)
  are the test cases.
- **Ownership:** the process's own (T3 today, its T2 cell later).
- **ISA:** none. **Effort:** small. **Risk:** low; timing-visible, so a
  program that uses it gives up Theorem 2's determinism unless it orders
  its uses (a single producer and a single consumer per ring keep the
  history of each ring deterministic).

### 4.3 Small requests without the kernel (user-level calls)

- **Design:** a client and a server share a request ring and a reply word
  (in the client's memory, as 4.1). The client posts a short request and
  waits for the reply word; the server takes requests from its rings
  between messages. Messages remain for anything with a capability
  attached, and for blocking operations that park.
- **Candidates:** `pipe` (198 requests; better still, 4.4), `proc`'s queries
  (the registry, `ps`), `fs` STAT and OPEN of a name in its cache.
- **Gain:** depends on whether the server is running. Running (busy, or
  spinning briefly after its last request): a round trip of about 20
  atomics plus the work, about 1,000 cycles against 33,000 to 72,000.
  Idle (blocked in RECEIVE): someone has to wake its core. Without W, the
  client's `svc` and a core-control write, then the server's dispatcher:
  about half of today's cost. With W, the dispatcher's idle `tany` wakes on
  the ring itself: the client takes no trap, the server's core one pass.
  For the shell session's 567 requests to `proc`, `fs` and `pipe`, roughly
  5 M to 15 M cycles of waiting.
- **Ownership:** as 4.1.
- **ISA:** none needed; W decides how large the gain is when servers are
  idle, which they mostly are.
- **Effort:** medium to large: a second request path in each server, kept
  equivalent to the first. **Risk:** medium: two paths to keep in step,
  ordering between a client's ring and its messages (the same drain rule
  as 4.1).

### 4.4 Pipes as rings between the two processes

- **Design:** `pipe` sets a pipe up and tears it down; the data goes
  through a ring shared by writer and reader directly (a 4.2 ring of
  records), with spin-then-block on full and empty. `pipe` handles only
  the cases that need it (a reader of an empty pipe whose writer is gone,
  more than one reader or writer: the message path).
- **Gain:** a pipe transfer today is two round trips (writer to `pipe`,
  `pipe` to reader), over 66,000 cycles; through a ring, a few hundred
  cycles of atomics per line. In the shell session 198 requests.
- **Ownership:** the ring belongs to the pipe; with model E, both ends are
  holders and it is free when both have ended (the T3 stand-in needs one
  side's arena: the reader's, so a reader's death frees it, and a writer
  then gets a fault where it would get a broken pipe).
- **ISA:** none. **Effort:** medium. **Risk:** medium (shell redirection,
  `dup`, a pipe passed to a child).

### 4.5 Published records: read by many, written by one

- **Design:** a server or the kernel keeps a small table in T2 that
  everyone may read and only it writes: the kernel's per-core and per-pid
  statistics (the KST's own words, read today by `ps`, `cores`, `uptime`,
  `sched` and drawn by `ws` through INFO messages), `proc`'s process table,
  `fs`'s metadata of hot names, the database store's roots. Records of up
  to 64 bytes, or a sequence word per record (written odd, then the
  record, then even).
- **Gain:** a STAT or an INFO from 33,000 to 72,000 cycles to a few hundred.
  How often these happen is not counted yet: the shell session's `fs` and
  kernel requests bound it (242 and about 90); `ws` asks for statistics
  for its core lattice regularly.
- **Ownership:** model B (the publisher's range for the machine's life) or
  A (the KST); readers are never revoked, so only what may stay readable
  forever goes there.
- **ISA:** O (3.3) is required: giving the KST, or `fs`'s table, to every
  program as an `A` capability would let any of them write it.
  Short atomic bursts make records one transaction.
- **Effort:** medium; **risk:** low once O exists.

### 4.6 Validation words for client caches

- **Design:** a server keeps a generation word per object (a directory, a
  file, the registry); a client keeps the answers it got (a STAT, a
  directory listing, a registry lookup, a small file's contents) and
  before using one reads the word: one atomic instead of a request.
- **Gain:** a cache hit costs one atomic. Kira's `fs` traffic (133,523
  short transfers, 12% of its bus) and `nav`/`ls` listing a directory
  again are the candidates; not counted per request.
- **Ownership and ISA:** as 4.5 (with `A` capabilities, a program could set
  a word back and make other clients use stale answers: O is needed).
- **Effort:** medium, mostly in the clients (`sys.s` for STAT and the
  registry). **Risk:** medium: every cached answer is a consistency
  argument.

### 4.7 The window server's frame handshake

- **Design:** clients that redraw every frame (`wclock`, `wmandel`,
  `wdoom`, Kira) publish "frame N ready" in a word, and `ws` reads the
  words once per frame instead of receiving a request for each; TEXT of a
  terminal window goes through a 4.1 ring. Bands of pixels stay lent
  (DAMAGE): they are bulk and linear.
- **Gain:** the window-server session's messages (about 3,300 requests,
  estimated) less those that carry a band; the frame rate of `wdoom` and
  Kira is bound by their round trips per frame. To be counted per
  operation first.
- **Ownership:** as 4.1; `ws` is not a boot server, so its copies must
  die with it (T3 stand-in or E).
- **ISA:** none. **Effort:** medium. **Risk:** medium.

### 4.8 The file server's index in T2

`doc/t2-proposal.md` 5.4 and 5.5, seen from 3.3: an index (the store's
roots and upper pages, a name hash) kept as small linked records in a
fixed T2 range (model B) is read in short bursts at little extra cost,
and is the natural thing to publish (4.5) once O exists. Up to 2.7% of
Kira's bus; the larger gain would be STATs answered without `fs` (4.5).

### 4.9 Not recommended

- **Locks between cores or processes.** A lock holder that is switched out
  leaves its waiters spinning on the one bus. Single-writer rings,
  sequence words and published records need no lock.
- **Message buffers or headers in T2** (`doc/t2-proposal.md` 5.1): 16 cycles
  of a 33,000-cycle round trip.
- **Shared counters as a new use:** the KST holds them already; the
  statistics are published (4.5), not moved.
- **Polling from many cores without W or backoff:** see section 2.

## 5. Ranked

| # | Use | Gain | Effort | Risk | ISA / hardware |
|---|---|---|---|---|---|
| 1 | Console output rings (4.1), built | WRITE messages 470 to 5 in the shell session, KST atomics -14%; 18x per write on the RTL | medium | medium (output semantics) | none; W optional |
| 2 | Channel library (4.2) | a word in 35 bus cycles instead of a trap; the base of 1, 3, 4 | small | low | none |
| 3 | Per-process T2 by confinement (model E, 3.1) | lets 1 to 4 move from T3 to T2: 3x less bus per atomic | medium (kernel) | medium (a new rule on the receive path) | none |
| 4 | Pipes as rings (4.4) | 66,000 cycles per transfer to hundreds | medium | medium | none |
| 5 | Watch on a T2 word (W, 3.2) | servers woken without a trap; no polling; core 0 stops polling the KST | small | low | ISA (tany event) + RTL comparator |
| 6 | Small requests without the kernel (4.3) | 33,000 to 72,000 cycles to about 1,000 when the server runs; needs 5 when it is idle | medium-large | medium | none; W for full gain |
| 7 | Observe permission O (3.3) and published records (4.5), validation words (4.6) | STAT, INFO, registry lookups in a few hundred cycles; counts unknown | medium | low-medium | ISA (one permission) |
| 8 | Frame handshake with `ws` (4.7) | not counted yet | medium | medium | none |
| 9 | Short atomic bursts (3.3) | a record in 12 bus cycles instead of 56 | medium | medium | ISA |
| 10 | Finer T2 granules, 1 KiB (D', 3.1) | replaces model E's table and filter | medium | medium | ISA + RTL |
| — | T2 lane (`doc/t2-proposal.md` 5.10) | every protocol here 5x to 7x lower latency than in T3 | medium | medium | hardware |

## 6. Recommendation

1. **Write the channel library (2) in T3 first**, from the process's own
   arena, and measure on the RTL what a word, a record and a round trip
   through it cost, against `cgive` and against a message. No kernel
   change, so this settles the numbers in section 4 before anything else
   moves.
2. **Console output rings (1)**, still in T3: the largest single gain in
   the measured sessions, in one server and the library. Decide the
   output semantics first (question 3). Done (4.1), in T2: 18 times
   cheaper per write on the RTL, WRITE messages in the shell session from
   470 to 5; output is buffered until the next request, the process's
   end, or `tty`'s next look (at most 500 µs while output flows).
3. **Then model E (3)**, to move the rings into T2, and measure the
   difference against T3: it is the T2-specific step, and it is worth
   doing only if the bus occupancy measured in 1 and 2 matters.
4. **Count before 4.5 to 4.7:** STATs, INFOs and registry lookups per
   session, and the window server's requests by operation (the
   `--bus-stats` stamp count of this document, extended with the
   operation word).
5. **ISA: W first, if anything.** It is the smallest addition, and it is
   what turns 4.3 from "faster when the server is busy" into "faster",
   while also ending core 0's polling. O next, only if 4.5/4.6 show the
   counts. Finer granules only if model E proves awkward.
6. Leave to the other work under way: the dispatcher's KST atomics per
   pass, arena scrubbing, device-read retries. Fewer round trips (1, 4, 6)
   also mean fewer dispatcher passes, so the two gains overlap.

## 7. Questions

1. **A second path beside messages.** Is it acceptable that small,
   frequent interactions (console output, pipes, queries) go through
   shared words, with messages kept for capabilities and blocking? It
   changes the OS's one-interface shape and makes those paths
   timing-visible (outside Theorem 2).
2. **Ownership:** model E (the dispatchers confine T2 capabilities, no ISA
   change), or 1 KiB T2 granules (ISA) so that each arena carries a T2
   cell?
3. **Console output semantics:** may `write` return before the bytes are on
   the console (buffered, flushed before reads and at exit), and may
   Ctrl-C drop what is still buffered?
4. **ISA appetite:** the watch (W), the observe permission (O), short
   atomic bursts. Any, all, or none for now?
5. **T3 first:** is prototyping in T3 (where ownership is already solved)
   and moving to T2 later acceptable, given that the measured difference
   may then turn out small without the T2 lane?
6. **Threat model:** shared words can be corrupted by any holder. Model E
   limits holders to the parties of a channel; is that enough, or must a
   server never trust a shared word it did not write (validate
   everything it reads from a ring)?

## Appendix: counting requests per server

With `strata-emu --bus-stats FILE` (`tools/busstats.py`'s format), the
dispatcher's stamp of the sender's pid is a supervisor `tput` of 8 bytes
through a 4 KiB capability at one pc, issued on the server's core:

```
build/strata-emu -c 12 -j -g none -T virtual --bus-stats /tmp/demo.txt \
  -d /tmp/d.img -i os/demo.txt build/bootrom.stx
awk '!/^#/ && $2==0 && $8=="1000" && $10/$9==8 && $5==1 {n[$1]+=$9}
     END {for (c in n) print c, n[c]}' /tmp/demo.txt
```

(cores 1 `proc`, 2 `dev`, 3 `fs`, 4 `tty`, 5 `pipe` in that session; core
0's line is the kernel's own 8-byte writes, not requests). The kernel's
requests are estimated from core 0's supervisor `tget`s of 64 bytes
through 4 KiB capabilities (about 90, two per request in its code-cache
slots).
