# Strata Forth

A Forth for Strata, the ISA where memory is explicit I/O. It is a classic
bootstrap — a small kernel in Strata assembly ([`forth.s`](forth.s)) and the
rest of the language written in Forth ([`core.fs`](core.fs)), compiled at
power-on — with a design that takes Strata's peculiarities as the point
rather than as obstacles:

- **Native code, installed by transfers.** Words compile to machine code.
  Stores cannot reach the instruction Local Store, so `;` installs each
  definition the only way code can get there: `tput` to a far-memory mirror
  of the I-LS, then `tgetx` back into the I-LS. The install is visible
  (`true jit-trace`, `.jit`, `see`).
- **Tiers and capabilities as words.** Transfers with tags, capability
  register operations, far atomics, and a far `@`/`!` backed by a software
  cache built on `ltag`/`linst`, with its hit/miss/write-back counts on
  display.
- **Cores as workers.** `spawn`/`await` run an xt on another core, which
  receives the image by being lent capability c0; memory moves between
  cores by `give`/`take` of capabilities (the demos split a heap and the
  framebuffer this way).
- **The conveniences of a modern Forth:** locals `{ a b -- }`, quotations
  `[: ... ;]`, `see` with a disassembler, `words`, `.s`, `catch`/`throw`,
  error messages that name the word (and the core.fs line), case-blind names.

It runs bare-metal on both `strata-emu` and `strata-rtl` (8 cores by
default) with byte-identical console output on both, and as a program of
**StrataOS 0.1** (`forth` at the shell: a REPL, `forth FILE`, `forth -e`,
pipes, `-n N forth` for threads), where the dispatcher preempts it like any
other process and reloads its generated code from a far mirror that Forth
keeps. One kernel source, two platform layers.

## Running it

```bash
make forth          # REPL on the emulator (bare metal, every core)
make forth-rtl      # the same on the Verilog simulator (slower)
make test-forth     # tests/test.fs on the emulator, the RTL and under StrataOS; files, tools, preemption
make boot           # StrataOS: then type `forth` at the shell (see "StrataOS" below)
```

Feed a file instead of typing (the REPL echoes each line, then the output,
then ` ok`):

```bash
build/strata-emu -c 8 -i lang/forth/demos/tiers.fs build/forth.stx
build/strata-emu -c 8 -i lang/forth/demos/multicore.fs build/forth.stx
build/strata-emu -c 8 -r 320x200 -i lang/forth/demos/gfx.fs build/forth.stx     # opens a window
build/strata-emu -c 8 -r 320x200 -g none -F m.ppm -i lang/forth/demos/gfx.fs build/forth.stx
```

End of input (or `bye`) halts every core. There is no Ctrl-C: the REPL runs
in supervisor mode on bare metal, which nothing can preempt; a runaway loop
is stopped by quitting the simulator.

## A session

A session fed from a file (each line is echoed, then its output follows):

```
Strata Forth 0.1 (native code, 8 cores, bare metal) 32528 code bytes free, 18200 data bytes free
: sq ( n -- n*n ) dup * ;  12 sq . 144  ok
see sq
: sq  ( xt $80f0 , 40 bytes)
  80f0:   442fff8  addi sp, sp, -8
  80f4:  60220000  sd ra, 0(sp)
  80f8:   508fff8  addi s0, s0, -8
  80fc:  61280000  sd s1, 0(s0)
  8100:  40a80000  ld t0, 0(s0)
  8104:   5080008  addi s0, s0, 8
  8108:   125480a  mul s1, t0, s1
  810c:  40220000  ld ra, 0(sp)
  8110:   4420008  addi sp, sp, 8
  8114:  a4010000  ret
 ok
variable v  : bump ( -- ) v @ 1+ v ! ;  ok
see bump
: bump  ( xt $8130 , 48 bytes)
  8130:   442fff8  addi sp, sp, -8
  8134:  60220000  sd ra, 0(sp)
  8138:   508fff8  addi s0, s0, -8
  813c:  61280000  sd s1, 0(s0)
  8140:  41205108  ld s1, 5108(zero)
  8144:   5290001  addi s1, s1, 1
  8148:  61205108  sd s1, 5108(zero)
  814c:  41280000  ld s1, 0(s0)
  8150:   5080008  addi s0, s0, 8
  8154:  40220000  ld ra, 0(sp)
  8158:   4420008  addi sp, sp, 8
  815c:  a4010000  ret
 ok
true jit-trace  : cube dup dup * * ; [jit: tput+tgetx 64 bytes -> I-LS 0x8160]  ok
false jit-trace  ok
1234 0 far!  0 far@ . 1234  ok
.fcache 1 hits, 1 misses, 0 write-backs
 ok
7 1 ' sq 1 spawn  1 await . 49  ok
' core# 5 run-on . 5  ok
frob
*** frob: undefined word
```

