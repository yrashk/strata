# Stralog

A Prolog for Strata, written in Strata assembly, that runs as a StrataOS
program. Strata's memory is explicit I/O, and Stralog's engine is built
around that rather than hiding it:

- Every term lives in far memory: the arena, reached only by `tget` and
  `tput` through capability c0.
- The data Local Store holds windows onto the tops of the heap, the trail
  and the choicepoint stack, plus a small write-back far cache for
  everything else.
- `statistics/0` shows what moved between the two.

The design, and the reasons for it, are in [DESIGN.md](DESIGN.md). The website's
Stralog page (`doc/manual/gen/genstralog.py`) has the syntax, a reference entry
for every predicate (templates, errors, differences from ISO and SWI-Prolog,
examples: `doc/manual/web/stralog-ref.txt`), the example programs with Try
buttons, and a playground running it in StrataOS in the browser.

## Running it

```
strata$ stralog                       the top level
strata$ stralog /stralog/family.pl     consult files first
strata$ stralog -g 'main' prog.pl     run a goal and halt (the goal: no spaces)
strata$ -m 8 stralog                  an arena of 8 MiB: about 7 MiB of heap
```

A session:

```
?- X = f(Y), Y = 3.
X = f(3), Y = 3.
?- [family].
true.
?- ancestor(A, jim).
A = pat ;
A = tom ;
A = bob ;
false.
?- findall(D, ancestor(tom, D), Ds).
Ds = [bob,liz,ann,pat,jim].
```

**Answers.** After an answer that may have others, the top level waits for a line:

- `;` asks for the next answer;
- anything else stops.

**Line editing.** The line editor echoes what is typed and understands:

- Backspace;
- Ctrl-U, which kills the line;
- Ctrl-D on an empty line, which ends the input;
- ↑ and ↓, which bring back the last eight lines.

It works on the console, which it puts in raw mode while a line is typed, and in a window server terminal, whose keys arrive as they are.

**Consulting.** `[user]` reads clauses typed in, up to Ctrl-D. `consult/1` and `[File]` look for `File`, `File.pl`, `/stralog/File` and `/stralog/File.pl`, in that order. The examples are tagged `prolog`.

## The language

ISO core Prolog in one namespace.

- **Control:** `,` `;` `->` `*->` `\+` `call/1..8` `catch/3` `throw/1` `findall/3,4` `forall/2`.
- **Terms:** `=` `\=` `==` `@<` (and the other standard-order comparisons) `compare/3` `functor/3` `arg/3` `=../2` `copy_term/2` `term_variables/2`, and the type tests.
- **Arithmetic:** `is/2` and the comparisons, over integers of 61 bits:
  - `+ - * // / mod rem div min max abs sign gcd ** ^ >> << /\ \/ xor \ msb`;
  - a result outside 61 bits raises `evaluation_error(int_overflow)`;
  - there are no floats, so `/` divides and truncates.
- **Atoms and text:** `atom_codes` `atom_chars` `char_code` `atom_length` `number_codes` `number_chars` `atom_concat` `sub_atom` `atom_number` `upcase_atom` `term_to_atom`. Double-quoted text is a list of codes.
- **Database:** `assert` `asserta` `assertz` `retract` `retractall` `abolish` `clause/2` `dynamic/1`, under the logical update view.
- **Input and output:** `read/1,2` `read_term/2,3` (with `variable_names/1`), `write` `print` `writeq` `write_canonical` `write_term/2,3` `nl` `put_char` `get_char` `peek_char` `open/3,4` `close/1` `set_input` `set_output` `current_input` `current_output` `flush_output`, and `format/1,2` (`~w ~a ~d ~q ~p ~s ~n ~~`).
- **Operators:** `op/3` and `current_op/3`.
- **All solutions and DCGs:** `bagof` `setof` (with `^`), DCG rules (`-->`, `phrase/2,3`).
- **Lists:** `append` `member` `memberchk` `length` `reverse` `nth0` `nth1` `last` `select` `permutation` `delete` `exclude` `include` `maplist/2..4` `foldl/4` `sum_list` `max_list` `min_list` `numlist/3` `msort` `sort` `keysort` `predsort` `between/3` `succ/2` `plus/3`.

Errors are ISO error terms (`error(type_error(callable, 1), _)` and so on).

Not there:
- floats;
- bignums;
- modules;
- tabling;
- constraints;
- streams other than files and the console;
- garbage collection of atoms.

## Limits

- **Memory:**
  - The arena's program memory is 832 KiB unless `-m N` gives more.
  - Above 512 KiB the heap, the trail (a 16th) and the choicepoint stack (a 32nd) share it. In the default arena that leaves 236 KiB of heap.
  - Bodies are copied when a clause is called, so a long deterministic recursion uses heap until it backtracks, the query ends, or the collector runs.
  - A full heap raises `resource_error(memory)`.
