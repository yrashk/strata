; =============================================================================
; reserved.s: reserved CSRs, reserved CCR bits, and ignored instruction fields
; =============================================================================
;
; What it checks (as emu/emu.c behaves; the manual's encoding chapter calls
; shaded fields "ignored")
;   * CSR 17 (reserved) and unassigned CSR numbers read as 0; writes to
;     them are ignored.
;   * CCR keeps whatever is written to it (bit 0 is PTRAP; the other bits
;     are reserved but read back).
;   * Fields an instruction does not use are ignored: twait / tpoll with
;     nonzero rd / rs1 fields, halt / eret / svc with nonzero register fields
;     (eret is checked), cvalid with an rs2 field, csrr with an rs1 field.
;   * The low bits of jal's link and of a branch offset cannot be misaligned
;     (word offsets): nothing to check.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        csrr  a0, 17                    ; CSR 17: reserved
        li    a1, 0                     ; reads 0
        call  chk                       ; check
        li    t0, 0x1234                ; a value
        csrw  17, t0                    ; write it: ignored
        csrr  a0, 17                    ; read back
        li    a1, 0                     ; still 0
        call  chk                       ; check
        csrr  a0, 100                   ; an unassigned CSR number
        li    a1, 0                     ; reads 0
        call  chk                       ; check
        csrw  100, t0                   ; write: ignored
        csrr  a0, 0xffff                ; the largest CSR number
        li    a1, 0                     ; 0
        call  chk                       ; check
        li    t0, 0xfe                  ; reserved CCR bits, PTRAP clear
        csrw  ccr, t0                   ; write
        csrr  a0, ccr                   ; read back
        li    a1, 0xfe                  ; kept
        call  chk                       ; check
        csrw  ccr, zero                 ; clear it again
        li    t1, 0                     ; t1 = 0
        .word 0x31 << 26 | 5 << 21 | 6 << 16 | 0xffff ; twait with rd = t0, rs1 = t1 (ignored): waits for all tags
        .word 0x32 << 26 | 10 << 21 | 6 << 16 | 0xffff ; tpoll a0 with an rs1 field (ignored)
        li    a1, 0                     ; nothing busy
        call  chk                       ; check
        .word 0x34 << 26 | 10 << 21 | 0 << 16 | 7 << 11 | 14 ; cvalid a0, c0 with an rs2 field (ignored)
        li    a1, 1                     ; c0 is valid
        call  chk                       ; check
        .word 0x38 << 26 | 10 << 21 | 6 << 16 | 7 ; csrr a0, coreid with an rs1 field (ignored)
        li    a1, 0                     ; core 0
        call  chk                       ; check
        la    t0, rs_ok                 ; eret target
        csrw  epc, t0                   ; epc = rs_ok
        li    t0, 2                     ; stay in supervisor mode
        csrw  status, t0                ; spp = supervisor
        li    a0, 0                     ; a0 = 0 unless the next instruction runs
        .word 0x3a << 26 | 5 << 21 | 6 << 16 | 1 ; eret with register fields set (ignored)
        li    a0, 99                    ; (skipped)
rs_ok:
        li    a1, 0                     ; expected: eret jumped
        call  chk                       ; check
        li    a0, 0                     ; no trap anywhere above
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict
