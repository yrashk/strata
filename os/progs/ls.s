; =============================================================================
; ls.s: list the files on the disk
; =============================================================================
;
;   ls                    one line per file: name (padded to 26 columns), size
;
; Asks the file server for its directory with sys_dir (records of 32 bytes:
; a 24-byte name, zero-padded, and a 64-bit size). Prints "(no files)" when
; the disk is empty.

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
dir:    .space 128 * 32                 ; the directory records
m_none: .ascii "(no files)\n"           ; output text
m_none_e:                               ; end of the text above
m_err:  .ascii "ls: cannot read the directory\n" ; error text
m_err_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, dir                   ; the directory
        call  sys_dir                   ; a0 = number of files
        bltz  a0, fail                  ; the file server said no
        beqz  a0, none                  ; empty disk
        mv    s0, a0                    ; s0 = records left
        la    s1, dir                   ; s1 = current record
entry:
        mv    a0, s1                    ; the name's length (zero-padded, 24 bytes)
        li    a1, 24                    ; ...
        call  str_len                   ; a0 = length
        mv    s2, a0                    ; s2 = length
        mv    a0, s1                    ; print the name
        mv    a1, s2                    ; ...
        call  out_str                   ; ...
        li    a0, 26                    ; pad it to 26 columns
        sub   a0, a0, s2                ; ...
        call  out_pad                   ; ...
        ld    a0, 24(s1)                ; the size
        call  out_dec                   ; ...
        call  out_nl                    ; end the line
        addi  s1, s1, 32                ; next record
        addi  s0, s0, -1                ; one fewer
        bnez  s0, entry                 ; more
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process
none:
        la    a0, m_none                ; "(no files)"
        li    a1, m_none_e - m_none     ; ...
        call  out_str                   ; ...
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process
fail:
        la    a0, m_err                 ; complain on standard error
        li    a1, m_err_e - m_err       ; ...
        call  err_str                   ; ...
        li    a0, 1                     ; exit code
        call  sys_exit                  ; end the process

        .include "../lib/sys.s"         ; the system interface
