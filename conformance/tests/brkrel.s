; =============================================================================
; brkrel.s: one release with break reads waiting on two cores
; =============================================================================
;
; What it checks (FINDINGS F4, doc/strataos.md 1.2: one write to the
; release port completes EVERY break read waiting at that moment, on every
; core, with 0)
;   * Core 1 (given a copy of the device capability) and core 0 both wait on
;     the break port. One write to the release port completes both reads
;     with 0: core 0's tag is idle shortly after, and core 1's report (a
;     gift sent once its read completed) is in core 0's inbox (cpoll).
; A second release later completes anything still waiting, so a machine
; that completes only one read still finishes (and fails the cpoll check).

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

C_BRK = 0x0010                          ; console break port
C_REL = 0x0018                          ; console release port

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
kbuf:   .dword -1                       ; break read target

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        li    t1, 1                     ; core 1?
        beq   t0, t1, other             ; core 1 waits on the break port too
        bnez  t0, park                  ; the other cores stop
        li    t0, 1                     ; core 1
        cgive c3, t0                    ; a copy of the device capability
        li    t0, 1                     ; from core 1
        ctake c5, t0                    ; "my break read is in flight"
        la    s1, kbuf                  ; s1 = buffer
        li    t0, C_BRK                 ; break port
        li    t1, 8                     ; 8 bytes
        tget  tg2, s1, c3, t0, t1       ; our own break read
        li    a0, C_REL                 ; release
        li    a1, 0                     ; (ignored)
        call  devwr                     ; once
        li    t2, 2000                  ; let it settle
br_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, br_spin               ; loop
        tpoll a0, tg2                   ; our read: completed by the one release?
        li    a1, 0                     ; expected: yes (idle)
        call  chk                       ; check
        li    t2, 100                   ; a bounded wait for core 1's report
br_poll:
        cpoll a0                        ; core 1's report: bit 1
        bnez  a0, br_got                ; there
        addi  t2, t2, -1                ; count down
        bnez  t2, br_poll               ; again (a machine that completed only one read gives up)
br_got:
        li    a1, 2                     ; expected: core 1's read completed too
        call  chk                       ; check
        li    a0, C_REL                 ; a second release: completes whatever still waits
        li    a1, 0                     ; (ignored)
        call  devwr                     ; release
        li    t0, 1                     ; core 1's report
        ctake c6, t0                    ; take it
        li    t2, 2000                  ; let any other release race settle
br_spin2:
        addi  t2, t2, -1                ; count down
        bnez  t2, br_spin2              ; loop
        li    a0, C_REL                 ; a third release: nothing waits (dropped)
        li    a1, 0                     ; (ignored)
        call  devwr                     ; release
        ld    a0, 0(s1)                 ; our read's value
        li    a1, 0                     ; released: 0
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
other:
        ctake c3                        ; the device capability
        la    s1, kbuf                  ; buffer
        li    t0, C_BRK                 ; break port
        li    t1, 8                     ; 8 bytes
        tget  tg2, s1, c3, t0, t1       ; wait for Ctrl-C or a release
        li    t0, 0                     ; core 0
        cgive c2, t0                    ; "in flight"
        twait tg2                       ; wait for it to complete
        li    t0, 0                     ; core 0
        cgive c2, t0                    ; "completed"
        j     park                      ; done
