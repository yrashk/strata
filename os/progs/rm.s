; =============================================================================
; rm.s: delete files
; =============================================================================
;
;   rm NAME...            delete each named file
;
; Each name is sent to the file server with sys_unlink. A name that does not
; exist is reported on standard error ("rm: no such file: X") and makes the
; exit code 1; the other names are still deleted.

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
args:   .space 512                      ; the argument text (a command line is at most 440 bytes)
m_use:  .ascii "usage: rm NAME...\n"    ; error text
m_use_e:                                ; end of the text above
m_no:   .ascii "rm: no such file: "     ; error text
m_no_e:                                 ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        call  sys_init                  ; handles and arguments
        li    s4, 0                     ; s4 = exit code
        la    a0, args                  ; the arguments ...
        call  sys_args                  ; ... a0 = their length
        beqz  a0, usage                 ; no names
        la    s0, args                  ; s0 = cursor
        add   s1, s0, a0                ; s1 = end
next:
        mv    a0, s0                    ; the next name
        mv    a1, s1                    ; ...
        call  arg_next                  ; a0 = start, a1 = length, a2 = cursor after
        beqz  a1, done                  ; no more names
        mv    s0, a2                    ; advance the cursor
        mv    s2, a0                    ; s2 = name
        mv    s3, a1                    ; s3 = its length
        call  sys_unlink                ; a0 = 0 or < 0
        bgez  a0, next                  ; deleted
        li    s4, 1                     ; remember the failure
        la    a0, m_no                  ; "rm: no such file: "
        li    a1, m_no_e - m_no         ; ...
        call  err_str                   ; ...
        mv    a0, s2                    ; the name
        mv    a1, s3                    ; ...
        call  err_str                   ; ...
        la    a0, sys_nl                ; a newline
        li    a1, 1                     ; ...
        call  err_str                   ; ...
        j     next                      ; next name
usage:
        la    a0, m_use                 ; how to use it
        li    a1, m_use_e - m_use       ; ...
        call  err_str                   ; ...
        li    s4, 2                     ; exit code for a usage error
done:
        mv    a0, s4                    ; exit code
        call  sys_exit                  ; flush stdout, end the process

        .include "../lib/sys.s"         ; the system interface
