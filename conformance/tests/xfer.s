; =============================================================================
; xfer.s: transfers (tget / tput / tgetx), tags, hazards, transfer faults,
; far atomics (tamo)
; =============================================================================
;
; What it checks
;   * A transfer takes effect at its issue point ("as if synchronous"); the
;     hardware stalls whatever would see the difference:
;       - a load from bytes an in-flight tget is filling sees the new data;
;       - a store into bytes an in-flight tget is filling lands after it;
;       - a store into bytes an in-flight tput is reading does not change
;         what the tput sends;
;       - a tput / tget of bytes an in-flight tget is filling moves the new data;
;       - a far access (tget, tamo) after a tput / tamo to the same far
;         address sees it;
;       - an instruction fetch from I-LS bytes an in-flight tgetx is filling
;         runs the new code (also when older code there has already run).
;   * Tags: twait waits for the listed tags; afterwards tpoll reports them
;     idle (0) and tany returns them ready. Reusing a busy tag waits.
;   * Faults, checked in this order: capinv (empty / revoked), perm (missing
;     R / W / X; tgetx from device or core control; tget from core control;
;     endpoints), xalign (LS address, offset or length of a memory transfer
;     not a multiple of 8; tval = the offset), bounds (offset + length
;     beyond the capability, without wrapping; for devices: offset >=
;     length), lsfault (Local Store range beyond the D-LS, or the I-LS for
;     tgetx; tval = the LS address). Device transfers need no alignment.
;     A zero-length transfer at offset = length is fine.
;   * tamo.add / swap / cas / and / or: rd = old value, memory updated; cas
;     stores only when memory equals rd's old value. Needs A (perm), 8-byte
;     alignment (xalign) and offset + 8 within the capability (bounds); tval
;     is the offset.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store
        .align 8                        ; transfer buffers are 8-byte aligned
src:    .dword 0x1111111111111111, 0x2222222222222222, 0x3333333333333333, 0x4444444444444444
dst:    .space 32                       ; destination of gets
dst2:   .space 32                       ; second destination
code1:  .word 0x05400000 | 101          ; addi a0, zero, 101    (a function returning 101)
        .word 0xa4010000                ; jalr zero, ra, 0      (ret)
code2:  .word 0x05400000 | 202          ; addi a0, zero, 202    (a function returning 202)
        .word 0xa4010000                ; jalr zero, ra, 0      (ret)
devmsg: .ascii "xfer: device bytes\n"   ; 19 bytes, printed from an odd address below

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    t0, 0x100000              ; 1 MiB
        csplit c5, c0, t0               ; c0 = [0, 1M) of T3, c5 = the rest
        la    s1, src                   ; s1 = source buffer
        la    s2, dst                   ; s2 = destination buffer
        la    s4, dst2                  ; s4 = second destination
        li    s3, 32                    ; s3 = 32 bytes

; ---- put then get, load at once ----------------------------------------------------------
        li    t0, 0x1000                ; far offset 4 KiB
        tput  tg1, s1, c0, t0, s3       ; T3[4K..] = src (32 bytes)
        tget  tg2, s2, c0, t0, s3       ; dst = T3[4K..]: sees the put (same far address, issued later)
        ld    a0, 24(s2)                ; load at once: waits for the get's bytes
        li    a1, 0x4444444444444444    ; the fourth source word
        call  chk                       ; check
        ld    a0, 0(s2)                 ; first word
        li    a1, 0x1111111111111111    ; expected
        call  chk                       ; check

; ---- a store into a buffer an in-flight tput reads does not change what it sends ----------
        li    t0, 0x2000                ; far offset 8 KiB
        tput  tg1, s1, c0, t0, s3       ; send src
        li    t1, -1                    ; t1 = all ones
        sd    t1, 0(s1)                 ; overwrite src[0] at once (waits until the put has read it)
        sd    t1, 24(s1)                ; and src[3]
        tget  tg2, s2, c0, t0, s3       ; read back what was sent
        ld    a0, 0(s2)                 ; first word sent
        li    a1, 0x1111111111111111    ; the old value
        call  chk                       ; check
        ld    a0, 24(s2)                ; last word sent
        li    a1, 0x4444444444444444    ; the old value
        call  chk                       ; check
        li    t1, 0x1111111111111111    ; restore src[0]
        sd    t1, 0(s1)                 ; store
        li    t1, 0x4444444444444444    ; restore src[3]
        sd    t1, 24(s1)                ; store