In `sq`, `dup` and `*` were copied inline. In `bump`, the variable's
address (a 16-bit literal) was folded into the load and the store, and
`1+` is one `addi`: the body is three instructions. The numbers in the
disassembly are hex.

## Design

### Threading model and registers

Subroutine threading compiled to native code. A colon definition is a
machine-code routine:

```
addi sp, sp, -8 ; sd ra, 0(sp)        prologue
<one jal per word called, or the word's body copied inline>
ld ra, 0(sp) ; addi sp, sp, 8 ; ret   epilogue (or a jump, see tail calls)
```

| Register | Use |
|---|---|
| `s1` | top of the data stack (cached) |
| `s0` | data stack pointer: points at the second item; grows down |
| `sp` | the return stack (the machine stack) |
| `s2`, `s3` | the innermost `DO` loop's index and limit (`i` is `mv s1, s2`) |
| `s4` | the locals frame |
| `t*`, `a*`, `s5`..`s11` | scratch: any word may clobber them |

A string literal is three instructions (`ori t1, zero, addr`; `addi t2,
zero, len`; a call to a helper that pushes or prints it); the text itself
lives in data space.

The compiler:

- **inlines** primitives whose bodies are at most 4 instructions (`dup`,
  `+`, `@`, `>r`, `i`, ...). A body is read back from far memory with a
  `tget` (code cannot be loaded as data), and copied into the definition;
- **folds** a 16-bit literal followed by `+ - and or xor lshift rshift
  arshift @ ! c@ c!` into one instruction (`v @` becomes `ld s1, v(zero)`);
  `CREATE`d words, `CONSTANT`s and `VALUE`s compile as literals / loads, so
  variables cost one instruction;
- turns a **call just before `;`** into a jump (tail calls; `recurse` in
  tail position is a loop);
