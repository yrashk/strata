; =============================================================================
; race.s: the data races that cannot be written
; =============================================================================
;
; What it shows
;   * The classic lost-update race is impossible. Shared mutable state must
;     live in an *atomic* segment, and an atomic capability allows only
;     `tamo` operations, which execute indivisibly at the memory. Both cores
;     add 1 a thousand times and the counter ends at exactly 2000, every run.
;     A plain read-modify-write of the counter isn't merely discouraged:
;     there is no instruction that can express it. Core 1 tries a plain
;     `tput` through the atomic capability and traps with `perm`.
;   * Use-after-give is impossible. Core 0 gives a buffer to core 1 and then
;     tries to write to it anyway. Its capability register is already empty,
;     so the write traps with `capinv`. The bytes never move.
;   * Hand-off implies visibility. Core 1 writes a message into the buffer
;     and gives the buffer back. Core 0 reads it and is guaranteed to see the
;     message, because `cgive` completes only after core 1's write has landed.
;
; Expected output (all printed by core 0):
;   core 0 writes a buffer it gave away   -> capinv
;   shared counter after 2 x 1000 adds    = 2000
;   core 1 plain store to the counter     -> perm
;   message from core 1: core 1 says hi through owned T3

ADDS    = 1000                          ; increments per core

        .data                           ; data Local Store (one per core)
        .align 8                        ; transfer buffers must be aligned
buf:    .space 32                       ; scratch buffer for transfers
msg:    .ascii "core 1 says hi through owned T3\n" ; exactly 32 bytes, a multiple of 8
names:  .ascii "none    illegal lsfault capinv  perm    bounds  xalign  ifault  xmiss   pend    capop   "  ; cause names, 8 characters each, indexed by cause number
l_gave: .ascii "core 0 writes a buffer it gave away   -> "  ; output text
l_gave_e:                               ; end of the text above (its length = end - start)
l_cnt:  .ascii "shared counter after 2 x 1000 adds    = "  ; output text
l_cnt_e:                                ; end of the text above (its length = end - start)
l_plain:.ascii "core 1 plain store to the counter     -> "  ; output text
l_plain_e:                              ; end of the text above (its length = end - start)
l_msg:  .ascii "message from core 1: "  ; output text
l_msg_e:                                ; end of the text above (its length = end - start)

m_need: .ascii "this example needs at least 2 cores\n" ; output text
m_need_e:                               ; end of the text above

        .text                           ; instruction Local Store
_start:                                 ; entry point: every core starts executing here, at I-LS address 0
        li    sp, 65536                 ; stack at the top of D-LS
        csrr  t0, ncores                ; how many cores are there?
        li    t1, 2                     ; this example needs two
        bge   t0, t1, enough            ; fine
        la    a0, m_need                ; otherwise say so
        li    a1, m_need_e - m_need     ; its length
        call  print_str                 ; print it
        li    a0, 1                     ; exit code 1
        halt                            ; and stop
enough:
        la    t0, handler               ; t0 = trap handler
        csrw  tvec, t0                  ; both cores record traps instead of stopping
        li    s1, 1                     ; s1 = 1, the increment
        la    s5, buf                   ; s5 = scratch buffer
        csrr  t0, coreid                ; which core?
        li    t1, 1                     ; core 1 has its own script
        beq   t0, t1, core1             ; go run it
        bnez  t0, idle                  ; cores 2 and up are not needed

; =============================== core 0 =========================================
        li    t0, 16                    ; t0 = two words
        csplit c4, c0, t0               ; c0 = [0, 16), c4 = the rest of T3
        catomic c6, c0                  ; c6 = atomic, copyable view of [0,16): word 0 counter, word 1 report
        li    t0, 32                    ; t0 = 32 bytes
        csplit c5, c4, t0               ; c4 = a 32-byte buffer, c5 = the rest
        cmov  c7, c4                    ; c7 = the buffer
        li    t1, 1                     ; t1 = core 1
        cgive c6, t1                    ; give core 1 a copy of the atomic capability (we keep ours)
        cgive c7, t1                    ; give core 1 the buffer itself (c7 is now empty)

        li    s11, 0                    ; clear the recorded trap cause
        li    t0, 8                     ; t0 = 8 bytes
        tput  tg0, s5, c7, zero, t0     ; try to write into the buffer we just gave away
        la    a0, l_gave                ; describe the attempt
        li    a1, l_gave_e - l_gave     ; label length
        call  print_cause               ; print it with the cause the handler recorded

        li    s2, ADDS                  ; s2 = increments left
