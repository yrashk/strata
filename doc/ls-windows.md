# User-mode Local Store windows: protection and switches that copy nothing

Status: design, 2026-11-15. Nothing is implemented. Four decisions are
open (the end of this file). This is option B of `doc/ls-switch.md`. It
is the same hardware as the open item "user-mode Local Store protection"
in HANDOFF, so this document covers both.

## What it solves

1. **Protection.** Today user-mode loads, stores and transfers reach
   every Local Store address, including the dispatcher's data (D-LS
   0xA000..0xDFFF: the records and saved registers of every thread on
   the core) and the kernel's code (I-LS 0x4000..0x7FFF, which a user
   `tgetx` can overwrite). A hostile program owns its core's kernel.
2. **The cost of a switch.** A switch between two processes moves 66
   to 81 KiB (`make ls-stats`), most of it there only so that no
   program sees another's bytes. If each program's addresses are
   relocated into a part of the stores of its own, two programs can
   stay resident side by side. A switch between them then moves
   nothing, and isolation follows from the bound instead of from
   copying.

## The mechanism (proposed)

Three windows per core, each a supervisor CSR, used only in user mode:

| Window | Virtual range (user addresses) | Covers in StrataOS |
|---|---|---|
| `wdata` | [vlo, vlo + len) | the data, at 0 |
| `wstack` | [vlo, vlo + len) | the stack, ending at 0x10000 |
| `wcode` | [vlo, vlo + len) | the code and the code cache, from 0x8000 |

Each CSR packs `vlo`, `len` and `pbase` (the physical start) in units of
1/64 of its store (1 KiB at 64 KiB, 64 bytes at 4 KiB, so 7 bits each),
plus an enable bit. With the enable bit clear, the window does not
restrict or relocate anything, which is today's behaviour. A
user-mode address `va`:
- **load, store, `ltag`/`linst` (the tag table):** `va` must lie in
  `wdata` or `wstack`, and the access must not straddle the two;
  otherwise `lsfault` with `tval = va`. The physical address is
  `va - vlo + pbase`;
- **a transfer (`tget`, `tput`, `tgetx`):** the whole Local Store range
  must lie inside one window (`wcode` for `tgetx`), checked at issue
  together with today's checks, and relocated at issue. The Transfer
  Unit and the hazard logic see only physical addresses;
- **fetch:** `pc` must lie in `wcode` (otherwise `ifault`), and the
  fetch address is relocated the same way;
- **`xmap`:** its I-LS address must lie in `wcode`; the overlay map holds
  virtual addresses, which are relocated at fetch like the `pc`.

Supervisor mode uses physical addresses, as now. A trap leaves user mode
and so leaves the windows; `eret` to user mode brings them back.
Everything user-visible (`pc`, `uepc`, `utvec`, `tval`, the tag table
CSRs, the overlay map) holds virtual addresses. The windows are
1-KiB-aligned, so relocation leaves the low 10 bits alone: it is a
6-bit add of a precomputed offset (`pbase - vlo`) on the top bits.

Guests are unaffected: a guest kernel runs in supervisor mode on whole
cores of its own, and can use the windows for its own programs. A bare-metal
program run by StrataOS (not `F_SYS`) gets a 40 KiB `wdata`, which is its
extent today.

### What the hardware pays

- Per window: two comparisons (`vlo` and `vlo + len`), then a selection
  of the offset and a 6-bit add, between the ALU's adder (`maddr` in
  `rtl/strata_core.sv`, which feeds the D-LS address directly today) and
  the RAM port. The check itself (`mok` today) runs beside the access as
  it does now. The relocation is in series on the address path. The
  same applies to the fetch address (`ia_addr = pc[15:3]`), which the
  stream fetch also reads ahead.
- About 3 x 22 flip-flops for the CSRs, and the comparators.
- Not measured yet. The deepest path on ECP5 today begins at the D-LS
  read port (`fpga/README.md`), not on its address side, but adding
  logic before the RAM moves that. The way to know is to synthesize
  with and without the windows (`fpga/ecp5-runs.sh`). If it hurts, the
  usual remedy is to register the Local Store address (one more cycle
  for loads), which `fpga/README.md` already names as the next timing
  step.

## What the dispatcher does with it

- **Space.** Per core, a pool of D-LS units (the program part:
  [0, 0xA000) and [0xE000, 0x10000), 48 KiB) and of I-LS units
  ([0x8000, 0x10000), 32 KiB). A thread gets a data window as large as
  its extent, a stack window, and a code window (its code plus a code
  cache, whose size is now per thread).
- **Resident threads.** A thread keeps its windows while it is not
  running. Switching to a resident thread moves nothing. It only
  restores registers and capabilities, sets the three CSRs and re-enters
  the overlay map (its code units are still in its window, so no copying
  is needed, only `xmap`s).
- **Eviction.** When a thread that is not resident must run, the least
  recently run threads are evicted until its windows fit. An evicted
  thread is saved as today (extent and live stack; with option A's
  dirty mask, only what it wrote). Space handed to a thread is filled
  whole from its save area (zeros where it has nothing), so it never
  holds another's bytes.
