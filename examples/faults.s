; =============================================================================
; faults.s: the protection model, one trap at a time
; =============================================================================
;
; What it shows
;   * Far memory is reachable only through capability registers (c0..c15).
;     A capability is (space, base, length, permissions); there is no way to
;     turn an integer into one.
;   * Every transfer is checked when it *issues*, so a bad transfer traps
;     precisely, on the instruction that asked for it, before any byte moves.
;   * Writable capabilities are *linear*: moving one (cmov) leaves the source
;     register empty, nothing can copy it, and no instruction may overwrite
;     one that is still live. `cshare` turns one into a non-writable
;     capability (read and execute rights kept) that may be copied freely.
;   * Each trap sets `cause`, `epc` (the trapping instruction) and `tval`,
;     then jumps to `tvec`. This handler records the cause and resumes at the
;     next instruction, so the program can show one failure after another.
;
; Expected output:
;   read past the end of a segment      -> bounds
;   misaligned transfer                 -> xalign
;   use a capability after moving it    -> capinv
;   write through a non-writable share  -> perm
;   load outside the data Local Store   -> lsfault
;   atomic on non-atomic memory         -> perm
;   undefined instruction               -> illegal
;   split more than the segment holds   -> capop
;   overwrite a live capability         -> capop
;   give to a core that has halted      -> capop

        .data                           ; data Local Store
        .align 8                        ; transfer buffers must be 8-byte aligned
buf:    .space 64                       ; scratch buffer for the transfers below
names:  .ascii "none    illegal lsfault capinv  perm    bounds  xalign  ifault  xmiss   pend    capop   "  ; cause names, 8 characters each, indexed by cause number
arrow:  .ascii " -> "                   ; separator between description and cause
d1:     .ascii "read past the end of a segment    " ; test descriptions, all the same width (34)
d2:     .ascii "misaligned transfer               "  ; output text
d3:     .ascii "use a capability after moving it  "  ; output text
d4:     .ascii "write through a non-writable share"  ; output text
d5:     .ascii "load outside the data Local Store "  ; output text
d6:     .ascii "atomic on non-atomic memory       "  ; output text
d7:     .ascii "undefined instruction             "  ; output text
d8:     .ascii "split more than the segment holds "
d9:     .ascii "overwrite a live capability       "  ; output text
d10:    .ascii "give to a core that has halted    "  ; output text  ; output text
DLEN    = 34                            ; description width

        .text                           ; instruction Local Store
_start:                                 ; entry point: every core starts executing here, at I-LS address 0
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; core 0 only
        li    sp, 65536                 ; stack at the top of D-LS
        la    t0, handler               ; t0 = handler address
        csrw  tvec, t0                  ; install the trap handler

        li    t0, 4096                  ; t0 = 4 KiB
        csplit c5, c0, t0               ; split root c0: c0 keeps [0, 4096), c5 gets the rest of T3
        la    s1, buf                   ; s1 = D-LS buffer address
        li    s2, 16                    ; s2 = a 16-byte transfer length

; ---- 1. bounds -----------------------------------------------------------------
        li    t1, 4096 - 8              ; t1 = offset of the segment's last word
        tget  tg0, s1, c0, t1, s2       ; ask for 16 bytes there: 8 of them lie outside c0
        la    a0, d1                    ; describe the test
        call  report                    ; print description and the recorded cause

; ---- 2. misaligned transfer -----------------------------------------------------
        li    t1, 4                     ; t1 = an offset that is not a multiple of 8
        tget  tg0, s1, c0, t1, s2       ; memory transfers move whole 8-byte words
        la    a0, d2                    ; describe
        call  report                    ; print

; ---- 3. use after move ------------------------------------------------------------
        cmov  c6, c0                    ; move the 4 KiB capability to c6; c0 is now empty
        tget  tg0, s1, c0, zero, s2     ; try to use c0 anyway
        la    a0, d3                    ; describe
        call  report                    ; print
        cmov  c0, c6                    ; move it back for the following tests

; ---- 4. write through a read-only share --------------------------------------------
        cshare c7, c5                   ; c7 = non-writable, copyable view of c5's segment (c5 is consumed)
        tput  tg0, s1, c7, zero, s2     ; try to write through it
        la    a0, d4                    ; describe
        call  report                    ; print

; ---- 5. load outside the Local Store ------------------------------------------------
        li    t1, 65536                 ; t1 = first address past the 64 KiB D-LS
        ld    t2, 0(t1)                 ; loads reach only the Local Store
        la    a0, d5                    ; describe
        call  report                    ; print

; ---- 6. atomic on ordinary memory ----------------------------------------------------
        li    t2, 1                     ; t2 = amount to add
        tamo.add t1, c0, zero, t2       ; far atomics need an atomic (A) capability; c0 is R/W/X
        la    a0, d6                    ; describe
        call  report                    ; print

; ---- 7. undefined instruction ---------------------------------------------------------
        .word 0xfc000000                ; opcode 0x3f is not assigned
        la    a0, d7                    ; describe
        call  report                    ; print

; ---- 8. capability arithmetic out of range ----------------------------------------------
        li    t1, 8192                  ; t1 = more than c0's 4096 bytes
        csplit c8, c0, t1               ; cannot split beyond the end
        la    a0, d8                    ; describe
        call  report                    ; print

; ---- 9. overwriting a live linear capability ------------------------------------------
        li    t1, 1024                  ; t1 = 1 KiB
        csplit c8, c0, t1               ; c0 = first 1 KiB, c8 = the rest of its 4 KiB: two live writable caps
        cmov  c8, c0                    ; moving c0 onto c8 would destroy c8's memory for good: refused
        la    a0, d9                    ; describe
        call  report                    ; print

; ---- 10. giving to a halted core ----------------------------------------------------------
        li    t1, 1                     ; core 1 halted at start-up (see park)
        cgive c8, t1                    ; a capability sent there could never be used or returned
        la    a0, d10                   ; describe
        call  report                    ; print
park:                                   ; cores with nothing to do end up here
        li    a0, 0                     ; exit code
        halt                            ; stop

; -----------------------------------------------------------------------------
; report(a0 = description): print "<description> -> <cause name>\n" using the
; cause recorded in s11 by the handler, then clear it.
; -----------------------------------------------------------------------------
report:                                 ; print the verdict selected in a0/a1
        addi  sp, sp, -8                ; room for the return address
        sd    ra, 0(sp)                 ; save it (we make calls below)
        li    a1, DLEN                  ; description length
        call  print_str                 ; print the description
        la    a0, arrow                 ; " -> "
        li    a1, 4                     ; its length
        call  print_str                 ; print it
        slli  t0, s11, 3                ; t0 = cause * 8 = offset of its name
        la    a0, names                 ; a0 = name table
        add   a0, a0, t0                ; a0 = this cause's name
        li    a1, 8                     ; 8 characters (padded with spaces)
        call  print_str                 ; print the name
        call  print_nl                  ; end the line
        li    s11, 0                    ; clear the recorded cause for the next test
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; release the stack slot
        ret                             ; back to the test sequence

; -----------------------------------------------------------------------------
; Trap handler: remember the cause in s11 and skip the trapping instruction.
; (It clobbers t0; the tests above never rely on t0 across a trap.)
; -----------------------------------------------------------------------------
handler:                                ; trap handler: tvec points here
        csrr  s11, cause                ; s11 = cause number
        csrr  t0, epc                   ; t0 = address of the trapping instruction
        addi  t0, t0, 4                 ; t0 = the instruction after it
        csrw  epc, t0                   ; resume there
        eret                            ; return from the trap

        .include "lib/print.s"          ; console helpers
