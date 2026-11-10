; =============================================================================
; caps.s: capability registers and the operations on them
; =============================================================================
;
; What it checks
;   * Reset capabilities of core 0: c0 = all of system memory (T3, R W X),
;     c1 = all of the cluster store (T2, R W X), c2 = the console output port
;     (device, W D, length 1), c3 = all of device space (R W D), c4 = core
;     control (W D, 8 bytes per core); c5..c15 empty.
;   * cbase / clen / cperms (= space << 8 | perms) / cvalid; the first three
;     trap capinv (tval = the register number) on an empty capability,
;     cvalid just answers 0.
;   * Linearity: a capability without D is linear: cmov moves it (the source
;     becomes empty); with D it is copied. No operation may overwrite a live
;     linear capability (capop, tval = the destination register) except
;     cclear, which drops it deliberately.
;   * csplit cd, cs, rx: cs keeps [base, base + x), cd gets the rest; x may
;     be 0 or the whole length; x > length, cd = cs, or a live linear cd:
;     capop (tval = x).
;   * cjoin cd, cs: cd must end exactly where cs begins, same space and
;     perms; cd grows, cs becomes empty; otherwise capop (tval = cs).
;   * cshare: a copyable capability keeping only R and X (+ D); needs R or X
;     (perm, tval = cs); a linear source is consumed, a D source kept.
;   * catomic: an atomic-only capability (A D) of writable memory; needs W
;     and T2/T3 (perm); the source is always consumed.
;   * crestrict cd, cs, rx: perms &= x; it can never add a permission.
;   * csave cs, slot / crestore cd, slot: a 64-entry save table with the
;     same linearity rules (capop for a live linear slot; crestore of an
;     empty slot is capinv, tval = slot).

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test

; ---- reset capabilities -------------------------------------------------------------
        cperms a0, c0                   ; c0 = system memory
        li    a1, SP_T3 << 8 | P_R | P_W | P_X ; T3, R W X
        call  chk                       ; check
        cbase a0, c0                    ; its base
        li    a1, 0                     ; 0
        call  chk                       ; check
        clen  a0, c0                    ; its length
        li    a1, 0x4000000             ; 64 MiB
        call  chk                       ; check
        cperms a0, c1                   ; c1 = cluster store
        li    a1, SP_T2 << 8 | P_R | P_W | P_X ; T2, R W X
        call  chk                       ; check
        clen  a0, c1                    ; its length
        li    a1, 0x40000               ; 256 KiB
        call  chk                       ; check
        cperms a0, c2                   ; c2 = console output
        li    a1, SP_DEV << 8 | P_W | P_D ; device, write-only, copyable
        call  chk                       ; check
        cbase a0, c2                    ; console output port
        li    a1, 0                     ; port 0
        call  chk                       ; check
        clen  a0, c2                    ; one port
        li    a1, 1                     ; length 1
        call  chk                       ; check
        cperms a0, c3                   ; c3 = device space
        li    a1, SP_DEV << 8 | P_R | P_W | P_D ; device, R W D
        call  chk                       ; check
        clen  a0, c3                    ; its length
        li    a1, 0x5000                ; the five device windows
        call  chk                       ; check
        cperms a0, c4                   ; c4 = core control
        li    a1, SP_CORE << 8 | P_W | P_D ; core control, W D
        call  chk                       ; check
        clen  a0, c4                    ; 8 bytes per core
        csrr  a1, ncores                ; a1 = core count
        slli  a1, a1, 3                 ; expected: ncores * 8
        call  chk                       ; check
        cvalid a0, c5                   ; c5 is empty
        li    a1, 0                     ; expected 0
        call  chk                       ; check
        cvalid a0, c0                   ; c0 is valid
        li    a1, 1                     ; expected 1
        call  chk                       ; check
inv1:   cbase a0, c9                    ; base of an empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, inv1                  ; expected epc
        li    a2, 9                     ; expected tval: the register number
        call  chkt                      ; check
inv2:   clen  a0, c15                   ; length of an empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, inv2                  ; expected epc
        li    a2, 15                    ; expected tval
        call  chkt                      ; check
inv3:   cperms a0, c5                   ; perms of an empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, inv3                  ; expected epc
        li    a2, 5                     ; expected tval
        call  chkt                      ; check
inv4:   cmov  c6, c5                    ; moving an empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, inv4                  ; expected epc
        li    a2, 5                     ; expected tval: the source register
        call  chkt                      ; check

; ---- csplit -----------------------------------------------------------------------
        li    t0, 0x10000               ; t0 = 64 KiB
        csplit c5, c0, t0               ; c0 = [0, 64K), c5 = [64K, 64M)
        clen  a0, c0                    ; c0 length
        li    a1, 0x10000               ; 64 KiB
        call  chk                       ; check
        cbase a0, c5                    ; c5 base
        li    a1, 0x10000               ; 64 KiB
        call  chk                       ; check
        clen  a0, c5                    ; c5 length
        li    a1, 0x4000000 - 0x10000   ; the rest
        call  chk                       ; check
        cperms a0, c5                   ; same space and perms
        li    a1, SP_T3 << 8 | 7        ; T3 R W X
        call  chk                       ; check
        li    t0, 0x1000                ; t0 = 4 KiB
        csplit c6, c0, t0               ; c0 = [0, 4K), c6 = [4K, 64K)
        li    t0, 0x1000                ; split at the whole length
        csplit c7, c0, t0               ; c7 = [4K, 4K): empty range, still valid
        cvalid a0, c7                   ; valid?
        li    a1, 1                     ; yes
        call  chk                       ; check
        clen  a0, c7                    ; its length
        li    a1, 0                     ; zero
        call  chk                       ; check
        cbase a0, c7                    ; its base
        li    a1, 0x1000                ; the end of c0
        call  chk                       ; check
        clen  a0, c0                    ; c0 unchanged
        li    a1, 0x1000                ; 4 KiB
        call  chk                       ; check
        cclear c7                       ; drop the empty piece
        li    t0, 0x1001                ; one past the length
spl1:   csplit c7, c0, t0               ; split beyond the end
        li    a0, C_CAPOP               ; expected cause
        la    a1, spl1                  ; expected epc
        li    a2, 0x1001                ; expected tval: the offset
        call  chkt                      ; check
        li    t0, 8                     ; a fine offset
spl2:   csplit c0, c0, t0               ; cd = cs
        li    a0, C_CAPOP               ; expected cause
        la    a1, spl2                  ; expected epc
        li    a2, 8                     ; expected tval: the offset
        call  chkt                      ; check
spl3:   csplit c6, c0, t0               ; destination c6 holds a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, spl3                  ; expected epc
        li    a2, 8                     ; expected tval: the offset
        call  chkt                      ; check
        clen  a0, c0                    ; nothing changed
        li    a1, 0x1000                ; c0 still 4 KiB
        call  chk                       ; check
        clen  a0, c6                    ; and c6
        li    a1, 0x10000 - 0x1000      ; still 60 KiB
        call  chk                       ; check

; ---- cjoin ----------------------------------------------------------------------------
cj1:    cjoin c6, c0                    ; c6 = [4K, 64K) does not end where c0 = [0, 4K) begins
        li    a0, C_CAPOP               ; expected cause
        la    a1, cj1                   ; expected epc
        li    a2, 0                     ; expected tval: the source register (c0)
        call  chkt                      ; check
        cjoin c0, c6                    ; c0 ends where c6 begins: c0 = [0, 64K)
        clen  a0, c0                    ; joined length
        li    a1, 0x10000               ; 64 KiB
        call  chk                       ; check
        cvalid a0, c6                   ; the source is consumed
        li    a1, 0                     ; empty
        call  chk                       ; check
cj2:    cjoin c0, c0                    ; joining with itself
        li    a0, C_CAPOP               ; expected cause
        la    a1, cj2                   ; expected epc
        li    a2, 0                     ; expected tval: cs = c0
        call  chkt                      ; check
cj3:    cjoin c0, c6                    ; c6 is empty
        li    a0, C_CAPINV              ; expected cause
        la    a1, cj3                   ; expected epc
        li    a2, 6                     ; expected tval: cs
        call  chkt                      ; check
        li    t0, 0x8000                ; 32 KiB
        csplit c6, c0, t0               ; c0 = [0, 32K), c6 = [32K, 64K)
        li    t0, P_R                   ; read only
        crestrict c6, c6, t0            ; c6 = [32K, 64K) read-only (in place)
cj4:    cjoin c0, c6                    ; adjacent, but the permissions differ
        li    a0, C_CAPOP               ; expected cause
        la    a1, cj4                   ; expected epc
        li    a2, 6                     ; expected tval
        call  chkt                      ; check
