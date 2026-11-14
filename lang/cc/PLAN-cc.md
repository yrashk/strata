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
- [x] `ladder/EXPECT.tsv`: the 73 tests not expected to pass, with reasons
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
- [ ] anonymous struct and union members (C11, used by two tests)

### Stage 4: the preprocessor
- [x] `#include` (members of `cc.lib`, then the file system), include stack
- [x] object-like and function-like macros, variadic macros, `#undef`, `#`
      and `##`, `__LINE__`, `__FILE__`
- [x] `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`, `defined`
- [x] `#error`; `#line` and `#pragma` are skipped
- [x] backslash-newline (removed when a file is loaded, line numbers kept)
- [x] the library's headers: `assert ctype limits stdarg stdbool stddef
      stdint stdio stdlib string strata`
- [ ] `__STDC__`, `__STDC_VERSION__` and the other predefined macros
- [ ] trigraphs, `_Pragma`, `#include` with a macro as its operand

### Stage 5: the rest of C99
- [x] `long long` (the same as `long`), `_Bool`, `//` comments, mixed
      declarations and code, declarations in `for`
- [x] variadic functions (`<stdarg.h>`), more than eight arguments
- [x] designated initialisers (nested), compound literals
- [x] `__func__`
- [~] bit-fields: read, write, initialise; a field starts a new storage unit
      where the reference compilers share one with a preceding member, and an
      unsigned field narrower than `int` stays unsigned (9 tests fail)
- [x] floating point: `double` arithmetic, comparisons and conversions by
      software (`lib/fp.s`, checked against the host on 1800 cases), decimal
      constants, `printf` of `%f %e %g` exactly rounded
- [~] `float`: stored as 4 bytes, computed in double (results of float
      arithmetic have type double); no hexadecimal constants; `c ? 1 : 2.5`
      with an integer first branch is not converted; `x++` on a floating
      lvalue is rejected; `-0.0` is true in a condition
- [ ] variable-length arrays (the plan: DESIGN.md has none yet; frames have a
      fixed size, so a VLA would come from the heap, freed at block exit)
- [ ] old-style (K&R) function definitions
- [ ] wide strings (`L"..."` is read as a plain string)
- [ ] `qsort`, `bsearch`, `strtod`, `<math.h>` in the library

### Stage 6: the main compiler, in C
`cc.s` is the bootstrap compiler; `cc.c` is to be the main one and need not
emit the same bytes (DESIGN.md, section 6).
- [x] paged code model (`-p`): functions placed in 4 KiB units; the whole
      ladder passes with `CC_FLAGS=-p` exactly as without; a generated
      program of 150 functions and 100 KiB of code (three times the
      instruction store) runs and prints what the host prints
- [ ] the symbol table (1000 records, 5 per function with a prototype) is
      too small for a program of the compiler's own size: prototype
      parameters need a cheaper form, or the table a place in the arena
- [ ] `cc.c`, compiled by `cc.s`
- [ ] fixed point: `cc2 = cc1(cc.c)`, `cc3 = cc2(cc.c)`, identical bytes
- [ ] programs whose image exceeds 128 KiB: code units in a second file,
      loaded by `crt0` (as `cc` itself does with `cc.lib`)

### Stage 7: the machine from C
- [ ] intrinsics (`<strata.h>`), one instruction each; tags, capability
      registers and CSR numbers are constants: `__tget __tput __tgetx __twait
      __tpoll __tany`, `__tamo_add/_swap/_cas/_and/_or`, `__cbase __clen
      __cperms __cvalid`, `__cmov __csplit __cjoin __cshare __crestrict
      __cclear`, `__cgive __ctake __cpoll __csend`, `__csrr __csrw`, `__svc
      __halt`, `__ltag __linst`. Supervisor-only instructions are left to `asm`
- [ ] `asm("...")`: inline Strata assembly as `as` reads it, encoded with the
      instruction table of `as` (`os/progs/as.s`; `asm/sasm.c` for `cc.c`).
      In a function: lines encoded in place, `{name}` is a C variable as a
      memory operand, labels are local to the statement; t0..t6, tp, a0..a7
      are free, s registers, sp and gp are kept. At file scope: defines
      symbols in the code section, declared to C by a prototype

