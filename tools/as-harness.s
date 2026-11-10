; =============================================================================
; as-harness.s: run `as` the way StrataOS's `run as < src > out` would
; =============================================================================
;
; Used by tools/test-as.sh to test the StrataOS front end of os/progs/as.s
; without booting the OS. tools/test-as.sh merges this image (code at I-LS 0)
; with as assembled by `sasm -T 0x8000` (code at I-LS 0x8000, data at D-LS 0)
; into one image and runs it bare metal on core 0.
;
; What it does, mirroring the kernel's do_run / w_run:
;   * reads the console input (the source) into system memory at the
;     program's input offset 0x80000;
;   * cuts c0 down to a 1 MiB arena starting at 0, as the kernel hands out;
;   * enters the program in user mode (eret) at 0x8000 with a0 = input
;     length, a1 = 1 (output redirected); its `halt` traps to the supervisor
;     handler here, as under StrataOS;
;   * on return, copies a0 bytes from arena offset 0xC0000 to the console.
;
; It has no data section (its only buffer is at D-LS 0xA000, which under the
; real OS is kernel data that a program must not touch), so it cannot clash
; with the program's own D-LS image.

HBUF     = 0xA000                       ; D-LS bounce buffer (above the program's data)
HSZ      = 1024                         ; its size
ARENA    = 0x100000                     ; arena size the kernel gives a program
IN_OFF   = 0x80000                      ; arena offset of the program's input
OUT_OFF  = 0xC0000                      ; arena offset of the program's output
PTEXT    = 0x8000                       ; program entry point
CON_IN   = 8                            ; console input port in device space

        .text                           ; harness code at I-LS 0
_start:                                 ; entry at I-LS 0
        li    sp, 0x10000               ; a stack, like the kernel's
        csrr  t0, coreid                ; only core 0 runs the harness
        beqz  t0, h_read                ; core 0: go
        li    a0, 0                     ; others
        halt                            ; stop
h_read:                                 ; core 0: read the source
        li    t0, HBUF + HSZ            ; t0 = one-byte landing slot after the buffer
        li    t1, CON_IN                ; t1 = console input port
        li    t2, 1                     ; t2 = one byte per read
        li    t3, HBUF                  ; t3 = gathering buffer
        li    s0, 0                     ; s0 = bytes read
        li    t5, IN_OFF                ; t5 = input area
hr_loop:                                ; loop: one input byte
        tget  tg1, t0, c3, t1, t2       ; read a byte (waits until one arrives)
        lbu   a0, 0(t0)                 ; the byte
        li    a1, 4                     ; end-of-input marker?
        beq   a0, a1, hr_end            ; yes
        andi  a2, s0, HSZ - 1           ; position in the buffer
        add   a3, t3, a2                ; its address
        sb    a0, 0(a3)                 ; keep the byte
        addi  s0, s0, 1                 ; one more
        andi  a2, s0, HSZ - 1           ; buffer full?
        bnez  a2, hr_loop               ; not yet
        add   a4, t5, s0                ; end of the full buffer's place
        addi  a4, a4, -HSZ              ; its start
        li    a5, HSZ                   ; whole buffer
        tput  tg2, t3, c0, a4, a5       ; to system memory
        j     hr_loop                   ; continue
hr_end:                                 ; end of input: write the partial buffer
        andi  a2, s0, HSZ - 1           ; bytes in the partial buffer
        beqz  a2, h_run                 ; none
        sub   a4, s0, a2                ; input offset of the partial buffer
        add   a4, t5, a4                ; its place in system memory
        addi  a5, a2, 7                 ; length rounded
        srli  a5, a5, 3                 ; up to
        slli  a5, a5, 3                 ; whole words
        tput  tg2, t3, c0, a4, a5       ; write it
h_run:                                  ; start the program
        li    t0, ARENA                 ; arena size
        csplit c5, c0, t0               ; c0 = [0, 1 MiB): the arena; c5 = the rest
        la    t0, h_back                ; the program's halt traps here
        csrw  tvec, t0                  ; (the supervisor trap vector)
        li    t0, PTEXT                 ; the program's entry point
        csrw  epc, t0                   ; is where eret goes
        csrw  status, zero              ; bit 1 clear: eret enters user mode
        mv    a0, s0                    ; a0 = input length
        li    a1, 1                     ; a1 = output redirected
        eret                            ; run it
h_back:                                 ; the program halted: a0 = output length
        mv    s1, a0                    ; s1 = output length
        li    s2, 0                     ; s2 = bytes copied
        li    t3, HBUF                  ; t3 = bounce buffer
hb_loop:                                ; loop: one buffer of output
        bgeu  s2, s1, hb_done           ; all copied
        sub   t4, s1, s2                ; bytes left
        li    t5, HSZ                   ; at most a buffer
        bltu  t4, t5, hb_n              ; fewer left
        mv    t4, t5                    ; a full buffer
hb_n:                                   ; size decided
        addi  t6, t4, 7                 ; read whole words
        srli  t6, t6, 3                 ; ...
        slli  t6, t6, 3                 ; ...
        li    t5, OUT_OFF               ; output area
        add   t5, t5, s2                ; source offset
        tget  tg1, t3, c0, t5, t6       ; arena -> D-LS
        tput  tg2, t3, c2, zero, t4     ; D-LS -> console
        add   s2, s2, t4                ; advance
        j     hb_loop                   ; continue
hb_done:                                ; all copied
        mv    a0, s1                    ; exit code = output length
        halt                            ; stop
