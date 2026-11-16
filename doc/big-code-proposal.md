# Programs larger than the Local Stores: paging code and data without restructuring

Status: built, with the changes listed in "What was built" below; the rest
of the document is the proposal as it was decided. The measurements
describe the tree at commit b9e3438 (2026-11-16).

## What was built

- **The ISA change of section 8.4**, in the emulator, the RTL (a new state,
  S_FA, after the tag-lookup sequencer; formal properties updated), the
  manual ("Far loads and stores") and three conformance tests (`farls`,
  `farlsx`, `farhint`). One rule was added: a far access whose line address
  is not a multiple of its size is an lsfault (a `tdata` that is not 8-byte
  aligned). The RTL remembers the last line a far access looked up, so a
  far load of the same line takes 3 cycles in sequence (a near load 2, a
  walk that hits the first way 7) and a far store to a dirty way 2 (8).
- **StrataOS serves `dmiss`** in the resident dispatcher (`xdmiss`), as
  section 8.4 describes; `tools/test-far.sh`.
- **Code units come from the program's image, not from a segment.** The
  first attempt put `sasm`'s units in the arena, where a program like vi
  (which uses all of its memory for text) overwrote them. Instead of the
  earlier proposal's code segments, an image now carries its units in a
  section of their own (kind 5); the kernel gives such a process its image as
  a share of its own and puts it in c15 at every switch-in, and `page_in`
  serves a miss outside c0 from c15. The units cost the program none of its
  memory; the image is still limited to 128 KiB.
- **`sasm`** pages code and uses far data by default for StrataOS programs
  (`-r`, `-n`, `.resident`, `.near`, `.pinned`, `-u`, `-c`, `-v`). Its rules
  came out of running real programs: a function is a target of `call`; a
  branch or jump to a function in another group becomes a far one (t6 is
  lost, as at a call); any other branch, jump or fall-through joins regions;
  a group larger than a unit stays resident instead of being an error. Every
  program of the tree is still built with `-r -n` and is byte for byte what
  it was; `tools/test-paged.sh` runs the vi and shell tests with vi (paged
  code and far data), sh (paged code; its data leaves no room for the cache,
  so `-n`) and five utilities built with the defaults.
- **`cc`** pages code and uses far data by default (`-r`, `-n`), as section
  8.6 describes, except that the cache is part of every far-mode image
  rather than carved from the heap on demand, and large automatic objects
  stay on the stack (`lang/cc/DESIGN.md`, "Far data").
- **The self-hosted `as`** follows `sasm` (`.resident`, `.near`, `.pinned`;
  it has no command line).

The question: how can a program whose code is much larger than the 32 KiB of
I-LS a StrataOS program has, and whose data is much larger than the 40 KiB of
D-LS it has, be written and compiled as if all its code and data were
present, with both loaded on demand, so that large C programs, interpreters
and games can be ported without being cut into code units or rewritten
around explicit transfers? Explicit units and explicit transfers must stay
possible. Sections 2 to 7 are about code, section 8 about data.

`doc/code-loading-proposal.md` asked where a loading service should live and recommended keeping
the miss mechanism in the dispatcher, adding code segments per thread, and
putting the policy in `proc`. This document is about the other side: what a
*program* must look like for that mechanism to page it, and who makes it look
like that. It uses that document's RTL miss costs and reuses its stages for
the kernel side. Section 9 says where the two differ.

## 1. Summary

- **The hardware cannot page plain code.** An instruction is fetched from the
  I-LS address in `pc`, untranslated. A `jal`, a branch or a `ret` into a
  slot that holds other code does not fault: it runs the other code. A jump
  outside the code window faults with `ifault`, but by then the link is an
  I-LS address and the jump's source is lost. The only translated control
  transfers are `xcall` and `xret`, and only they leave return addresses (far
  links) that survive eviction. So code must be *rewritten* into `xcall` and
  `xret` before it can be paged. A pager that runs on faults alone is not
  possible on this ISA. Emulating every jump between pages in a trap handler
  would make the measured programs 2.5 to 18 times slower.
- **The C compiler already does this rewrite.** `cc -p` turns every call into
  an `xcall` and every return into an `xret`, and function pointers into
  arena offsets. A C program is written as if all its code were present. What
  limits large C programs is not code: an image of at most 128 KiB, a function
  of at most 4 KiB and, above all, 40 KiB of data, because a C pointer is a
  D-LS address. Section 8 removes that limit.
- **For assembly, the assembler can do the same rewrite.** `sasm` sees the
  whole program; there is no linker. It can find the functions (the targets
  of calls), pack them into units, expand calls and returns, and reject what
  it cannot rewrite safely. Stralog's `mkimg.py` and the file server's
  `tools/check-fsunits.py` already check the hardest rule (no jump leaves a
  unit) after assembly, each for its own program.
- **Measured working sets are small.** vi touches 16 KiB of its 31 KiB,
  wdoom 11 of 18, the Stratalk interpreter 16 of 24, and Stralog 26 KiB of
  its 128 KiB including units. Paged whole through 2 KiB units, all four miss
  less than once per 30,000 instructions with a cache of 20 KiB or more. A
  rewritten call costs 2 instructions more. That adds 1% (vi, wdoom) to 6%
  (Stratalk); Stralog, which calls very often, would pay 14%.
- **The exception is the compiler.** `cc` touches 75 KiB of code while
  compiling itself and thrashes any cache that fits the I-LS: 229,810 misses
  in 74.9 million instructions. That is 42.4 million instructions in the
  dispatcher, **+57% today**. This is the case to expect from large
  one-pass programs, and only a larger overlay map really reduces it
  (section 7).
- **Data can be paged; the hardware already has the assist.** `ltag` and
  `linst` look an arena offset up in a set-associative tag table in the D-LS,
  and Stralog runs its whole far heap through such a cache (4 KiB, 3.1% of
  lookups miss). Unlike a jump, a load outside the D-LS faults precisely, so
  data could even be paged on faults alone, but at a trap per far access.
