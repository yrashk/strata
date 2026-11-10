# JIT for strata-emu: working plan

Dynamic binary translator for the plain integer ISA, two host backends
(arm64, x86-64), selected at compile time. Everything else stays in the
interpreter (`step()` in emu/emu.c).

## Design (summary)

- `emu/jit/jit.h`: the interface emu.c uses (init, exec, invalidate).
- `emu/jit/jit_be.h`: the private interface between the common part and a
  backend.
- `emu/jit/jit.c`: code memory (MAP_JIT / RWX), per-core translation caches
  (direct-mapped table of 16384 I-LS words -> host code), block formation,
  dispatcher, chaining (patch exit branches), invalidation (flush a core's
  cache when tgetx overwrites a translated word).
- `emu/jit/jit_arm64.c`: 24 guest registers live in host registers; 7 in the
  Core struct.
- `emu/jit/jit_x86_64.c`: guest registers in the Core struct (memory
  operands).
- Blocks are superblocks: they continue past conditional branches (taken =
  side exit), end at jal/jalr, before an untranslated instruction, or after
  128 instructions. Every exit adds its exact instruction count to instret.
- instret lives in a host register as `instret - limit` while translated
  code runs; a block's prologue exits when it reaches 0 (the quantum).
- Faulting loads/stores leave translated code at the faulting instruction;
  the interpreter then executes it (and traps) exactly as it would.
- emu.c: per-core quanta (JIT mode only); a core with pending device reads
  or a pending stop runs only interpreted steps.

## Checklist

- [x] Read README, spec 2.0, emu.c, isa.h, test scripts
- [x] Row in PLAN.md "Agent working locations"
- [x] jit.h / jit_be.h interface
- [x] jit.c common (memory, caches, dispatcher, chaining, invalidation)
- [x] arm64 backend
- [x] x86-64 backend
- [x] emu.c hooks: include, -J/-j flags + default, tgetx invalidation,
      quantum driver, round accounting
- [x] Makefile: jit sources into strata-emu; `bench` target
- [x] -j in tools/compare.sh, tools/compare-boot.sh, tools/test-fb.sh
- [x] tools/test-jit.sh (examples, gfx frame, Forth test input)
- [x] tools/bench-jit.sh (interpreter vs JIT wall time)
- [x] Test arm64 natively
- [x] Build x86-64 (clang -arch x86_64) and test under Rosetta
- [x] emu/jit/fuzz.py: differential fuzzer (random plain-ISA programs with
      traps, loops, calls; plus a tgetx invalidation check), both backends
- [x] Quantum ends in front of an instruction that meets other cores
      (gives/takes, inbox, tamo, cap2, tany, device/core-control transfers):
      faults.s otherwise saw a core that halts in its first steps still alive
- [x] StrataOS demo under the JIT: identical up to `kill %1`, where the
      kernel faults (capinv c8 at 0x580c): os/kernel.s wpl_bounce calls
      w_ring, which reuses c8 (crs8 T_CCTL ... cclear c8), then cgives c8.
      Reproduced with quanta and no translation at all: an OS race exposed
      by the coarser interleaving, reported to the OS owner.
- [x] Interpreter paths unchanged: tools/compare.sh (all 11 examples vs RTL),
      tools/test-fb.sh, tools/test-as.sh (now on the JIT by default) pass
- [x] Report; README note; scratch row removed from PLAN.md
- [x] (section X of PLAN.md) third backend, WebAssembly: emu/jit/jit_wasm.c
      (regions of basic blocks -> one wasm function; hot code only; checks
      the hazard range of pending device reads). A core with a pending
      device read now runs emu.c's fast loop (run_fast) instead of step()
      on the native backends.
- [ ] Later: x86-64 register caching; hazard-range check in the native
      backends' loads/stores (so they translate while device reads are
      pending, as the wasm backend does); fold this file into docs and
      delete it
