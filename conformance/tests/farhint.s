; =============================================================================
; farhint.s: far loads and stores after the table changes under them
; =============================================================================
;
; What it checks: a far access finds what the table holds now, whatever the
; accesses before it found. An implementation may remember the last line it
; looked up (the RTL does); every way the table can change must be seen:
;   * a store to a tag word, a linst that evicts the line, a tget over the
;     entry: the next access to that line is a dmiss;
;   * a store that clears a way's dirty bit: the next far store sets it again,
;     also when the store before it found the way dirty;
;   * a far load and then a far store to the same line: the store sets the
;     dirty bit (the load does not say whether the way is dirty);
;   * csrw tdata, csrw ttag: the line is reached at the new place, or missed;
;   * accesses that alternate between two ways of one set, and between two
;     sets, reach the right bytes.
        .include "lib/conf.s"

LSH  = 6                                ; 64-byte lines
SETS = 4                                ; 16 sets
WAYS = 2                                ; two ways: 24-byte entries
SPAN = (WAYS + 1) * 8                   ; ...
TT   = 0x6000                           ; the tag table
TT2  = 0x6800                           ; another, empty
TD   = 0x7000                           ; the lines
FA   = 1 << 16                          ; tgeom: far access
GEOM = LSH | SETS << 6 | WAYS << 12 | FA
A1   = 0x12340                          ; line 0x48d, set 13
SET1 = (A1 >> LSH) & 15
E1   = TT + SET1 * SPAN                 ; its entry
K1   = (A1 >> LSH) << 1 | 1             ; its key
L0   = TD + ((SET1 * WAYS + 0) << LSH)  ; way 0's line
L1   = TD + ((SET1 * WAYS + 1) << LSH)  ; way 1's line
A2   = A1 + 16 * 64                     ; another line of set 13
A3   = A1 + 32 * 64                     ; a third
B1   = A1 + 64                          ; set 14
EB   = TT + (SET1 + 1) * SPAN           ; its entry
LB   = TD + (((SET1 + 1) * WAYS + 0) << LSH)
FAR  = 0x200000

        .far
        .org  FAR
fzero:  .dword 0, 0, 0, 0

        .text
main:
        csrr  t0, coreid
        bnez  t0, park
        li    t0, TT                    ; clear both tables and the lines
        li    t1, TD + 0x800
clr:    sd    zero, 0(t0)
        addi  t0, t0, 8
        bltu  t0, t1, clr
        li    t0, TT
        csrw  ttag, t0
        li    t0, TD
        csrw  tdata, t0
        li    t0, GEOM
        csrw  tgeom, t0
        li    s1, A1
        li    s2, A2
        li    s3, A3
        li    s4, B1
        li    t0, 0x1111
        sd    t0, L0(zero)              ; what way 0's line holds
        li    t0, 0x2222
        sd    t0, L1(zero)              ; way 1's
        li    t0, 0x3333
        sd    t0, LB(zero)              ; set 14 way 0's

; ---- a store to the tag word -------------------------------------------------
        linst s1                        ; A1 in way 0
        ld    a0, 0(s1)                 ; a hit
        li    a1, 0x1111
        call  chk
        ld    a0, 0(s1)                 ; again
        li    a1, 0x1111
        call  chk
        sd    zero, E1(zero)            ; software removes it
h1:     ld    a0, 0(s1)                 ; dmiss
        li    a0, C_DMISS
        la    a1, h1
        mv    a2, s1
        call  chkt
        li    t0, K1                    ; and puts it back by hand
        sd    t0, E1(zero)
        ld    a0, 0(s1)                 ; a hit again
        li    a1, 0x1111
        call  chk

; ---- dirty bits ----------------------------------------------------------------
        ld    a0, 8(s1)                 ; a load of the line, then a store
        li    t0, 5
        sd    t0, 8(s1)                 ; sets way 0's dirty bit
        ld    a0, E1 + 16(zero)
        li    a1, 1 << 32 | 1           ; (the index is 1)
        call  chk
        li    t0, 6
        sd    t0, 8(s1)                 ; dirty already
        ld    a0, L0 + 8(zero)
        li    a1, 6
        call  chk
        sd    zero, E1 + 16(zero)       ; software cleans it (the index 0)
        li    t0, 7
        sd    t0, 8(s1)                 ; dirty again
        ld    a0, E1 + 16(zero)
        li    a1, 1 << 32
        call  chk
        ld    a0, L0 + 8(zero)
        li    a1, 7
        call  chk
        li    t0, 1                     ; clean, the index 1
        sd    t0, E1 + 16(zero)

; ---- two ways of one set, two sets ---------------------------------------------
        linst s2                        ; A2 in way 1 (the index goes to 0)
        linst s4                        ; B1 in set 14 way 0
        ld    a0, 0(s1)
        li    a1, 0x1111
        call  chk
        ld    a0, 0(s2)
        li    a1, 0x2222
        call  chk
        ld    a0, 0(s1)
        li    a1, 0x1111
        call  chk
        ld    a0, 0(s4)
        li    a1, 0x3333
        call  chk
        ld    a0, 0(s1)
        li    a1, 0x1111
        call  chk
        li    t0, 9
        sd    t0, 16(s2)                ; way 1 dirty; way 0 not
        ld    a0, E1 + 16(zero)
        li    a1, 1 << 33
        call  chk
        li    t0, 10
        sd    t0, 16(s1)                ; way 0 dirty too
        ld    a0, E1 + 16(zero)
        li    a1, 3 << 32
        call  chk

; ---- linst evicts the line -----------------------------------------------------
        li    t0, 3 << 32 | 1           ; the index to 1: A2's way
        sd    t0, E1 + 16(zero)
        ld    a0, 0(s2)                 ; A2 (way 1)
        li    a1, 0x2222
        call  chk
        linst s3                        ; A3 replaces A2 in way 1
h2:     ld    a0, 0(s2)                 ; dmiss
        li    a0, C_DMISS
        la    a1, h2
        mv    a2, s2
        call  chkt
        ld    a0, 0(s3)                 ; A3: way 1's line
        li    a1, 0x2222
        call  chk

; ---- a tget over the entry -----------------------------------------------------
        ld    a0, 0(s1)                 ; A1 (way 0)
        li    a1, 0x1111
        call  chk
        li    t0, E1
        li    t1, FAR
        li    t2, 8
        tget  tg1, t0, c0, t1, t2       ; zero its tag word
        twait tg1
h3:     ld    a0, 0(s1)                 ; dmiss
        li    a0, C_DMISS
        la    a1, h3
        mv    a2, s1
        call  chkt
        linst s1                        ; back (into way 0: the index was 0)

; ---- tdata and ttag --------------------------------------------------------------
        ld    a0, 0(s1)
        li    a1, 0x1111
        call  chk
        li    t0, TD + 0x40             ; the lines move by one line
        csrw  tdata, t0
        ld    a0, 0(s1)                 ; way 0 of set 13 is now at L0 + 0x40
        li    a1, 0x2222                ; = L1
        call  chk
        li    t0, TD
        csrw  tdata, t0
        ld    a0, 0(s1)
        li    a1, 0x1111
        call  chk
        li    t0, TT2                   ; an empty table
        csrw  ttag, t0
h4:     ld    a0, 0(s1)                 ; dmiss
        li    a0, C_DMISS
        la    a1, h4
        mv    a2, s1
        call  chkt
        li    t0, TT
        csrw  ttag, t0
        ld    a0, 0(s1)
        li    a1, 0x1111
        call  chk

        csrw  tgeom, zero
        csrw  ttag, zero
        csrw  tdata, zero
        j     done
