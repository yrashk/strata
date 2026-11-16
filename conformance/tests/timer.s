; =============================================================================
; timer.s: the timer (device 0x3000) and the framebuffer controller (0x4000)
; =============================================================================
;
; What it checks (doc/strataos.md section 1.2; common/platform.h)
;   * FREQ (0x3008) reads 1000000 (1 tick = 1 us).
;   * EPOCH (0x3020) and ZONE (0x3028) read what the host gave the machine:
;     conformance/run.sh sets STRATA_EPOCH=1763109000,-25200, so EPOCH is
;     1763109000 * 10^6 and ZONE is -25200 (signed, 64 bits).
;   * NOW (0x3000) never goes backwards; a register is LATCHED when its byte
;     0 is read: reading byte 0, waiting, then reading bytes 1..7 gives the
;     value of the moment byte 0 was read, not a torn mix.
;   * DEADLINE (0x3010) resets to 0 and reads back what was written; a write
;     takes effect when its byte 7 is written (a write of bytes 0..3 alone
;     changes nothing; bytes 4..7 later complete it); reading is latched at
;     byte 0 too.
;   * WAIT (0x3018) completes once NOW >= DEADLINE and returns NOW: the
;     value is >= DEADLINE, and NOW read afterwards is >= it. While it
;     waits its tag is busy (tpoll). Writing DEADLINE re-evaluates a pending
;     wait: writing 0 completes it at once.
;   * VSYNC (0x4008) completes at the next refresh (every 16667 ticks) and
;     returns the frame number: two reads in a row give consecutive frame
;     numbers; NOW afterwards >= frame * 16667.
;   * PRESENT (0x4000) accepts a write.
;   * Unassigned device ports read as zero; a device offset >= the
;     capability's length is a bounds fault, a long transfer starting
;     inside is not.
; Only relations go into the signature (NOW values depend on timing).

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

T_NOW = 0x3000                          ; timer ports
T_FREQ = 0x3008                         ; ticks per second
T_DL = 0x3010                           ; DEADLINE
T_WAIT = 0x3018                         ; WAIT
T_EPOCH = 0x3020                        ; wall clock at NOW = 0, us since 1970
T_ZONE = 0x3028                         ; local time minus UTC, seconds
F_PRESENT = 0x4000                      ; framebuffer controller: PRESENT
F_VSYNC = 0x4008                        ; VSYNC

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
wbuf:   .dword 0                        ; WAIT / VSYNC result
bbuf:   .dword 0                        ; byte-wise reads
qbuf:   .dword 0x1122334455667788, 0    ; a value written in two halves

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test

; ---- FREQ, DEADLINE reset value ---------------------------------------------------------
        li    a0, T_FREQ                ; FREQ
        call  devrd                     ; read it
        li    a1, 1000000               ; 1 MHz
        call  chk                       ; check
        li    a0, T_DL                  ; DEADLINE
        call  devrd                     ; read it
        li    a1, 0                     ; reset value 0
        call  chk                       ; check

; ---- EPOCH and ZONE: as the host set them (run.sh: STRATA_EPOCH) ---------------------------
        li    a0, T_EPOCH               ; EPOCH
        call  devrd                     ; read it
        li    a1, 1763109000000000      ; 1763109000 s
        call  chk                       ; check
        li    a0, T_ZONE                ; ZONE
        call  devrd                     ; read it
        li    a1, -25200                ; UTC-7
        call  chk                       ; check

; ---- NOW is monotonic --------------------------------------------------------------------
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; first reading
        mv    s1, a0                    ; s1 = NOW0
        li    t2, 2000                  ; spin a while
nw_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, nw_spin               ; loop
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; second reading
        sltu  a0, a0, s1                ; went backwards?
        li    a1, 0                     ; expected: no
        call  chk                       ; check

; ---- NOW is latched at byte 0 ----------------------------------------------------------------
        la    s2, bbuf                  ; s2 = byte buffer
        sd    zero, 0(s2)               ; clear it
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; s3 = NOW before the latch
        mv    s3, a0                    ; keep it
        li    t0, T_NOW                 ; port of byte 0
        li    t1, 1                     ; one byte
        tget  tg1, s2, c3, t0, t1       ; read byte 0: latches the whole register
        twait tg1                       ; done
        li    t2, 100000                ; spin long enough for NOW to move by more than 256 ticks
lt_spin:
        addi  t2, t2, -1                ; count down
        bnez  t2, lt_spin               ; loop
        addi  t3, s2, 1                 ; bytes 1..7 of the buffer
        li    t0, T_NOW + 1             ; ports of bytes 1..7
        li    t1, 7                     ; seven bytes
        tget  tg1, t3, c3, t0, t1       ; read them: from the latch
        ld    s4, 0(s2)                 ; s4 = the assembled value (waits for the bytes)
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; s5 = NOW now
        mv    s5, a0                    ; keep it
        sltu  a0, s4, s3                ; latched value < the reading before it?
        li    a1, 0                     ; expected: no
        call  chk                       ; check
        addi  t0, s4, 256               ; latched + 256
        sltu  a0, s5, t0                ; NOW now < latched + 256? (only if the latch failed or time stood still)
        li    a1, 0                     ; expected: no (the spin took > 256 ticks)
        call  chk                       ; check