cj5:    cjoin c1, c5                    ; different spaces (T2 and T3)
        li    a0, C_CAPOP               ; expected cause
        la    a1, cj5                   ; expected epc
        li    a2, 5                     ; expected tval
        call  chkt                      ; check

; ---- crestrict: can only remove permissions; R-only without D is still linear ------
        cperms a0, c6                   ; c6 read-only
        li    a1, SP_T3 << 8 | P_R      ; T3, R
        call  chk                       ; check
        li    t0, 63                    ; ask for every permission
        crestrict c6, c6, t0            ; perms &= 63: nothing is added
        cperms a0, c6                   ; still
        li    a1, SP_T3 << 8 | P_R      ; T3, R
        call  chk                       ; check
        cmov  c7, c6                    ; R without D: linear, so this is a move
        cvalid a0, c6                   ; source
        li    a1, 0                     ; emptied
        call  chk                       ; check
        li    t0, P_R | P_D             ; restrict c3 (device R W D) to R D
        crestrict c8, c3, t0            ; a copyable source: c3 stays
        cperms a0, c8                   ; the copy
        li    a1, SP_DEV << 8 | P_R | P_D ; device R D
        call  chk                       ; check
        cperms a0, c3                   ; the source
        li    a1, SP_DEV << 8 | P_R | P_W | P_D ; unchanged
        call  chk                       ; check
rs1:    crestrict c7, c3, t0            ; onto c7, a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, rs1                   ; expected epc
        li    a2, 7                     ; expected tval: the destination
        call  chkt                      ; check

; ---- cmov: move, copy, overwrite rules ---------------------------------------------------
mv1:    cmov  c7, c0                    ; c7 holds a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, mv1                   ; expected epc
        li    a2, 7                     ; expected tval: the destination
        call  chkt                      ; check
        cvalid a0, c0                   ; the source is untouched
        li    a1, 1                     ; still valid
        call  chk                       ; check
        cmov  c8, c0                    ; c8 holds a copyable (D) capability: may be overwritten
        cperms a0, c8                   ; c8 is now the T3 capability
        li    a1, SP_T3 << 8 | 7        ; T3 R W X
        call  chk                       ; check
        cvalid a0, c0                   ; moved: c0 empty
        li    a1, 0                     ; empty
        call  chk                       ; check
        cmov  c0, c8                    ; move it back
        cmov  c0, c0                    ; moving onto itself: a no-op
        cvalid a0, c0                   ; still there
        li    a1, 1                     ; valid
        call  chk                       ; check
        cmov  c9, c2                    ; a copyable capability is copied
        cvalid a0, c2                   ; the source stays
        li    a1, 1                     ; valid
        call  chk                       ; check
        cperms a0, c9                   ; the copy
        li    a1, SP_DEV << 8 | P_W | P_D ; console output
        call  chk                       ; check
        cclear c7                       ; cclear drops even a live linear capability
        cvalid a0, c7                   ; gone
        li    a1, 0                     ; empty
        call  chk                       ; check

; ---- cshare ------------------------------------------------------------------------------
        li    t0, 0x4000                ; 16 KiB
        csplit c6, c0, t0               ; c0 = [0, 16K), c6 = [16K, 32K)
        cshare c7, c6                   ; c7 = shared view of c6; linear c6 is consumed
        cperms a0, c7                   ; R and X kept, W dropped, D added
        li    a1, SP_T3 << 8 | P_R | P_X | P_D ; T3 R X D
        call  chk                       ; check
        cvalid a0, c6                   ; consumed
        li    a1, 0                     ; empty
        call  chk                       ; check
        cbase a0, c7                    ; same range
        li    a1, 0x4000                ; 16 KiB
        call  chk                       ; check
        cmov  c8, c7                    ; a shared capability copies
        cvalid a0, c7                   ; the source stays
        li    a1, 1                     ; valid
        call  chk                       ; check
        cshare c10, c3                  ; sharing a copyable capability: the source stays
        cperms a0, c10                  ; device R D (W dropped)
        li    a1, SP_DEV << 8 | P_R | P_D ; expected
        call  chk                       ; check
        cperms a0, c3                   ; c3 itself
        li    a1, SP_DEV << 8 | P_R | P_W | P_D ; unchanged
        call  chk                       ; check
sh1:    cshare c11, c2                  ; c2 has neither R nor X
        li    a0, C_PERM                ; expected cause
        la    a1, sh1                   ; expected epc
        li    a2, 2                     ; expected tval: the source register
        call  chkt                      ; check
