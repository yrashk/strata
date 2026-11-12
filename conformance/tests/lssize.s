; =============================================================================
; lssize.s: the Local Stores' sizes, a platform parameter
; =============================================================================
;
; What it checks (manual: Local Stores, platform table, reset state). The
; sizes come from the platform table, so the test runs on any machine; the
; suite runs it at 64/64 KiB and `make test-ls` at 32/32 and 16/4 KiB
; (D-LS/I-LS), on the emulator (-L) and an RTL built with DLS_KIB / ILS_KIB.
;   * The platform table's header: u16 D-LS KiB at 24, u16 I-LS KiB at 26,
;     each a power of two, 4..64; bytes 28..31 reserved (zero).
;   * Reset puts the D-LS size in sp (the harness keeps it in rsp).
;   * Loads and stores: the last doubleword and the last byte of the D-LS
;     work; an access at the size, one that runs past it, a misaligned one
;     there, and one at twice the size minus 8 (no aliasing of a smaller
;     store's address bits) trap with lsfault, tval = the address; a faulting
;     load leaves rd alone, a faulting store leaves memory alone.
;   * Transfers: tget / tput D-LS ranges are checked against the D-LS size
;     and tgetx I-LS ranges against the I-LS size (the last word: fine; one
;     past: lsfault, tval = the Local Store address; an empty range at the
;     end: fine; an address past the end, even with length 0: lsfault).
;   * Fetch: code tgetx'ed into the last 8 bytes of the I-LS runs; running
;     off its end, and jumping to the size or twice the size, trap with
;     ifault, epc = tval = the pc.
;   * xmap: an I-LS address in the last word maps (xcall runs it); one at
;     the I-LS size traps with lsfault, tval = that address.
;   * ltag: a set entry that ends at the top of the D-LS works; one that runs
;     past it traps with lsfault, tval = the entry address.
; With different D-LS and I-LS sizes, every check of one store against the
; other's size is caught (16/4: tget at the end of the D-LS, tgetx past the
; I-LS).

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

FAR = 0x200000                          ; system memory scratch (c0 offset)

        .far                            ; system memory image (c0 offsets)
        .org  FAR                       ; code for the top of the I-LS
tail7:  addi  a0, a0, 7                 ; a0 += 7
        ret                             ; back
        .org  FAR + 8                   ; code that runs off the end of the I-LS
tail2:  addi  a0, a0, 1                 ; a0 += 1
        addi  a0, a0, 1                 ; a0 += 1, then the next fetch is at the I-LS size
        .org  FAR + 0x100               ; a doubleword written through a tput
fword:  .dword 0

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
tbl:    .space 32                       ; the platform table's header

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        la    s1, tbl                   ; s1 = the header buffer
        li    t0, 0x1000                ; the platform table's window
        li    t1, 32                    ; its header
        tget  tg1, s1, c3, t0, t1       ; read it
        twait tg1                       ; ...

; ---- the platform table and the reset sp ----------------------------------------------------
        lhu   s2, 24(s1)                ; s2 = D-LS KiB
        lhu   s3, 26(s1)                ; s3 = I-LS KiB
        mv    a0, s2                    ; record them
        call  sig                       ; ...
        mv    a0, s3                    ; ...
        call  sig                       ; ...
        lwu   a0, 28(s1)                ; reserved
        li    a1, 0                     ; zero
        call  chk                       ; check
        slli  s2, s2, 10                ; s2 = D-LS bytes
        slli  s3, s3, 10                ; s3 = I-LS bytes
        mv    a0, s2                    ; each a power of two, 4 KiB..64 KiB
        call  pow2ok                    ; ...
        mv    a0, s3                    ; ...
        call  pow2ok                    ; ...
        ld    a0, rsp(zero)             ; the sp reset gave this core
        mv    a1, s2                    ; is the D-LS size
        call  chk                       ; check
        addi  sp, s2, -1024             ; a stack below the top 1 KiB (which the test uses)