; ---- DEADLINE: read back, takes effect at byte 7, read latched ------------------------------
        li    a0, T_DL                  ; DEADLINE
        li    a1, 0x0123456789abcdef    ; a value far in the future
        call  devwr                     ; write all 8 bytes
        li    a0, T_DL                  ; DEADLINE
        call  devrd                     ; read it back
        li    a1, 0x0123456789abcdef    ; expected
        call  chk                       ; check
        la    t2, qbuf                  ; t2 = 0x1122334455667788
        li    t0, T_DL                  ; bytes 0..3
        li    t1, 4                     ; four bytes
        tput  tg1, t2, c3, t0, t1       ; write the low half only
        twait tg1                       ; done
        li    a0, T_DL                  ; DEADLINE
        call  devrd                     ; nothing has taken effect yet
        li    a1, 0x0123456789abcdef    ; expected: the old value
        call  chk                       ; check
        addi  t2, t2, 4                 ; the high half of qbuf
        li    t0, T_DL + 4              ; bytes 4..7
        li    t1, 4                     ; four bytes
        tput  tg1, t2, c3, t0, t1       ; byte 7 written: the whole value takes effect
        twait tg1                       ; done
        li    a0, T_DL                  ; DEADLINE
        call  devrd                     ; read it
        li    a1, 0x1122334455667788    ; expected: both halves
        call  chk                       ; check
        sd    zero, 0(s2)               ; clear the byte buffer
        li    t0, T_DL                  ; byte 0 of DEADLINE
        li    t1, 1                     ; one byte
        tget  tg1, s2, c3, t0, t1       ; read it: latches DEADLINE
        twait tg1                       ; done
        li    a0, T_DL                  ; now change DEADLINE
        li    a1, 0x0aaaaaaaaaaaaaaa    ; to something else
        call  devwr                     ; write
        addi  t3, s2, 1                 ; bytes 1..7 of the buffer
        li    t0, T_DL + 1              ; ports of bytes 1..7
        li    t1, 7                     ; seven bytes
        tget  tg1, t3, c3, t0, t1       ; read: still the latched value
        ld    a0, 0(s2)                 ; assembled
        li    a1, 0x1122334455667788    ; expected: the value at the latch
        call  chk                       ; check

; ---- WAIT --------------------------------------------------------------------------------------
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; a0 = NOW
        li    t0, 3000                  ; 3 ms from now
        add   s6, a0, t0                ; s6 = the deadline
        li    a0, T_DL                  ; DEADLINE
        mv    a1, s6                    ; = s6
        call  devwr                     ; set it
        la    s7, wbuf                  ; s7 = WAIT result buffer
        li    t0, T_WAIT                ; WAIT
        li    t1, 8                     ; 8 bytes
        tget  tg2, s7, c3, t0, t1       ; completes when NOW >= DEADLINE
        ld    s8, 0(s7)                 ; s8 = the value (the load waits)
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; NOW afterwards
        sltu  a0, a0, s8                ; NOW < WAIT's value?
        li    a1, 0                     ; expected: no
        call  chk                       ; check
        sltu  a0, s8, s6                ; WAIT's value < DEADLINE?
        li    a1, 0                     ; expected: no
        call  chk                       ; check
        li    t0, T_WAIT                ; WAIT again: the deadline is past
        li    t1, 8                     ; 8 bytes
        tget  tg2, s7, c3, t0, t1       ; completes at once
        ld    a0, 0(s7)                 ; its value
        sltu  a0, a0, s6                ; < DEADLINE?
        li    a1, 0                     ; expected: no
        call  chk                       ; check
        li    a0, T_DL                  ; DEADLINE
        li    a1, -1                    ; never
        call  devwr                     ; set it
        li    t0, T_WAIT                ; WAIT
        li    t1, 8                     ; 8 bytes
        tget  tg3, s7, c3, t0, t1       ; pending
        tpoll a0, tg3                   ; is tag 3 busy?
        li    a1, 1 << 3                ; expected: busy (the deadline is never)
        call  chk                       ; check
        li    a0, T_DL                  ; DEADLINE
        li    a1, 0                     ; 0: completes pending waits at once
        call  devwr                     ; write it
        twait tg3                       ; the wait completes
        tpoll a0, tg3                   ; idle now
        li    a1, 0                     ; expected
        call  chk                       ; check

; ---- VSYNC -----------------------------------------------------------------------------------------
        li    t0, F_VSYNC               ; VSYNC
        li    t1, 8                     ; 8 bytes
        tget  tg4, s7, c3, t0, t1       ; wait for the next refresh
        ld    s9, 0(s7)                 ; s9 = frame number F1
        tget  tg4, s7, c3, t0, t1       ; and the one after
        ld    s10, 0(s7)                ; s10 = F2
        sub   a0, s10, s9               ; F2 - F1
        li    a1, 1                     ; consecutive frames
        call  chk                       ; check
        li    a0, T_NOW                 ; NOW
        call  devrd                     ; afterwards
        li    t0, 16667                 ; ticks per frame
        mul   t0, s10, t0               ; F2 * 16667
        sltu  a0, a0, t0                ; NOW < the refresh it waited for?
        li    a1, 0                     ; expected: no
        call  chk                       ; check
        li    a0, F_PRESENT             ; PRESENT
        li    a1, 0                     ; the value is ignored
        call  devwr                     ; "this frame is complete"

; ---- device space: unassigned ports, bounds ----------------------------------------------------------
        li    a0, 0x0f00                ; inside the console window, no port there
        call  devrd                     ; reads zeros
        li    a1, 0                     ; expected
        call  chk                       ; check
        li    a0, 0x4ff8                ; the last 8 bytes of device space (unassigned)
        call  devrd                     ; fine
        li    a1, 0                     ; zeros
        call  chk                       ; check
        li    t0, 0x4fff                ; the last port
        li    t1, 16                    ; a transfer running past the end of the capability
        tget  tg1, s2, c3, t0, t1       ; allowed: for devices only the offset is checked
        twait tg1                       ; done
        li    t0, 0x5000                ; offset = c3's length
        li    t1, 1                     ; one byte
dv1:    tget  tg1, s2, c3, t0, t1       ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, dv1                   ; expected epc
        li    a2, 0x5000                ; expected tval: the offset
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict
