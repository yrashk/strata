; =============================================================================
; hello.s: the smallest Strata program, on every core in turn
; =============================================================================
;
; What it shows
;   * Where code and data live. `.text` assembles into the instruction Local
;     Store (I-LS) and `.data` into the data Local Store (D-LS). Both are
;     loaded before the cores start, and both are private to each core.
;   * That output is I/O. The text is printed by a `tput` transfer to the
;     console device through capability c2 (see lib/print.s).
;   * Deterministic hand-offs. The cores greet in order: each one waits for a
;     token from the core before it, using `ctake cd, rs`, which takes a
;     capability only from the named sender. Because `cgive` completes only
;     after the giver's own transfers have finished, each greeting is fully
;     out before the next core starts.
;
; Expected output (4 cores):
;   Hello from Strata core 0 of 4
;   Hello from Strata core 1 of 4
;   Hello from Strata core 2 of 4
;   Hello from Strata core 3 of 4

        .data                           ; data Local Store
msg:    .ascii "Hello from Strata core " ; the greeting, without a trailing newline
msg_end:                                ; label just past the greeting, used for its length
of:     .ascii " of "                   ; text between the two numbers
of_end:                                 ; end of the text above

        .text                           ; instruction Local Store; execution starts at address 0
_start:
        csrr  s0, coreid                ; s0 = this core's number
        csrr  s1, ncores                ; s1 = how many cores there are
        beqz  s0, speak                 ; core 0 speaks first, right away
        addi  t0, s0, -1                ; t0 = the core before us
        ctake c3, t0                    ; wait for its token (only a gift from that core counts)
speak:
        la    a0, msg                   ; a0 = D-LS address of the greeting
        li    a1, msg_end - msg         ; a1 = its length in bytes
        call  print_str                 ; print the greeting
        mv    a0, s0                    ; a0 = our core number
        call  print_dec                 ; print it in decimal
        la    a0, of                    ; " of "
        li    a1, of_end - of           ; its length
        call  print_str                 ; print it
        mv    a0, s1                    ; the core count
        call  print_dec                 ; print it
        call  print_nl                  ; finish the line
        addi  t0, s0, 1                 ; t0 = the next core
        bge   t0, s1, done              ; the last core has no one to pass to
        cgive c2, t0                    ; pass a copy of the console capability as the token
                                        ; (cgive waits until our own console bytes are out)
done:
        li    a0, 0                     ; exit code 0
        halt                            ; stop this core (halting first drains its transfers)

        .include "lib/print.s"          ; console helpers
