# Stratalk

A Smalltalk for Strata, running under StrataOS. Its object memory follows
the machine's rule: the core works in its Local Stores, and far memory is
reached with transfers.

```
strata$ stratalk                      the REPL (Tab completes, the arrows recall lines)
strata$ stratalk -e 3 + 4             one expression, printed
strata$ stratalk FILE.st ARGS...      file a program in
strata$ echo '100 factorial' | stratalk -
```

`doc/stratalk-proposal.md` is the design as it was proposed. This file says
what was built, in what form, and why.

## The language

Smalltalk-80 with Pharo's syntax, class library and exceptions:

- **Files are the source.** A file holds class definitions, methods and
  statements, run in order:

  ```smalltalk
  Object subclass: #Point slots: 'x y'.
  Point class >> x: ax y: ay [ ^self new setX: ax y: ay ]
  Point >> + p [ ^Point x: x + p x y: y + p y ]
  Transcript showln: (Point x: 1 y: 2) printString.
  ```

  `variableSubclass:`, `byteSubclass:` and `wordSubclass:` make indexed
  classes. `| a b |` at the top level declares variables of the file
  (globals). The image is a cache built from the kernel's files; it is
  never the only copy of anything.
- **Blocks** are closures with non-local return: `^` in a block returns
  from the method it is written in; if that has returned already,
  `BlockCannotReturn` is signalled.
- **Exceptions** as in ANSI: `on:do:`, `ensure:`, `ifCurtailed:`,
  `signal`, `resume:`, `retry`, `return:`, `pass`, `outer`, exception sets
  (`ZeroDivide, MessageNotUnderstood`). A handler runs on top of the stack
  that signalled. An unhandled error prints its message and the stack, and
  goes back to the prompt.
- **Numbers**: 63-bit SmallIntegers; LargePositive- and
  LargeNegativeIntegers (bytes, in Stratalk) when they overflow. No floats.
- **Strings** are bytes; Symbols are unique and always in far memory;
  literals cannot be changed.
- **Not here**: `thisContext` (the `Frame` class answers what exceptions
  need), `become:`, class variables (use class-side slots), traits.

## Talking to StrataOS

`OS.st`: a `Server` is an endpoint in one of the process's capability
registers (proc 1, fs 2, tty 3, pipe 4, or one looked up by name), and a
request is a message (operation, handle, mode, data) whose reply comes
back as a `ServerReply`:

```smalltalk
Proc ps                 "the processes, as ProcessInfo"
Proc info               "cores, heap, switches"
Fs statfs               "#(blocks used files)"
Dev devices             "the platform table"
(Server proc) request: 16 replySize: 64     "any operation of os/spec/*.toml"
(File named: '/doc/motd') contents
File write: 'hello' to: 'note'
```

## The VM (`vm.s`, `vm-mem.s`, `vm-prim.s`, `vm-data.s`)

A bytecode interpreter in Strata assembly (22 KiB of the program's 32 KiB
of I-LS; 38 KiB of its 40 KiB of D-LS). Not C: the interpreter's loop must
stay resident in the I-LS with ip, fp, hp, self, the nursery's pointers
and the caches' bases in registers for the whole run, which a C function's
register allocation does not give, and a C program larger than the I-LS
pays an `xcall` at every call.

### Object memory: near and far

- **References.** Bit 0 set: a SmallInteger. Low bits `100`: a Character.
  `010`: a *near* object (in the D-LS). `000`: a *far* object (an offset in
  the far heap); 0 is nil. Where an object lives shows in its reference.
- **An object** is a header word and slots. Header: class index (bits
  0..15), format (16..19: 0 named slots, 1 indexed, 2 bytes, 3 compiled
  code, 4 raw words), unused bytes of the last word (20..22), immutable
  (23), mark (24), identity hash (27..43), slots (44..63).
- **New objects are near**: bumped in an 8 KiB nursery. A near object has
  a forwarding word before its header.
- **The scavenger** (when the nursery is full, or the remembered set):
  marks what the stack, the VM's roots and the remembered far slots reach;
  gives each survivor its far address; points every reference at it;
  slides the survivors together; copies them out to the heap's top in
  **one `tput`**. Promotion is the write-out.
- **The write barrier**: storing a near reference into a far object
  remembers the far slot (64 entries; full: a scavenge).
- **Far objects are read through a software cache** on `ltag`/`linst`:
  32 sets of two 64-byte lines. Every far store goes through it and out
  (write-through: one 8-byte `tput`).
- **Symbols, methods, classes and objects over 2 KiB are made far.**
- **The far heap** is an extra arena from `proc` (MORE) in c6, 6 MiB by
  default (`-m MIB`), the top 1 MiB of it the far stack.

### Methods and sends

- A method runs from the **method cache**: 4 KiB of D-LS into which a
  method's slots (header, literals, bytecodes) are copied in one `tget`.
  When it is full it is emptied; frames keep their method and an offset.