- **A far data model for C.** A pointer below 0x10000 is a D-LS address, one
  from 0x10000 up is an arena offset, the split `cc -p` already uses for
  function pointers. The stack, scalars and small statics stay in the D-LS;
  the heap and large objects go to the arena. A dereference tests the
  pointer and, when it is far, goes through an `ltag` cache in the D-LS. In
  `cc` compiling itself, 63 of every 1000 instructions are dereferences.
  Kept near, they would cost +6%. Made far, they would cost about +30%
  (+4 instructions per load, +6 per store); a 4 KiB cache misses on 0.7% of
  them.
- **`cc` pages code and data by default.** Flags turn either off for a
  tighter program: `-r` keeps all code resident, `-n` keeps all data near.
  Objects go near first and far only when the D-LS is full, so a program
  that fits pays only the pointer test (+6% for `cc`, nothing once the ISA
  change below exists) and the call sequences (+1% to +6%). Section 8.6
  gives the details.
- **One ISA change is worth weighing for data**: loads and stores beyond the
  D-LS doing the tag lookup themselves, with a dirty bit and a precise miss
  trap. That takes the +30% back to a few cycles per access, makes far data
  transparent to assembly too, and reuses the RTL's tag-lookup sequencer
  (section 8.4). Unlike the code-side change, it buys speed.
