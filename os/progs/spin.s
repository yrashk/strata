; =============================================================================
; spin.s: burn CPU on purpose, printing a character now and then
; =============================================================================
;
;   spin                  a dot every ~200000 loop iterations, forever
;   spin 20 a             twenty a's, then exit 0
;
; Usage: spin [N [C]]. N = 0 or absent: forever. C defaults to '.'.
; Each character is flushed at once so it appears while the loop runs.
; Used to test Ctrl-C (spin forever, then press Ctrl-C: the shell gives the
; console to this process, which does not catch interrupts and is killed) and
; preemption (`spin 20 a & spin 20 b` on one core: both make progress
; because the kernel time-slices them).

DELAY   = 200000                        ; loop iterations between characters

        .data                           ; data Local Store
        .align 8                        ; aligned buffer
args:   .space 512                      ; the argument text (a command line is at most 440 bytes)

        .text                           ; instruction Local Store
_start:
        j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS 0.1 program
main:
        li    sp, 65536                 ; stack at the top of the D-LS
        call  sys_init                  ; handles and arguments
        li    s0, 0                     ; s0 = count (0 = forever)
        li    s1, '.'                   ; s1 = the character
        la    a0, args                  ; the arguments ...
        call  sys_args                  ; ... a0 = their length
        la    s2, args                  ; s2 = cursor
        add   s3, s2, a0                ; s3 = end
        mv    a0, s2                    ; first word: N
        mv    a1, s3                    ; ...
        call  arg_next                  ; a0 = start, a1 = length, a2 = cursor after
        beqz  a1, loop                  ; no arguments
        mv    s2, a2                    ; keep the cursor
        call  str_atoi                  ; a0 = N (0 if not a number)
        mv    s0, a0                    ; ...
        mv    a0, s2                    ; second word: C
        mv    a1, s3                    ; ...
        call  arg_next                  ; ...
        beqz  a1, loop                  ; none: keep the dot
        lbu   s1, 0(a0)                 ; its first character
loop:
        li    t0, DELAY                 ; t0 = iterations before the next character
wait:
        addi  t0, t0, -1                ; count down
        bnez  t0, wait                  ; busy, on purpose
        mv    a0, s1                    ; the character
        call  out_chr                   ; buffer it
        call  out_flush                 ; and send it now
        beqz  s0, loop                  ; forever: never count
        addi  s0, s0, -1                ; one fewer to go
        bnez  s0, loop                  ; more
        call  out_nl                    ; end the line
        li    a0, 0                     ; exit code
        call  sys_exit                  ; flush stdout, end the process

        .include "../lib/sys.s"         ; the system interface
