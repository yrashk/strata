; =============================================================================
; console.s: the console device: output, input, break and release ports
; =============================================================================
; args: -i conformance/tests/data/console-in.txt
;
; What it checks (common/platform.h; doc/strataos.md section 1.2)
;   * Output (port 0x0000): bytes appear in order (this test's own output).
;   * Input (port 0x0008): a read of n bytes completes once n bytes have
;     arrived; bytes come in order; after the end of the input every byte
;     reads 0x04. The input file holds "ab\ncdefghij" (11 bytes).
;   * Break (port 0x0010): a read stays in flight (tag busy) until Ctrl-C is
;     pressed or a write to the release port (0x0018) completes it with 0.
;     A release with no break read waiting is dropped (it does not complete
;     a later read).
;   * The console output capability c2 every core has is write-only.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

C_IN = 0x0008                           ; console input port
C_BRK = 0x0010                          ; console break port
C_REL = 0x0018                          ; console release port

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
ibuf:   .space 32                       ; input bytes
kbuf:   .dword 0                        ; break read
msg:    .ascii "console: output port works\n" ; 27 bytes

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test

; ---- output -----------------------------------------------------------------------------
        la    t0, msg                   ; the message
        li    t1, 27                    ; its length
        tput  tg15, t0, c2, zero, t1    ; print it
        la    s1, ibuf                  ; s1 = input buffer
        li    t1, 8                     ; 8 bytes
cn1:    tget  tg1, s1, c2, zero, t1     ; c2 is write-only: reading through it is a perm fault
        li    a0, C_PERM                ; expected cause
        la    a1, cn1                   ; expected epc
        li    a2, 0                     ; expected tval: the offset
        call  chkt                      ; check

; ---- input ------------------------------------------------------------------------------------
        li    t0, C_IN                  ; input port
        li    t1, 1                     ; one byte
        tget  tg1, s1, c3, t0, t1       ; read 'a'
        lbu   a0, 0(s1)                 ; the byte (waits for it)
        li    a1, 'a'                   ; expected
        call  chk                       ; check
        li    t1, 3                     ; three bytes
        tget  tg1, s1, c3, t0, t1       ; "b\nc"
        lbu   a0, 0(s1)                 ; first
        li    a1, 'b'                   ; expected
        call  chk                       ; check
        lbu   a0, 1(s1)                 ; second
        li    a1, 10                    ; newline
        call  chk                       ; check
        lbu   a0, 2(s1)                 ; third
        li    a1, 'c'                   ; expected
        call  chk                       ; check
        li    t1, 8                     ; eight bytes: "defghij" and the end of input
        tget  tg1, s1, c3, t0, t1       ; read
        ld    a0, 0(s1)                 ; all 8 bytes
        li    a1, 0x046a696867666564    ; "defghij" then 0x04
        call  chk                       ; check
        li    t1, 4                     ; past the end
        tget  tg1, s1, c3, t0, t1       ; read
        lwu   a0, 0(s1)                 ; four bytes
        li    a1, 0x04040404            ; all 0x04
        call  chk                       ; check

; ---- break and release ---------------------------------------------------------------------------
        li    a0, C_REL                 ; release with no break read waiting
        li    a1, 0                     ; (the value is ignored)
        call  devwr                     ; dropped
        la    s2, kbuf                  ; s2 = break buffer
        li    t0, -1                    ; fill it with ones
        sd    t0, 0(s2)                 ; so that a completion is visible
        li    t0, C_BRK                 ; break port
        li    t1, 8                     ; 8 bytes
        tget  tg2, s2, c3, t0, t1       ; waits for Ctrl-C (none comes in this test)
        li    t2, 200                   ; spin a little: the read stays pending
br_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, br_spin               ; loop
        tpoll a0, tg2                   ; still busy (the earlier release was dropped)
        li    a1, 1 << 2                ; expected: tag 2 busy
        call  chk                       ; check
        li    a0, C_REL                 ; release
        li    a1, 0                     ; (ignored)
        call  devwr                     ; completes the pending break read with 0
        twait tg2                       ; done
        ld    a0, 0(s2)                 ; the value
        li    a1, 0                     ; expected 0
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
