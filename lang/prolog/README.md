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

The design, and the reasons for it, are in [DESIGN.md](DESIGN.md).

## Running it

```
strata$ stralog                       the top level
strata$ stralog /prolog/family.pl     consult files first
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

**Consulting.** `consult/1` and `[File]` look for `File`, `File.pl`, `/prolog/File` and `/prolog/File.pl`, in that order. The examples are tagged `prolog`.

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
  - Bodies are copied when a clause is called, so a long deterministic recursion uses heap until it backtracks, the query ends, or (milestone 5) the collector runs.
  - A full heap raises `resource_error(memory)`.
- **Recursion depth:** unification, copying, comparing and writing recurse on the machine stack (8 KiB) except on a compound's last argument. Lists can be any length, but a term nested more than about 200 deep elsewhere raises `resource_error(term_depth)`.
- **Sizes:**
  - an arity of at most 255;
  - names of at most 1000 bytes;
  - 64 variables in a clause read;
  - 64 KiB of atoms, 184 KiB of clauses, 124 KiB of findall answers.

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
| `examples/` | Prolog programs on the disk, under `/prolog` |
| `tests/` | the scripted sessions (`run.sh`, in `make test`) |
