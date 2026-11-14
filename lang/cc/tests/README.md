# Test vectors for `cc`

The compiler is driven and measured by a **ladder**: existing C conformance
tests, sorted by the language features they need. `run.sh` compiles each test
with `cc` inside StrataOS under the emulator, runs the result there, compares
exit status and standard output, and prints a pass count per rung.

```
make test-cc                 # the whole ladder
make test-cc-fast            # the subset `make test` runs
lang/cc/tests/run.sh 03      # one rung (a prefix of its name)
lang/cc/tests/run.sh -v 04   # ... listing every failure
CC_FLAGS=-p lang/cc/tests/run.sh   # the same in the paged code model
```

## Suites

Each suite was cloned and its licence read from the files named below.

| Suite | Revision | Licence | Adopted |
|---|---|---|---|
| scc, `tests/cc/execute` (git://git.simple-cc.org/scc) | 66f99bceac13dc773446a44f22afd4bdc5f895a8 (2026-09-15) | ISC: `LICENSE` at the top of the repository ("ISC License", the copyright holders listed there) | 266 tests |
| lacc, `test/c89` and `test/c99` (https://github.com/larmel/lacc) | 30839843daaff9d87574b5854854c9ee4610cdcd (2022-03-11) | MIT: `LICENSE.md` | 255 tests |
| c-testsuite (https://github.com/c-testsuite/c-testsuite) | 5c7275656d751de0e68b2d340a95b5681858ed07 (2020-03-09) | MIT for the runners (`LICENSE`); `tests/LICENSE` says each test's licence follows its origin, recorded in its `.otags` file | none directly |
| chibicc (https://github.com/rui314/chibicc) | 90d1f7f199cc55b13c7fdb5839d1409806633fdb (2020-12-07) | MIT: `LICENSE` | none |
| 8cc (https://github.com/rui314/8cc) | b480958396f159d3794f0d4883172b21438a8597 (2020-10-13) | MIT: `LICENSE` | none |
| cproc (https://github.com/michaelforney/cproc) | d1c53ddf56571573a7025324c8dd5c6d547a4d1f (2026-04-27) | ISC: `LICENSE` | none |
| TinyCC `tests/tests2` (https://repo.or.cz/tinycc.git) | not kept | LGPL-2.1 | optional download |
| GCC `gcc.c-torture/execute` | not kept | GPL-3.0 | optional download |

- **scc.** The tests are single files that return 0 from `main` on success;
  a few print. Its `README` in that directory credits some of them to Andrew
  Chambers's qc; he is among the copyright holders of scc's licence. The
  licence is copied to `LICENSES/scc-LICENSE`.
- **lacc.** Single files; the suite's own method (`test/check.sh`) is to
  compare exit status and standard output with those of a reference compiler.
  The expectations kept here were produced that way, with the host compiler
  (`cc -std=c99`, arm64, LP64, signed `char`: the target's data model). The
  licence is copied to `LICENSES/lacc-LICENSE.md`.
- **c-testsuite** has 220 single-file tests: 150 of them are scc's tests at an
  older revision (355356a9836e487939cf5e98b5332a63e5264e27, 2018-08-26), taken
  here from scc itself at the newer revision, and 69 are TinyCC's `tests2`
  (LGPL), which are not kept.
- **chibicc** tests rely on GNU statement expressions through the `ASSERT`
  macro of `test/test.h` in every check, so they are not C99 programs.
- **8cc** tests are linked with `test/testmain.c` and include `test.h`: not
  single files, and several use extensions.
- **cproc** tests compare the compiler's QBE output with expected QBE text;
  they are not run.
- `fetch-optional.sh` downloads TinyCC, c-testsuite and GCC's torture tests
  into `optional/` (ignored by git) for anyone who wants to try them.

The adopted files are byte-identical to upstream. Their names carry the suite
(`scc-0042-prime.c`, `lacc-bitfield-basic.c`); `_` in an scc name became `-`.

## How tests were chosen

`collect.py SUITES OUT WORK` made the ladder from clones of the suites. A
candidate was dropped when it
- includes a header other than `stdio.h stdlib.h string.h stdarg.h stddef.h
  stdint.h limits.h stdbool.h ctype.h assert.h math.h float.h` (6 tests: local
  headers and `wchar.h`),
- uses C11 or an extension (1),
- does not build with the reference compiler in C99 mode, or does not exit
  normally there (13: implicit `int`, implicit function declarations, K&R
  corner cases the host compiler rejects),
- prints addresses, dates or file names (5), is not deterministic (1), or
  prints more than 16 KiB (1).

Every kept test was compiled and run on the reference host; an scc test is
kept only if it returns 0 there.

## The ladder

`ladder/RR-name/NAME.c`, with `NAME.out` (expected standard output, only when
there is some) and `NAME.exit` (expected exit status, only when not 0).
`ladder/MANIFEST.tsv` lists every test: rung, file, suite, upstream path and
flags (`printf`, `stdlib`, `string`, `stdarg`, `float`: what it needs from
the library).

A test sits on the highest rung whose features it uses; the sorting is by
pattern (`collect.py`), so it is approximate. Including `<stdio.h>` to print
does not by itself put a test on the preprocessor rung.

| Rung | Needs | scc | lacc |
|---|---|---|---|
| 01-int-control | integer expressions, assignment, `if`/`while`/`for`/`do` | 25 | 7 |
| 02-functions | functions, recursion, scalar globals | 11 | 1 |
| 03-pointers-arrays | pointers, arrays, strings, `char`/`short`/`long`, casts, `sizeof` | 63 | 30 |
| 04-structs | `struct`, `union`, `enum`, `typedef` | 26 | 7 |
| 05-preproc | macros, conditionals, `#` and `##` | 46 | 12 |
| 06-init | aggregate and string initialisers, static locals | 36 | 39 |
| 07-funcptr-switch-goto | function pointers, `switch`, `goto` | 10 | 8 |
| 08-c99-misc | `long long`, `_Bool`, designated initialisers, compound literals, VLAs, mixed declarations, `//`, variadic functions, bit-fields | 39 | 100 |
| 09-float | `float`, `double` | 9 | 52 |

`ladder/EXPECT.tsv` records tests (as `rung/file`) that are not expected to pass, with the
reason (a feature not implemented, or a program too large for the machine);
the runner reports them separately and they do not fail a run. For `cc` the
list is empty: all 521 pass. `ladder/include/` holds the few files of the
suites that tests include; the runner puts them on every test disk.
`ladder/EXPECT-cc0.tsv` is the same list for the bootstrap compiler, empty too.

## The runner

`run.sh` builds disk images holding the OS, `cc`, its library and a batch of
tests (the directory holds 128 files), boots each under
`strata-emu -T virtual` with a scripted console session that compiles and
runs every test of the batch, and reads the results out of the console
output. A test that hangs ends its boot at the step limit; the runner marks
it and boots again for the rest of the batch. Results are also written to
`out/results.tsv`.

Environment: `CC_FLAGS=-p` compiles in the paged code model; `CC_NAME=cc0`
uses the bootstrap compiler (`make test-cc0`); `CC_HOST=build/strata-cc`
compiles on the host with the cross compiler and only runs the programs in
StrataOS (`make test-cc-host`), which is the quick way to try a change to
`cc.c`. `../examples/cmp.c` is the file comparison that `tools/test-cc-boot.sh` uses to
check that the compiler reproduces itself.
