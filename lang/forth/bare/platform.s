; =============================================================================
; lang/forth/bare/platform.s: the bare-metal platform layer
; =============================================================================
;
; Everything the kernel needs from the machine goes through these routines,
; so that another backend (StrataOS: lang/forth/os/platform.s) can replace
; them. They are internal routines: arguments in a0.., clobber t0..t2 and
; a0..a2 at most (callers rely on that), never s registers.
;
; Capabilities at power-on (emu/emu.c, sim/main.cpp), core 0:
;   c0 all of system memory (T3, 64 MiB, rwx)   c1 the cluster store (T2, rwx)
;   c2 console output (copyable)                c3 the device space (copyable)
;   c4 core control (copyable)
; Other cores get only c2. plat_init carves core 0's memory into:
;   c0  T3 [0, 1 MiB)        the kernel's: I-LS mirror, core.fs, snapshot
;   c8  T3 [2 MiB, 48 MiB)   the heap behind far@ / far! (far address 0 = its start)
;   c9  T3 [48 MiB, 64 MiB)  the framebuffer window
;   c10 T3 what is left of [1 MiB, 2 MiB) after each worker got a 64 KiB page
;   c1  T2 [0, 4 KiB)        the job board, made atomic (copyable)
;   c12 T2 [4 KiB, 256 KiB)  free for programs
; (c7 is the kernel's scratch register; the board is c1 and the scratch c7 on
; every platform, because c0..c7 are all a StrataOS process keeps.)
; and gives every worker its page (its c0, for xexec trampolines) and a copy
; of the board.

PL_T3_FB   = 0x3000000                  ; framebuffer window: [48 MiB, 64 MiB)
PL_T3_HEAP = 0x200000                   ; heap starts at 2 MiB
PL_T3_SYS  = 0x100000                   ; the kernel keeps [0, 1 MiB)
PL_PAGE    = 0x10000                    ; a worker's private page
PL_BOARD   = 4096                       ; bytes of the job board
PL_CON_IN  = 0x0008                     ; device space: console input port
PL_NOW     = 0x3000                     ; timer NOW
PL_DEADLINE = 0x3010                    ; timer DEADLINE
PL_WAIT    = 0x3018                     ; timer WAIT

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

; plat_write(a0 = D-LS address, a1 = length): console output
plat_write:                             ; one transfer to the console device
        tput  tg15, a0, c2, zero, a1    ; returns at once; reusing the buffer waits for it
        ret                             ; done

; plat_key -> a0 = the next input byte (0x04 at the end of input)
plat_key:                               ; a device read that completes when a key arrives
        la    t0, v_kbuf                ; where the byte lands
        li    t1, PL_CON_IN             ; the console input port
        li    t2, 1                     ; one byte
        tget  tg14, t0, c3, t1, t2      ; stays in flight until a byte arrives
        lbu   a0, v_kbuf(zero)          ; this load waits for it
        ret                             ; done

; plat_ticks -> a0 = microseconds since power-on
plat_ticks:                             ; read the timer's NOW register
        la    t0, v_tick                ; 8 bytes of D-LS
        li    t1, PL_NOW                ; NOW
        li    t2, 8                     ; one register
        tget  tg10, t0, c3, t1, t2      ; device -> D-LS
        ld    a0, v_tick(zero)          ; waits for it
        ret                             ; done

; plat_ms(a0 = milliseconds): sleep, by a timer WAIT read
plat_ms:                                ; core 0 only (the machine has one DEADLINE)
        li    t0, 1000                  ; to microseconds
        mul   a2, a0, t0                ; a2 = delay
        mv    a1, ra                    ; plat_ticks leaves a1 alone
        call  plat_ticks                ; a0 = now
        mv    ra, a1                    ; ...
        add   a0, a0, a2                ; the deadline
        sd    a0, v_tick(zero)          ; ...
        la    t0, v_tick                ; ...
        li    t1, PL_DEADLINE           ; DEADLINE register
        li    t2, 8                     ; ...
        tput  tg10, t0, c3, t1, t2      ; set it
        li    t1, PL_WAIT               ; WAIT register
        tget  tg10, t0, c3, t1, t2      ; completes when the deadline passes
        ld    a0, v_tick(zero)          ; waits for that
        ret                             ; done

; plat_fget(a0 = D-LS, a1 = far address, a2 = bytes): far cache fill
plat_fget:                              ; from the heap capability
        tget  tg12, a0, c8, a1, a2      ; heap -> D-LS
        ret                             ; done
; plat_fput(a0 = D-LS, a1 = far address, a2 = bytes): far cache write-back
plat_fput:                              ; to the heap capability
        tput  tg12, a0, c8, a1, a2      ; D-LS -> heap
        ret                             ; done

; plat_source -> a0 = c0 offset of the core.fs text, a1 = its length.
; Bare metal: it is embedded in the image's far section (see forth.s).
plat_source:                            ; leaf
        la    a0, core_fs               ; start
        la    a1, core_fs_end           ; end
        sub   a1, a1, a0                ; length
        ret                             ; done

; plat_bye(a0 = exit code): stop (the workers were told already)
plat_bye:                               ; never returns
        halt                            ; halting drains our transfers first

; plat_tool(a0 = name, a1 = length) -> a0 = 0: no word is loaded on demand
; here (the tools are part of the embedded source)
plat_tool:                              ; leaf
        li    a0, 0                     ; not a tool
        ret                             ; done

; plat_load(a0 = name, a1 = length, a2 = c0 offset) -> a0 = bytes, or a throw
; code. Bare metal has no files.
plat_load:                              ; leaf
        li    a0, -306                  ; not available on this platform
        ret                             ; done

; ---- lending the image to a worker (see "Lending the image" in forth.s) -------
; plat_lend(t0 = core): give the worker the image: all of c0. Keeps t0.
plat_lend:                              ; leaf
        cgive c0, t0                    ; it installs from it and gives it back
        ret                             ; done
; plat_home: the image came back into the scratch register: it is c0 again.
; Clobbers nothing.
plat_home:                              ; leaf
        cmov  c0, c7                    ; c0 is home
        ret                             ; done
; plat_publish: nothing more to publish than the snapshot (the worker reads
; the code from the mirror in the lent c0)
plat_publish:                           ; leaf
        ret                             ; done
