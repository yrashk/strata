; =============================================================================
; seq.s: print the numbers 1 to N, one per line, on standard output
; =============================================================================
;
;   seq 20            seq 100 | grep 7 | wc
;
; Shows the smallest useful program written against the system interface
; (os/lib/sys.s): arguments come from sys_args, output goes to handle 1,
; which the shell connects to the console, a file or a pipe.

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
args:   .space 512                      ; the argument text (a command line is at most 440 bytes)

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, args                  ; the arguments ...
        call  sys_args                  ; ... a0 = their length
        mv    a1, a0                    ; length
        la    a0, args                  ; text
        call  str_atoi                  ; a0 = N
        mv    s0, a0                    ; s0 = N
        li    s1, 1                     ; s1 = the next number
loop:
        bgt   s1, s0, done              ; past N: done
        mv    a0, s1                    ; the number
        call  out_dec                   ; to standard output
        call  out_nl                    ; and a newline
        addi  s1, s1, 1                 ; next
        j     loop                      ; continue
done:
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process

        .include "../lib/sys.s"         ; the system interface
