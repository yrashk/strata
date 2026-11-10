; =============================================================================
; pendxfer.s: a transfer touching the Local Store range of an in-flight
; device read is ordered after it (as if synchronous)
; =============================================================================
;
; What it checks (FINDINGS F5, doc/strataos-0.2.md 1.2: a transfer whose
; D-LS range overlaps an in-flight device read of the same core waits at
; issue until that read completes, as loads and stores do)
;   A. A break read is in flight into kbuf. A tput of kbuf issued after it
;      must send what the read delivers (here 0, from a release), not the
;      bytes kbuf held before.
;   B. A break read is in flight into kbuf. A memory tget into kbuf issued
;      after it must win: kbuf ends up with the tget's data, not the value
;      the break read delivers later.
;   C. With CCR.PTRAP set, a tput of kbuf while a break read into it is in
;      flight traps pend (tval = the D-LS address), as a load would.
; Core 1 writes the release port after long delays (three times), so a
; machine that makes the transfer wait still finishes.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

C_BRK = 0x0010                          ; console break port
C_REL = 0x0018                          ; console release port

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
kbuf:   .dword -1                       ; break read target
gbuf:   .dword 0                        ; read-back buffer
val:    .dword 0x5555                   ; data for part B

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        li    t1, 1                     ; core 1?
        beq   t0, t1, rescuer           ; core 1 releases late
        bnez  t0, park                  ; the other cores stop
        li    t0, 1                     ; core 1
        cgive c3, t0                    ; a copy of the device capability
        la    s1, kbuf                  ; s1 = break buffer
        la    s2, gbuf                  ; s2 = read-back buffer
        li    s3, 8                     ; 8 bytes
; ---- A. tput from the in-flight range ----------------------------------------------------
        li    t0, C_BRK                 ; break port
        tget  tg2, s1, c3, t0, s3       ; in flight until core 1 releases it
        li    t1, 0x100                 ; T3 offset
        tput  tg3, s1, c0, t1, s3       ; send kbuf: must carry the read's result
        twait tg2, tg3                  ; both done
        tget  tg4, s2, c0, t1, s3       ; read T3 back
        ld    a0, 0(s2)                 ; what the tput sent
        li    a1, 0                     ; the released value, not the old ones
        call  chk                       ; check
; ---- B. tget into the in-flight range ------------------------------------------------------
        li    t0, -1                    ; refill kbuf
        sd    t0, 0(s1)                 ; with ones
        la    t2, val                   ; 0x5555
        li    t1, 0x108                 ; T3 offset
        tput  tg3, t2, c0, t1, s3       ; T3[0x108] = 0x5555
        li    t0, C_BRK                 ; break port
        tget  tg2, s1, c3, t0, s3       ; in flight until core 1 releases it again
        tget  tg3, s1, c0, t1, s3       ; kbuf = 0x5555: issued later, so it wins
        twait tg2, tg3                  ; both done
        ld    a0, 0(s1)                 ; the final contents
        li    a1, 0x5555                ; the later transfer's data
        call  chk                       ; check
; ---- C. with PTRAP, the overlapping transfer traps pend ----------------------------------------
        li    t0, C_BRK                 ; break port
        tget  tg2, s1, c3, t0, s3       ; in flight until core 1 releases it a third time
        li    t0, 1                     ; CCR.PTRAP
        csrw  ccr, t0                   ; on
        li    t1, 0x110                 ; T3 offset
pxc:    tput  tg3, s1, c0, t1, s3       ; overlaps the in-flight read: traps
        csrw  ccr, zero                 ; PTRAP off
        li    a0, C_PEND                ; expected cause
        la    a1, pxc                   ; expected epc
        mv    a2, s1                    ; expected tval: the D-LS address
        call  chkt                      ; check
        twait tg2                       ; the third release
        j     done                      ; print the signature and the verdict
rescuer:
        ctake c3                        ; the device capability
        li    s4, 3                     ; three releases
rs_again:
        li    t2, 50000                 ; a long delay
rs_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, rs_spin               ; loop
        la    t0, dbuf                  ; a buffer
        li    t1, 8                     ; 8 bytes
        li    t3, C_REL                 ; release port
        tput  tg1, t0, c3, t3, t1       ; release
        addi  s4, s4, -1                ; one fewer
        bnez  s4, rs_again              ; again
        j     park                      ; done
