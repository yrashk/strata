; =============================================================================
; wc.s: count the lines, words and bytes of standard input
; =============================================================================
;
;   wc < motd             seq 1000 | wc
;
; Prints "LINES WORDS BYTES". A word is a run of characters other than
; spaces and tabs.

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
buf:    .space 256                      ; the current line
sp1:    .ascii " "                      ; a separator

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        li    s0, 0                     ; s0 = lines
        li    s1, 0                     ; s1 = words
        li    s2, 0                     ; s2 = bytes
loop:
        la    a0, buf                   ; the next line
        li    a1, 255                   ; at most this long
        call  in_line                   ; a0 = its length, -1 at end
        bltz  a0, done                  ; end of input
        addi  s0, s0, 1                 ; one more line
        add   s2, s2, a0                ; its bytes ...
        addi  s2, s2, 1                 ; ... and its newline
        la    t0, buf                   ; count its words:
        add   t1, t0, a0                ;   t1 = end of the line
        li    t2, 0                     ;   t2 = 1 while inside a word
wloop:
        bgeu  t0, t1, loop              ; end of the line: next line
        lbu   t3, 0(t0)                 ; next character
        addi  t0, t0, 1                 ; ...
        li    t4, ' '                   ; a space ...
        beq   t3, t4, wsep              ; ... separates
        li    t4, 9                     ; and so does a tab
        beq   t3, t4, wsep              ; ...
        bnez  t2, wloop                 ; already inside a word
        li    t2, 1                     ; a word starts
        addi  s1, s1, 1                 ; count it
        j     wloop                     ; continue
wsep:
        li    t2, 0                     ; outside a word
        j     wloop                     ; continue
done:
        mv    a0, s0                    ; lines
        call  out_dec                   ; print
        la    a0, sp1                   ; " "
        li    a1, 1                     ; ...
        call  out_str                   ; print
        mv    a0, s1                    ; words
        call  out_dec                   ; print
        la    a0, sp1                   ; " "
        li    a1, 1                     ; ...
        call  out_str                   ; print
        mv    a0, s2                    ; bytes
        call  out_dec                   ; print
        call  out_nl                    ; newline
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process

        .include "../lib/sys.s"         ; the system interface
