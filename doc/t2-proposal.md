# T2, the cluster store: what StrataOS does with it, and what it could do

Status: proposal, nothing implemented beyond a measuring counter
(`strata-emu --bus-stats`, `tools/busstats.py`). Written 2026-11-14.

## 1. Summary

- **What T2 holds.** On the default machine (256 KiB): the kernel shared
  table (KST, 32 KiB reserved, about 10 KiB of it ever touched) and the
  copy of the kernel's code units (88 KiB, not the 64 KiB `strataos.md`
  says: the far image has grown). 136 KiB (53%) is never touched. On the
  FPGA size (64 KiB): the KST only; the units do not fit and 32 KiB is
  unused.
- **What T2 does.** It carries 24% of the memory bus time of a shell
  session (the emulator's count; 18% on the RTL), and almost all of that
  is far atomics on the KST (554,000 of them). Those
  atomics in T3 would cost 8.9 M more bus cycles: the KST in T2 already
  takes a third off the session's bus time. The unit copy saves 0.06%.
- **What T2 can still do, as the machine is built.** T2 and T3 are on the
  same far bus, which carries one transaction at a time at one 8-byte beat
  per cycle for either; the only difference is the start-up latency (4 bus
  cycles against 20, so 16 saved per transaction, and 16 per atomic). The
  T3 transactions that are left are almost all bulk (switches, arena
  scrubbing, code, the framebuffer): moving *every* non-framebuffer T3
  transaction of the measured sessions into T2 would save 0.4% to 4.1% of
  their bus time. No candidate in the list is worth an ISA change on that
  gain.
- **Where the gains are.** (a) Fewer KST atomics per dispatcher pass (about
  47 now, most of them publishing values that have not changed): 15% to
  20% of a shell session's bus time, no ISA or hardware change. (b) If T2
  is to be more than a low-latency corner, it needs its own lane on the far
  bus (a hardware change, not an ISA change): atomics stop waiting behind
  T3 bursts (an estimated 10% to 15% off a trap), and T2 becomes a second
  memory channel, so bandwidth users (save areas, code) become worth
  moving. (c)
  On the FPGA board, where T3 is DDR3 at one DRAM access per beat, T2 is
  the only fast far memory, and the 32 KiB left there should hold the
  hottest kernel units.

## 2. How T2 is reached

From the manual (`ch-impl.tex`, far bus and targets) and `rtl/strata_bus.sv`:

- One far bus for every master (each core's Transfer Unit and atomic unit,
  the block device's DMA). **Exactly one transaction is in flight
  system-wide**: a T3 burst holds the bus for all other cores too.
- A memory burst costs the target's start-up latency, then one beat (8
  bytes) per cycle: T3 20 + n/8, T2 4 + n/8. An atomic is about 23 in T3,
  7 in T2.
- So T2 is not faster for bulk: a 4 KiB transfer is 532 cycles from T3 and
  516 from T2 (3% apart); a 48 KiB save area 6,164 against 6,148. It is
  three times faster for an atomic and up to five times for a one-word
  transfer.
- T2 is a single revocation granule (256 KiB, `GRAN_SHIFT` = 18, the same
  for both spaces): `crevoke` and `cdom` work on whole granules, so any
  piece of T2 lent out cannot be taken back without revoking all of T2,
  the KST and the kernel's code included.
- On the FPGA board (`fpga/arty/`, `fpga/rtl/strata_t3_litedram.sv`) T3 is
  DDR3 behind LiteDRAM with one DRAM access per 8-byte beat and one access
  in flight, while T2 is block RAM. There T2 is faster in bandwidth too,
  by an order of magnitude. The board has two cores and a 64 KiB T2.

## 3. What T2 holds now

Measured with `--bus-stats`, which also records every 64-byte line of T2
that a transfer or atomic touched.

| Range | 256 KiB T2 (emulator, `-c 12`) | 64 KiB T2 (`--t2-kib 64`, the FPGA size) |
|---|---|---|
| [0, 32 KiB) | KST: 9.7 KiB of lines touched (core areas 0x900..0x4500 of 15 cores, the per-pid statistics at 0x4800, globals) | the same |
| [32 KiB, 120 KiB) | the kernel's code units: 88 KiB, 44 units of 2 KiB (`u_fart2`) | — (the units stay in T3) |
| [120 KiB, 256 KiB) | never touched: 136 KiB | — |
| [32 KiB, 64 KiB) | | never touched: 32 KiB |

The KST's layout (`os/kernel.s`, `KST_SIZE` and below) defines words up
to 0x5900 (22 KiB); the rest of its 32 KiB is reserve.

No server or program has any T2: the kernel lends memory as granules of
T3, and the one granule of T2 cannot be lent and taken back piecemeal.

## 4. Measurements

### 4.1 Method

- `strata-emu --bus-stats FILE` counts every far-bus transaction by the
  issuing core, mode, PC, link register and capability length, and by
  operation, space and 4 KiB page (an atomic: its word). It charges each
  the RTL's bus cycles (latency + beats; an atomic latency + 3; a device
  transfer a cycle per byte). `--t2-kib N` makes the platform table give
  a smaller T2, so the kernel lays itself out as on the FPGA builds.
