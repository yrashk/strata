; =============================================================================
; units.s: a program larger than its code cache, paged in by StrataOS
; =============================================================================
;
; What it shows
;   * Code that does not live in the Local Store. The 24 functions below are
;     *code units*: each sits in its own 1 KiB slot of the program's image in
;     system memory (the `.far` section), and none of them is in the I-LS when
;     the program starts. The program turns on slot mapping with
;     `csrw xslot, 10` and calls a unit with `xcall`.
;   * Demand paging done by the OS, explicitly. A call to a unit that is not
;     resident traps with `xmiss`; StrataOS copies the unit into a slot of the
;     program's code cache (16 slots here, so 24 units cannot all fit),
;     maps it, and retries the call. Evicted units come back when needed.
;   * Returning into evicted code. When a unit calls another, `xcall` leaves
;     a *far* return link (the caller's address in the image, bit 63 set).
;     `xret` resolves it through the overlay map, so if the caller was evicted
;     while its callee ran, it is paged back in before the return lands.
;   * The result is checked against the same computation done by resident
;     code that never pages.
;
; Expected output (under StrataOS: `run units`):
;   units: 24 functions of 1 KiB, chains 7 calls deep
;   paged sum   = <n>
;   resident sum= <n>
;   check: ok
;   [<n> code units loaded]                (printed by the kernel)

N       = 24                            ; number of code units
DEPTH   = 6                             ; extra calls per chain

        .data                           ; data Local Store
        .align 8                        ; tables of 64-bit words
mult:   .dword 3, 15, 27, 39, 51, 63    ; each unit's multiplier
        .dword 75, 87, 99, 14, 26, 38   ; (continued)
        .dword 50, 62, 74, 86, 98, 13   ; (continued)
        .dword 25, 37, 49, 61, 73, 85   ; (continued)
addc:   .dword 1, 504, 7, 510, 13, 516  ; each unit's constant
        .dword 19, 522, 25, 528, 31, 534; (continued)
        .dword 37, 540, 43, 546, 49, 552; (continued)
        .dword 55, 558, 61, 564, 67, 570; (continued)
nxt:    .dword 5, 12, 19, 2, 9, 16      ; the unit each one calls
        .dword 23, 6, 13, 20, 3, 10     ; (continued)
        .dword 17, 0, 7, 14, 21, 4      ; (continued)
        .dword 11, 18, 1, 8, 15, 22     ; (continued)
m_head: .ascii "units: 24 functions of 1 KiB, chains 7 calls deep\n" ; output text
m_head_e:                               ; end of the text above
m_pag:  .ascii "paged sum   = "         ; output text
m_pag_e:                                ; end of the text above
m_res:  .ascii "resident sum= "         ; output text
m_res_e:                                ; end of the text above
m_ok:   .ascii "check: ok\n"           ; output text
m_ok_e:                                 ; end of the text above
m_bad:  .ascii "check: MISMATCH\n"     ; output text
m_bad_e:                                ; end of the text above

        .text                           ; resident code: the I-LS
_start:
        li    sp, 65536                 ; stack at the top of the D-LS
        li    t0, 10                    ; slots of 2^10 = 1 KiB:
        csrw  xslot, t0                 ;   an overlay mapping now covers a whole unit
        la    a0, m_head                ; the heading
        li    a1, m_head_e - m_head     ; its length
        call  print_str                 ; print it
        li    s1, 0                     ; s1 = unit number k
        li    s2, 0                     ; s2 = sum through the code units
        li    s3, 0                     ; s3 = sum through the resident reference
loop:
        addi  a0, s1, 1                 ; x = k + 1
        li    a1, DEPTH                 ; chain depth
        la    t5, u0                    ; far offset of unit 0 ...
        slli  t6, s1, 10                ; ... plus k slots of 1 KiB
        add   t5, t5, t6                ; t5 = far offset of unit k
        xcall ra, c0, t5                ; call unit k through the overlay map (paged in on demand)
        add   s2, s2, a0                ; accumulate
        mv    a0, s1                    ; the same computation, resident: unit k
        addi  a1, s1, 1                 ; x = k + 1
        li    a2, DEPTH                 ; chain depth
        call  ref                       ; a0 = the reference result
        add   s3, s3, a0                ; accumulate
        addi  s1, s1, 1                 ; next unit
        li    t0, N                     ; loop bound
        blt   s1, t0, loop              ; all units, each starting a chain
        la    a0, m_pag                 ; "paged sum   = "
        li    a1, m_pag_e - m_pag       ; length
        call  print_str                 ; print
        mv    a0, s2                    ; the paged sum
        call  print_dec                 ; print
        call  print_nl                  ; newline
        la    a0, m_res                 ; "resident sum= "
        li    a1, m_res_e - m_res       ; length
        call  print_str                 ; print
        mv    a0, s3                    ; the reference sum
        call  print_dec                 ; print
        call  print_nl                  ; newline
        la    a0, m_ok                  ; assume they agree
        li    a1, m_ok_e - m_ok         ; length
        beq   s2, s3, verdict           ; they do
        la    a0, m_bad                 ; they do not
        li    a1, m_bad_e - m_bad       ; length
verdict:
        call  print_str                 ; print the verdict
        li    a0, 0                     ; exit code
        halt                            ; done

; ref(a0 = unit k, a1 = x, a2 = depth) -> a0: the units' computation, resident
ref:
        slli  t0, a0, 3                 ; t0 = k * 8: offset into the tables
        la    t1, mult                  ; multiplier table
        add   t1, t1, t0                ; this unit's entry
        ld    t1, 0(t1)                 ; t1 = multiplier
        mul   t1, a1, t1                ; t1 = x * multiplier
        la    t2, addc                  ; constant table
        add   t2, t2, t0                ; this unit's entry
        ld    t2, 0(t2)                 ; t2 = constant
        add   t1, t1, t2                ; t1 = x * multiplier + constant
        beqz  a2, ref_leaf              ; depth 0: done
        addi  sp, sp, -16               ; frame: ra and the partial result
        sd    ra, 0(sp)                 ; save ra
        sd    t1, 8(sp)                 ; save the partial result
        la    t2, nxt                   ; the next-unit table
        add   t2, t2, t0                ; this unit's entry
        ld    a0, 0(t2)                 ; a0 = the unit it calls
        andi  a1, t1, 0xffff            ; its x: the low 16 bits of ours
        addi  a2, a2, -1                ; one level shallower
        call  ref                       ; recurse
        ld    t1, 8(sp)                 ; the partial result
        add   t1, t1, a0                ; plus the callee's
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
ref_leaf:
        mv    a0, t1                    ; the result
        ret                             ; done

        .include "../../examples/lib/print.s" ; console helpers

; =============================================================================
; The code units: in the program's image in system memory, never preloaded.
; =============================================================================
        .far                            ; the image section that stays in system memory
        .align 1024                     ; every unit starts on its own 1 KiB slot
u0:                                    ; unit 0: f(x, d) = x*3 + 1, plus unit 5's f when d > 0
        li    t0, 3                      ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 1                   ; t0 = x * multiplier + this unit's constant
        beqz  a1, u0_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u5                    ; far offset of unit 5
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u0_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u1:                                    ; unit 1: f(x, d) = x*15 + 504, plus unit 12's f when d > 0
        li    t0, 15                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 504                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u1_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u12                   ; far offset of unit 12
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u1_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u2:                                    ; unit 2: f(x, d) = x*27 + 7, plus unit 19's f when d > 0
        li    t0, 27                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 7                   ; t0 = x * multiplier + this unit's constant
        beqz  a1, u2_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u19                   ; far offset of unit 19
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u2_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u3:                                    ; unit 3: f(x, d) = x*39 + 510, plus unit 2's f when d > 0
        li    t0, 39                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 510                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u3_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u2                    ; far offset of unit 2
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u3_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u4:                                    ; unit 4: f(x, d) = x*51 + 13, plus unit 9's f when d > 0
        li    t0, 51                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 13                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u4_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u9                    ; far offset of unit 9
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u4_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u5:                                    ; unit 5: f(x, d) = x*63 + 516, plus unit 16's f when d > 0
        li    t0, 63                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 516                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u5_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u16                   ; far offset of unit 16
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u5_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u6:                                    ; unit 6: f(x, d) = x*75 + 19, plus unit 23's f when d > 0
        li    t0, 75                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 19                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u6_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u23                   ; far offset of unit 23
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u6_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u7:                                    ; unit 7: f(x, d) = x*87 + 522, plus unit 6's f when d > 0
        li    t0, 87                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 522                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u7_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u6                    ; far offset of unit 6
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u7_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u8:                                    ; unit 8: f(x, d) = x*99 + 25, plus unit 13's f when d > 0
        li    t0, 99                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 25                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u8_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u13                   ; far offset of unit 13
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u8_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u9:                                    ; unit 9: f(x, d) = x*14 + 528, plus unit 20's f when d > 0
        li    t0, 14                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 528                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u9_leaf                 ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u20                   ; far offset of unit 20
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u9_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u10:                                    ; unit 10: f(x, d) = x*26 + 31, plus unit 3's f when d > 0
        li    t0, 26                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 31                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u10_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u3                    ; far offset of unit 3
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u10_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u11:                                    ; unit 11: f(x, d) = x*38 + 534, plus unit 10's f when d > 0
        li    t0, 38                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 534                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u11_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u10                   ; far offset of unit 10
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u11_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u12:                                    ; unit 12: f(x, d) = x*50 + 37, plus unit 17's f when d > 0
        li    t0, 50                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 37                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u12_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u17                   ; far offset of unit 17
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u12_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u13:                                    ; unit 13: f(x, d) = x*62 + 540, plus unit 0's f when d > 0
        li    t0, 62                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 540                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u13_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u0                    ; far offset of unit 0
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u13_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u14:                                    ; unit 14: f(x, d) = x*74 + 43, plus unit 7's f when d > 0
        li    t0, 74                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 43                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u14_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u7                    ; far offset of unit 7
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u14_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u15:                                    ; unit 15: f(x, d) = x*86 + 546, plus unit 14's f when d > 0
        li    t0, 86                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 546                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u15_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u14                   ; far offset of unit 14
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u15_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u16:                                    ; unit 16: f(x, d) = x*98 + 49, plus unit 21's f when d > 0
        li    t0, 98                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 49                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u16_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u21                   ; far offset of unit 21
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u16_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u17:                                    ; unit 17: f(x, d) = x*13 + 552, plus unit 4's f when d > 0
        li    t0, 13                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 552                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u17_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u4                    ; far offset of unit 4
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u17_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u18:                                    ; unit 18: f(x, d) = x*25 + 55, plus unit 11's f when d > 0
        li    t0, 25                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 55                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u18_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u11                   ; far offset of unit 11
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u18_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u19:                                    ; unit 19: f(x, d) = x*37 + 558, plus unit 18's f when d > 0
        li    t0, 37                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 558                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u19_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u18                   ; far offset of unit 18
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u19_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u20:                                    ; unit 20: f(x, d) = x*49 + 61, plus unit 1's f when d > 0
        li    t0, 49                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 61                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u20_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u1                    ; far offset of unit 1
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u20_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u21:                                    ; unit 21: f(x, d) = x*61 + 564, plus unit 8's f when d > 0
        li    t0, 61                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 564                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u21_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u8                    ; far offset of unit 8
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u21_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u22:                                    ; unit 22: f(x, d) = x*73 + 67, plus unit 15's f when d > 0
        li    t0, 73                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 67                  ; t0 = x * multiplier + this unit's constant
        beqz  a1, u22_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u15                   ; far offset of unit 15
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u22_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
        .align 1024                     ; every unit starts on its own 1 KiB slot
u23:                                    ; unit 23: f(x, d) = x*85 + 570, plus unit 22's f when d > 0
        li    t0, 85                     ; this unit's multiplier
        mul   t0, a0, t0                ; t0 = x * multiplier
        addi  t0, t0, 570                 ; t0 = x * multiplier + this unit's constant
        beqz  a1, u23_leaf                ; depth 0: no further call
        addi  sp, sp, -16               ; room for the return link and our partial result
        sd    ra, 0(sp)                 ; the link (a far link when another unit called us)
        sd    t0, 8(sp)                 ; our partial result
        andi  a0, t0, 0xffff            ; the next unit's x: the low 16 bits of ours
        addi  a1, a1, -1                ; one level shallower
        la    t5, u22                   ; far offset of unit 22
        xcall ra, c0, t5                ; call it; if it is not resident, the kernel pages it in
        ld    t0, 8(sp)                 ; our partial result again
        add   t0, t0, a0                ; plus what the callee returned
        ld    ra, 0(sp)                 ; our return link
        addi  sp, sp, 16                ; release the frame
u23_leaf:
        mv    a0, t0                    ; the result
        xret  ra                        ; return; if our caller was evicted meanwhile, it is paged back in
