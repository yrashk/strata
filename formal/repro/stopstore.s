; =============================================================================
; stopstore.s: a store that a stop preempts must not have written
; =============================================================================
; The reproduction of formal/FINDINGS.md F2. Two cores, any Local Store size:
;   formal/repro/run.sh
;
; Core 0 runs a three-instruction loop in user mode: count up, store the
; count into `cell`, jump back. Core 1 stops it again and again through core
; control, each time a cycle later in core 0's loop. The supervisor's
; handler looks at every stop that was taken at the store (epc = usd): the
; store has not executed then, so `cell` must still hold the previous count.
;
; Before the fix the RTL wrote the Local Store in the cycle it took the stop
; (a stop request that arrived during the store's fetch), so the handler saw
; the new count in `cell` under an instruction that had not run. The
; emulator takes a stop only between instructions.
;
; Expected output: ok

NSTOP = 36                              ; stops sent: every phase of the 9-cycle loop, four times

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
one:    .dword 1                        ; a core-control word: bit 0 is the stop request
cell:   .dword 0                        ; what the user loop stores into
okm:    .ascii "ok\n"                   ; the verdicts
badm:   .ascii "bad\n"                  ; ...

        .text                           ; instruction Local Store
_start:
        csrr  s0, coreid                ; which core?
        li    t0, 1                     ; ...
        beq   s0, t0, core1             ; core 1 sends the stops
        bnez  s0, park                  ; any other core has nothing to do
        la    t0, handler               ; the supervisor's trap handler
        csrw  tvec, t0                  ; ...
        li    t0, 1                     ; core 1
        cgive c4, t0                    ; core control to core 1 (a copy)
        la    s3, cell                  ; the user loop's pointer
        csrw  status, zero              ; previous mode: user
        la    t0, uloop                 ; where eret goes
        csrw  epc, t0                   ; ...
        eret                            ; into user mode

uloop:  addi  s2, s2, 1                 ; the next count
usd:    sd    s2, 0(s3)                 ; store it
        j     uloop                     ; for ever (until the supervisor has seen enough)

handler:                                ; supervisor: a stop (nothing else traps here)
        csrr  t5, epc                   ; where was it taken?
        la    t6, usd                   ; at the store?
        bne   t5, t6, hnext             ; no: nothing to check
        ld    t5, 0(s3)                 ; the store has not run: the cell holds the count before
        beq   t5, s2, bad               ; the new count already: the store wrote
hnext:  cpoll t5                        ; core 1's token: it has sent them all
        bnez  t5, good                  ; ...
        eret                            ; back into the loop, at the same instruction
good:   la    t0, okm                   ; every stop at the store found the old count
        li    t1, 3                     ; ...
        j     say                       ; ...
bad:    la    t0, badm                  ; a preempted store had written
        li    t1, 4                     ; ...
say:    tput  tg1, t0, c2, zero, t1     ; the verdict
park:   halt                            ; (drains the transfer first)

core1:  ctake c5, zero                  ; core control, from core 0
        la    s1, one                   ; the stop word
        li    s2, NSTOP                 ; stops to send
c1next: mv    t0, s2                    ; wait s2 rounds of 10 cycles: one cycle later in core 0's
c1spin: ld    t1, 0(s1)                 ;   9-cycle loop each time (a load takes 4 cycles,
        addi  t0, t0, -1                ;   the other two 3 each)
        bnez  t0, c1spin                ; ...
        li    t1, 8                     ; one word
        tput  tg1, s1, c5, zero, t1     ; stop core 0 (offset 0 of core control)
        addi  s2, s2, -1                ; the next one
        bnez  s2, c1next                ; ...
        cgive c2, zero                  ; the token: the handler ends at the next stop
        li    t0, 200                   ; well after the last stop was taken
c1last: addi  t0, t0, -1                ; ...
        bnez  t0, c1last                ; ...
        li    t1, 8                     ; one more stop, for the handler to see the token
        tput  tg1, s1, c5, zero, t1     ; ...
        halt                            ; done
