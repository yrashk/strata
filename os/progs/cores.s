; =============================================================================
; cores.s: what every core is doing
; =============================================================================
;
;   cores
;   core 0: system
;   core 1: running 3, 1 runnable, 4 processes, server; 120 switches, 40 KiB moved
;   core 5: idle, 0 runnable, 1 processes, exclusive; 0 switches, 0 KiB moved
;
; Asks the process server with sys_cores: one 32-byte record per core (u8
; core, u8 pid running (0 none), u8 runnable, u8 processes, u8 flags (1
; exclusive, 2 server, 4 solo), 3 reserved, u32 switches, u32 KiB moved).
; Core 0 runs the system (the kernel of the system core, pid 0).

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
tab:    .space 16 * 32                  ; the records
m_core: .ascii "core "                  ; output text
m_core_e:                               ; end of the text above
m_sys:  .ascii ": system\n"             ; output text
m_sys_e:                                ; end of the text above
m_run:  .ascii ": running "             ; output text
m_run_e:                                ; end of the text above
m_idle: .ascii ": idle"                 ; output text
m_idle_e:                               ; end of the text above
m_rbl:  .ascii " runnable, "            ; output text
m_rbl_e:                                ; end of the text above
m_prc:  .ascii " processes"             ; output text
m_prc_e:                                ; end of the text above
m_excl: .ascii ", exclusive"            ; flag text
m_excl_e:                               ; end of the text above
m_serv: .ascii ", server"               ; flag text
m_serv_e:                               ; end of the text above
m_solo: .ascii ", solo"                 ; flag text
m_solo_e:                               ; end of the text above
m_sw:   .ascii "; "                     ; output text
m_sw_e:                                 ; end of the text above
m_swn:  .ascii " switches, "            ; output text
m_swn_e:                                ; end of the text above
m_kib:  .ascii " KiB moved\n"           ; output text
m_kib_e:                                ; end of the text above
m_comma: .ascii ", "                    ; output text
m_err:  .ascii "cores: cannot ask the process server\n" ; error text
m_err_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, tab                   ; the records
        call  sys_cores                 ; a0 = how many
        bltz  a0, fail                  ; no answer
        mv    s0, a0                    ; s0 = records left
        li    t0, 16                    ; at most 16 fit
        bleu  s0, t0, start             ; ...
        mv    s0, t0                    ; ...
start:
        la    s1, tab                   ; s1 = current record
row:
        beqz  s0, done                  ; all printed
        la    a0, m_core                ; "core "
        li    a1, m_core_e - m_core     ; ...
        call  out_str                   ; ...
        lbu   a0, 0(s1)                 ; the core number
        call  out_dec                   ; ...
        lbu   t0, 0(s1)                 ; core 0?
        bnez  t0, worker                ; no: a worker core
        la    a0, m_sys                 ; ": system"
        li    a1, m_sys_e - m_sys       ; ...
        call  out_str                   ; ...
        j     next                      ; next record
worker:
        lbu   t0, 1(s1)                 ; the pid running
        beqz  t0, idle                  ; none
        la    a0, m_run                 ; ": running "
        li    a1, m_run_e - m_run       ; ...
        call  out_str                   ; ...
        lbu   a0, 1(s1)                 ; the pid
        call  out_dec                   ; ...
        j     counts                    ; continue
idle:
        la    a0, m_idle                ; ": idle"
        li    a1, m_idle_e - m_idle     ; ...
        call  out_str                   ; ...
counts:
        la    a0, m_comma               ; ", "
        li    a1, 2                     ; ...
        call  out_str                   ; ...
        lbu   a0, 2(s1)                 ; runnable
        call  out_dec                   ; ...
        la    a0, m_rbl                 ; " runnable, "
        li    a1, m_rbl_e - m_rbl       ; ...
        call  out_str                   ; ...
        lbu   a0, 3(s1)                 ; processes
        call  out_dec                   ; ...
        la    a0, m_prc                 ; " processes"
        li    a1, m_prc_e - m_prc       ; ...
        call  out_str                   ; ...
        lbu   t0, 4(s1)                 ; flags: exclusive?
        andi  t0, t0, 1                 ; ...
        beqz  t0, f_serv                ; no
        la    a0, m_excl                ; ", exclusive"
        li    a1, m_excl_e - m_excl     ; ...
        call  out_str                   ; ...
f_serv:
        lbu   t0, 4(s1)                 ; server?
        andi  t0, t0, 2                 ; ...
        beqz  t0, f_solo                ; no
        la    a0, m_serv                ; ", server"
        li    a1, m_serv_e - m_serv     ; ...
        call  out_str                   ; ...
f_solo:
        lbu   t0, 4(s1)                 ; solo?
        andi  t0, t0, 4                 ; ...
        beqz  t0, f_done                ; no
        la    a0, m_solo                ; ", solo"
        li    a1, m_solo_e - m_solo     ; ...
        call  out_str                   ; ...
f_done:
        la    a0, m_sw                  ; "; "
        li    a1, m_sw_e - m_sw         ; ...
        call  out_str                   ; ...
        lwu   a0, 8(s1)                 ; switches
        call  out_dec                   ; ...
        la    a0, m_swn                 ; " switches, "
        li    a1, m_swn_e - m_swn       ; ...
        call  out_str                   ; ...
        lwu   a0, 12(s1)                ; KiB moved
        call  out_dec                   ; ...
        la    a0, m_kib                 ; " KiB moved"
        li    a1, m_kib_e - m_kib       ; ...
        call  out_str                   ; ...
next:
        addi  s1, s1, 32                ; next record
        addi  s0, s0, -1                ; one fewer
        j     row                       ; continue
done:
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process
fail:
        la    a0, m_err                 ; complain on standard error
        li    a1, m_err_e - m_err       ; ...
        call  err_str                   ; ...
        li    a0, 1                     ; exit code
        call  sys_exit                  ; end the process

        .include "../lib/sys.s"         ; the system interface