- compiles **`DO`/`LOOP`** with the index and limit in registers (the
  outer loop's are saved on the return stack: `j` reads them there).

**Compact code** (`PLAT_COMPACT`, on in the StrataOS build, where code space
is 32 KiB): the prologue is one instruction, `jal t0, k_enter`, a plain
return is `j k_exit` (the two sequences exist once, in the kernel), and the
stub of a `CREATE`d word, `CONSTANT` or `VALUE` is 8 bytes (`ori t1, zero,
addr; j k_var`) instead of 24. That is 12 bytes less per colon definition
for two more jumps per call; `see` shows it.

**The inlining limit** (`inline-limit`, a variable: 16 bytes, 4 instructions,
by default). Under StrataOS the start-up source (core.fs, os.fs) is compiled
with 4 (`PLAT_INLINE`): only one-instruction primitives are copied, `dup`,
`swap`, `+` and the like are called. That saves about 2.5 KiB of the 32;
os.fs sets 16 again for what is typed or included later. Files that must
fit next to others (net.fs, httpd.fs) lower it for themselves:
`inline-limit @ 4 inline-limit ! ... inline-limit !`.

Control structures, `DO` loops, locals and quotations are written in
core.fs with a few code-generation words from the kernel (`insn,` `mark`
`if,` `ahead,` `resolve` `prologue,` `epilogue,`) and a small assembler
(`addi,` `ld,` `sd,` `beq,` ...): `do` is
`%sp %sp -16 addi, %s2 %sp 0 sd, ...`.

### Memory map

**I-LS** (64 KiB, per core)

| Range | Contents |
|---|---|
| `0x0000..0x00FF` | `.text`: the boot stub and the worker loop (all the image loads directly) |
| `0x0100..0x013F` | 8 `xexec` trampolines (one instruction + `ret` each) |
| `0x0140..kend` | the kernel (about 12.9 KiB), installed from far memory at power-on |
| `kend..0xFFFF` | compiled code; core.fs, tools.fs and see.fs take about 19.4 KiB, leaving about 32 KiB |

(Bare metal. Under StrataOS everything is 0x8000 higher: programs own I-LS
`0x8000..0xFFFF`; see "StrataOS" below.)

**D-LS** (64 KiB, per core)

| Range | Contents |
|---|---|
| `0x0000..` | kernel variables, buffers (TIB, output, staging for code: 4 KiB), the far cache (4 KiB lines + tags), messages |
| `0x3118..0x97FF` | the dictionary: headers and data space, growing up (about 17 KiB free after core.fs) |
| `0x8000..` | the kernel word table, read once at start-up and then overwritten by the growing dictionary |
| `0x9800..0x9EFF` | the data stack (224 cells), a guard area above it |
| `0xE000..0xFFFF` | the return stack (`sp` starts at 0x10000) |

Headers: `+0` link, `+2` hash-chain link, `+4` xt, `+6` code size (u16),
`+8` flags (immediate, inline, hidden, create, constant, value), `+9`
folding kind, `+10` name length, `+11` name; the data field follows,
8-aligned. Names hash into 64 buckets (case-blind).

**Far memory** (bare metal, core 0)

| Capability | Range | Use |
|---|---|---|
| `c0` | T3 `[0, 1 MiB)` | the kernel's: `[0, 0x10000)` an identity mirror of the I-LS (far offset = I-LS address; the kernel image itself is its lower part), `0x10000` the embedded source text, `0x20000` the D-LS snapshot for workers |
| `c1` | T2 `[0, 4 KiB)` | the job board, atomics only (copyable) |
| `c7` | | the kernel's scratch register (the image coming back from a worker, a doorbell) |
| `c8` | T3 `[2 MiB, 48 MiB)` | the heap behind `far@`/`far!` (far address = offset in it): `heap-cap` |
| `c9` | T3 `[48 MiB, 64 MiB)` | the framebuffer window |
| `c10` | T3 | what is left of `[1 MiB, 2 MiB)` after each worker got a 64 KiB page |
| `c12` | T2 `[4 KiB, 256 KiB)` | free |
| `c2` `c3` `c4` | | console, device space, core control (from the boot ROM) |

`c11` (`tmp-cap`) and `c13`..`c15` are free for programs. A worker holds its
64 KiB page in `c0` and a copy of the board in `c1`. The board is `c1` and
the scratch register `c7` on every platform because `c0`..`c7` are all a
StrataOS process keeps across a context switch; the StrataOS map is under
"StrataOS" below.

### How code is installed

1. `:` opens a definition at `chere` (the next free I-LS address, 8-aligned).
2. Instructions are assembled into a 4 KiB staging buffer in the D-LS.
   Forward branches are patched there (`resolve`).
3. `;` compiles the epilogue, pads to 8 bytes, records the size, and
   installs: `tput tg13, stage, c0, chere, len` (D-LS → far mirror) then
   `tgetx tg13, chere, c0, chere, len` (far mirror → I-LS). Fetching from a
   range a `tgetx` is still filling stalls, so the word can run at once.
   (Under StrataOS that same mirror is what the dispatcher reloads the I-LS
   from after every context switch.)
4. `CREATE` stubs are staged too and installed before the interpreter next
   runs a word. `DOES>` patches its word's stub (in staging, or through
   `code!`, which reads the doubleword back, patches it and re-installs it).

The kernel installs itself the same way: `.text` is only the boot stub,
which `tgetx`es `[0x140, kend)` from the far image. So everything compiled
is readable in far memory: `see` disassembles it with `code@`, the
compiler inlines from it, and other cores install it from there.

`.jit` shows the code space and the install counts; `true jit-trace`
reports every install.

### `xexec`: instructions built at run time

Strata instructions name capability registers and transfer tags in
immediate fields. So `tget` through "capability register n" is made by
assembling the instruction and running it from a trampoline: `xexec ( a0 a1
a2 insn -- a0' )` installs `insn ; ret` into one of 8 I-LS trampolines
(tput + tgetx of 8 bytes, direct-mapped by a hash of the instruction, so a
loop reusing an instruction pays the install once) and calls it with
`a0..a2` loaded. Every capability and transfer word in core.fs is a
one-liner over `xexec`, e.g.

```forth
: csplit ( cs off cd -- ) rot %a2 1 capop cap1 drop ;
```

### Cores: lending the image, the board, the doorbell

