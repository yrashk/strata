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
- [x] Runner: `tests/run.sh` (`ladder.py`): batches of tests per boot
- [ ] `ladder/EXPECT.tsv`: tests not expected to pass, with reasons
- [ ] `ladder/FAST.txt`: the subset `make test` runs

## Design

- [x] `DESIGN.md`: data model, calling convention, code models, compiler
      structure, output, library, the second source

## Stages

Each stage ends with the ladder run and its score recorded below.

### Stage 0: skeleton
- [ ] `cc.s`: program header, D-LS and arena maps, resident run-time
      (messages, files, errors), unit call discipline
- [ ] `lib/libc.s` start-up, `write`, `putchar`, `exit`; `lib/mklib.py`;
      `cc.lib` in the build
- [ ] image writer: library copied in, start-up words patched, STX2 out
- [ ] `tests/check-units.py`: no unit over 4 KiB, no jump across units

### Stage 1: `int`, statements, functions
- [ ] scanner: identifiers (interned in the arena), numbers, punctuators,
      comments, character constants
- [ ] value stack, evaluation registers, instruction encoders, branch patching
- [ ] expressions on `int`: all binary and unary operators, assignment and
      compound assignment, `++`/`--`, `?:`, `&&`, `||`, comma
- [ ] statements: compound, `if`, `while`, `do`, `for`, `break`, `continue`,
      `return`, expression statements
- [ ] functions: definitions, parameters, calls, recursion, prototypes
- [ ] local and global `int` variables

### Stage 2: types
- [ ] the type table: `char short int long`, signed and unsigned, pointers,
      arrays, functions
- [ ] declarators in full (pointers to arrays, arrays of pointers, ...)
- [ ] pointer arithmetic, indexing, `&`, `*`, `sizeof`
- [ ] integer promotions and the usual arithmetic conversions; casts
- [ ] string literals; global data with constant initialisers of scalars

### Stage 3: aggregates and the rest of the statements
- [ ] `struct`, `union` (members, `.`, `->`, assignment, by-value arguments
      and results), `enum`, `typedef`
- [ ] initialisers: scalars, arrays, structures, strings, nested braces
- [ ] function pointers
- [ ] `switch`, `goto` and labels
- [ ] `static` locals, `extern`, tentative definitions

### Stage 4: the preprocessor
- [ ] `#include` (library file and file system), include stack
- [ ] object-like and function-like macros, `#undef`, `#` and `##`,
      `__LINE__`, `__FILE__`, the predefined macros
- [ ] `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`, `defined`
- [ ] `#error`, `#line`, `#pragma` (ignored)
- [ ] the library's headers

### Stage 5: the rest of C99
- [ ] `long long`, `_Bool`, `//` comments, mixed declarations and code,
      declarations in `for`
- [ ] variadic functions (`<stdarg.h>`), more than eight arguments
- [ ] designated initialisers, compound literals
- [ ] bit-fields
- [ ] variable-length arrays
- [ ] floating point (soft-float in the library; constants, conversions,
      arithmetic, comparisons, `printf` of `%f`)
- [ ] `printf` family, `malloc`, strings, `<ctype.h>` complete in the library

### Stage 6: the second source
- [ ] paged code model (`-p`) tested on the ladder
- [ ] `cc.c`, compiled by the assembly compiler
- [ ] fixed point: `cc1 = cc(cc.c)`, `cc2 = cc1(cc.c)`, identical bytes

## Integration
- [ ] `cc` and `cc.lib` in the OS image (Makefile), `help` line in the shell
- [ ] `make test-cc`, and the fast subset in `make test`
- [ ] `examples/hello.c` and a larger example, compiled and run by a test
- [ ] README section; `doc/strataos.md` and the manual mention `cc`

## Scores

| Stage | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 | 09 | Total |
|---|---|---|---|---|---|---|---|---|---|---|
| tests | 32 | 12 | 93 | 33 | 58 | 75 | 18 | 139 | 61 | 521 |

## Notes for whoever continues

(decisions that turned out differently from DESIGN.md, traps, measurements)
