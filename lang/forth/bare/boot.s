; =============================================================================
; lang/forth/bare/boot.s: what the bare-metal image puts directly into the I-LS
; =============================================================================
;
; Included by forth.s in place of its .text section (the StrataOS backend has
; its own: lang/forth/os/boot.s). Capability registers used here: c0 the
; image / a worker's private page, c1 the job board, c7 the kernel's scratch
; register (what a worker receives lands there first).

; =============================================================================
; .text: the boot stub, the worker loop, the xexec trampolines (bare metal)
; =============================================================================
; This is all the image puts directly into the I-LS. Every core starts here.
; The main core installs the kernel from far memory and jumps to it. A worker
; core waits for core 0: first its private far page and the board, then, any
; number of times, either the image (capability with X permission: install
; it) or a doorbell (a copy of the board capability: read the job).
        .text                           ; instruction Local Store
_start:                                 ; every core starts here
        csrr  t0, coreid                ; t0 = this core's number
        bnez  t0, worker                ; every core but core 0 is a worker
main_core:                              ; install the kernel and start it
        li    t0, KSTART                ; t0 = I-LS address of the kernel, also its c0 offset
        li    t1, kend - KSTART         ; t1 = kernel bytes (a multiple of 8)
        tgetx tg13, t0, c0, t0, t1      ; far memory -> I-LS: the kernel arrives
        la    t0, cold                  ; t0 = the kernel's entry (fetching it waits for the tgetx)
        jr    t0                        ; go
worker:                                 ; a worker core
        li    sp, RS_TOP                ; return stack at the top of D-LS
        ctake c0, zero                  ; our private far page (from core 0 only)
        ctake c1, zero                  ; a copy of the job board (atomics only)
w_loop:                                 ; wait for core 0
        ctake c7, zero                  ; the next capability core 0 gives us
        cperms t0, c7                   ; t0 = space << 8 | permissions
        andi  t0, t0, P_X               ; executable?
        beqz  t0, w_job                 ; no: it is the doorbell
        li    t1, B_CEND                ; board offset of the published code end
        tamo.add t1, c1, t1, zero       ; t1 = code end (an atomic add of 0 is a read)
        li    t0, KSTART                ; t0 = start of the kernel in the I-LS and in c0
        sub   t2, t1, t0                ; t2 = bytes of kernel + compiled code
        tgetx tg13, t0, c7, t0, t2      ; install all of it into our I-LS
        li    t1, B_SNAP                ; board offset of the snapshot length
        tamo.add t2, c1, t1, zero       ; t2 = snapshot bytes
        li    t1, FAR_SNAP              ; t1 = where the snapshot is in c0
        tget  tg13, zero, c7, t1, t2    ; the data space arrives at D-LS 0
        cgive c7, zero                  ; give the image back (completes after our transfers)
        j     w_loop                    ; and wait for the job
w_job:                                  ; the doorbell: a job or a halt
        cclear c7                       ; drop the doorbell (a copy)
        csrr  t0, coreid                ; t0 = our core number
        slli  t0, t0, 7                 ; times SLOT_SZ (128)
        addi  t0, t0, B_SLOTS + S_CMD   ; t0 = board offset of our command
        tamo.add t1, c1, t0, zero       ; t1 = the command
        li    t2, CMD_RUN               ; t2 = run
        bne   t1, t2, w_halt            ; anything else: stop
        la    t0, worker_run            ; t0 = the kernel's job runner
        jalr  ra, t0, 0                 ; run the job (it rings back when done)
        j     w_loop                    ; next
w_halt:                                 ; core 0 said bye
        li    a0, 0                     ; exit code
        halt                            ; stop this core

        .org  TRAMP                     ; the trampolines (xexec installs into these)
tramp:  .space NTRAMP * 8               ; 8 slots: <instruction> ret
