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
other process. One kernel source, two platform layers. Under StrataOS only
the Forth kernel stays in the I-LS: everything compiled after it goes into
**code units** in far memory that StrataOS pages in as they are called
(the hardware's `xslot`/`xcall`/`xmiss`, the operating system's miss
handler; "Code paging" below). So a program may be much bigger than the
I-LS with no annotations: the editor `vi.fs`, the Forth port of
StrataOS's `vi`, is about 60 KiB of code.

## Running it

```bash
make forth          # REPL on the emulator (bare metal, every core)
make forth-rtl      # the same on the Verilog simulator (slower)
make test-forth     # tests/test.fs on the emulator, the RTL and under StrataOS; files, tools, preemption
make boot           # StrataOS: then type `forth` at the shell (see "StrataOS" below)
make boot           # ... or `guest forth 2 16`: bare-metal Forth as a guest OS (see "As a guest")
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
| `0x0140..kpage` | the kernel (about 13.2 KiB), installed from far memory at power-on |
| `kpage..kend` | the kernel's parts for code paging and start-up (1.8 KiB): compiled code overwrites them |
| `kpage..0xFFFF` | compiled code; core.fs, tools.fs and see.fs take about 19.6 KiB, leaving about 31 KiB |

(Bare metal. Under StrataOS everything is 0x8000 higher: programs own I-LS
`0x8000..0xFFFF`; with one thread, the kernel ends at `kboot` and the rest
is the code cache: see "Code paging" below.)

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

(Under StrataOS with one thread, step 3 is a `tput` to the definition's code
unit and nothing more: see "Code paging".)

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
- Under StrataOS with one thread (code paging): an xt is a code unit's far
  offset (`$20000` and up) or a kernel word's I-LS address; a definition
  must fit in a code unit (2 KiB: "definition longer than a code unit"
  otherwise); `:noname` pushes its xt at `;` (the definition may move to
  the next unit when it is placed), not at once.
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
| `(msg) ( handle len mode op reg -- result )` | StrataOS: one request to a server (register 1 proc, 2 fs, 3 tty, 4 pipe, 6 the network server, looked up through proc each time); data moves with `5 tput` / `5 tget` at offset 64. Bare metal: "not available on this platform" |
| `tcp-listen ( port -- sock\|err )` `tcp-accept ( lsock -- sock\|err )` `tcp-connect ( ip port -- sock\|err )` | StrataOS, net.fs: TCP through the network server (started if none runs) |
| `sock-read sock-write ( addr u sock -- n )` `sock-close sock-shutdown ( sock -- )` | net.fs: a socket is read and written like a file; `sock-write` writes all of it |
| `net-init` `split ( a u c -- rest u2 first u1 )` | net.fs: finding (or starting) the server, a string helper |
| `ip>str ( ip -- addr u )` `.ip ( ip -- )` `str>ip ( addr u -- ip\|-1 )` `sock-peer ( sock -- ip port )` | udp.fs: IPv4 addresses (a.b.c.d in a cell), the other end of a connection |
| `udp-open ( port -- sock\|err )` `udp-send ( addr u ip port sock -- n )` `udp-recv ( addr u sock -- n ip port )` `ping ( ip -- us\|err )` | udp.fs: datagrams and ICMP echo |
| `inline-limit` | a variable: primitives with bodies of up to this many bytes are copied inline (16; 4 for the start-up source under StrataOS) |
| `(mark)` `(release)` | remember the dictionary / forget everything defined since (one level) |
| `main:` `stop` `usage` `+e` `e!` `arg` `atoi` `num` `.u` `in-line` `open` `read` `close` `stat` `write` `tags-of` `scan` `skip` | StrataOS, sys.fs: the library of the ports of os/progs (see "The ports of os/progs" below) |
| `unit-stats ( -- misses slots )` `xtliteral ( xt -- )` `(lit?) ( -- x -1 \| 0 )` | code paging (StrataOS, one thread): the code units the dispatcher has paged in for this Forth and the code cache's slots holding one (bare metal: 0 0); compile an xt as a literal that moves with its definition (`;]` uses it); take back a 16-bit literal just compiled (`of` compares with it in place) |
| `kvar ( n -- addr )` | the kernel's variables, by number: 14 CHERE's, 17 the staging base, 32 the command line, 37 code paging (+0 on, +8 where code space ends, +16 NXMAP, +24 gateway entries), 38 the standard handles (server register and id of handles 0..2: what `(msg)` needs to talk to the tty about standard input), 39 the word INCLUDED runs for a name that is no file, 40 where INCLUDED puts a file's text, 41 the server `(msg)`'s register 6 looks up, ... (core.fs and forth.s's `kvars` list them) |
| `ticks ( -- us )` `ms ( n -- )` `cycles` `instret` `timeit ( xt -- )` `csr@ ( csr# -- x )` | time and cost |
| `words` `dump` `.cap` `.caps` `.jit` `.fcache` | tools (tools.fs) |
| `.s` `h.` `.r` `u.r` `xt>name` `find-name` `name>string` `name>xt` `name>size` | more tools, always there |

## Files

| File | |
|---|---|
| `forth.s` | the kernel: interpreter, compiler, catch/throw, multicore, far cache, files and tools on demand, primitives (every line commented) |
| `core.fs` | the rest of the language, in Forth (embedded in the image) |
| `tools.fs`, `see.fs` | `words dump .cap .caps .jit .fcache`, and the disassembler with `see`: embedded on bare metal, disk files loaded on demand under StrataOS |
| `bare/` | the bare-metal platform: `config.s` (constants), `boot.s` (the image's `.text`: boot stub, worker loop), `platform.s` (console, timer, far-cache backing, `bye`), `init.s` (capability set-up, the workers), `source.s` and `start.fs` (the embedded source, the banner) |
| `guest/` | the bare-metal Forth as a StrataOS guest (over `bare/`, whose `source.s` it uses): `config.s` (constants, the console buffers), `boot.s` (the stub: the granted capabilities moved to the bare-metal places; workers also take a message buffer), `platform.s` (the console as tty READ / WRITE / CLOSE through the endpoint, the clock, `ms` by watching NOW, `bye`), `init.s` (the arena cut up, the workers), `start.fs` (the banner); see "As a guest" |
| `os/` | the StrataOS 0.1 platform: `config.s` (constants, arena layout, the unit store, data), `boot.s` (the stub, twice: `.text` and its copy in the mirror; the embedded source), `platform.s` (messages to tty/fs/pipe, `(msg)`, files, the clock, threads and the parcel, a code unit's miss, exit), `init.s` (handles, the command line, the heap, the threads), `os.fs` (`include`, `require`, the banner) |
| `net.fs`, `udp.fs` | StrataOS: TCP; UDP, ping, addresses. Disk files (tagged forth, net), loaded on demand like tools.fs |
| `vi.fs`, `vi-text.fs`, `vi-edit.fs` | StrataOS: the editor (`forth vi.fs FILE`, or `include vi.fs` then `vi FILE`), the Forth port of `os/progs/vi.s`; its keyword tables are `vi-syntax.fs`, generated by `tools/vi-syntax.py` (into build/forth-os/). Disk files tagged forth |
| `progs/*.fs`, `sys.fs`, `progs.fs` | StrataOS: the ports of os/progs (`forth seq.fs 20`), their library, and the head of the one disk file they are packed into (`progs.pk`, made by `tools/forth-pack.py`); see "The ports of os/progs" |
| `httpd.fs`, `httpd-ps.fs` | StrataOS: an HTTP/1.0 server for the tag file system (`forth httpd.fs`; tagged forth, net, demo), and its `/~ps` page, loaded for each request of it |
| `demos/tiers.fs` | capabilities, transfers and tags, the far cache, code installation, ownership moving between cores |
| `demos/multicore.fs` | a parallel sum: the heap is cut into slices, given to the workers, summed through each worker's own far cache, and joined back |
| `demos/gfx.fs` | a parallel Mandelbrot: the framebuffer is cut into bands, one per worker, then joined and presented (bare metal only) |
| `tests/test.fs`, `tests/test.out`, `tests/run.sh` | the regression test, bare metal on the emulator and the RTL |
| `tests/run-os.sh`, `tests/ostest.fs`, `tests/os.out`, `tests/inc*.fs`, `tests/preempt.fs`, `tests/paging.fs` | the same test under StrataOS, files and tools, command lines and pipes, preemption, and a program twice the code cache run while another program shares its core |
| `tests/nettest.fs`, `tests/http/`, `tests/net.out` | under StrataOS: the network words and httpd.fs over loopback (the files of `tests/http/` are tagged httptest on the test disk) |

The images are built by
`build/sasm -I lang/forth/bare -I build/forth -o build/forth.stx lang/forth/forth.s`,
`build/sasm -T 0x8000 -I lang/forth/os -I build/forth-os -o build/prog/forth lang/forth/forth.s`
and (the guest)
`build/sasm -I lang/forth/guest -I lang/forth/bare -I build/forth-guest -o build/guest/forth.g lang/forth/forth.s`;
`corefs.s` in the last include directory is generated from the `.fs`
files (one `.ascii` line per line). The include path picks the platform
layer: `config.s`, `boot.s`, `platform.s`, `init.s`, `source.s` (the first
directory that has the file).

## Costs and sizes

| | bare metal | StrataOS 0.1, one thread (code paging) | StrataOS 0.1, `forth -n N` |
|---|---|---|---|
| kernel + platform code | 13.4 KiB (15.2 with the parts for paging and start-up, which compiled code overwrites) | 16.3 KiB resident (the kernel, the platform layer, the stub and trampolines: the code mirror), and 0.9 KiB of start-up code the code cache overwrites | 15.0 KiB resident, and 2.3 KiB (paging, start-up) that compiled code overwrites |
| Forth source compiled at start-up | core.fs, tools.fs, see.fs: 19.4 KiB | core.fs, os.fs: 9.8 KiB, in code units (inline limit 4) | core.fs, os.fs: 8.9 KiB (compact code, inline limit 4) |
| code space after start-up | 31.1 KiB of 64 free | 92 KiB of the 104 KiB unit store free, paged through a 14 KiB code cache (7 slots of 2 KiB) | 8.0 KiB of 32 free |
| data space free after start-up | 16.5 KiB | 16.1 KiB | 16.1 KiB |
| image | 131 KiB | 89 KiB (limit: 128) | the same |
| start-up | about 1.0 M instructions | 1.58 M for `forth -e 1 drop`, all of it (was 1.53 M before code paging): 51 code units paged in | 1.79 M with 2 threads (1.77 M) |

forth.s is 5330 lines of assembly, the platform layers 280 (bare) and 1000
(StrataOS) more; core.fs 299 lines, tools.fs 40, see.fs 88, net.fs 98,
udp.fs 46, httpd.fs 195, httpd-ps.fs 60, vi.fs with its two parts 920,
sys.fs 106, progs.fs 41 and the 22 ports 435. `make test-forth` takes about 25 s; `tools/test-vifs.sh` (the
editor, in `make test`) a few seconds, `tools/test-fs-progs.sh` (the ports) about 12.

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

- **Time-shared, like any program.** The kernel, installed beyond the
  image's code, survives a context switch because the program keeps a far
  copy of its I-LS (the *code mirror*, in its arena) and declares it with
  svc SET_MIRROR: the dispatcher reloads the code range from it on every
  switch-in. With one thread the mirror is the kernel only, and the code
  units in the cache after it are put back by the dispatcher ("Code
  paging"); with threads (`forth -n N`) every word is in the mirror, and
  each worker thread gets a page of its own for the same purpose.
- **Console and files through the servers.** `key`/`emit` are tty READ
  and WRITE (cooked mode echoes, so the REPL does not); `include FILE`
  reads source through `fs`, tag paths included (`include /forth/core.fs`).
- **The I-LS budget.** Programs get 0x8000..0xFFFF (32 KiB). With one
  thread the kernel takes 16.3 KiB of it and the rest is the code cache;
  code space proper is the unit store in far memory, 104 KiB. With threads
  the kernel, the platform layer and core.fs compiled in compact form (and
  with the inlining limit at 4) leave about 8.2 KiB of code space. Either
  way the tools (`see`, the disassembler, `dump`, `words`, `.cap`, the
  network words) are not compiled at start-up, which they would make
  longer: `tools.fs`, `see.fs`, `net.fs` and `udp.fs` are loaded on demand
  the first time one of their words is used.
- **No framebuffer.** Only the window server gets the framebuffer
  (GRANT_FB), so `demos/gfx.fs` is a bare-metal demo
  (`make forth-demo-gfx`).

### As a guest

The bare-metal image also runs as a StrataOS **guest** (doc/strataos.md,
"Guests"): a second OS on whole cores of its own, in supervisor mode,
beside StrataOS. `guest forth 2 16` at the StrataOS shell boots
`forth.g` (the disk file; tagged guest and forth) on 2 cores with a 16 MiB
arena, and gives it the console:

```
strata$ guest forth 2 16
guest started: id 240, core 6
guest 240 has the console: Ctrl-] gives it back to StrataOS
Strata Forth 0.1 (native code, 2 cores, a StrataOS guest, 13 MiB far heap) 31456 code bytes free, 16272 data bytes free
2 3 + .
5  ok
: sq ( n -- n*n ) dup * ;  7 1 ' sq 1 spawn  1 await .
49  ok
^]
guest 240 detached: `guest attach 240` returns to it, `guest stop 240` ends it
strata$ guest stop 240
guest stopped
```

What a guest is given, and where the platform layer (`lang/forth/guest/`)
puts it:

- **Its cores.** Every guest core starts at I-LS 0 as on bare metal, with
  `coreid` and `ncores` relative to the guest's own cores, so `cores` is
  the number asked for and the multicore words (`spawn`, `await`, `give`,
  `take`, demos/multicore.fs) run on them unchanged: workers wait for core
  0, which lends them the image and rings the board. The stub moves the
  granted capabilities into the bare-metal registers first: the console
  endpoint to c2, the clock to c3, core control (its own cores) to c4.
- **Its memory: the arena** (c0 of core 0; the image is already copied in
  at the bare-metal offsets). plat_init cuts it like bare metal's 64 MiB:
  [0, 1 MiB) the kernel's (mirror, source, snapshot); from 1 MiB a 4 KiB
  message buffer for core 0, the 4 KiB job board (made atomic: there is no
  cluster store) and per worker a 64 KiB page and its own message buffer;
  from 2 MiB to the end the far heap. At least 4 MiB, at most 15 cores.
- **The console: messages to StrataOS's tty**, as a StrataOS program's,
  but sent by hand (a supervisor has no `svc`): the header and data into
  the 4 KiB buffer, `csend c5, c2`, and the answer with `crecv c5, c2`, so
  only the tty's node is taken from (a worker's doorbell in core 0's inbox
  is not mistaken for it). StrataOS takes one 4 KiB request at a time from
  each guest core, so each core has its own buffer and waits for its
  answer. Input is READ in the tty's cooked mode: the tty echoes and edits
  the line (so the REPL does not echo: PLAT_ECHO 0). **Keystrokes reach the
  guest while the console is attached to it**: `guest` attaches it and
  waits (the shell waits for `guest`), so typed lines answer the guest's
  READs; Ctrl-] (or Ctrl-C, which also ends the `guest` command) gives the
  console back to the shell, the guest's READ then waits in the tty until
  `guest attach 240`, and nothing typed for one side reaches the other. The
  guest's output reaches the console either way.
- **The clock** (NOW, FREQ; read-only): `ticks`, `timeit`, and `ms`, which
  watches NOW (there is no timer deadline for a guest: DEADLINE / WAIT are
  StrataOS's), on a core that is the guest's own.
- **`bye`** CLOSEs the console (it comes back to the shell) and halts;
  `guest stop 240` resets the cores and returns them to StrataOS.
- **Not there**: the framebuffer and the device space (`demos/gfx.fs`
  cannot run: its first line reads the platform table through c3, which
  here is the 16-byte clock window, and faults; c9 is empty), the cluster
  store, files (`include` fails: no endpoint to fs) and the network
  (`(msg)`). tools.fs and see.fs are embedded, as on bare metal.
  demos/tiers.fs and demos/multicore.fs run unchanged; type or paste them
  (there are no files).

`tools/test-guest.sh` (in `make test`) runs such a session: arithmetic, a
word on the worker core, demos/multicore.fs, Ctrl-], `cores` at the shell,
`guest attach`, `bye`, `guest stop`, and programs on the returned cores.

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
: sock-read ( addr u sock -- n ) net-init 6 msg-read ;
```

- **net.fs**: `tcp-listen ( port -- sock|err )`, `tcp-accept ( lsock --
  sock|err )` (waits), `tcp-connect ( ip port -- sock|err )`, `sock-read`
  and `sock-write ( addr u sock -- n )` (a read returns what has arrived,
  at most 1 KiB, 0 once the peer has closed; a write sends all of it),
  `sock-close`, `sock-shutdown ( sock -- )`. **udp.fs**: `sock-peer ( sock
  -- ip port )`, `ip>str ( ip -- addr u )`, `.ip`, `str>ip ( addr u --
  ip|-1 )`, `udp-open ( port -- sock|err )` (0: any port), `udp-send ( addr
  u ip port sock -- n )`, `udp-recv ( addr u sock -- n ip port )`, `ping (
  ip -- us|err )` (apart from net.fs, so that a TCP program such as
  httpd.fs has more code space). A socket is the server's id for it; results below zero are
  the server's errors (-1 refused or reset, -4 no network server, -6 no
  free socket, -7 port in use, -8 no answer). Addresses are a.b.c.d =
  a<<24 | b<<16 | c<<8 | d in a cell: `$7f000001` is 127.0.0.1.
- **Loading.** At the prompt each word loads its file for one command, like
  `see`; `require net` (or `require udp`) loads it for good, as a program
  must that uses the words in its definitions.
- **The server's endpoint.** A process keeps c0..c7 and nothing else, and
  Forth uses all of them, so the network server's endpoint has no register:
  `(msg)` with register 6 asks `proc` (c1) for it, LOOKUP "net", before
  every request, sends the request through it and drops it after. The
  endpoint arrives where the heap lives (c6), so the heap waits in c7
  meanwhile; LOOKUP's name covers 8 bytes of the request's data, which are
  saved and put back. That is a `proc` round trip per network request (a
  1 KiB `sock-write` chunk, an ACCEPT, ...), and in exchange `proc` stays
  reachable (httpd.fs's `/~ps` asks it for INFO, CORES and PS). The first
  call starts a network server (`net`) if none runs. A Forth of several
  threads (`-n N`) keeps the job board in c1 and has no network.
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
server), one connection at a time, until Ctrl-C or COUNT requests (its
port is 8000 so that it can run next to the assembly `httpd` on 80,
doc/strataos.md 2.11). URL
paths are tag paths: `/doc/motd` is motd, which carries the tag `doc`; a
path of tags is an HTML listing of the files carrying them (`/forth/net`);
a path ending in `/` serves its `index.html`, or else the listing; `/` is
its own home page, `/www/forth.html`, and `/~/` the listing of every file;
`/~ps` is what the machine is doing (uptime, cores, processes, context
switches and the KiB they moved, from `proc`'s INFO, CORES and PS, as on
the assembly httpd). GET and HEAD; Content-Type by extension (html, txt,
css, js, json, svg, png, jpg, gif, pdf, and the source files as text),
else text or binary by the first bytes; Content-Length; 200, 400, 404 and
405 (with `Allow`). Each request is logged on a line (`GET /doc/motd
200 1402`: method, path, status, body bytes). A listing is generated twice,
once to count its bytes for Content-Length and once to send them, through a
deferred `out`. Limits: requests of up to 1 KiB (headers are read and
ignored), listings of 126 files, no %-escapes, no keep-alive.

With net.fs it is about 8 KiB of code (in code units). The `/~ps` page is a
file of its own, `httpd-ps.fs`, which httpd.fs loads for each request of
`/~ps` and forgets after it with `(tool)`, the word the interpreter loads
`see.fs` with: it was written so when httpd.fs had to fit in the 8 KiB of
code space a StrataOS program had left, and it keeps the data space it
takes for a request only while the request lasts. Most of that file is not
even compiled: below a few definitions its lines are interpreted as it is
read, and they make the page into a buffer in data space and send it.

### Code paging

With one thread, a StrataOS Forth keeps only its kernel in the I-LS. Every
word compiled after it, core.fs and os.fs at start-up and everything after
them, goes into **code units**: 2 KiB, slot-aligned pieces of a store in far
memory (c0 `[0x20000, 0x3A000)`, 104 KiB, the arena's parcel, which only
threads need), each holding whole definitions. StrataOS pages them, with
the hardware's slot mapping and its own miss handler (doc/strataos.md 2.2,
"Code units"; the manual's code-paging section):

- Forth sets `xslot` to 11. A call of a unit that is not in the I-LS misses
  (`xmiss`); the dispatcher copies the unit into a slot of the **code
  cache**, the I-LS after the kernel (7 slots of 2 KiB, 0xC800..0xFFFF),
  maps it with `xmap` and retries the call. Forth has its own trap handler
  (faults become THROWs), so a miss reaches that first: `plat_miss` hands it
  over with svc PAGE and returns into the call.
- The code mirror (svc SET_MIRROR) covers the kernel only, 16.3 KiB: the
  code cache starts after it, and the dispatcher puts the cache back as it
  was after every context switch (each slot's unit, recorded when it paged
  it in), since a unit may be interrupted, or be waited on by a plain return
  address, while another program runs on the core.

A unit's code runs in whatever slot it got, so the compiler makes it
independent of where that is:

| | in a code unit | resident (bare metal, threads) |
|---|---|---|
| prologue / return | `jalr t0, gp, k_enter` / `jalr zero, gp, k_exit` (`gp` = 0x10000) | `jal t0, k_enter` / `j k_exit` |
| a call of a kernel word | `jalr ra, gp, a - 0x10000` (a plain link: the kernel never pages) | `jal ra, a` |
| a call of a kernel word that may run paged code (F_PAGER: `execute catch evaluate evaluate-far interpret included (tool)`) | an xcall of its entry in the **gateway** (unit 0: `jalr zero, gp, a - 0x10000` per word), so that its link is a far link; it returns with `xret ra` | `jal ra, a` |
| a call of a word in a unit (also in the same unit) | `addi t5, tp, a - TPV; xcall ra, c0, t5` (`tp` = TPV, the store's start + 32 KiB; `lui`, `ori` further away). The link is a far link: the return finds the caller's unit wherever it is now, paging it back in if it was evicted | `jal ra, a` |
| a tail call | of a unit: `xcall zero, c0, t5` after the epilogue; of a kernel word: none (a primitive returns with `ret`, which cannot follow a far link) | `jal zero, a` |
| a variable's stub | `ori t1, zero, a; jalr zero, gp, k_var` and room for DOES> (16 bytes) | `ori t1, zero, a; j k_var` |

An xt is the code's address: a kernel word's I-LS address, or a unit's far
offset (0x20000 and up; the header holds it as (xt - 0x20000) / 8, below
0x8000, so a header has room for it). `execute` jumps into a unit with an
xcall; called with a far link (from a unit, through the gateway), it runs a
kernel word as a call, since a primitive returns with `ret`. `k_exit`,
`k_var`, `k_val`, `catch`, `throw`, `evaluate` and the other gateway words
return with `xret ra`, which follows a far link and is a `jr` for a plain
one.

A definition is staged as before and placed at `;`: where the last one
ended, or, if it does not fit in that unit's rest, at the start of the next
(its few absolute references to itself, RECURSE, a quotation's xt and the
DOES> code's address, are lui/ori pairs recorded as it is compiled, and
move with it). So it must fit in a unit: "definition longer than a code
unit" otherwise (vi.fs splits its longest words; a `case` arm whose
value is a literal is four instructions now, for that too). Installing it is
a `tput` to the unit and a `twait`; since the unit may be in the cache, the
overlay map is then cleared (`xunmap`, NXMAP entries: SET_MIRROR returns
NXMAP), and what is needed comes back on demand.

The kernel's part (forth.s, "Code paging"): `cg_target` compiles every call
as the table says; `end_def` places a definition; `p_paging` (at start-up,
before core.fs) builds the gateway and turns paging on; `hxt` decodes a
header's xt. The code only paging runs sits at the end of the kernel
(kpage..kboot), and the start-up code after it (kboot..kend): with threads
and on bare metal compiled code starts at kpage and overwrites both (the
code space there is what it was before paging), and with paging the code
cache overwrites the start-up part.

`unit-stats ( -- misses slots )` shows the units the dispatcher has paged in
for this Forth (svc UNITS). A miss costs about 240 instructions (the trap,
Forth's handler, svc PAGE, the dispatcher's `page_in`, the return), and a
2 KiB `tgetx` of bus time on the hardware.

**Why 2 KiB.** With 1 KiB units the cache has 15 slots and vi.fs misses less
when it opens a file (71 misses for `/src/sh.s`, against 1,640), more for a
key (20 against 14): both cost the same within a percent or two (a key 56 K
instructions against 54 K, opening `/src/sh.s` 22.9 M against 23.2 M). But
a definition must then fit in 1 KiB, which ordinary code does not (cp.fs's
and ls.fs's main words, vi.fs's dispatchers), so units are 2 KiB.

**With threads** (`forth -n N`) nothing is paged: a worker installs the code
from the parcel, where the store would be, and has its own I-LS and overlay
map, which thread 0's units do not reach. Every word is resident, as before
(8.2 KiB of code space after start-up).

**Before and after** (the same build otherwise; instructions of the whole
machine, `tools/fs-progs-speed.sh` for the ports):

| | with code overlays (overlay.fs) | with code paging |
|---|---|---|
| code space after start-up | 8.0 KiB of I-LS | 92 KiB of units (104), through a 14 KiB cache |
| start-up, `forth -e 1 drop` | 1.53 M | 1.58 M (51 misses) |
| vi.fs: starting (`forth vi.fs`, `:q`) | 7.76 M | 7.36 M |
| vi.fs: opening `/src/sh.s` (333 KiB) | 21.6 M | 23.2 M (1,640 misses with drawing and `:q`) |
| vi.fs: opening `seq 15000` (77 KiB) | 17.6 M | 20.3 M |
| vi.fs: a key in normal mode (`j`, `k`) | 55 K | 54 K (14 misses) |
| vi.fs: code / data space left | 0 of I-LS (19 overlays of 4.1 KiB) / 1.2 KiB | 31 KiB of units / 2.0 KiB |
| the ports: a run | | 3 to 4 % more (about 110 K: start-up, sys.fs's units) |
| `forth units.fs` | 3.72 M | 3.50 M (257 misses) |

A call of a unit is one instruction more than a resident call (the `addi`),
which is most of the difference in loops that call short words (opening
`seq 15000`); vi.fs no longer pays the overlay manager (some 400
instructions a call into another overlay), and the cache holds more of it.

**What Forth uses StrataOS for now, and what it keeps.** Paging its code is
the operating system's (the kernel's miss handler, its cache bookkeeping
across switches) instead of overlay.fs's, which is gone with its kernel
support (F_OVL, the overlay xt, `ovcall`/`ovjump`, KVAR 37's overlay block).
Kept, and why:

- the code mirror, for the kernel: Forth installs its kernel from the
  image's far section (the image's code is only the 256-byte stub) and
  `xexec` installs its trampolines at run time, and both must survive a
  switch; it is half what it was (16 KiB reloaded per switch-in, then the
  cache's units);
- its own trap handler (faults become THROWs at the prompt), so misses are
  handed over with svc PAGE rather than taken by the dispatcher directly;
- the pack, progs.pk: the file system's directory has room for 128 files
  and the disk has 110 without the ports, so they cannot be files of their
  own, with tags;
- its buffering: output is collected in the D-LS and sent a message at a
  time, input read a message at a time; it uses the servers' protocol
  directly, not os/lib/sys.s, whose 4 KiB of code and 13 KiB of data would
  not fit beside it;
- the tools loaded on demand (`see`, `words`, the network words): code
  space is no longer the reason, start-up time is (every port starts a
  Forth);
- its far cache (`far@`): StrataOS has none.

### vi.fs: an editor

```
strata$ forth vi.fs /src/hello.s        # in another tag path: forth /vi.fs FILE
strata$ forth
include vi.fs
vi notes.fs                             # as often as wanted; :q comes back to the prompt
```

The Forth port of StrataOS's editor (`os/progs/vi.s`, doc/strataos.md 2.12):
the same modes, motions, operators with counts, undo and redo, `.`, search,
`:` commands, status line, screen-size question and highlighting of Strata
assembly and Forth, with the same keys. Given the same keys it writes the
same files: `tools/test-vifs.sh` runs the assembly vi's test session with
`forth vi.fs` and compares the files with both editors' expected output, then
checks the colours of an `.s` and an `.fs` file, a Ctrl-C, and `vi` at the
Forth prompt (in `make test`; `tools/vi-shots.sh -f` takes its pictures in a
window).

It is 920 lines in three files (`vi.fs` includes `vi-text.fs` and
`vi-edit.fs`: an included file's text must fit in 64 KiB with what it
includes) and about 60 KiB of code, which is in code units like any other
("Code paging": it needs no annotations; it was nineteen code overlays of
overlay.fs before, and its longest words are split to fit units). The byte loops (lines, keywords, identifiers, strings, numbers) are
code words assembled with core.fs's assembler; the keyword tables are
generated at build time (`tools/vi-syntax.py` writes `vi-syntax.fs`, read
once into far memory) from the same sources as vi.s's; the message texts
are kept in far memory too (`m" text"`), since data space, 16 KiB with every
word's name in it, is the other limit. vi.fs talks to the tty itself through
`(msg)` and KVAR 38 (raw mode, READs that do not wait, for the Esc timing)
and catches interrupts, so Ctrl-C is a key, as for vi.s.

What differs from vi.s, and why: the text can be 400 KiB (vi.s: 500), the
undo history 96 KiB (224) and the register 48 KiB (96), because Forth's
heap is what its 1 MiB arena leaves after the code mirror, include buffers
and the code units; `.` repeats a change of up to 64 keys (256), for data
space; a Ctrl-C during the 30 ms after an Esc is not seen (`ms` does not say
it was cut short). Every start compiles the editor: about 6 M instructions
(7.4 M for `forth vi.fs` and `:q`, all of it). Opening the 333 KiB shell
source costs about 23 M instructions (vi.s: 18 M), `seq 15000`'s 77 KiB file
20 M (7 M), a key in normal mode about 54 K (45 K, most of it the tty's
messages, the same for both).

### The ports of os/progs

```
strata$ forth seq.fs 100 | forth grep.fs 7 | forth wc.fs
19 19 56
strata$ forth
include cat.fs
cat motd                                # at the prompt: the port's word, on the rest of the line
```

StrataOS's programs written in Strata Forth, one file each in `progs/`, run
as `forth NAME.fs ARGS` with the same arguments, the same output, the same
errors on standard error and the same exit codes as the assembly program,
in pipes and with redirections; Ctrl-C kills them as it kills the assembly
programs (they do not catch it). At the Forth prompt `include NAME.fs`
defines the word NAME, which runs the program on the rest of its line.

| Port | | Port | |
|---|---|---|---|
| `seq.fs` | the numbers 1 to N | `cp.fs` | copy a file (`-t`: its tags too) |
| `cat.fs` | files or standard input | `mv.fs` | rename (fs RENAME) |
| `upper.fs` | in capital letters | `rm.fs`, `touch.fs` | delete, create empty |
| `wc.fs` | lines, words, bytes | `tag.fs` (also `untag.fs`, `retag.fs`) | a file's tags |
| `grep.fs` | lines containing a text | `tags.fs` | every tag, or a file's |
| `hexdump.fs` | a raw disk block | `ls.fs` | a tag path's files, `-t`, facets |
| `df.fs`, `free.fs` | disk, memory | `ps.fs`, `cores.fs` | processes, cores |
| `uptime.fs`, `sched.fs` | time, the slice | `devs.fs` | the platform table |
| `spin.fs` | burn CPU, a dot now and then | `units.fs` | 24 functions of 1 KiB, a code unit each |

Not ported: the network programs (ping, host, ifconfig, netstat, nc,
tcpecho, httpd: `httpd.fs` is Forth's own web server), the window server and
its clients (ws, term, wclock, wmandel), sh and as. `units.fs` is now what
units.s is: 24 functions of a little over 1 KiB, each in a code unit of its
own, three times Forth's code cache, in chains seven deep; it prints the
units the dispatcher paged in (257) where it printed the overlays it brought
in.

**sys.fs** is their library (os/lib/sys.s's counterpart, about 2.9 KiB of
code and 9.2 KiB of data space, the buffers of a message and of standard
input): `main:` (`' NAME-main main: NAME` ends a port: from the command line
it runs at once on the arguments and ends the process with STATUS), `stop
( code -- )`, `usage`, `+e` `e!` (a message on standard error), `arg ( a u --
rest u' word u2 )`, `atoi`, `num`, `.u`, `last/`, `zlen`, `in-line ( buf max
-- u|-1 )` (standard input by lines, as sys.s's in_line reads them), `open`
`read` `close` `stat` `fs-path` `fs-2path` `tags-of` (the file server),
`proc`, `write ( a u reg id -- )`, and the code words `scan`, `skip`,
`digits`. Under StrataOS it is compiled after the platform has read the
standard handles, so their servers and ids are compiled in as literals.

**The pack.** The disk's directory has room for 128 files (and a DIR answer
for 126), and the standard disk already has 110 (the test disks more), so
the ports and sys.fs are not files of their own: the Makefile packs them
into one, `progs.pk` (`tools/forth-pack.py`): `progs.fs`, Forth, with an
index put in (a line `OFFSET LENGTH port NAME` per file; `untag.fs` and
`retag.fs` are more names for `tag.fs`), then the files. INCLUDED, given a
name that is no file, runs the word in KVAR 39 instead (once): os.fs's
`(pack)` includes `/progs.pk` with the name on the stack. INCLUDED reads the
whole pack into far memory and interprets its head: the index lines note
where the port and sys.fs are, the loader forgets its words (`(mark)`,
`(release)`), names the text after the port (errors say `seq.fs:12:`),
interprets sys.fs where it lies unless it is loaded (`evaluate-far`), then
the port, and ends the pack's text (KVAR 7's neighbours: where the far text's
next line is and where it ends). `include`, `require sys` and an INCLUDE in
a port all find them. A name in neither is "no such file", as before. So
the ports take one directory entry; the http test's disk is full with it
(128 files while that test runs). The kernel's part is 8 instructions;
`(pack)` is one short word. KVAR 41 is the name `(msg)`'s register 6 looks up (`net`; `devs.fs`
asks for `dev`).

