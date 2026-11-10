; =============================================================================
; dom.s: revocation domains (cdom / crevoke / cundom), endpoints (cmkep /
; csend / crecv) and the inbox seen from one core (cgive to itself)
; =============================================================================
;
; What it checks
;   * cdom cd, cs: cs (a linear writable T2/T3 capability outside any domain)
;     becomes the domain's REVOKER (perms V only), cd a working capability of
;     the same region inside the new domain. Not allowed (capop, tval = cs):
;     cd = cs, a copyable or read-only source, a source already in a domain,
;     device space, a live linear cd. Domains are machine-wide; there are 15.
;   * Everything derived from a working capability (csplit, cshare, cmov,
;     csave) stays in its domain. crevoke cd, cs(revoker) kills every
;     capability of the domain at once (they read as not valid: cvalid 0,
;     use = capinv, even from the save table) and puts a fresh working
;     capability for the whole region in cd. The revoker survives it.
;   * cundom cd, cs: kills the domain's capabilities, ends the domain, and
;     gives back a plain capability (no domain) for the region; the revoker
;     is consumed. A non-revoker as cs: capinv.
;   * cjoin never joins across domains.
;   * cmkep cd, rx: an endpoint for node x (0..ncores, ncores = the block
;     device): space 6, perms R W D, base x, length 1; x > ncores: capop.
;   * csend cs, ce gives cs to the node ce names (linear: moved; D: copied);
;     crecv cd, ce takes from the inbox queue of the node ce names. ce must
;     be a live endpoint with W (csend) / R (crecv): capinv (tval = ce).
;   * cgive to oneself: the gift sits in the core's own inbox (queue of
;     sender = itself); cpoll shows bit 0, tany sees bit 16, ctake (any or
;     named) takes it, takefrom = the sender.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
buf:    .space 16                       ; scratch

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    t0, 0x100000              ; 1 MiB
        csplit c5, c0, t0               ; c0 = [0, 1M), c5 = the rest of T3 (kept aside)
        li    t0, 0x10000               ; 64 KiB
        csplit c6, c0, t0               ; c0 = [0, 64K), c6 = [64K, 1M)

; ---- cdom ----------------------------------------------------------------------------
        cdom  c7, c0                    ; c0 -> revoker, c7 = working capability in a new domain
        cperms a0, c0                   ; the revoker
        li    a1, SP_T3 << 8 | P_V      ; T3, V only
        call  chk                       ; check
        cbase a0, c0                    ; same region
        li    a1, 0                     ; base 0
        call  chk                       ; check
        clen  a0, c0                    ; length
        li    a1, 0x10000               ; 64 KiB
        call  chk                       ; check
        cperms a0, c7                   ; the working capability
        li    a1, SP_T3 << 8 | 7        ; same perms as the source had (R W X)
        call  chk                       ; check
        clen  a0, c7                    ; its length
        li    a1, 0x10000               ; 64 KiB
        call  chk                       ; check
dm1:    cdom  c8, c7                    ; c7 is already in a domain
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

; ---- derived capabilities stay in the domain; crevoke kills them all ------------------
        li    t0, 0x8000                ; 32 KiB
        csplit c8, c7, t0               ; c7 = [0, 32K), c8 = [32K, 64K): both in the domain
        cshare c9, c8                   ; c9 = shared view of c8 (c8 consumed), in the domain
        cmov  c10, c9                   ; a copy, in the domain
        csave c10, 7                    ; and one in the save table
dj1:    cjoin c6, c5                    ; (c6 and c5 are plain and adjacent: fine)
        clen  a0, c6                    ; joined
        li    a1, 0x4000000 - 0x10000   ; [64K, 64M)
        call  chk                       ; check
        li    t0, 0x10000               ; 64 KiB
        csplit c5, c6, t0               ; c6 = [64K, 128K), c5 = the rest again
        li    t0, 0x8000                ; 32 KiB
        csplit c11, c7, t0              ; c7 = [0, 32K), c11 = [32K, 32K): empty range, in the domain
        cclear c11                      ; drop it
        cmov  c11, c7                   ; c11 = [0, 32K) in the domain
