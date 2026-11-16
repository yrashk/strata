# Programs larger than the instruction store: paging code without restructuring

Status: a proposal. Nothing under "Options", "Recommendation" or "Work" is
implemented. The measurements describe the tree at commit b9e3438
(2026-11-16).

The question: how can a program whose code is much larger than the 32 KiB of
I-LS a StrataOS program has be written and compiled as if all its code were
present, with the code loaded on demand, so that large C programs,
interpreters and games can be ported without being cut into code units by
hand? Explicit units must stay possible.

`doc/code-loading-proposal.md` asked where a loading service should live and recommended keeping
the miss mechanism in the dispatcher, adding code segments per thread, and
putting the policy in `proc`. This document is about the other side: what a
*program* must look like for that mechanism to page it, and who makes it look
like that. It uses that document's RTL miss costs and reuses its stages for
the kernel side. Section 8 says where the two differ.

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
  D-LS address.
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
- **Recommendation: a hybrid with no ISA change.** The assembler and the
  compiler rewrite code into units at build time, under one convention. The
  kernel pages them as it does now. Units come from a read-only segment, not
  from a copy in the arena, so images are no longer limited to 128 KiB (the
  earlier proposal's stages 2 and 3). Programs that manage their own units
  (the Forth, the Stratalk JIT, Stralog) keep doing so. Section 9 lists the
  work.

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

**(b) A larger overlay map (NXMAP up to 32 or 64).**
- *What it buys.* Smaller units can fill the window. For `cc` that halves the
  misses (2.48 per 1000 with 1 KiB units in 28 slots, 1.73 with 512 B units
  in 56, against 3.03 with 2 KiB units). With the stream fetch a small unit
  is also cheaper per miss, so the time spent in misses falls by about 40%
  (1 KiB) to 60% (512 B). For the programs whose working set fits, it
  changes nothing.
- *What it costs.*
  - Comparators on the `xcall`/`xret` path only, not on the fetch. The map
    is already a platform parameter (4 to 16), so the change is to its
    range.
  - The per-thread record grows: `PR_UNITS` from 16 to 32 or 64 entries.
  - A switch-in issues more, smaller transfers.
- *Verdict.* The only lever for big working sets. Consider it once a program
  like `cc` matters for speed.

**(c) A fault that reports the source of a jump.** It would not help: what is
missing is translation, not information.

## 8. Where this differs from the earlier proposal

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

## 9. Recommendation and work

Option 3, in stages, with no ISA change.

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

**Optional, later:**
- a shorter miss path (184 instructions, of which the record keeping is a
  part);
- `cc`: functions over a unit split at basic blocks, and `-p` with 2 KiB
  units;
- NXMAP 32 (section 7b), if `cc`-like programs matter for speed.

**What ports most easily:**
- C programs within the data limits: already, with `cc -p`.
- Assembly that calls with `call`/`ret`, keeps code addresses only in
  registers and calls, and does not keep values in the scratch register
  across calls. A first count of `gp`, `t6`, `jalr` and `la` in vi, ws,
  the Stratalk VM and `os/progs` suggests most of them do; the tool
  decides.
- Games, as far as code is concerned: wdoom's working set is 11 KiB.

**Risks:**
- **Data, not code, limits large C programs.** A C object must live in the
  40 KiB of D-LS, with no far pointers (`lang/cc/DESIGN.md`, section 2).
  Large C programs, interpreters written in C and games keep far more than
  that. Paging code does not address it, and porting them needs a decision
  about data first.
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

## 10. Questions

1. **Scope.**
   - Is stage A worth doing on its own? With the units-file workaround, it
     already lets assembly programs exceed 32 KiB.
   - Or should it wait for the segments of stage B?
2. **The convention.** Should the scratch register for rewritten calls be
   fixed (`t6`, as `cc` uses) or chosen per program?
3. **Data for C.** Should large C programs wait for a decision on far data,
   which this proposal does not make?
4. **NXMAP.** Is a larger map acceptable as a platform option, given that
   only programs like `cc` gain from it?
