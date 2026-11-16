; =============================================================================
; farls.s: far loads and stores through the tag table (tgeom.FA)
; =============================================================================
;
; What it checks
;   * With tgeom bit 16 (FA) clear, a load beyond the D-LS is an lsfault, as
;     it always was.
;   * With FA set, a naturally aligned load or store at or past the D-LS
;     size looks its address up in the tag table as ltag does: a hit
;     reaches the bytes in the line (tdata + ((set * ways + w) << lsh) +
;     offset); a miss traps with dmiss, tval = the address, epc = the
;     instruction. Addresses inside the D-LS are unaffected.
;   * A far store to a way whose dirty bit (bit 32 + w of the set's counter
;     word) is clear sets it; the replacement index stays in bits 3:0.
;   * ltag's miss result has bit 62 set when the victim way is dirty;
;     linst clears the victim's dirty bit and keeps the others.
;   * Order of checks: misalignment (lsfault, tval = the address), then the
;     table (lsfault, tval = the entry), lines shorter than 8 bytes (lsfault,
;     tval = the address), then dmiss.
;   * Byte and word accesses, sign extension, an address that is negative
;     as a signed number.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

LSH  = 6                                ; 64-byte lines
SETS = 4                                ; 16 sets
WAYS = 2                                ; two ways: 24-byte entries
SPAN = (WAYS + 1) * 8                   ; ...
TT   = 0x6000                           ; the tag table (D-LS)
TD   = 0x7000                           ; the lines (16 sets x 2 ways x 64 bytes)
FA   = 1 << 16                          ; tgeom: far access
GEOM = LSH | SETS << 6 | WAYS << 12     ; ...
A1   = 0x12340                          ; line 0x48d, set 13, offset 0
SET1 = (A1 >> LSH) & 15                 ; its set
E1   = TT + SET1 * SPAN                 ; its entry
L0   = TD + ((SET1 * WAYS + 0) << LSH)  ; its way 0's line
L1   = TD + ((SET1 * WAYS + 1) << LSH)  ; its way 1's line
A2   = A1 + 16 * 64                     ; another line of the same set
A3   = A1 + 32 * 64                     ; a third
A4   = A1 + 48 * 64                     ; a fourth

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        li    t0, TT                    ; clear the tag table and the lines
        li    t1, TD + 0x800            ; the end
clr:    sd    zero, 0(t0)               ; one word
        addi  t0, t0, 8                 ; next
        bltu  t0, t1, clr               ; until the end
        li    t0, TT                    ; the table
        csrw  ttag, t0                  ; ...
        li    t0, TD                    ; the lines
        csrw  tdata, t0                 ; ...
        li    s1, A1                    ; s1..s4: four lines of one set
        li    s2, A2                    ; ...
        li    s3, A3                    ; ...
        li    s4, A4                    ; ...

; ---- FA clear: an lsfault, as always ----------------------------------------------------
        li    t0, GEOM                  ; the geometry, FA clear
        csrw  tgeom, t0                 ; ...
f0:     ld    a0, 0(s1)                 ; beyond the D-LS
        li    a0, C_LSFAULT             ; expected cause
        la    a1, f0                    ; expected epc
        mv    a2, s1                    ; expected tval: the address
        call  chkt                      ; check

; ---- FA set: a miss, an install, hits -----------------------------------------------------
        li    t0, GEOM | FA             ; far access on
        csrw  tgeom, t0                 ; ...
        csrr  a0, tgeom                 ; the bit reads back
        li    a1, GEOM | FA             ; expected
        call  chk                       ; check
f1:     ld    a0, 8(s1)                 ; not in the table: dmiss
        li    a0, C_DMISS               ; expected cause
        la    a1, f1                    ; expected epc
        addi  a2, s1, 8                 ; expected tval: the address
        call  chkt                      ; check
        linst s1                        ; install A1's line in way 0, counter 1
        li    t0, 0x1122334455667788    ; what the line holds at offset 8
        sd    t0, L0 + 8(zero)          ; ...
        ld    a0, 8(s1)                 ; a hit
        li    a1, 0x1122334455667788    ; expected
        call  chk                       ; check
        lw    a0, 12(s1)                ; a word, sign-extended
        li    a1, 0x11223344            ; expected
        call  chk                       ; check
        lbu   a0, 9(s1)                 ; a byte
        li    a1, 0x77                  ; expected
        call  chk                       ; check
        ld    a0, E1 + 16(zero)         ; the counter: index 1, nothing dirty
        li    a1, 1                     ; expected
        call  chk                       ; check

