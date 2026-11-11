; =============================================================================
; ltag.s: the tag-lookup instructions ltag / linst
; =============================================================================
;
; What it checks
;   * tgeom = lsh | lsets << 6 | ways << 12 (line 2^lsh bytes, 2^lsets sets,
;     ways 1..15); the set of address a is (a >> lsh) & (2^lsets - 1), its
;     entry at ttag + set * (ways + 1) * 8 in the D-LS: ways tag words (key
;     = line << 1 | 1) and the replacement counter.
;   * ltag rd, rs: a hit in way w gives tdata + ((set * ways + w) << lsh) +
;     (a mod 2^lsh); a miss gives bit 63 | tdata + ((set * ways + v) << lsh),
;     v = the counter (0 if it is not below ways).
;   * linst rs: writes the key into the victim way and advances the counter
;     (wrapping at ways).
;   * lsfault (tval = the entry address, computed in 64 bits: it may wrap)
;     when ways = 0, the entry address is misaligned, or the entry does not
;     fit in the D-LS; an entry address that wraps around into the D-LS is
;     an ordinary lookup.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

LSH  = 6                                ; 64-byte lines
SETS = 4                                ; 16 sets
WAYS = 3                                ; three ways: 32-byte entries
TT   = 0x6000                           ; the tag table (D-LS)
TD   = 0x100000                         ; tdata: the cached lines' base
A1   = 0x12345                          ; line 0x48d, set 13, offset 5
SET1 = (A1 >> LSH) & 15                 ; its set

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    t0, TT                    ; clear the tag table (16 x 32 bytes) and 512 more
        li    t1, TT + 0x400            ; the end
clr:    sd    zero, 0(t0)               ; one word
        addi  t0, t0, 8                 ; next
        bltu  t0, t1, clr               ; until the end
        li    t0, LSH | SETS << 6 | WAYS << 12 ; the geometry
        csrw  tgeom, t0                 ; ...
        li    t0, TT                    ; the table
        csrw  ttag, t0                  ; ...
        li    t0, TD                    ; the data base
        csrw  tdata, t0                 ; ...

; ---- misses, installs, hits, replacement ---------------------------------------------
        li    s1, A1                    ; a first address
        ltag  a0, s1                    ; empty: a miss, victim 0
        li    a1, 1 << 63 | TD + ((SET1 * WAYS + 0) << LSH) ; expected
        call  chk                       ; check
        linst s1                        ; way 0 = A1's line, counter 1
        ltag  a0, s1                    ; a hit in way 0
        li    a1, TD + ((SET1 * WAYS + 0) << LSH) + 5 ; expected: with the offset
        call  chk                       ; check
        li    s2, A1 + 16 * 64 + 0x30   ; another line of the same set, offset 0x35
        ltag  a0, s2                    ; a miss, victim 1
        li    a1, 1 << 63 | TD + ((SET1 * WAYS + 1) << LSH) ; expected
        call  chk                       ; check
        linst s2                        ; way 1, counter 2
        ltag  a0, s2                    ; a hit in way 1
        li    a1, TD + ((SET1 * WAYS + 1) << LSH) + 0x35 ; expected
        call  chk                       ; check
        ltag  a0, s1                    ; the first line is still there
        li    a1, TD + ((SET1 * WAYS + 0) << LSH) + 5 ; expected
        call  chk                       ; check
        li    s3, A1 + 32 * 64          ; a third line of the set
        linst s3                        ; way 2, counter wraps to 0
        li    s4, A1 + 48 * 64          ; a fourth
        linst s4                        ; replaces way 0 (A1), counter 1
        ltag  a0, s1                    ; A1 is gone: a miss, victim 1
        li    a1, 1 << 63 | TD + ((SET1 * WAYS + 1) << LSH) ; expected
        call  chk                       ; check
        ltag  a0, s4                    ; the fourth line, in way 0
        li    a1, TD + ((SET1 * WAYS + 0) << LSH) + 5 ; expected
        call  chk                       ; check
        ld    a0, TT + SET1 * 32 + 24(zero) ; the set's counter word
        li    a1, 1                     ; expected
        call  chk                       ; check
        li    t0, 7                     ; a counter not below ways
        sd    t0, TT + SET1 * 32 + 24(zero) ; ...
        li    s5, A1 + 64 * 64          ; a fifth line: a miss
        ltag  a0, s5                    ; victim 0 (counter out of range)
        li    a1, 1 << 63 | TD + ((SET1 * WAYS + 0) << LSH) ; expected
        call  chk                       ; check
        ld    a0, TT + 8 * 32(zero)     ; another set was not touched
        li    a1, 0                     ; expected
        call  chk                       ; check

