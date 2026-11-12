# conformance: the architectural conformance suite

Bare-metal test programs that check the ISA and the platform as the manual
states them, run on the three machines (the interpreter, the JIT and the
RTL) and compared with each other: every machine must say `pass`, and all
must produce the same signature.

```bash
make conformance              # every test on interpreter, JIT and RTL (~20 s)
conformance/run.sh -v ptr     # one test; -v shows the failing checks
make fuzz SEEDS=N FIRST=S     # 3-way differential fuzzer (fuzz/fuzz.py)
```

## Writing a test

A test `.include`s `tests/lib/conf.s` first; it provides `_start`, a
recording trap handler (supervisor and user), and:

- `sig a0`: append a value to the signature;
- `chk a0 = got, a1 = expected`: append `got`, count a failure if it differs;
- `chkt a0 = cause, a1 = epc, a2 = tval`: check (and forget) the last trap;
- `done`: print the signature and the verdict (core 0), then halt;
- `devrd` / `devwr`, `to_user`, `tresume` / `uexit`.

Signatures must not hold timing-visible values (cycle counts, NOW, `tpoll`
results that depend on latency). Lines at the top of a test configure the
run: `; args: FLAGS` (extra simulator flags, e.g. `-i` input or a `-P`
pointer script) and `; stdin: open` (console input that is open but never
delivers, so input reads wait as at a terminal). `xfail.txt` lists known
failures per machine; `FINDINGS.md` records every discrepancy the suite
found and how it was decided.

## The tests

| Test | Covers |
|---|---|
| `alu`, `ls`, `branch` | generated (`gen/gen_*.py`): every ALU op, load/store width and branch |
| `traps` | causes, epc/tval, the two trap banks, routing, privilege, the inbox rule, stop |
| `caps` | reset capabilities; cmov/csplit/cjoin/cshare/catomic/crestrict/csave/crestore |
| `ctab` | the save table beyond slot 63: csavex/crestorex, its size from the platform table, the same slots as the immediate forms, linearity and replacement, out of range (capop, tval = the register's value, checked first), 192 capabilities in slots 64..255 |
| `capalign` | a capability's base alignment (F6) |
| `dom` | revocation by address: cdom/crevoke/cundom, granule alignment, units and cjoin, revoker pieces, generations through split/share/save/gifts, 40 regions; endpoints, self-gifts |
| `xfer` | transfer hazards, tags, faults and their order, `tamo` |
| `pendxfer`, `pend` | transfers ordered after an in-flight device read (F5); CCR.PTRAP for loads, stores, `ltag`, `linst` |
| `haltdrain` | `halt` drains device reads (F3) |
| `ltag` | ltag/linst: hits, misses, replacement, the counter out of range; lsfault (ways 0, misaligned, past the D-LS) with the 64-bit entry address, entry addresses that wrap around |
| `xmap` | xmap/xunmap/xcall/xret/xslot, xmiss; slot-aligned units (xalign), the low bits of an entry ignored under a larger xslot, odd and huge slots, far links with high bits |
| `wide` | 64-bit offsets, lengths and split points against capability bounds: bits above the space's size count (transfers, device ports, `tamo`, `csplit`, `xmap`/`xcall`); the last word of system memory |
| `timer` | FREQ/NOW/DEADLINE/WAIT, latching; VSYNC, PRESENT; device bounds |
| `devspan` | byte-per-beat device transfers across registers |
| `console`, `break`, `brkrel`, `inrel` | output, input, end of input, Ctrl-C (`-b`), one release for every break read (F4) and for waiting input reads |
| `blk` | the block device: identify, write/read/flush, errors, the completion queue |
| `blkpair` | the block device and two cores: a command pairs only with a buffer from the core that submitted it, an orphan buffer comes straight back to its lender, a buffer returns to its lender whatever byte 1 says |
| `plat` | the platform table: layout (the save table's and the overlay map's sizes and the Local Stores' in the header), checksum, every entry |
| `lssize` | the Local Stores' sizes from the platform table (powers of two, 4..64 KiB), sp = the D-LS size at reset; loads, stores, tget / tput / tgetx ranges, the fetch, xmap's I-LS address and ltag's entry against them (lsfault / ifault at the size and at twice the size, no wrap-around). Run at 64/64 by the suite and at 32/32 and 16/4 KiB by `make test-ls` (EMU_ARGS="-L ..." with an RTL built with DLS_KIB / ILS_KIB); every check is mutation-checked against the 16/4 RTL |
| `ptr` | the pointer: STATE, EVENT order and packing, release by a write |
| `mc` | gifts between cores, per-sender queues, `ctake` from, `cpoll`, `tany` on the inbox, windows, revocation across cores, stop, a halted target |
| `reserved` | reserved CSRs, CCR bits, ignored fields |
| `reset` | the core-control reset request: taken by a spinning supervisor, a halted core, a user-mode core and a core that resets itself (before its next instruction); clears registers, capabilities, the save table, CSRs, the overlay map, the inbox and waiting reads; the boot ROM (first 4 KiB of each Local Store) comes back and the rest is cleared; restart at pc 0 in supervisor mode |

## Not covered yet

- Several cores waiting on WAIT at once; VSYNC on two cores.
- `ltag` / `linst` edge cases beyond the pending-range rule.
- `tgetx` from T2; xslot sizes other than 256.
- The fuzzer: user mode, capability operations, xmap.
