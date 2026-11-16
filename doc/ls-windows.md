# User-mode Local Store windows: protection and switches that copy nothing

Status, 2026-11-15: the four decisions are taken as recommended (the end
of this file). Steps 1 to 4 are done for the D-LS: the ISA, the emulator,
the RTL and the debug engine, the protection, threads that stay resident
in relocated D-LS slices, ECP5 synthesis, the documentation. The code is
not relocated yet (the end of "Step 3, as done" says why). This is option
B of `doc/ls-switch.md`. It is the same hardware as the item "user-mode
Local Store protection" that HANDOFF listed, so this document covers
both.

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

## Step 1, as done

- **The windows are the same for every thread.** StrataOS sets
  `wdata` = [0, 0xA000), `wstack` = [0xE000, 0x10000) and `wcode` =
  I-LS [0x8000, 0x10000), all identity, once per worker in `wboot`. That
  keeps every program's view exactly as before (`as`'s heap above its
  data section included) and costs a switch nothing. Tight windows
  (the extent) belong to step 3, where they decide what fits side by side.
- **The fast paths.** The emulator keeps per core a 64-entry relocation
  table per store for the current mode (`drel`, `irel`; `win_sync` after
  every mode change and window write). The fast loop and the JITs relocate
  every load and store through `drel` (about five more host instructions
  per access in the native JITs). They run code only where `irel` is 0
  (inside the code window, not relocated): a block or region keeps to one
  1/64 of the I-LS and checks its unit when it starts. A relocated code
  window runs in `step()` until step 3 needs it fast.
- **The RTL's stream fetch** goes back through F0 whenever the next pc
  starts another unit of the I-LS, so the read-ahead never carries
  execution past a window's end.
- **What it found.** `lang/cc/examples/vla.c` had a 16 KiB array on its
  8 KiB stack: it wrote over the dispatcher's data at 0xC000..0xE000 on
  every run. It faults now; the array is a variable-length one (from the
  heap), which is what the example meant. The `overlay` example put its
  overlay slots at I-LS 0x7700, in the worker kernel's part; its slots are
  its own code now. The worker's resident kernel had 16 bytes left, not
  48; the windows' setup took 12 of the bytes three `la sp` became `addi`s
  to free.
- **Checked:** `lswin` passes on the interpreter, the JIT (arm64, and
  x86-64 under Rosetta) and the RTL, and in the WebAssembly build; mutations
  of each piece (the range check, the D-LS and I-LS relocation, the stream
  fetch's unit break, `xmap`, `ltag`, the transfer relocation) each make it
  fail.

## Step 3, as done: resident threads (the D-LS)

- **Slices.** The program part of a worker's D-LS is 48 1 KiB units
  (0..39 and 56..63). A thread gets a data slice of its extent (whole KiB;
  40 for a bare-metal program) and an 8 KiB stack slice, anywhere among
  them, and keeps them while switched out. `wdata` maps [0, extent) and
  `wstack` [0xE000, 0x10000) onto them at every switch-in.
- **Eviction.** A thread without slices takes free units. When there are
  not enough, the least recently run thread on the core goes first (a
  dead one, ended or not started, first of all: its units come back with
  nothing saved). A live one is saved as a switch used to save: its extent
  without the scratch range, and its live stack. Its bytes are counted
  before any transfer (the switch's atomics come first), its save is
  issued before the restore that may land in the same units (I2).
- **Isolation.** New slices are filled whole from the save area: the data
  window and the 8 KiB stack. Resident slices are reachable only through
  their owner's windows.
- **Where the code is.** None of this fits the worker's resident kernel
  (4 bytes were left). It is the worker extension, `os/kunits/wext.s`,
  1.9 of the 2.25 KiB that core 0's own resident code occupies at I-LS
  0x7700..0x7FFF and a worker never runs. It lives in the kernel's far
  image; core 0 gives each worker a share of that image after the KST and
  core control (`boot.s`, and `guest.s` for cores a guest gives back), and
  `wboot` copies the extension to 0x7700. Moving the old save and restore
  code out freed 684 bytes of the resident part. The bookkeeping uses
  core 0's `k_hdr`/`k_cdata`/`k_hdr2` (128 + 16 bytes; workers never use
  them), as core 0's stack already lives in the workers' records.
- **What it found.** Programs that reached beyond their data extent now
  fault instead of working by luck (that memory was lost on every switch
  anyway): `tools/dlsgap.s` filled up to 0xA000 (its fill is now the rest
  of its data window), `lang/cc/examples/vla.c`'s array did not fit the
  8 KiB heap either (its `malloc` failed and it wrote through the null
  pointer; it is 5.6 KiB now). `tools/lsprot.s` tries one more way:
  past its own data window.

Measured between two `uptime`s, 8 cores, `-T virtual`, the same sessions
on step 1 (identity windows, copying on every switch) and now:

| Workload | Switches | KiB moved, copying | KiB moved, resident | KiB per switch |
|---|---:|---:|---:|---|
| two `spin`s pinned to core 6 | 136 / 138 | 9,498 | 1,876 | 69.8 → 13.6 |
| `cat /src/cc.c \| wc`, both on core 6 | 434 / 442 | 35,005 | 17,874 | 80.7 → 40.4 |
| `cat \| upper \| wc`, all on core 6 | 853 / 848 | 64,767 | 33,228 | 75.9 → 39.2 |
| `cat /src/cc.c` | 95 / 95 | 6,318 | 1,386 | 66.5 → 14.6 |
| `cp /src/cc.c /x` | 101 / 101 | 7,057 | 1,443 | 69.9 → 14.3 |
| `cc -o hi /src/hi.c` | 88 / 88 | 6,881 | 5,450 | 78.2 → 61.9 |

The simulation predicted −87% for the two `spin`s and −54 to −59% for the
pipelines; with 8 KiB stacks and the code still reloaded it is −80% and
−49%. What is left is the code (7 to 15 KiB a switch), and the evictions
where two threads do not fit: `pipe` (35 KiB) and `db` (40 KiB) on one
core, and `cc`, whose data is large. The time of the workloads, machine
and host, does not change measurably: on the emulator a transfer is a
`memcpy`.

**Not done: relocating the code.** `wcode` stays I-LS [0x8000, 0x10000)
for every thread, so every switch still reloads the incoming code and
throws away the JIT's translations of the old. Relocating code would let
two programs' code stay too, but the fast paths cannot run relocated code
yet: the JITs index their translations by I-LS address and chain `jalr`
through that table, the fast loop decodes by I-LS address, and a block's
link register and exit pc are the virtual pc. It needs every backend to
translate by physical address with the block's relocation as a constant,
and `jalr` to check the target's window before it looks up the table.
Until then a relocated code window would run in `step()`, slower than the
copy it saves.

## Step 2: what the windows cost the hardware (ECP5)

Not measured yet: one core synthesized and placed and routed with and
without the windows is the next commit.

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