; ---- a store into a buffer an in-flight tget fills lands after the get ----------------------
        li    t0, 0x1000                ; far offset 4 KiB (holds src)
        tget  tg3, s4, c0, t0, s3       ; dst2 = T3[4K..]
        li    t1, 0x5555                ; t1 = a new value
        sd    t1, 8(s4)                 ; store into dst2[1] at once: must win over the get
        ld    a0, 8(s4)                 ; read it back
        li    a1, 0x5555                ; the store's value
        call  chk                       ; check
        ld    a0, 16(s4)                ; a word only the get wrote
        li    a1, 0x3333333333333333    ; from T3
        call  chk                       ; check

; ---- a transfer out of a buffer an in-flight tget fills moves the new data ------------------
        li    t1, 0                     ; clear dst
        sd    t1, 0(s2)                 ; word 0
        sd    t1, 8(s2)                 ; word 1
        sd    t1, 16(s2)                ; word 2
        sd    t1, 24(s2)                ; word 3
        li    t0, 0x1000                ; T3[4K..] = src
        tget  tg4, s2, c0, t0, s3       ; dst = src (in flight)
        li    t2, 0x3000                ; far offset 12 KiB
        tput  tg5, s2, c0, t2, s3       ; T3[12K..] = dst: must carry the got data
        tget  tg6, s4, c0, t2, s3       ; dst2 = T3[12K..]
        ld    a0, 16(s4)                ; third word
        li    a1, 0x3333333333333333    ; came through both transfers
        call  chk                       ; check

; ---- tags ---------------------------------------------------------------------------------
        twait tg1, tg2, tg3, tg4, tg5, tg6 ; wait for everything above
        tpoll a0, 0x7e                  ; tags 1..6: all idle now
        li    a1, 0                     ; nothing busy
        call  chk                       ; check
        li    t0, 0x7e                  ; tags 1..6
        tany  a0, t0                    ; all ready
        li    a1, 0x7e                  ; every selected tag
        call  chk                       ; check
        li    t0, 0x1000                ; T3[4K]
        tget  tg7, s2, c0, t0, s3       ; reuse a tag ...
        tget  tg7, s4, c0, t0, s3       ; ... at once: the second issue waits for the first
        twait tg7                       ; both done
        ld    a0, 8(s2)                 ; first get's data
        li    a1, 0x2222222222222222    ; expected
        call  chk                       ; check
        ld    a0, 8(s4)                 ; second get's data
        li    a1, 0x2222222222222222    ; expected
        call  chk                       ; check
        tfence                          ; wait for every tag (twait 0xffff)
        tpoll a0, 0xffff                ; all idle
        li    a1, 0                     ; expected
        call  chk                       ; check

; ---- the cluster store (T2) --------------------------------------------------------------------
        li    t0, 0x100                 ; T2 offset
        tput  tg1, s1, c1, t0, s3       ; T2[0x100..] = src
        tget  tg2, s4, c1, t0, s3       ; read back
        ld    a0, 16(s4)                ; third word
        li    a1, 0x3333333333333333    ; expected
        call  chk                       ; check

; ---- code: tgetx, then run it at once; replace code that already ran -----------------------
        la    t1, code1                 ; t1 = D-LS code
        li    t0, 0x4000                ; far offset 16 KiB
        li    t2, 8                     ; two instructions
        tput  tg1, t1, c0, t0, t2       ; T3[16K] = code1
        la    t1, code2                 ; second function
        li    t3, 0x4008                ; right after
        tput  tg1, t1, c0, t3, t2       ; T3[16K + 8] = code2
        li    s5, 0xe000                ; s5 = an unused I-LS address
        tgetx tg2, s5, c0, t0, t2       ; I-LS[0xe000] = code1 (in flight)
        jalr  ra, s5, 0                 ; call it at once: the fetch waits for the bytes
        li    a1, 101                   ; code1 returns 101
        call  chk                       ; check
        jalr  ra, s5, 0                 ; call it again (now perhaps translated / cached)
        li    a1, 101                   ; still 101
        call  chk                       ; check
        li    t0, 0x4008                ; code2's far address
        li    t2, 8                     ; two instructions
        tgetx tg3, s5, c0, t0, t2       ; replace the function with code2
        jalr  ra, s5, 0                 ; call it
        li    a1, 202                   ; the new code runs
        call  chk                       ; check

; ---- zero-length transfers ------------------------------------------------------------------
        clen  t0, c0                    ; t0 = c0's length: offset = length
        li    t2, 0                     ; length 0
        tget  tg1, s2, c0, t0, t2       ; allowed: nothing moves
        tput  tg1, s2, c0, t0, t2       ; allowed
        twait tg1                       ; done
        li    a0, 0                     ; no trap so far
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check

