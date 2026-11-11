; =============================================================================
; ps.s: list the processes
; =============================================================================
;
;   ps
;     PID  PPID STATE    CORE  CPUS  SWITCHES   KIB  NAME
;       1     0 blocked     1     0        12     0  proc (server)
;
; Asks the process server with sys_ps: one 32-byte record per process
; (u8 pid, u8 state, u8 core, u8 parent, u8 flags, u8 cores, 2 reserved,
; u32 switches, u32 KiB moved, 16-byte name). States: 1 running, 2 ready,
; 3 blocked, 4 zombie. Flags: 2 server (CPUS > 1: threads on that many cores).

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
tab:    .space 64 * 32                  ; the process records (proc keeps 64)
m_head: .ascii "  PID  PPID STATE    CORE  CPUS  SWITCHES   KIB  NAME\n" ; the header
m_head_e:                               ; end of the text above
states: .ascii "?       running ready   blocked zombie  " ; state names, 8 characters each
m_excl: .ascii " (excl)"                ; flag text
m_excl_e:                               ; end of the text above
m_serv: .ascii " (server)"              ; flag text
m_serv_e:                               ; end of the text above
m_err:  .ascii "ps: cannot ask the process server\n" ; error text
m_err_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, tab                   ; the records
        call  sys_ps                    ; a0 = how many
        bltz  a0, fail                  ; no answer
        mv    s0, a0                    ; s0 = records left
        li    t0, 64                    ; at most 64 fit
        bleu  s0, t0, head              ; ...
        mv    s0, t0                    ; ...
head:
        la    a0, m_head                ; the header
        li    a1, m_head_e - m_head     ; ...
        call  out_str                   ; ...
        la    s1, tab                   ; s1 = current record
row:
        beqz  s0, done                  ; all printed
        lbu   a0, 0(s1)                 ; pid
        li    a1, 5                     ; ...
        call  out_decw                  ; ...
        lbu   a0, 3(s1)                 ; parent
        li    a1, 6                     ; ...
        call  out_decw                  ; ...
        li    a0, ' '                   ; separator
        call  out_chr                   ; ...
        lbu   t0, 1(s1)                 ; state
        li    t1, 5                     ; known states are 1..4
        bltu  t0, t1, st_ok             ; ...
        li    t0, 0                     ; others print as "?"
st_ok:
        slli  t0, t0, 3                 ; 8 characters per name
        la    a0, states                ; ...
        add   a0, a0, t0                ; ...
        li    a1, 8                     ; ...
        call  out_str                   ; ...
        lbu   a0, 2(s1)                 ; core
        li    a1, 5                     ; ...
        call  out_decw                  ; ...
        lbu   a0, 5(s1)                 ; cores of its own
        li    a1, 6                     ; ...
        call  out_decw                  ; ...
        lwu   a0, 8(s1)                 ; context switches
        li    a1, 10                    ; ...
        call  out_decw                  ; ...
        lwu   a0, 12(s1)                ; KiB moved
        li    a1, 6                     ; ...
        call  out_decw                  ; ...
        li    a0, 2                     ; two spaces
        call  out_pad                   ; ...
        addi  a0, s1, 16                ; the name (zero-padded, 16 bytes)
        li    a1, 16                    ; ...
        call  str_len                   ; a0 = its length
        mv    a1, a0                    ; print it
        addi  a0, s1, 16                ; ...
        call  out_str                   ; ...
        lbu   t0, 4(s1)                 ; flags
        andi  t0, t0, 1                 ; exclusive?
        beqz  t0, fl_serv               ; no
        la    a0, m_excl                ; " (excl)"
        li    a1, m_excl_e - m_excl     ; ...
        call  out_str                   ; ...
fl_serv:
        lbu   t0, 4(s1)                 ; flags
        andi  t0, t0, 2                 ; server?
        beqz  t0, fl_done               ; no
        la    a0, m_serv                ; " (server)"
        li    a1, m_serv_e - m_serv     ; ...
        call  out_str                   ; ...
fl_done:
        call  out_nl                    ; end the line
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
