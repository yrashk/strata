; =============================================================================
; devs.s: the machine's platform table
; =============================================================================
;
;   devs
;   memory   0 space 3 base 0x0000000000000000 size 805306368 info 0
;   console  0 space 4 base 0x0000000000000000 size 256 info 3
;   ...
;
; Asks the device manager (sys_devs) for the platform-table entries and
; prints one line per entry, as the firmware does at boot. Entry (32 bytes):
; u16 type, u16 index, u16 space, u16 node, u64 info, u64 base, u64 size.
; Types: 1 memory, 2 console, 3 platform, 4 block, 5 fb, 6 timer, 7 pointer, 8 net.

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
tab:    .space 32 * 16                  ; the entries
names:  .ascii "?        memory   console  platform block    fb       timer    pointer  net      " ; 9 characters per type
m_sp:   .ascii " space "                ; output text
m_sp_e:                                 ; end of the text above
m_base: .ascii " base 0x"               ; output text
m_base_e:                               ; end of the text above
m_size: .ascii " size "                 ; output text
m_size_e:                               ; end of the text above
m_info: .ascii " info "                 ; output text
m_info_e:                               ; end of the text above
m_err:  .ascii "devs: no device manager\n" ; error text
m_err_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        la    a0, tab                   ; the entries
        call  sys_devs                  ; a0 = how many
        bltz  a0, fail                  ; no answer
        mv    s0, a0                    ; s0 = entries left
        li    t0, 16                    ; at most 16 fit
        bleu  s0, t0, start             ; ...
        mv    s0, t0                    ; ...
start:
        la    s1, tab                   ; s1 = current entry
entry:
        beqz  s0, done                  ; all printed
        lhu   t0, 0(s1)                 ; type
        li    t1, 9                     ; known types are 1..8
        bltu  t0, t1, known             ; ...
        li    t0, 0                     ; others print as "?"
known:
        li    t1, 9                     ; 9 characters per name
        mul   t0, t0, t1                ; ...
        la    a0, names                 ; ...
        add   a0, a0, t0                ; ...
        li    a1, 9                     ; ...
        call  out_str                   ; the type name
        lhu   a0, 2(s1)                 ; index
        call  out_dec                   ; ...
        la    a0, m_sp                  ; " space "
        li    a1, m_sp_e - m_sp         ; ...
        call  out_str                   ; ...
        lhu   a0, 4(s1)                 ; space
        call  out_dec                   ; ...
        la    a0, m_base                ; " base 0x"
        li    a1, m_base_e - m_base     ; ...
        call  out_str                   ; ...
        ld    a0, 16(s1)                ; base
        li    a1, 16                    ; all 16 hex digits
        call  out_hex                   ; ...
        la    a0, m_size                ; " size "
        li    a1, m_size_e - m_size     ; ...
        call  out_str                   ; ...
        ld    a0, 24(s1)                ; size
        call  out_dec                   ; ...
        la    a0, m_info                ; " info "
        li    a1, m_info_e - m_info     ; ...
        call  out_str                   ; ...
        ld    a0, 8(s1)                 ; info (meaning depends on the type)
        call  out_dec                   ; ...
        call  out_nl                    ; end the line
        addi  s1, s1, 32                ; next entry
        addi  s0, s0, -1                ; one fewer
        j     entry                     ; continue
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
