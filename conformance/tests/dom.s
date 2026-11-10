; =============================================================================
; dom.s: revocation by address (cdom / crevoke / cundom over 256 KiB
; granules), endpoints (cmkep / csend / crecv) and the inbox seen from one
; core (cgive to itself)
; =============================================================================
;
; What it checks
;   * cdom cd, cs: cs (a linear writable T2/T3 capability, not revocable,
;     for whole granules: base and length multiples of 256 KiB, length > 0)
;     becomes the region's REVOKER (perms V only, not revocable), cd a
;     revocable working capability for the same region. Not allowed (capop,
;     tval = cs): cd = cs, a copyable or read-only source, a revocable
;     source, device space, an unaligned base or length, an empty region, a
;     live linear cd. An empty source: capinv.
;   * Everything derived from a working capability (csplit, cshare, cmov,
;     csave, a gift) is revocable with the same generation. crevoke cd,
;     cs(revoker) kills every revocable capability whose base lies in the
;     revoker's range (cvalid 0, use = capinv, even from the save table or
;     an inbox) and puts a fresh working capability for the range in cd. The
;     revoker survives it. Other regions are not touched.
;   * A zero-length piece at the very end of a region has its base in the
;     next granule, and lives and dies with that granule.
;   * cjoin never joins across units: two revocable pieces with the same
;     generation are refused where the second begins a unit (adjacent
;     regions; the two halves after a revocation by halves).
;   * A revoker is cut and joined only at granule boundaries; crevoke with a
;     piece revokes that range: the units it touches die whole, and it
;     becomes a unit of its own.
;   * cundom cd, cs: kills the range's capabilities and gives back a plain
;     capability; the revoker is consumed. A non-revoker as cs: capinv.
;   * T2 is one granule. Regions are limited only by memory (40 here).
;   * cmkep cd, rx: an endpoint for node x (0..ncores, ncores = the block
;     device): space 6, perms R W D, base x, length 1; x > ncores: capop.
;   * csend cs, ce gives cs to the node ce names (linear: moved; D: copied);
;     crecv cd, ce takes from the inbox queue of the node ce names. ce must
;     be a live endpoint with W (csend) / R (crecv): capinv (tval = ce).
;   * cgive to oneself: the gift sits in the core's own inbox (queue of
;     sender = itself); cpoll shows bit 0, tany sees bit 16, ctake (any or
;     named) takes it, takefrom = the sender.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

GRAN    = 0x40000                       ; a revocation granule: 256 KiB

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
buf:    .space 16                       ; scratch

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    t0, 0x100000              ; 1 MiB
        csplit c5, c0, t0               ; c0 = A = [0, 1M), c5 = [1M, 64M)
        li    t0, 0x80000               ; 512 KiB
        csplit c6, c5, t0               ; c5 = B = [1M, 1.5M), c6 = [1.5M, 64M), plain

; ---- cdom ----------------------------------------------------------------------------
        cdom  c7, c0                    ; c0 -> revoker of A, c7 = working capability
        cperms a0, c0                   ; the revoker
        li    a1, SP_T3 << 8 | P_V      ; T3, V only
        call  chk                       ; check
        cbase a0, c0                    ; same region
        li    a1, 0                     ; base 0
        call  chk                       ; check
        clen  a0, c0                    ; length
        li    a1, 0x100000              ; 1 MiB
        call  chk                       ; check
        cperms a0, c7                   ; the working capability
        li    a1, SP_T3 << 8 | 7        ; same perms as the source had (R W X)
        call  chk                       ; check
        clen  a0, c7                    ; its length
        li    a1, 0x100000              ; 1 MiB
        call  chk                       ; check
dm1:    cdom  c8, c7                    ; c7 is revocable already
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm1                   ; expected epc
        li    a2, 7                     ; expected tval: cs
        call  chkt                      ; check
dm2:    cdom  c8, c3                    ; device space (and copyable)
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm2                   ; expected epc
        li    a2, 3                     ; expected tval
        call  chkt                      ; check
dm3:    cdom  c6, c6                    ; cd = cs
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm3                   ; expected epc
        li    a2, 6                     ; expected tval
        call  chkt                      ; check
dm4:    cdom  c7, c6                    ; cd holds a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm4                   ; expected epc
        li    a2, 6                     ; expected tval: cs
        call  chkt                      ; check
dm5:    cdom  c8, c9                    ; empty source
        li    a0, C_CAPINV              ; expected cause
        la    a1, dm5                   ; expected epc
        li    a2, 9                     ; expected tval
        call  chkt                      ; check
        li    t0, 0x1000                ; 4 KiB
        csplit c8, c6, t0               ; c6 = [1.5M, +4K), c8 = [1.5M + 4K, 64M)
dm6:    cdom  c9, c8                    ; base not on a granule boundary
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm6                   ; expected epc
        li    a2, 8                     ; expected tval: cs
        call  chkt                      ; check
dm7:    cdom  c9, c6                    ; 4 KiB: not whole granules
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm7                   ; expected epc
        li    a2, 6                     ; expected tval: cs
        call  chkt                      ; check
        cjoin c6, c8                    ; c6 = [1.5M, 64M) again
        li    t0, 0                     ; at 0
        csplit c8, c6, t0               ; c6 = [1.5M, 1.5M), c8 = [1.5M, 64M)
dm8:    cdom  c9, c6                    ; an empty region
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm8                   ; expected epc
        li    a2, 6                     ; expected tval: cs
        call  chkt                      ; check
        cjoin c6, c8                    ; whole again
        li    t0, GRAN                  ; one granule
        csplit c8, c6, t0               ; c6 = [1.5M, 1.75M), c8 = [1.75M, 64M)
        li    t0, P_R                   ; read only (still linear)
        crestrict c6, c6, t0            ; ...
dm9:    cdom  c9, c6                    ; not writable
        li    a0, C_CAPOP               ; expected cause
        la    a1, dm9                   ; expected epc
        li    a2, 6                     ; expected tval: cs
        call  chkt                      ; check
        cclear c6                       ; (that granule is not needed)
        cmov  c6, c8                    ; c6 = [1.75M, 64M), plain

; ---- a second region right after the first; no join across them -------------------
        cdom  c13, c5                   ; c5 = revoker of B = [1M, 1.5M), c13 its working capability
dj1:    cjoin c7, c13                   ; A's [0, 1M) + B's [1M, 1.5M): same generation, but B begins a unit
        li    a0, C_CAPOP               ; expected cause
        la    a1, dj1                   ; expected epc
        li    a2, 13                    ; expected tval: cs
        call  chkt                      ; check

; ---- derived capabilities stay revocable; crevoke kills them all ---------------------
        li    t0, 0x60000               ; 384 KiB: inside granule 1
        csplit c8, c7, t0               ; c7 = [0, 384K), c8 = [384K, 1M): both revocable
        cshare c9, c8                   ; c9 = shared view of c8 (c8 consumed)
        cmov  c10, c9                   ; a copy
        csave c10, 7                    ; and one in the save table
        csplit c11, c7, t0              ; c7 = [0, 384K), c11 = [384K, 384K): empty, inside A
        cvalid a0, c11                  ; live: its base is in A
        li    a1, 1                     ; ...
        call  chk                       ; check
        cjoin c7, c11                   ; empty pieces join too
        clen  a0, c7                    ; unchanged
        li    a1, 0x60000               ; 384 KiB
        call  chk                       ; check
        li    t0, 0xA0000               ; 640 KiB: the share's end
        csplit c12, c9, t0              ; c12 = [1M, 1M): empty, its base in B's first granule
        cvalid a0, c12                  ; live (B has the generation A has)
        li    a1, 1                     ; ...
        call  chk                       ; check
        crevoke c14, c0                 ; revoke A
        cvalid a0, c7                   ; working piece
        li    a1, 0                     ; dead
        call  chk                       ; check
        cvalid a0, c9                   ; shared view
        li    a1, 0                     ; dead
        call  chk                       ; check
        cvalid a0, c10                  ; copy
        li    a1, 0                     ; dead
        call  chk                       ; check
        cvalid a0, c12                  ; the empty piece at A's end follows B: alive
        li    a1, 1                     ; ...
        call  chk                       ; check
        cvalid a0, c13                  ; B's working capability: untouched
        li    a1, 1                     ; alive
        call  chk                       ; check
        cvalid a0, c0                   ; the revoker survives
        li    a1, 1                     ; alive
        call  chk                       ; check
        cperms a0, c14                  ; the fresh working capability
        li    a1, SP_T3 << 8 | 7        ; the region's original perms
        call  chk                       ; check
        clen  a0, c14                   ; the whole region
        li    a1, 0x100000              ; 1 MiB
        call  chk                       ; check
        la    s1, buf                   ; s1 = D-LS buffer
        li    s2, 8                     ; one word
rv1:    tget  tg0, s1, c9, zero, s2     ; a transfer through a revoked capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, rv1                   ; expected epc
        li    a2, 0                     ; expected tval: the offset
        call  chkt                      ; check
rv2:    cbase a0, c10                   ; inspecting a revoked capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, rv2                   ; expected epc
        li    a2, 10                    ; expected tval
        call  chkt                      ; check
rv3:    crestore c11, 7                 ; the saved copy died too
        li    a0, C_CAPINV              ; expected cause
        la    a1, rv3                   ; expected epc
        li    a2, 7                     ; expected tval: the slot
        call  chkt                      ; check
        cmov  c7, c14                   ; dead capabilities may be overwritten (c7 was dead)
        cvalid a0, c7                   ; moved in
        li    a1, 1                     ; valid
        call  chk                       ; check
        tget  tg0, s1, c7, zero, s2     ; the new working capability works
        twait tg0                       ; wait
        li    a0, 0                     ; no trap
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check
rv4:    crevoke c7, c0                  ; cd holds a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, rv4                   ; expected epc
        li    a2, 7                     ; expected tval: cd
        call  chkt                      ; check
rv5:    crevoke c14, c7                 ; c7 is a working capability, not a revoker
        li    a0, C_CAPINV              ; expected cause
        la    a1, rv5                   ; expected epc
        li    a2, 7                     ; expected tval: cs
        call  chkt                      ; check
rv6:    crevoke c0, c0                  ; cd = cs
        li    a0, C_CAPOP               ; expected cause
        la    a1, rv6                   ; expected epc
        li    a2, 0                     ; expected tval: cd
        call  chkt                      ; check

; ---- a gift in an inbox dies too ------------------------------------------------------
        li    t0, GRAN                  ; one granule
        csplit c8, c7, t0               ; c7 = [0, 256K), c8 = [256K, 1M)
        li    t0, 0                     ; ourselves
        cgive c8, t0                    ; c8 waits in our inbox
        crevoke c14, c0                 ; revoke A again
        ctake c8                        ; the gift
        cvalid a0, c8                   ; arrived dead
        li    a1, 0                     ; ...
        call  chk                       ; check
        cvalid a0, c7                   ; and the piece kept here
        li    a1, 0                     ; dead
        call  chk                       ; check

; ---- revocation by address: a revoker cut at a granule boundary ----------------------
        li    t0, 0x1000                ; 4 KiB