; ---- loads and stores at the top of the D-LS ---------------------------------------------------
        li    t0, 0x55                  ; t0 = a value
        sd    t0, -8(s2)                ; the last doubleword
        ld    a0, -8(s2)                ; reads back
        li    a1, 0x55                  ; ...
        call  chk                       ; check
        lbu   a0, -1(s2)                ; the last byte (the value's top byte)
        li    a1, 0                     ; ...
        call  chk                       ; check
        li    a0, 0                     ; no trap so far
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        call  chkt                      ; check
        li    a0, 0x1234                ; a faulting load leaves rd alone
lf1:    ld    a0, 0(s2)                 ; at the size: lsfault
        li    a1, 0x1234                ; ...
        call  chk                       ; check
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf1                   ; expected epc
        mv    a2, s2                    ; expected tval: the address
        call  chkt                      ; check
lf2:    lw    a0, -2(s2)                ; misaligned, running past the end
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf2                   ; expected epc
        addi  a2, s2, -2                ; expected tval
        call  chkt                      ; check
        li    t0, 0x77                  ; a value a faulting store must not write
lf3:    sd    t0, -4(s2)                ; past the end
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf3                   ; expected epc
        addi  a2, s2, -4                ; expected tval
        call  chkt                      ; check
lf4:    sb    t0, 0(s2)                 ; the first byte past the end
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf4                   ; expected epc
        mv    a2, s2                    ; expected tval
        call  chkt                      ; check
        add   s4, s2, s2                ; s4 = twice the size
        addi  s4, s4, -8                ; minus 8: its low bits name the last doubleword
lf5:    sd    t0, 0(s4)                 ; must not wrap around into the D-LS
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf5                   ; expected epc
        mv    a2, s4                    ; expected tval
        call  chkt                      ; check
lf6:    ld    a0, 0(s4)                 ; nor read it
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lf6                   ; expected epc
        mv    a2, s4                    ; expected tval
        call  chkt                      ; check
        ld    a0, -8(s2)                ; the last doubleword is still the first value
        li    a1, 0x55                  ; ...
        call  chk                       ; check

; ---- transfers: the D-LS range of tget / tput, the I-LS range of tgetx --------------------------
        li    t1, FAR + 0x100           ; t1 = the far word
        li    t2, 8                     ; t2 = 8 bytes
        addi  t3, s2, -8                ; t3 = the last D-LS doubleword
        tput  tg1, t3, c0, t1, t2       ; D-LS -> far
        addi  t4, s2, -16               ; t4 = the one below it
        tget  tg2, t4, c0, t1, t2       ; far -> D-LS
        ld    a0, -16(s2)               ; (the load waits for the transfer)
        li    a1, 0x55                  ; the value went out and came back
        call  chk                       ; check
        li    a0, 0                     ; no trap
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        call  chkt                      ; check
        li    t5, 16                    ; 16 bytes from the last doubleword: past the end
xf1:    tget  tg1, t3, c0, t1, t5       ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xf1                   ; expected epc
        mv    a2, t3                    ; expected tval: the Local Store address
        call  chkt                      ; check
xf2:    tput  tg1, s2, c0, t1, t2       ; from the size on: lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xf2                   ; expected epc
        mv    a2, s2                    ; expected tval
        call  chkt                      ; check
        tget  tg1, s2, c0, t1, zero     ; an empty range at the end: fine
        li    a0, 0                     ; no trap
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        call  chkt                      ; check
        addi  t6, s2, 8                 ; past the end, length 0
xf3:    tget  tg1, t6, c0, t1, zero     ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xf3                   ; expected epc
        mv    a2, t6                    ; expected tval
        call  chkt                      ; check
        addi  s5, s3, -8                ; s5 = the last 8 bytes of the I-LS
        li    t1, FAR                   ; the code for them
        tgetx tg3, s5, c0, t1, t2       ; installs it
        li    a0, 0                     ; no trap
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        call  chkt                      ; check
xf4:    tgetx tg3, s5, c0, t1, t5       ; 16 bytes: past the end of the I-LS
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xf4                   ; expected epc
        mv    a2, s5                    ; expected tval
        call  chkt                      ; check
xf5:    tgetx tg3, s3, c0, t1, t2       ; at the I-LS size: lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xf5                   ; expected epc
        mv    a2, s3                    ; expected tval
        call  chkt                      ; check

; ---- fetching at the top of the I-LS --------------------------------------------------------------
        li    a0, 0                     ; a0 = 0
        jalr  ra, s5, 0                 ; the installed code: a0 += 7, ret
        li    a1, 7                     ; it ran
        call  chk                       ; check
        li    t1, FAR + 8               ; code that runs off the end
        li    t2, 8                     ; ...
        tgetx tg3, s5, c0, t1, t2       ; replaces it
        la    t0, if1                   ; resume there after the fetch fault
        sd    t0, tresume(zero)         ; ...
        li    a0, 0                     ; a0 = 0
        jalr  zero, s5, 0               ; a0 += 1 twice, then the fetch at the size faults
if1:    li    a1, 2                     ; both instructions ran
        call  chk                       ; check
        li    a0, C_IFAULT              ; expected cause
        mv    a1, s3                    ; expected epc: the I-LS size
        mv    a2, s3                    ; expected tval
        call  chkt                      ; check
        la    t0, if2                   ; resume point
        sd    t0, tresume(zero)         ; ...
        add   s6, s3, s3                ; twice the I-LS size
        jalr  zero, s6, 0               ; must not wrap around into the I-LS
if2:    li    a0, C_IFAULT              ; expected cause
        mv    a1, s6                    ; expected epc
        mv    a2, s6                    ; expected tval
        call  chkt                      ; check

; ---- xmap: the I-LS address --------------------------------------------------------------------
        li    t1, FAR                   ; the "a0 += 7" code again
        li    t2, 8                     ; ...
        tgetx tg3, s5, c0, t1, t2       ; at the top of the I-LS
        xmap  0, s5, c0, t1             ; far FAR -> the last I-LS word pair
        li    a0, 0                     ; a0 = 0
        xcall ra, c0, t1                ; runs it
        li    a1, 7                     ; ...
        call  chk                       ; check
xm1:    xmap  1, s3, c0, t1             ; at the I-LS size: lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, xm1                   ; expected epc
        mv    a2, s3                    ; expected tval
        call  chkt                      ; check
        xunmap 0                        ; done with the map

; ---- ltag: the set entry against the D-LS size -------------------------------------------------
        li    t0, 6 | 0 << 6 | 1 << 12  ; 64-byte lines, one set, one way: 16-byte entries
        csrw  tgeom, t0                 ; ...
        addi  t0, s2, -16               ; the entry: the last 16 bytes of the D-LS
        csrw  ttag, t0                  ; ...
        sd    zero, -16(s2)             ; an empty way
        sd    zero, -8(s2)              ; and its counter
        li    t1, 0x40                  ; a line address
        ltag  a0, t1                    ; a miss: fits
        call  sig                       ; record what it returned
        li    a0, 0                     ; no trap
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        call  chkt                      ; check
        addi  t0, s2, -8                ; an entry that runs 8 bytes past the end
        csrw  ttag, t0                  ; ...
lt1:    ltag  a0, t1                    ; lsfault
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lt1                   ; expected epc
        addi  a2, s2, -8                ; expected tval: the entry address
        call  chkt                      ; check
        csrw  tgeom, zero               ; leave the cache geometry as at reset
        csrw  ttag, zero                ; ...
        j     done                      ; print the signature and the verdict

; pow2ok(a0 = bytes): check that a0 is a power of two in [4 KiB, 64 KiB]
pow2ok:
        mv    s7, ra                    ; keep the return address
        mv    s8, a0                    ; keep the size
        addi  t0, s8, -1                ; a power of two has no bit in common with itself - 1
        and   a0, s8, t0                ; ...
        li    a1, 0                     ; ...
        call  chk                       ; check
        li    t0, 4096                  ; at least 4 KiB
        sltu  a0, s8, t0                ; 1 if below
        li    a1, 0                     ; ...
        call  chk                       ; check
        li    t0, 65537                 ; at most 64 KiB
        sltu  a0, s8, t0                ; 1 if not above
        li    a1, 1                     ; ...
        call  chk                       ; check
        jr    s7                        ; back