; ---- device transfers: any alignment ---------------------------------------------------------
        la    t1, devmsg                ; message (odd length; the address is arbitrary)
        li    t2, 19                    ; 19 bytes
        tput  tg15, t1, c2, zero, t2    ; console output port: one byte per beat
        twait tg15                      ; done
        li    a0, 0                     ; no trap
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check

; ---- faults -----------------------------------------------------------------------------------
        li    t0, P_W                   ; write-only
        li    t1, 0x1000                ; 4 KiB
        csplit c6, c5, t1               ; c5 = 4K piece, c6 = the rest
        crestrict c7, c5, t0            ; c7 = the 4K piece, write-only (c5 consumed)
        li    t1, 8                     ; offset 8
        li    t2, 8                     ; length 8
xf1:    tget  tg1, s2, c7, t1, t2       ; read through a write-only capability
        li    a0, C_PERM                ; expected cause
        la    a1, xf1                   ; expected epc
        li    a2, 8                     ; expected tval: the offset
        call  chkt                      ; check
xf2:    tgetx tg1, s5, c7, t1, t2       ; execute through it
        li    a0, C_PERM                ; expected cause
        la    a1, xf2                   ; expected epc
        li    a2, 8                     ; expected tval
        call  chkt                      ; check
        li    t1, 4                     ; a misaligned offset
xf3:    tget  tg1, s2, c7, t1, t2       ; perm and xalign both apply: perm wins
        li    a0, C_PERM                ; expected cause
        la    a1, xf3                   ; expected epc
        li    a2, 4                     ; expected tval
        call  chkt                      ; check
xf4:    tput  tg1, s2, c7, t1, t2       ; writing is allowed; the offset is misaligned
        li    a0, C_XALIGN              ; expected cause
        la    a1, xf4                   ; expected epc
        li    a2, 4                     ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 0x1000                ; offset = length
        li    t2, 4                     ; misaligned length, also out of bounds
xf5:    tput  tg1, s2, c7, t1, t2       ; xalign before bounds
        li    a0, C_XALIGN              ; expected cause
        la    a1, xf5                   ; expected epc
        li    a2, 0x1000                ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 0x1008                ; past the end
        li    t2, 0                     ; nothing to move
xf6:    tput  tg1, s2, c7, t1, t2       ; offset > length
        li    a0, C_BOUNDS              ; expected cause
        la    a1, xf6                   ; expected epc
        li    a2, 0x1008                ; expected tval
        call  chkt                      ; check
        li    t1, 8                     ; offset 8
        li    t2, -8                    ; a huge length: offset + length wraps
xf7:    tput  tg1, s2, c7, t1, t2       ; must not wrap around into bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, xf7                   ; expected epc
        li    a2, 8                     ; expected tval
        call  chkt                      ; check
        li    t1, 0                     ; offset 0
        li    t2, 16                    ; 16 bytes
        li    t3, 0xfff8                ; the last D-LS word: 16 bytes run past the end
xf8:    tput  tg1, t3, c7, t1, t2       ; Local Store range out of bounds
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xf8                   ; expected epc
        li    a2, 0xfff8                ; expected tval: the LS address
        call  chkt                      ; check
        li    t1, 0x0ff8                ; near the end of c7 too
xf9:    tput  tg1, t3, c7, t1, t2       ; bounds and lsfault: bounds wins
        li    a0, C_BOUNDS              ; expected cause
        la    a1, xf9                   ; expected epc
        li    a2, 0x0ff8                ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 0                     ; offset 0
        li    t3, 0x10000               ; LS address 64K: past the end (16 bytes)
xf10:   tgetx tg1, t3, c0, t1, t2       ; tgetx is checked against the I-LS (also 64 KiB)
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xf10                  ; expected epc
        li    a2, 0x10000               ; expected tval
        call  chkt                      ; check
xf11:   tgetx tg1, s5, c3, zero, t2     ; code from device space
        li    a0, C_PERM                ; expected cause
        la    a1, xf11                  ; expected epc
        li    a2, 0                     ; expected tval
        call  chkt                      ; check
        li    t2, 8                     ; one word
xf12:   tget  tg1, s2, c4, zero, t2     ; reading core control (it is write-only)
        li    a0, C_PERM                ; expected cause
        la    a1, xf12                  ; expected epc
        li    a2, 0                     ; expected tval
        call  chkt                      ; check
        li    t1, 1                     ; offset 1 = length of c2
        li    t2, 1                     ; one byte
xf13:   tput  tg1, s2, c2, t1, t2       ; device: the offset names a port; must be < length
        li    a0, C_BOUNDS              ; expected cause
        la    a1, xf13                  ; expected epc
        li    a2, 1                     ; expected tval
        call  chkt                      ; check

; ---- tamo ------------------------------------------------------------------------------------------
        li    t1, 0x1000                ; 4 KiB
        csplit c8, c6, t1               ; c6 = 4K piece, c8 = the rest
        li    t1, 0x40                  ; offset 0x40 in the piece
        li    t2, 8                     ; one word
        li    t3, 0x1000                ; value 0x1000
        sd    t3, 0(s2)                 ; in dst[0]
        tput  tg1, s2, c6, t1, t2       ; piece[0x40] = 0x1000
        catomic c9, c6                  ; c9 = atomic view of the piece (c6 consumed)
        li    t0, 0x40                  ; t0 = the word's offset
        li    t3, 5                     ; operand 5
        tamo.add a0, c9, t0, t3         ; add 5; a0 = old: sees the put issued before
        li    a1, 0x1000                ; old value
        call  chk                       ; check
        li    t3, 0x77                  ; operand
        tamo.swap a0, c9, t0, t3        ; swap in 0x77
        li    a1, 0x1005                ; old: 0x1000 + 5
        call  chk                       ; check
        li    a0, 0x76                  ; compare value: not equal
        li    t3, 0x99                  ; new value
        tamo.cas a0, c9, t0, t3         ; memory 0x77 != 0x76: no store
        li    a1, 0x77                  ; old value returned
        call  chk                       ; check
        li    a0, 0x77                  ; compare value: equal now
        tamo.cas a0, c9, t0, t3         ; memory = 0x77: store 0x99
        li    a1, 0x77                  ; old value
        call  chk                       ; check
        li    t3, 0x0f                  ; mask
        tamo.and a0, c9, t0, t3         ; 0x99 & 0x0f
        li    a1, 0x99                  ; old value
        call  chk                       ; check
        li    t3, 0x100                 ; bits
        tamo.or a0, c9, t0, t3          ; 0x09 | 0x100
        li    a1, 0x09                  ; old value
        call  chk                       ; check
        tamo.add zero, c9, t0, zero     ; rd = x0: the old value is discarded
        mv    a0, zero                  ; x0
        li    a1, 0                     ; still 0
        call  chk                       ; check
        li    t1, 0x40                  ; read the word back: c9 is atomic-only, so via ...
        li    t3, 0                     ; tamo.or with 0 reads without changing
        tamo.or a0, c9, t1, t3          ; a0 = the current value
        li    a1, 0x109                 ; 0x09 | 0x100
        call  chk                       ; check
        li    t0, 0x44                  ; misaligned
am1:    tamo.add a0, c9, t0, t3         ; xalign
        li    a0, C_XALIGN              ; expected cause
        la    a1, am1                   ; expected epc
        li    a2, 0x44                  ; expected tval: the offset
        call  chkt                      ; check
        li    t0, 0x1000                ; = length
am2:    tamo.add a0, c9, t0, t3         ; offset + 8 beyond the capability
        li    a0, C_BOUNDS              ; expected cause
        la    a1, am2                   ; expected epc
        li    a2, 0x1000                ; expected tval
        call  chkt                      ; check
        li    t0, 0xff8                 ; the last word
        tamo.add a0, c9, t0, t3         ; fine
        li    t0, 0                     ; offset 0
am3:    tamo.add a0, c0, t0, t3         ; c0 has no A
        li    a0, C_PERM                ; expected cause
        la    a1, am3                   ; expected epc
        li    a2, 0                     ; expected tval
        call  chkt                      ; check
am4:    tamo.add a0, c15, t0, t3        ; empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, am4                   ; expected epc
        li    a2, 0                     ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 0x10                  ; split off a 0x10-byte piece of c8 ...
        csplit c10, c8, t1              ; c8 = 16 bytes
        li    t1, 0                     ; ... and an empty one (split points are multiples of 8)
        csplit c11, c8, t1              ; c8 = 0 bytes, c11 = 16 bytes
        catomic c12, c8                 ; atomic, 0 bytes long
am5:    tamo.add a0, c12, zero, t3      ; a capability shorter than a word
        li    a0, C_BOUNDS              ; expected cause
        la    a1, am5                   ; expected epc
        li    a2, 0                     ; expected tval
        call  chkt                      ; check
        catomic c13, c1                 ; atomics on the cluster store (T2) too (c1 consumed)
        li    t0, 0x200                 ; offset
        li    t3, 3                     ; operand
        tamo.swap a0, c13, t0, t3       ; T2[0x200] = 3
        tamo.add a0, c13, t0, t3        ; += 3, old = 3
        li    a1, 3                     ; expected old value
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
