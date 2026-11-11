# The Strata debug protocol, version 1

The debug engine of the reference emulator (`emu/debug.c`) runs a Strata
machine under control: it stops it, steps it, sets breakpoints and
watchpoints, shows what the machine holds (registers, capabilities, the
save table, inboxes, the overlay map, the transfer tags, pending device
reads), keeps an event log and the history of every capability, and, on a
deterministic run, travels back in time. Front-ends talk to it in this
protocol: `strata-dbg` (the text debugger, `dbg/`), the web debugger
(`site/debug/`), and anything else that can write a line of JSON.

The ISA does not change for any of this: breakpoints and watchpoints live
in the emulator, and a machine run without `--debug` runs exactly as it
always has.

## Transports

The engine starts stopped, in front of the first instruction.

| Where | How |
|---|---|
| `strata-emu --debug stdio ...` | requests on stdin, answers and events on stdout, one JSON object per line. The emulator's own stdout is moved to stderr, so nothing else reaches the protocol. `strata-dbg` starts the emulator this way. The engine ends when stdin closes. |
| `strata-emu --debug PORT ...` (or `HOST:PORT`, `tcp:HOST:PORT`) | a TCP port, on 127.0.0.1 unless a host is given. A connection that starts with an HTTP request is either a WebSocket upgrade (one text message per JSON line, both ways) or a GET of a file under `--www DIR` (default `site/`; `/` redirects to `/debug/`, and `GET /dbg-info` answers `{"engine":true,"version":1}`, which is how the web debugger knows it was served by an engine). Anything else is raw JSON lines. Up to 8 clients at once; every client gets every event. |
| `strata-emu --debug unix:PATH ...` | raw JSON lines on a Unix-domain socket |
| the browser | the play page's WebAssembly build exports `web_dbg(line)` (one request, returns the answer), `web_dbg_run(ms)` (runs the machine while it is running: 0 = call again, > 0 = idle, wait that many milliseconds or until input, < 0 = not running) and `web_dbg_events()` (the events since the last call, as lines). `site/debug/dbg-worker.js` and `tools/wasm-dbg.js` drive them. |

Companion flags of `strata-emu`:

| Flag | Meaning |
|---|---|
| `--map FILE` | load a symbol map (`sasm -g`). `IMAGE.map`, next to `IMAGE.stx`, is loaded by itself. |
| `--os DIR` | StrataOS awareness: `DIR/kernel.map` for the kernel and its code units, `DIR/prog/NAME.map` for the program a core runs in user mode (loaded when first needed); the kernel's tables and `proc`'s process table read through them. `make` writes these maps into `build/`, so `--os build`. |
| `--www DIR` | the files a TCP debug port serves to a browser |
| `--history N` | time travel's memory budget in MiB (512; 128 in the browser) |

With `-i FILE` console input comes from the file as without `--debug`;
otherwise it comes only from `input` requests, and the guest's console
output comes only as `console` events: the debugger's terminal and the
guest's never mix.

## Messages

A **request** is a JSON object with `cmd` and, optionally, `id` (a number
or a string, echoed in the answer). Every request gets exactly one
**answer**: `{"id":..,"cmd":..,"ok":true, ...}` or
`{"id":..,"cmd":..,"ok":false,"error":"..."}`. Asynchronous **events** have
`ev` instead of `cmd` and come between answers.

Numbers that may not fit a double (registers, capability bases and
lengths, addresses in some answers) are strings of hexadecimal: `"0x5c"`.
Requests accept either form for any number. Strings that carry guest bytes
(console output, input, memory) use `\u00XX` for bytes outside printable
ASCII: one escape per byte, not UTF-8.

### Time

The engine runs the reference interleaving of the emulator (`-t`): round
after round, core 0, core 1, ... each executes one instruction or finds
itself blocked. A **tick** is one core's slot in a round; `tick` counts
them from power-on and is the debugger's clock. Positions are reported as
`{"tick", "round", "next" (the core whose slot comes next), "steps"
(instructions retired by all cores), "frontier" (the furthest tick reached;
before it, a run is a replay)}`. A stop is always in front of a slot: the
instruction of core `next` has not executed. `round` is the emulator's
`rounds`: the virtual timer reads it (rounds / 100 = microseconds), and an
idle machine skips it ahead to the next deadline, so it may jump.

## Requests

### Session

| Request | Answer |
|---|---|
| `hello` | `version` (1), `ncores`, `image`, `jit`, `virtual`, `timetravel`, `os`, `state` (`stopped`, `running`, `done`), `maps` (`path`, `scope`: image / kernel / prog, `prog`, `forth`), the position |
| `status` | `state`, `why` (when done), the position, `events` (the next event sequence number), `console` (bytes of console output so far), `history` (below) |
| `quit` | the engine ends after answering |

### Running

These answer at once with the position; the machine then runs, and a
`stopped` (or `done`) event says where it stopped. A request that runs
while the machine runs is refused: `pause` first.

| Request | Runs until |
|---|---|
| `continue` | a breakpoint, a watchpoint, `pause`, or the machine's end. With `fast: true`: not recorded (see below) |
| `stepi {core, n}` | core `core` has made `n` steps (an instruction, or a trap taken); the other cores run their slots of the same rounds. With `{pid}` instead of `core` (StrataOS): steps of whichever core runs that process in user mode, across switches and cores. |
| `next {core}` | as `stepi`, but over a call: to the instruction after it |
| `finish {core}` | the core reaches the address in its `ra` |
| `until {loc or addr, core?}` | some core (or `core`) is about to execute `loc` |
| `step-round {n}` | `n` rounds have ended |
| `goto {tick}` | forward: the machine reaches that tick, breakpoints ignored (on a recorded run inside the history, at once) |
| `pause` | stops a running machine at the next slot (or, with the JIT, between quanta) |

A plain `continue` with no breakpoint or watchpoint set, on a run that is
not recorded for time travel (the real-time timer, the network), runs at
full speed (`machine_round()`: the JIT with `-J`); transfers and gifts are
not logged meanwhile. Everything else runs the engine's exact loop.

`continue {fast: true}` catches up on a recorded run: the history is
dropped, the machine runs unrecorded (at full speed when no breakpoint or
watchpoint is set, else the exact loop without snapshots) and, when it
stops, recording starts again at that point (at the next round's start if
it stopped inside a round). Going back then reaches no further than that.

### Time travel

Only on a deterministic run: `-T virtual`, no network. A recorded run
steps one instruction at a time; the JIT (`-J`) serves only fast continues.
They stop at once (the answer is followed by a `stopped` event).

| Request | Goes back to |
|---|---|
| `goto {tick}` | any tick of the history (`status`: `history.from` .. `history.to`) |
| `reverse-stepi {core, n}` | in front of the core's n-th last step |
| `reverse-continue` | the last tick before now at which a breakpoint or watchpoint would have stopped |
| `reverse-step-round {n}` | the start of the current round (if a core has had its turn in it), or of the round before, n times |
| `reverse-tag {core, tag}` | in front of the last issue of that tag of that core |

