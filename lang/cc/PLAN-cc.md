# Plan: a C99 compiler for Strata (`lang/cc/`)

The design is in `DESIGN.md`; the tests in `tests/README.md`. This file is the
state of the work: what is done, what is next, and the ladder's score after
each stage. Keep it current.

## Ground rules

- The compiler (`cc.s` and the files it includes) is Strata assembly, written
  by hand. Host scripts only run tests and build tables (`lib/mklib.py` packs
  the library file, `tests/*.py` run the ladder and check the code units).
- Every assembly line carries a comment.
- `cc` emits STX2 images itself; `as` is not involved.
- A second source of the same compiler, `cc.c`, in C, must be compiled by the
  assembly compiler into a program that writes the same images, itself
  included (DESIGN.md, section 6).

## Test vectors

- [x] Suites examined, licences read from their sources (`tests/README.md`)
- [x] 521 tests adopted (scc 266, ISC; lacc 255, MIT), verified on the host
- [x] Sorted into nine rungs, `ladder/MANIFEST.tsv`
- [x] Runner: `tests/run.sh` (`ladder.py`): batches of tests per boot;
      `CC_FLAGS=-p` runs the ladder in the paged code model
- [x] `ladder/EXPECT.tsv`, `EXPECT-cc0.tsv`: the tests not expected to pass,
      with reasons; both are empty now
- [x] `ladder/FAST.txt`: the subset `make test` runs (52 tests)

## Design

- [x] `DESIGN.md`: data model, calling convention, code models, compiler
      structure, output, library, bootstrap

## Stages

### Stage 0: skeleton
- [x] `cc.s`: program header, D-LS and arena maps, resident run-time
      (messages, files, errors), unit call discipline
- [x] `lib/libc.s`, `lib/rt.s`, `lib/mklib.py`; `cc.lib` in the build
- [x] image writer: library copied in, start-up words patched, STX2 out
- [x] `tests/check-units.py`: no jump or branch leaves its 4 KiB unit
- [x] the compiler's own code units live in `cc.lib` (member `cc.units`) and
      are copied into the arena at start-up: with them in the image it
      exceeded the kernel's 128 KiB

### Stage 1: `int`, statements, functions
- [x] scanner: identifiers (interned in the arena), numbers, punctuators,
      comments, character constants, strings
- [x] value stack, evaluation registers, instruction encoders, jump chains
- [x] expressions: all binary and unary operators, assignment and compound
      assignment, `++`/`--`, `?:`, `&&`, `||`, comma; constants fold
- [x] statements: compound, `if`, `while`, `do`, `for`, `break`, `continue`,
      `return`, expression statements
- [x] functions: definitions, parameters, calls, recursion, prototypes,
      implicit declaration by a call
- [x] local and global variables

### Stage 2: types
- [x] `_Bool char short int long`, signed and unsigned, pointers, arrays,
      functions; declarators in full (nested, abstract)
- [x] pointer arithmetic, indexing, `&`, `*`, `sizeof`
- [x] integer promotions and the usual arithmetic conversions; casts;
      narrow values extended only where needed ("dirty" registers)
- [x] string literals; static data with constant initialisers and fixups

### Stage 3: aggregates and the rest of the statements
- [x] `struct`, `union`: members, `.`, `->`, assignment, by-value arguments
      and results; `enum`; `typedef`
- [x] initialisers: scalars, arrays, structures, strings, nested and elided
      braces, arrays of unknown length (a dry run counts)
- [x] function pointers
- [x] `switch`, `goto` and labels
- [x] `static` locals, `extern`, tentative definitions
- [x] anonymous struct and union members (C11, used by two tests)

### Stage 4: the preprocessor
- [x] `#include` (members of `cc.lib`, then the file system), include stack
- [x] object-like and function-like macros, variadic macros, `#undef`, `#`
      and `##`, `__LINE__`, `__FILE__`
- [x] `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`, `defined`
- [x] `#error`, `#line`; `#pragma` is skipped
- [x] backslash-newline (removed when a file is loaded, line numbers kept)
- [x] the library's headers: `assert ctype limits stdarg stdbool stddef
      stdint stdio stdlib string strata`, and `math` (for `cc`)
- [x] `__STDC__`, `__STDC_VERSION__`, `__strata__`
- [x] trigraphs, `_Pragma`, `#include` with a macro as its operand

### Stage 5: the rest of C99
- [x] `long long` (the same as `long`), `_Bool`, `//` comments, mixed
      declarations and code, declarations in `for`
- [x] variadic functions (`<stdarg.h>`), more than eight arguments
- [x] designated initialisers (nested), compound literals
- [x] `__func__`
- [x] bit-fields: read, write, initialise; laid out and promoted as the
      usual ABIs do