- **Stack size.** Either a fixed 8 KiB (today's maximum) or start small
  and grow on a fault just below the window. The simulation below has
  both; growth saves about a tenth.
- **Isolation becomes a bound.** A program can no longer read memory
  outside its windows, so the 48 KiB scrub on every switch between
  processes goes away. `tools/dlsgap.s` writes beyond its extent, so
  under windows it must fault, and `test-isolate` changes to expect
  that.

## Simulated

`make ls-stats` now also writes the dispatcher's switch transfers to a
log (`STRATA_LSLOG`), and `tools/ls-windows.py` replays them with
resident threads and LRU eviction. Window sizes are the largest each
thread used over the session, the stack's from its deepest written 1 KiB
segment. These are whole sessions, boot included. KiB moved by switches:

| Session | Switches | Today | B | B + dirty mask | B, 8 KiB stacks | B, power-of-two windows |
|---|---:|---:|---:|---:|---:|---:|
| boot only | 26 | 2,138 | 966 | 863 | 1,092 | 1,229 |
| two `spin`s on core 6 | 158 | 11,336 | 1,466 (−87%) | 1,258 | 1,648 | 8,910 |
| `cat \| wc` on core 6 | 450 | 36,670 | 15,036 (−59%) | 11,261 | 16,254 | 27,251 |
| `cat \| upper \| wc` on core 6 | 862 | 65,896 | 30,259 (−54%) | 23,920 | 33,766 | 47,527 |
| `cat /src/cc.c` | 114 | 7,968 | 5,413 (−32%) | 4,962 | 6,155 | 6,902 |
| `cp /src/cc.c /x` | 120 | 8,730 | 6,447 (−26%) | 5,451 | 7,231 | 7,647 |

Where it does and does not help (sizes from the `cat | wc` session):

| Core | Threads | Data | Stack | Code (with cache) | Fits together? |
|---|---|---:|---:|---:|---|
| 6 | `cat`, `wc` | 17.4 + 13.2 KiB | 1 + 1 | 23.1 + 7.5 KiB | yes: after the first loads, 0 bytes per switch |
| 5 | `pipe`, `db` | 34.6 + 39.5 KiB | 1 + 1 | 21.4 + 10.0 KiB | no: every switch evicts |

- Programs side by side move nothing. That is where the large savings
  come from (the two `spin`s, the pipeline stages).
- The servers' data extents are large (their 4 KiB message and page
  buffers), so two servers on one core rarely fit. What remains is
  mostly core 5. Keeping big servers on cores of their own, or moving
  their buffers out of the extent, would fix it; that is separate work.
- With the dirty mask (option A) on top, evictions get cheaper: another
  8 to 25%.
- Power-of-two windows would let relocation be a bit merge instead of
  an add, but they waste so much space that most pairs no longer fit.
  Not worth it.
- The stacks seen are all within 1 KiB. A fixed 8 KiB stack window
  costs 8 to 14% against windows that grow.

## Every place it touches

In order, each step passing `make test` before the next:

1. **ISA and emulator, protection only.** `asm/isa.h` (CSRs 26..28), the
   assembler's names, `emu/emu.c` (step, the fast loop's address checks
   and hazards, transfers, fetch, `xmap`, `ltag`/`linst`, core reset),
   the JITs' bounds masks (arm64, x86-64, wasm), the debug engine
   (`pre_decode`, `stall_reason`, `prov_after`, the snapshot's `Misc`,
   user addresses shown virtual), conformance tests (each access kind
   inside, outside and straddling a window, relocation, `tval`; checked
   to fail without the change). The kernel sets identity windows
   (`pbase = vlo`) on `eret`, which already gives the protection. A new
   test runs a hostile program that writes 0xA000 and checks that it
   faults; `test-isolate` expects the fault.
2. **RTL.** `strata_core.sv` (address paths, CSRs, fetch), `strata_tu.sv`
   if the issue-time checks move there, the formal properties that name
   `maddr`/`mok`, ECP5 synthesis before and after.
3. **The dispatcher.** The pools, resident threads, eviction, the
   per-thread code cache size (`ucache`), overlay re-entry without
   copying, stack windows. The worker's resident kernel has 48 bytes
   free, so this goes into a kernel unit. `cores`/`ps` keep counting
   what is moved, and the `ls-stats` recogniser (`lss_xfer`) follows the
   new transfers.
4. **Documentation.** The manual (the CSR table, the memory and
   protection model, traps, the OS chapter's switch and isolation
   sections), `doc/strataos.md`, the site's ISA pages and
   `site/os/kernel.html` section 04, HANDOFF.

## Decisions

1. **Shape: three windows, with no change to programs (recommended), or
   one D-LS window and a new program ABI.** With one window the stack
   would live at the top of the data window. That means fewer
   comparators, but a stack overflow runs silently into the data, and
   every program's start-up and every stack constant changes. Three
   windows keep every program as it is.
2. **Timing.** Accept a 6-bit add in series on the Local Store address
   paths, and measure it on ECP5 before going further (recommended).
   The fallback, a registered address with one more cycle for loads, is
   decided only if the numbers say so.
3. **User-mode narrowing** (the protection proposal's nesting: a program
   narrowing its own windows to sandbox code it runs). Leave it out now
   (recommended); it can be added later as one more user-writable CSR.
4. **Stacks: a fixed 8 KiB stack window first (recommended), growth on a
   fault later.** Growth saves 8 to 14% of the bytes moved, but it needs
   a fault-and-move path in the dispatcher.
