# A C99 compiler for Strata: design

`cc` is a C99 compiler written in Strata assembly. It runs as a StrataOS
program, reads C source from the file system and writes a program image
that the shell can start. This file records the decisions and their reasons.
`PLAN-cc.md` tracks what is done; `tests/README.md` describes the tests.

## 1. What `as` is here, and what `cc` is

`as` (`os/progs/as.s`) is a program in the OS image, tagged `bin`, started
from the shell as `as < prog.s > prog`. It is a bare-metal program: `proc`
copies its input file into its arena and appends its output to a file when it
exits. That protocol gives it one input of at most 256 KiB, one output of at
most 64 KiB and no file access; its symbol heap holds about a thousand labels
and it accepts 4096 `li`/`la` lines.

`cc` is available the same way: a program on the disk, tagged `bin`, listed
by the shell's `help`. It does **not** go through `as`:

- **`cc` emits program images directly** (STX2, the format `as` writes).
  Compiler output is full of generated labels and address loads; a program of
  a few thousand instructions exceeds `as`'s label and `li` limits, and its
  64 KiB output limit is half of what the kernel can load. Formatting text for
  another program to parse again would also cost more compiler code than
  encoding the forty-odd instructions the compiler uses.
- So there is no linker either. The run-time library is assembled once, on the
  host, at fixed addresses (code from I-LS 0x8000, data from D-LS 0), and `cc`
  copies it into every image and places the program after it. A table of the
  library's exported names and addresses sits beside it. This is static
  linking against a library at a fixed address.
- `cc` needs one more file, `/bin/cc.lib`: the library's code and data, its
  export table, the headers, and the compiler's own code units (section 4).

`cc hello.c` writes `hello` (the name without `.c`; `-o NAME` chooses
another); typing `hello` runs it.

```
cc [-o OUT] [-p] [-h KIB] FILE.c ...
  -p      page the program's code: functions go into 4 KiB code units
  -h KIB  heap size (the D-LS after the program's data; default 8)
```

## 2. The machine, as a C target

- Loads and stores reach only the data Local Store. In StrataOS a program has
  D-LS 0..0x9FFF (40 KiB) for data and 0xE000..0xFFFF (8 KiB) for its stack,
  and I-LS 0x8000..0xFFFF (32 KiB) for code. Everything else is the arena, a
  megabyte of system memory behind capability c0, reached with `tget`/`tput`.
- There is no floating-point hardware and there are no 32-bit arithmetic
  instructions: the ALU is 64-bit (`add sub and or xor sll srl sra slt sltu
  mul mulhu divu remu div rem`), with sign- and zero-extending loads of 1, 2,
  4 and 8 bytes.
- A context switch saves the program's *data extent* (the D-LS section of its
  image) and its live stack. Memory outside the extent is not kept, so the
  heap is part of the D-LS section.

### Data model: LP64, pointers are D-LS addresses

| type | size | align | | type | size | align |
|---|---|---|---|---|---|---|
| `_Bool`, `char` (signed) | 1 | 1 | | `long`, `long long` | 8 | 8 |
| `short` | 2 | 2 | | pointers | 8 | 8 |
| `int`, `enum` | 4 | 4 | | `float` | 4 | 4 |
| | | | | `double`, `long double` | 8 | 8 |

- `int` is 32 bits although the machine has no 32-bit arithmetic. Programs
  and tests assume it (overflow of `unsigned`, the type of `0xffffffff`,
  `sizeof(int)`), so the compiler pays for it: see "narrow values" below.
- **A pointer is a D-LS address** held in 64 bits. A C object must be
  reachable by a load, and loads reach only the D-LS, so every object (static,
  automatic, allocated by `malloc`) lives there. A program has at most 40 KiB
  of data and heap and 8 KiB of stack; this is the machine's scratchpad shown
  as it is.
- **System memory is not addressable from C.** The arena is reached through
  library calls (`<strata.h>`: `far_read(offset, buffer, n)`,
  `far_write(...)`, whole words, which are `tget`/`tput` on c0). A "far
  pointer" that hid a software cache behind every dereference would cost a
  check per access and code the 32 KiB instruction store has no room for.
  Programs that need more than the D-LS manage it themselves, like the
  assembly programs of this system do.
- Floating point is soft: IEEE 754 double in the library (`lib/fp.s`:
  `__fadd`, `__fmul`, ...), round to nearest even; the compiler includes the
  same routines to fold constants. `float` is kept as a 4-byte object and
  computed in double.

### Registers and calling convention

| registers | use |
|---|---|
| `a0`..`a7` | arguments; `a0` the result |
| `t0`..`t5` | expression evaluation; not kept across calls |
| `t6`, `tp` | code generator scratch (`t6` holds the target of a far call) |
| `s0` | frame base, only in functions with variadic or stack parameters |
| `s1`..`s11` | not used by compiled code; kept across calls by the library |
| `gp` | the constant 0x10000 |
| `sp`, `ra` | stack pointer (8-byte aligned), return link |

- Arguments are converted to their parameter types and passed clean (sign- or
  zero-extended to 64 bits) in `a0`..`a7`; further ones go on the stack at
  `0(sp)`, `8(sp)`, ... A structure is passed as the address of a copy the
  caller makes. A function that returns a structure gets the address of the
  result as a hidden first argument.
- A variadic function stores `a0`..`a7` just below its caller's stack
  arguments and sets `s0` to the first: every argument is then at `8*i(s0)`
  and `va_arg` is a pointer walk. The same frame base serves functions with
  more than eight parameters.
- The frame has a fixed size: `sp` moves only in the prologue and epilogue
  (and around a call with stack arguments), so locals are addressed from `sp`
  and there is no frame pointer. The prologue is two instructions,
  `addi sp, sp, -F` and `sd ra, F-8(sp)`, patched when the function ends and F
  is known.
- **`gp` = 0x10000 makes every static address one instruction away**: D-LS
  addresses below 0x8000 are `imm(zero)`, the rest `imm(gp)` with a negative
  immediate. The same register reaches the resident library from paged code
  (`jalr ra, gp, f-0x10000`).

## 3. Programs larger than the instruction store

Two code models, chosen on the command line:

- **Resident** (default). Library and program share I-LS 0x8000..0xFFFF.
  Calls are `jal`, returns `jalr`. About 6000 instructions of program.
- **Paged** (`-p`). The library stays resident; every C function goes into the
  image's `.far` section, packed into 4 KiB code units (a function never
  straddles a unit, so its branches stay inside one; a function over 4 KiB is
  an error). `crt0` sets `xslot` to 12 and StrataOS pages units into the code
  cache on `xmiss`, as it does for `units` and Forth. A call is
  `lui/ori t6, target; xcall ra, c0, t6` and every function returns with
  `xret ra`, because the caller's unit may have been evicted and reloaded into
  another slot meanwhile: only far links survive that. Library functions are
  leaves with respect to paging and are called with a plain link. A function
  pointer is a far offset (units start at arena offset 0x10000) or a resident
  address (below it); an indirect call tests which.