- A send looks in a 128-entry cache of (class, selector) → method; a miss
  walks the method dictionaries in far memory.
- The special selectors (`+ - < > <= >= = ~= * bitAnd: bitOr: == class
  ~~`) are done in place for SmallIntegers.

### The stack in pages

Frames are on the program's stack (D-LS 0xE000..0xFFFF). A frame is named
by a logical address (D-LS address + a bias). When an activation would not
fit, the frames above the current one go out to the **far stack** in one
transfer (after a scavenge: nothing near goes out) and the rest moves up;
returning into them brings them back. So recursion goes as deep as the far
stack (1 MiB, about 15,000 frames) and then signals `StackOverflow`.

### Frames

From the top: the receiver, the arguments, the other temps; six words
under `hp`: the caller's fp and hp (logical), the caller's ip (an offset
in its method), the method, a serial and flags, self; then the operands.
Flags: 1 a block's, 2 `ensure:`/`ifCurtailed:` (primitive 198), 4
`on:do:` (primitive 199), 8 unwound, 16 its handler running.

### Bytecodes

One byte, then 0..2 operand bytes. `lang/stratalk/host/stc.py` lists them
(`OPNAMES`). Literals: a method's selector and class are its last two;
a block's class its last.

## The JIT (`kernel/Jit.st`, `vm-jit.s`)

`stratalk -j ...` or `Jit on`: a method activated 200 times is offered to
the JIT (the VM counts activations in the method cache entry and sends
`Jit jitCompile: method` from inside the method's new frame). The JIT is
Stratalk code: it translates the bytecodes template by template into
Strata code that keeps the interpreter's frames and registers, with the
operands as constants and no dispatch. Temps, literals, pushes, stores,
jumps, `==`, `~~` and the SmallInteger cases of `+ - * < > <= >= = ~=
bitAnd: bitOr:` are done in place; sends, returns, closures, arrays and
objects' slots call the resident VM (`jalr ra, gp, ...`).

- **The code is paged, as memory is.** Each compiled method gets a code
  unit of 1 KiB in the program's arena (c0); the kernel pages units into
  the I-LS after the VM's resident code on a miss (`xslot` 10: 7 slots).
  A method whose code is over 1 KiB stays interpreted.
- **Returns are far links.** A send from native code passes the far
  address to come back to; the callee's frame keeps it in its ip word
  (`NATIVE` + the address), and the return goes there with `xret`, which
  pages the unit back in if it was evicted meanwhile.
- **The native table** (the specials' slot 15: pairs of method and c0
  offset; header bit 53 says a method is in it) is where the method cache
  finds a method's code. It keeps compiled methods alive.
- `tests/run.sh -j` runs every test vector with the JIT on (`stratalk-jit`).

## The compilers

- `host/stc.py`: the compiler on the host, which builds the image
  (`host/stratalk.py build`).
- `kernel/Compiler.st`: the compiler in the image, which the REPL and
  file-in use. It follows `stc.py` step by step;
  `host/stratalk.py check IMAGE kernel/LOAD` compiles every kernel method
  with both and compares the bytes (962 of 962 agree).

Captured variables that are assigned live in a temp vector; the others are
copied into the closure. `ifTrue:` and the like, `whileTrue:`, `to:do:`,
`and:`/`or:`, `ifNil:`/`ifNotNil:` and `repeat` are compiled in line.

## The host tool

`host/stratalk.py run IMAGE ARGS...` runs an image in a reference
interpreter written in Python: the same bytecodes and primitives, no
nursery (everything is far). It is how the kernel is debugged without the
emulator; `tests/run.sh -h` runs the test vectors on it.

## Tests

`tests/NAME.st` are expressions, one a line; `tests/NAME.out` what the
REPL must print for them, worked out by hand and by Python, not by
Stratalk: arithmetic at the SmallInteger boundaries and in large integers,
floor and truncated division, closures and non-local return, every path
of the exceptions, collections growing and shrinking, the collector under
load, deep recursion, the compiler. `tests/run.sh` types them into
`stratalk -` under StrataOS on the emulator; `-h` on the host.

Every class and method of the kernel is described by its comments (the
class's right after its definition, the method's first in its body), which
the site's Stratalk page shows. A comment line `EXPR >>> RESULT` is an
example; `tests/doc.sh` types every one into `stratalk -` and checks what
it prints.

## Files

| file | |
|---|---|
| `vm.s` | start-up, the interpreter, sends, returns, the paged stack |
| `vm-mem.s` | the far cache, allocation, the scavenger, the method and lookup caches, the image |
| `vm-prim.s` | the primitives |
| `vm-data.s` | constants and the D-LS |
| `kernel/*.st` | the class library (`LOAD`: their order) |
| `examples/*.st` | programs to try (on the disk: `/stratalk/examples`) |
| `host/` | the host compiler, image builder and reference interpreter |
| `tests/` | the test vectors |
