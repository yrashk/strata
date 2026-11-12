; =============================================================================
; lang/forth/bare/init.s: plat_init, the bare-metal platform's start-up
; =============================================================================
;
; Run once, by cold, before core.fs is compiled. forth.s includes this file in
; its start-up part (kboot..kend), which compiled code later overwrites.

; plat_init: carve the capabilities, set up the workers, v_ncores
plat_init:                              ; core 0, once
        li    t0, 0x1000 + 26           ; the platform table's I-LS size (u16 KiB): compiled
        li    t1, 2                     ;   code grows up to CODE_LIMIT, 64 KiB (the D-LS is
        li    t2, DS_BOTTOM             ;   64 KiB already: the image's data reaches 0x9F00,
        tget  tg13, t2, c3, t0, t1      ;   which a smaller D-LS refuses to load)
        lhu   t0, 0(t2)                 ; (the data stack's area: empty at start-up)
        beqz  t0, pi_ls                 ; 0: an older table, 64 KiB
        li    t1, CODE_LIMIT >> 10      ; ...
        beq   t0, t1, pi_ls             ; ...
        la    a0, pi_lsmsg              ; too small: say so and stop
        li    a1, pi_lsmsg_e - pi_lsmsg ; ...
        call  plat_write                ; ...
        twait tg15                      ; ...
        li    a0, 1                     ; exit code 1
        halt                            ; (the workers wait for core 0 for good)
pi_ls:
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

        .data                           ; (D-LS)
pi_lsmsg: .ascii "Strata Forth needs a 64 KiB I-LS\n"
pi_lsmsg_e:
        .far                            ; back to the kernel image