- `tools/busstats.py` sums a file per space and per use: `kst` (atomics),
  `switch` (the dispatcher's save and restore: `w_out`, `w_in`, `wi_*`,
  `dd_*`), `code` (every `tgetx`), `scrub` (core 0 zeroing an arena it
  hands out), `fb` (user transfers into [48, 64) MiB), `msg` (user
  transfers through a 4 KiB capability: message buffers), `fscache` (the
  rest of the file server's transfers), `disk` (the block device's DMA),
  `kernel`, `device`, `user`.
- The emulator's transfers complete at once, so the counts are what the
  sessions ask of the bus, not when. Sessions run with `-j` (interpreter
  only); the counts do not depend on timing, but scripted sessions in real
  time (`ws`, Kira) do a timing-dependent number of frames.
- Sessions: `os/demo.txt` (the shell session of the RTL comparison,
  `-T virtual`); the window-server session of `tools/test-ws.sh` (its
  first key script: terminals, vi, wmandel, wclock, full screen and back,
  ~50 s real time); `cc` compiling and running three programs from
  `/src` (`-T virtual`); Kira's demo 1 under `ws`.
- Bus occupancy over time: the RTL's far bus with a temporary counter
  (cycles not idle, by target), `os/demo.txt` on 8 cores, `-T virtual`
  (section 4.3).

### 4.2 Bus cycles per space and use

**Shell session** (`os/demo.txt`, 12 cores, 256 KiB T2): 17.0 M bus cycles.

| Use | Space | Transactions | Bytes | Bus cycles | Share | Latency share |
|---|---|---|---|---|---|---|
| arena scrub (core 0) | T3 | 10,765 | 44.1 M | 5.73 M | 33.6% | 3.8% |
| context switches | T3 | 1,768 | 38.2 M | 4.81 M | 28.2% | 0.7% |
| KST atomics | **T2** | 554,357 | 4.4 M | 3.88 M | 22.8% | 57% |
| code page-ins | T3 | 843 | 6.7 M | 0.85 M | 5.0% | 2.0% |
| file server | T3 | 1,342 | 5.2 M | 0.68 M | 4.0% | 4.0% |
| messages | T3 | 10,103 | 1.3 M | 0.37 M | 2.2% | 55% |
| disk DMA | T3 | 347 | 2.5 M | 0.32 M | 1.9% | 2.1% |
| kernel units | **T2** | 624 | 1.3 M | 0.16 M | 1.0% | 1.5% |
| other | | | | 0.23 M | 1.3% | |

"Latency share" is the part of those cycles that is start-up latency: the
most that a lower latency could take.

**FPGA size** (`--t2-kib 64`, same session): the same within 1%, except
that the kernel's 611 unit loads go to T3 (code T3: 1,454 transactions,
1.02 M cycles); that costs 10,000 bus cycles more. The KST stays in T2.

