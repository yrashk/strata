; =============================================================================
; cat.s: copy files (or standard input) to standard output
; =============================================================================
;
;   cat motd about        cat < note        cat motd > copy
;
; Shows opening files through the system interface: each name in the
; arguments is opened with sys_open, read in chunks with sys_read and written
; to handle 1. Without arguments, standard input is copied instead.

        .data                           ; data Local Store
        .align 8                        ; aligned buffers
args:   .space 512                      ; the argument text (a command line is at most 440 bytes)
buf:    .space 4096                     ; a chunk of a file
nofile: .ascii "cat: no such file: "    ; error text (to standard error, handle 2)
nofile_e:                               ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        li    s4, 0                     ; s4 = exit code (1 if a file was missing)
        la    a0, args                  ; the arguments ...
        call  sys_args                  ; ... a0 = their length
        mv    s1, a0                    ; s1 = argument length
        beqz  s1, stdin                 ; none: copy standard input
        la    s0, args                  ; s0 = cursor in the arguments
        add   s1, s0, s1                ; s1 = their end
next:
        bgeu  s0, s1, done              ; no more names
        lbu   t0, 0(s0)                 ; skip spaces
        li    t1, ' '                   ; ...
        bne   t0, t1, name              ; a name starts
        addi  s0, s0, 1                 ; ...
        j     next                      ; ...
name:
        mv    s2, s0                    ; s2 = name start
nlen:
        bgeu  s0, s1, nend              ; the name ends at the end ...
        lbu   t0, 0(s0)                 ; ... or at a space
        li    t1, ' '                   ; ...
        beq   t0, t1, nend              ; ...
        addi  s0, s0, 1                 ; ...
        j     nlen                      ; ...
nend:
        mv    a0, s2                    ; open it for reading
        sub   a1, s0, s2                ; ...
        li    a2, 0                     ; ...
        call  sys_open                  ; a0 = handle or -1
        bltz  a0, missing               ; no such file
        mv    s3, a0                    ; s3 = handle
chunk:
        mv    a0, s3                    ; read a chunk
        la    a1, buf                   ; ...
        li    a2, 4032                  ; ...
        call  sys_read                  ; a0 = bytes
        blez  a0, closef                ; end of the file
        mv    a1, a0                    ; write them
        la    a0, buf                   ; ...
        call  out_str                   ; ...
        j     chunk                     ; next chunk
closef:
        mv    a0, s3                    ; close the file
        call  sys_close                 ; ...
        j     next                      ; next name
missing:
        li    s4, 1                     ; the exit code will say so
        la    a0, nofile                ; "cat: no such file: " (err_str flushes stdout first)
        li    a1, nofile_e - nofile     ; ...
        call  err_str                   ; ...
        mv    a0, s2                    ; the name
        sub   a1, s0, s2                ; ...
        call  err_str                   ; ...
        la    a0, sys_nl                ; a newline
        li    a1, 1                     ; ...
        call  err_str                   ; ...
        j     next                      ; next name
stdin:
        la    a0, buf                   ; copy standard input, line by line
        li    a1, 4000                  ; ...
        call  in_line                   ; a0 = length, -1 at end
        bltz  a0, done                  ; end of input
        mv    a1, a0                    ; print it
        la    a0, buf                   ; ...
        call  out_str                   ; ...
        call  out_nl                    ; ...
        j     stdin                     ; next line
done:
        mv    a0, s4                    ; exit code
        call  sys_exit                  ; flush stdout, end the process

        .include "../lib/sys.s"         ; the system interface
