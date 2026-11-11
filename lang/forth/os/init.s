; =============================================================================
; lang/forth/os/init.s: plat_init, the StrataOS platform's start-up
; =============================================================================
;
; Run once, by cold, before core.fs is compiled. forth.s includes this file in
; its start-up part (kboot..kend), which the code that comes later overwrites:
; the code cache in paged mode, compiled code with threads (see forth.s).

; -----------------------------------------------------------------------------
; plat_init: handles, the command line, the heap; with threads, the workers
; -----------------------------------------------------------------------------
plat_init:                              ; thread 0, once; clobbers t0..t6, a0..a5
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        cbase t0, c0                    ; the arena starts where our memory does
        sd    t0, pl_arena(zero)        ; remember (workers' mirror offsets are relative to it)
        la    t0, pl_start              ; the start-up block -> D-LS
        li    t1, A_START               ; proc wrote it into the arena
        li    t2, 512                   ; its size
        tget  tg9, t0, c0, t1, t2       ; arena -> D-LS
        la    t3, pl_iobuf              ; then clear it in the arena (the buffer is still zero):
        tput  tg9, t3, c0, t1, t2       ; the block lies inside the far heap, which starts zeroed
        li    t3, 0                     ; t3 = handle 0..2
pi_h:                                   ; one standard handle per iteration
        slli  t4, t3, 3                 ; its descriptor is at offset 16 + 8 h
        add   t5, t0, t4                ; ...
        ld    t5, 16(t5)                ; server register << 32 | id, or -1 (waits for the tget)
        bltz  t5, pi_hn                 ; closed
        srli  t6, t5, 32                ; the server's register
        sd    t6, pl_hreg(t4)           ; ...
        slli  t6, t5, 32                ; the server's id: the low half
        srli  t6, t6, 32                ; ...
        sd    t6, pl_hid(t4)            ; ...
pi_hn:                                  ; next handle
        addi  t3, t3, 1                 ; ...
        li    t6, 3                     ; three of them
        blt   t3, t6, pi_h              ; continue
        ld    t0, pl_hreg(zero)         ; is standard input the console?
        addi  t0, t0, -R_TTY            ; 0 if it is
        sltu  t0, zero, t0              ; 1 if it is a file or a pipe:
        sd    t0, v_echo(zero)          ; then the line editor echoes (the tty did not)
        ld    t0, pl_hreg+8(zero)       ; is standard output the console?
        addi  t0, t0, -R_TTY            ; 0 if it is
        sltiu t0, t0, 1                 ; 1 if it is:
        sd    t0, v_nlflush(zero)       ; then every line goes out at once
        la    t0, pl_start              ; the command line: "forth args"
        ld    t1, 40(t0)                ; its length
        addi  t2, t0, 64                ; t2 = cursor
        add   t1, t2, t1                ; t1 = end
        li    t4, ' '                   ; the separator
pi_name:                                ; skip the program's name
        bgeu  t2, t1, pi_heap           ; nothing after it: the console
        lbu   t3, 0(t2)                 ; a character
        beq   t3, t4, pi_sp             ; the name ended
        addi  t2, t2, 1                 ; next
        j     pi_name                   ; continue
pi_sp:                                  ; skip the spaces after it
        bgeu  t2, t1, pi_heap           ; nothing after them: the console
        lbu   t3, 0(t2)                 ; a character
        bne   t3, t4, pi_arg            ; an argument starts
        addi  t2, t2, 1                 ; next
        j     pi_sp                     ; continue
pi_arg:                                 ; "-e text" or "file [text]"
        li    t5, '-'                   ; "-e " ?
        bne   t3, t5, pi_file           ; no: a file name
        lbu   t3, 1(t2)                 ; ...
        li    t5, 'e'                   ; ...
        bne   t3, t5, pi_file           ; ...
        lbu   t3, 2(t2)                 ; ...
        bne   t3, t4, pi_file           ; ...
        addi  t2, t2, 3                 ; the text after "-e " is the command
        j     pi_cmd                    ; ...
pi_file:                                ; a file: the command is "include file ..."
        addi  t2, t2, -8                ; eight bytes before the name (over "forth " and the header's end)
        la    t3, pl_inc                ; "include "
        li    t5, 0                     ; index
pi_inc:                                 ; copy it in front of the name
        add   t6, t3, t5                ; source byte
        lbu   t6, 0(t6)                 ; ...
        add   a0, t2, t5                ; destination
        sb    t6, 0(a0)                 ; ...
        addi  t5, t5, 1                 ; next
        li    t6, 8                     ; eight bytes
        blt   t5, t6, pi_inc            ; continue
pi_cmd:                                 ; t2 = the text, t1 = its end
        sd    t2, v_cmd(zero)           ; cold interprets it instead of the console, then leaves
        sub   t1, t1, t2                ; its length
        sd    t1, v_cmd+8(zero)         ; ...
pi_heap:                                ; the far heap: everything from A_HEAP up
        li    t0, A_HEAP                ; c0 keeps [0, A_HEAP)
        csplit c6, c0, t0               ; c6 = the heap
        li    t0, 6                     ; far@ / far! go through c6
        sd    t0, v_heapc(zero)         ; (heap-cap)
        csrr  t0, corecount             ; threads?
        beqz  t0, pi_done               ; no: one thread, v_ncores stays 1
        sd    t0, v_ncores(zero)        ; the threads of this process are our "cores"
        clen  t0, c6                    ; the job board: the top 4 KiB of the heap
        li    t1, 4096                  ; ...
        sub   t0, t0, t1                ; ...
        csplit c7, c6, t0               ; c7 = the board's memory (the arena starts zeroed)
        catomic c1, c7                  ; c1 = the board, atomics only, copyable (replaces proc's endpoint)
        li    a5, 1                     ; a5 = worker thread 1 first
pi_w:                                   ; one worker per iteration
        ld    t0, v_ncores(zero)        ; all set up?
        bgeu  a5, t0, pi_done           ; yes
        clen  t0, c6                    ; its page: the top 32 KiB of the heap
        li    t1, PL_PAGE               ; ...
        sub   t0, t0, t1                ; ...
        csplit c7, c6, t0               ; c7 = the page
        cbase t0, c7                    ; the page's header: where the page is in the arena
        ld    t1, pl_arena(zero)        ; ...
        sub   t0, t0, t1                ; ...
        sd    t0, pl_wh(zero)           ; word 0: what the worker passes to SET_MIRROR
        li    t0, kend                  ; word 1: the end of the code in the page
        sd    t0, pl_wh+8(zero)         ; ...
        la    t0, pl_wh                 ; header -> the page's last 16 bytes
        li    t1, PL_WHDR               ; ...
        li    t2, 16                    ; two words
        tput  tg13, t0, c7, t1, t2      ; ...
        li    a4, ORIGIN                ; a4 = cursor: copy our mirror [ORIGIN, kend) into the page
pi_cp:                                  ; a chunk per iteration, through the bounce buffer
        li    t0, kend                  ; done?
        bgeu  a4, t0, pi_cpd            ; yes
        la    t0, pl_iobuf              ; the bounce buffer
        li    t1, PL_IOSZ               ; a chunk
        tget  tg13, t0, c0, a4, t1      ; mirror -> D-LS
        li    t2, ORIGIN                ; the page holds I-LS address a at offset a - ORIGIN
        sub   t2, a4, t2                ; ...
        tput  tg13, t0, c7, t2, t1      ; D-LS -> page (ordered after the tget)
        addi  a4, a4, PL_IOSZ           ; next chunk
        j     pi_cp                     ; continue
pi_cpd:                                 ; the page is ready
        cgive c7, a5                    ; the worker's c0 (its stub waits for it)
        clen  t0, c6                    ; its message buffer: the next 4 KiB down
        li    t1, 4096                  ; ...
        sub   t0, t0, t1                ; ...
        csplit c7, c6, t0               ; c7 = the buffer
        cgive c7, a5                    ; the worker's c5
        cgive c1, a5                    ; a copy of the board
        cgive c2, a5                    ; copies of our endpoints: the worker's output
        cgive c3, a5                    ; goes where ours goes
        cgive c4, a5                    ; ...
        addi  a5, a5, 1                 ; next worker
        j     pi_w                      ; continue
pi_done:                                ; ready
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
