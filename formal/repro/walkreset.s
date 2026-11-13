; =============================================================================
; walkreset.s: a revocation walk that outlives its core's reset
; =============================================================================
; The reproduction of formal/FINDINGS.md F1. Needs 4 KiB Local Stores (the
; reset sequencer is then shorter than the longest walk) and two cores:
;   formal/repro/run.sh
;
; Core 0 starts the longest walk there is (crevoke with the revoker of the
; last granule of a unit that is all of system memory: back over 255
; granules, then over all 256 twice, about 770 cycles). Core 1 resets core 0
; while the walk runs. Core 0 is back about 520 cycles later, sees core 1's
; token in its inbox and asks for a walk of its own (cdom over all of system
; memory, with the reset capability c0).
;
; Before the fix the RTL gave the first walk's done to that cdom: the cdom
; ended at once, with the first walk's generation and without a walk of its
; own, so the head the crevoke left at granule 255 was still there. The
; working capability, cut there and joined again, then trapped with capop
; (cjoin never joins across a head). On the emulator, and on the RTL now,
; the cdom rewrites the unit and the join works.
;
; Expected output: ok

DELAY = 100                             ; core 1's wait, about 6 cycles each: into the walk

        .data                           ; data Local Store (inside the boot ROM: a reset restores it)
        .align 8                        ; a transfer buffer
word:   .dword 2                        ; a core-control word: bit 1 is the reset request
ok:     .ascii "ok\n"                   ; what core 0 prints at the end

        .text                           ; instruction Local Store
_start:
        csrr  s0, coreid                ; which core?
        li    t0, 1                     ; ...
        beq   s0, t0, core1             ; core 1 resets core 0
        bnez  s0, park                  ; any other core has nothing to do
        cpoll t0                        ; a gift waiting? then this is the run after the reset
        bnez  t0, again                 ; ...
        li    t0, 1                     ; core 1
        cgive c4, t0                    ; core control to core 1 (c4 is copyable: a copy)
        cdom  c5, c0                    ; all of system memory revocable; c0 becomes its revoker
        li    t1, 0x3FC0000             ; the last granule's offset (255 * 256 KiB)
        csplit c6, c0, t1               ; c6 = the revoker of the last granule alone
        crevoke c7, c6                  ; the long walk; the reset arrives during it
park:   halt                            ; (not reached on core 0 if the reset is in time)

again:  cdom  c5, c0                    ; c0 is the reset capability again: a walk of our own
        li    t1, 0x3FC0000             ; where the old walk left a head
        csplit c6, c5, t1               ; cut the working capability there
        cjoin c5, c6                    ; and join it: one unit after our cdom, so this works
        la    t0, ok                    ; say so
        li    t1, 3                     ; ...
        tput  tg1, t0, c2, zero, t1     ; ...
        halt                            ; (drains the transfer first)

core1:  ctake c5, zero                  ; core control, from core 0
        li    t0, DELAY                 ; wait until core 0 is in its crevoke
spin:   addi  t0, t0, -1                ; ...
        bnez  t0, spin                  ; ...
        la    t0, word                  ; the reset request
        li    t1, 8                     ; one word
        tput  tg1, t0, c5, zero, t1     ; to core 0 (offset 0 of core control)
        cgive c2, zero                  ; a token for the restarted core 0 (given after the request took effect)
        halt                            ; done
