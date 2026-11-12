; =============================================================================
; lang/forth/guest/boot.s: what the guest image puts directly into the I-LS
; =============================================================================
;
; Included by forth.s in place of its .text section when it is built as a
; StrataOS guest (lang/forth/guest/config.s says how). It is the bare-metal
; stub (lang/forth/bare/boot.s) with the guest's capability registers moved
; into the bare-metal places first.
;
; StrataOS's guest loader (os/kunits/guest.s, u_gload) starts every guest core
; here, in supervisor mode, with a0 = the relative core, coreid / ncores
; already relative to the guest's own cores (corebase / corecount), and:
;   c0 the writable arena (relative core 0 only; the image's .far section is
;      already copied into it, at the offsets bare metal has it in c0)
;   c1 the console endpoint (the tty server)   c2 the clock (NOW, FREQ)
;   c3 core control over the guest's own cores
; The stub moves them to where the bare-metal Forth keeps its devices: c2 the
; console (now an endpoint, not the console port), c3 the clock (in place of
; the device space: NOW is at offset 0 of it), c4 core control; c1 is then
; free for the job board, as on bare metal. Core 0 goes on into the kernel
; (plat_init, guest/init.s, cuts the arena); a worker waits for core 0 as on
; bare metal: its private far page, the board, and (unlike bare metal) its own
; 4 KiB message buffer for the console (c5), then images and doorbells.
        .text                           ; instruction Local Store
_start:                                 ; every guest core starts here
        cmov  c4, c3                    ; core control (own cores) -> c4
        cmov  c3, c2                    ; the clock -> c3
        cmov  c2, c1                    ; the console endpoint -> c2 (c1 is empty now)
        csrr  t0, coreid                ; t0 = this core's number (relative)
        bnez  t0, worker                ; every core but core 0 is a worker
main_core:                              ; install the kernel and start it
        li    t0, KSTART                ; t0 = I-LS address of the kernel, also its c0 offset
        li    t1, kend - KSTART         ; t1 = kernel bytes (a multiple of 8)
        tgetx tg13, t0, c0, t0, t1      ; far memory -> I-LS: the kernel arrives
        la    t0, cold                  ; t0 = the kernel's entry (fetching it waits for the tgetx)
        jr    t0                        ; go
worker:                                 ; a worker core
        li    sp, RS_TOP                ; return stack at the top of D-LS
        cclear c0                       ; (a worker has no arena: c0 is empty anyway)
        ctake c0, zero                  ; our private far page (from core 0 only)
        ctake c1, zero                  ; a copy of the job board (atomics only)
        cclear c5                       ; ...
        ctake c5, zero                  ; our console message buffer (4 KiB)
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
        halt                            ; stop this core (StrataOS's `guest stop` resets it)

        .org  TRAMP                     ; the trampolines (xexec installs into these)
tramp:  .space NTRAMP * 8               ; 8 slots: <instruction> ret