**Tests.** `tools/test-fs-progs.sh` (in `make test`) runs 46 cases, each as
the assembly program and as its port in one session (pipes, redirections,
missing files, usage errors, a sequence of touch, cp, mv, tag, ls and rm
run twice): 36 must give the same bytes on the console (output, error
messages, the shell's report of the exit status); the 10 status reports
(uptime, free, cores, ps, sched, units), whose wording may differ, are
compared with `tools/test-fs-progs.out`, numbers masked. Then Ctrl-C ends
`forth spin.fs`, and ports run at the Forth prompt.

**Speed** (`tools/fs-progs-speed.sh`: the whole machine's instructions for
one command, less those of `true`; thousands; the .s column of the same
run as the paged one). Every start costs about 2.5 M: Forth itself (1.6 M),
reading the 24 KiB pack (a KiB per message), compiling sys.fs and the port.
Past that, the byte loops are code words and the messages are the same, so
long inputs come close to the assembly programs. With code paging a run
costs 3 to 4 % more than it did with every word resident (about 110 K: a
start, sys.fs and the port compiled into units, a call of a unit one
instruction longer); `units` costs less, without overlay.fs.

| command | .s | .fs, code overlays | .fs, code paging | ratio (paging) |
|---|---:|---:|---:|---:|
| `seq 1000` | 662 | 3739 | 3864 | 5.8 |
| `cat /src/as.s` (180 KiB) | 10393 | 19387 | 19861 | 1.9 |
| `upper < /src/hello.s` | 1992 | 4932 | 5074 | 2.5 |
| `wc < /src/sh.s` (333 KiB) | 17504 | 26934 | 27113 | 1.5 |
| `grep ecall < /src/sh.s` | 18698 | 20863 | 21054 | 1.1 |
| `hexdump 0` | 599 | 3251 | 3365 | 5.6 |
| `ls` | 500 | 3307 | 3418 | 6.8 |
| `ls -t /src` | 1333 | 4011 | 4150 | 3.1 |
| `tags` | 347 | 2875 | 2983 | 8.6 |
| `cp /src/units.s u2` (50 KiB) | 2775 | 4945 | 5072 | 1.8 |
| `df` | 236 | 2744 | 2850 | 12.0 |
| `devs` | 380 | 2959 | 3069 | 8.1 |
| `ps` | 312 | 2863 | 2971 | 9.5 |
| `cores` | 446 | 3008 | 3113 | 7.0 |
| `uptime` | 457 | 2975 | 3085 | 6.7 |
| `free` | 373 | 2882 | 2989 | 8.0 |
| `sched` | 424 | 2951 | 3055 | 7.2 |
| `spin 3` | 1636 | 4135 | 4244 | 2.6 |
| `units` | 363 | 3724 | 3502 | 9.6 |