dj2:    cjoin c11, c6                   ; [0,32K) in the domain + [64K,...) plain: not adjacent anyway
        li    a0, C_CAPOP               ; expected cause
        la    a1, dj2                   ; expected epc
        li    a2, 6                     ; expected tval
        call  chkt                      ; check
        crevoke c12, c0                 ; revoke: every capability of the domain dies
        cvalid a0, c11                  ; working piece
        li    a1, 0                     ; dead
        call  chk                       ; check
        cvalid a0, c9                   ; shared view
        li    a1, 0                     ; dead
        call  chk                       ; check
        cvalid a0, c10                  ; copy
        li    a1, 0                     ; dead
        call  chk                       ; check
        cvalid a0, c0                   ; the revoker survives
        li    a1, 1                     ; alive
        call  chk                       ; check
        cperms a0, c12                  ; the fresh working capability
        li    a1, SP_T3 << 8 | 7        ; the region's original perms
        call  chk                       ; check
        clen  a0, c12                   ; the whole region
        li    a1, 0x10000               ; 64 KiB
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
rv3:    crestore c13, 7                 ; the saved copy died too
        li    a0, C_CAPINV              ; expected cause
        la    a1, rv3                   ; expected epc
        li    a2, 7                     ; expected tval: the slot
        call  chkt                      ; check
        cmov  c11, c12                  ; dead capabilities may be overwritten (c11 was dead)
        cvalid a0, c11                  ; moved in
        li    a1, 1                     ; valid
        call  chk                       ; check
        tget  tg0, s1, c11, zero, s2    ; the new working capability works
        twait tg0                       ; wait
        li    a0, 0                     ; no trap
        li    a1, 0                     ; (epc)
        li    a2, 0                     ; (tval)
        call  chkt                      ; check
rv4:    crevoke c11, c0                 ; cd holds a live linear capability
        li    a0, C_CAPOP               ; expected cause
        la    a1, rv4                   ; expected epc
        li    a2, 11                    ; expected tval: cd
        call  chkt                      ; check
rv5:    crevoke c13, c11                ; c11 is a working capability, not a revoker
        li    a0, C_CAPINV              ; expected cause
        la    a1, rv5                   ; expected epc
        li    a2, 11                    ; expected tval: cs
        call  chkt                      ; check
rv6:    crevoke c0, c0                  ; cd = cs
        li    a0, C_CAPOP               ; expected cause
        la    a1, rv6                   ; expected epc
        li    a2, 0                     ; expected tval: cd
        call  chkt                      ; check
        crevoke c13, c0                 ; revoke again (kills c11)
        cvalid a0, c11                  ; old working capability
        li    a1, 0                     ; dead
        call  chk                       ; check

; ---- cundom ---------------------------------------------------------------------------
        cundom c14, c0                  ; end the domain: c14 = plain capability, revoker consumed
        cvalid a0, c0                   ; the revoker
        li    a1, 0                     ; consumed
        call  chk                       ; check
        cvalid a0, c13                  ; the last working capability
        li    a1, 0                     ; dead
        call  chk                       ; check
        cperms a0, c14                  ; the plain capability
        li    a1, SP_T3 << 8 | 7        ; T3 R W X
        call  chk                       ; check
        cjoin c14, c6                   ; plain again: joins with the adjacent plain piece
        clen  a0, c14                   ; [0, 128K)
        li    a1, 0x20000               ; 128 KiB
        call  chk                       ; check
        cdom  c7, c14                   ; a domain can be made again from it
        cvalid a0, c7                   ; working capability
        li    a1, 1                     ; valid
        call  chk                       ; check
        cundom c0, c14                  ; and ended at once
        clen  a0, c0                    ; c0 = [0, 128K) plain
        li    a1, 0x20000               ; 128 KiB
        call  chk                       ; check

; ---- there are 15 domains (all ended above, so all free) -----------------------------
        li    s3, 0                     ; s3 = domains made
        li    s4, 20                    ; give up after 20
dm_loop:
        li    t0, 0x1000                ; 4 KiB pieces
        csplit c6, c0, t0               ; c0 = 4 KiB, c6 = the rest
dm_cd:  cdom  c7, c0                    ; a new domain (a trap leaves c0 and c7 alone)
        ld    t1, tcause(zero)          ; did it trap?
        bnez  t1, dm_end                ; yes: out of domains
        addi  s3, s3, 1                 ; one more domain
        cclear c7                       ; drop the working capability
        cclear c0                       ; and the revoker: the domain stays allocated (only cundom ends it)
        cmov  c0, c6                    ; continue with the rest
        blt   s3, s4, dm_loop           ; next
dm_end:
        li    a0, C_CAPOP               ; the 16th cdom: out of domains
        la    a1, dm_cd                 ; expected epc
        li    a2, 0                     ; expected tval: cs = c0
        call  chkt                      ; check
        mv    a0, s3                    ; domains made
        li    a1, 15                    ; all 15
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
