; =============================================================================
; break.s: Ctrl-C through the console break port (simulated with -b)
; =============================================================================
; args: -b 200000
;
; What it checks (common/platform.h; doc/strataos.md section 1.2)
;   * A break read (port 0x0010) waits, without holding up the machine,
;     until Ctrl-C is pressed; it then completes with 0x03 bytes.
;   * Each press completes one read: a second read waits again (here it
;     is completed by a write to the release port, with 0).
; The runner presses Ctrl-C once, after 200000 emulator steps / RTL cycles
; (-b). Core 0 reads the break port at once and waits; core 1 keeps the
; machine busy meanwhile (an emulator with every core blocked and no way
; for input to arrive reports a deadlock).

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

C_BRK = 0x0010                          ; console break port
C_REL = 0x0018                          ; console release port

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
kbuf:   .dword 0                        ; break read

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        li    t1, 1                     ; core 1?
        beq   t0, t1, spinner           ; core 1 keeps the machine busy
        bnez  t0, park                  ; the other cores stop
        la    s2, kbuf                  ; s2 = break buffer
        li    t0, -1                    ; fill it with ones
        sd    t0, 0(s2)                 ; so the completion is visible
        li    t0, C_BRK                 ; break port
        li    t1, 8                     ; 8 bytes
        tget  tg2, s2, c3, t0, t1       ; wait for Ctrl-C
        ld    a0, 0(s2)                 ; the load waits until it completes
        li    a1, 0x0303030303030303    ; Ctrl-C: 0x03 bytes
        call  chk                       ; check
        li    t0, -1                    ; refill
        sd    t0, 0(s2)                 ; ones
        li    t0, C_BRK                 ; break port
        li    t1, 8                     ; 8 bytes
        tget  tg2, s2, c3, t0, t1       ; a second read: the one press was used up
        tpoll a0, tg2                   ; pending
        li    a1, 1 << 2                ; tag 2 busy
        call  chk                       ; check
        li    a0, C_REL                 ; release
        li    a1, 0                     ; (ignored)
        call  devwr                     ; completes it with 0
        ld    a0, 0(s2)                 ; the value
        li    a1, 0                     ; 0
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
spinner:
        li    t2, 300000                ; long enough to cover the press on every machine
sp_loop:
        addi  t2, t2, -1                ; count down
        bnez  t2, sp_loop               ; loop
        j     park                      ; then stop
