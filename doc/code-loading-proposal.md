# Loading code on demand in StrataOS: survey and proposal

Status: a proposal. Nothing described under "Options", "Recommendation" or
"Plan" is implemented. The survey and the measurements describe the tree at
commit d8946b7 (2026-11-13), plus two branches where said so.

The question: should StrataOS offer loading of code on demand as one shared
service, so that not every large program carries its own, and where should it
live: a user-level server, the per-core dispatcher, a library, or a
combination?

## 1. Summary

- **The mechanism is already shared, and it is in the dispatcher.** Since the
  code-units work, a program sets `xslot`, keeps its code units in its arena
  and calls them with `xcall`; the miss traps to its core's dispatcher, which
  pages the unit in (`page_in`, `os/kernel.s:4354`) and puts the code cache
  back after every context switch. `units`, the Forth and the C compiler (and
  the programs it compiles with `-p`) all use that one pager. No program in
  `os/progs/` contains a pager of its own.
- **The window server, `wdoom` and `kira` do not page code at all.** Their code
  fits the 32 KiB of I-LS a program has (22.5, 17.4 and 23.7 KiB). `wdoom`
  loads *data* on demand (texture columns with `tget`), which is a different
  problem.
- **What is repeated is the layer above the mechanism**: how code is cut into
  units, how a unit is called, how a unit calls resident code, and how code
  gets into the arena in the first place. There are four unit layouts, three
  call sequences and three unit sizes, and neither the assembler nor the image
  format knows what a unit is.
- **What is missing is everything a loader does**: code is never loaded from
  the disk on demand (the whole image is read at spawn and its far section is
  then copied a second time), nothing is shared between processes (every
  process has a private copy of its program and of the 6 KiB system library),
  an image cannot exceed 128 KiB (the C compiler works around it by reading
  its own units from a library file), and a running program can add code only
  by writing it into its own arena.
- **A server cannot be on the path of a miss.** A page-in by the dispatcher
  costs 600 to 870 cycles (320 to 670 with the stream fetch); the cheapest
  message round trip to a server costs 33,000 (19,000). And a server cannot
  write another core's I-LS in any case: only code running on a core can.
- **Recommendation: the split (option d).** Keep the mechanism where it is,
  generalise it from "units in `c0`" to "units in any of a thread's code
  segments", and put the policy (which file, shared with whom, when to drop
  it) in `proc`, which already loads every program. Give the layer above one
  format, in the assembler. Section 6 has the reasons, section 7 the stages,
  section 8 the questions that need an answer first.

## 2. What exists

### 2.1 The mechanism every case uses

The hardware part is the overlay map (manual, section "Code overlays and code
paging", `doc/manual/ch-swmanaged.tex:76`): NXMAP entries per core (16 by
default), each mapping a far address to an I-LS address. With `xslot` = n an
entry covers a unit of 2^n bytes. `xcall` and `xret` look the far address up
and trap with `xmiss` when it is not mapped; the handler loads the unit with
`tgetx`, maps it with `xmap` and returns with `eret`, which runs the call
again. `tgetx` unmaps whatever it overwrites.