- **Garbage collection** (`gc.s`):
  - When the heap passes three quarters of its size, the solve loop collects it between two goals, with a sliding mark-and-compact collector.
  - The roots are the continuation, every choicepoint's goal and continuation, and the trail. The trail is tidied first: an entry whose cell is newer than its choicepoint's heap top undoes nothing, and would only keep cells alive.
  - The mark bitmap and a prefix count every 64 cells go in the free heap above the top. Every cell moves through the same window and far cache as the rest of the engine.
  - The next collection comes when the heap has grown by half of what is free (at least 64 KiB).
  - `statistics/0` counts collections and the bytes they gave back. In `examples/sorting.pl`, `nrev_bench(200)` allocates 2.3 MB on a 3 MB heap and is collected once.
- **Recursion depth:** unification, copying, comparing and writing recurse on the machine stack (8 KiB) except on a compound's last argument. Lists can be any length, but a term nested more than about 200 deep elsewhere raises `resource_error(term_depth)`.
- **Sizes:**
  - an arity of at most 255;
  - names of at most 1000 bytes;
  - 64 variables in a clause read;
  - 80 KiB of atoms, 168 KiB of clauses, 124 KiB of findall answers.
  - Clauses that are retracted or replaced by a new consult keep their space. Atoms are never collected, so `sub_atom/5` makes atoms only of its answers.

## Files

| file | what |
|---|---|
| `stralog.s` | the layout, the D-LS, start-up (reads `/bin/stralog.u` into the arena) |
| `core.s` | cells, the windows, the far cache, unification, templates (resident) |
| `solve.s` | the solve loop, control constructs, backtracking, exceptions (resident) |
| `db.s` `term.s` | atoms and predicates; compiling clauses into templates, findall, call/N |
| `read.s` `write.s` | the reader and the writer |
| `arith.s` `bi.s` `io.s` | arithmetic, the builtins, streams and the line editor |
| `init.s` | start-up: atoms, the builtin table, `boot.pl` |
| `boot.pl` | what is written in Prolog: the top level, consult, lists, sorting, bagof, DCGs, format |
| `mkatoms.py` `mkboot.py` `mkimg.py` | the build: predefined atoms; `boot.pl` as text; the split into the program and its code units, with the check that no jump leaves its unit |
| `gc.s` | the heap's garbage collector |
| `examples/` | Prolog programs on the disk, under `/stralog` (below) |
| `tests/` | the scripted sessions (`run.sh`, in `make test`): `session`, `builtins`, `files`, `demos`, `iso`; and `ref.sh`, which runs the examples of the website's predicate reference (`doc/manual/web/stralog-ref.txt`) |
| `tests/iso/` | the ISO conformance vectors, and `iso_run.pl`, which runs them |

## Examples

On the disk under `/stralog`; consult one with `[queens]`:

| file | what | try |
|---|---|---|
| `family.pl` | facts, rules, recursion, a cut | `ancestor(A, jim).` |
| `queens.pl` | N queens, generate and test and column by column | `queens2(8, Qs), show(Qs).` |
| `zebra.pl` | the zebra puzzle | `zebra(Owner).` |
| `animals.pl` | an expert system that asks questions and remembers the answers | `identify.` |
| `hanoi.pl` | the towers of Hanoi | `hanoi(3).` |
| `primes.pl` | primes by trial division and a sieve with a lambda | `primes(60, Ps).` |
| `sendmore.pl` | SEND + MORE = MONEY | `sendmore(L).` |
| `calc.pl` | a calculator as a DCG | `calc("2 * (3 + 4) - 5", V).` |
| `roman.pl` | Roman numerals both ways with a DCG | `roman(1987, R).` |
| `graph.pl` | paths, breadth-first search, setof | `shortest(a, e, P).` |
| `kb.pl` | a knowledge base of planets, with setof and aggregate_all | `in_order(Ps).` |
| `meta.pl` | a meta-interpreter with proof trees | `proof(app([1], [2], L), P).` |
| `sorting.pl` | quicksort, insertion sort, a naive-reverse benchmark | `nrev_bench(200).` |

## Conformance

`tests/iso/` holds 596 vectors in 49 files, one per builtin or control
construct. They come from [Logtalk](https://logtalk.org/)'s tests
(Apache-2.0), which carry the examples of the ISO/IEC 13211-1 standard and
of Szabó and Szeredi's conformance suite.

`tests/mkiso.py` makes them from a Logtalk checkout. It keeps the tests
whose body is one goal, and leaves out floats, Logtalk's own notation and
what Stralog does not have.

`make test` runs them in groups, each in a fresh `stralog`
(`tests/iso.txt`), and compares the result with `tests/iso.out`. Today 584
pass. The 12 that do not:
- `findall/3` does not check its result list;
- `term_variables/2` does not check its second argument;
- `=..` does not refuse `[]`;
- a variable body is not turned into `call/1` when a clause is stored;
- `retract/1` and `retractall/1` differ on two of the standard's examples;
- two `call/1` tests need dynamic declarations that live inside Logtalk's test object.