; ---- the entry address: faults and wrap-around ------------------------------------------------
        li    t0, LSH | SETS << 6       ; ways = 0
        csrw  tgeom, t0                 ; ...
lf1:    ltag  a0, s1                    ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf1                   ; expected epc
        li    a2, TT + SET1 * 8         ; expected tval: the entry address, span 8
        call  chkt                      ; check
        li    t0, LSH | SETS << 6 | WAYS << 12 ; ways again
        csrw  tgeom, t0                 ; ...
        li    t0, TT + 4                ; a misaligned table
        csrw  ttag, t0                  ; ...
lf2:    linst s1                        ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf2                   ; expected epc
        li    a2, TT + 4 + SET1 * 32    ; expected tval
        call  chkt                      ; check
        li    t0, 0x10000 - 32 * SET1   ; set 13's entry would start at the end of the D-LS
        csrw  ttag, t0                  ; ...
lf3:    ltag  a0, s1                    ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf3                   ; expected epc
        li    a2, 0x10000               ; expected tval
        call  chkt                      ; check
        li    t0, 0x10000 - 32 * SET1 - 32 ; the last 32 bytes of the D-LS: fits
        csrw  ttag, t0                  ; ...
        ltag  a0, s1                    ; an ordinary lookup (whatever is there)
        call  sig                       ; record it
        li    t0, 63 | 63 << 6 | 15 << 12 ; 2^63-byte lines, 2^63 sets, 15 ways (128-byte entries)
        csrw  tgeom, t0                 ; ...
        li    t0, TT                    ; the table
        csrw  ttag, t0                  ; ...
        li    s6, -1                    ; all ones: line 1, set 1
        ltag  a0, s6                    ; entry TT + 128: fits; a miss
        li    a1, 1 << 63 | TD + (15 << 63) ; expected: (set * 15 + 0) << 63 = 2^63
        call  chk                       ; check
        li    t0, 0 | 63 << 6 | 15 << 12 ; lsh 0: line = address; 2^63 sets
        csrw  tgeom, t0                 ; ...
        li    t0, TT + 128              ; ttag + set * 128 wraps around to TT
        csrw  ttag, t0                  ; ...
        li    s6, 0x01ffffffffffffff    ; set 2^57 - 1: set * 128 = 2^64 - 128
        linst s6                        ; entry TT (the wrapped address): way 0
        ld    a0, TT(zero)              ; the key
        li    a1, 0x01ffffffffffffff << 1 | 1 ; expected
        call  chk                       ; check
        ltag  a0, s6                    ; now a hit in way 0
        li    a1, TD + ((0x01ffffffffffffff * 15) << 0) ; expected: tdata + set * ways
        call  chk                       ; check
        li    t0, TT                    ; the table
        csrw  ttag, t0                  ; ...
        li    s6, 0x4000000000000200    ; set 0x4000000000000200
lf5:    ltag  a0, s6                    ; entry TT + set * 128 (mod 2^64): beyond the D-LS
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf5                   ; expected epc
        li    a2, TT + 0x200 * 128      ; expected tval: set * 128 wraps (2^62 * 128 = 0)
        call  chkt                      ; check
        li    s6, 0x2000000000000005    ; set * 128 = 2^68 + 5 * 128: wraps to 0x280
        linst s6                        ; entry TT + 0x280: installs in way 0
        ld    a0, TT + 0x280(zero)      ; way 0 of that entry
        li    a1, 0x2000000000000005 << 1 | 1 ; expected: the key
        call  chk                       ; check
        ld    a0, TT + 0x280 + 15 * 8(zero) ; its counter
        li    a1, 1                     ; expected
        call  chk                       ; check
        li    t0, TT + 4                ; misaligned table
        csrw  ttag, t0                  ; ...
lf7:    ltag  a0, s6                    ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf7                   ; expected epc
        li    a2, TT + 4 + 0x280        ; expected tval
        call  chkt                      ; check
        csrw  tgeom, zero               ; off
        csrw  ttag, zero                ; ...
        csrw  tdata, zero               ; ...
        j     done                      ; print the signature and the verdict