| | The system core's kernel units | A program's code units |
|---|---|---|
| Handler | `k_trap`, `os/kernel.s:4644` (core 0's own trap handler) | `page_in`, `os/kernel.s:4354`, reached from the dispatcher's trap entry (`:1140`, `wt_page` `:1163`) or through svc PAGE (`:1625`) |
| Who decides what to load | the handler: the unit holding the missed address | the same |
| Where the code comes from | the kernel image's `.far` section through `c12`: first in T3, after start-up a read+execute share of a copy in T2 (`doc/strataos.md` 2.1) | the program's arena through `c0`, wherever the bytes came from |
| Unit size | 2 KiB, fixed | 2^`xslot`, the program's choice |
| Cache | 16 slots from I-LS 0x8000 | the I-LS after the resident code or code mirror, at most NXMAP slots |
| Replacement | round robin, never the slot of the instruction that missed | the same |
| Per-thread state | none (core 0 runs no programs) | `PR_UNITS` (16 × u16, the unit in each slot), `PR_VICT`, `PR_LOADS`, `PR_CEND`, `PR_MIRROR` |
| On a context switch | does not apply | the map is cleared, every recorded unit is copied back into its slot and mapped again (`os/kernel.s:4172`-`4221`) |
| Resident bytes | 280 handler + 128 `xmap` table = 408 | 316 `page_in` + 68 `ucache` + 100 `unmap_all` + 128 `xmap` table + about 180 switch-in + 156 for svc 7, 13, 14 + 40 trap route: about 990 |
| Instructions per miss | 68 (counted in a trace: 63 misses from boot to `halt`) | 184 (measured, section 2.4) |

The two handlers are the same algorithm written twice. They differ in the
capability register, in the fixed unit size, and in that the program's keeps
a record for the switch. They cannot simply be merged: core 0's lives in its
own resident range (0x7700 and up), which the workers do not run.

Three supervisor calls belong to the mechanism (`doc/strataos.md` 2.3): 7
SET_MIRROR (the resident code is reloaded from a copy the program maintains,
and the cache starts after it), 13 UNITS (counters), 14 PAGE (a program with
a trap handler of its own hands a miss over).

### 2.2 The users, one by one

| | What it keeps for paging | Unit size, layout | Call of a unit | Call of resident code from a unit | How the units reach the arena |
|---|---|---|---|---|---|
| `units` (`os/progs/units.s`) | `csrw xslot` (`:60`), nothing else | 1 KiB, `.align 1024` by hand in `.far` (`:139`) | `la t5, u; xcall ra, c0, t5` (`:73`) | none | the kernel copies the image's `.far` section to its offsets at CREATE (`u_farcopy`, `os/kunits/ops.s:928`) |
| Forth, one thread (`lang/forth/`) | a miss forwarder of 14 instructions, because Forth has a trap handler of its own (`os/platform.s:346`); SET_MIRROR in the start-up stub (`os/boot.s:36`); the unit store's allocator and the rule that a definition fits one unit; a gateway unit for kernel words that may run paged code; a run of `xunmap` after it changes a unit (`forth.s:4404`) | 2 KiB, a 104 KiB store in its arena, filled by the compiler | `addi t5, tp, a - TPV; xcall ra, c0, t5` (`forth.s:1266`) | `jalr ra, gp, a - 0x10000` | the compiler writes them with `tput` |
| Forth with threads, on bare metal, as a guest | nothing paged: every word is resident, installed with `tput` + `tgetx` through the mirror | | | | |
| `cc` itself (branch `claude/cc-c99-b737d2`, `lang/cc/DESIGN.md` section 4) | `crt0` sets `xslot` to 12; start-up code that reads 107 KiB of units out of `/bin/cc.lib` and copies them to the bottom of the arena (`cc.s:421`), because the image would exceed 128 KiB | 4 KiB, packed by the build | `lui/ori t6, u; xcall ra, c0, t6` | `jalr ra, gp, f - 0x10000` | read from a file by the program |
| Programs compiled by `cc -p` | `crt0`; an indirect call tests whether a function pointer is a far offset or a resident address | 4 KiB, packed by the code generator; a function may not exceed a unit | as `cc` | as `cc` | the image's `.far` section, as `units` |
| `examples/overlay.s` (bare metal, also runs under StrataOS) | a complete handler in user mode, exact mapping (`xslot` = 0), two slots | routines, not units | `xcall` | | `.far` |
| `ws`, `wdoom`, `kira`, `vi`, `sh`, `net` | nothing: all code resident (22.5, 17.4, 23.7, 21.6, 21.8, 21.4 KiB of 32) | | | | |

`wdoom`'s plan says so directly ("No code paging was needed",
`os/progs/PLAN-wdoom.md:12`); what it fetches on demand is art, a column at a
time with `tget` from the arena. The window server's modules take about
14 KiB (`os/ws/README.md:105`).

### 2.3 What is duplicated, and where the copies differ

- **The pager**: twice (core 0, dispatcher), as above. About 400 and 990
  bytes. Programs: none, except the Forth's 14-instruction forwarder and the
  bare-metal example.
- **Cutting code into units**: four times. By hand with `.align` (`units`,
  `os/kunits/*.s` with `.org u + 2048` guards), by the Forth compiler, by
  `cc`'s code generator, by `cc`'s own build. The assembler has no directive
  for a unit, does not check that a branch stays inside one, and has no macros
  to hide the call sequence.
- **The call sequence**: three spellings of the same thing (the far offset in
  `t5` from `la`, in `t5` from `tp`, in `t6` from `lui/ori`).
