; =============================================================================
; lang/forth/guest/config.s: build constants of Strata Forth as a StrataOS guest
; =============================================================================
;
; The bare-metal Forth, booted by StrataOS on whole cores of its own beside
; StrataOS (doc/strataos.md, "Guests"): `guest forth 2 16` at the StrataOS
; shell. This directory holds what differs from bare metal (boot.s, config.s,
; init.s, platform.s, start.fs); source.s comes from lang/forth/bare. The
; include path chooses them, this directory first:
;   build/sasm -I lang/forth/guest -I lang/forth/bare -I build/forth-guest \
;              -o build/guest/forth.g lang/forth/forth.s
; As on bare metal the program starts on every core at I-LS 0 in supervisor
; mode, but it owns only what the guest grant gives it: an arena (its far
; memory), the console through an endpoint to StrataOS's tty server, a
; read-only clock and core control over its own cores (guest/boot.s).

ORIGIN    = 0x0000                      ; I-LS address of .text (sasm without -T)
PLAT_OS   = 0                           ; 0: bare metal (any core but core 0 is a worker)
PLAT_ECHO = 0                           ; the tty (cooked mode) echoes and edits what is typed
PLAT_STUB = 0x100                       ; bytes of .text before the xexec trampolines (the boot stub)
FAR_SNAP  = 0x20000                     ; c0 offset: the published D-LS snapshot (workers read it there)
FAR_SRC   = 0x10000                     ; c0 offset: the embedded source text (core.fs, tools.fs, see.fs)
PLAT_COMPACT = 0                        ; 0: every word has its own prologue and return (fast; 64 KiB of code space)
PLAT_INLINE = 16                        ; primitives of up to 16 code bytes (4 instructions) are copied inline
A_FILES   = 0                           ; (no files: INCLUDED fails before it uses this)
PLAT_PAGE = 0                           ; 0: no code paging (every word is resident; forth.s, "Code paging")
XSLOT     = 0                           ; (unused)
UBASE     = 0                           ; ...
UEND      = 0                           ; ...
TPV       = 0                           ; ...
PL_CHUNK  = 256                         ; console bytes per message (out_flush sends at most 256)

        .data                           ; D-LS (before the kernel's data)
        .align 8                        ; ...
plat_handles: .dword 0, 0, 0, 0, 0, 0   ; KVAR 38: standard handles (none: zeros)
plat_lkname: .dword 0                   ; KVAR 41: the server (msg) register 6 looks up (none)
pl_msg:   .space 64 + PL_CHUNK          ; a console message: the header, then its data
pl_kbuf:  .space PL_CHUNK               ; console input, a line at a time
pl_kpos:  .dword 0                      ; next byte of pl_kbuf to hand out
pl_klen:  .dword 0                      ; bytes in pl_kbuf
pl_keof:  .dword 0                      ; 1: the console's input has ended
s_gsmall: .ascii "Strata Forth: a guest needs an arena of at least 4 MiB\n" ; (plat_init)
s_gsmall_e:                             ; ...
        .align 8                        ; ...