At power-on core 0 gives each worker a 64 KiB private page (its c0, for its
own trampolines) and a copy of the board capability. A worker then waits in
the `.text` loop with `ctake`:

- if it receives a capability with **X** permission, it is the **image**:
  core 0's c0, lent. The worker `tgetx`es `[0x140, chere)` into its I-LS,
  `tget`s the D-LS snapshot into its D-LS, and gives c0 back.
- otherwise it is the **doorbell** (a copy of the board capability): it
  reads its job slot on the board with far atomics (`tamo`), pushes the
  arguments, runs the xt under `catch`, writes back the top 8 cells of its
  stack and the throw code, flushes its output and rings core 0 back.

`spawn` publishes a new image (a `tput` of the D-LS below the data stack)
only when the interpreter ran something since the last one, and lends c0
only to workers holding an older generation. `await` takes c0 back if it
is still out, then the doorbell, and pushes the results; a job's error is
printed by the worker (`core 3: *** ...`) and rethrown by `await`.
(What arrives from a worker lands in the scratch register c7 first. The
StrataOS build lends a *parcel* cut from c0 instead of all of c0: see
below.)

Capabilities a job needs are given *after* `spawn` and taken by the job
with `take`; capabilities a job gives back are taken by core 0 *before*
`await` (each sender's gifts arrive in order).

### The far cache

`far@ far! farc@ farc!` address the heap capability (`heap-cap`: c8 on bare
metal, c6 under StrataOS) through a 2-way,
32-set, 64-byte-line write-back cache in the D-LS, using the hardware's
`ltag` (look up a tag table, get a hit address or a victim) and `linst`
(record a line, advance round robin). A miss writes back a dirty victim
(`tput`) and fetches the line (`tget`); loads from it simply wait for the
transfer. `fflush` writes every dirty line back, `finval` also forgets them,
`.fcache` shows hits, misses and write-backs. Each core has its own cache;
a worker can use `far@` on memory it was given in its c8.

## The dialect

Close to Forth 2012 for the core words. Deviations:

- One cell is 64 bits; there are **no double-cell words** (`um*`, `um/mod`,
  `d+`, `<# #>` on doubles): number formatting (`<# # #s #> hold sign`) works
  on single cells, `*/` has a 64-bit intermediate, `um*hi` gives the high
  half of a product.
- `/` and `mod` are symmetric (truncating), like the hardware.
- Code space and data space are separate (Harvard): `here`, `,`, `allot`
  are data space; `chere` is the code pointer. String literals live in data
  space. `>body` works for `create`d words.
- `[if] [else] [then]` work within one line (or one `evaluate`d string).
- Numbers: `$ff`, `#99`, `%1010`, `'c'`, `-$10`. Names are case-blind.
- `compile,` always compiles a call; the interpreter's compile path
  (and `postpone`) also inline and fold.
- Locals: `{ a b c -- comment }` at the start of a definition (up to 16;
  `to` works on them). Not inside quotations.
- `bye` (or the end of input) halts every core (StrataOS: ends the process).
- `2>r`, `2r>`, `2r@` are compiled as calls (their bodies are longer than
  the 4 instructions that are inlined), never as tail calls.
- A word that is a tool under StrataOS (`see`, `words`, the network words,
  ...) cannot be used inside a definition there unless `require tools` /
  `require see` / `require net` / `require udp` came first.

## Word list highlights

Beyond the core words (`: ; if else then begin until while repeat again do
?do loop +loop leave i j unloop case of endof endcase create does> variable
constant value to defer is s" ." abort" catch throw evaluate`...):

| Words | |
|---|---|
| `see` `disasm ( a u -- )` `dis ( insn -- )` `code@ ( a -- insn )` | the disassembler (see.fs); code is read back from the far mirror |
| `.jit` `jit-trace ( f -- )` `install` `chere` | code space and installs |
| `insn,` `mark` `if,` `ahead,` `resolve` `prologue,` `epilogue,` `slit,` `dotq,` `addi,` `ld,` `sd,` `beq,` ... | code generation, the assembler |
| `xexec ( a0 a1 a2 insn -- a0' )` | run one instruction built at run time |
| `tget tput ( dls off len c# -- )` `tag ( c# -- mask )` `twait tpoll tany ( mask -- )` | transfers (through cN with tag tgN) |
| `csplit ( cs off cd -- )` `cjoin ( cd cs -- )` `cmov cshare catomic ( cs cd -- )` `crestrict ( c# perms -- )` `cclear` | capability operations |
| `cbase clen cperms cvalid ( c# -- x )` `.cap ( c# -- )` `.caps` | inspecting capabilities |
| `give take ( c# core -- )` | move a capability to / from another core |
| `tamo ( addr operand c# fn -- old )` `atomic@ atomic! atomic+!` | far atomics |
| `far@ far! farc@ farc!` `far-read far-write ( dls far u -- )` `fflush finval .fcache fcache-reset far-size` | far memory through the software cache, and in bulk |
| `heap-cap` `tmp-cap` | the heap's capability register (8; 6 under StrataOS) and a spare one (11; 7 under StrataOS) |
| `cores core# workers` `spawn ( x1..xn n xt core -- )` `await ( core -- y1..ym )` `run-on ( xt core -- ... )` `par ( xt -- )` `publish` | cores (StrataOS: the threads of `-n N forth`) |
| `include FILE` `included ( a u -- )` `require NAME` | StrataOS: interpret a file; `require tools` loads tools.fs for good, once |
| `(msg) ( handle len mode op reg -- result )` | StrataOS: one request to a server (register 1 proc / the server a LOOKUP found, 2 fs, 3 tty, 4 pipe); data moves with `5 tput` / `5 tget` at offset 64. Bare metal: "not available on this platform" |
| `tcp-listen ( port -- sock\|err )` `tcp-accept ( lsock -- sock\|err )` `tcp-connect ( ip port -- sock\|err )` | StrataOS, net.fs: TCP through the network server (started if none runs) |
| `sock-read sock-write ( addr u sock -- n )` `sock-close sock-shutdown ( sock -- )` `sock-peer ( sock -- ip port )` | net.fs: a socket is read and written like a file; `sock-write` writes all of it |
| `ip>str ( ip -- addr u )` `.ip ( ip -- )` `str>ip ( addr u -- ip\|-1 )` `net-init` `split ( a u c -- rest u2 first u1 )` | net.fs: IPv4 addresses (a.b.c.d in a cell), finding the server, a string helper |
| `udp-open ( port -- sock\|err )` `udp-send ( addr u ip port sock -- n )` `udp-recv ( addr u sock -- n ip port )` `ping ( ip -- us\|err )` | udp.fs: datagrams and ICMP echo |
| `inline-limit` | a variable: primitives with bodies of up to this many bytes are copied inline (16; 4 for the start-up source under StrataOS) |
| `(mark)` `(release)` | remember the dictionary / forget everything defined since (one level) |
| `ticks ( -- us )` `ms ( n -- )` `cycles` `instret` `timeit ( xt -- )` `csr@ ( csr# -- x )` | time and cost |
| `words` `dump` `.cap` `.caps` `.jit` `.fcache` | tools (tools.fs) |
| `.s` `h.` `.r` `u.r` `xt>name` `find-name` `name>string` `name>xt` `name>size` | more tools, always there |

## Files

| File | |
|---|---|
| `forth.s` | the kernel: interpreter, compiler, catch/throw, multicore, far cache, files and tools on demand, primitives (every line commented) |
| `core.fs` | the rest of the language, in Forth (embedded in the image) |
| `tools.fs`, `see.fs` | `words dump .cap .caps .jit .fcache`, and the disassembler with `see`: embedded on bare metal, disk files loaded on demand under StrataOS |
| `bare/` | the bare-metal platform: `config.s` (constants), `boot.s` (the image's `.text`: boot stub, worker loop), `platform.s` (console, timer, capability set-up, far-cache backing, `bye`), `source.s` and `start.fs` (the embedded source, the banner) |
| `os/` | the StrataOS 0.1 platform: `config.s` (constants, arena layout, data), `boot.s` (the stub, twice: `.text` and its copy in the mirror; the embedded source), `platform.s` (messages to tty/fs/pipe, `(msg)`, files, the clock, threads and the parcel, exit), `os.fs` (`include`, `require`, the banner) |
| `net.fs`, `udp.fs` | StrataOS: TCP, addresses; UDP and ping. Disk files (tagged forth, net), loaded on demand like tools.fs |
| `httpd.fs` | StrataOS: an HTTP/1.0 server for the tag file system (`forth httpd.fs`; tagged forth, net, demo) |
| `demos/tiers.fs` | capabilities, transfers and tags, the far cache, code installation, ownership moving between cores |
| `demos/multicore.fs` | a parallel sum: the heap is cut into slices, given to the workers, summed through each worker's own far cache, and joined back |
| `demos/gfx.fs` | a parallel Mandelbrot: the framebuffer is cut into bands, one per worker, then joined and presented (bare metal only) |
| `tests/test.fs`, `tests/test.out`, `tests/run.sh` | the regression test, bare metal on the emulator and the RTL |
| `tests/run-os.sh`, `tests/ostest.fs`, `tests/os.out`, `tests/inc*.fs`, `tests/preempt.fs` | the same test under StrataOS, files and tools, command lines and pipes, preemption |
| `tests/nettest.fs`, `tests/www/`, `tests/net.out` | under StrataOS: the network words and httpd.fs over loopback (the files of `tests/www/` are tagged www on the test disk) |

The images are built by
`build/sasm -I lang/forth/bare -I build/forth -o build/forth.stx lang/forth/forth.s`
and
`build/sasm -T 0x8000 -I lang/forth/os -I build/forth-os -o build/prog/forth lang/forth/forth.s`;
`corefs.s` in the second include directory is generated from the `.fs`
files (one `.ascii` line per line). The include path picks the platform
layer: `config.s`, `boot.s`, `platform.s`, `source.s`.

## Costs and sizes

| | bare metal | StrataOS 0.1 |
|---|---|---|
| kernel + platform code | 12.9 KiB | 14.7 KiB (the kernel, the platform layer, the stub and trampolines) |
| Forth source compiled at start-up | core.fs, tools.fs, see.fs: 19.4 KiB | core.fs, os.fs: 8.9 KiB (compact code, inline limit 4) |
| code space free after start-up | about 32 KiB of 64 | about 8.4 KiB of 32 (net.fs takes 2.4, httpd.fs 5.3 more) |
| data space free after start-up | about 17.4 KiB | about 16.4 KiB |
| image | 133 KiB | 87 KiB (limit: 128) |
| start-up | about 1.0 M instructions | about 0.8 M, plus messages |

forth.s is 4581 lines of assembly, the platform layers 250 (bare) and 920
(StrataOS) more; core.fs 299 lines, tools.fs 40, see.fs 68, net.fs 98,
udp.fs 22, httpd.fs 188. `make test-forth` takes about 20 s.

## StrataOS

Strata Forth also runs as a StrataOS program: `forth` at the shell (a
REPL on the console), `forth FILE.fs` (run a file, then the REPL),
`forth -n N` (N threads on N cores, for the multicore words), and in
pipes (`seq 5 | forth sum.fs`). `make test-forth` runs tests/test.fs
under the OS and checks files, tools, command lines, pipes, preemption
and the network (tests/ostest.fs, tests/os.out, tests/preempt.fs,
tests/nettest.fs, tests/net.out).

The platform layer is the seam: console I/O, the timer, the far cache's
backing transfers, capability set-up and `bye` are all the kernel asks of
the machine (`plat_*` routines; `lang/forth/bare/` and `lang/forth/os/`).
Under the OS:

- **Time-shared, like any program.** Code the compiler installs beyond
  the image survives a context switch because the program keeps a far
  copy of its I-LS (the *code mirror*, in its arena) and declares it with
  svc SET_MIRROR: the dispatcher reloads the code range from it on every
  switch-in. Each worker thread of `forth -n N` gets a page of its own
  for the same purpose.
- **Console and files through the servers.** `key`/`emit` are tty READ
  and WRITE (cooked mode echoes, so the REPL does not); `include FILE`
  reads source through `fs`, tag paths included (`include /forth/core.fs`).
- **The I-LS budget.** Programs get 0x8000..0xFFFF (32 KiB). The kernel,
  the platform layer and core.fs compiled in compact form (and with the
  inlining limit at 4) leave about 8.4 KiB of code space, so the tools
  (`see`, the disassembler, `dump`, `words`, `.cap`, the network words)
  are not compiled at start-up: `tools.fs`, `see.fs`, `net.fs` and
  `udp.fs` are loaded on demand the first time one of their words is used.
- **No framebuffer.** Only the window server gets the framebuffer
  (GRANT_FB), so `demos/gfx.fs` is a bare-metal demo
  (`make forth-demo-gfx`).

### Networking

The network words talk to the network server (`os/servers/net.s`,
doc/strataos.md 2.10) through one kernel word, the platform's message call
`(msg) ( handle len mode op reg -- result )`: it writes a request header
into the process's message buffer, lends the buffer to the server behind
endpoint register `reg` and sleeps until it is back. The data of a request
or a reply are the buffer's bytes from 64 on, and Forth moves them itself
with `5 tput` and `5 tget`, so everything else is written in Forth:

```forth
: tcp-listen ( port -- sock|err ) 0 0 54 net ;   \ LISTEN: handle = port
: sock-read ( addr u sock -- n ) net-init 1 msg-read ;
```

- **net.fs**: `tcp-listen ( port -- sock|err )`, `tcp-accept ( lsock --
  sock|err )` (waits), `tcp-connect ( ip port -- sock|err )`, `sock-read`
  and `sock-write ( addr u sock -- n )` (a read returns what has arrived,
  at most 1 KiB, 0 once the peer has closed; a write sends all of it),
  `sock-close`, `sock-shutdown ( sock -- )`, `sock-peer ( sock -- ip port )`,
  `ip>str ( ip -- addr u )`, `.ip`, `str>ip ( addr u -- ip|-1 )`. **udp.fs**:
  `udp-open ( port -- sock|err )` (0: any port), `udp-send ( addr u ip port
  sock -- n )`, `udp-recv ( addr u sock -- n ip port )`, `ping ( ip --
  us|err )`. A socket is the server's id for it; results below zero are
  the server's errors (-1 refused or reset, -4 no network server, -6 no
  free socket, -7 port in use, -8 no answer). Addresses are a.b.c.d =
  a<<24 | b<<16 | c<<8 | d in a cell: `$7f000001` is 127.0.0.1.
- **Loading.** At the prompt each word loads its file for one command, like
  `see`; `require net` (or `require udp`) loads it for good, as a program
  must that uses the words in its definitions.
- **The server's endpoint.** The first call looks the server up (LOOKUP
  "net" through `proc`, whose endpoint is c1) and starts one (`net
  10.0.0.1`) if none runs. The endpoint arrives where the heap lives (c6),
  so the heap waits in c7 meanwhile; then it replaces `proc`'s in c1 for
  good (Forth needs `proc` for nothing else). A Forth of several threads
  (`-n N`) keeps the job board in c1 and has no network.
