# emu/jit: the emulator's translators

`strata-emu` translates hot plain-integer code to the host and leaves
everything else to the interpreter (`step()` in `emu/emu.c`), which stays
the reference. Three backends, chosen at build time: arm64 and x86-64
(native), and WebAssembly (the browser build, `web/`).

| File | What |
|---|---|
| `jit.h` | the interface `emu.c` uses: init, exec, invalidate |
| `jit_be.h` | the interface between the common part and a backend |
| `jit.c` | code memory (MAP_JIT / RWX), per-core translation caches (a direct-mapped table of 16384 I-LS words to host code), block formation, the dispatcher, chaining (patched exit branches), invalidation |
| `jit_arm64.c` | 24 guest registers live in host registers, 7 in the Core struct |
| `jit_x86_64.c` | guest registers in the Core struct (memory operands) |
| `jit_wasm.c` | regions of basic blocks become one wasm function; hot code only |
| `fuzz.py` | differential fuzzer: random plain-ISA programs (traps, loops, calls, a `tgetx` invalidation check), interpreter against JIT |

## How it works

- **Blocks are superblocks.** They continue past conditional branches (a
  taken branch is a side exit) and end at `jal`/`jalr`, in front of an
  instruction that is not translated, or after 128 instructions. Every exit
  adds its exact instruction count to `instret`.
- **Quanta.** While translated code runs, `instret` lives in a host
  register as `instret - limit`; a block's prologue exits when it reaches
  0. The quantum also ends in front of any instruction that meets other
  cores (gives, takes, the inbox, `tamo`, `cap2`, `tany`, device and
  core-control transfers), so those happen in the reference order.
- **Faults.** A load or store that faults leaves translated code at that
  instruction; the interpreter then executes it, and traps, exactly as it
  would have.
- **Invalidation.** `tgetx` over translated code flushes that range of the
  core's cache.
- **Pending device reads.** The WebAssembly backend checks the hazard
  range of a core's in-flight device reads in its loads and stores, so it
  keeps translating. The native backends do not: a core with a device read
  in flight runs `emu.c`'s fast interpreter loop (`run_fast`) until it
  completes. In StrataOS only `tty` keeps reads in flight, alone on its
  core.

The JIT is the default unless `-t` (trace) or `-T virtual` asks for the
exact one-instruction interleaving; `-J` / `-j` force it on or off.

## Testing

```bash
make test-jit       # every example, the gfx frame and the Forth test input: JIT = interpreter
make bench          # interpreter against JIT, wall time (mandel, gfx, Forth gfx demo)
python3 emu/jit/fuzz.py   # the differential fuzzer (also run by make test-wasm for the wasm backend)
```

The x86-64 backend was tested only under Rosetta (built with
`clang -arch x86_64`).

## Open

- x86-64: keep guest registers in host registers, as arm64 does.
- The native backends: check the pending-read hazard range in translated
  loads and stores (as the wasm backend does) instead of falling back to
  the fast interpreter loop.
