; =============================================================================
; grep.s: print the lines of standard input that contain a pattern
; =============================================================================
;
;   grep TEXT < file      seq 50 | grep 3
;
; The pattern is the whole argument text. Lines come from handle 0 (a file,
; a pipe or the console); matches go to handle 1.

        .data                           ; data Local Store
        .align 8                        ; aligned buffers
pat:    .space 512                      ; the pattern (a command line is at most 440 bytes)
buf:    .space 256                      ; the current line

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, pat                   ; the pattern ...
        call  sys_args                  ; ... a0 = its length
        mv    s0, a0                    ; s0 = pattern length
loop:
        la    a0, buf                   ; the next line
        li    a1, 255                   ; at most this long
        call  in_line                   ; a0 = its length, -1 at end
        bltz  a0, done                  ; end of input
        mv    s1, a0                    ; s1 = line length
        la    a0, buf                   ; does it contain the pattern?
        mv    a1, s1                    ; ...
        la    a2, pat                   ; ...
        mv    a3, s0                    ; ...
        call  str_has                   ; ...
        beqz  a0, loop                  ; no: next line
        la    a0, buf                   ; yes: print it
        mv    a1, s1                    ; ...
        call  out_str                   ; ...
        call  out_nl                    ; ...
        j     loop                      ; next line
done:
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process

        .include "../lib/sys.s"         ; the system interface
