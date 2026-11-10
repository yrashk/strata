; =============================================================================
; devspan.s: device transfers move one byte per beat to consecutive ports
; =============================================================================
;
; What it checks (doc/strataos.md 1.2; common/platform.h)
;   * A 16-byte read starting at FREQ (0x3008) returns FREQ then DEADLINE.
;   * A 16-byte write starting at FREQ (read-only: ignored) writes DEADLINE
;     with its second 8 bytes (it takes effect at DEADLINE's byte 7).
;   * Read-only windows are byte-addressed: 4 bytes from 0x1004 are bytes
;     4..7 of the platform table (version, entry size); 2 bytes from 0x2006
;     are the identify ROM's log2 block size.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
buf:    .dword 0, 0                     ; 16 bytes
wv:     .dword 0x1111, 0x0000777700007777 ; FREQ (ignored), DEADLINE

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    a0, 0x3010                ; DEADLINE
        li    a1, 0x4242                ; a known value
        call  devwr                     ; set it
        la    s1, buf                   ; buffer
        li    t0, 0x3008                ; FREQ
        li    t1, 16                    ; FREQ and DEADLINE
        tget  tg1, s1, c3, t0, t1       ; one read across two registers
        ld    a0, 0(s1)                 ; FREQ
        li    a1, 1000000               ; expected
        call  chk                       ; check
        ld    a0, 8(s1)                 ; DEADLINE
        li    a1, 0x4242                ; expected
        call  chk                       ; check
        la    t2, wv                    ; 16 bytes to write
        li    t0, 0x3008                ; starting at FREQ
        li    t1, 16                    ; FREQ (ignored) and DEADLINE
        tput  tg1, t2, c3, t0, t1       ; write
        twait tg1                       ; done
        li    a0, 0x3010                ; DEADLINE
        call  devrd                     ; read it
        li    a1, 0x0000777700007777    ; the second 8 bytes
        call  chk                       ; check
        li    a0, 0x3008                ; FREQ
        call  devrd                     ; unchanged
        li    a1, 1000000               ; expected
        call  chk                       ; check
        sd    zero, 0(s1)               ; clear the buffer
        li    t0, 0x1004                ; platform table bytes 4..7
        li    t1, 4                     ; four bytes
        tget  tg1, s1, c3, t0, t1       ; read
        lwu   a0, 0(s1)                 ; version | entry size << 16
        li    a1, 1 | 32 << 16          ; expected
        call  chk                       ; check
        sd    zero, 0(s1)               ; clear
        li    t0, 0x2006                ; identify ROM bytes 6..7
        li    t1, 2                     ; two bytes
        tget  tg1, s1, c3, t0, t1       ; read
        lhu   a0, 0(s1)                 ; log2 block size
        li    a1, 9                     ; 512-byte blocks
        call  chk                       ; check
        li    a0, 0x3010                ; DEADLINE
        li    a1, 0                     ; back to 0
        call  devwr                     ; write
        j     done                      ; print the signature and the verdict