c0_add:                                 ; loop: core 0 increments
        tamo.add zero, c6, zero, s1     ; counter += 1, performed at the memory
        addi  s2, s2, -1                ; one fewer
        bnez  s2, c0_add                ; until done (core 1 is adding at the same time)

        ctake c7                        ; wait for the buffer to come back: core 1 has finished
        tamo.add a2, c6, zero, zero     ; a2 = counter (atomic add of zero = atomic read)
        la    a0, l_cnt                 ; label
        li    a1, l_cnt_e - l_cnt       ; length
        call  print_kv                  ; print the counter

        li    t0, 8                     ; t0 = offset of the report word
        tamo.add s11, c6, t0, zero      ; s11 = the cause core 1 recorded
        la    a0, l_plain               ; describe core 1's attempt
        li    a1, l_plain_e - l_plain   ; length
        call  print_cause               ; print it

        li    t0, 32                    ; t0 = message length
        tget  tg0, s5, c7, zero, t0     ; read the buffer core 1 wrote and returned
        la    a0, l_msg                 ; "message from core 1: "
        li    a1, l_msg_e - l_msg       ; length
        call  print_str                 ; print the label
        mv    a0, s5                    ; the message
        li    a1, 32                    ; its length
        call  print_str                 ; print it (waits behind the tget automatically)
        li    a0, 0                     ; exit code
        halt                            ; stop

idle:
        li    a0, 0                     ; exit code
        halt                            ; extra cores just stop

; =============================== core 1 =========================================
core1:                                  ; core 1 starts here
        ctake c6                        ; receive the atomic capability
        ctake c7                        ; receive the buffer

        li    s11, 0                    ; clear the recorded cause
        li    t0, 8                     ; t0 = 8 bytes
        tput  tg0, s5, c6, zero, t0     ; try an ordinary write to the counter
        li    t0, 8                     ; t0 = offset of the report word
        tamo.swap zero, c6, t0, s11     ; report the cause (perm) to core 0 through the atomic segment

        li    s2, ADDS                  ; s2 = increments left
c1_add:                                 ; loop: core 1 increments
        tamo.add zero, c6, zero, s1     ; counter += 1
        addi  s2, s2, -1                ; one fewer
        bnez  s2, c1_add                ; until done

        la    t1, msg                   ; t1 = our message in D-LS
        li    t0, 32                    ; t0 = its length
        tput  tg0, t1, c7, zero, t0     ; write it into the buffer we now own
        li    t0, 0                     ; t0 = core 0
        cgive c7, t0                    ; give the buffer back; completes only after the tput landed
        li    a0, 0                     ; exit code
        halt                            ; stop

; -----------------------------------------------------------------------------
; print_cause(a0 = label, a1 = label length): print "<label><cause name>\n"
; for the cause number in s11.
; -----------------------------------------------------------------------------
print_cause:                            ; routine entry
        addi  sp, sp, -8                ; room for the return address
        sd    ra, 0(sp)                 ; save it
        call  print_str                 ; print the label
        slli  t0, s11, 3                ; t0 = cause * 8
        la    a0, names                 ; a0 = name table
        add   a0, a0, t0                ; a0 = this cause's name
        li    a1, 8                     ; names are 8 characters, space-padded
        call  print_str                 ; print the name
        call  print_nl                  ; end the line
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; release the slot
        ret                             ; done

; -----------------------------------------------------------------------------
; Trap handler: record the cause in s11 and skip the trapping instruction.
; -----------------------------------------------------------------------------
handler:                                ; trap handler: tvec points here
        csrr  s11, cause                ; s11 = cause number
        csrr  t0, epc                   ; t0 = trapping instruction
        addi  t0, t0, 4                 ; t0 = the next one
        csrw  epc, t0                   ; resume there
        eret                            ; return from the trap

        .include "lib/print.s"          ; console helpers
