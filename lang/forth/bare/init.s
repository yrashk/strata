; =============================================================================
; lang/forth/bare/init.s: plat_init, the bare-metal platform's start-up
; =============================================================================
;
; Run once, by cold, before core.fs is compiled. forth.s includes this file in
; its start-up part (kboot..kend), which compiled code later overwrites.

; plat_init: carve the capabilities, set up the workers, v_ncores
plat_init:                              ; core 0, once
        csrr  t0, ncores                ; every core of the machine is ours
        sd    t0, v_ncores(zero)        ; ...
        li    t0, PL_T3_FB              ; c9 = the framebuffer window
        csplit c9, c0, t0               ; ...
        li    t0, PL_T3_HEAP            ; c8 = the heap
        csplit c8, c0, t0               ; ...
        li    t0, PL_T3_SYS             ; c10 = the pages for workers, c0 = ours
        csplit c10, c0, t0              ; ...
        li    t0, PL_BOARD              ; c1 = the board's 4 KiB, c12 = the rest
        csplit c12, c1, t0              ; ... of the cluster store, free for programs
        catomic c7, c1                  ; the board, atomics only, copyable (c1 is empty now)
        cmov  c1, c7                    ; c1 = the board
        cclear c7                       ; the scratch register stays empty
        li    a0, 1                     ; worker 1 first
pi_loop:                                ; one worker per iteration
        ld    t1, v_ncores(zero)        ; ...
        bgeu  a0, t1, pi_done           ; all set up
        li    t0, PL_PAGE               ; c10 = its page, c11 = the rest
        csplit c11, c10, t0             ; ...
        cgive c10, a0                   ; the page is the worker's now
        cmov  c10, c11                  ; the rest back in c10
        cgive c1, a0                    ; and a copy of the board
        addi  a0, a0, 1                 ; next worker
        j     pi_loop                   ; ...
pi_done:                                ; ...
        ret                             ; done