rs1:    csplit c15, c0, t0              ; a revoker is cut only at granule boundaries
        li    a0, C_CAPOP               ; expected cause
        la    a1, rs1                   ; expected epc
        li    a2, 0x1000                ; expected tval: the offset
        call  chkt                      ; check
        li    t0, 0x80000               ; 512 KiB
        csplit c15, c0, t0              ; c0 = revoker of [0, 512K), c15 = of [512K, 1M)
        cperms a0, c15                  ; a revoker still
        li    a1, SP_T3 << 8 | P_V      ; ...
        call  chk                       ; check
        crevoke c8, c15                 ; the upper half: inside the unit of c14 ([0, 1M)) ...
        cvalid a0, c14                  ; ... which dies whole
        li    a1, 0                     ; ...
        call  chk                       ; check
        cbase a0, c8                    ; a fresh capability for the upper half
        li    a1, 0x80000               ; ...
        call  chk                       ; check
        clen  a0, c8                    ; ...
        li    a1, 0x80000               ; ...
        call  chk                       ; check
        cperms a0, c8                   ; with the region's perms
        li    a1, SP_T3 << 8 | 7        ; ...
        call  chk                       ; check
        crevoke c9, c0                  ; the lower half, a unit of its own now
        cvalid a0, c8                   ; the upper half's capability survives it
        li    a1, 1                     ; ...
        call  chk                       ; check
        cvalid a0, c9                   ; ...
        li    a1, 1                     ; ...
        call  chk                       ; check
dj3:    cjoin c9, c8                    ; two units: no join
        li    a0, C_CAPOP               ; expected cause
        la    a1, dj3                   ; expected epc
        li    a2, 8                     ; expected tval: cs
        call  chkt                      ; check
        cjoin c0, c15                   ; the revoker pieces join again
        clen  a0, c0                    ; [0, 1M)
        li    a1, 0x100000              ; ...
        call  chk                       ; check
        crevoke c10, c0                 ; all of A: both halves die
        cvalid a0, c8                   ; ...
        li    a1, 0                     ; ...
        call  chk                       ; check
        cvalid a0, c9                   ; ...
        li    a1, 0                     ; ...
        call  chk                       ; check

