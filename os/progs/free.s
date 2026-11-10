; =============================================================================
; free.s: how much memory is left
; =============================================================================
;
;   free
;   total:  786432 KiB  (768 MiB)
;   free:   524288 KiB  (512 MiB)
;   processes: 7
;
; Asks the process server with sys_info (64 bytes: u64 cores, free heap,
; total memory, processes, kernel units loaded, context switches, KiB moved).

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
info:   .space 64                       ; the summary
m_tot:  .ascii "total: "                ; output text
m_tot_e:                                ; end of the text above
m_free: .ascii "free:  "                ; output text
m_free_e:                               ; end of the text above
m_kib:  .ascii " KiB  ("                ; output text
m_kib_e:                                ; end of the text above
m_mib:  .ascii " MiB)\n"                ; output text
m_mib_e:                                ; end of the text above
m_proc: .ascii "processes: "            ; output text
m_proc_e:                               ; end of the text above
m_err:  .ascii "free: cannot ask the process server\n" ; error text
m_err_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, info                  ; the summary
        call  sys_info                  ; a0 = 0, or < 0
        bltz  a0, fail                  ; no answer
        la    s0, info                  ; s0 = the summary
        la    a0, m_tot                 ; "total: "
        li    a1, m_tot_e - m_tot       ; ...
        call  out_str                   ; ...
        ld    a0, 16(s0)                ; total memory (bytes)
        call  amount                    ; "N KiB  (M MiB)"
        la    a0, m_free                ; "free:  "
        li    a1, m_free_e - m_free     ; ...
        call  out_str                   ; ...
        ld    a0, 8(s0)                 ; free heap (bytes)
        call  amount                    ; "N KiB  (M MiB)"
        la    a0, m_proc                ; "processes: "
        li    a1, m_proc_e - m_proc     ; ...
        call  out_str                   ; ...
        ld    a0, 24(s0)                ; processes
        call  out_dec                   ; ...
        call  out_nl                    ; ...
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process
fail:
        la    a0, m_err                 ; complain on standard error
        li    a1, m_err_e - m_err       ; ...
        call  err_str                   ; ...
        li    a0, 1                     ; exit code
        call  sys_exit                  ; end the process

; amount(a0 = bytes): print "KIB KiB  (MIB MiB)" and a newline
amount:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; the bytes
        srli  a0, a0, 10                ; KiB
        li    a1, 8                     ; right-aligned in 8 columns
        call  out_decw                  ; ...
        la    a0, m_kib                 ; " KiB  ("
        li    a1, m_kib_e - m_kib       ; ...
        call  out_str                   ; ...
        ld    a0, 8(sp)                 ; MiB
        srli  a0, a0, 20                ; ...
        call  out_dec                   ; ...
        la    a0, m_mib                 ; " MiB)"
        li    a1, m_mib_e - m_mib       ; ...
        call  out_str                   ; ...
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

        .include "../lib/sys.s"         ; the system interface