The engine keeps a snapshot of the machine every `history.every` ticks
(only what changed since the one before: 4 KiB pages of T3, T2, the disk
and each core's state) and logs what came from outside (console input,
Ctrl-C, the debugger's own writes) with the position it arrived at. Going
back is a restore and a replay; reverse requests search snapshot interval
by snapshot interval, newest first. A write or input in the middle of the
history starts a new future: the snapshots and log entries after it are
dropped. The history stays inside its budget by dropping every other old
snapshot (the interval doubles). `history`:

```json
{"on":true,"from":0,"to":7715184,"snapshots":40,"every":200000,"bytes":31457280,
 "budget":536870912,"inputs":3,"diverged":0,"ticks":[0,200000,...]}
```

`diverged` counts replays that did not reproduce a snapshot exactly; it
should stay 0.

### Breakpoints and watchpoints

| Request | Fields |
|---|---|
| `break` / `tbreak` | `kind`: `pc` (default; `loc` or `addr`), `trap` (`cause`: illegal, lsfault, capinv, perm, bounds, xalign, ifault, xmiss, pend, capop, priv, halt, stop, svc, or any), `svc`, `eret`, `halt` (a core halts), `capop` (`ops`: comma-separated give, take, send, recv, dom, revoke, undom, split, share, restrict, join, save, restore, mkep, atomic, or all), `pid` (`pid` or `name`: when that process starts running on a core; a name not running yet becomes a pc breakpoint at its program's `_start`). Common: `core` (default any), `ignore` (hits to skip), `cond` (`"REG OP VALUE"`, OP one of == != < > <= >=, REG an integer register, `pc` or `instret`), `prog` (StrataOS: only while this program runs), `temp`. Answer: `bp` (its id), `desc`. |
| `watch` | `kind`: `ls` (`mem`: dls / ils, `loc` or `addr`, `len`, `access`: r / w / rw), `far` (`space`: t2 / t3 / dev, `addr`, `len`, `access`), `cap` (`core`, `reg`), `tag` (`core`, `tag`, `access`: issue / complete / both). Answer: `bp`, `desc`. |
| `delete {bp?}`, `enable {bp?}`, `disable {bp?}` | one, or all |
| `breakpoints` | `bps`: `id`, `kind`, `on`, `temp`, `core`, `addr`, `len`, `hits`, `ignore`, `desc` |

A breakpoint stops in front of the instruction. A watchpoint stops after
the slot that touched the watched thing. What touches what:

- D-LS bytes are written by stores, `linst`, a `tget` (a memory `tget`
  completes at issue; a pending device read when it completes, in some
  later slot) and read by loads, `ltag`, `linst`, a `tput`. I-LS bytes are
  written by `tgetx`.
- Far ranges: every write to T2 or T3 (a `tput`, a far atomic, the block
  device's DMA) and, with `r`, the issue of a `tget` / `tgetx` / atomic
  over them. In device space a transfer touches the port it starts at.
- A tag: its issue, its completion (at issue for memory transfers).

`loc` is an address, `label`, `label+N`, `file.s:LINE` (the first code at
or after the line; a basename is enough) or, under StrataOS, `prog:label`.

### State

| Request | Answer |
|---|---|
| `cores` | the position and `cores`: one summary per core (below) |
| `regs {core}` | `pc` (with `sym`, `file`, `line`), `x` (32 values), `csr` (instret, mode, ccr, cause, epc, tval, tvec, the user-mode ones, scratch, sscratch, ttag, tdata, tgeom, takefrom, corebase, corecount, xslot, ipend), `halted`, `stall` |
| `caps {core}` | `caps`: 16 capabilities |
| `ctab {core}` | `size`, `entries`: `slot`, `cap` for every valid entry of the save table |
| `inbox {core}` | `from`: `node`, `caps` per sender with something queued |
| `xmap {core}` | `xslot`, `entries`: `index`, `valid`, `space`, `far`, `ils`, `sym` |
| `tags {core?}` | `cores`: `core`, `tags` (16: `tag`, `busy`; for a tag that has had a transfer: `op` tget / tput / tgetx, `space`, `ls`, `len`, `far`, `port` (device), `pc`, `issued` and `completed` rounds, and ticks), `stall` |
| `pending` | `reads`: every pending device read (`core`, `tag`, `port`, `name`, `ls`, `len`, `seq`, `issued`, `waits`: what it waits for, e.g. "the timer deadline 5002 (now 3, in 4999 ticks)"); `blk`: the block device's queues (`commands`, `partial`, `caps`, `completions`, `returning_to`); `input_queued`, `breaks`, `deadline`, `now` |
| `granules` | `units`: the revocation units (`space`, `base`, `len`, `gen`) |
| `mem {space, core, addr or loc, len}` | `space` (dls, ils, t2, t3, disk), `addr`, `hex`, `sym` (D-LS). At most 64 KiB. |
| `disasm {core, addr or loc, n, before}` | `lines`: `addr`, `word`, `text`, `label` (at a label), `sym`, `file`, `line`, `pc` (the core's pc), `bp` |
| `sym {loc}` | `addr`, `section`, `prog` |
| `source {file, from, n}` | `lines` of a source file (found through the maps' `root`) |
| `backtrace {core}` | `frames`: `pc`, `sym`, `file`, `line`, `via` (ra / stack). There are no frame pointers: past `ra`, frames are words on the stack that point just after a `call`. |
| `processes` | StrataOS: `procs`: `pid`, `parent`, `state`, `status`, `core`, `ncores`, `name`, `running` (the cores running it now) |
| `console` | `data`: the last 64 KiB of console output |
| `history` | `history`, as above |

A **capability** is `{valid, live, space (none, t2, t3, dev, core, ep),
base, len, perms (r w x a d v), rv, gen, gnow (the granule's generation
now), id, port}`; `live` is false for a revoked one.

A **core summary** (`cores`, `stopped`) is `{core, pc, sym, file, line,
halted, mode (super / user), instret, busy (busy tags), pid and proc
(StrataOS), insn (the instruction at pc), stall}`. A **stall** says why the
core cannot make its step: `{reason, since (round), since_tick, detail,
why}` with reason one of `ls-hazard` (an access over a pending device
read), `xfer-hazard`, `tag-busy`, `pending-full`, `twait`, `tany`,
`inbox-empty` (ctake / crecv; `why` names the sender awaited),
`inbox-full` (cgive / csend), `halt-drain`, `blocked`.

### Changing the machine

| Request | Does |
|---|---|
| `set-reg {core, reg, value}` | `reg`: x0..x31, an ABI name, or `pc` |
| `set-mem {core, space, addr, hex}` | writes bytes (dls, ils, t2, t3, disk) |
| `input {data}` | console input bytes |
| `ctrl-c` | the break key |
| `pointer {op, x, y}` | the pointer device: `op` 1 move to (`x`, `y`) in framebuffer pixels, 2 button `x` (0 left, 1 right, 2 middle) down if `y` is 1 or up if 0, 3 wheel (`x` notches away from the user, `y` to the right), 4 the pointer enters the display, 5 leaves it |

On a recorded run these are logged and replayed like any input.

### The event log

| Request | Answer |
|---|---|
| `log {since, limit}` | `first` (the oldest event kept), `next` (the sequence number after the last one returned), `last` (the next one to be written), `events` |

Every event has `seq`, `kind`, `tick`, `round`, `core`, and under StrataOS
`pid` (the process the core ran). By kind:

| Kind | Fields |
|---|---|
| `xfer` | a transfer issued: `tag`, `op`, `space`, `ls`, `len`, `far`, `port`, `pending` (a device read that has not completed), `pc`, `cap` (the capability's id) |
| `xdone` | a pending device read completed: `tag`, `ls`, `len`, `issued` (round), `port` |
| `trap` | `cause`, `tval`, `pc`, `user` |
| `eret` | `from`, `to`, `user` (the mode now) |
| `give`, `send` | `to` (node), `space`, `base`, `len`, `perms`, `cap`, `pc`; `msgop` when it is a StrataOS message (a 4 KiB buffer: its op word) |
| `take`, `recv` | `from` (node), the same |
| `dom`, `revoke`, `undom` | `space`, `base`, `len`, `gen` |
| `halt` | `a0`, `instret`, `faulted` |
| `stall` | a stall that has ended: `from`, `to` (rounds), `reason`, `detail`, `pc` |
| `input` | `bytes` |

The log keeps the last 65536 events. When the engine goes back in time it
drops the events after the new position (the replay writes them again):
`last` may go down, and a front-end drops what it has from `last` on.

### Capability provenance

Every capability the machine makes while debugged gets an id (shown as
`id` in capabilities and `cap` in events); moves (cmov, csave / crestore,
the inbox) keep it. The engine records for each id: `op` (reset, split,
share, restrict, give, mint, join, dom, revoker, revoke, undom, atomic),
`parent` (and `parent2` for a join), `core`, `from` (give: the node it came
from), `space`, `base`, `len`, `perms`, `round`, `tick`, `pc`.

| Request | Answer |
|---|---|
| `prov {id}` or `prov {core, reg}` | `chain`: the capability and its ancestors, newest first |
| `provgraph {core?}` | `held`: every capability held now (registers and save tables of all cores, or one: `core`, `reg` or `slot`, `id`, `live`); `nodes`: them and all their ancestors |

## Events

| Event | Fields |
|---|---|
| `stopped` | `reason` (e.g. "breakpoint 1: pc 0x5c (print_str examples/lib/print.s:34)", "step", "round", "paused", "reverse step"), `core` (-1 if none), `bp`, the position, `cores` (summaries) |
| `done` | the machine has ended: `why` (halted, deadlock, timeout), `faulted`, the position, `cores`. Reverse requests still work. |
| `console` | `data`: guest console output |
| `emu` | `text`: a line the emulator wrote to stderr (a halt, a fault, a deadlock): TCP and Unix-socket clients only (with stdio it is on stderr) |

## An example

```
> {"id":1,"cmd":"break","loc":"print_str"}
< {"id":1,"cmd":"break","ok":true,"bp":1,"desc":"pc 0x5c (print_str examples/lib/print.s:34)"}
> {"id":2,"cmd":"continue"}
< {"id":2,"cmd":"continue","ok":true,"tick":0,"round":0,"next":0,"steps":0,"frontier":0}
< {"ev":"stopped","reason":"breakpoint 1: pc 0x5c (print_str examples/lib/print.s:34)","core":0,"bp":1,
   "tick":28,"round":8,"next":0,"steps":19,"frontier":28,"cores":[{"core":0,"pc":"0x5c","sym":"print_str",
   "file":"examples/lib/print.s","line":34,"halted":false,"mode":"super","instret":7,"busy":0,
   "insn":"tput  tg15, a0, c2, zero, a1"},{"core":1,"pc":"0x10",...,"insn":"ctake c3, t0",
   "stall":{"reason":"inbox-empty","since":5,"since_tick":17,"detail":"0x0","why":"waits for a capability from node 0"}},...]}
> {"id":3,"cmd":"reverse-stepi","core":0}
< {"id":3,"cmd":"reverse-stepi","ok":true,"tick":24,"round":7,"next":0,"steps":18,"frontier":28}
< {"ev":"stopped","reason":"reverse step","core":0,"tick":24,...}
```

## The map format (`sasm -g`)

A text file, one entry per line:

```
strata-map 1
root DIR                    the directory source paths are relative to (sasm's cwd)
image FILE                  the image it describes
org ADDR                    where .text starts (-T)
file N PATH                 source file N
sym SECTION ADDR NAME       a label (text, data, far, cluster) or a constant (abs)
line SECTION ADDR FILE LINE the first byte a source line put into a section
```

Addresses are hexadecimal. Code run through the overlay map (`xcall`) is
looked up at its far address in the `far` section. Under StrataOS, code at
I-LS 0x0000..0x3FFF is the boot ROM's (the image's map), 0x4000..0x7FFF
the resident kernel's (`kernel.map`), and kernel units in core 0's code
cache are found through its overlay map; user code at 0x8000 and up is the
program's (`prog/NAME.map`). A map with Forth's `v_latest` also names code
by the Forth dictionary in the core's D-LS (words compiled at run time),
and code above `KSTART` is Forth's kernel, installed from `.far`.

## Versions

| Version | Changes |
|---|---|
| 1 | the first |

A front-end checks `hello.version`; the engine will keep accepting version
1 requests, and new fields may be added to answers and events at any time.