- [x] floating point: `double` arithmetic, comparisons and conversions by
      software (`lib/fp.s`, checked against the host on 1800 cases), decimal
      constants, `printf` of `%f %e %g` exactly rounded
- [x] `float`: stored as 4 bytes, its arithmetic rounded to float;
      hexadecimal constants
- [x] variable-length arrays (`cc-vla.s`): storage from the heap, given back
      at the end of the block and by `return`, `break`, `continue` and `goto`
- [x] old-style (K&R) function definitions
- [x] wide characters (`L'x'`); wide strings only in `cc.c`
- [x] `strtod`, `strtof`, `strtold`, `atof` in the library
- [ ] `qsort`, `bsearch`, `<math.h>`: these are C source in the library, which
      only `cc.c` can compile into a program (stage 6)

### Stage 6: the main compiler, in C
`cc.s` is the bootstrap compiler (`cc0`); `cc.c` is the compiler (`cc`, and
`build/strata-cc` on the host) and need not emit the same bytes (DESIGN.md,
section 6).
- [x] paged code model (`-p`): functions placed in 4 KiB units; the whole
      ladder passes with `CC_FLAGS=-p` exactly as without; a generated
      program of 150 functions and 100 KiB of code (three times the
      instruction store) runs and prints what the host prints
- [x] programs whose image exceeds 128 KiB: the code units go to a second
      file, `OUT.u`, loaded by `crt0` (`__uload`); both compilers write it
- [x] `cc.c`: the whole compiler in C (4,600 lines), compiled by `cc.s`
      without changes to its tables (it stays under 1000 symbols and 448
      types by defining functions before their use)
- [x] fixed point, inside StrataOS: `cc1 = cc0(cc.c)`, `c2 = cc1(cc.c)`,
      `c3 = c2(cc.c)`; `c2` and `c3` are identical, and identical to the
      `cc` built on the host (`make test-cc-boot`, part of `make test`)
- [x] `cc.c` on the host: `lang/cc/host/`, `build/strata-cc`; the Makefile
      builds the `cc` of the disk with it
- [x] `cc.c` passes the ladder: all 521
- [x] the bootstrap compiler follows: all 521 too. Ported to `cc.s`:
      trigraphs, `#line`, `_Pragma`, `#include` of a macro, macros named
      like keywords, the never-expand-again mark, stringified blanks and
      escapes, comments in macro arguments, `\u` and `L'x'`, hexadecimal
      floating constants, bit-field layout and promotion, old-style
      definitions, unnamed members, designators that continue and the
      other initialiser forms, parenthesised declarators, `va_start` and
      `va_arg` as builtins, float arithmetic rounded to float, an enum in
      a parameter list, `extern` in a block. Its code window is 1 KiB now
      (it was 2): that freed the data these needed
- [x] variable-length arrays in `cc.s` (`cc-vla.s`): the same design as in
      `cc.c`
- [x] found on the way, in `cc.s`: an lvalue through a pointer that a call
      left in a0 was read after a0 had been loaded with the first argument
- [x] found on the way, fixed in `cc.s`: a register stored to the frame
      inside one arm of `?:`, `&&`, `||` was read back on the other path
- [x] in `cc.c` beyond the bootstrap compiler: variable-length arrays and
      variably modified types, old-style definitions, unnamed members,
      structure arguments through `va_arg` (`va_start` and `va_arg` are
      builtins), wide characters and strings, universal character names,
      hexadecimal floating constants, trigraphs, `#line`, `_Pragma`,
      `#include` of a macro, the rule that a name found busy in an
      expansion is never expanded later, designators that continue in the
      designated object, bit-fields laid out and promoted as the usual ABIs
      do
- [x] the last seven tests: the suites' headers are kept in
      `tests/ladder/include`; comments inside macro arguments; `strtod`,
      `strtof`, `strtold` and `atof` in the library; a floating value below
      zero converted to a narrow unsigned type gives 0
- [x] the identifier hash and the scanner's saved state moved to the arena:
      38 KiB of the 40 KiB of D-LS are in use
- [x] a variable-length array left by `goto` is given back, in both
      compilers (DESIGN.md, section 6): back to a label, by the goto itself;
      forward, by code at the end of each scope the jump leaves.
      `examples/vla.c` leaves every way, often enough to exhaust the heap if
      one of them kept the storage; `tools/test-cc.sh` runs it with `cc` in
      both code models and with `cc0`
- [x] library functions as C source (`lib/src`, one function a file, members
      `NAME.c` of `cc.lib`): at the end of a program `cc.c` compiles the ones
      the program calls and nothing else defines. `qsort` and `bsearch`;
      `<math.h>`: 29 functions, compared with the host's library on 200,000
      random arguments each (the host compiles the same files) and, run in
      StrataOS, bit for bit with the same files run on the host
      (`examples/sort.c`, `examples/math.c`)