- **Recommendation: a hybrid with no ISA change to begin with.** The assembler
  and the compiler rewrite code into units at build time, under one
  convention, and the kernel pages them as it does now. Units come from a
  read-only segment, not from a copy in the arena, so images are no longer
  limited to 128 KiB (the earlier proposal's stages 2 and 3). `cc` gets the
  far data model in software and makes paged code and far data its defaults. The data ISA change is decided on the numbers
  from one large C program ported that way. Programs that manage their own
  units or transfers (the Forth, the Stratalk JIT, Stralog, wdoom's art) keep
  doing so. Section 10 lists the work.

## 2. What the machine catches

| Event | Result |
|---|---|
| `xcall` to a far address with no overlay entry | `xmiss`, `tval` = the far address; precise, retried after `eret` |
| `xret` through a far link (bit 63) whose unit is not mapped | `xmiss`, `tval` = the link; retried |
| `xcall` executed inside a mapped slot | its link is a far link: the caller may be evicted and come back in another slot |
| `jal`, a branch, `jalr` or `ret` to an address inside the code window | no fault: whatever is in that slot runs |
| fall-through past the end of a slot | no fault: the next slot's code runs |
| a jump to an address outside the code window or the I-LS | `ifault` at the target's fetch, `tval` = `pc` = the target; the jump's link is already written (an I-LS address) and its source is not recorded |

Only `xcall` and `xret` translate addresses, and only they protect return
addresses. A trap handler can fix up an `ifault` and continue at a slot. But
the code it continues runs at an address other than the one it was linked
for: its next jump out of the page goes wrong silently, and every link it
writes is a slot address. Plain code can be run paged only if every transfer
between pages traps, which means linking the code outside the I-LS. Then every
such transfer costs a handler, with the cost per 1000 instructions in the
"page changes" column of section 3.

**Miss cost.** The dispatcher's miss path is 184.5 instructions on the current
kernel, from the trap to the return to user mode. That is 42,393,629
instructions for `cc`'s 229,811 misses, and 184.4 for Stralog's. The earlier
proposal measured it on the RTL with 8 cores (on the tree of 2026-11-13; not
repeated here): 320, 418 and 674 cycles for 1, 2 and 4 KiB units with the
stream fetch, which is now the default, and 602, 614 and 870 with
`STREAM` = 0. Without the stream fetch the dispatcher's instructions hide the
transfer; with it the transfer shows, so smaller units are cheaper per miss.
A hit costs the same as a plain call.

## 3. Measurements

Method: the emulator, with a hook outside the tree, recorded the code a
user-mode program executes. Each record is a run of instructions inside one
64-byte block, keyed by the I-LS address for resident code, or by the arena
offset for a unit, found through the overlay map. A cache simulator replays
that through slots of 512 B to 4 KiB, a window of 4 to 32 KiB, at most 16
slots (the map), round robin as StrataOS replaces them, and LRU for
comparison. It matches the two programs that page today: 243,000 simulated
misses against 229,810 real ones for `cc` (+6%), and 29,300 against 30,120
for Stralog (−3%). The hook and the simulator are kept with the working notes,
not in the tree.

Workloads (8 cores, `-T virtual`; wdoom on 12 cores):
- `cc -p -h 0 -o c2 /src/cc.c`;
- the Stralog demo session (`lang/stralog/tests/demos.txt`);
- the seven Stratalk examples, interpreted;
- `vi /src/cc.c` with searches, scrolling, edits and `:wq`;
- the first 98 million instructions of `ws wdoom demo`.

| Program | Instructions | Code in the image | Code touched | Calls per 1000 | Page changes per 1000 (2 KiB) |
|---|---|---|---|---|---|
| `cc` | 74.9 M | 8.7 KiB resident + 107 KiB units | 74.6 KiB | 30.8 | 51.0 |
| Stralog | 243.0 M | 13.5 KiB resident + 115 KiB units | 26.4 KiB | 71.7 | 95.6 |
| Stratalk (interpreter) | 328.9 M | 24.3 KiB | 15.9 KiB | 28.0 | 54.5 |
| `vi` | 46.9 M | 31.3 KiB | 16.2 KiB | 5.2 | 13.3 |
| `wdoom` | 98.1 M | 18.5 KiB | 10.6 KiB | 6.6 | 8.3 |

The table below gives misses per 1000 instructions with the *whole* program
paged (resident part included) through 2 KiB units, 16 map entries and round
robin. Each column is a code cache of that size.

| Program | 32 KiB | 28 KiB | 24 KiB | 20 KiB | 16 KiB | 12 KiB |
|---|---|---|---|---|---|---|
| `cc` | 2.64 | 3.03 | 3.70 | 4.72 | 7.70 | 11.32 |
| Stralog | 0.004 | 0.006 | 0.012 | 0.033 | 0.072 | 0.226 |
| Stratalk | 0 | 0 | 0 | 0 | 0.005 | 2.28 |
| `vi` | 0 | 0 | 0.003 | 0.010 | 0.017 | 0.138 |
| `wdoom` | 0 | 0 | 0 | 0.003 | 0.009 | 0.013 |

How to read the tables:

- **Cost of a miss.** Each miss costs about 185 instructions of the dispatcher,
  so 1 miss per 1000 instructions is +18.5% in instructions. On the RTL as
  built (stream fetch) it is about 320 to 670 cycles per 1000 instructions,
  depending on the unit size.
- **Pure run-time paging (option 1).** It would pay that cost at every page
  change. For 2 KiB pages that is +150% (wdoom), +250% (vi), +940% (`cc`),
  +1000% (Stratalk) and +1760% (Stralog), before the handler has emulated
  anything.
- **Rewriting at build time (option 2).** Calls become 3 instructions instead
  of 1: +2 × calls per 1000. That is +1.0% (vi), +1.3% (wdoom), +5.6%
  (Stratalk) and +14% (Stralog). `cc` already pays it.
- **Programs whose working set fits.** A cache of 16 to 20 KiB serves vi,
  wdoom, Stratalk and Stralog, and their code could grow far past 32 KiB as
  long as what runs together stays near that size. Stralog today has a
  16 KiB cache (4 slots of 4 KiB) and pays +2.3% for 30,120 misses.
- **`cc`.** No layout within 16 map entries helps much:

  | `cc`, whole program paged, 28 KiB of cache | misses / 1000 | RTL cycles in misses / 1000 instructions | the same, `STREAM` = 0 |
  |---|---|---|---|
  | 4 KiB units, 7 slots | 2.53 | about 1,710 | about 2,200 |
  | 2 KiB units, 14 slots | 3.03 | about 1,270 | about 1,860 |
  | 1 KiB units, 16 slots (the map is full) | 5.19 | about 1,660 | about 3,120 |
  | today: resident 8.7 KiB, 4 KiB units, 5 slots | 3.38 | about 2,280 | about 2,940 |
  | 1 KiB units, 28 slots (a map of 32) | 2.48 | about 790 | about 1,490 |
  | 512-byte units, 56 slots (a map of 64) | 1.73 | about 520 (estimate) | about 1,040 (estimate) |

  (Misses times the measured cost per miss; the cost of a 512-byte miss is
  extrapolated.)

  LRU instead of round robin would save 15 to 20% of the misses. Nothing in
  the hardware tells the dispatcher which slot was used last.

## 4. The unit of loading, placement, and code addresses

**Fixed slots, functions packed.** The overlay map forces the shape. With
`xslot` = n every unit is 2^n bytes on a 2^n boundary, one size per thread.
Exact mapping (`xslot` = 0) could place single functions, but it makes no
far links, so a caller could never be evicted under its callee: it is
excluded. Within that shape there are two choices:
- **Pages of the linear image.** These need no rewrite at all. But a function
  then straddles pages, so its own branches cross pages, and only a fetch
  that translates (section 7) could run that.
- **Functions packed into units.** No branch leaves a unit; only calls and
  returns do, and those are what `xcall` and `xret` handle. This is what
  `cc -p`, Stralog and the kernel's units do, and what a tool can produce.

**Size.** 2 KiB is the default to recommend. Sixteen map entries cover 32 KiB
only with 2 KiB units: 1 KiB units leave half the window unused, and 4 KiB
units give too few slots. A program with functions over 2 KiB, or with
`cc`'s pattern, chooses 4 KiB. `xslot` is per thread, so a program that also
manages explicit units of its own (a JIT) must use the same size.

**Placement and eviction.** Unchanged: round robin over the slots after the
pinned part, never the slot of the instruction that missed. The per-thread
record restores the cache after a context switch, so a `pc` or an `epc` inside
a slot stays valid.

**Return addresses: solved by the hardware, under one rule.** A call that may
lead to paging must be an `xcall` executed in the caller's own unit. Only
then is its link a far link, which `xret` resolves wherever the caller is now,
or pages back in. Two consequences:
- *Every* such call is rewritten, including calls within one unit. A callee in
  the same unit that calls out may have the unit evicted and reloaded
  elsewhere, and a plain link to the old slot would then lead into other code.
  Only a callee that is a leaf with respect to paging can keep `jal`: it calls
  nothing outside its unit except pinned code, transitively. The tool can see
  that in the call graph.
- Pinned code called with a plain link from a unit must never page, because
  the link points into a slot. This is `cc`'s rule ("library functions are
  leaves with respect to paging") and Stralog's ("resident code that a unit
  calls never calls a unit"). The tool checks it. A pinned function that does
  call into units (a callback, an interpreter's dispatch loop) must not be
  called from a unit. Making it pageable is the simplest fix.

**Function pointers.** A function pointer is the function's arena offset, and
an indirect call is `xcall ra, c0, reg`. Pinned functions keep their I-LS
address, and an indirect call tells the two apart: `cc` tests whether the
value is below 0x10000, which costs a few instructions. Equality and ordering of function
pointers still work. A program may keep and compare code addresses in data
structures, jump tables, saved continuations or `setjmp` buffers. Each must
be an arena offset or a far link and be entered with `xcall` or `xret`. The
tool can convert the forms it recognises: a code label in `la` or `.dword`, a
computed jump within a unit (made PC-relative with `jal rX, .+4`, since there
is no `auipc`). It must reject the rest. This is where hand-written assembly
needs attention, and where a source change is sometimes unavoidable.

**Return through an interrupted unit.** Nothing new: a thread preempted inside
a slot gets the slot back on switch-in, as now.

## 5. The options

**1. Pure run-time demand paging on faults.** The program is linked as one
large image outside the I-LS. Every transfer that leaves a page faults, and
the handler translates and continues. Not possible as such (section 2): the
continued code is not at its linked address. Emulating every transfer in a
handler costs 2.5 to 18 times the program's own work (section 3). Only an ISA
change makes this option real (section 7).

**2. Splitting at build time, with automatic call sequences.** The build
packs functions into units and rewrites:
- calls into `lui/ori t6, f` + `xcall ra, c0, t6`;
- returns into `xret ra`;
- calls of pinned code from units into an absolute `jalr` through a register;
- code addresses into offsets.

No source change, as long as the code keeps to the rules of section 4.
Shared trampolines (one resident stub per function, reached by an unchanged
`jal`) do not work: the `xcall` would then execute in the stub, and the
caller's link would be a slot address. The longer call sequence must be at
the call site, so the code grows and branch offsets change. That is why this
belongs in the assembler, which knows every label, not in a pass over a
finished image.
- For C, it exists (`cc -p`).
- For assembly, it is a mode of `sasm`. sasm has no local labels, so
  "function" means a label that is the target of a call. A unit is a run of
  such functions together with whatever their branches reach. A run larger
  than a unit is an error naming the branch, as `mkimg.py` reports today.
- The rewritten call needs a scratch register (`t6` by convention). The
  assembler must check that it is not live across the call. In this tree `t6`
  is used in vi, ws, Stratalk and wdoom, and `gp` is a data base register in
  wdoom and kira. So the convention must not take `gp`, and the scratch
  register must be configurable per program.

**3. A hybrid.** Option 2 for the shape of the code. At run time, the kernel's
existing pager, with three additions:
- the units come from a read-only segment of the program file, not a private
  copy;
- the image limit no longer applies to units;
- a profile chooses what to pin. The emulator can produce it; this proposal's
  hook is a start.

| | 1. run-time only | 2. build-time split | 3. hybrid |
|---|---|---|---|
| Source changes | none | none within the rules; rejected constructs named by the tool | as 2 |
| Works on the current ISA | no | yes | yes |
| Cost of a hit | none | +2 instructions per call (+1% to +14%) | as 2; pinned hot code pays nothing |
| Cost of misses | every page change traps (+150% to +1760%) | the miss rate of section 3 | as 2, lower with a profile-chosen pinned set |
| Return addresses, function pointers | far PCs (with the ISA change) | far links, arena offsets; checked by the tool | as 2 |
| Image size | n/a | 128 KiB with today's loader; workaround: a units file read at start-up (as `cc`, Stralog) | units paged from a segment: no limit but the arena's |
| Kernel | n/a | none | segments (the earlier proposal's stage 2), sharing (stage 3) |
| Toolchain | n/a | `sasm` paged mode; `cc -p` unchanged | as 2, plus a pinned list or profile |

## 6. What it meets in the system

- **Per-thread slot records and context switches.**
  - Unchanged. A switch-in reloads every recorded unit, so a paged program
    costs what a resident program of its cache's size costs: up to 32 KiB per
    switch, as for vi today.
  - A program with a small cache could switch cheaper, but the dispatcher
    cannot know which units will be needed.
- **Several threads of one program.** Each thread has its own record and cache.
  Two threads on one core reload each other's units. Threads on separate cores
  page separately; the units are read-only, so nothing needs to be kept
  coherent.
- **The kernel's far image.** It is the same mechanism with the same rules:
  2 KiB units, round robin, far links. Core 0 moves its units to T2 because a
  miss from T2 starts after 4 bus cycles instead of 20. A program's units
  could get the same benefit only if T2 had room; it does not today.
- **Capabilities.**
  - `tgetx` needs execute permission on the capability it reads. Today that
    is `c0`, the arena, which is writable, so a program can overwrite its own
    units.
  - With segments, units come from a read+execute share that nobody can write
    and that any number of processes can hold (`cshare`).
  - The overlay map itself is the authority for `xret`. A map entry exists
    only because a capability with execute permission allowed the `tgetx`.
- **Explicit units.**
  - They keep working: the paged mode is a choice per program.
  - A program can mix: build-time units for its own code and units it makes
    at run time (Stratalk's JIT, the Forth), provided both use one `xslot`
    and one miss path.
  - A program with a trap handler of its own passes misses on with svc PAGE,
    as the Forth does.
- **Debugging.** Code in a unit has an arena offset rather than an I-LS
  address. `sasm -g` maps would need a section for paged code, and the
  debugger would have to resolve slot addresses through the overlay map, as
  the hook here does.

## 7. ISA changes considered

**(a) Fetch through the overlay map ("far PC").**
- *What it is.* A `pc` with bit 63 set would be a far address. The fetch
  looks it up in the map like an `xret` target, and a miss is `xmiss` with
  `tval` = `pc`. `jal` and branches then work in far space, every link is
  a far link, and a function pointer is a far PC.
- *What it buys.* Option 1 becomes real: plain code, linked at a far base,
  paged through pages of the linear image, with no rewriting and no
  conventions for assembly.
- *What it does not change.* The miss rates of section 3 stay the same, so
  the expensive cases stay expensive. It saves the 2 instructions per call.
- *What it costs the RTL.*
  - `pc` arithmetic is 17 bits today (`pc4`) and 24 bits for branches
    (`pc_br`); it becomes far-address wide.
  - F0 gains a CAM lookup in front of the I-LS address. It can reuse the
    16 comparators `xcall` uses in EX, but it sits on the fetch path, which
    probably means an extra cycle on every transfer into far code.
  - The `STREAM` read-ahead must stop at slot boundaries. It already stops
    at window units (`i_brk`).
  - `epc`, `tval` and the links widen.
- *What it costs elsewhere.* The emulator's predecoded loop and both JITs
  (native and WebAssembly) key code by I-LS address and need a translation
  step. The conformance suite and the formal proofs change, as does the
  debugger.
- *Verdict.* Not worth it now. The assembler can do the rewrite, and the
  change buys convenience, not speed.

**(b) A larger overlay map (NXMAP up to 32).**
- *What it buys.* Smaller units can fill the window. For `cc` that halves the
  misses (2.48 per 1000 with 1 KiB units in 28 slots, 1.73 with 512 B units
  in 56, against 3.03 with 2 KiB units). With the stream fetch a small unit
  is also cheaper per miss, so the time spent in misses falls by about 40%
  (1 KiB) to 60% (512 B). For the programs whose working set fits, it
  changes nothing.
- *What it changes, exactly.*
  - The platform range of NXMAP goes from 4..16 to 4..32.
  - `xmap` and `xunmap` take their entry number from bits 24:21, with bit 25
    fixed at 0 (an index with bit 25 set is illegal today). Bit 25 becomes
    the top bit of a 5-bit index, so no encoding is added. A map of 64 would
    need one of the spare `funct` bits as well, and the measurements do not
    ask for it.
  - The platform table already gives NXMAP in a 16-bit field.
- *What it costs.*
  - Comparators on the `xcall`/`xret` path only, not on the fetch: 32
    instead of 16, and a wider priority encoder.
  - The per-thread record grows: `PR_UNITS` from 16 to 32 entries.
  - A switch-in issues more, smaller transfers.
- *Verdict.* The only lever for big working sets. Consider it once a program
  like `cc` matters for speed.

**(c) A fault that reports the source of a jump.** It would not help: what is
missing is translation, not information.

## 8. Data

### 8.1 What limits C programs, and what the machine has

- **The limit.**
  - A C pointer is a D-LS address (`lang/cc/DESIGN.md`, section 2). A
    program's data, heap included, lives in D-LS 0..0x9FFF (40 KiB), with an
    8 KiB stack.
  - The arena (1 MiB by default, up to 255 MiB with the shell's `-m N`) is
    reachable only through `far_read` and `far_write`.
  - The design rejected far pointers because a software cache behind every
    dereference "would cost a check per access and code the 32 KiB
    instruction store has no room for". Paged code removes the second half
    of that objection; the first half is measured below.
- **The translation the machine has.**
  - Loads and stores reach only the D-LS. The two D-LS windows relocate 1 KiB
    units inside the 64 KiB store, so they cannot name more than 64 KiB.
  - The software-cache assist (manual, "Software data caches") can. `ltag rd,
    rs` looks an arena offset up in a set-associative tag table in the D-LS.
    A hit gives the D-LS address of the byte; a miss gives the victim line
    with bit 63 set. `linst` records a new line.
  - The geometry is in `ttag`, `tdata` and `tgeom`, which the dispatcher
    already saves and restores per thread. The lines and tags are ordinary
    D-LS data, so they travel with the thread.
- **A cache that already works.** Stralog keeps its atoms, clauses and older
  stack cells in the arena behind exactly such a cache: 4 KiB, 64-byte lines,
  2 ways, write-back with a dirty byte per line (`lang/stralog/core.s`,
  `crd`/`cwr`/`fc_fill`).
  - A read hit is 3 instructions (`ltag`, `bltz`, `ld`); a write hit is 7.
  - In the demo session it did 4,756,865 lookups and 145,805 fills: 3.1%
    miss.

### 8.2 What the machine catches, for data

Data differs from code here. A load or store outside the D-LS (or outside
the windows) traps with `lsfault`, precisely, with `tval` = the address. The
handler can perform the access itself and step past it:
- decode the instruction;
- look the address up in the tag table, filling a line if it is missing;
- write the destination register, or the line.

So far data with *no* compiler change is possible on this ISA. It costs a
trap per far access, not per miss: probably 60 to 100 instructions (not
measured; the code miss path, which keeps more records, is 184). At `cc`'s
63 dereferences per 1000 instructions that is +400% to +600%. It is useful
only as a fallback: for rare accesses, and for assembly nobody has converted.

### 8.3 A far data model for C, without an ISA change

- **Pointers.** One 64-bit value. Below 0x10000 it is a D-LS address (near);
  from 0x10000 up it is an arena offset (far). NULL is 0.
  - This is the split `cc -p` already makes for function pointers, so a C
    pointer of either kind has one rule.
  - Arithmetic, comparison within an object, and casts to and from integers
    are unchanged.
  - Code units and far data share the arena's offsets but never a pointer
    type, so the two cannot be confused.
- **Where objects go.** Named objects are placed by the compiler, which
  addresses them directly as now:
  - near: the stack (through `sp`), scalars and small statics (through
    `zero` and `gp`);
  - far: what does not fit. Statics and string literals are placed near as
    they are declared, until the D-LS budget for them is used up; later ones
    go far. `malloc` returns near memory while the near heap has room and
    arena memory after that. Large locals and variable-length arrays go on
    a second stack in the arena.
  - So a program whose data fits has no far objects at all, and all its
    pointers are near.
  - Only accesses through pointers change.
- **A dereference.** `gp` is 0x10000 in `cc`'s convention, so the test is one
  instruction: `bgeu p, gp, far`. The near path is the old load or store.
  - A far load is inline: `addi t, p, off; ltag t, t; bltz t, miss;
    ld x, 0(t)`.
  - A far store also marks the line dirty, in 2 or 3 instructions with a
    dirty byte per line.
  - A miss calls a routine in the C library that writes the victim back if it
    is dirty, `tget`s the line and `linst`s it: Stralog's `fc_fill`, about 30
    instructions plus the line's transfer.
  - Natural alignment keeps a scalar inside one line.
- **Block operations.** Structure copies, `memcpy`, `memset`, the string
  functions, `far_read` and `far_write` handle any mix of near and far:
  through the cache, or by writing back and dropping a range and then
  transferring it directly.
- **The cache.** It lives in the D-LS: 4 to 8 KiB plus tags and dirty bytes.
  It is carved from the near heap when the first far object appears, so a
  program that never goes far never gives up the space. It travels with the
  thread like any other data.
- **Code size.** The far path cannot be a shared routine without a register
  convention for the address and the value, so it sits out of line at the
  end of each function: the test stays inline (+1 word per dereference), the
  far path adds about 6 words per dereference site. That growth, not the
  speed, is the main reason to turn far data off for a small program.
- **The default.** `cc` uses this model unless told not to (section 8.6).

**Measured**, on `cc` compiling itself: a C program built by `cc`, 74.9
million instructions, counted by the base register of every load and store.

| Accesses | Share | Per 1000 instructions |
|---|---|---|
| all loads and stores | | 293 |
| through `sp` (the stack) | 47% | 138 |
| at fixed addresses (`zero`) | 31% | 91 |
| through a pointer | 21% | 63 (26% of them stores) |

Those 4.7 million pointer accesses were replayed through write-back caches
of `ltag`'s geometry, with round robin in each set as `linst` does:

| Cache | Line | Ways | Misses (% of pointer accesses) | Write-backs (%) |
|---|---|---|---|---|
| 2 KiB | 64 B | 2 | 1.72 | 0.44 |
| 4 KiB | 64 B | 2 | 0.69 | 0.22 |
| 4 KiB | 64 B | 4 | 0.49 | 0.22 |
| 8 KiB | 64 B | 2 | 0.26 | 0.11 |
| 16 KiB | 64 B | 2 | 0.07 | 0.03 |

The cost in instructions follows.
- **Every pointer stays near:** +1 per dereference, **+6%**. This is the
  price of the model for a program that does not need it.
- **All of them far**, with a 4 KiB cache:
  - +4 per load and +6 per store hit: +28%;
  - 0.43 misses per 1000 instructions at about 30 instructions each: +1.3%;
  - in all, **about +30%**.
- Each miss also waits for a 64-byte line from system memory, and a quarter
  to two fifths of the misses also write a line back.

These working sets are a lower bound. `cc` was written to keep its pointer
data inside 40 KiB, while a program written for flat memory touches more.
Stralog's real far cache, which serves a large heap, misses on 3.1% of
lookups at 4 KiB. The miss rate of a ported program is the number to
measure first.

### 8.4 An ISA change: loads and stores through the tag table

The change reuses what `ltag` and `linst` already define: the geometry CSRs
`ttag`, `tdata` and `tgeom`, and the tag table in the D-LS. It adds an enable
bit, dirty bits, and one trap cause. A program that does not set the enable
bit sees no difference anywhere.

**1. An enable bit.** `tgeom` bit 16 is **FA** (far access). Today the bits of
`tgeom` above 15 are ignored, and no program in the tree sets bit 16.

**2. Loads and stores** (`lb` to `ld`, `sb` to `sd`).
- Only an address at or above `DLS_SIZE` takes the new path. Every such
  access traps with `lsfault` today, so nothing that works now changes.
- An address inside the D-LS but outside the user-mode windows still traps
  with `lsfault`, so the kernel's protection is untouched.
- The path works in either mode, so bare-metal programs and conformance tests
  can use it.

```
addr = X[rs1] + SignExtend(imm16, 64);
if addr MOD n != 0 then Trap(lsfault, addr); end
if UInt(addr) >= DLS_SIZE and TGEOM<16> == 1 then             // far: through the tag table
    lsh, set, eb, pe, key, ctr as in LTAG for offset addr;       // the same lsfault on a bad table
    if lsh < 3 then Trap(lsfault, addr); end                     // a line holds any aligned scalar
    w = the way whose tag word == key, else Trap(dmiss, addr);
    pa = Window(FALSE, TDATA + ((set*ways + w) << lsh) + (addr AND ((1 << lsh) - 1)), n);
    if pa == FAULT then Trap(lsfault, addr); end
    Stall as now while [pa, pa+n) overlaps an in-flight transfer;
    load:  X[rd] = DLS.Read(pa, n), extended as now;
    store: DLS.Write(pa, n, ...);
           if ctr<32+w> == 0 then DLS.Write(pe + 8*ways, 8, ctr OR (1 << (32 + w))); end
else
    ... exactly as now (lsfault if addr > DLS_SIZE - n, the windows, the stalls)
end
```

Natural alignment and lines of at least 8 bytes keep an access inside one
line. The existing stall rule applies to the line, so a miss handler can
issue its `tget`, `linst` and `eret` without waiting: the retried access waits
for its bytes.

**3. Dirty bits go in the set's counter word, not in the tag.** The counter
doubleword that follows each set's tags holds only the round-robin index
today (0 to 14). It becomes:

| Bits | Meaning |
|---|---|
| 3:0 | the replacement index, as now |
| 32 + w | way w is dirty (ways 0 to 14) |
| others | zero |

The tag format, `(line << 1) | 1`, does not change. `ltag` and `linst` change
in three small ways:
- `ltag` takes the victim from `ctr<3:0>` (if below `ways`, else 0) instead of
  from the whole word.
- On a miss, `ltag` also sets bit 62 of its result when the victim way is
  dirty. Existing code clears bit 63 with `slli 1; srli 1`, which would keep
  bit 62. That is safe, because only a far store with FA set ever sets a
  dirty bit.
- `linst` writes the next index into bits 3:0, clears the victim way's dirty
  bit and leaves the other bits as they were.

Software that never sets FA finds the counter word exactly as before. A flush
routine finds the dirty lines by reading the counter words, which are
ordinary D-LS memory, and clears the bits with ordinary stores.

**4. A new cause.** 15 = **dmiss**: a far load or store whose line is not in
the tag table. `tval` is the address. The trap is precise, `epc` is the load
or store, and `eret` retries it. It takes the instruction's own place in the
order of checks: after a misaligned address (`lsfault`) and a bad table
entry (`lsfault`). Routing is the usual: the program's handler if it has
installed one, otherwise the supervisor.

**5. Serving the miss.** By default the dispatcher serves it, as it serves
`xmiss` for code. It needs no per-thread records: the geometry is in the
thread's CSRs and the lines and tags are the thread's data. About 30
instructions:
1. Reject an offset outside `c0`. The program then ends with a fault, as for
   an `xmiss` that cannot be served.
2. `ltag` the address to find the victim.
3. If bit 62 says the victim is dirty, read its old tag and `tput` its line to
   `c0` at that line's offset.
4. `tget` the new line from `c0` into the victim's storage.
5. `linst` the address, and `eret`.

A program with a trap handler of its own serves its misses itself, or passes
them on, as the Forth passes on code misses with svc PAGE.

**What it buys.**
- Every dereference is the plain load or store: no pointer test, no `ltag`,
  no dirty byte. The +30% of section 8.3 becomes the lookup's cycles.
- `cc` emits ordinary loads and stores for every dereference, near or far.
  Its start-up sets the three CSRs with FA, and `malloc` returns arena
  offsets once the near heap is full.
- Assembly gets far data with no rewriting: a pointer can simply be an arena
  offset.

**What it costs the RTL.**
- In EX, a load or store already compares its address with `DLS_SIZE` to raise
  `lsfault`. With FA set, it goes instead to the existing tag-lookup sequencer
  (`S_LG`/`S_LT`), keyed by the address and marked as a load or a store.
- On a hit it continues to `S_LD`, or makes the store. A store to a clean way
  then rewrites the counter word, like `linst`'s second write (`S_LW`).
- A miss raises `dmiss`.
- The `ltag`/`linst` datapath changes only in the counter's mask, bit 62 of
  the result, and `linst`'s write of the counter.
- Speed: the sequencer reads one table word per two cycles, so a 2-way lookup
  plus the counter word takes about 6 cycles. That is the work `ltag` does
  today; what the change saves is the 4 to 6 instructions around it.
  An implementation may remember its last hit to skip repeated lookups. That
  is a choice of the implementation, not part of the ISA, and it must forget
  the hit on any store into the tag table and on `linst`.

**What it costs elsewhere.**
- **Emulator:** the slow path of loads and stores, and `ltag`/`linst`. The
  predecoded loop and both JITs already leave their fast path on an
  out-of-range address; there they check FA.
- **Manual:** the load and store pages, `ltag`, `linst`, the `tgeom` figure,
  the cause tables. Also the cause names in `common/stx.h` and the debugger.
- **Conformance tests:** FA = 0 unchanged, hits, misses, dirty bits, `linst`
  clearing a dirty bit, and `ltag`'s bit 62.
- **Formal proofs:** the properties of the load/store path.
- **Kernel:** the dmiss service, which fits in the worker extension.

**Verdict.** Unlike the far PC of section 7a, this buys speed as well as
transparency, and its parts exist in the RTL. Decide it after the software
model has run one large C program, with that program's miss rate and
instruction counts in hand.

### 8.5 What far data meets in the system

- **Threads.** Each thread's cache is private. Two threads that share far data
  (on different cores, or the same core) see stale lines unless each writes
  back and drops the shared range at its synchronisation points. A
  single-threaded port is unaffected. A threaded one needs flushes at its
  locks, which the library's lock calls can make.
- **Explicit transfers.** A program that also uses `tget`/`tput`, `far_read`
  or `far_write` on far data must not bypass dirty lines. The library's
  versions write back first.
- **Context switches.**
  - The cache is part of the data extent, so a resident thread pays nothing.
  - An evicted thread pays the cache's size, and its dirty lines stay dirty
    in the save area, which is correct.
  - A switch neither flushes nor drops lines.
- **Code paging.** Independent: one is the I-LS and the overlay map, the other
  the D-LS and the tag table. Both use the arena: the code units from 0x10000,
  far data after them.
- **Debugging.** A far pointer is an arena offset. To show what it points at,
  the debugger must look in the program's cache before the arena, because
  the arena may be stale.

### 8.6 `cc`'s defaults, and the flags that turn them off

`cc` pages code and uses far data unless told otherwise. A program is written
and compiled without flags whether it fits the Local Stores or not. The flags
make a program tighter when it is known to fit:

| Flag | What it turns off | What the program gets |
|---|---|---|
| (none) | | paged code (today's `-p`) and far data (section 8.3) |
| `-r` | paged code | today's default: all code resident, calls are `jal`, no units; an error if the code does not fit the I-LS |
| `-n` | far data | today's data model: no pointer test, no cache, no far path; an error if the data does not fit the D-LS |
| `-r -n` | both | exactly today's default output |

`-p` stays accepted and means the default. Two size options come with the
defaults: `-u KIB` for the unit size (4 KiB, as now, until stage A's
measurements say otherwise) and `-c KIB` for the data cache (4 KiB).

What the defaults cost a program that would have fitted, measured on `cc`:
- **Paged code.**
  - +2 instructions per call: +6% at `cc`'s 31 calls per 1000 instructions,
    +1% for vi- and wdoom-like code.
  - One miss per unit at start-up.
  - Misses beyond that only if the working set exceeds the cache, as for
    `cc` itself.
- **Far data, with no far objects** (near-first placement).
  - The pointer test: +1 instruction per dereference, +6% for `cc`.
  - About 1 word of code per dereference, plus the out-of-line far paths.
  - No D-LS: the cache is never made.
- **Far data after the ISA change of section 8.4.**
  - The hardware chooses near or far by address, so the compiler emits the
    plain load or store: no test and no far path.
  - The default then costs a program that fits nothing at all, and `-n` only
    turns off the library's far support.

`cc` compiles in one pass, so it learns whether a program fits only at the
end, after the call and dereference sequences are emitted. It cannot drop to
the tight model by itself without compiling a second time. That could be
offered later as an option, but it is not the default, because it doubles
compile time.

Consequences for the build and the tests:
- **The bootstrap.**
  - `cc0`, the bootstrap compiler in assembly, keeps today's models: it only
    has to compile `cc.c`.
  - `cc` itself is built with `-n`, because its data fits by design.
  - `test-cc-boot` keeps comparing the same files.
- **The test ladder.**
  - It runs in the default model.
  - A subset also runs with `-r`, `-n` and `-r -n`, so that the tight models
    stay correct.

## 9. Where this differs from the earlier proposal

- **What is paged.** The earlier proposal did not plan to page the resident
  code. Here everything is paged except a small pinned part, because that is
  what lets a program be written as if all of it were present. The
  measurements show that it costs nothing for programs whose working set fits.
- **The assembler's part.** The earlier proposal's stage 1 gives `sasm` a unit
  directive and a far-call pseudo-instruction, which a programmer writes by
  hand. Here the assembler finds the units and expands the calls itself. The
  directive stays, for programs that want explicit units.
- **What is the same.** The kernel side is the earlier proposal's: the
  mechanism in the dispatcher, segments per thread, policy in `proc`, no
  server on the miss path, units read from memory and never from the disk
  one miss at a time.

## 10. Recommendation and work

Option 3 for code, the far data model for C, in stages, with no ISA change
to begin with. Stages A to C are code, D and E data; they are independent of
each other.

**Stage A: a paged mode in `sasm`.** No kernel change.
- Functions found from call targets; packing into units of 2^n bytes (2 KiB
  by default); calls, returns, unit-to-pinned calls and code addresses
  rewritten as in section 5.
- Errors, naming the instruction, for:
  - a branch leaving a unit;
  - a scratch register live across a call;
  - a code address used in a way the tool cannot convert;
  - pinned code called from a unit that calls back into a unit.
- A `.pinned` directive, and an option that reads a list of pinned functions.
- The output is the image (pinned code and data) plus a units file that the
  start-up code reads into the arena, as `cc` and Stralog do now.
- The same in the self-hosted `as`, later.
- Check: vi, wdoom and Stratalk's VM built paged with a deliberately small
  pinned part, with their tests passing unchanged. One of them made larger
  than 32 KiB on purpose (vi with all its syntax tables, say).

**Stage B: units from a segment.** This is the earlier proposal's stage 2
(code segments per thread, ATTACH/DETACH, `page_in` by segment), then its
stage 3 for the image (`proc` loads the units file once, shares it read-only,
SPAWN attaches it). The 128 KiB limit then applies to the pinned part and the
data only. `cc` and Stralog stop reading their units into their arenas.

**Stage C: a profile.** The emulator writes, per program, how often each
function runs and misses. The hook used here records code blocks; a symbol map
turns them into functions. `sasm` takes the result as the pinned list. Pinning
`cc`'s hottest few KiB is the cheapest experiment on its +57%.

**Stage D: far data in `cc`, and the new defaults.**
- The model of section 8.3: the pointer test, far loads and stores through an
  `ltag` cache, the miss routine, near-first placement of statics and the
  heap, large locals in the arena.
- The defaults and flags of section 8.6: paged code and far data on, `-r` and
  `-n` to turn them off, `-u` and `-c` for the sizes.
- In the library: block operations, `far_read`/`far_write` and the flush, for
  near and far alike.
- `cc` counts its cache's lookups, misses and write-backs, as Stralog's
  `statistics/0` does.
- Check:
  - the C test ladder in the default model, and a subset with `-r`, `-n` and
    `-r -n`;
  - a program with several MiB of heap (run with `-m`);
  - `cc` itself, built with `-n`, still reproducing itself;
  - the cost on programs that fit, in instructions and in code size, against
    `-r -n`.

**Stage E: decide on loads and stores through the tag table** (section 8.4),
with stage D's numbers from a ported program. If adopted, `cc` drops its
pointer tests and far paths, and the miss routine moves to the run-time
library or the dispatcher.

**Optional, later:**
- a shorter miss path (184 instructions, of which the record keeping is a
  part);
- `cc`: functions over a unit split at basic blocks;
- NXMAP 32 (section 7b), if `cc`-like programs matter for speed.

**What ports most easily:**
- C programs within the data limits: already, with `cc -p`.
- C programs beyond them: with no flags at all once stage D exists, at the
  cost of section 8.3.
- Assembly that calls with `call`/`ret`, keeps code addresses only in
  registers and calls, and does not keep values in the scratch register
  across calls. A first count of `gp`, `t6`, `jalr` and `la` in vi, ws,
  the Stratalk VM and `os/progs` suggests most of them do; the tool
  decides.
- Games, as far as code is concerned: wdoom's working set is 11 KiB.

**Risks:**
- **Far data's cost is measured only on a program that does not need it.**
  The +30% and the miss rates of section 8.3 come from `cc`, whose data fits
  in 40 KiB. A program written for flat memory may miss more. Stralog's 3.1%
  is the only real far-cache figure.
- **Far data and threads.** Threads that share far data must flush at their
  synchronisation points. A C program that relies on shared memory without
  locks will see stale data.
- **The D-LS gets tighter** for a program that goes far: the data cache takes
  4 to 8 KiB of the 40 KiB for near data.
- **The defaults cost programs that fit** until the ISA change: +6% (`cc`) in
  pointer tests and some code growth, unless they are built with `-n`. The
  flags exist for that; the risk is that nobody uses them.
- **Programs with large working sets.** They pay +50% or more in
  instructions, as `cc` does today. Only pinning and a larger map reduce it.
- **Hand-written assembly with its own conventions.** Some code uses `gp` as a
  data base or keeps values in `t6` across calls, and some code keeps code
  addresses in tables. It needs either source changes or a tool that can
  prove more. The tool must reject what it cannot prove, never guess.
- **Every call that may lead to paging becomes an `xcall`.** Debuggers,
  backtraces and anything that reads return addresses see far links.
- **Switch cost.** A paged program's whole cache is reloaded on every switch,
  as resident code is now. Many paged programs sharing a core switch as
  expensively as large resident programs do today. Since threads keep their
  data resident in D-LS slices, code is most of what a switch moves, so
  this matters more than it did.
- **One unit size per thread.** A program that both builds units and JITs
  code must agree on it.

## 11. Questions

1. **Scope.**
   - Is stage A worth doing on its own? With the units-file workaround, it
     already lets assembly programs exceed 32 KiB.
   - Or should it wait for the segments of stage B?
2. **The convention.** Should the scratch register for rewritten calls be
   fixed (`t6`, as `cc` uses) or chosen per program?
3. **Data for C.**
   - Should `cc` get the far data model of section 8.3, on by default as
     section 8.6 proposes (stage D)?
   - Should loads and stores through the tag table (section 8.4) be
     considered only after a large C program has been ported in software, as
     recommended, or earlier?
4. **NXMAP.** Is a larger map acceptable as a platform option, given that
   only programs like `cc` gain from it?
