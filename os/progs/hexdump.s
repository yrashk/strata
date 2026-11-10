; =============================================================================
; hexdump.s: show a raw disk block
; =============================================================================
;
;   hexdump 0             the first 256 bytes of block 0
;   000  53 54 46 53 01 00 00 00 00 00 00 00 00 00 00 00  |STFS............|
;
; Reads one 512-byte block with sys_readblk (straight from the disk, below
; the file system) and prints its first 256 bytes as 16 rows: the offset in
; 3 hex digits, 16 bytes in hex, and the printable ones between bars.

        .data                           ; data Local Store
        .align 8                        ; aligned buffers
args:   .space 512                      ; the argument text (a command line is at most 440 bytes)
blk:    .space 512                      ; the block
m_use:  .ascii "usage: hexdump BLOCK\n" ; error text
m_use_e:                                ; end of the text above
m_err:  .ascii "hexdump: cannot read that block\n" ; error text
m_err_e:                                ; end of the text above
m_bar:  .ascii "  |"                    ; before the characters
m_bar_e:                                ; end of the text above
m_end:  .ascii "|\n"                    ; after them
m_end_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, args                  ; the arguments ...
        call  sys_args                  ; ... a0 = their length
        la    t0, args                  ; the first word
        add   a1, t0, a0                ; ...
        mv    a0, t0                    ; ...
        call  arg_next                  ; a0 = start, a1 = length
        beqz  a1, usage                 ; none
        call  str_num                   ; a0 = the block number, or -1
        bltz  a0, usage                 ; not a number
        mv    s0, a0                    ; s0 = block number
        la    a1, blk                   ; read it
        call  sys_readblk               ; a0 = 512, or < 0
        blez  a0, fail                  ; could not
        li    s1, 0                     ; s1 = offset of the row
row:
        mv    a0, s1                    ; the offset
        li    a1, 3                     ; 3 hex digits
        call  out_hex                   ; ...
        li    a0, 1                     ; one space (each byte adds another)
        call  out_pad                   ; ...
        li    s2, 0                     ; s2 = byte in the row
hex:
        li    a0, ' '                   ; separator
        call  out_chr                   ; ...
        la    t0, blk                   ; the byte
        add   t0, t0, s1                ; ...
        add   t0, t0, s2                ; ...
        lbu   a0, 0(t0)                 ; ...
        li    a1, 2                     ; 2 hex digits
        call  out_hex                   ; ...
        addi  s2, s2, 1                 ; next byte
        li    t0, 16                    ; 16 per row
        blt   s2, t0, hex               ; ...
        la    a0, m_bar                 ; "  |"
        li    a1, m_bar_e - m_bar       ; ...
        call  out_str                   ; ...
        li    s2, 0                     ; the same bytes as characters
chars:
        la    t0, blk                   ; the byte
        add   t0, t0, s1                ; ...
        add   t0, t0, s2                ; ...
        lbu   a0, 0(t0)                 ; ...
        addi  t1, a0, -32               ; printable: 32..126
        li    t2, 95                    ; ...
        bltu  t1, t2, ch_ok             ; yes
        li    a0, '.'                   ; no: a dot
ch_ok:
        call  out_chr                   ; ...
        addi  s2, s2, 1                 ; next byte
        li    t0, 16                    ; 16 per row
        blt   s2, t0, chars             ; ...
        la    a0, m_end                 ; "|"
        li    a1, m_end_e - m_end       ; ...
        call  out_str                   ; ...
        addi  s1, s1, 16                ; next row
        li    t0, 256                   ; 16 rows
        blt   s1, t0, row               ; ...
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process
usage:
        la    a0, m_use                 ; how to use it
        li    a1, m_use_e - m_use       ; ...
        call  err_str                   ; ...
        li    a0, 2                     ; exit code
        call  sys_exit                  ; end the process
fail:
        la    a0, m_err                 ; "hexdump: cannot read that block"
        li    a1, m_err_e - m_err       ; ...
        call  err_str                   ; ...
        li    a0, 1                     ; exit code
        call  sys_exit                  ; end the process

        .include "../lib/sys.s"         ; the system interface
