# Stratalk: a proposal

A Smalltalk for Strata whose object memory is built on the machine's own
rule: the core works on its Local Stores, and far memory is I/O.

## Language

- **Files are the source of truth, the image is a cache.** Classes live
  in `.st` files in the tag file system, edited with `vi`, read by
  `stratalk`. A snapshot (`Smalltalk snapshot: 'x.image'`) is the far
  heap written out as it is, so it starts with one read; it is never
  the only copy of anything. The syntax is bang-free and readable in an
  editor:

  ```
  Object subclass: #Point slots: 'x y'.
  Point class >> x: ax y: ay [ ^self new setX: ax y: ay ]
  Point >> + p [ ^Point x: x + p x y: y + p y ]
  ```
- **Blocks are full closures with non-local return.** `^` in a block
  returns from its home method; if the home has returned,
  `BlockCannotReturn` is signalled.
- **Classes, single inheritance, metaclasses**, as in Smalltalk-80.
  Traits (stateless, flattened when a class is loaded) come later, once
  the library is big enough to want them.
- **Basics.** 63-bit SmallIntegers (tagged), LargeIntegers later.
  Strings are bytes (UTF-8 in, UTF-8 out), Symbols are interned,
  literals are immutable. `{a. b}` dynamic arrays, `#[1 2]` byte arrays,
  `Array`, `OrderedCollection`, `Dictionary`, `Set`, `Interval`,
  `ReadStream`/`WriteStream`.
- **Exceptions** as in Pharo and ANSI: `on:do:`, `ensure:`,
  `ifCurtailed:`, `signal`, `resume:`, `retry`, `return:`, `pass`. The
  handler runs on top of the signalling stack, so resumption is free.
  An unhandled error prints the stack and returns to the REPL.
- **Borrowed:** Pharo's syntax, class library and exceptions; Newspeak's
  rule of no ambient authority: a program's `main:` receives a
  `Platform` object holding its files, console and network, the way a
  StrataOS process holds capabilities, rather than reaching them
  through globals; Self's inline caches. **Left out:** Morphic, the
  image as the only home of code, Self's prototypes, Newspeak's
  module system, `become:` (a scan of far memory; later, if at all).

## VM: in Strata assembly

A bytecode interpreter in assembly, built as Forth is: a resident core
(dispatch, send and the lookup cache, the object cache, allocation,
the scavenger, the common primitives; about 14 KiB of the 32 KiB I-LS)
and 2 KiB code units for what is cold (the old-space collector,
snapshots, file primitives, printing), paged by the dispatcher.

Not C: `cc` keeps every variable in memory and has no register
allocation, and its paged model makes every call an `xcall`. An
interpreter wants its instruction pointer, stack pointer, receiver and
cache base in registers and its loop resident. C would cost several
times the instructions per bytecode, in an I-LS where the loop must fit.

The compiler (source to bytecodes) is written in Stratalk and lives in
the image. A host tool, `tools/stratalk.py`, compiles the kernel
sources (the compiler among them) into the first image, as `cc0`
bootstraps `cc.c`; a test checks that the image's compiler, recompiling
the kernel, gives the same methods.

## Object memory: near and far

An object reference is 64 bits. Tags: SmallInteger, Character, a
**near** object (a D-LS address) or a **far** object (an offset in the
far heap). Where an object lives is visible in its reference.

- **New objects are near.** Allocation bumps a pointer in a D-LS
  nursery (about 12 KiB). Most objects die there and never cost a
  transfer. A scavenge copies the survivors out with `tput`:
  *promotion is the write-out*. A store of a near reference into a far
  object goes into a remembered set (the write barrier).
- **Far objects are read through a software cache** on the hardware's
  `ltag`/`linst` (64-byte lines, about 10 KiB). The allocator never
  lets an object of eight words or fewer straddle a line, so touching a
  small object is one lookup and at most one `tget`. Dirty lines are
  written back on eviction and at every scavenge.
- **Contexts live on the D-LS stack.** A frame goes to far memory only
  when a block that refers to it outlives it, or when the stack spills.
- **Methods.** A CompiledMethod is a far object. Its bytecodes and
  literals are copied into a D-LS method cache the interpreter runs
  from. A send looks in a global (class, selector) cache in the D-LS,
  then in an inline cache at the send site; a miss walks the method
  dictionaries in far memory, and costs transfers, which are counted.
- **The far heap** is the program's arena (`c0`) and one extra arena
  from `proc`'s MORE in `c6`, whose size the command line picks. T2
  stays the kernel's until the OS offers programs a share of it.
- **Old space** is collected by mark and sweep, by streaming through
  far memory a window at a time with transfers queued ahead (later:
  compaction).
- **Visible from Smalltalk:** `Smalltalk vm stats` (hits, misses,
  bytes moved, promotions, scavenges), `anObject isNear`,
  `Smalltalk vm flush`, and large collections' `do:` fetching the next
  window while the current one is processed.

D-LS budget (40 KiB data and 8 KiB stack): VM state and buffers 4,
lookup cache 4, method cache 6, far cache 10, nursery 12, remembered
set and spare 4. The stack holds the frames.

## Programs and the first milestone

`/bin/stratalk` is the VM; the image and sources are tagged `stratalk`.
`stratalk` gives a REPL, `stratalk FILE.st` files a program in and sends
it `main:`, `stratalk -e EXPR` prints a result, and it reads a pipe
like other programs.

Milestones, each with a test in `tools/tests.sh` and docs:

1. **REPL.** VM, host compiler, image boot, SmallIntegers, strings,
   `printString`, sends, the far cache and its statistics, and the
   image's compiler for expressions. No collector. `3 + 4` prints `7`.
2. **Classes and blocks** from files: closures, non-local return,
   exceptions, the nursery scavenger.
3. **Collections and the library**: symbols, dictionaries, streams,
   the old-space collector, snapshots, the image's compiler whole
   (and the test that it reproduces the host's).
4. **Files and programs**: `Platform`, file streams, `stratalk FILE.st`,
   pipes.
5. **A `ws` workspace window**, then a class browser.
