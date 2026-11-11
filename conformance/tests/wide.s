; =============================================================================
; wide.s: 64-bit operands against capability bounds
; =============================================================================
;
; What it checks
;   A capability's base and length are 64-bit values architecturally; an
;   implementation may hold them in fewer bits (ch-impl: base + length never
;   exceed the space's size). Offsets, lengths and split points are full
;   64-bit registers, so every bit above the narrow part must still count:
;   * tget / tput: an offset or a length with a high bit set is out of bounds
;     (bounds, tval = the offset), also when its low bits would fit; the
;     offset equal to the length with length 0 is in bounds; a device
;     capability's port number likewise.
;   * tamo: an offset with a high bit set (bounds, tval = it).
;   * csplit: a split point with a high bit set (capop, tval = it); a split
;     at the whole length leaves an empty remainder whose base is the end.
;   * xmap / xcall: an offset with a high bit set (bounds, tval = it).
;   * cbase / clen of the whole of system memory and of its last byte.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    s2, 0xb000                ; s2 = a D-LS buffer

; ---- tget / tput offsets and lengths -------------------------------------------------
        li    s3, 0x1000                ; 4 KiB
        csplit c6, c0, s3               ; c0 = [0, 4K), c6 = the rest of system memory
        li    t1, 1 << 40               ; an offset with bit 40 set (low bits 0)
        li    t2, 8                     ; one word
wt1:    tget  tg1, s2, c0, t1, t2       ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wt1                   ; expected epc
        li    a2, 1 << 40               ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 1 << 63 | 8           ; bit 63 and a small offset
wt2:    tput  tg1, s2, c0, t1, t2       ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wt2                   ; expected epc
        li    a2, 1 << 63 | 8           ; expected tval
        call  chkt                      ; check
        li    t1, 0                     ; offset 0
        li    t2, 1 << 32 | 8           ; a length with bit 32 set
wt3:    tget  tg1, s2, c0, t1, t2       ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wt3                   ; expected epc
        li    a2, 0                     ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 8                     ; offset 8
        li    t2, -8                    ; length 2^64 - 8: offset + length wraps to 0
wt4:    tget  tg1, s2, c0, t1, t2       ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wt4                   ; expected epc
        li    a2, 8                     ; expected tval
        call  chkt                      ; check
        li    t1, -8                    ; offset 2^64 - 8
        li    t2, 8                     ; one word
wt5:    tget  tg1, s2, c0, t1, t2       ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wt5                   ; expected epc
        li    a2, -8                    ; expected tval
        call  chkt                      ; check
        li    t1, 1 << 27               ; offset 2^27: bit 27, beyond the 64 MiB of system memory
        li    t2, 0                     ; nothing
wt6:    tget  tg1, s2, c6, t1, t2       ; out of bounds even with length 0
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wt6                   ; expected epc
        li    a2, 1 << 27               ; expected tval
        call  chkt                      ; check
        li    t1, 0x1000                ; offset = c0's length
        li    t2, 0                     ; length 0
        tget  tg1, s2, c0, t1, t2       ; in bounds: moves nothing
        twait tg1                       ; done
        li    a0, 0                     ; no trap
        li    a1, 0                     ; (none recorded)
        li    a2, 0                     ;
        call  chkt                      ; check
        li    t1, 1 << 48               ; a device port number with bit 48 set
        li    t2, 1                     ; one byte
wt7:    tput  tg1, s2, c2, t1, t2       ; the console capability has one port: out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wt7                   ; expected epc
        li    a2, 1 << 48               ; expected tval
        call  chkt                      ; check

; ---- tamo ----------------------------------------------------------------------------------
        catomic c9, c0                  ; c9 = an atomic view of [0, 4K) (c0 consumed)
        li    t0, 1 << 36 | 0x40        ; bit 36 and an in-range word offset
        li    t3, 1                     ; operand
wa1:    tamo.add a0, c9, t0, t3         ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wa1                   ; expected epc
        li    a2, 1 << 36 | 0x40        ; expected tval: the offset
        call  chkt                      ; check

; ---- csplit --------------------------------------------------------------------------------
        li    t1, 1 << 30 | 8           ; a split point with bit 30 set
ws1:    csplit c7, c6, t1               ; beyond the length: capop
        li    a0, C_CAPOP               ; expected cause
        la    a1, ws1                   ; expected epc
        li    a2, 1 << 30 | 8           ; expected tval: the split point
        call  chkt                      ; check
        clen  t1, c6                    ; the whole length
        csplit c7, c6, t1               ; c6 unchanged, c7 = [end, end)
        clen  a0, c7                    ; empty
        li    a1, 0                     ; expected
        call  chk                       ; check
        cbase a0, c7                    ; at the end of system memory
        li    a1, 0x4000000             ; 64 MiB
        call  chk                       ; check
        cclear c7                       ; drop it
        cbase a0, c6                    ; c6 = [4K, 64M)
        li    a1, 0x1000                ; expected
        call  chk                       ; check
        clen  a0, c6                    ; its length
        li    a1, 0x4000000 - 0x1000    ; expected
        call  chk                       ; check
        li    t1, 0x4000000 - 0x1000 - 8 ; split off the last word
        csplit c7, c6, t1               ; c7 = [64M - 8, 64M)
        cbase a0, c7                    ; its base
        li    a1, 0x4000000 - 8         ; expected
        call  chk                       ; check
        li    t1, 0                     ; offset 0
        li    t2, 8                     ; one word
        li    t3, 0x5a5a                ; a value
        sd    t3, 0(s2)                 ; in the buffer
        tput  tg1, s2, c7, t1, t2       ; the last word of system memory
        sd    zero, 0(s2)               ; clear the buffer
        tget  tg2, s2, c7, t1, t2       ; read it back
        twait tg2                       ; done
        ld    a0, 0(s2)                 ; the word
        li    a1, 0x5a5a                ; expected
        call  chk                       ; check
        cjoin c6, c7                    ; whole again: [4K, 64M)
        clen  a0, c6                    ; its length
        li    a1, 0x4000000 - 0x1000    ; expected
        call  chk                       ; check

; ---- xmap / xcall --------------------------------------------------------------------------
        li    t0, 0xd000                ; an I-LS address
        li    t1, 1 << 44               ; an offset with bit 44 set
wx1:    xmap  0, t0, c6, t1             ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wx1                   ; expected epc
        li    a2, 1 << 44               ; expected tval
        call  chkt                      ; check
wx2:    xcall ra, c6, t1                ; out of bounds
        li    a0, C_BOUNDS              ; expected cause
        la    a1, wx2                   ; expected epc
        li    a2, 1 << 44               ; expected tval
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict
