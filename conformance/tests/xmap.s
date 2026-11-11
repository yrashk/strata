; =============================================================================
; xmap.s: explicit code paging: xmap / xunmap / xcall / xret / xslot, xmiss
; =============================================================================
;
; What it checks
;   * xmap i, rl, cN, ro: overlay map entry i (0..15) says "far address
;     cN.base + x[ro], in cN's space, is at I-LS address x[rl]". Faults:
;     capinv (empty cN; tval = N), perm (no X; tval = N), bounds (offset >=
;     length; tval = offset), lsfault (I-LS address misaligned or >= 64 KiB;
;     tval = it).
;   * xcall rd, cN, ro: looks the far address up; a hit jumps to the mapped
;     I-LS address (links pc + 4 into rd); no entry: xmiss (cause 8, tval =
;     the far address). The space must match too. Faults as for xmap
;     (bounds: offset >= length).
;   * Exact mapping (xslot = 0): an entry matches one far address only.
;   * Slot mapping (xslot = n): an entry covers the 2^n bytes from its far
;     address; a far address inside hits at the same offset in the I-LS
;     slot; a call made from inside a mapped unit links a FAR return
;     address (bit 63 set | far address of pc + 4).
;   * xret rs: bit 63 clear: jump to rs & ~3; set: look the far address up
;     like xcall (xmiss with tval = rs, bit 63 included, if unmapped).
;   * xunmap i forgets entry i. tgetx over a mapped I-LS range forgets the
;     entries pointing into it.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

; ---- code units in system memory (T3): the .far section's addresses are T3 offsets
        .far                            ; system memory image
        .org  0x20000                   ; exact-mapping function
fx:     li    a0, 101                   ; returns 101
        ret                             ; back through ra (an I-LS address)
        .org  0x20008                   ; a second function right after it
fy:     li    a0, 102                   ; returns 102
        ret                             ; back through ra
        .org  0x20100                   ; unit A: 256-byte slot unit
ua:     xcall a3, c0, a4                ; call unit B; from inside a unit: a3 = far link
        mv    s7, a3                    ; keep the link for the test
        xret  a2                        ; return to the resident caller (a2: plain I-LS address)
        .org  0x20200                   ; unit B
ub:     li    a0, 55                    ; returns 55
        xret  a3                        ; return through the far link: back into unit A
        .org  0x20300                   ; end of the units

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    s1, 0xd000                ; s1 = I-LS area for paged code (unused by the test itself)

; ---- exact mapping -------------------------------------------------------------------
        li    t0, fx                    ; t0 = far offset of fx (c0 base is 0)
        li    t1, 16                    ; fx and fy: 16 bytes
        tgetx tg1, s1, c0, t0, t1       ; I-LS[0xd000..] = fx, fy
        xmap  0, s1, c0, t0             ; entry 0: far fx -> I-LS 0xd000
xc1:    xcall ra, c0, t0                ; call fx through the map
        li    a1, 101                   ; it ran
        call  chk                       ; check
        li    t2, fy                    ; fy is at fx + 8, inside the same 16 bytes ...
xc2:    xcall ra, c0, t2                ; ... but exact mapping matches fx only: miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xc2                   ; expected epc
        li    a2, fy                    ; expected tval: the far address
        call  chkt                      ; check
        addi  t3, s1, 8                 ; I-LS address of fy
        xmap  15, t3, c0, t2            ; entry 15: far fy -> I-LS 0xd008
        xcall ra, c0, t2                ; now it hits
        li    a1, 102                   ; fy ran
        call  chk                       ; check
        li    t4, 0x20000               ; the same offset in the cluster store
xc3:    xcall ra, c1, t4                ; c1 is T2: the entry is for T3 (space must match)
        li    a0, C_XMISS               ; expected cause
        la    a1, xc3                   ; expected epc
        li    a2, 0x20000               ; expected tval
        call  chkt                      ; check
        xunmap 0                        ; forget entry 0
xc4:    xcall ra, c0, t0                ; miss again
        li    a0, C_XMISS               ; expected cause
        la    a1, xc4                   ; expected epc
        li    a2, fx                    ; expected tval
        call  chkt                      ; check
        tgetx tg1, s1, c0, t0, t1       ; reload the code over I-LS 0xd000: entry 15 points into it
        twait tg1                       ; done
xc5:    xcall ra, c0, t2                ; entry 15 was forgotten: miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xc5                   ; expected epc
        li    a2, fy                    ; expected tval
        call  chkt                      ; check

; ---- xmap / xcall faults -----------------------------------------------------------------
xm1:    xmap  1, s1, c9, t0             ; empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, xm1                   ; expected epc
        li    a2, 9                     ; expected tval: the register number
        call  chkt                      ; check
        li    t5, P_R | P_W             ; no X
        li    t6, 0x100000              ; 1 MiB
        csplit c6, c0, t6               ; c0 = [0, 1M), c6 = the rest
        crestrict c7, c6, t5            ; c7 = [1M, ...) without X (c6 consumed)
xm2:    xmap  1, s1, c7, zero           ; mapping needs X
        li    a0, C_PERM                ; expected cause
        la    a1, xm2                   ; expected epc
        li    a2, 7                     ; expected tval: the register number
        call  chkt                      ; check
        li    t5, 0x100000              ; = c0's length
xm3:    xmap  1, s1, c0, t5             ; offset beyond the capability
        li    a0, C_BOUNDS              ; expected cause
        la    a1, xm3                   ; expected epc
        li    a2, 0x100000              ; expected tval: the offset
        call  chkt                      ; check
        addi  t5, s1, 2                 ; a misaligned I-LS address
xm4:    xmap  1, t5, c0, t0             ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xm4                   ; expected epc
        addi  a2, s1, 2                 ; expected tval: the I-LS address
        call  chkt                      ; check
        li    t5, 0x10000               ; past the I-LS
xm5:    xmap  1, t5, c0, t0             ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xm5                   ; expected epc
        li    a2, 0x10000               ; expected tval
        call  chkt                      ; check
xm6:    xcall ra, c7, zero              ; xcall needs X
        li    a0, C_PERM                ; expected cause
        la    a1, xm6                   ; expected epc
        li    a2, 7                     ; expected tval
        call  chkt                      ; check
        li    t5, 0x100000              ; = c0's length
xm7:    xcall ra, c0, t5                ; offset beyond the capability
        li    a0, C_BOUNDS              ; expected cause
        la    a1, xm7                   ; expected epc
        li    a2, 0x100000              ; expected tval
        call  chkt                      ; check
xm8:    xcall ra, c9, zero              ; empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, xm8                   ; expected epc
        li    a2, 9                     ; expected tval
        call  chkt                      ; check

; ---- xret with a plain address --------------------------------------------------------------
        la    t5, xr_t                  ; t5 = target
        addi  t5, t5, 3                 ; low bits are ignored
        li    a0, 0                     ; a0 = 0 unless the next instruction runs
        xret  t5                        ; bit 63 clear: jump to t5 & ~3
        li    a0, 99                    ; (skipped)
xr_t:
        li    a1, 0                     ; expected: landed on xr_t
        call  chk                       ; check

; ---- slot mapping: 256-byte units, far return links -------------------------------------------
        li    t5, 8                     ; 2^8 = 256-byte slots
        csrw  xslot, t5                 ; slot mapping
        li    s2, 0xd100                ; I-LS slot for unit A
        li    s3, 0xd200                ; I-LS slot for unit B
        li    t0, ua                    ; far address of unit A
        li    t1, 256                   ; one slot
        tgetx tg1, s2, c0, t0, t1       ; load unit A into its slot
        li    t2, ub                    ; far address of unit B
        tgetx tg1, s3, c0, t2, t1       ; load unit B into its slot
        xmap  2, s2, c0, t0             ; entry 2: unit A
        xmap  3, s3, c0, t2             ; entry 3: unit B
        mv    a4, t2                    ; unit A calls unit B through a4
        li    s7, 0                     ; unit A stores B's link here
        li    a0, 0                     ; result
sl1:    xcall a2, c0, t0                ; call unit A (from resident code: a2 = plain pc + 4)
        li    a1, 55                    ; unit B's result came back through A
        call  chk                       ; check
        mv    a0, s7                    ; the link unit A's xcall produced
        li    a1, 1 << 63 | (ua + 4)    ; bit 63 | the far address after A's xcall
        call  chk                       ; check
        mv    a0, a2                    ; the resident link
        la    a1, sl1+4                 ; plain pc + 4
        call  chk                       ; check
        addi  t3, t0, 4                 ; a far address inside unit A (its second instruction)
        li    s7, 0x1234                ; a marker
        la    a2, sl2                   ; A's tail: mv s7, a3 then xret a2 -> sl2
        li    a3, 0x777                 ; a3 = the value A's `mv s7, a3` copies
        xcall zero, c0, t3              ; enter unit A at its second instruction: hits the slot
sl2:
        mv    a0, s7                    ; A copied a3 into s7
        li    a1, 0x777                 ; expected
        call  chk                       ; check
        xunmap 2                        ; unit A is evicted
        li    t5, 1 << 63 | (ua + 4)    ; a far return link into it
sl3:    xret  t5                        ; it is not mapped: xmiss
        li    a0, C_XMISS               ; expected cause
        la    a1, sl3                   ; expected epc
        li    a2, 1 << 63 | (ua + 4)    ; expected tval: the link, bit 63 included
        call  chkt                      ; check
        li    t6, ub + 0x100            ; the far address just past unit B
sl4:    xcall ra, c0, t6                ; outside every mapped slot
        li    a0, C_XMISS               ; expected cause
        la    a1, sl4                   ; expected epc
        li    a2, ub + 0x100            ; expected tval
        call  chkt                      ; check

; ---- slot sizes at the edges: odd slots, far links with high bits, huge slots -------------------
; (an implementation may hold far addresses narrow; a far link from xret is a full 63-bit key)
        xunmap 3                        ; only entry 4 below
        li    t5, 3                     ; 2^3 = 8-byte slots
        csrw  xslot, t5                 ; slot mapping
        li    t0, fx                    ; fx: li a0, 101; ret (still at I-LS s1 = 0xd000)
        xmap  4, s1, c0, t0             ; entry 4: [fx, fx + 8) -> 0xd000
        addi  t2, t0, 4                 ; fx + 4: its ret
        li    a0, 7                     ; entering at the ret leaves a0 alone
        xcall ra, c0, t2                ; inside the 8-byte slot: jumps to 0xd004
        li    a1, 7                     ; expected
        call  chk                       ; check
        addi  t2, t0, 8                 ; fx + 8: just past the slot
xe1:    xcall ra, c0, t2                ; miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xe1                   ; expected epc
        li    a2, fx + 8                ; expected tval
        call  chkt                      ; check
        li    t5, 1 << 63 | 1 << 40 | fx ; a far link with bit 40 set: not fx
xe2:    xret  t5                        ; miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xe2                   ; expected epc
        li    a2, 1 << 63 | 1 << 40 | fx ; expected tval
        call  chkt                      ; check
        li    t5, 26                    ; 64 MiB slots
        csrw  xslot, t5                 ; slot mapping
        la    t6, xe3b                  ; where to resume after the fetch fault
        sd    t6, tresume(zero)         ; (one-shot)
        li    t5, 1 << 63 | (fx + (1 << 26) - 8) ; inside fx's slot, near its end
xe3:    xret  t5                        ; hits: jumps to 0xd000 + 2^26 - 8, past the I-LS
xe3b:   li    a0, C_IFAULT              ; expected cause: the fetch
        li    a1, 0xd000 + (1 << 26) - 8 ; expected epc: the exact target
        li    a2, 0xd000 + (1 << 26) - 8 ; expected tval
        call  chkt                      ; check
        li    t5, 27                    ; 128 MiB slots
        csrw  xslot, t5                 ; slot mapping
        la    t6, xe4b                  ; resume address
        sd    t6, tresume(zero)         ; (one-shot)
        li    t5, 1 << 63 | (fx + (1 << 27) - 8) ; bit 27 set, still inside the slot
xe4:    xret  t5                        ; hits
xe4b:   li    a0, C_IFAULT              ; expected cause
        li    a1, 0xd000 + (1 << 27) - 8 ; expected epc
        li    a2, 0xd000 + (1 << 27) - 8 ; expected tval
        call  chkt                      ; check
        li    t5, 1 << 63 | (fx + (1 << 27)) ; just past the slot
xe5:    xret  t5                        ; miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xe5                   ; expected epc
        li    a2, 1 << 63 | (fx + (1 << 27)) ; expected tval
        call  chkt                      ; check
        li    t5, 40                    ; 2^40-byte slots
        csrw  xslot, t5                 ; slot mapping
        la    t6, xe6b                  ; resume address
        sd    t6, tresume(zero)         ; (one-shot)
        li    t5, 1 << 63 | (fx + (1 << 40) - 8) ; bit 40 set, inside the slot
xe6:    xret  t5                        ; hits
xe6b:   li    a0, C_IFAULT              ; expected cause
        li    a1, 0xd000 + (1 << 40) - 8 ; expected epc
        li    a2, 0xd000 + (1 << 40) - 8 ; expected tval
        call  chkt                      ; check
        li    t5, 1 << 63 | (1 << 40) | 4 ; bit 40 set, low part below fx: still inside
        la    t6, xe7b                  ; resume address
        sd    t6, tresume(zero)         ; (one-shot)
xe7:    xret  t5                        ; hits
xe7b:   li    a0, C_IFAULT              ; expected cause
        li    a1, 0xd000 + (1 << 40) + 4 - fx ; expected epc
        li    a2, 0xd000 + (1 << 40) + 4 - fx ; expected tval
        call  chkt                      ; check
        li    t5, 1 << 63 | (fx + (1 << 40)) ; just past the slot
xe8:    xret  t5                        ; miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xe8                   ; expected epc
        li    a2, 1 << 63 | (fx + (1 << 40)) ; expected tval
        call  chkt                      ; check
        li    t5, 1 << 63 | 4           ; below fx
xe9:    xret  t5                        ; miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xe9                   ; expected epc
        li    a2, 1 << 63 | 4           ; expected tval
        call  chkt                      ; check
        li    t5, 63                    ; the largest slot
        csrw  xslot, t5                 ; slot mapping
        la    t6, xe10b                 ; resume address
        sd    t6, tresume(zero)         ; (one-shot)
        li    t5, 1 << 63 | 1 << 62     ; any key at or above fx hits
xe10:   xret  t5                        ; hits
xe10b:  li    a0, C_IFAULT              ; expected cause
        li    a1, 0xd000 + (1 << 62) - fx ; expected epc
        li    a2, 0xd000 + (1 << 62) - fx ; expected tval
        call  chkt                      ; check
        li    t5, 3                     ; tgetx over [0xd008, 0xd010): past entry 4's 8-byte slot
        csrw  xslot, t5                 ; slot mapping
        addi  t3, s1, 8                 ; 0xd008
        li    t2, fy                    ; fy's code
        li    t1, 8                     ; one word
        tgetx tg1, t3, c0, t2, t1       ; reload fy's word: entry 4 survives
        twait tg1                       ; done
        li    a0, 7                     ; as before
        addi  t2, t0, 4                 ; fx + 4
        xcall ra, c0, t2                ; still mapped
        li    a1, 7                     ; expected
        call  chk                       ; check
        tgetx tg1, s1, c0, t0, t1       ; tgetx over [0xd000, 0xd008): entry 4 is forgotten
        twait tg1                       ; done
        addi  t2, t0, 4                 ; fx + 4
xe11:   xcall ra, c0, t2                ; miss
        li    a0, C_XMISS               ; expected cause
        la    a1, xe11                  ; expected epc
        li    a2, fx + 4                ; expected tval
        call  chkt                      ; check
        csrw  xslot, zero               ; back to exact mapping
        j     done                      ; print the signature and the verdict
