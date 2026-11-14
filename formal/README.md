# Formal verification of the RTL

Proofs of `rtl/` with [SymbiYosys](https://github.com/YosysHQ/sby) (`sby`).
The simulation-based checks (the emulator comparison, the conformance
suite) show that the RTL does what the emulator does on the programs that
were run; these proofs show properties for every input sequence, under the
assumptions each one states.

```
make formal            # every proof; prints the table of results
make formal-NAME       # one target: alu decode div mul mul_lemma bus tu core top
make formal-report     # the table again, from the last runs
formal/repro/run.sh    # the reproductions of FINDINGS.md F1 and F2 on emulator and RTL
```

`make formal` is not part of `make test`: it takes about 15 minutes on an
18-core laptop, nearly all of it for the core (five inductions of 5 to 8
minutes each, run side by side).
What was found is in `FINDINGS.md`.

## Tools

| Tool | Version used | Installed with |
|---|---|---|
| SymbiYosys (`sby`) | 0.71 | `brew install sby` |
| Yosys (with `yosys-smtbmc`) | 0.71 | (a dependency of `sby`) |
| sv2v | 0.0.13 | (already there for `fpga/synth.sh`) |
| Yices 2 | 2.7.0 | `brew install yices2` |
| Bitwuzla | 0.9.1 | `brew install bitwuzla` |
| Z3 | 5.4.1 | `brew install z3` (not used by any proof now) |

**Front end.** The RTL is SystemVerilog with a package, packed structs and
enums, which Yosys's own `read_verilog -sv` does not take. It is converted
with `sv2v`, exactly as `fpga/synth.sh` does for synthesis, so the proofs are
about the same Verilog that is synthesized. The alternative, the
`yosys-slang` plugin, is not in Homebrew's Yosys, and would be a second
reading of the source next to sv2v's and Verilator's. `sv2v` is run with
`-D FORMAL` and `-E assert` (keep the assertions), over the RTL and
`formal/spec/*.sv`, into `formal/build/strata.v`; every `.sby` file reads
that one file. A failed assertion is therefore reported by its line in
`formal/build/strata.v`.

## Layout

```
formal/NAME.sby          one per target; its tasks are the proofs (prove, cover, ...)
formal/spec/*.sv         specifications of combinational modules: a module that
                         instantiates the unit and asserts its outputs
formal/props/MODULE.svh  properties of a sequential module, included at the
                         end of rtl/MODULE.sv under `ifdef FORMAL (three lines
                         in the RTL); they can see the module's internals and
                         the package's types
formal/run.sh            runs everything, prints the table
formal/vcdpeek.py        prints chosen signals of a counterexample trace
formal/repro/            programs that show a finding on emulator and RTL
formal/build/            sv2v output, sby work directories (not in git)
```

In the property files everything that is not RTL starts with `f_`. The
header comment of each says what is proved, what is assumed, and what is
not covered; assumptions are `assume` statements and nowhere else.

## The proofs

The solver is Yices for `bus`, `tu`, `top` and `div`'s `ref`, Bitwuzla for
the rest. (Yices did not finish the core's inductions in 20 minutes each;
Bitwuzla takes 5 to 8.)

| Target | Task | Method | What |
|---|---|---|---|
| `alu` | prove, cover | combinational | every ALU function against its definition; `lt` / `ltu` |
| `decode` | prove, cover | combinational | an encoding is illegal exactly when the emulator says so; the kind and every operand field of every format |
| `div` | prove | induction (k = 2) | A = Q·B + R, R < B, the signs, x/0 and MIN/-1; done after exactly 65 cycles (1 for the special cases); results held |
| `div` | ref | BMC, 68 cycles | the same results against Verilog's `/` and `%`, operands up to 8 bits |
| `div` | cover | 72 cycles | signed and unsigned divisions, the special cases, a restart |
| `mul` | prove, cover | induction (k = 2) | the four partial products of the right halves, added at the right weights; `done_lo` after 3 cycles, `done` after 4 |
| `mul_lemma` | prove, cover | combinational | the schoolbook identity `mul` rests on, for 4-bit digits |
| `bus` | prove, prove5 | induction (k = 3) | one grant, round-robin, ownership, one start per transaction, beats neither lost nor made up, a retry returns the bus; 3 and 5 masters |
| `bus` | live | induction (k = 20) | a request is granted within NM·(T + 2) cycles when targets answer within T |
| `bus` | cover | 30 cycles | |
| `tu` | prove | induction (k = 4) | queue and tag invariants, status outputs, hazards (both directions), Local Store writes, put data, no command lost, retire order and the rotation rule |
| `tu` | cover | 40 cycles | every kind of transfer retires, a rotation with a full queue, a retry half way |
| `core` | base | induction (k = 2) | x0; the shape of every capability register (in its space, aligned, never writable and copyable in memory, ...); the core's "live" equals the specification's; what `tu` and `top` assume of a core |
| `core` | traps | induction (k = 2) | the listed traps are delivered as the emulator's `trap()`: bank, epc, cause, tval, mode, next pc or halt |
| `core` | prec | induction (k = 2) | a cycle that retires nothing changes no architectural state and takes nothing from the rest of the machine |
| `core` | priv | induction (k = 2) | in user mode every supervisor-only instruction traps; supervisor state changes only by a trap to the supervisor |
| `core` | lin | induction (k = 2) | write access to a byte of far memory is never in more registers after an instruction than before (but for the instructions that bring a capability in); a gift given empties a linear source, a gift taken lands in cd; csave / crestore move, not copy |
| `core` | cover | 6 cycles, from any state | traps of several causes to both handlers and to the double-fault halt, instructions retiring, a gift given and one taken; from any state, see below |
| `top` | prove | induction (k = 3) | inboxes: arbitration, no overflow, a gift comes out once, unchanged, in order; the walker: one walk, at most 774 cycles, the range rewritten with a new highest generation, heads at unit boundaries, done only for the request that started it |
| `top` | cover | 40 cycles | |

Results and run times of the last run: `make formal-report`.

**The core's covers start in any state, not at reset.** From reset every
trace spends 256 cycles in the reset sequencer first, and the solver then
needs half an hour per cover. So `core`'s `cover` task drops the
reset-in-the-first-cycle assumption (`F_FREE`): its traces show that each
property's condition can occur together with every assumption (the proofs
are not vacuous), not that the states are reachable. From reset, the first
instruction's execute cycle was reached once by hand (step 260, 28 minutes
of Bitwuzla; writing the trace had not finished 35 minutes later and was
stopped), so that check is not a task. The proofs themselves do not depend
on this: an induction holds from any state anyway. The other targets'
covers all start at reset.

### What is assumed

Every assumption is in the header of the property file it belongs to. In
short:

- **All:** reset is asserted in the first cycle.
- **`alu`, `decode`, `div`, `mul_lemma`:** nothing else.
- **`mul`:** the operands are held from start to done (the module's
  contract; inside the core the unit is cut out, see below).
- **`bus`:** nothing for safety. For liveness: the master keeps asking,
  targets answer within T cycles.
- **`tu`:** the core's side (commands inside the Local Store, aligned, no
  device `tgetx`, flush only when quiet), which `core` **proves** of the
  real core (task `base`); the bus's side (a grant only to a request,
  answers only to a granted transaction), which `bus` proves; the targets'
  side (no beat beyond the burst, done with or after the last beat, retry
  only to a device read with bytes to come), which is **not proved** of
  `strata_mem` / `strata_dev`; and that a Local Store read returns the word
  read.
- **`core`:** a capability taken from the inbox is well-formed; the save
  table returns a well-formed capability (every write to it is proved
  well-formed; the table is not modelled word by word). The Local Stores,
  the multiplier, the divider and the Transfer Unit are cut out, so nothing
  depends on what they answer.
- **`top`:** a core pops its inbox only on a hit, and a revocation request
  names a non-empty range inside its table (both **proved** of the real core
  in `core`); a core keeps a request up, operands unchanged, unless a reset
  request for it is pending (true of `strata_core` by `dom_req`'s
  definition, not proved). The cores, devices, memories and bus are cut
  out.

### What is not covered, and why

- **What instructions compute when they retire** (the value written, the
  next pc, the capability made). That would be a full ISA specification in
  SystemVerilog next to the emulator; the instruction-by-instruction trace
  comparison covers it by simulation. The core proofs are about the things
  simulation cannot exhaust: traps, privilege, linearity, liveness of
  capabilities, precision.
- **The full system with real cores.** `top` cuts the cores out. That each
  core's copy of the granule table equals the master, and that capabilities
  in inboxes, save tables and other cores do not overlap a writable one, are
  system-wide invariants that were not attempted.
- **`strata_mem`, `strata_dev`, `strata_uart`, `strata_ram`:** no proofs.
  The Transfer Unit's assumptions about targets rest on reading them.
- **Liveness** beyond the bus's bound (a transfer completes, an instruction
  finishes): depends on devices that may wait forever by design.
- **capop and pend traps, the tag lookup sequencer, the overlay map's
  lookup:** not specified.
- **The multiplier's multiplication:** `mul` shows the right operands reach
  the unit's one multiplier and the products are added correctly; that
  `ma * mb` is a product is the synthesis tool's business. The schoolbook
  identity is checked for 4-bit digits only (no solver here decides it for
  6-bit ones within minutes).
- **Other parameters:** `core` and `top` are run for two cores, 4 KiB Local
  Stores and (core) a 4-entry overlay map, as core 0.

## Reading a failure

`sby` prints the failed assertion as `strata.v:LINE`; look the line up in
`formal/build/strata.v` (the property text is recognisable there). The
trace is `formal/build/NAME_TASK/engine_0/trace*.vcd`:

```
formal/vcdpeek.py formal/build/top_prove/engine_0/trace.vcd ws dom_req dom_done w_who
```

A failure in the *induction* step of a `prove` task is not yet a bug: the
trace starts in a state that may be unreachable, and the usual cure is
another invariant (see the ones already in the property files). A failure
in the *base case*, or in a `bmc` task, starts from reset and is real, or
is a wrong property, or a missing assumption.

## Writing properties: what bit us

- sv2v reads `if (c) assert (x); else ...` as the assertion's own `else`.
  Write `if (c) begin assert (x); end else ...`.
- A function called from `always_comb` must not read module signals (sv2v
  then writes an explicit sensitivity list, with memories in it, which Yosys
  refuses): pass them as arguments.
- `$past` only inside clocked blocks, and `$past(a[i])` takes the past of
  `i` as well.
- One element "chosen by the solver" (`(* anyconst *)`) stands for all only
  if the property needs nothing about the other elements; an invariant that
  other properties lean on must be asserted for all elements (the Transfer
  Unit's tags and entries are).
- Small memories whose read address depends on another read of the same
  memory (the overlay map) make the SMT back end report a logic loop:
  `memory_map` them in the `.sby` script.
- In a `.sby` script, `hierarchy -top M -chparam ...` followed by
  `prep -top M` works for `strata_core`; for `strata_top` it crashed Yosys
  0.71, and `chparam -set ...; hierarchy -top M; prep` is used instead.
