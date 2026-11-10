; =============================================================================
; haltdrain.s: halt waits for the core's own transfers, device reads included
; =============================================================================
;
; What it checks (FINDINGS F3, doc/strataos-0.2.md 1.2; manual: gen-insns-sys.tex
; HALT, ch-traps.tex, ch-intercore.tex: "halt waits for all of the core's
; transfers first", device reads included)
;   * Core 0 sets DEADLINE 20000 ticks ahead, issues a timer WAIT read (in
;     flight until then), tells core 1, and halts. Core 1 waits a little
;     (far less than 20000 ticks) and gives core 0 a capability: if halt
;     drained the WAIT first, core 0 has not halted yet and the gift
;     succeeds; a core that halted at once makes it a capop.
; Core 1 prints the result.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

T_NOW = 0x3000                          ; timer NOW
T_DL = 0x3010                           ; DEADLINE
T_WAIT = 0x3018                         ; WAIT

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
wbuf:   .dword 0                        ; WAIT result

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        li    t1, 1                     ; core 1?
        beq   t0, t1, observer          ; core 1 observes
        bnez  t0, park                  ; the other cores stop
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; a0 = NOW
        li    t0, 20000                 ; 20 ms ahead
        add   a1, a0, t0                ; the deadline
        li    a0, T_DL                  ; DEADLINE
        call  devwr                     ; set it
        la    t0, wbuf                  ; WAIT buffer
        li    t1, T_WAIT                ; WAIT port
        li    t2, 8                     ; 8 bytes
        tget  tg1, t0, c3, t1, t2       ; in flight for 20000 ticks
        li    t0, 1                     ; core 1
        cgive c2, t0                    ; "about to halt"
        li    a0, 0                     ; exit code
        halt                            ; must wait for the WAIT read first
observer:
        li    t0, 0                     ; from core 0
        ctake c5, t0                    ; its token
        li    t2, 1000                  ; a short delay (a few tens of ticks)
ob_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, ob_spin               ; loop
        li    t0, 0                     ; core 0
ob_give:
        cgive c5, t0                    ; give it back: core 0 is still draining its halt
        li    a0, 0                     ; expected: no trap
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict
