# Fast browser emulator: worker, predecode, wasm JIT — working plan

Summary in PLAN.md section X. All done; fold into the docs, then delete.
(The scratch build dir `build-fast/` is removed.)

## 1. Web Worker — DONE (final browser pass with step 3)
- [x] emu/emu.c: `machine_round()` shared by main() and web/web.c (the
      duplicated round loop in web.c is gone); `-b`/`-m` are globals
- [x] web/web.c: `web_run(ms)` slice driver (no emscripten main loop):
      0 = call again, >0 = ms to sleep, <0 = stopped; `web_paint`, `web_finish`
- [x] site/play/worker.js: owns the module; postMessage protocol
      (out / paint with transferable RGBA rows / status / stopped; input /
      break the other way); idle = setTimeout to the next deadline, busy =
      MessageChannel hop (not clamped to 4 ms)
- [x] site/play/play.js: page only paints and sends input; Reset = new
      worker; no rAF anywhere (works in a hidden pane); JIT checkbox, ?jit=0
- [x] tools/wasm-run.js: the same module under node with the desktop flags
- [x] first browser check: hello, ws, gfx, Forth + gfx demo work
- [x] full browser pass: os boot + ls/uptime/spin + Ctrl-C, Reset, hello,
      mandel, gfx, ws (60 paints/s), Forth + gfx demo, ?run=forth&demo=gfx, ?jit=0

## 2. Faster interpreter — DONE
- [x] predecoded I-LS cache per core (`Dec`, `dec_tab`), decoded lazily,
      invalidated with the JIT (tgetx: `dec_invalidate`)
- [x] `run_fast()` for the plain integer subset; step() for the rest
- [x] hazard range (`hazard_set`, Core.hz_base/hz_span): the fast loop also
      runs while device reads are pending (the ws demo always has one)
- [x] reference mode keeps the exact interleaving: lead counters, whole
      rounds counted wholesale; old vs new `-j -T virtual` byte-identical
      (stdout+stderr incl. instret) on all examples, Forth test/gfx/multicore,
      ws demo, OS demo boot (12 cores), OS + -b
- [x] JIT mode: run_fast for cores with pending reads (native) / cold code (wasm)
- [x] conformance (interp/JIT/RTL), test-jit, compare.sh x11, test-fb,
      fuzz SEEDS=100, emu/jit/fuzz.py: all pass (BUILD=build-fast)
- [x] bench (arm64, -T virtual, wall): gfx 1280x800 0.28 s -> 0.02 s; Forth
      gfx 4.90 s -> 0.36 s; ws demo 300M steps 2.31 s -> 0.48 s (-j),
      0.58 s -> 0.15 s (-J: was all step() because of the pending read)

- [x] user-mode cores also run ahead exactly (`user_burst`, `slow_events`):
      OS demo boot `-j -T virtual` 3.3 s -> 0.8 s, identical to a
      step()-only build (`cc -DNO_FAST`), also with -c 8, -b, -m

## 3. Wasm JIT — DONE
- [x] emu/jit/jit_wasm.c: regions of basic blocks (BFS from a hot pc over
      branches, jal targets and return addresses, fall-through; <= 192
      blocks) -> one wasm function: br_table dispatch in a loop, forward
      branches as `br`, self-loops as their own `loop`, jalr through the
      per-core fn[]/blk[] tables, registers in locals, $ic quantum counter
- [x] JS glue (EM_JS): `new WebAssembly.Module` + `Instance` importing the
      emulator's memory and table; `table.grow` (-sALLOW_TABLE_GROWTH)
- [x] hot counters (24 visits; the fast loop returns to the JIT at backward
      jumps), flush on tgetx, slot reuse, tail-call chaining
      (return_call_indirect, feature-detected by WebAssembly.validate)
- [x] loads/stores check bounds/alignment and the hazard range -> the JIT
      runs with device reads pending (the ws demo always has one)
- [x] page toggle "JIT" (default on, ?jit=0), MIPS + mode in the status line
- [x] one build for worker and node (`-sENVIRONMENT=worker,node`);
      tools/wasm-run.js; tools/test-wasm.sh; `make test-wasm`; in `make test`
      when node + emcc exist; JIT fuzzer through it (eager and default HOT)
- [x] CI: `make test-wasm` before the site is assembled
- [ ] CI run itself not observed (emsdk 3.1.74 vs local emcc 7.0.0)

## Measurements (M-series Mac; browser = the desktop app's Chromium pane)

| what | before | interpreter now | wasm JIT |
|---|---|---|---|
| native gfx 1280x800, -j -T virtual | 0.28 s | 0.02-0.04 s | (native JIT 0.01 s) |
| native Forth gfx demo 640x400, -j | 4.90 s (69 MIPS) | 0.36-0.43 s (~850 MIPS) | (native JIT 0.04 s) |
| native ws demo, first 300M steps, -j / -J | 2.31 s / 0.58 s | 0.48 s / 0.15 s | |
| native OS demo boot, -j -T virtual | 3.3 s | 0.8 s | |
| node: ws demo first 300M steps | n/a | 0.46 s (~730 MIPS) | 0.18 s (~2300 MIPS) |
| browser: Forth gfx demo (335M) | ~20 s at 10 ms/frame (est.), 12 s in a worker without the fast loop (27 MIPS measured) | 0.43 s (779 MIPS) | 0.07 s (~5100 MIPS) |
| browser: gfx (27M, 8 cores) | 0.93 s machine time (29 MIPS) | 0.07 s | 0.05 s |
| browser: StrataOS `spin` | ~4 MIPS | 736 MIPS | 4670 MIPS |
| browser: ws demo | (was the complaint) | 60 paints/s, peaks of 290 MIPS demand met | 60 paints/s |

## Limitations
- The native JIT backends still do not check the hazard range: a core with
  a device read in flight runs the fast loop there.
- Regions are found per hot pc and may overlap (a function called from two
  hot loops is translated into both); MAXREGIONS per core, then a flush.
- Without tail calls every region-to-region transfer returns to the C
  dispatcher (correct, slower).
- The status line's MIPS is instructions retired per wall second: an idle
  (VSYNC-paced) machine shows little even though it could run much faster.