; ---- stores, dirty bits ---------------------------------------------------------------------
        li    t0, -2                    ; a far store
        sd    t0, 16(s1)                ; ...
        ld    a0, L0 + 16(zero)         ; reached the line
        li    a1, -2                    ; expected
        call  chk                       ; check
        ld    a0, E1 + 16(zero)         ; the counter: way 0 dirty
        li    a1, 1 << 32 | 1           ; expected
        call  chk                       ; check
        li    t0, 0x80                  ; a far byte store
        sb    t0, 3(s1)                 ; ...
        lb    a0, 3(s1)                 ; read back, sign-extended
        li    a1, -128                  ; expected
        call  chk                       ; check
        ld    a0, E1 + 16(zero)         ; the counter: unchanged
        li    a1, 1 << 32 | 1           ; expected
        call  chk                       ; check
        linst s2                        ; A2 in way 1, the index wraps to 0
        ld    a0, E1 + 16(zero)         ; the counter: way 0 still dirty
        li    a1, 1 << 32               ; expected
        call  chk                       ; check
        ltag  a0, s3                    ; A3: a miss, victim way 0, dirty
        li    a1, 3 << 62 | L0          ; expected: bits 63 and 62
        call  chk                       ; check
        linst s3                        ; A3 replaces A1 in way 0: its dirty bit goes
        ld    a0, E1 + 16(zero)         ; the counter: index 1, nothing dirty
        li    a1, 1                     ; expected
        call  chk                       ; check
        sw    t0, 4(s2)                 ; a far store to way 1
        ld    a0, E1 + 16(zero)         ; the counter: way 1 dirty
        li    a1, 1 << 33 | 1           ; expected
        call  chk                       ; check
        ltag  a0, s4                    ; A4: a miss, victim way 1, dirty
        li    a1, 3 << 62 | L1          ; expected
        call  chk                       ; check
        ltag  a0, s1                    ; A1 is gone: a miss (victim way 1)
        li    a1, 3 << 62 | L1          ; expected
        call  chk                       ; check
        li    t0, 1 << 32 | 1           ; way 0 dirty in software's own write
        sd    t0, E1 + 16(zero)         ; ...
        linst s4                        ; A4 into way 1: way 0's bit stays
        ld    a0, E1 + 16(zero)         ; the counter
        li    a1, 1 << 32               ; expected
        call  chk                       ; check
        ltag  a0, s4                    ; a hit in way 1
        li    a1, L1                    ; expected
        call  chk                       ; check
f2:     ld    a0, 0(s1)                 ; A1 is not there: dmiss
        li    a0, C_DMISS               ; expected cause
        la    a1, f2                    ; expected epc
        mv    a2, s1                    ; expected tval
        call  chkt                      ; check

; ---- the D-LS itself is unaffected ------------------------------------------------------
        ld    a0, L1 + 4(zero)          ; an ordinary load: the word stored above
        li    a1, 0x80                  ; expected (A2's line was in way 1 then)
        call  sig                       ; record it
        li    t0, 0x5a                  ; an ordinary store
        sd    t0, 0x7ff8(zero)          ; ...
        ld    a0, 0x7ff8(zero)          ; ...
        li    a1, 0x5a                  ; expected
        call  chk                       ; check

; ---- the order of the checks ----------------------------------------------------------------
f3:     ld    a0, 4(s4)                 ; misaligned: lsfault before the table
        li    a0, C_LSFAULT             ; expected cause
        la    a1, f3                    ; expected epc
        addi  a2, s4, 4                 ; expected tval: the address
        call  chkt                      ; check
        li    t0, LSH | SETS << 6 | FA  ; ways = 0: a bad table
        csrw  tgeom, t0                 ; ...
f4:     ld    a0, 0(s4)                 ; lsfault on the entry
        li    a0, C_LSFAULT             ; expected cause
        la    a1, f4                    ; expected epc
        li    a2, TT + SET1 * 8         ; expected tval: the entry address (span 8)
        call  chkt                      ; check
        li    t0, 2 | 8 << 6 | WAYS << 12 | FA ; 4-byte lines: too short
        csrw  tgeom, t0                 ; ...
f5:     lb    a0, 0(s4)                 ; lsfault, the address
        li    a0, C_LSFAULT             ; expected cause
        la    a1, f5                    ; expected epc
        mv    a2, s4                    ; expected tval
        call  chkt                      ; check
        li    t0, GEOM | FA             ; the good geometry again
        csrw  tgeom, t0                 ; ...
        li    s5, -64                   ; negative as a signed number: far too
f6:     sd    zero, 0(s5)               ; dmiss
        li    a0, C_DMISS               ; expected cause
        la    a1, f6                    ; expected epc
        mv    a2, s5                    ; expected tval
        call  chkt                      ; check
        linst s5                        ; install it
        li    t0, 99                    ; and store
        sd    t0, 8(s5)                 ; a hit now
        ld    a0, 8(s5)                 ; ...
        li    a1, 99                    ; expected
        call  chk                       ; check

        csrw  tgeom, zero               ; off
        csrw  ttag, zero                ; ...
        csrw  tdata, zero               ; ...
        j     done                      ; print the signature and the verdict
