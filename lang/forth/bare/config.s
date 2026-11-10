; =============================================================================
; lang/forth/bare/config.s: build constants of the bare-metal Forth
; =============================================================================
;
; The kernel (lang/forth/forth.s) includes "config.s" first and "platform.s"
; near its end. Which pair it gets is chosen by the assembler's include path:
;   build/sasm -I lang/forth/bare -I build/forth -o build/forth.stx lang/forth/forth.s
; This pair is the bare-metal one: the program owns the whole machine, starts
; on every core at I-LS 0 in supervisor mode with every boot capability.

ORIGIN    = 0x0000                      ; I-LS address of .text (sasm without -T)
PLAT_OS   = 0                           ; 0: bare metal (any core but core 0 is a worker)
PLAT_ECHO = 1                           ; the console is raw: the line editor echoes what is typed
PLAT_STUB = 0x100                       ; bytes of .text before the xexec trampolines (the boot stub)
FAR_SNAP  = 0x20000                     ; c0 offset: the published D-LS snapshot (workers read it there)
FAR_SRC   = 0x10000                     ; c0 offset: the embedded source text (core.fs, tools.fs, see.fs)
PLAT_COMPACT = 0                        ; 0: every word has its own prologue and return (fast; 64 KiB of code space)
PLAT_INLINE = 16                        ; primitives of up to 16 code bytes (4 instructions) are copied inline
A_FILES   = 0                           ; (no files on bare metal: INCLUDED fails before it uses this)
