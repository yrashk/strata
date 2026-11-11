; =============================================================================
; mc.s: several cores: gifts, per-sender inbox queues, ctake from a named
; sender, cpoll, tany on the inbox, core windows, core-control stop
; =============================================================================
;
; What it checks
;   * cgive cs, rx moves a linear capability into core x's inbox (queue of
;     the giving core); ctake cd takes the oldest gift of the lowest-numbered
;     sender that has one; ctake cd, rx only from sender x; takefrom = the
;     sender. Each sender has its own FIFO queue, so a sender that fills its
;     queue never blocks a gift another sender makes (core 0 takes core 3's
;     gift by name while core 2's third gift waits for room).
;   * cpoll: bit n set when sender n has a gift waiting.
;   * tany with bit 16 waits until a gift arrives, then returns bit 16.
;   * Core windows: with corebase = b, corecount = n, user code sees coreid -
;     b and ncores = n, and cgive targets 0..n-1 (relative): n or more is
;     capop (tval = the relative number).
;   * Core control (c4, core 0 only): writing a word with bit 0 set at offset
;     8k stops core k: a core running in user mode traps to its supervisor
;     with cause 13 (stop).
;   * Revocation is machine-wide: a capability another core holds dies when
;     the granule its base lies in is revoked.
;   * cgive to a core that has halted: capop (tval = the core).
; Only core 0 prints; the other cores report through memory they are given.
; Roles: core 1 worker + user mode + stop, core 2 fills its queue, core 3 a
; single gift and a revoked capability, core 4 halts at once, cores 5 and 6 race for cpoll / ctake,
; core 7 a delayed gift for tany.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store (each core has its own copy)
        .align 8                        ; transfer buffers
res:    .space 64                       ; results to send back (core 1)
rbuf:   .space 64                       ; results read back (core 0)
one:    .dword 1                        ; a core-control word: bit 0 = stop

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        beqz  t0, boss                  ; core 0 runs the test
        li    t1, 1                     ; dispatch the others by number
        beq   t0, t1, w1                ; core 1
        li    t1, 2                     ; core 2
        beq   t0, t1, w2                ; core 2
        li    t1, 4                     ; core 4 halts at once
        beq   t0, t1, park              ; halt
        li    t1, 7                     ; core 7
        beq   t0, t1, w7                ; core 7
        li    t1, 3                     ; core 3
        beq   t0, t1, w3                ; core 3
        li    t1, 8                     ; cores 5, 6 return what they are given
        blt   t0, t1, wret              ; echo
        j     park                      ; (more cores than 8: they stop)

; =============================================================================
; core 0
; =============================================================================
boss:
        li    t0, 0x200000              ; 2 MiB
        csplit c5, c0, t0               ; c0 = [0, 2M), c5 = the rest
        cmov  c15, c5                   ; c15 = the pool of memory to hand out
        li    s11, 0x200000             ; s11 = the pool's base (for checks)

; ---- 1. worker core 1: give it memory, get it back with results ----------------------
        li    a0, 64                    ; a 64-byte piece
        call  piece                     ; c5 = the next piece of the pool
        li    t0, 1                     ; core 1
        cgive c5, t0                    ; give it
        cvalid a0, c5                   ; linear: gone from here
        li    a1, 0                     ; empty
        call  chk                       ; check
        li    t0, 1                     ; from core 1
        ctake c5, t0                    ; wait for it to come back
        csrr  a0, takefrom              ; sender
        li    a1, 1                     ; core 1
        call  chk                       ; check
        la    t1, rbuf                  ; read the results
        li    t2, 16                    ; two words
        tget  tg1, t1, c5, zero, t2     ; get them
        ld    a0, 0(t1)                 ; core 1's coreid
        li    a1, 1                     ; 1
        call  chk                       ; check
        ld    a0, 8(t1)                 ; its marker
        li    a1, 0x1111                ; expected
        call  chk                       ; check
        cclear c5                       ; done with it

; ---- 2. per-sender queues: core 2 gives 3 pieces (its queue holds 2), core 3 one ---------
        li    a0, 48                    ; 48 bytes: core 2 splits it into 8 + 16 + 24
        call  piece                     ; c5
        li    t0, 2                     ; core 2
        cgive c5, t0                    ; give
        li    a0, 8                     ; 8 bytes for core 3 to echo
        call  piece                     ; c5
        li    t0, 3                     ; core 3
        cgive c5, t0                    ; give
        li    t0, 3                     ; take core 3's gift by name, whatever core 2 does
        ctake c6, t0                    ; (with one shared queue, core 2 could fill it: deadlock)
        clen  a0, c6                    ; core 3's piece
        li    a1, 8                     ; 8 bytes
        call  chk                       ; check
        cclear c6                       ; drop it
        li    t0, 2                     ; now core 2's three, in order
        ctake c6, t0                    ; first
        clen  a0, c6                    ; length
        li    a1, 8                     ; A = 8 bytes
        call  chk                       ; check
        ctake c7, t0                    ; second
        clen  a0, c7                    ; length
        li    a1, 16                    ; B = 16 bytes
        call  chk                       ; check
        ctake c8, t0                    ; third (it waited for room in core 2's queue)
        clen  a0, c8                    ; length
        li    a1, 24                    ; C = 24 bytes
        call  chk                       ; check
        cjoin c6, c7                    ; A + B (adjacent, same perms)
        cjoin c6, c8                    ; + C
        clen  a0, c6                    ; the original 48 bytes again
        li    a1, 48                    ; expected
        call  chk                       ; check
        cclear c6                       ; drop it

; ---- 3. cpoll and ctake-any: cores 5 and 6 both give; the lower sender is taken first -----
        li    a0, 8                     ; a piece for core 5
        call  piece                     ; c5
        li    t0, 5                     ; core 5
        cgive c5, t0                    ; give
        li    a0, 16                    ; a piece for core 6
        call  piece                     ; c5
        li    t0, 6                     ; core 6
        cgive c5, t0                    ; give
        li    t1, 1 << 5 | 1 << 6       ; both senders
cp_wait:
        cpoll a0                        ; who has a gift waiting?
        and   t2, a0, t1                ; senders 5 and 6
        bne   t2, t1, cp_wait           ; until both
        li    a1, 1 << 5 | 1 << 6       ; exactly those two
        call  chk                       ; check
        ctake c6                        ; any sender: the lowest-numbered first
        csrr  a0, takefrom              ; sender
        li    a1, 5                     ; core 5
        call  chk                       ; check
        clen  a0, c6                    ; its piece
        li    a1, 8                     ; 8 bytes
        call  chk                       ; check
        cpoll a0                        ; who is left
        li    a1, 1 << 6                ; core 6
        call  chk                       ; check
        ctake c7                        ; any sender
        csrr  a0, takefrom              ; sender
        li    a1, 6                     ; core 6
        call  chk                       ; check
        cclear c6                       ; drop
        cclear c7                       ; drop
        cpoll a0                        ; inbox empty
        li    a1, 0                     ; nothing
        call  chk                       ; check

; ---- 4. tany on the inbox: core 7 gives back after a delay --------------------------------
        li    a0, 8                     ; a piece for core 7
        call  piece                     ; c5
        li    t0, 7                     ; core 7
        cgive c5, t0                    ; give
        li    t0, 1 << 16               ; the inbox only
        tany  a0, t0                    ; wait until a gift arrives
        li    a1, 1 << 16               ; bit 16
        call  chk                       ; check
        li    t0, 7                     ; from core 7
        ctake c6, t0                    ; take it
        clen  a0, c6                    ; the piece
        li    a1, 8                     ; 8 bytes
        call  chk                       ; check
        cclear c6                       ; drop

; ---- 4b. revocation reaches capabilities other cores hold ---------------------------------
        li    t0, 0x40000               ; one revocation granule (256 KiB) of [0, 2M)
        csplit c5, c0, t0               ; c0 = [0, 256K), c5 = [256K, 2M)
        cclear c5                       ; (not needed)
        cmov  c5, c0                    ; c5 = [0, 256K): granule-aligned, plain
        cdom  c6, c5                    ; c5 = revoker, c6 = working capability (revocable)
        li    t0, 3                     ; core 3
        cgive c6, t0                    ; core 3 holds the working capability
        ctake c7, t0                    ; its token: "holding it"
        cclear c7                       ; drop the token
        crevoke c8, c5                  ; revoke the region: core 3's copy dies too
        cgive c2, t0                    ; token to core 3: "look at it now"
        ctake c7, t0                    ; its report: the dead capability can't be given, so
        clen  a0, c7                    ; core 3 sends its console copy (length 1) instead
        li    a1, 1                     ; expected: the held capability was dead
        call  chk                       ; check
        cclear c7                       ; drop the report
        cclear c8                       ; drop the fresh working capability
        cundom c9, c5                   ; dissolve it (c9 = plain region)
        cclear c9                       ; drop it

; ---- 5. core 1 in user mode, in a core window; stop it through core control ----------------
        li    a0, 64                    ; a piece for core 1's results
        call  piece                     ; c5
        li    t0, 1                     ; core 1
        cgive c5, t0                    ; give
        li    t0, 1                     ; core 1 says when it is ready to be stopped
        ctake c6, t0                    ; its token
        cclear c6                       ; drop it
        la    t0, one                   ; a word with bit 0 set
        li    t1, 8                     ; offset 8 = core 1's control word
        li    t2, 8                     ; one word
        tput  tg2, t0, c4, t1, t2       ; stop core 1 (taken as soon as it is in user mode)
        li    t0, 1                     ; from core 1
        ctake c5, t0                    ; its results
        la    s1, rbuf                  ; read them
        li    t2, 48                    ; six words
        tget  tg1, s1, c5, zero, t2     ; get
        ld    a0, 0(s1)                 ; user coreid in the window [1, 3)
        li    a1, 0                     ; 1 - corebase 1
        call  chk                       ; check
        ld    a0, 8(s1)                 ; user ncores
        li    a1, 2                     ; = corecount
        call  chk                       ; check
        ld    a0, 16(s1)                ; cause of cgive to window core 2
        li    a1, C_CAPOP               ; outside the window
        call  chk                       ; check
        ld    a0, 24(s1)                ; its tval
        li    a1, 2                     ; the relative core number
        call  chk                       ; check
        ld    a0, 32(s1)                ; cause of the stop
        li    a1, C_STOP                ; 13
        call  chk                       ; check
        ld    a0, 40(s1)                ; tval of the stop
        li    a1, 0                     ; 0
        call  chk                       ; check

; ---- 6. giving to a halted core ---------------------------------------------------------------
        li    t0, 4                     ; core 4 halted at start
mc6:    cgive c5, t0                    ; give to it
        li    a0, C_CAPOP               ; expected cause
        la    a1, mc6                   ; expected epc
        li    a2, 4                     ; expected tval: the core
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict

; piece(a0 = bytes): c5 = the next a0 bytes of the pool c15
piece:
        csplit c5, c15, a0              ; c15 = the first a0 bytes, c5 = the rest
        cmov  c14, c5                   ; c14 = the rest
        cmov  c5, c15                   ; c5 = the piece
        cmov  c15, c14                  ; c15 = the rest of the pool
        ret                             ; back

; =============================================================================
; core 1: worker, then user mode in a window until stopped
; =============================================================================
w1:
        ctake c5                        ; wait for memory from core 0
        csrr  t0, coreid                ; our core number
        la    t1, res                   ; results
        sd    t0, 0(t1)                 ; word 0: coreid
        li    t0, 0x1111                ; word 1: a marker
        sd    t0, 8(t1)                 ; store
        li    t2, 16                    ; two words
        tput  tg1, t1, c5, zero, t2     ; write them into the piece
        li    t0, 0                     ; core 0
        cgive c5, t0                    ; give it back (the put is as if done)
        ctake c5                        ; memory for the second part
        li    t0, 1                     ; corebase 1
        csrw  corebase, t0              ; window starts at core 1
        li    t0, 2                     ; corecount 2: cores 1 and 2
        csrw  corecount, t0             ; window size
        la    t0, w1_back               ; where `svc` with a7 = UEXIT continues
        sd    t0, uexit(zero)           ; (supervisor)
        la    a0, w1_user               ; user entry
        call  to_user                   ; enter user mode
w1_user:
        la    s1, res                   ; results
        csrr  t0, coreid                ; relative core number
        sd    t0, 0(s1)                 ; res[0]
        csrr  t0, ncores                ; window size
        sd    t0, 8(s1)                 ; res[1]
        li    t0, 2                     ; relative core 2: outside a 2-core window
        cgive c2, t0                    ; capop, to the supervisor (recorded), back here
        ld    t0, tcause(zero)          ; the cause
        sd    t0, 16(s1)                ; res[2]
        ld    t0, ttval(zero)           ; the tval
        sd    t0, 24(s1)                ; res[3]
        li    a7, UEXIT                 ; back to the supervisor
        svc                             ; (not recorded)
w1_back:                                ; supervisor mode
        csrw  corebase, zero            ; leave the window
        csrw  corecount, zero           ; (supervisor)
        la    t0, w1_stopped            ; where the supervisor continues after the stop
        sd    t0, tresume(zero)         ; (the next recorded trap: the stop)
        li    t0, 0                     ; tell core 0 we are ready to be stopped
        cgive c2, t0                    ; a copy of the console capability as the token
        la    a0, w1_spin               ; user entry
        call  to_user                   ; spin in user mode
w1_spin:
        j     w1_spin                   ; wait for the stop (it may come before the first spin)
w1_stopped:                             ; supervisor mode again
        la    s1, res                   ; results
        ld    t0, tcause(zero)          ; the stop's cause
        sd    t0, 32(s1)                ; res[4]
        ld    t0, ttval(zero)           ; its tval
        sd    t0, 40(s1)                ; res[5]
        li    t2, 48                    ; six words
        tput  tg1, s1, c5, zero, t2     ; into the piece
        li    t0, 0                     ; core 0
        cgive c5, t0                    ; back
        j     park                      ; done

; =============================================================================
; core 2: split a 48-byte piece in three and give them all back in order
; =============================================================================
w2:
        ctake c5                        ; 48 bytes from core 0
        li    t0, 8                     ; A = first 8 bytes
        csplit c6, c5, t0               ; c5 = A, c6 = 40 bytes
        li    t0, 16                    ; B = next 16
        csplit c7, c6, t0               ; c6 = B, c7 = C (24 bytes)
        li    t0, 0                     ; core 0
        cgive c5, t0                    ; A: queue 1 of 2
        cgive c6, t0                    ; B: queue full
        cgive c7, t0                    ; C: waits until core 0 takes A
        j     park                      ; done

; =============================================================================
; core 3: give back a gift; then hold a revocable capability
; and report whether it is still valid after core 0 revoked its region
; =============================================================================
w3:
        ctake c5                        ; from core 0
        li    t0, 0                     ; core 0
        cgive c5, t0                    ; back
        ctake c6                        ; the region's working capability
        cgive c2, t0                    ; token: "holding it"
        ctake c7                        ; token: "look now"
        cvalid t1, c6                   ; still valid?
        bnez  t1, w3_alive              ; (it must not be)
        cgive c2, t0                    ; dead: report with the console copy (length 1)
        j     park                      ; done
w3_alive:
        cgive c6, t0                    ; alive: report with the capability itself (64 bytes)
        j     park                      ; done

; =============================================================================
; cores 5, 6: give back what they are given
; =============================================================================
wret:
        ctake c5                        ; from core 0
        li    t0, 0                     ; core 0
        cgive c5, t0                    ; back
        j     park                      ; done

; =============================================================================
; core 7: give back after a delay (core 0 waits in tany meanwhile)
; =============================================================================
w7:
        ctake c5                        ; from core 0
        li    t2, 5000                  ; a delay
w7_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, w7_spin               ; loop
        li    t0, 0                     ; core 0
        cgive c5, t0                    ; back
        j     park                      ; done