sh2:    cshare c0, c7                   ; onto live linear c0
        li    a0, C_CAPOP               ; expected cause
        la    a1, sh2                   ; expected epc
        li    a2, 0                     ; expected tval: the destination
        call  chkt                      ; check

; ---- catomic -----------------------------------------------------------------------------
        li    t0, 0x2000                ; 8 KiB
        csplit c6, c0, t0               ; c0 = [0, 8K), c6 = [8K, 16K)
        catomic c11, c6                 ; c11 = atomic-only view; c6 consumed
        cperms a0, c11                  ; A D only
        li    a1, SP_T3 << 8 | P_A | P_D ; T3 A D
        call  chk                       ; check
        cvalid a0, c6                   ; consumed
        li    a1, 0                     ; empty
        call  chk                       ; check
at1:    catomic c12, c3                 ; device space: not memory
        li    a0, C_PERM                ; expected cause
        la    a1, at1                   ; expected epc
        li    a2, 3                     ; expected tval
        call  chkt                      ; check
at2:    catomic c12, c7                 ; shared (no W)
        li    a0, C_PERM                ; expected cause
        la    a1, at2                   ; expected epc
        li    a2, 7                     ; expected tval
        call  chkt                      ; check
at3:    catomic c11, c11                ; in place, from an atomic capability (no W)
        li    a0, C_PERM                ; expected cause
        la    a1, at3                   ; expected epc
        li    a2, 11                    ; expected tval
        call  chkt                      ; check
        li    t0, 0x1000                ; 4 KiB
        csplit c6, c0, t0               ; c0 = [0, 4K), c6 = [4K, 8K)
        catomic c6, c6                  ; in place: allowed
        cperms a0, c6                   ; now atomic
        li    a1, SP_T3 << 8 | P_A | P_D ; T3 A D
        call  chk                       ; check

; ---- csave / crestore ---------------------------------------------------------------------
        li    t0, 0x800                 ; 2 KiB
        csplit c12, c0, t0              ; c0 = [0, 2K), c12 = [2K, 4K)
        csave c12, 0                    ; linear: moved into slot 0
        cvalid a0, c12                  ; source emptied
        li    a1, 0                     ; empty
        call  chk                       ; check
cs1:    csave c0, 0                     ; slot 0 holds a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, cs1                   ; expected epc
        li    a2, 0                     ; expected tval: the slot
        call  chkt                      ; check
        csave c2, 63                    ; a copyable capability into the last slot: copied
        cvalid a0, c2                   ; the source stays
        li    a1, 1                     ; valid
        call  chk                       ; check
        csave c3, 63                    ; slot 63 holds a copyable capability: may be overwritten
        crestore c13, 63                ; restore a copyable capability: the slot keeps it
        cperms a0, c13                  ; device R W D
        li    a1, SP_DEV << 8 | P_R | P_W | P_D ; expected
        call  chk                       ; check
        crestore c14, 63                ; and again
        cvalid a0, c14                  ; still there
        li    a1, 1                     ; valid
        call  chk                       ; check
cs2:    crestore c0, 0                  ; onto live linear c0
        li    a0, C_CAPOP               ; expected cause
        la    a1, cs2                   ; expected epc
        li    a2, 0                     ; expected tval: the destination register
        call  chkt                      ; check
        crestore c12, 0                 ; restore the linear one: the slot empties
        cbase a0, c12                   ; it is the 2K piece
        li    a1, 0x800                 ; base 2 KiB
        call  chk                       ; check
cs3:    crestore c15, 0                 ; slot 0 is empty now
        li    a0, C_CAPINV              ; expected cause
        la    a1, cs3                   ; expected epc
        li    a2, 0                     ; expected tval: the slot
        call  chkt                      ; check
cs4:    crestore c15, 17                ; never used
        li    a0, C_CAPINV              ; expected cause
        la    a1, cs4                   ; expected epc
        li    a2, 17                    ; expected tval
        call  chkt                      ; check
cs5:    csave c15, 5                    ; saving an empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, cs5                   ; expected epc
        li    a2, 15                    ; expected tval: the source register
        call  chkt                      ; check

; ---- a capability works for transfers only within its own range ---------------------
        cjoin c0, c12                   ; c0 = [0, 4K) again
        li    a0, 0                     ; no trap expected so far
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict
