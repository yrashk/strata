# What a context switch copies, and how to copy less

Status: analysis, 2026-11-15. Nothing here is implemented yet except the
measurement (`make ls-stats`). Option A needs an ISA change and waits
for a decision.

## What a switch does today

A worker core time-shares the threads placed on it. The dispatcher
switches in `w_sched` (`os/kernel.s`, at `ws_in`):

| Step | Code | Moves |
|---|---|---|
| save the outgoing thread's D-LS | `w_out` counts, `w_outdls` puts | its data extent [0, PR_DEND) without a scratch range, and its live stack [sp, 0x10000) |
| load the incoming thread's code | `w_incode` | the image's code section, `tgetx` into 0x8000.. (code is never saved) |
| restore the incoming thread's D-LS | `w_in` | **another process's bytes are in the D-LS** (`w_dpid` differs) or this is a first load: all of [0, 0xA000) and [0xE000, 0x10000), 48 KiB (`wi_whole`). The same thread coming back: its extent and its live stack (`wi_restore`) |
| first load only | `w_in` | the image's data section on top |
| code mirror, code units | `w_in` | a JIT's mirror; each code unit its cache held |

The extent of a StrataOS program is its data section (a bare-metal one:
all 40 KiB). The 48 KiB restore exists for isolation (`doc/strataos.md`,
"What the next process may see"). Without it, the bytes the previous
process left above the incoming one's extent and below its live stack
would be visible to the incoming one. `tools/test-isolate.sh` checks
this with `tools/dlsgap.s`, which writes a pattern into exactly those
gaps.

Nothing waits for these transfers (they are queued on tags 12..15 and the
thread runs while they stream in). The cost is bus traffic: on the RTL
one burst is 20 cycles of latency from T3, then a beat per 8 bytes, and
it competes with every other core's transfers. On the emulator it is a
`memcpy`, plus, for code, the loss of the JIT's and the decode cache's
translations of the overwritten I-LS. That is host time, which is what
makes a time-shared core slow in the browser build.

## Measured

`make ls-stats` builds `build/strata-emu-ls` (`emu/emu.c` with
`-DSTRATA_LSSTATS`, interpreter only) and runs `tools/ls-stats.sh`.
Each workload is its own session on 8 cores, `-T virtual`, with the boot
session subtracted. The emulator recognises the switch's transfers by
their shape (supervisor mode, the StrataOS layout) and also models the
options below. KiB are D-LS save + D-LS restore + code. Code mirrors and
code units are not included; `uptime`'s "KiB moved" includes them.

| Workload | Switches | Save | Restore | Code | KiB/switch |
|---|---:|---:|---:|---:|---:|
| boot to the shell | 33 | 377 | 1,486 | 386 | 68.2 |
| two `spin`s pinned to core 6 | 132 | 1,823 | 6,363 | 1,011 | 69.7 |
| `cat /src/cc.c \| wc`, both on core 6 | 424 | 9,730 | 20,383 | 4,419 | 81.4 |
| `cat \| upper \| wc`, all on core 6 | 836 | 15,968 | 40,172 | 7,617 | 76.3 |
| `cat /src/cc.c` (default placement) | 88 | 1,111 | 4,242 | 476 | 66.2 |
| `cp /src/cc.c /x` (default placement) | 94 | 1,531 | 4,538 | 523 | 70.1 |

The 48 KiB restore is 55 to 70% of every row. The save of the extent
is most of the rest; code is 7 to 15%. Only 7 of 480 switches in these
sessions are a thread coming back to its own bytes. The rest are
switches between processes, so the cheap path almost never applies.
The case that started this (`ws` and `term` on one core before 7cfe7c7:
9,569 switches, 909 MB, 97 KiB a switch) has the same shape.

## Options

### S. Software only (no ISA change)

- **S1: restore only the union of the two extents** ([0, max(ext_in,
  ext_prev)) and the whole 8 KiB stack). About 40% fewer bytes, but it
  trusts that a program writes only inside its extent and stack.
  Nothing enforces that: `dlsgap` writes outside both, and the next
  process would see it. That breaks the guarantee `test-isolate`
  checks. Rejected.
- **S2: S1 plus a scan.** At switch-out the dispatcher checks that the
  gap above the extent is still zero, and falls back to the 48 KiB
  restore if it is not. The scan is about 27 KiB of loads for a small
  program, some 4,000 instructions (7,000 RTL cycles) per switch. The
  bus time it saves is about 3,400 beats, which the thread overlaps
  with running anyway. That is slower in cycles. Rejected.
- **S3: skip when the same thread comes back.** This is already done
  (`wi_restore`; and when nothing else ran, `w_loaded` means no switch
  happens at all). It is rare: 7 of 480 switches.
- **S4: place threads so they do not share a core.** This is where most
  of the gain was. 7cfe7c7 (ws as a busy server) took the `cat` in a
  term from 9,569 switches to 176. It does not help once cores run out
  or programs are pinned.

Software cannot tell which bytes a program wrote. Every remaining
option needs that from the hardware.

### A. A dirty mask of the D-LS (ISA: one CSR)

A supervisor CSR `dlsdirty`, 64 bits, one per 1/64 of the D-LS (1 KiB
at 64 KiB, 64 bytes at 4 KiB). A bit is set by a store in any mode to
that segment, and by a transfer into the D-LS that is issued in user
mode (set at issue, for the transfer's whole range). Transfers issued in
supervisor mode do not set bits, so the dispatcher's restores, still in
flight, do not mark anything. `csrw` writes the mask; the dispatcher
clears it when it loads a thread.

The kernel keeps two masks:
- per thread, **F**: the segments its save area may hold non-zero.
  F grows by what each save writes, and on a first load by the image's
  data section;
- per core, **L**: the segments the D-LS may hold non-zero bytes of
  the occupant in. L = F(occupant) | dlsdirty at switch-out.

At switch-out it saves `dlsdirty & (extent | live stack)`, whole
segments, as runs. At switch-in from another process it restores
`F(in) | L` from the incoming thread's save area, which holds zeros
outside F(in). That overwrites everything the previous occupant could
have left, `dlsgap`'s gaps included, so the isolation guarantee is
unchanged. The thread coming back to its own bytes needs no restore at
all.

| Workload | Save (1 KiB) | Restore | KiB/switch | Change | with 4 KiB pages |
|---|---:|---:|---:|---:|---:|
| boot | 218 | 512 | 33.8 | −50% | 39.2 |
| two spins | 259 | 2,635 | 29.6 | −58% | 39.1 |
| `cat \| wc` on one core | 3,541 | 11,436 | 45.7 | −44% | 58.4 |
| `cat \| upper \| wc` on one core | 6,159 | 18,868 | 39.0 | −49% | 52.6 |
| `cat` | 738 | 1,799 | 34.2 | −48% | 44.9 |
| `cp` | 618 | 2,609 | 39.9 | −43% | 52.2 |

The save drops by 35 to 85%, the restore by 45 to 65%. What is left is
the incoming program's footprint plus the outgoing one's, and its code.
Code is now a quarter of what moves.

Cost: 64 flip-flops per core. A store sets one bit from 6 address bits.
A user transfer sets a range of bits (two thermometer codes), at issue,
off the load path. The emulator's interpreter and fast loop set the bit
on every store. Each JIT (arm64, x86-64, wasm) needs a few more
instructions per store, which is a small but real slowdown of all
JITted code.

**Every place it touches** (HANDOFF's rule): `asm/isa.h` (CSR number
26), `asm/` (its name), `emu/emu.c` (step, `run_fast`, core reset), the
three JITs' store paths, `rtl/strata_core.sv` (and `strata_tu.sv` for
user transfers), the debug engine (snapshot `Misc`, register list), a
conformance test (stores and transfers in user and supervisor mode, set
and clear; checked to fail without the change), the manual's CSR table
and execution model, `doc/strataos.md`'s switch section, and the
kernel: `w_out`, `w_outdls`, `w_in`, `w_incount`, two words in the
record. The worker's resident kernel has 48 bytes to spare, so most of
the new code has to go into a kernel unit.

