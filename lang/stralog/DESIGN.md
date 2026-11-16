# Stralog: a Prolog for Strata (design)

Stralog is a Prolog written in Strata assembly that runs as a StrataOS program
(`stralog`). Every term it touches lives in far memory: the D-LS holds only
windows onto the tops of its stacks and a small far cache, and each transfer
between the two is an explicit `tget` or `tput` in the engine.

## Language

ISO core Prolog in one flat namespace (no modules).

- **Control:** `,` `;` `->` `*->` `\+` `call/1..8`, and cut (opaque in
  `call/N`).
- **Database:** `assert/a/z`, `retract`, `abolish`, `dynamic`, with the
  logical update view.
- **All solutions:** `findall/3,4`; `bagof`/`setof` with `^`, written in
  Prolog over `findall` and `keysort`.
- **DCGs:** `-->` and `phrase/2,3`, translated in Prolog.
- **Exceptions:** `catch`/`throw`, with ISO error terms.
- **Terms:**
  - integers of 61 bits, tagged in a 64-bit cell. Overflow raises
    `evaluation_error(int_overflow)`, which ISO allows. No bignums.
  - atoms, with full quoting and escapes.
  - `double_quotes` is `codes`. There is no separate string type.
- **Floats:** none for now. `/` on integers divides and truncates, which
  differs from ISO.
- **Reader and writer:** `op/3` with the standard operator table,
  `read_term` with `variable_names`, `write`, `writeq`, `print`,
  `write_canonical`.
- **Never, unless asked:** tabling, clp(fd), attributed variables.

## Engine

**Written in Strata assembly**, as `cc.s` and `forth.s` are, with every line
commented. The code is larger than the 32 KiB instruction store, so it is
split the way the C compiler is:

- **Resident code** (I-LS from 0x8000) holds:
  - `os/lib/sys.s`, the system interface;
  - the solve loop;
  - the hot path: reading and writing cells, the windows and the far cache,
    deref, bind and trail, and unification.
- **4 KiB code units** in the `.far` section (`xslot` = 12) hold the reader,
  the writer, arithmetic, the builtins and the database. StrataOS pages them
  in on `xmiss`.
- The calling rules are cc's:
  - a unit calls a unit with `xcall` and returns with `xret`;
  - a unit calls resident leaves with `jalr ra, gp, f-R`, where gp = R =
    0x10000;
  - resident code called from a unit never calls a unit.
- If the image grows past the kernel's 128 KiB, the units and the Prolog
  library go into a second file, `/bin/stralog.u`. The resident start-up
  code reads it into the arena, as cc does with `cc.u`.

**A structure-copying interpreter, not a WAM:**

- **Clauses** are compiled once, when they are consulted or asserted, into
  templates in the clause store. A template is cells in which variables are
  `TVAR i`.
- **A call** allocates a frame of fresh variables on the heap and unifies the
  goal against the head template. Only the parts it binds to goal variables
  are built.
- **The body** is built from its template and pushed as a continuation term,
  `'$cont'(Goal, CutBarrier, Next)`, on the heap.
- **First-argument indexing** keys each clause by atom, integer or functor,
  so most deterministic calls leave no choicepoint.
- **Control constructs** are terms that the solve loop recognises. A cut
  goes back to the choicepoint recorded in its continuation.
  - If-then-else pushes a choicepoint for the else branch and then
    `'$cut'(B0)`.
  - `catch/3` is a choicepoint of its own kind.
  - `findall/3` is also a choicepoint kind. Its answers are compiled into a
    findall area as templates.
- **Builtins** are routines in units, reached through a jump table. The
  nondeterministic ones (`between`, `clause`, `retract`, `sub_atom`,
  `current_op`) are written in Prolog over deterministic primitives.
- **Written in Prolog** (`boot.pl`, embedded in the image and consulted at
  start-up): the top level, consult, lists, the DCG translation, bagof and
  setof, sorting, and `format`.

### Cells

A cell is 64 bits with a 3-bit tag. **Every reference is an arena offset,
never a D-LS address**, so where a term happens to be resident never changes
its identity.

| tag | cell | what it holds |
|---|---|---|
| 0 | REF | a variable: the offset of the cell it names (an unbound variable refers to itself) |
| 1 | STR | the offset of a functor cell, plus 1 |
| 3 | ATM | the offset of the atom's record, plus 3 |
| 4 | INT | the value shifted left by 3, plus 4 |
| 5 | FUN | atom offset << 16, arity << 3, plus 5 |
| 6 | TVAR | variable i of a template |

## Memory

The program's arena (c0, 832 KiB):

| arena offsets | contents | reached through |
|---|---|---|
| 0x00000 | the image's `.far`: code units, `boot.pl` | `xcall`; the reader reads `boot.pl` |
| 0x20000 | atom records (name, operators, predicate chain), 80 KiB | far cache |
| 0x34000 | the atom hash: 1024 heads | far cache |
| 0x36000 | predicates and clause templates | far cache |
| 0x60000 | the findall and ball area | far cache |
| 0x80000 | the heap (256 KiB) | its window, else the far cache |
| 0xC0000 | the trail (32 KiB) | its window, else the far cache |
| 0xC8000 | the choicepoint stack (32 KiB, 512 frames) | its window, else the far cache |

