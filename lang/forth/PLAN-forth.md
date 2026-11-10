# Strata Forth: working plan (agent F)

Temporary; folded into README.md when integrated.

## Design decisions (made)
- Native subroutine-threaded code; TOS in s1, DSP s0 (down), return stack = sp,
  DO index/limit in s2/s3, locals frame s4. Inline primitives (body copied from
  the far mirror), literal folding (+ - and or xor shifts @ ! c@ c!), tail calls.
- Code compiled into a D-LS staging buffer (4 KiB), installed at `;` by
  tput -> far mirror (c0, identity map: far offset == I-LS address) + tgetx.
- Kernel lives in `.far` at KSTART=ORIGIN+0x100; `.text` is a boot stub +
  worker loop + 8 xexec trampolines (ORIGIN+0xC0).
- Capability/transfer words built in Forth via `xexec` (run-time-assembled
  single instruction in a cached trampoline).
- Multicore: c0 (image) lent to workers; job board = atomic T2 cap c12;
  doorbell = copy of c12 via cgive. spawn/await.
- Far cache (ltag/linst, 32 sets x 2 ways x 64 B, write-back) behind
  far@/far!; heap cap is platform-defined (bare: c8).
- Platform layer: lang/forth/{bare,os}/{config.s,platform.s}, chosen by -I.
- core.fs embedded via generated build/forth/corefs.s (awk) at far 0x10000.

## Tasks
- [x] Read ISA/emu/sasm/examples/spec
- [x] forth.s kernel written (lang/forth/forth.s is the only source; the
      scratch drafts are deleted)
- [x] bare platform.s
- [x] Assembles; boots on emu and RTL (boot ~1M instructions, ~4 s on RTL)
- [x] core.fs: control structures, loops, strings, defining words, printing
- [x] core.fs: mini assembler, see/disassembler, words, .s, dump
- [x] core.fs: locals {, quotations [: ;]
- [x] core.fs: tiers/caps words (xexec), far cache stats
- [x] core.fs: multicore helpers (spawn/await/run-on/par)
- [x] tests/test.fs + test.out + run.sh; emu == RTL == expected (verified)
- [x] Makefile: forth, forth-rtl, test-forth (block before the manual rules)
- [x] demos: tiers.fs, multicore.fs, gfx.fs (verified on emu; tiers also on RTL: same output but cycle counts)
- [x] README.md (design, maps, dialect, words, session, sizes, OS notes)
- [x] platform seam: plat_init plat_write plat_key plat_ticks plat_ms plat_fget
      plat_fput plat_source plat_bye; PLAT_STUB / PLAT_ECHO / PLAT_OS in config.s
- [ ] OS backend (waiting for the kernel agent): lang/forth/os/{config.s,platform.s}
  - config: ORIGIN 0x8000, PLAT_OS 1, PLAT_ECHO 0 (tty cooked echoes),
    PLAT_STUB large enough for sys.s's .text if sys.s is included from config.s
    (sys.s .data must land before dict0: include it from config.s, which comes
    before forth.s's .data; the "SYS2" marker word decides time-shared vs not)
  - plat_write -> sys_write(1), plat_key -> sys_read(0) (buffered), plat_ticks
    -> c7 clock, plat_ms -> sys_sleep, plat_source -> read core.fs through fs
    into c0 at FAR_SRC, plat_bye -> sys_exit, v_ncores = corecount (0 -> 1:
    spawn then says "no such worker core"), heap cap = a piece of c0
  - BLOCKER 1: the kernel proper is in the image's .far section; under the OS
    the program cannot read its image (time-shared) or gets a read-only share
    of the raw image (exclusive) -> the stub must copy the far section into c0
    at the label offsets first (needs: which register holds the image share,
    and the image layout), or proc does it.
  - BLOCKER 2: time-shared code is reloaded from the image on every switch, so
    JIT code is lost -> run Forth exclusive (no SYS2 marker, or -n N), or the
    dispatcher reloads [PTEXT, program-declared end) from c0's mirror.
  - BLOCKER 3: I-LS 0x8000..0xFFFF (32 KiB) < kernel 11.4 KiB + core.fs 21 KiB
    + sys.s; move see/disasm/dump/words/.caps into tools.fs loaded by include.
  - Makefile: build/prog/forth (sasm -T 0x8000 -I lang/forth/os -I os/lib ...),
    core.fs/tools.fs/demos as disk files (after step 4's rules settle)
- [ ] Wire test-forth into make test (user does it)
- [ ] Optional: leaf words without prologue; shorter ." code; tools split

## Open problems
- I-LS budget: kernel 11.6 KB + core.fs ~21 KB compiled -> 33 KB free (bare).
  StrataOS gives only I-LS 0x8000..0xFFFF (32 KB): must split core.fs
  (tools.fs loaded with include) and/or page code.
- OS: JIT code installed beyond the image's .text may be lost on context
  switch (OS reloads code from the image) — needs coordination.
- OS: where .far lands in the arena (assumed: c0 offset == label).