- [x] found on the way: the library's quiet NaN had lost its top bit (0/0
      was 1.75 at run time; the compiler's own folding was right)
- [ ] decimal floating constants of more than 15 digits, or far from 1, can
      be off by a unit or two in the last place (the digits are multiplied
      out in double); hexadecimal constants are exact, and the library's
      sources use them. The same holds for `strtod`
- [ ] `<math.h>` is `double` only: no `sinf`, `sinl` and the like

### Stage 7: the machine from C
- [x] intrinsics (`cc-intr.s`; in `cc.c` the same table; documented in
      `<strata.h>`), one instruction each: `__tget __tput __tgetx __twait
      __tpoll __tany`, `__tamo_add/_swap/_cas/_and/_or`, `__cbase __clen
      __cperms __cvalid`, `__cmov __cjoin __cshare __csplit __crestrict
      __cclear`, `__cgive __ctake __cpoll __csend`, `__csrr __csrw`, `__svc
      __halt`, `__ltag __linst`. Tried in StrataOS: transfers to and from
      the arena, the clock through c7, capability queries, CSRs, `svc`
- [x] `asm("...")` in `cc.c` (DESIGN.md): every instruction of the
      assembler, `{name}` for C objects, constants and functions, labels of
      the function; at file scope the labels are functions. The table comes
      from `sasm` (`lib/mkasm.py`, `asm.tab` in `cc.lib`).
      `examples/asm.c`, run by `tools/test-cc.sh` in both code models

## Integration
- [x] on the OS disk (Makefile `CC_DISK`, `CC_SRCS`): `cc`, `cc.u`,
      `cc.lib`, the bootstrap compiler `cc0` with `cc0.lib`, and under
      `/src` the compiler's source `cc.c` and the examples, so that the
      bootstrap can be done by hand on the machine. (While the directory
      had 128 entries the library rode behind `cc.u` and `cc0` had a disk
      of its own; the store has no such limit)
- [x] `help` line in the shell
- [x] `make test-cc` (the ladder), `make test-cc-fast` (52 tests and
      `tools/test-cc.sh`: the examples compiled and run in the OS); in
      `make test` as `cc-ladder`, `cc` and `cc-boot` (`tools/tests.sh`)
- [x] `examples/`: `hi.c`, `calc.c`, `asm.c`, `sort.c`, `math.c`, `vla.c`,
      `cmp.c`
- [x] README section, `doc/strataos.md` paragraph, a page of the site
      (`site/c/`)
- [x] the manual: a section of the toolchain chapter, a paragraph of the
      operating system's

## Scores

Tests passing per rung, in the resident code model
(`lang/cc/tests/run.sh`). First the bootstrap compiler after each of its
stages (`make test-cc0`; the paged model, `CC_FLAGS=-p`, gives the same
counts), then `cc.c` (`make test-cc`; `make test-cc-host` compiles on the
host and gives the same).

| After | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 | 09 | Total |
|---|---|---|---|---|---|---|---|---|---|---|
| tests | 32 | 12 | 93 | 33 | 58 | 75 | 18 | 139 | 61 | 521 |
| stage 1 and 2 (`int`, pointers, types) | 30 | 12 | 79 | 2 | 10 | 3 | 5 | 35 | 1 | 177 |
| the preprocessor, struct/union/enum | 32 | 12 | 83 | 28 | 47 | 4 | 8 | 51 | 3 | 268 |
| initialisers | 32 | 12 | 83 | 28 | 48 | 62 | 9 | 70 | 4 | 348 |
| switch, goto, struct values, variadic | 32 | 12 | 85 | 29 | 48 | 68 | 17 | 88 | 4 | 383 |
| bit-fields, compound literals | 32 | 12 | 88 | 29 | 52 | 68 | 17 | 97 | 4 | 399 |
| floating point | 32 | 12 | 88 | 29 | 52 | 67 | 17 | 97 | 46 | 440 |
| typedef fix, nested designators | 32 | 12 | 88 | 31 | 53 | 70 | 17 | 97 | 48 | 448 |
| a code-window fix (both code models) | 32 | 12 | 88 | 31 | 53 | 71 | 17 | 97 | 49 | 450 |
| a spill before conditional branches | 32 | 12 | 88 | 31 | 53 | 71 | 17 | 97 | 49 | 450 |
| **`cc.c`**, first run | 32 | 12 | 90 | 31 | 52 | 73 | 16 | 105 | 51 | 462 |
| **`cc.c`**: labels, bit-field layout | 32 | 12 | 90 | 31 | 53 | 73 | 18 | 110 | 52 | 471 |
| **`cc.c`**: the rest of the preprocessor, K&R, wide and hex constants | 32 | 12 | 92 | 31 | 56 | 74 | 18 | 121 | 54 | 490 |
| **`cc.c`**: designators, `va_arg`, bit-field promotion | 32 | 12 | 92 | 33 | 56 | 74 | 18 | 131 | 57 | 505 |
| **`cc.c`**: variable-length arrays | 32 | 12 | 92 | 33 | 56 | 74 | 18 | 138 | 59 | 514 |
| **`cc.c`**: `#include` of a macro, `strtod` | 32 | 12 | 93 | 33 | 58 | 75 | 18 | 139 | 61 | 521 |
| the bootstrap compiler now (headers kept, `strtod`) | 32 | 12 | 89 | 31 | 53 | 71 | 17 | 97 | 50 | 452 |
| the bootstrap compiler, all but variable-length arrays | 32 | 12 | 93 | 33 | 58 | 75 | 18 | 132 | 59 | 512 |
| the bootstrap compiler with variable-length arrays | 32 | 12 | 93 | 33 | 58 | 75 | 18 | 139 | 61 | 521 |