- **Reaching resident code from a unit**: the Forth and `cc` arrived
  independently at the same trick, `jalr ra, gp, f - 0x10000` with `gp` =
  0x10000.
- **Unit sizes**: 1, 2, 2 and 4 KiB. The size trades cache slots against
  transfer length and is rightly a program's choice; the Forth's README
  explains its 2 KiB by measurement.
- **Getting code into the arena**: three ways (the kernel's copy of `.far` at
  CREATE, the Forth's `tput`, `cc` reading a file).
- **The system library**: `os/lib/sys.s` is about 6 KiB of code assembled
  into each of the 35 programs and servers that include it (`cat` is 6.4 KiB of code in all). This is
  the largest repetition in bytes, and it has nothing to do with paging.

### 2.4 What a page-in costs

Measured with a test program that reads the `cycle` CSR before and after a
call (six units, three entered at their first word and three at their last;
then three messages to each of three servers), on `strata-rtl` with 8 cores
and `-T virtual`. "Stream" is the same program on the RTL of branch
`claude/smart-memory-research-4e7a72` (`STREAM` = 1). The emulator's `cycle`
counts instructions.

| | RTL cycles | RTL cycles, stream fetch | Instructions |
|---|---|---|---|
| `call` + `ret`, resident | 9 | 7 | 3 |
| `xcall` + `xret`, the unit mapped (a hit) | 9 | 7 | 3 |
| a miss, 1 KiB unit | 602 | 320 | 185 |
| a miss, 2 KiB unit | 614 | 418 | 184 |
| a miss, 4 KiB unit | 870 | 674 | 184 |
| a message to an idle server on another core, answered at once (an unknown operation to `pipe` or `proc`) | 33,100 | 18,900 | 6,400 |
| the same, the server on the caller's core (two context switches) | 61,500 | 44,200 | 13,700 |
| `fs` STAT of a name that does not exist, from another core | 72,300 | 23,100 | 6,500 |
| the same, from `fs`'s core | 101,800 | 49,300 | 22,800 |

- A hit costs nothing over a plain call.
- A miss returns when the whole unit has arrived: entering at the first or at
  the last word costs the same. Without the stream fetch the dispatcher's 184
  instructions hide the transfer of a small unit; with it the transfer shows
  (about one cycle per 8 bytes from T3: 256 cycles more for each 2 KiB).
- The Forth pays about 240 instructions per miss (its README): its own
  handler and svc PAGE on top of the 184.
- A message costs 45 to 60 times a miss before the server has done anything.
  Each message was sent three times; the times agreed to within 3% and
  the table gives the lower ones.

Not measured: the cost of a spawn (MEMORY, LOADIMG, CREATE) and the share of a
context switch that is code. The switch reloads all of a program's resident
code and every unit in its cache, each time: 22 KiB for `sh`.

## 3. What the hardware and the kernel allow

**Who gets the miss.** An `xmiss` in user mode goes to the program's own
handler if it has installed one, otherwise to the supervisor of the same core
(manual, "Trap entry and routing", `doc/manual/ch-traps.tex:73`). It never
goes to another core. The trap is precise and the instruction is retried, so
whoever handles it may take as long as it likes, and the dispatcher could
block the thread and run another meanwhile, as it does for a thread waiting
for a reply (it does not today: `page_in` never waits).

**Who can fill an I-LS.** Only an instruction executed on that core: `tgetx`,
which needs a capability with execute permission and is not privileged. So
the running program can, and its dispatcher can. A server on another core
cannot, by any means. What a server can supply is the *source*: a capability
for far memory that holds the code.

**What capabilities that takes.** A writable capability is linear, but
`cshare` turns it into a copyable one with read and execute only
(`doc/manual/ch-caps.tex:155`). So one copy of a program's code in far memory
can be handed to any number of cores, and nobody, the loader included, can
write it afterwards. The kernel already does exactly this with its own units
(`c12`) and with each thread's share of its image. Two limits:
- A share of memory that is not revocable is permanent. Only the kernel can
  make memory revocable, and revocation works on 256 KiB granules. Code that
  must be unloadable therefore lives in memory the kernel handed out as
  revocable, and is dropped a granule at a time.
- A switched-out thread's memory capabilities occupy slots of its core's save
  table: 10 are reserved per thread and a typical thread uses 3. A code
  segment is one more slot each.

`xcall` computes the far address from a capability register's base, and the
map matches absolute far addresses. Shared code therefore has the same
address in every process, and units need no relocation as long as they are
position-independent, which Strata code is. What changes is the register:
today every unit is called through `c0`, the program's private memory, and
`page_in` refuses anything else (`os/kernel.s:4359`-`4373`).

**A message compared with a local page-in.** Section 2.4: 19,000 to 33,000
cycles against 320 to 870. A server per miss would make paged code some fifty
times slower at every miss, and `fs` behind it more. A server per *segment*
(one message when a program or a library is first needed) costs the same as
the OPEN a program does today.

**The context switch.** The switch-in reloads the resident code from the
image share and the cache from `c0`. With code segments the source of each
becomes a segment's capability; the transfers are the same. One thing gets
cheaper if code is shared: a unit is identified by its far address, so a unit
of a shared segment that the previous thread on the core left in the same
slot need not be transferred again. That is an opportunity, not a
measurement.

**The stream fetch.** `STREAM` changes the cost of instructions, not their
effect: a fetch from a range `tgetx` is filling still waits. It halves the
dispatcher's part of a miss and of a message alike (table above), so the
ratio between them stays, and the bus transfer becomes the larger part of a
miss. That favours small units and code kept in T2, and does not change the
choice between the options.

**Local Store protection.** Today a program can overwrite its dispatcher, so
a pager in the dispatcher is no better protected than one in the program. If
the proposal in `HANDOFF.md` (a user window per Local Store) is adopted, the
dispatcher's pager and its records become protected, and a pager in a
library does not. The two proposals do not conflict: the code cache lies in
the program's part of the I-LS either way.

**Room in the dispatcher.** The worker's resident code ends at 0x76E8, 24
bytes below core 0's range. Workers do not page kernel units. Any addition to
the mechanism needs room made first.

**Servers and cores.** A core hosts at most one server and the system needs
six cores as it is. A new server that is always present raises that to
seven, unless it is started on demand like `ws` and `net`. Only `proc` and
`dev` hold the kernel's endpoint.

## 4. What "hot" loading should mean

Three things are meant by it, and they are separable:

1. **Lazy**: code enters the I-LS at first use. *Exists*, from the arena.
   Does not exist from the disk: every byte of an image is read at spawn.
2. **Shared**: one copy of a program's or a library's code serves every
   process that uses it. *Does not exist.* The capability model supports it
   directly (`cshare`).
3. **Dynamic**: code that was not in the image at start is added to a
   running program (a library, a plug-in, the output of `cc` or of the
   Forth), or code is replaced while the program runs. *Half exists*: a
   program that writes units into its own arena gets them paged (the Forth
   does), and must clear the map itself when it changes one. There is no way
   to ask for code from a file, no format for what a loadable piece exports,
   and no way to share generated code.

## 5. The options

**(a) A library and one format.** A standard pager linked into programs
(served in user mode, as `examples/overlay.s` does), or, since the dispatcher
already serves misses, only the layer above it: one unit format, one call
sequence, assembler support.

**(b) The dispatcher as the service.** This is today's design. Extending it
means the dispatcher also learns where code comes from: a table in the image
that it reads, loading from the disk included.

**(c) A `load` server** that owns program images and serves pages by
message.

**(d) A split.** The dispatcher keeps the mechanism (miss, cache, switch) and
learns only that a thread may have several code segments, each a capability.
A server decides what a segment is: it loads files, keeps one shared copy,
hands out shares, answers requests for libraries and for code made at run
time.

| | (a) library + format | (b) dispatcher does all | (c) server serves pages | (d) mechanism in the dispatcher, policy in a server |
|---|---|---|---|---|
| What programs no longer contain | hand layout of units, the call spellings; with a user-mode pager they would gain about 1 KiB each | nothing more than today | nothing more than today | hand layout and spellings (with the format of (a)); `cc`'s reading of its own units; the private copy of the image |
| Program size | unchanged, or +1 KiB with a user-mode pager | unchanged | unchanged | images may exceed 128 KiB; 128 KiB of each arena freed once code is shared |
| Latency of a miss | 184 instructions as today; a user-mode pager could be shorter (no register save for a switch) but loses the cache across a switch unless the kernel still restores it | as today | at least 19,000 to 33,000 cycles, plus the dispatcher's part | as today; one message per segment, at first use |
| Lazy / shared / dynamic | yes (arena) / no / as today | yes / only if the kernel shares / only what the kernel implements | yes / yes / yes | yes / yes / yes |
| Security and isolation | a user-mode pager is the program's own affair; nothing shared | all policy in supervisor code on every core | the server needs no access to its clients' memory; the dispatcher still does the copying | the dispatcher checks only "is this address inside a segment this thread holds"; shares are read+execute, nobody can write them; the server is trusted for what it loads, as `proc` is today |
| Fit with a microkernel | good | poor: file names, formats and lifetime in the kernel, which today knows no file | good in form, but the mechanism cannot leave the core, so the server is an extra hop, not a replacement | good: the kernel interface grows by attach and detach |
| ISA changes | none | none | none | none |
| Assembler | a unit directive, a far-call pseudo-instruction, a check that branches stay in a unit | none | none | as (a), plus a mark for far code that may be shared |
| `cc` | may emit the directive instead of packing | none | none | drops the `cc.lib` units member and its loader; code generation unchanged |
| Forth | none (its compiler packs units itself) | none | none | none required; generated code could be offered as a segment later |
| Image format | none | a table of units or segments the kernel reads | a table the server reads | a flag: far code that is read-only (shareable) against far data |
| `proc` | none | less: the kernel takes loading over | spawn goes through `load` | keeps a table of loaded code; SPAWN hands a share instead of copying; one new operation for libraries |
| Kernel | none | the largest change, in the fullest part of the kernel | a new wait state (a thread blocked in a miss), a message from the dispatcher | a segment table per thread, attach and detach, `page_in` generalised; room must be made in the resident dispatcher |
| Work | small | large | medium, for a result fifty times slower per miss | medium, in stages that are each useful alone |

Notes on the rows:

- **(a) alone removes the visible repetition and adds no capability.** It is
  the first stage of any other option.
- **(b) taken further is the wrong direction.** The dispatcher would have to
  talk to `fs`, parse images and decide lifetimes: policy in the part of the
  system that has 24 bytes left and that every core runs.
- **(c) as stated cannot exist**: the server cannot write an I-LS, so the
  dispatcher handles every miss anyway. What remains of (c) once the
  dispatcher does the copying is (d) with a message per miss instead of per
  segment.
- **(d) keeps the measured fast path** and moves only decisions to user
  level. The server is asked once per program or library, not once per unit.

## 6. Recommendation

Option (d), built on (a), with the policy in `proc` at first.

1. **The mechanism stays in the dispatcher**, because it must: the miss
   arrives there, only that core can fill its I-LS, and the cache is part of
   a thread's state across a switch. It is also already written, tested
   (`units` in the lockstep session, `make test-forth`) and fast.
2. **Generalise it by one notion, the code segment**: a slot-aligned range of
   far memory holding units, named by a read+execute capability. A thread has
   a small table of them (four would do); segment 0 is its arena, which keeps
   every existing program working unchanged. `page_in` looks the missed
   address up in the table instead of testing `c0` alone. Two new supervisor
   calls: ATTACH (a capability that arrived in `c6` becomes a segment) and
   DETACH (its units leave the cache, the capability is dropped).
3. **Policy goes to `proc`, not to a new server, for now.** `proc` already
   performs every load (MEMORY, LOADIMG, CREATE), already holds the kernel's
   endpoint, and costs no additional core. It gains a table of loaded code: a
   program's or library's read-only code is read from `fs` once into memory
   of its own, shared, and every later SPAWN or request receives a share.
   If dynamic loading grows (plug-ins, a linker), the table moves into a
   `load` server started on demand, behind the same messages.
4. **One format for the layer above**, in the assembler: a directive that
   starts a unit of a given size and checks what must hold inside one, a
   pseudo-instruction for a call of far code, and a mark in the image for far
   code that is read-only. `units`, the kernel's units and hand-written
   programs that outgrow 32 KiB (`kira` is at 23.7, `ws` at 22.5) then use the
   same thing `cc` and the Forth generate.
5. **Do not make a server serve pages.** The measurements leave no room for
   it.

What this gives, against section 4: lazy loading as today; shared code
between processes; images larger than 128 KiB; libraries loaded at run time;
generated code handed from a compiler to another process as a segment.
Replacing code in a running program becomes: attach the new segment, switch
the program's entry points to it, detach the old one when no far link into it
remains. That last condition is the program's to guarantee; a link into a
detached segment is a miss the dispatcher cannot serve, which ends the
program with a fault as an unservable miss does today.

What it does not give, and should not be claimed: memory saved by sharing is
small while every process gets a 1 MiB arena regardless; the I-LS is still
private to a core, so shared code is still copied into each core's cache;
and loading single units from the *disk* on demand is left out (a segment is
read whole at first use), because a miss would then wait for `fs`.

## 7. Plan, in stages

Each stage leaves the system working and is useful without the next.

**Stage 0: decide.** The questions of section 8.

**Stage 1: one format (option a).** No kernel or server change.
- `sasm`: a unit directive (size, alignment, a branch out of the unit is an
  error, the unit's rest is padded), a far-call pseudo-instruction, and the
  same in the self-hosted `as`.
- A short library file with the conventions the Forth and `cc` share (`gp` =
  0x10000 for resident calls, `xret ra` as the return).
- `units.s` and `os/kunits/*.s` converted; the manual's code-paging section
  and `doc/strataos.md` 2.2 describe the format.
- Check: `make test` unchanged in output; `units` prints the same sums.

**Stage 2: code segments in the dispatcher.**
- Make room in the resident dispatcher first (it has 24 bytes).
- A segment table in the thread record, `page_in` and the switch-in by
  segment, ATTACH and DETACH, UNITS per segment.
- A test program that attaches a second segment cut from its own arena,
  calls into it, detaches it, and is preempted throughout.
- Check: the measurements of section 2.4 repeated; a miss must not cost more
  than 10% over today's.

**Stage 3: shared program code through `proc`.**
- The image marks read-only far code. `proc` keeps loaded code in a table;
  SPAWN of a program already loaded skips LOADIMG for its code and attaches a
  share; the kernel's second copy of the far section (`u_farcopy`) goes for
  such programs. The 128 KiB limit then applies to the resident part and the
  data only.
- `cc` drops its units member of `cc.lib` and the loader for it.
- Check: two shells and two `cc` runs at once, the isolation test, `ps`
  showing the shared code once; spawn time measured before and after.

**Stage 4: loading at run time.**
- A `proc` operation: a file name in, a share of its code and its export
  table out. A small user library: load, find a name, call, unload.
- The system library as the first shared library is the natural test, and
  the one with the largest effect (6 KiB in every program); it needs a
  decision of its own because every program's start-up changes.
- Offering generated code (`cc -p` output run without a spawn, Forth words
  given to another process) uses the same call with memory instead of a file
  name.

**Stage 5, only if wanted: a `load` server**, started on demand, taking the
table over from `proc`.

Not planned: paging the resident code itself (a small stub and everything
else in units). It would shorten switches for programs that use a small part
of their code, and lengthen them for the others; it needs the switch's code
share measured first.

## 8. Questions

1. **Scope.** Is stage 1 (one format, no new capability) worth doing on its
   own, or only as part of the whole?
2. **Sharing.** Is shared code between processes a goal in itself? It is the
   part with the most work (stages 2 and 3) and, with fixed 1 MiB arenas, the
   least visible gain; the gains that are certain are images over 128 KiB and
   a faster second spawn.
3. **Where the policy lives.** `proc` as recommended (no additional core), or
   a separate `load` server from the start (cleaner, one more core or
   started on demand, and a third holder of the kernel's endpoint)?
4. **The system library.** Should `sys.s` become a shared library, changing
   how every program starts, or stay assembled into each program?
5. **Replacing code in a running program.** Is the form described in section
   6 (new segment, switch entry points, detach when quiet) enough, or is
   replacing a unit in place, under a program that keeps running in it,
   wanted? The latter needs a rule for code that is executing in the unit.
6. **Order with the other open work.** The dispatcher change of stage 2
   touches the same resident code as the Local Store protection proposal and
   needs room there; the new file server changes LOADIMG's side of stage 3.
   Should this wait for either?
7. **Units from the disk.** Is loading a segment whole at first use
   acceptable, or should a large program's units come from the disk one at a
   time (a thread then waits in a miss for `fs`, some 100,000 cycles)?