**Window-server session** (12 cores, real time): 407 M bus cycles.

| Use | Space | Transactions | Bus cycles | Share | Latency share |
|---|---|---|---|---|---|
| framebuffer | T3 | 1,083,024 | 338.3 M | 83.1% | 6.4% |
| context switches | T3 | 6,773 | 18.8 M | 4.6% | 0.7% |
| programs (ws reading surfaces, clients) | T3 | 52,360 | 17.3 M | 4.3% | 6.0% |
| KST atomics | **T2** | 2,286,323 | 16.0 M | 3.9% | 57% |
| file server | T3 | 16,362 | 5.6 M | 1.4% | 5.9% |
| code page-ins | T3 | 2,087 | 4.5 M | 1.1% | 0.9% |
| arena scrub | T3 | 8,455 | 4.5 M | 1.1% | 3.8% |
| messages | T3 | 19,567 | 0.7 M | 0.2% | 55% |

**cc session** (compile and run hi.c, calc.c, sort.c): 65.6 M bus cycles.

| Use | Space | Transactions | Bus cycles | Share | Latency share |
|---|---|---|---|---|---|
| context switches | T3 | 11,076 | 35.5 M | 54.1% | 0.6% |
| code page-ins (cc's units) | T3 | 28,068 | 19.9 M | 30.3% | 2.8% |
| file server | T3 | 21,099 | 4.8 M | 7.3% | 8.8% |
| KST atomics | **T2** | 406,054 | 2.8 M | 4.3% | 57% |
| arena scrub | T3 | 3,335 | 1.8 M | 2.7% | 3.8% |
| messages | T3 | 11,702 | 0.4 M | 0.7% | 53% |

**Kira, demo 1** (under `ws`): 79.5 M bus cycles.

| Use | Space | Transactions | Bus cycles | Share | Latency share |
|---|---|---|---|---|---|
| framebuffer | T3 | 287,078 | 55.7 M | 70.1% | 10.3% |
| file server | T3 | 133,523 | 9.3 M | 11.7% | 28.7% |
| programs | T3 | 63,411 | 7.4 M | 9.3% | 17.1% |
| KST atomics | **T2** | 331,739 | 2.3 M | 2.9% | 57% |
| context switches | T3 | 722 | 2.3 M | 2.9% | 0.6% |
| arena scrub | T3 | 2,311 | 1.2 M | 1.5% | 3.8% |
| code page-ins | T3 | 339 | 0.7 M | 0.9% | 1.0% |
| messages | T3 | 3,022 | 0.2 M | 0.2% | 31% |

### 4.3 How busy the bus is

On the RTL (8 cores, `os/demo.txt`, `-T virtual`; a counter in
`strata_bus.sv` of the cycles the bus is not idle, by target; not
committed):

| | Cycles | Of the session |
|---|---|---|
| session | 161,640,138 | 100% |
| bus not idle | 115,843,083 | 71.7% |
| T3 | 21,490,663 | 13.3% |
| T2 | 4,854,144 | 3.0% |
| devices | 89,488,082 | 55.4% |
| core control | 10,194 | 0.0% |

- Memory (T2 and T3 together) holds the bus 16% of the time: the bus is
  not saturated by memory in this session, so T2 cannot buy throughput
  here; what it buys is latency.
- The RTL's cycles are 1.2 to 1.7 times the emulator model's for the same
  session (the model leaves out the bus's own start cycle per transaction
  and the TU's turnarounds); the shares are alike.
- **Devices hold the bus 55% of the session.** Device bytes are a rounding
  error in the emulator's count (126,000 cycles), so nearly all of that is
  pending device reads answering *retry* (`tty`'s console and break
  reads, timed waits) and being retried. Each attempt is short, and the
  arbiter is round-robin, so a memory transaction waits at most one
  attempt per master; but the bus is almost never idle. Not a T2 matter
  (section 8).
- Contention: a T2 atomic that arrives while a T3 burst holds the bus
  waits for the rest of it. T3 is busy 13% of the time with bursts of
  about 800 RTL cycles on average, so an atomic waits some 50 cycles on
  average instead of its own 7 to 9: a rough estimate (bursts are not
  spread evenly), which section 5.10 needs measured.

### 4.4 What the numbers say

1. **T2's traffic is the KST.** Atomics are 99.9% of T2's transactions and
   96% to 99.5% of its bus cycles in every session. They come from the dispatchers'
   `w_cmds` and `w_publish`, which run on every pass through the
   dispatcher: 16 `xchg`s of the notification words, 4 job-record reads,
   the halt and guest words, 16 slot-state writes, 3 counts, 4 timing
   counters: about 47 atomics per pass, on every worker that traps, most of
   them writing a value that has not changed or reading a zero. In the
   shell session the busiest is the solo `tty` core (234,000 of the
   554,000), then the server cores; in the window-server session core 6
   (914,000) and core 0 (595,000: the system core polls the KST).
2. **The KST in T2 is worth a third of the shell session's bus.** The same
   554,357 atomics in T3 would be 12.75 M bus cycles instead of 3.88 M.
3. **The unit copy is worth nothing measurable** (624 loads x 16 cycles =
   10,000 of 17 M). It is cheap to keep, but its 88 KiB are the only real
   claim on T2's space.
4. **What is left in T3 is bulk.** Switches (whole D-LS and save areas),
   scrubbing (4 KiB at a time), code (2 to 8 KiB), the framebuffer (rows):
   their latency share is 0.6% to 6%. The only T3 traffic with a large
   latency share is small: message buffers (about 130 bytes per transfer,
   55%), the file server's short transfers in Kira (about 400 bytes, 29%),
   and the kernel's own small transfers.
5. **Upper bound.** If every T3 transaction except the framebuffer's went
   to T2, the sessions would save: shell 2.6% (437,000 cycles), window
   server 0.4%, cc 1.9%, Kira 4.1%. Every concrete candidate below is a
   fraction of that.
6. **Not a T2 matter, but the largest item of the shell session:** core 0
   scrubs every arena it hands out with 4 KiB `tput`s of zeros, 1 MiB per
   process: 34% of the session's bus time. See section 8.

## 5. Candidates

Gains are bus cycles saved in the measured sessions; "per event" figures
use the bus model of section 2.

### 5.1 Message buffers in T2

- Now: each process's 4 KiB buffer is the last 4 KiB of its arena (T3);
  a server reads the header and data with `tget`s, writes the reply with
  `tput`s. Shell session: 10,103 transfers, 0.37 M cycles (2.2%).
- Gain in T2: 16 cycles per transfer: 0.16 M (0.95%) in the shell session,
  under 0.3% in the others. A message round trip costs about 33,000 cycles
  on the RTL (`doc/code-loading-proposal.md`, measured: an empty request
  to an idle server on another core); four transfers save 64 of them,
  0.2%. The round trip is the dispatchers' work (traps, atomics, doorbells),
  not the buffer.
- Ownership: a buffer is lent to a server and comes back; when a process
  dies, the kernel revokes its arena and with it every copy of the buffer
  a server may still hold. In T2 that revocation is impossible (one
  granule), so a server that kept a capability could read the next owner's
  messages. It needs either finer T2 granules (5.9) or buffers that are
  the kernel's and are never handed out (the kernel copying each message:
  more bus traffic than it saves).
- Space: 4 KiB per process; 136 KiB holds 34.
- Verdict: no. Under 1% for a security problem or an ISA change.

### 5.2 Context-switch save areas in T2

- Now: 28% of the shell session, 54% of the cc session; 21 KiB per
  transfer on average.
- Gain in T2: 0.6% to 0.7% of the switch traffic (bandwidth-bound).
- Space: 48 KiB per thread: two threads.
- Verdict: no, as long as T2 shares the bus. With a T2 lane of its own
  (5.10), the busiest core's save areas would come off the shared lane;
  even then only two or three fit.

### 5.3 A shared code cache in T2 (programs' units, libraries)

- Now: the kernel's units are in T2 already (0.06%). Programs' units come
  from each process's arena; in the cc session that is 28,068 page-ins,
  30% of the bus; the latency share is 2.8%.
- Gain in T2: about 2.8% of code traffic, 0.85% of the cc session; a 2 KiB
  unit miss saves 16 of about 600 cycles.
- Ownership: code is read-only, so the kernel can keep a T2 cache for good
  and give out read+execute shares (as it does with its own units: c12).
  A share cannot be revoked, so a slot of the cache can never be reused
  for another program's code while an old share may be alive: the cache
  must be filled once (at boot, or per program image version) and only
  ever grow, or hold only public code (`/bin`, the system library).
- The real gain of a shared code cache is one copy per program instead of
  one per process, and that does not need T2 (`doc/code-loading-proposal.md`
  recommends it in T3, through `proc`).
- Verdict: not for latency. Worth it only if T2 gets its own lane, or on the
  FPGA board.

### 5.4 The file server's hottest pages in T2

- Now: `fs` transfers are 4% (shell), 7% (cc) and 12% (Kira) of the bus;
  in Kira they are short (133,523 transfers, about 400 bytes each) with a
  latency share of 29%.
- Gain in T2: up to 2.1 M cycles in the Kira session (2.7%), 0.34 M in cc
  (0.5%), 21,000 in the shell session; only if the hot pages fit (a 64 KiB
  piece holds 16 pages of 4 KiB: the store's root and index pages, not the
  data of a file being read).
- Ownership: `fs` is started at boot and never ends, and it is the only
  process that can read or write the disk's data anyway. The kernel could
  give it a fixed T2 range at start-up for good (cut from what the KST and
  the units leave: no revocation is ever needed, since the range is never
  given to anyone else). If `fs` dies the machine does not go on in any
  case. No ISA change.
- Verdict: possible, small. The first candidate if something user-side is
  to go into T2, but measure the hit rate of a 64 KiB tier first.

### 5.5 Store root pages (the database file system)

Part of 5.4: the same server and the same ownership. The roots and the
upper index pages are read on every lookup; whether they are in `fs`'s
cache already (then their reads are D-LS or cache-to-D-LS transfers)
decides the gain. Same verdict.

### 5.6 The window server's damage lists or small surfaces

- Now: the framebuffer is 70% to 83% of a graphics session and must stay
  in T3 (it is 4 MB and scanned out from T3's window). Surfaces are in
  the clients' arenas; `ws` reading them is the "programs" row (4% to 9%,
  latency share 6% to 17%). Damage lists live in `ws`'s D-LS.
- Gain in T2: under 1%; a surface of any useful size (a 320x200 window is
  250 KiB) does not fit.
- Ownership: `ws` is not a boot server (it is started from the shell and
  quits), so a T2 range lent to it would have to come back: the granule
  problem again.
- Verdict: no.

### 5.7 Ring buffers for `tty` and pipes

- Now: `tty` and `pipe` keep their rings in their D-LS; what crosses the
  bus is the message buffers (5.1). Nothing to move.
- Verdict: no.

### 5.8 Per-core run queues

- Now: each dispatcher's run queue is in its D-LS; what other cores need
  of it is published into the KST (slot states, runnable counts), which is
  in T2 already. That publishing is T2's whole traffic.
- The gain is in doing less of it, not in moving it (section 6, option A).

### 5.9 Finer granules for T2 (ISA change)

What it would take to lend T2 revocably to ordinary processes:

- ISA: a granule size per space (from the platform table, or fixed: e.g.
  16 KiB for T2), so `cdom`, `crevoke` and the revoker's alignment rules
  use the space's shift (manual `ch-caps.tex`: domains and revocation;
  `ch-os.tex`).