The image holds at most 128 KiB (the kernel's limit), of which the data
extent takes its share.

## 4. The compiler

`cc` is one program in Strata assembly, larger than the instruction store, so
it uses the mechanism of section 3 itself: a resident part (input and output,
the code buffer, the instruction encoders, messages) and 4 KiB code units for
everything else. With its 40 KiB data section and 107 KiB of units it is also
larger than the 128 KiB the kernel loads as one image: the units are a member
of `cc.lib`, which the resident start-up code reads and copies to the bottom
of the arena before the first `xcall`. StrataOS pages units from the
program's arena, wherever their bytes came from.

### One pass, no tree

The compiler reads the source once and emits code as it parses, with no
syntax tree. What it needs to see ahead of the code it emits is kept on a
**value stack** of descriptors. Each describes a value that is not computed
yet or sits in a register:

| kind | meaning |
|---|---|
| constant | an integer, or a symbol's address plus an offset |
| register | in evaluation register `t0`..`t5` |
| local | an lvalue at `offset(sp)` (or `offset(s0)`) |
| global | an lvalue at a static address |
| indirect | an lvalue at `offset(register)` |
| saved | an lvalue whose address was saved in a frame slot |
| local address | `sp + offset`, not yet in a register |

An operator pops its operands and pushes the result. Constants fold; a
constant or a variable as an operand becomes an immediate or a single load;
nothing is emitted for a name until it is used. Evaluation registers are a
stack (`t0` first), so the live ones are always the lowest. Before a call,
every live register is stored into a frame slot and its descriptor becomes
"local" or "saved". That is all the register allocation there is.

**Narrow values.** A register holding an `int` computed by `add`, `sub`,
`mul`, `sll` or a cast has garbage above bit 31. The descriptor says so
("dirty"), and the two instructions that extend it are emitted only when the
upper bits matter: before a comparison, a division, a right shift, a
conversion to a wider type, an index, an argument or a return. A store never
needs them. Values loaded from memory are clean.

This is the only optimisation, and it comes with the descriptors for free.
Variables live in memory; there is no register allocation for them.

### Output

Code is emitted as 32-bit words into a window of the image being built in the
arena. Forward branches are patched in place (in the window, or through an
8-byte read-modify-write of the arena). References to functions and objects
not yet defined are **fixups** (location, symbol, kind), resolved when the
symbol is defined or at the end. Static data is laid out as it is declared;
initialisers are written into the data image, with fixups for addresses of
functions.

At the end: `main`, the heap bounds and the paging flag are patched into the
library's start-up words, undefined symbols are reported, and the image is
written out as STX2 sections (I-LS from 0x8000, D-LS from 0 covering data and
heap, and in the paged model T3 from 0x10000).

### Preprocessor

The preprocessor works on text. A macro's body is stored as text; expanding
it pushes the text, with the arguments substituted, as a new input source
under the scanner. Arguments are expanded first by running the same scanner
over them into a buffer (so that `MAX(MAX(a, b), c)` works); `#` and `##` use
the unexpanded text. A macro is disabled while its expansion is being read.
Conditionals are evaluated with a small evaluator of their own.
`#include <name>` reads the library file, `#include "name"` the file system.

### Where the compiler's tables live

| table | where | why |
|---|---|---|
| symbols (16 bytes each), types (16 bytes each), value stack, scopes | D-LS | touched constantly |
| identifiers and their spellings, macro bodies, fixups | arena | large, touched once per token or less |
| the image being built (code, data, far code) | arena | larger than the D-LS |
| the library file | arena | read once |

An identifier is interned when scanned; the token carries its record's arena
offset and the record's bindings (keyword, macro, symbol, tag), read with one
`tget`.

### Diagnostics

`file:line: message`, then the compiler stops at the first error (exit
status 1, no output file).

## 5. Run-time library

`lib/libc.s`, in Strata assembly, assembled by `sasm` with the C calling
convention; `lib/include/*.h` declare it. Both are packed, with the export
table, into one disk file, `cc.lib`.

- `crt0`: the `"SYS2"` marker, handles from the start-up block, `gp`,
  `xslot`, `main(argc, argv)`, `exit`.
- Files map to the OS's messages: `open`/`read`/`write`/`close` are `fs`,
  `tty` and `pipe` requests on the program's handles; `fopen`, `fgetc`,
  `fputs`, `fclose` are thin layers over them; `stdout` is buffered and
  flushed at exit.
- `printf` family (`%d i u x X o c s p %`, `l`/`ll`/`h`/`z`, width, precision,
  `-`, `0`, `+`; `%f %e %g` with soft-float), `putchar`, `puts`.
- `malloc`/`free`/`calloc`/`realloc` (first fit with coalescing over the heap
  inside the data extent), `memcpy memmove memset memcmp strlen strcpy strcmp
  strncmp strcat strchr strrchr strstr`, `atoi strtol abs qsort`, `<ctype.h>`.
- Soft-float and the helpers compiled code calls.

## 6. Bootstrap: `cc.s`, then `cc.c`

There are two compilers.

- **`cc.c` is the compiler**: the `cc` of StrataOS, and, built for another
  machine, the cross compiler `build/strata-cc`. It is written in the C it
  compiles.
- **`cc.s`**, in assembly, is the **bootstrap** compiler (`cc0` in
  StrataOS): it exists so that `cc.c` can be compiled on a machine that has
  no C compiler. It only has to stay good enough for that; new language
  features go into `cc.c`.

The two agree on the calling convention and on the library, not on the code
they emit: `cc.c` generates somewhat tighter code. Both pass the whole test
ladder; `cc.c` alone has `asm("...")`.

### The fixed point

`make test-cc-boot` runs the bootstrap inside StrataOS:

```
cc0 -p -h 0 -o cc1 cc.c        cc1: cc.c compiled by the bootstrap compiler
cc1 -p -h 0 -o c2  cc.c        c2:  cc.c compiled by itself
c2  -p -h 0 -o c3  cc.c        c3:  the same, once more
```

`c2` and `c3` are the same bytes: the compiler reproduces itself. (`cc1`
differs: other compiler, other code.) They are also, byte for byte, the
`cc` that the Makefile puts on the disk, which is `cc.c` compiled by
`strata-cc` on the host: the cross compiler and the native one are one
program and give one result.

### `cc.c` on another machine

`cc.c` uses three things of StrataOS: the arena (`far_read`, `far_write`),
files (`open`, `read`, `write`, `close`), and the library's floating-point
routines, with which it folds constants. `lang/cc/host/` supplies them on an
ordinary 64-bit little-endian machine (an array for the arena, the host's
files and doubles), and `make build/strata-cc` compiles the two together
with the host's C compiler:

```
build/strata-cc [-o OUT] [-p] [-h KIB] FILE.c      # reads build/cc/cc.lib, or $CC_LIB
```

The image it writes runs in StrataOS as it is. The ordinary build makes
`cc` this way (no emulator is needed to build the system); the bootstrap
path is the test above.

### How `cc.c` differs inside

It is the same one-pass design as `cc.s` (section 4), with these changes:

- **A program of its own size.** Its code is 108 KiB in 4 KiB units, more
  than an image may hold beside its data, so the units are a second file,
  `cc.u`, which the start-up code of every paged program loads when the
  image says so (`__uload`). Its tables take 38 of the 40 KiB of data:
  symbols (700), types (600), the value stack; everything else is in the
  arena: identifiers and their hash, macros, fixups, parameter types, the
  cases of open `switch` statements, the image being built.
- **The source is read as the scanner goes**, through a 64 KiB window of
  the arena, so a source file may be larger than the arena has room for
  (`cc.c` itself is 130 KiB). An array whose length its initialiser gives is
  read twice; the window then keeps the text from where the initialiser
  began.
- **Comparisons and narrow results stay lazy.** A comparison is a value
  that has not been made yet (two registers and a condition): a branch uses
  it as it is. The result of 32-bit arithmetic is marked when its upper bits
  are not yet the extension of the lower ones, and extended only where that
  matters (a comparison, a wider use, an argument).
- **What is in registers goes to the frame before a conditional branch** of
  `?:`, `&&` and `||`: a store made on one path only would be lost on the
  other.
- Functions used before their definition, and the library's, are called
  through fixups resolved when the image is closed; in the paged model the
  call of a resident library function is patched to one instruction then.
- Bit-fields are laid out as the usual ABIs do (a field starts at the next
  free bit unless it would cross a unit of its type). Unnamed structure
  members (C11) are accepted.
- **Code that is parsed but not compiled** (the arm of a constant condition
  that is not taken, the operand of `sizeof`, a constant expression) leaves
  the value stack entries of live code and the register mask as they were.

### Variable-length arrays

An array type whose size is not a constant keeps its size in a frame word,
computed where the declarator stands; `sizeof` and pointer arithmetic read
that word. This covers arrays of arrays and pointers to them. The storage
of a variable-length array comes from `malloc`, its address is a frame word
(the object is reached as a structure parameter is), and it is given back
at the end of its block and before `return`, `break` and `continue` leave
it; a `goto` out of the block does not give it back. Local Store has no
second stack to take it from: `sp`-relative frames stay fixed.

In a parameter list the names a dimension uses are not declared yet and no
code can be emitted, so the text of the dimension is kept in the arena and
read again, as an expression, when the function is entered.

### `asm("...")`

```
asm("ld    t0, {a}\n"            /* {name}: a C object as a memory operand */
    "addi  t0, t0, {BIAS}\n"     /* ... an enumeration constant as a number */
    "loop: addi t0, t0, -1\n"    /* a label of the function */
    "bnez  t0, loop\n"
    "la    t1, {total}\n"        /* ... the address of an object */
    "call  {f}\n"                /* ... a C function */
    "sd    a0, {r}");
```

The text is Strata assembly as `as` reads it, one instruction a line, `;`
to the end of a line a comment: every instruction and pseudo-instruction of
the assembler, with numbers (not expressions) as operands. It is encoded in
place. `t0`-`t6`, `tp` and `a0`-`a7` are free between two statements; the
other registers are the compiler's. In the paged model `ret` is `xret ra`,
and `call` of a C function is the call the compiler would make.

At file scope the labels of an `asm` are functions: declared in C, they are
called like any other (`examples/asm.c`).

The instruction table is not in the compiler: `lib/mkasm.py` makes it from
the assembler itself, by assembling each instruction with `sasm` and seeing
which bits each operand changes, and it travels in `cc.lib` (`asm.tab`,
110 instructions). The compiler cannot disagree with the assembler.
