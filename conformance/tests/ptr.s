; =============================================================================
; ptr.s: the pointer device (device window 0x4100)
; =============================================================================
; args: -P conformance/tests/data/ptr.txt
;
; What it checks (common/platform.h, doc/strataos.md 1.2)
;   * The script queues, before the program runs: the pointer entering at
;     (100, 50) (the first move of a pointer not over the display is an
;     enter, carrying the position), a move to (120, 60), the left button
;     down and up there, and a wheel turn of 2 away from the user and 1
;     left.
;   * STATE: x 120, y 60, no buttons, 5 events queued, over the display.
;   * EVENT returns them in order, packed u16 x, u16 y, u8 buttons, s8 wheel
;     y, s8 wheel x, u8 kind (4 enter, 1 move, 2 button, 3 wheel).
;   * STATE afterwards: none queued.
;   * A write to EVENT completes an EVENT read that waits (nothing queued)
;     with 0, on all 8 bytes.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

P_EV  = 0x4100                          ; EVENT
P_ST  = 0x4108                          ; STATE

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
pbuf:   .dword 0                        ; a register read
wbuf:   .dword -1                       ; the read the write releases
expect: .dword 100 | 50 << 16 | 4 << 56                 ; enter
        .dword 120 | 60 << 16 | 1 << 56                 ; move
        .dword 120 | 60 << 16 | 1 << 32 | 2 << 56       ; left down
        .dword 120 | 60 << 16 | 0 << 32 | 2 << 56       ; left up
        .dword 120 | 60 << 16 | 2 << 40 | 0xff << 48 | 3 << 56 ; wheel +2, -1

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    a0, P_ST                  ; STATE
        call  preg                      ; a0 = it
        li    a1, 120 | 60 << 16 | 5 << 40 | 1 << 56 ; at (120, 60), 5 queued, over the display
        call  chk                       ; check
        la    s2, expect                ; the events in order
        li    s3, 5                     ; ...
ev_l:   li    a0, P_EV                  ; EVENT
        call  preg                      ; a0 = the next one
        ld    a1, 0(s2)                 ; expected
        call  chk                       ; check
        addi  s2, s2, 8                 ; next
        addi  s3, s3, -1                ; ...
        bnez  s3, ev_l                  ; ...
        li    a0, P_ST                  ; STATE: none left
        call  preg                      ; ...
        li    a1, 120 | 60 << 16 | 1 << 56 ; ...
        call  chk                       ; check
        la    s1, wbuf                  ; an EVENT read that has to wait
        li    t0, P_EV                  ; ...
        li    t1, 8                     ; ...
        tget  tg2, s1, c3, t0, t1       ; ...
        li    t2, 2000                  ; let it be tried
pr_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, pr_spin               ; loop
        li    a0, P_EV                  ; a write to EVENT releases it
        li    a1, 0                     ; (the value is ignored)
        call  devwr                     ; ...
        twait tg2                       ; it completes
        ld    a0, 0(s1)                 ; with 0
        li    a1, 0                     ; ...
        call  chk                       ; check
        j     done                      ; print the signature and the verdict

; preg(a0 = port) -> a0 = the 8-byte register read there
preg:
        la    t0, pbuf                  ; ...
        li    t1, 8                     ; ...
        tget  tg1, t0, c3, a0, t1       ; ...
        twait tg1                       ; ...
        ld    a0, 0(t0)                 ; ...
        ret                             ; done