`sys.s` takes about 18 KiB of the 40 KiB D-LS. Of the rest:

| D-LS area | size |
|---|---|
| heap window | 8 KiB |
| choicepoint window | 2 KiB |
| trail window | 1 KiB |
| far cache: 64-byte lines, 32 sets × 2 ways, `ltag`/`linst` tag table, write-back | 4 KiB |
| stream buffers, reader and writer buffers, globals | the rest |

**A window** is a ring in the D-LS that covers `[WB, WB + size)` of one stack:

- **Reads and writes:** one subtract and compare decide whether an offset
  is in the window. If it is, the cell is at `ring + (offset & (size − 1))`;
  if not, it goes through the far cache.
- **WB stays a multiple of 64 bytes**, so no cache line ever straddles a
  window's base.
- **Spill:** a push past the end writes the lower half out with an
  asynchronous `tput` on the stack's own tag (two if the half wraps the ring)
  and moves WB up by half. Nothing waits. A store that would overwrite bytes
  still being written out waits, by the machine's ordering rule.
- **Popping is free.** After backtracking or a cut, everything above the new
  top is dead, so nothing is read back. Old cells that are still live (the
  top choicepoint frame, a trail entry, an old variable being bound) are
  read and written through the far cache.
- **Slide down:** the next push below WB moves the window down to the top's
  line. The far cache lines between the new and the old base are written
  back if dirty and dropped. Then one 64-byte `tget` brings back the
  partially live line. A core's transfers act in issue order, so the
  write-backs reach far memory before that read.
- **Bindings into old cells** are always trailed and go through the
  write-back far cache. **Untrailing** resets them the same way.
- **Counters:** `statistics/0` reports spills, slides, cache hits, misses
  and write-backs, and bytes moved, for each stack.

**Garbage collection:**

- **Before any collection:** backtracking, and the top level's failure-driven loop, give back the heap of every query.
- **When it runs:** a sliding mark-and-compact collector (`gc.s`) runs between two goals once the heap passes a limit. The first limit is three quarters of the heap; after each collection it is set at half of what is free (at least 64 KiB).
- **Roots:** the continuation, every choicepoint's goal and continuation, and the trail.
- **Trail tidying:** before marking, an entry whose cell is newer than the heap top of its own choicepoint is dropped. Such entries are left behind by cuts, for instance by tail recursion through if-then-else, and they would keep the cells alive.
- **The collector's tables:** the mark bitmap (a bit per cell), a prefix table (the live cells before each 64) and the mark stack go in the free heap above the top. A live cell's new place is the heap's start plus eight times the live cells below it, and so is a choicepoint's saved heap top.
- **Order is kept:** the live cells slide down in order, so each choicepoint still owns the heap above its saved top.
- **Moving the cells:** everything is read and written through the heap window and the far cache, so the collector streams the heap through the D-LS like any other code. Afterwards the far cache drops what it held above the window's base: the bitmap and the table, which are dead.
- **What cannot be collected:** a program whose live data outgrows the heap raises `resource_error(memory)`, and `-m N` gives it more room. Atoms are never collected, nor is the clause store.

**Recursion limit:** unification, copying and writing recurse on the machine
stack (8 KiB) and iterate on the last argument. Lists and right-nested
operators can be any length, but a term nested more than about 200 deep
outside its last argument raises `resource_error`.

**Multicore (later, optional):** `par_findall/3` under `stralog -n N`.
Workers get a read-only share of the clause store and a `csplit` piece of
the arena for their stacks. They take the alternatives of the top
choicepoint, and their answers come back by `cgive`.

## On StrataOS

`stralog` in `/bin`:

- `stralog` opens a REPL at `?- `.
- `stralog a.pl b.pl` consults the files first.
- `stralog -g Goal file.pl` runs the goal and halts.

Files are fs paths (`consult('/src/queens.pl')`, `[queens]`). The top level
prints `X = f(3), Y = 3.` and, while more answers may exist, reads a line:
`;` asks for the next answer.

**Tests:**

- `tools/test-stralog.sh`, one line in `tools/tests.sh`: a scripted session
  under StrataOS, compared with `tools/test-stralog.out`. It grows with each
  milestone.
- The ISO conformance vectors come from Logtalk's tests (Apache-2.0).
  Inria's suite is used only if its licence allows.

## Milestones

Each milestone is tested, merged, and `main` is pushed.

1. **Terms and the top level:** reader, writer, unify, the windows and the
   far cache. `?- X = f(Y), Y = 3.` answers `X = f(3), Y = 3.`
2. **Resolution:** clauses, backtracking with trail and choicepoints, cut,
   `->`, `\+`, `call/N`, and indexing. `append` and `member` work.
3. **Builtins:** arithmetic, assert and retract, findall, bagof and setof,
   sorting, catch and throw, and the term and atom builtins.
4. **Files:** consult, `op/3`, DCGs, `statistics` with the transfer
   counters, and conformance vectors.
5. **Demos:** N-queens, the zebra puzzle, a small expert system, and heap
   GC. (All five are done: README.md has the state, the examples and the
   conformance figures.)