## Size

`cc.c`: 5,500 lines of C. Compiled by itself: 106 KiB of code in 4 KiB
units (`cc.u`), and an image `cc` of 47 KiB: the 9 KiB library and 38 KiB of
data (1.7 KiB of the 40 are left). The host program `strata-cc` is the same
source and 115 lines of `host/host.c`.

`cc.s` and the files it includes: 13,900 lines of assembly, of which the
resident part is 4 KiB of code and the 30 code units 119 KiB; the D-LS
section is the full 40 KiB (16 KiB symbols, 7 KiB types, 13 KiB variables
and buffers). The library: 3,000 lines of assembly, 9 KiB of code and 3 KiB
of data in every program, and 480 lines of C that a program gets only the
functions it calls of. `cc.lib` is 45 KiB (the library, the headers, the
table of `asm`: 28 KiB, which `cc` keeps in its arena; then the C sources);
`cc0.lib`, with the bootstrap compiler's units, 143 KiB, `cc0` 44 KiB.

## Notes for whoever continues

- **`cc.c` first.** Work on the compiler is work on `cc.c`: build
  `build/strata-cc`, try it on the host (`make test-cc-host` runs the ladder
  with it; compiling there with `-fsanitize=address,undefined` finds most
  mistakes at once), then `make test-cc-boot`. What `cc.c` uses of C must
  stay within what `cc.s` compiles, and within its tables: functions are
  defined before they are used (a prototype costs the bootstrap compiler a
  symbol per parameter), every function compiles to less than 4 KiB, and
  the data must fit 40 KiB.
- The rest of these notes is about `cc.s`.
- **Units.** Code in a unit calls code in another (or anything that may
  leave the unit) with `la t6, f` / `xcall ra, c0, t6`; resident code with
  `jalr ra, gp, f-R`. A plain `call` is only for leaves of the same unit.
  `check-units.py` (run by the Makefile) refuses an image in which a jump
  leaves its unit, which is also how a unit that outgrew 4 KiB shows up:
  split it with another `.align 4096`.
- **Labels are global** across all the included files: pick a new prefix.
- **Data.** Variables must stay below `CW` (the `.org CW` at the end of
  `cc.s` fails otherwise): 0x3960, and `data_end` is at 0x3728 now: 568
  bytes are left. Shrink a table (`NSYMS`, `NTYPES`) or move one to the
  arena when they run out. A unit's
  `.data` must start with `.align 8` (loads and stores of misaligned words
  fault). `NSYMS`, `NTYPES`, `NCASES`, `NARGS`, `XBSZ` are the knobs.
- **Loads and stores must be aligned** on this machine: the compiler never
  emits an 8-byte access to a 4-byte-aligned object (structure copies go by
  the type's alignment).
- **Debugging.** `strata-dbg --batch -x script ... ` with `break trap
  lsfault` finds a faulting compiler; the image of a compiled program can be
  pulled out of a session with `cat prog` between two `echo` markers and
  disassembled on the host.
- **Files added to the disk** change what `tools/test-http.sh` prints
  (listings, counts): `tools/test-http.sh -u` after looking at the diff.
- **Tests.** `make test-one T=cc`, `T=cc-boot`, `T=cc-ladder` take seconds;
  a whole ladder (`make test-cc`, `test-cc0`, `test-cc-host`) about a
  minute; `make test` runs everything in parallel (doc/testing.md).
- **The library in C** (`lib/src/README.md`): a file there may use only what
  `cc.c` compiles, names of its own that begin with two underscores, and no
  header.
