; =============================================================================
; df.s: how full the disk is
; =============================================================================
;
;   df                    disk: T blocks, U used, F free, N files
;
; Asks the file server with sys_statfs: three 64-bit words (total blocks,
; used blocks, files). Free = total - used.

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
st:     .space 24                       ; total, used, files
m_disk: .ascii "disk: "                 ; output text
m_disk_e:                               ; end of the text above
m_blk:  .ascii " blocks, "              ; output text
m_blk_e:                                ; end of the text above
m_used: .ascii " used, "                ; output text
m_used_e:                               ; end of the text above
m_free: .ascii " free, "                ; output text
m_free_e:                               ; end of the text above
m_fil:  .ascii " files\n"               ; output text
m_fil_e:                                ; end of the text above
m_err:  .ascii "df: cannot ask the file server\n" ; error text
m_err_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        call  sys_init                  ; handles and arguments
        la    a0, st                    ; the numbers
        call  sys_statfs                ; a0 = 3, or < 0
        blez  a0, fail                  ; no answer
        la    s0, st                    ; s0 = the numbers
        la    a0, m_disk                ; "disk: "
        li    a1, m_disk_e - m_disk     ; ...
        call  out_str                   ; ...
        ld    a0, 0(s0)                 ; total blocks
        call  out_dec                   ; ...
        la    a0, m_blk                 ; " blocks, "
        li    a1, m_blk_e - m_blk       ; ...
        call  out_str                   ; ...
        ld    a0, 8(s0)                 ; used blocks
        call  out_dec                   ; ...
        la    a0, m_used                ; " used, "
        li    a1, m_used_e - m_used     ; ...
        call  out_str                   ; ...
        ld    a0, 0(s0)                 ; free = total - used
        ld    t0, 8(s0)                 ; ...
        sub   a0, a0, t0                ; ...
        call  out_dec                   ; ...
        la    a0, m_free                ; " free, "
        li    a1, m_free_e - m_free     ; ...
        call  out_str                   ; ...
        ld    a0, 16(s0)                ; files
        call  out_dec                   ; ...
        la    a0, m_fil                 ; " files"
        li    a1, m_fil_e - m_fil       ; ...
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