### Stage 7: the machine from C
- [x] intrinsics (`cc-intr.s`, documented in `<strata.h>`), one instruction
      each: `__tget __tput __tgetx __twait __tpoll __tany`,
      `__tamo_add/_swap/_cas/_and/_or`, `__cbase __clen __cperms __cvalid`,
      `__cmov __cjoin __cshare __csplit __crestrict __cclear`, `__cgive
      __ctake __cpoll __csend`, `__csrr __csrw`, `__svc __halt`, `__ltag
      __linst`. Tried in StrataOS: transfers to and from the arena, the
      clock through c7, capability queries, CSRs, `svc`
- [ ] `asm("...")`: inline Strata assembly as `as` reads it. Planned for
      `cc.c`, which can use the instruction table of `asm/sasm.c` as it is;
      the bootstrap compiler does not have it. In a function: lines encoded
      in place, `{name}` is a C variable as a memory operand, labels are
      local to the statement; t0..t6, tp, a0..a7 are free, s registers, sp
      and gp are kept. At file scope: defines symbols in the code section

## Integration
- [x] `cc`, `cc.lib` and `hi.c` on the OS disk (Makefile `CC_DISK`); the
      disks of the HTTP, isolation and Forth tests are built without them
      (`DISK_ARGS_NOCC`): those tests fill the 128-entry directory
- [x] `help` line in the shell
- [x] `make test-cc` (the ladder), `make test-cc-fast` (52 tests and
      `tools/test-cc.sh`: `hi.c` and `calc.c` compiled and run in the OS),
      the latter a prerequisite of `make test`
- [x] `examples/hi.c`, `examples/calc.c`
- [x] README section, `doc/strataos.md` paragraph
- [ ] the manual (`doc/manual/ch-toolchain.tex`, `ch-os.tex`) does not
      mention `cc` yet

## Scores

Tests passing per rung, in the resident code model, after each stage
(`lang/cc/tests/run.sh`). The paged model (`CC_FLAGS=-p`) gave the same
counts when it was last run (at 392).

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

## Size

`cc.s` and the files it includes: 12,400 lines of assembly, of which the
resident part is 3.8 KiB of code and the 27 code units 107 KiB; the D-LS
section is the full 40 KiB (16 KiB symbols, 7 KiB types, 13 KiB variables
and buffers). The library: 2,800 lines, 8 KiB of code and 3 KiB of data in
every program. `cc.lib` is 128 KiB, `cc` 45 KiB.

## Notes for whoever continues

- **Units.** Code in a unit calls code in another (or anything that may
  leave the unit) with `la t6, f` / `xcall ra, c0, t6`; resident code with
  `jalr ra, gp, f-R`. A plain `call` is only for leaves of the same unit.
  `check-units.py` (run by the Makefile) refuses an image in which a jump
  leaves its unit, which is also how a unit that outgrew 4 KiB shows up:
  split it with another `.align 4096`.
- **Labels are global** across all the included files: pick a new prefix.
- **Data.** Variables must stay below `CW` (the `.org CW` at the end of
  `cc.s` fails otherwise): 0x3560, and `data_end` is at 0x3540 now: 32 bytes are left. Shrink a table
  (`NSYMS`, `NTYPES`) or move one to the arena before adding variables. A unit's
  `.data` must start with `.align 8` (loads and stores of misaligned words
  fault). `NSYMS`, `NTYPES`, `NCASES`, `NARGS`, `XBSZ` are the knobs.
- **Loads and stores must be aligned** on this machine: the compiler never
  emits an 8-byte access to a 4-byte-aligned object (structure copies go by
  the type's alignment).
- **Debugging.** `strata-dbg --batch -x script ... ` with `break trap
  lsfault` finds a faulting compiler; the image of a compiled program can be
  pulled out of a session with `cat prog` between two `echo` markers and
  disassembled on the host.
- **The disk's directory** (128 entries) is nearly full: every file added to
  the standard disk needs the tests that create files to still fit.
- The time of a ladder run is about a minute; the full `make test` took an
  hour and passed through its main part with this change (examples, OS
  sessions on emulator and RTL, the OS tests, the JIT, the debuggers, the
  conformance suite, `test-cc-fast`).
