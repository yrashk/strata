# What the formal proofs found

Findings from proving the RTL with SymbiYosys (`formal/README.md`), newest
last. Two real bugs so far (F1 and F2, both fixed); the rest are observations
that came up while writing the properties and are recorded so that nobody
has to find them again.

## F1. A revocation walk outlives its core's reset; its `done` is taken by the core's next request (RTL bug, fixed)

**Where:** `rtl/strata_top.sv`, the granule walker (`cdom` / `crevoke` /
`cundom`). **Reachable only** with both Local Stores at 4 KiB and at least
two cores. The emulator is not affected.

**The proof that failed:** `make formal-top`, the assertion "a done that its
core takes answers the request the walk was started for" (`f_cont` in
`formal/props/strata_top.svh`).

**Counterexample** (bounded model checking from reset, 6 cycles, cores cut
out, two cores):

| cycle | walker | core 1 |
|---|---|---|
| 1 | idle | asks: `cdom` over granule 0xff |
| 2 | reading (for core 1) | a reset request for core 1 arrives |
| 3 | reading | still asking (the request is taken at the next cycle) |
| 4 | writing | |
| 5 | tail | stops asking: it is being reset (`dom_req` has `!held`) |
| 6 | **done to core 1** | **asks again: a new request, after its reset** |

The walker latches the request when it starts and does not look at
`dom_req` again; it raised `dom_done[w_who]` when the walk ended, whoever
was asking by then. A core that is reset while its walk runs drops the
request (`strata_core`: `dom_req = c2_ok && !held`), restarts, and can ask
for another walk. If the old walk is still running, the new request got the
old walk's `done`: the instruction completed at once, without a walk of its
own, with the old walk's generation (`dom_gen`) and the table as the old
walk left it.

In the trace the core is back at once because the cores are cut out. In the
machine the core is away for the reset sequencer, one cycle per Local Store
word: 8193 cycles at 64 KiB, 1025 at 8 KiB, 513 at 4 KiB (the larger of the
two stores counts). The same proof shows that a walk takes at most
3 x 256 + 6 = 774 cycles. So the old walk can still be running only when
both stores are 4 KiB, and only for a long walk (a `crevoke` / `cundom`
that walks back over a large unit).

**Effect:** the new `cdom`'s working capability gets a generation that was
not written for its range, and the unit boundaries (heads) are the old
walk's. In the reproduction a `cjoin` that the emulator allows traps with
capop on the RTL. With other ranges the new capability can be dead from the
start (capinv on first use). No case was found, or is expected, where a
revoked capability becomes live: the granules' generations never decrease.

**Reproduction:** `formal/repro/walkreset.s`, run by `formal/repro/run.sh`
(two cores, 4 KiB Local Stores). Before the fix:

```
emulator: ok
RTL:      core 0: fault capop pc=0x48 tval=0x6
```

**Fix** (`rtl/strata_top.sv`): the walker notes that its requester stopped
asking during the walk (`w_gone`) and then gives no `done`; the walk still
runs to its end, so the table stays consistent (as if the instruction had
completed just before the reset). The core's new request starts a walk of
its own when the walker is idle again. After the fix: `make formal-top`
passes, the reproduction prints `ok` on both, and `make lint`,
`make conformance` and `tools/compare.sh` on the examples pass.

`make test-ls` (part of `make test`) now ends with `formal/repro/run.sh`,
which runs this reproduction and F2's with 4/4 KiB Local Stores.

## F2. A store preempted by a stop had already written the Local Store (RTL bug, fixed)

**Where:** `rtl/strata_core.sv`, the D-LS port A write of a store. Any
configuration; user mode. The emulator is not affected.

**The proof that failed:** `make formal-core`, task `prec`, the assertion
"the Local Store is written only by a store that retires" (a cycle that
retires no instruction changes no architectural state).

**What happens:** a stop request (core control) sets `ipend`. In user mode
it is taken at the next instruction boundary: in F0, or, if it arrived
during the instruction's fetch (F0 or F1), in EX, where the instruction is
dropped and the stop trap taken with epc = its pc. `held` keeps such an
instruction from reaching the rest of the machine (transfers, gifts,
atomics, revocation requests), and its register writes are in the branch
not taken. But the store's write enable was combinational and did not look
at `held`:

```
state == S_EX && d.kind == K_STORE && mok && !hz_wr_stall   ->   da_we = mmask
```

