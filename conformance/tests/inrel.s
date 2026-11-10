; =============================================================================
; inrel.s: the release port completes console input reads that wait
; =============================================================================
; stdin: open
;
; What it checks (common/platform.h, doc/strataos.md 1.2)
;   * With console input that is open but has nothing to give (the runner's
;     FIFO), a read of the input port waits.
;   * One write to the release port (0x18) completes it with 0 on all 8
;     bytes, as it completes a waiting break read: `halt` drains pending
;     reads, so software that stops a core waiting for a key can release
;     it (StrataOS does at halt).

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

C_IN  = 0x0008                          ; console input port
C_REL = 0x0018                          ; console release port

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
ibuf:   .dword -1                       ; input read target

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        la    s1, ibuf                  ; s1 = buffer
        li    t0, C_IN                  ; input port
        li    t1, 8                     ; 8 bytes
        tget  tg2, s1, c3, t0, t1       ; waits: nothing comes
        li    t2, 2000                  ; let it be tried
ir_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, ir_spin               ; loop
        li    a0, C_REL                 ; release
        li    a1, 0                     ; (ignored)
        call  devwr                     ; ...
        twait tg2                       ; it completes
        ld    a0, 0(s1)                 ; with 0
        li    a1, 0                     ; ...
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
