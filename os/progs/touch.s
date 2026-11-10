; =============================================================================
; touch.s: create empty files
; =============================================================================
;
;   touch FILE...         create each FILE, empty, unless the path names one
;
; FILE is a path: `touch /todo/milk` creates milk tagged todo. Files have no
; times, so a file the path already names (sys_stat) is left alone. Anything
; else is opened for appending and closed (sys_open mode 2): a new file is
; created empty, and an existing file that lacks the path's tags gets them
; with its contents kept (it is rewritten, so at most 128 KiB; `tag` does
; the same for any size). "touch: cannot create FILE" (exit code 1): a bad
; name, an excluding path ("/a/-b/f"), no room.

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
args:   .space 512                      ; the argument text (a command line is at most 440 bytes)
m_use:  .ascii "usage: touch FILE...\n" ; error text
m_use_e:                                ; end of the text above
m_no:   .ascii "touch: cannot create "  ; error text
m_no_e:                                 ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
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
        call  sys_stat                  ; does the path name a file already?
        bgez  a0, next                  ; yes: nothing to do
        mv    a0, s2                    ; no: open it for appending
        mv    a1, s3                    ; ...
        li    a2, 2                     ; ...
        call  sys_open                  ; a0 = handle or < 0
        bltz  a0, fail                  ; ...
        call  sys_close                 ; closing saves it
        j     next                      ; next name
fail:
        li    s4, 1                     ; remember the failure
        la    a0, m_no                  ; "touch: cannot create "
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