So the D-LS was written in the cycle the stop trap was taken. The
supervisor's handler then saw memory changed by an instruction that, by epc,
had not executed. When the program is resumed the store runs again and
writes the same bytes, which is why nothing noticed: the emulator comparison
has no stops in user mode at arbitrary cycles, and StrataOS resumes a
preempted program at epc with its registers. A supervisor that inspects or
copies the program's Local Store at a stop (a debugger, a checkpoint, a
signal delivered instead of resuming) saw the wrong contents. The window is
two cycles of every store's three.

The same write also happened for a store preempted by a reset request,
where it cannot be seen: the reset reloads and clears the Local Stores.

**Reproduction:** `formal/repro/stopstore.s`, run by `formal/repro/run.sh`:
a user loop that stores a counter, stopped 36 times at shifting cycles; the
handler checks the cell whenever epc is the store. Before the fix:

```
emulator: ok
RTL:      bad
```

**Fix** (`rtl/strata_core.sv`): the store's write enable has `&& !held`.
After the fix the `prec` proof passes, the reproduction prints `ok` on
both, and `make lint`, `make conformance` and `tools/compare.sh` on the
examples pass.

## Observations (no change made)

**O1. "Not copyable" is not "exclusive".** `crestrict` can take the D
permission away from a copyable capability; the result is a second
capability that is not copyable (emulator and RTL agree). The first version
of the linearity property counted non-copyable capabilities and failed on
exactly this. What is exclusive is write access to memory: W never comes
with D in T2 / T3 (proved: the shape invariant), and `crestrict` cannot add
W. The property now counts write access.

**O2. The granule tables have no reset value outside simulation.** `gt3` /
`gt2` in each core and `mt3` / `mt2` in `strata_top` are cleared only under
`SIMULATION`. An FPGA's memories start at zero; on an ASIC they start
undefined, and each core's copy may differ from the master. The proofs
leave the initial contents free, and everything proved holds anyway: the
walker's results depend only on what it reads in the range it walks, and a
revocable capability is only ever based in a granule that a walk has
written (not proved here; by inspection of `cdom`, `csplit` and `crevoke`).
One consequence to know about: the first `cdom` over a range reads
undefined generations, so its generation is arbitrary rather than 1.

**O3. Generations wrap at 16 bits.** A walk gives max + 1; when the highest
generation in its range is 0xffff the new one is 0, which is not above the
old ones. The walker property says so explicitly. It takes 65535
revocations of one range to get there; the emulator has the same 16-bit
field.

**O4. A gift acknowledged in the very cycle of a reset request for its
receiver is dropped.** The reset request empties the inbox in that cycle
(`ib_n <= 0` wins over the push), after the sender got its acknowledge. This
is the documented behaviour of a reset (gifts waiting in the inbox are
gone), listed here because it is the one way a gift is lost; the inbox
proof names it as the only exception.

**O5. `strata_decode`'s `writes_rd` is not used by the core** (so it is not
specified). **The ALU's `lt` / `ltu` are meaningful only when it subtracts**
(a branch, or any function but ADD); the core uses them only for branches.

**O6. A stop request that arrives in the cycle a pending stop is taken is
merged with it.** `strata_core` sets `ipend` on `stop_req` and clears it
when the stop trap is taken; when both happen in one cycle the clear wins.
The first version of the trap property expected the new request to stay
pending and failed. This is not a lost request in the architecture's terms:
`ipend` is a flag, a second request while one is pending changes nothing,
and the outcome is the one the emulator gives when the second request
arrives just before the trap. (A reset request has the same race and is
handled explicitly: `rpend <= reset_req` when the reset is taken.) Recorded
because a supervisor must not count stop traps to count stop requests.

**O7. A save-table instruction preempted by a reset request in its second
cycle still wrote its slot.** `ct_we` (like the store's write enable before
F2) does not look at `held`; in S_CT only a reset request can preempt
(S_CT is supervisor-only, a stop is not taken there), and the reset
sequencer then empties the whole table, so the write cannot be seen. The
precision property excepted exactly this case. **Changed since:** `ct_we`
now has `&& !rpend`, and the property has no exception.

**O8. A device read answers retry only before its first byte.** The far
bus's rule ("retry, one cycle, before any data") holds for every port of
`strata_dev` (proved: `make formal-dev`), with one way around it that the
machine does not take: a core reset under its own transaction (the break
port's release flag is cleared by the reset). `strata_core` is reset only
when its Transfer Unit is quiet, so no transaction of its own is under way.
The Transfer Unit would cope anyway (it asks again for the rest), but the
rest would be asked of port + bytes moved, which is another port.
