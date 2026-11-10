; =============================================================================
; pend.s: CCR.PTRAP turns a hazard stall into a precise `pend` trap (cause 9)
; =============================================================================
;
; What it checks (manual: ch-memory.tex "For debugging, setting bit 0 of CSR
; ccr (PTRAP) turns the stall ..."; gen-insns-ls.tex, exception `pend`)
;   * With CCR bit 0 set, a load or store touching bytes a transfer is still
;     filling traps with cause 9, tval = the Local Store address, instead of
;     waiting. A console break read that no Ctrl-C completes stays in flight
;     for as long as we like, so the trap is deterministic on every machine.
;   * Bytes outside the in-flight range are not affected.
;   * With CCR bit 0 clear the access waits as usual (after a release
;     completes the read with 0).
; Core 1 holds a copy of the device capability and, after a long delay,
; writes the release port as well, so a machine that stalls instead of
; trapping still finishes (and reports what it did) rather than deadlocking.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

C_BRK = 0x0010                          ; console break port
C_REL = 0x0018                          ; console release port

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
kbuf:   .dword -1, 0x1234               ; break read target, and a word after it

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        li    t1, 1                     ; core 1?
        beq   t0, t1, rescuer           ; core 1 releases late
        bnez  t0, park                  ; the other cores stop
        li    t0, 1                     ; core 1
        cgive c3, t0                    ; give it a copy of the device capability (c3 has D)
        li    t0, 1                     ; PTRAP
        csrw  ccr, t0                   ; set CCR bit 0
        csrr  a0, ccr                   ; read back
        li    a1, 1                     ; expected
        call  chk                       ; check
        la    s1, kbuf                  ; s1 = break buffer
        li    t0, C_BRK                 ; break port
        li    t1, 8                     ; 8 bytes
        tget  tg2, s1, c3, t0, t1       ; a read that stays in flight
        li    s2, 0x5a5a                ; marker
pd1:    ld    s2, 0(s1)                 ; load from the in-flight bytes
        li    a0, C_PEND                ; expected cause
        la    a1, pd1                   ; expected epc
        mv    a2, s1                    ; expected tval: the address
        call  chkt                      ; check
        mv    a0, s2                    ; the load's destination
        li    a1, 0x5a5a                ; unchanged
        call  chk                       ; check
pd2:    sw    zero, 4(s1)               ; store into the in-flight bytes
        li    a0, C_PEND                ; expected cause
        la    a1, pd2                   ; expected epc
        addi  a2, s1, 4                 ; expected tval
        call  chkt                      ; check
        ld    a0, 8(s1)                 ; the word after the range: no hazard
        li    a1, 0x1234                ; expected
        call  chk                       ; check
        csrw  ccr, zero                 ; PTRAP off
        li    a0, C_REL                 ; release
        li    a1, 0                     ; (ignored)
        call  devwr                     ; completes the break read with 0
        ld    a0, 0(s1)                 ; waits if needed, then reads
        li    a1, 0                     ; the released value (the trapped store wrote nothing)
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
rescuer:
        ctake c3                        ; the device capability
        li    t2, 50000                 ; a long delay
rs_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, rs_spin               ; loop
        la    t0, dbuf                  ; a buffer
        li    t1, 8                     ; 8 bytes
        li    t3, C_REL                 ; release port
        tput  tg1, t0, c3, t3, t1       ; release whatever break read still waits
        j     park                      ; done
