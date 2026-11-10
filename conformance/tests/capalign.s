; =============================================================================
; capalign.s: capabilities are 8-byte aligned
; =============================================================================
;
; What it checks (FINDINGS F6, doc/strataos.md 1.5: a capability's base
; is always a multiple of 8, so a transfer at offset o reaches exactly the
; bytes at base + o)
;   * csplit at an offset that is not a multiple of 8 (4, then 0x1001 - 1)
;     traps capop with tval = the offset; neither capability changes.
;   * csplit at a multiple of 8 (8) works: the new piece is based at 8, and
;     an 8-byte tget at its offset 0 returns the bytes at far addresses 8..15.
;   * The same rule in device space: splitting the device capability at 0x11
;     traps capop; at 0x10 (the break port) it works.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
pat:    .dword 0x0706050403020100, 0x0f0e0d0c0b0a0908 ; bytes 0..15
gbuf:   .dword 0                        ; read-back

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        la    s1, pat                   ; pattern
        la    s2, gbuf                  ; read-back buffer
        li    t1, 16                    ; 16 bytes
        tput  tg1, s1, c0, zero, t1     ; T3[0..16) = bytes 0..15
        li    t0, 0x1000                ; 4 KiB
        csplit c5, c0, t0               ; c0 = [0, 4K)
; ---- unaligned split points trap ----------------------------------------------------------
        li    t0, 4                     ; an unaligned split point
ca1:    csplit c6, c0, t0               ; must trap
        li    a0, C_CAPOP               ; expected cause
        la    a1, ca1                   ; expected epc
        li    a2, 4                     ; expected tval: the offset
        call  chkt                      ; check
        li    t0, 0xfff                 ; unaligned, inside the range
ca2:    csplit c6, c0, t0               ; must trap
        li    a0, C_CAPOP               ; expected cause
        la    a1, ca2                   ; expected epc
        li    a2, 0xfff                 ; expected tval: the offset
        call  chkt                      ; check
        cvalid a0, c6                   ; the destination is still empty
        li    a1, 0                     ; ...
        call  chk                       ; check
        clen  a0, c0                    ; c0 unchanged
        li    a1, 0x1000                ; 4 KiB
        call  chk                       ; check
; ---- an aligned split point works ---------------------------------------------------------
        li    t0, 8                     ; aligned
        csplit c6, c0, t0               ; c0 = [0, 8), c6 = [8, 4K)
        li    a0, 0                     ; no trap
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        call  chkt                      ; check
        cbase a0, c6                    ; its base
        li    a1, 8                     ; 8
        call  chk                       ; check
        li    t1, 8                     ; 8 bytes
        tget  tg1, s2, c6, zero, t1     ; offset 0: far address 8
        ld    a0, 0(s2)                 ; what came back
        li    a1, 0x0f0e0d0c0b0a0908    ; bytes 8..15
        call  chk                       ; check
; ---- device space: the same rule ------------------------------------------------------------
        cmov  c7, c3                    ; a copy of the device capability
        li    t0, 0x11                  ; unaligned
ca3:    csplit c8, c7, t0               ; must trap
        li    a0, C_CAPOP               ; expected cause
        la    a1, ca3                   ; expected epc
        li    a2, 0x11                  ; expected tval: the offset
        call  chkt                      ; check
        li    t0, 0x10                  ; the break port
        csplit c8, c7, t0               ; c8 = from the break port on
        cbase a0, c8                    ; its base
        li    a1, 0x10                  ; 0x10
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