- **Limits.** The server has 4 sockets (TCP and UDP together, a closed
  connection waits 0.5 s in TIME-WAIT); up to 1 KiB moves per message.
  Loopback (127.0.0.1, or the machine's own address) works with no link,
  so a Forth can talk to itself (tests/nettest.fs connects to its own
  listener). Bare metal has none of this: `(msg)` reports "not available
  on this platform" and the words do not exist.

### httpd.fs: a web server

```
strata$ forth httpd.fs &              # port 8000; forth httpd.fs PORT [COUNT]
httpd: serving the tag file system on port 8000
strata$ echo "GET /doc/motd HTTP/1.0" | nc 127.0.0.1 8000
HTTP/1.0 200 OK
Server: Strata Forth httpd
Content-Length: 1402
Content-Type: text/plain

Welcome to StrataOS 0.1 ...
```

An HTTP/1.0 server written in Forth on net.fs (and on `(msg)` to the file
server), one connection at a time, until Ctrl-C or COUNT requests. URL
paths are tag paths: `/doc/motd` is motd, which carries the tag `doc`; a
path of tags is an HTML listing of the files carrying them (`/forth/net`);
a path ending in `/` serves its `index.html`, or else the listing (`/`
lists every file). GET and HEAD; Content-Type by extension (html, txt,
css, js, json, svg, png, jpg, gif, pdf, and the source files as text),
else text or binary by the first bytes; Content-Length; 200, 400, 404 and
405 (with `Allow`). Each request is logged on a line (`127.0.0.1 GET
/doc/motd 200 1402`: client, method, path, status, body bytes). The
listing is generated twice, once to count its bytes for Content-Length and
once to send them, through a deferred `out`. Limits: requests of up to
1 KiB (headers are read and ignored), listings of 126 files, no
%-escapes, no keep-alive. With net.fs it takes about 7.7 of the 8.4 KiB of
code space.