- RTL: the granule table gets 15 more entries in every copy (each core's
  LUT-RAM and the top level's master: 16 instead of 1 for T2, 17 bits
  each); the index computation and the walker take the shift from the
  space (`strata_core.sv` `g_a`/`g_d`, `dom_a`/`dom_n`; `strata_top.sv`).
  Small in area. The formal proofs of the capability unit need the second
  shift.
- Emulator, conformance tests, the kernel's arena pool (a second bitmap
  and revoker for T2), `proc` (who gets T2, and when).
- Cost: medium (a week or two with the tests and the proofs), for a gain
  that 5.1 to 5.7 put at about 1%.
- Verdict: not now. Revisit with 5.10.

### 5.10 A lane of its own for T2 (hardware change, no ISA change)

- Today a T2 atomic waits behind whatever T3 burst holds the bus: a 4 KiB
  scrub write (532 cycles), a 48 KiB save area (6,164). With two lanes, one
  for T3 and devices and one for T2, a T2 transaction would wait only for
  other T2 transactions.
- Order: a core's Transfer Unit executes its queue one transaction at a
  time, so a core never has a T2 and a T3 transaction in flight together;
  invariant I2 (a core's transfers take effect in issue order) holds.
  Atomics stay linearizable per target, which is all they need.
  Publication (I4: `csend`, `tamo` wait for memory idle) is unchanged.
- Gain: the shell session's T2 traffic (24% of its memory bus time)
  leaves the shared lane, and every dispatcher pass stops waiting behind
  bulk transfers for its ~47 atomics. With the estimate of 4.3 (some 50
  cycles of waiting per atomic), that is in the order of 2,000 cycles per
  pass, against about 16,000 cycles per trap measured on the RTL (`cores`):
  some 10% to 15% off a trap, to be confirmed by counting the waits. With a lane of its own, T2 becomes a second memory channel and
  5.2 and 5.3 become worth doing for the busiest threads and programs.
- Cost: `strata_bus.sv` (two arbiters, two `cur`/`tgt` sets, the block
  device's master on the T3 lane), `strata_top.sv`; the RTL is compared
  with the emulator by results, not cycles, so the lockstep tests are
  unaffected. The formal proofs of the bus (`formal/`) need a second look.
- Verdict: the change that would make T2 matter. Worth measuring first
  (section 4.3: how often a T2 atomic waits behind a T3 burst).

## 6. Ownership models

| Model | What it allows | Revocation | ISA change |
|---|---|---|---|
| A. Kernel only (today) | KST, kernel code; anything kernel-mediated | never needed | no |
| B. Fixed trusted servers | a range cut at boot for `fs` (or `proc`, `pipe`) for the machine's life | never: the range is never reused | no |
| C. Kernel T2 allocator, kernel-mediated data only | e.g. a kernel-owned code cache that only gives read+execute shares | shares cannot be revoked: slots are filled once and never reused | no |
| D. Finer T2 granules | revocable T2 for any process (message buffers, surfaces, arenas) | as for T3 | yes (5.9) |

A and B fit the rule `strataos.md` states ("it holds only what is the
kernel's for good"): under B the range is the server's for good, which is
the same promise. C works for immutable data only. D is the only one that
lets T2 behave like T3, and nothing measured here pays for it.

## 7. Ranked options

| # | Option | Gain (bus cycles) | Effort | Risk | ISA / hardware |
|---|---|---|---|---|---|
| 1 | Fewer KST atomics per dispatcher pass: publish only what changed, one summary word for notes and jobs | 15%-20% of the shell session, 3%-4% of the others; shorter traps | small (kernel only) | low: the KST protocol is local to `kernel.s` | none |
| 2 | FPGA size: put the hottest kernel units (not all 88 KiB) into the 32 KiB that is free | small on the emulator; on the board, a unit load from block RAM instead of DDR3 at a DRAM access per beat | small-medium (the paging trap picks T2 or T3 by unit) | low | none |
| 3 | A T2 lane on the far bus | atomics stop waiting behind T3 bursts: an estimated 10%-15% off a trap; T2 becomes a second channel | medium (RTL bus, proofs) | medium | hardware, not ISA |
| 4 | `fs` gets a fixed T2 range for its hottest pages (model B) | up to 2.7% (Kira), 0.5% (cc) | medium (fs cache tiers) | low | none |
| 5 | Kernel-owned shared code cache in T2 (model C) | 0.85% of cc; more with option 3 | medium | medium (slot reuse) | none |
| 6 | Message buffers / save areas / surfaces in T2 | under 1% each | medium-large | high (no revocation) or ISA change | D: yes |
| 7 | Finer T2 granules | enables 6 | medium | medium | ISA |

## 8. Found on the way

- `doc/strataos.md` says the kernel's units in T2 are 64 KiB; they are
  88 KiB now (`mkdisk`: far 176 blocks).
- The KST touches 9.7 KiB of its 32 KiB.
- Arena scrubbing is the largest single use of the bus in the shell
  session (34%): 1 MiB of zeros per process created, in 4 KiB `tput`s
  from core 0. Ideas, none of them about T2: scrub only what the process
  can read before it writes it (not the image or the save areas, which
  are written anyway), or scrub when an arena is freed and only if it was
  touched, or a fill transfer in the Transfer Unit (an ISA change).
- Pending device reads that answer *retry* keep the far bus busy 55% of
  the shell session on the RTL (4.3). A retried read could wait in the
  device and be completed later (the way the console's break read is
  released), or retry less often; that would also make the bus figures
  easier to read.
- On the FPGA board T3 is far slower than the model's 20 + n/8, so all of
  the measurements above understate T2 there.

## 8a. Option 1, done

The dispatchers now read their commands only when core 0 has set their
pending word (`G_PEND`, set after every command), and publish a word only
when it changed (the timing counters only when the core goes idle).
`os/demo.txt`, 12 cores, `--bus-stats`:

| | Before | After |
|---|---|---|
| KST atomics | 554,357 | 87,775 (-84%) |
| T2 bus cycles | 4.05 M | 0.78 M |
| All far-bus cycles | 17.04 M | 13.81 M (-19%) |

Measured again on the main of 2026-11-16 (Local Store windows, resident
threads, console rings): KST atomics 612,033 -> 126,293 (-79%), far-bus
cycles 16.95 M -> 13.61 M (-20%).

The session's output is the same except for figures that depend on
timing (switch counts, the virtual clock, `ps` catching `proc` blocked
rather than still running while it waits for the kernel's reply).

## 9. Recommendation

1. Keep T2 the kernel's (model A), with one exception allowed later
   (model B for `fs`) if a measured hit rate supports it.
2. Do option 1 now: it is the cheapest change in this document and the
   only one with a double-digit gain; it is a T2 change in the sense that
   it is all of T2's traffic.
3. Do option 2 if the FPGA board is going to run StrataOS.
4. Before anything else that moves data into T2: measure how long T2
   atomics wait behind T3 bursts on the RTL, and decide on option 3. If
   T2 gets its own lane, revisit 5.2 and 5.3 with those numbers.
5. Leave the ISA alone (no finer T2 granules) unless option 3 lands and
   untrusted users of T2 then show a gain.

## 10. Questions

1. Is T2 meant to stay the kernel's for good (models A/B/C), or is
   revocable T2 for programs (model D, an ISA change) a goal in itself?
2. Is a second lane on the far bus acceptable as an RTL change (it changes
   the timing of every session, not the results)?
3. Should the FPGA builds be a design target for this (option 2), or is
   the emulator and RTL configuration the one that matters?
4. Is shrinking the dispatcher's KST traffic (option 1) in scope here, or
   a separate task?
5. The arena scrub and the device-read retries (section 8): separate tasks?

## Appendix: reproducing the numbers

```
make os build/disk-ws.img
cp build/disk.img /tmp/d.img
build/strata-emu -c 12 -j -g none -T virtual --bus-stats /tmp/demo.txt -d /tmp/d.img -i os/demo.txt build/bootrom.stx
tools/busstats.py --cores 1=proc,2=dev,3=fs,4=tty,5=pipe /tmp/demo.txt
```

Add `--t2-kib 64` for the FPGA size. The window-server keys are the first
script of `tools/test-ws.sh`; Kira's are `ws kira demo 1` with the waits of
`tools/test-kira.sh`.