### L. Lazy restore (ISA: per-segment presence bits that trap)

Restore nothing at switch-in. Mark the segments of `F(in) | L` absent,
and trap on the first load or store to one; the dispatcher then fetches
it, or zeroes it. Measured as the segments of `F | L` the thread
actually touches before it is switched out:

| Workload | KiB/switch | Traps per switch |
|---|---:|---:|
| boot | 21.2 | 2.9 |
| two spins | 11.9 | 2.3 |
| `cat \| wc` on one core | 29.4 | 10.6 |
| `cat \| upper \| wc` | 26.1 | 9.6 |

These are the fewest bytes, but a trap costs about 4,500 cycles today
(`cores`: cycles/trap). Ten of them cost far more than the 2,000 or so
bus beats they save. The variant where the hardware fetches the segment
itself on a miss turns the Local Store into a cache, which is what this
architecture is designed not to be. Not recommended.

### B. Two programs side by side (ISA: relocating windows)

Give the user mode a base and a bound per Local Store, so that a
program's addresses 0.. map to a part of the store the dispatcher
chooses. Then two programs whose footprints fit together share the
stores and a switch between them moves nothing: no save, no restore,
no code. The "fit" column of `ls-stats` counts the switches where the
two footprints add up to at most 48 KiB of D-LS and the two code sizes
to at most 32 KiB:

| Workload | Switches | Would fit side by side |
|---|---:|---:|
| two spins | 132 | 130 |
| `cat \| wc` on one core | 424 | 276 (the misses are `pipe` and `db` on core 5) |
| `cat \| upper \| wc` | 836 | 672 |
| `cat` / `cp` | 88 / 94 | 84 / 90 |

This is the biggest win. It is also the same hardware the open item
"user-mode Local Store protection" (HANDOFF) needs: a bound on what
user mode reaches. It is a much larger change, though:
- an adder (or a bit merge) on every user Local Store address, in what
  is already the RTL's deepest path (the D-LS read port);
- the D-LS program area is two ranges (data at 0, stack at 0xE000)
  around the dispatcher's data, so either two windows or a new program
  ABI;
- code is linked at 0x8000, so the I-LS needs a window too;
- the dispatcher has to allocate store space, and fall back to copying
  when programs do not fit (core 5's pair does not).

`doc/ls-windows.md` designs it and simulates it with resident threads
and eviction: −54 to −87% on the pinned workloads, −26 to −32% where
servers share cores.

### C. Bounds without relocation (ISA: the protection proposal)

With only the protection bounds, the kernel knows each thread's
footprint (its windows, grown on a trap like a guard page), so the
restore can cover just the union of the two footprints, as in A. The
save stays the extent and stack: about −40% (two spins 41 KiB a switch,
`cat | wc` 60). It costs more than A for less, unless protection is
wanted anyway. In that case it comes free with B.

## Recommendation

1. **A now.** It is contained (one CSR, plus kernel work), keeps the
   isolation guarantee exactly, and halves what every switch moves.
   1 KiB segments beat 4 KiB pages by 5 to 14 KiB a switch.
2. **B later, as part of the protection work.** It makes most switches
   copy nothing, but it changes the program ABI and the RTL's critical
   path. It should be designed together with the user-mode bounds,
   not before them.
3. Keep doing S4: a switch avoided is cheaper than any switch.

The numbers come from `make ls-stats`. The model reads the transfers
the kernel issues, so a kernel change to how switches are done needs the
recogniser in `lss_xfer` (`emu/emu.c`) to follow it.
