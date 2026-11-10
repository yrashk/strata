; =============================================================================
; uptime.s: how long the machine has been running, and how busy it was
; =============================================================================
;
;   uptime
;   up 12.345 s, 7 processes, 1200 context switches (3400 KiB moved), 5 kernel code units paged in
;
; The time comes from the clock capability (c7): NOW (port 0) in ticks and
; FREQ (port 8) in ticks per second. The rest comes from sys_info.

        .data                           ; data Local Store
        .align 8                        ; aligned buffers
info:   .space 64                       ; the summary from sys_info
freq:   .dword 0                        ; ticks per second (read from the clock)
m_up:   .ascii "up "                    ; output text
m_up_e:                                 ; end of the text above
m_s:    .ascii " s, "                   ; output text
m_s_e:                                  ; end of the text above
m_proc: .ascii " processes, "           ; output text
m_proc_e:                               ; end of the text above
m_sw:   .ascii " context switches ("    ; output text
m_sw_e:                                 ; end of the text above
m_kib:  .ascii " KiB moved), "          ; output text
m_kib_e:                                ; end of the text above
m_unit: .ascii " kernel code units paged in\n" ; output text
m_unit_e:                               ; end of the text above
m_err:  .ascii "uptime: cannot ask the process server\n" ; error text
m_err_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        call  sys_now                   ; a0 = ticks since power-on
        mv    s0, a0                    ; s0 = ticks
        la    t0, freq                  ; FREQ: the clock's second register
        li    t1, 8                     ; (port 8, 8 bytes)
        tget  tg10, t0, c7, t1, t1      ; clock -> D-LS
        ld    s1, 0(t0)                 ; s1 = ticks per second (waits for the read)
        bnez  s1, have_f                ; a sensible value
        li    s1, 1000000               ; otherwise assume 1 MHz
have_f:
        la    a0, info                  ; the summary
        call  sys_info                  ; a0 = 0, or < 0
        bltz  a0, fail                  ; no answer
        la    a0, m_up                  ; "up "
        li    a1, m_up_e - m_up         ; ...
        call  out_str                   ; ...
        divu  a0, s0, s1                ; whole seconds
        call  out_dec                   ; ...
        li    a0, '.'                   ; decimal point
        call  out_chr                   ; ...
        remu  s2, s0, s1                ; the ticks of the current second
        li    t0, 1000                  ; -> milliseconds
        mul   s2, s2, t0                ; ...
        divu  s2, s2, s1                ; s2 = 0..999
        li    t0, 100                   ; a leading zero below 100
        bgeu  s2, t0, ms_10             ; ...
        li    a0, '0'                   ; ...
        call  out_chr                   ; ...
ms_10:
        li    t0, 10                    ; and another below 10
        bgeu  s2, t0, ms_out            ; ...
        li    a0, '0'                   ; ...
        call  out_chr                   ; ...
ms_out:
        mv    a0, s2                    ; the milliseconds
        call  out_dec                   ; ...
        la    a0, m_s                   ; " s, "
        li    a1, m_s_e - m_s           ; ...
        call  out_str                   ; ...
        la    s3, info                  ; s3 = the summary
        ld    a0, 24(s3)                ; processes
        call  out_dec                   ; ...
        la    a0, m_proc                ; " processes, "
        li    a1, m_proc_e - m_proc     ; ...
        call  out_str                   ; ...
        ld    a0, 40(s3)                ; context switches
        call  out_dec                   ; ...
        la    a0, m_sw                  ; " context switches ("
        li    a1, m_sw_e - m_sw         ; ...
        call  out_str                   ; ...
        ld    a0, 48(s3)                ; KiB moved
        call  out_dec                   ; ...
        la    a0, m_kib                 ; " KiB moved), "
        li    a1, m_kib_e - m_kib       ; ...
        call  out_str                   ; ...
        ld    a0, 32(s3)                ; kernel code units loaded
        call  out_dec                   ; ...
        la    a0, m_unit                ; " kernel code units paged in"
        li    a1, m_unit_e - m_unit     ; ...
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