; ---- cundom ---------------------------------------------------------------------------
        cundom c14, c0                  ; dissolve A: c14 = plain capability, revoker consumed
        cvalid a0, c0                   ; the revoker
        li    a1, 0                     ; consumed
        call  chk                       ; check
        cvalid a0, c10                  ; the last working capability
        li    a1, 0                     ; dead
        call  chk                       ; check
        cperms a0, c14                  ; the plain capability
        li    a1, SP_T3 << 8 | 7        ; T3 R W X
        call  chk                       ; check
        cdom  c7, c14                   ; a region can be made again from it
        cvalid a0, c7                   ; working capability
        li    a1, 1                     ; valid
        call  chk                       ; check
        cundom c0, c14                  ; and dissolved at once
        clen  a0, c0                    ; c0 = [0, 1M) plain
        li    a1, 0x100000              ; 1 MiB
        call  chk                       ; check
        cvalid a0, c7                   ; dead
        li    a1, 0                     ; ...
        call  chk                       ; check
        crevoke c8, c5                  ; revoke B
        cvalid a0, c12                  ; the empty piece at A's end dies with it
        li    a1, 0                     ; ...
        call  chk                       ; check
        cvalid a0, c13                  ; B's working capability
        li    a1, 0                     ; dead
        call  chk                       ; check
        cclear c8                       ; (B's fresh one)
        cundom c13, c5                  ; dissolve B: c13 = plain [1M, 1.5M)
        cjoin c0, c13                   ; plain pieces join: [0, 1.5M)
        clen  a0, c0                    ; ...
        li    a1, 0x180000              ; 1.5 MiB
        call  chk                       ; check

; ---- T2: one granule ------------------------------------------------------------------
        cdom  c8, c1                    ; all of T2
        cperms a0, c8                   ; working capability
        li    a1, SP_T2 << 8 | 7        ; T2 R W X
        call  chk                       ; check
        crevoke c9, c1                  ; revoke it
        cvalid a0, c8                   ; dead
        li    a1, 0                     ; ...
        call  chk                       ; check
        cundom c8, c1                   ; dissolve: c8 = plain T2
        cvalid a0, c9                   ; dead
        li    a1, 0                     ; ...
        call  chk                       ; check
        cmov  c1, c8                    ; T2 back in c1
        clen  a0, c1                    ; all 256 KiB
        li    a1, 0x40000               ; ...
        call  chk                       ; check

; ---- regions are limited by memory only: 40 of them -----------------------------------
        li    s3, 0                     ; s3 = regions made
        li    s4, 40                    ; 40 (more than the 15 domains of old)
dm_loop:
        li    t0, GRAN                  ; one granule each
        csplit c8, c6, t0               ; c6 = one granule, c8 = the rest
dm_cd:  cdom  c7, c6                    ; a new region
        ld    t1, tcause(zero)          ; did it trap?
        bnez  t1, dm_end                ; yes: stop
        addi  s3, s3, 1                 ; one more region
        cclear c7                       ; drop the working capability
        cclear c6                       ; and the revoker (the granule stays revocable)
        cmov  c6, c8                    ; continue with the rest
        blt   s3, s4, dm_loop           ; next
dm_end:
        li    a0, 0                     ; no trap
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check
        mv    a0, s3                    ; regions made
        li    a1, 40                    ; all 40
        call  chk                       ; check

; ---- endpoints ---------------------------------------------------------------------------
ep_test:
        li    t0, 0                     ; node 0 = this core
        cmkep c8, t0                    ; c8 = endpoint for node 0
        cperms a0, c8                   ; endpoint space, R W D
        li    a1, SP_EP << 8 | P_R | P_W | P_D ; expected
        call  chk                       ; check
        cbase a0, c8                    ; the node
        li    a1, 0                     ; node 0
        call  chk                       ; check
        clen  a0, c8                    ; length
        li    a1, 1                     ; 1
        call  chk                       ; check
        csrr  t0, ncores                ; t0 = ncores: the block device's node number
        cmkep c9, t0                    ; allowed
        cbase a0, c9                    ; its node
        csrr  a1, ncores                ; expected ncores
        call  chk                       ; check
        addi  t0, t0, 1                 ; one past the last node
ep1:    cmkep c9, t0                    ; no such node
        li    a0, C_CAPOP               ; expected cause
        la    a1, ep1                   ; expected epc
        csrr  a2, ncores                ; expected tval: the node number
        addi  a2, a2, 1                 ; ncores + 1
        call  chkt                      ; check
        li    t0, 0x1000                ; 4 KiB
        csplit c10, c6, t0              ; c6 = a 4K piece, c10 = the rest
        csend c6, c8                    ; send c6 to node 0 (ourselves) through the endpoint
        cvalid a0, c6                   ; linear: moved
        li    a1, 0                     ; empty
        call  chk                       ; check
        cpoll a0                        ; who has given us something? bit n = sender n
        li    a1, 1                     ; sender 0 (ourselves)
        call  chk                       ; check
        csend c2, c8                    ; a copyable capability: copied
        cvalid a0, c2                   ; still here
        li    a1, 1                     ; valid
        call  chk                       ; check
        crecv c11, c8                   ; take the first gift from node 0's queue
        clen  a0, c11                   ; the 4K piece
        li    a1, 0x1000                ; expected
        call  chk                       ; check
        csrr  a0, takefrom              ; the sender
        li    a1, 0                     ; node 0
        call  chk                       ; check
rc1:    crecv c11, c8                   ; c11 holds a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, rc1                   ; expected epc
        li    a2, 11                    ; expected tval: cd
        call  chkt                      ; check
        crecv c12, c8                   ; the console copy
        cperms a0, c12                  ; console output
        li    a1, SP_DEV << 8 | P_W | P_D ; expected
        call  chk                       ; check
        cpoll a0                        ; inbox empty again
        li    a1, 0                     ; nothing
        call  chk                       ; check
        li    t0, P_R | P_D             ; receive-only
        crestrict c13, c8, t0           ; c13 = endpoint without W
ep2:    csend c2, c13                   ; send through it
        li    a0, C_CAPINV              ; expected cause
        la    a1, ep2                   ; expected epc
        li    a2, 13                    ; expected tval: the endpoint register
        call  chkt                      ; check
        li    t0, P_W | P_D             ; send-only
        crestrict c13, c8, t0           ; c13 = endpoint without R
ep3:    crecv c14, c13                  ; receive through it
        li    a0, C_CAPINV              ; expected cause (emu.c; doc/strataos.md says perm)
        la    a1, ep3                   ; expected epc
        li    a2, 13                    ; expected tval: the endpoint register
        call  chkt                      ; check
ep4:    csend c2, c3                    ; c3 is not an endpoint
        li    a0, C_CAPINV              ; expected cause
        la    a1, ep4                   ; expected epc
        li    a2, 3                     ; expected tval
        call  chkt                      ; check
ep5:    csend c15, c8                   ; sending an empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, ep5                   ; expected epc
        li    a2, 15                    ; expected tval: the source register
        call  chkt                      ; check
        la    s1, buf                   ; s1 = D-LS buffer
        li    s2, 8                     ; one word
ep6:    tget  tg0, s1, c8, zero, s2     ; an endpoint is not memory
        li    a0, C_PERM                ; expected cause
        la    a1, ep6                   ; expected epc
        li    a2, 0                     ; expected tval: the offset
        call  chkt                      ; check

; ---- cgive / ctake to oneself ----------------------------------------------------------
        li    t0, 0                     ; core 0 = this core
        cgive c11, t0                   ; give the 4K piece to ourselves
        cvalid a0, c11                  ; moved
        li    a1, 0                     ; empty
        call  chk                       ; check
        li    t1, 1 << 16               ; tany: bit 16 = "a gift is waiting"
        tany  a0, t1                    ; returns the ready sources (does not wait: one is)
        li    a1, 1 << 16               ; the inbox
        call  chk                       ; check
        cgive c2, t0                    ; a second gift (a copy of the console)
ct1:    ctake c11                       ; take the oldest gift, any sender
        clen  a0, c11                   ; the 4K piece first (queues are FIFO)
        li    a1, 0x1000                ; expected
        call  chk                       ; check
ct2:    ctake c11                       ; c11 is live and linear
        li    a0, C_CAPOP               ; expected cause
        la    a1, ct2                   ; expected epc
        li    a2, 11                    ; expected tval: cd
        call  chkt                      ; check
        ctake c12, t0                   ; take from sender 0 by name (c12 was a copyable capability)
        cperms a0, c12                  ; the console copy
        li    a1, SP_DEV << 8 | P_W | P_D ; expected
        call  chk                       ; check
        csrr  a0, takefrom              ; sender
        li    a1, 0                     ; core 0
        call  chk                       ; check
        li    t1, 1                     ; tany on tag 0 only (idle)
        tany  a0, t1                    ; ready at once
        li    a1, 1                     ; tag 0
        call  chk                       ; check
        li    t1, 0                     ; tany with nothing selected
        tany  a0, t1                    ; returns 0 at once
        li    a1, 0                     ; nothing
        call  chk                       ; check
        csrr  t0, ncores                ; one past the last core = block device
        addi  t0, t0, 1                 ; beyond that: no such node
cg1:    cgive c2, t0                    ; give to nobody
        li    a0, C_CAPOP               ; expected cause
        la    a1, cg1                   ; expected epc
        csrr  a2, ncores                ; expected tval: the node
        addi  a2, a2, 1                 ; ncores + 1
        call  chkt                      ; check
cg2:    cgive c15, zero                 ; give an empty capability
        li    a0, C_CAPINV              ; expected cause
        la    a1, cg2                   ; expected epc
        li    a2, 15                    ; expected tval
        call  chkt                      ; check
        j     done                      ; print the signature and the verdict
