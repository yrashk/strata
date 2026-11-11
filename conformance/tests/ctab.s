; =============================================================================
; ctab.s: the capability save table beyond slot 63 (csavex / crestorex)
; =============================================================================
;
; What it checks
;   * The table has as many slots as the platform table's header says (u16 at
;     offset 20; 256 by default): csavex cs, rx and crestorex cd, rx reach
;     every one of them, slot = x[rx].
;   * The immediate forms and the register forms name the same slots 0..63:
;     csave c, 63 is crestorex c, (63); slot 64 is not slot 0 (no wrap).
;   * The same linearity rules as csave / crestore: a linear capability moves
;     (the source / the slot empties), a copyable one is copied (the slot
;     keeps it); a slot holding a live linear capability is not overwritten
;     (capop, tval = the slot), nor is a live linear destination register
;     (capop, tval = cd).
;   * Out of range: x[rx] >= the table's size traps capop with tval = x[rx]
;     (the whole 64-bit value: 256, 0x10000, -1), for both instructions, and
;     changes nothing; that check comes first (an empty source register at a
;     bad slot is capop, not capinv).
;   * crestorex of an empty slot: capinv, tval = the slot; csavex of an empty
;     register: capinv, tval = the register number.
;   * Every slot holds its own capability: 192 pieces of memory saved in
;     slots 64..255 come back from them in reverse order, each with its own
;     base, and leave every slot empty.
;   (User mode: priv, in traps.s.)

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
hdr:    .space 32                       ; the platform table's header

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test

; ---- the table's size, from the platform table ----------------------------------------
        li    t0, 0x1000                ; the platform table: device window 0x1000
        csplit c5, c3, t0               ; c5 = device space from it on (c3 keeps the rest below)
        la    t1, hdr                   ; its header
        li    t2, 32                    ; ...
        tget  tg0, t1, c5, zero, t2     ; ...
        twait 1                         ; ...
        cjoin c3, c5                    ; c3 whole again
        lhu   s0, hdr+20(zero)          ; s0 = the save table's slots
        mv    a0, s0                    ; 256 by default
        li    a1, 256                   ; ...
        call  chk                       ; check

; ---- the immediate and the register forms name the same slots ---------------------------
        li    t0, 0x1000                ; c12 = [0, 4K) of system memory, linear
        csplit c13, c0, t0              ; c0 keeps [0, 4K), c13 = the rest
        cmov  c12, c0                   ; ...
        cmov  c0, c13                   ; c0 = [4K, ..)
        csave c12, 63                   ; immediate slot 63
        li    t1, 63                    ; ...
        crestorex c11, t1               ; is register slot 63
        cbase a0, c11                   ; base 0
        li    a1, 0                     ; ...
        call  chk                       ; check
        cvalid a0, c12                  ; moved: linear
        li    a1, 0                     ; ...
        call  chk                       ; check
        li    t1, 64                    ; slot 64 is a slot of its own (no wrap to 0)
        csavex c11, t1                  ; ...
        cvalid a0, c11                  ; moved
        li    a1, 0                     ; ...
        call  chk                       ; check
cw1:    crestore c10, 0                 ; slot 0 is still empty
        li    a0, C_CAPINV              ; expected cause
        la    a1, cw1                   ; expected epc
        li    a2, 0                     ; expected tval: the slot
        call  chkt                      ; check
        li    t1, 64                    ; ...
        crestorex c10, t1               ; back from 64
        clen  a0, c10                   ; 4 KiB
        li    a1, 0x1000                ; ...
        call  chk                       ; check

; ---- linearity and replacement in high slots --------------------------------------------
        li    t1, 255                   ; the last slot
        csavex c10, t1                  ; linear: moved
cw2:    csavex c0, t1                   ; a live linear capability there: not overwritten
        li    a0, C_CAPOP               ; expected cause
        la    a1, cw2                   ; expected epc
        li    a2, 255                   ; expected tval: the slot
        call  chkt                      ; check
        cvalid a0, c0                   ; c0 untouched
        li    a1, 1                     ; ...
        call  chk                       ; check
cw3:    crestorex c0, t1                ; onto live linear c0: not overwritten
        li    a0, C_CAPOP               ; expected cause
        la    a1, cw3                   ; expected epc
        li    a2, 0                     ; expected tval: the destination register
        call  chkt                      ; check
        crestorex c10, t1               ; back: the slot empties
cw4:    crestorex c9, t1                ; empty now
        li    a0, C_CAPINV              ; expected cause
        la    a1, cw4                   ; expected epc
        li    a2, 255                   ; expected tval: the slot
        call  chkt                      ; check
        li    t1, 200                   ; a copyable capability: copied
        csavex c2, t1                   ; ...
        cvalid a0, c2                   ; the source stays
        li    a1, 1                     ; ...
        call  chk                       ; check
        crestorex c9, t1                ; and the slot keeps it
        crestorex c8, t1                ; ...
        cperms a0, c8                   ; the console port: device W D
        li    a1, SP_DEV << 8 | P_W | P_D ; ...
        call  chk                       ; check
        csavex c10, t1                  ; a copyable one there may be overwritten
        crestorex c7, t1                ; ...
        cbase a0, c7                    ; the 4K piece again
        li    a1, 0                     ; ...
        call  chk                       ; check
        cclear c8                       ; ...
        cclear c9                       ; ...
cw5:    csavex c14, t1                  ; an empty register
        li    a0, C_CAPINV              ; expected cause
        la    a1, cw5                   ; expected epc
        li    a2, 14                    ; expected tval: the register
        call  chkt                      ; check

; ---- out of range -------------------------------------------------------------------------
        mv    t1, s0                    ; one past the last slot
cr1:    csavex c7, t1                   ; ...
        li    a0, C_CAPOP               ; expected cause
        la    a1, cr1                   ; expected epc
        mv    a2, s0                    ; expected tval: x[rx]
        call  chkt                      ; check
        cvalid a0, c7                   ; nothing moved
        li    a1, 1                     ; ...
        call  chk                       ; check
cr2:    crestorex c6, t1                ; ...
        li    a0, C_CAPOP               ; expected cause
        la    a1, cr2                   ; expected epc
        mv    a2, s0                    ; expected tval
        call  chkt                      ; check
        li    t1, -1                    ; the whole value counts
cr3:    crestorex c6, t1                ; ...
        li    a0, C_CAPOP               ; expected cause
        la    a1, cr3                   ; expected epc
        li    a2, -1                    ; expected tval
        call  chkt                      ; check
        li    t1, 0x10000               ; (not just its low bits: 0x10000 is not slot 0)
cr4:    csavex c14, t1                  ; and before capinv: c14 is empty
        li    a0, C_CAPOP               ; expected cause
        la    a1, cr4                   ; expected epc
        li    a2, 0x10000               ; expected tval
        call  chkt                      ; check

; ---- every slot its own: 192 pieces in slots 64..255 ------------------------------------
        cmov  c13, c7                   ; c13 = [0, 4K), cut into 64-byte pieces
        li    t0, 64                    ; ...
        li    s1, 64                    ; s1 = slot
cp1:
        csplit c14, c13, t0             ; c13 = this piece, c14 = the rest
        csavex c13, s1                  ; -> slot s1
        cmov  c13, c14                  ; ...
        addi  s1, s1, 1                 ; ...
        li    t1, 128                   ; (64 pieces of 4K: slots 64..127)
        blt   s1, t1, cp1               ; ...
        cclear c13                      ; (the empty piece left over)
        li    t1, 0x40000               ; then 128 pieces of 4 KiB from 260K on
        csplit c13, c0, t1              ; c0 = [4K, 260K), c13 = [260K, ..)
        li    t2, 0x1000                ; ...
cp2:
        csplit c14, c13, t2             ; c13 = this piece, c14 = the rest
        csavex c13, s1                  ; -> slot s1
        cmov  c13, c14                  ; ...
        addi  s1, s1, 1                 ; ...
        li    t1, 256                   ; (slots 128..255)
        blt   s1, t1, cp2               ; ...
        cclear c13                      ; (what is left of the region: not needed)
        li    s2, 0                     ; s2 = the sum of the bases, checked
        li    s1, 255                   ; back in reverse order
cp3:
        crestorex c13, s1               ; ...
        cbase t1, c13                   ; its base: 260K + (s1 - 128) * 4K, or (s1 - 64) * 64
        add   s2, s2, t1                ; ...
        cclear c13                      ; (the memory is not needed again)
        addi  s1, s1, -1                ; ...
        li    t1, 64                    ; ...
        bge   s1, t1, cp3               ; ...
        mv    a0, s2                    ; sum: 64 * 64 * 63 / 2 + 128 * 260K + 4K * 128 * 127 / 2
        li    a1, 64 * 64 * 63 / 2 + 128 * 0x41000 + 0x1000 * 128 * 127 / 2 ; ...
        call  chk                       ; check
        li    s1, 64                    ; and every slot is empty now
        li    s3, 0                     ; s3 = the traps counted
cp4:
        crestorex c13, s1               ; capinv each time
        ld    t1, tcause(zero)          ; ...
        addi  t1, t1, -C_CAPINV         ; ...
        bnez  t1, cp4n                  ; ...
        addi  s3, s3, 1                 ; ...
cp4n:
        sd    zero, tcause(zero)        ; (forget the trap)
        sd    zero, tepc(zero)          ; ...
        sd    zero, ttval(zero)         ; ...
        addi  s1, s1, 1                 ; ...
        li    t1, 256                   ; ...
        blt   s1, t1, cp4               ; ...
        mv    a0, s3                    ; 192
        li    a1, 192                   ; ...
        call  chk                       ; check
        li    a0, 0                     ; no trap left unchecked
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict
