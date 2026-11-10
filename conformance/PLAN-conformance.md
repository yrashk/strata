# Conformance suite: working plan

Owner: the conformance agent. Scratch: `build/conformance/` (images, outputs,
fuzz programs; removed by `make clean`). Fold into the docs and delete when
integrated.

## Harness
- [x] `tests/lib/conf.s`: _start, sig / chk / chkt / done, supervisor and user
      trap recorders, tresume / uexit, to_user, devrd / devwr
- [x] `run.sh`: 3 machines in parallel per test, table, `xfail.txt`, `-v`,
      per-test `; args:` line
- [x] `make conformance`, added to `make test`
- [x] `fuzz/fuzz.py` 3-way differential fuzzer, `make fuzz SEEDS=N FIRST=S`
      (300 seeds clean)

## Tests
- [x] alu (generated: gen/gen_alu.py)
- [x] ls (generated: gen/gen_ls.py)
- [x] branch (generated: gen/gen_br.py)
- [x] traps: causes 1-6, 8, 10-14, epc/tval, banks, routing, priv, inbox rule, stop
- [x] caps: reset caps, cmov/csplit/cjoin/cshare/catomic/crestrict/csave/crestore
- [x] dom: cdom/crevoke/cundom, domain count, endpoints, self-gifts
- [x] xfer: hazards, tags, faults and their order, tamo
- [x] xmap: xmap/xunmap/xcall/xret/xslot, xmiss
- [x] timer: FREQ/NOW/DEADLINE/WAIT, latching; VSYNC, PRESENT; device bounds
- [x] devspan: byte-per-beat device transfers across registers
- [x] console: out, in (-i file), EOF 0x04, break + release
- [x] break: Ctrl-C (-b)
- [x] blk: identify, write/read/flush, errors, completion queue
- [x] plat: table layout and checksum
- [x] mc: gifts between cores, per-sender queues, ctake from, cpoll, tany inbox,
      windows, revocation across cores, stop, halted target
- [x] reserved: reserved CSRs, CCR bits, ignored fields
- [x] probes for discrepancies: pend (fixed), haltdrain, brkrel, pendxfer,
      capalign (xfail entries)

## Ideas not done
- several cores waiting on WAIT at once; VSYNC on two cores
- ltag / linst (software cache assist) edge cases and their pending-range rule
- tgetx-from-T2 code; xslot sizes other than 256
- fuzzer: user mode, capability ops, xmap
