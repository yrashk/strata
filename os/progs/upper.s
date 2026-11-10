; =============================================================================
; upper.s: copy standard input to standard output in capital letters
; =============================================================================
;
;   upper < about         cat motd | upper

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
buf:    .space 256                      ; the current line

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
loop:
        la    a0, buf                   ; the next line
        li    a1, 255                   ; at most this long
        call  in_line                   ; a0 = its length, -1 at end
        bltz  a0, done                  ; end of input
        mv    s0, a0                    ; s0 = length
        la    t0, buf                   ; t0 = cursor
        add   t1, t0, s0                ; t1 = end
cap:
        bgeu  t0, t1, put               ; converted
        lbu   t2, 0(t0)                 ; next character
        addi  t3, t2, -97               ; 'a' -> 0
        li    t4, 26                    ; a lower-case letter?
        bgeu  t3, t4, capn              ; no
        addi  t2, t2, -32               ; yes: make it a capital
        sb    t2, 0(t0)                 ; ...
capn:
        addi  t0, t0, 1                 ; next character
        j     cap                       ; continue
put:
        la    a0, buf                   ; print the line
        mv    a1, s0                    ; ...
        call  out_str                   ; ...
        call  out_nl                    ; ...
        j     loop                      ; next line
done:
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process

        .include "../lib/sys.s"         ; the system interface
