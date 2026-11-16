; =============================================================================
; farlsx.s: far loads and stores (tgeom.FA), the cases farls.s leaves out
; =============================================================================
;
; What it checks: four ways with a hit in the last; 8-byte lines; a far
; load or store right behind a tget into its line (it waits for the bytes);
; user mode with relocating Local Store windows (the table and the line are
; reached through them; a table or line outside them is an lsfault); dmiss
; taken by the supervisor and by the program's own handler; a tdata that is
; not 8-byte aligned (an access whose line address is not a multiple of its
; size is an lsfault, tval = the address, even inside one 64-bit word; one
; that is aligned works).
        .include "lib/conf.s"

FA   = 1 << 16
TT   = 0x6000
TD   = 0x7000
B    = 0x100000                         ; line 0x20000 (8-byte lines), set 0 of 2
KB   = (B >> 3) << 1 | 1                ; its key
FAR  = 0x200000

        .far
        .org  FAR
fsrc:   .dword 0x0102030405060708, 0x1112131415161718

        .text
main:
        csrr  t0, coreid
        bnez  t0, park
        li    t0, TT
        li    t1, TD + 0x800
clr:    sd    zero, 0(t0)
        addi  t0, t0, 8
        bltu  t0, t1, clr
        li    t0, TT
        csrw  ttag, t0
        li    t0, TD
        csrw  tdata, t0
        li    t0, 3 | 1 << 6 | 4 << 12 | FA   ; 8-byte lines, 2 sets, 4 ways
        csrw  tgeom, t0
        li    s1, B
        linst s1                        ; way 0
        addi  t0, s1, 16
        linst t0                        ; way 1
        addi  t0, s1, 32
        linst t0                        ; way 2
        addi  s2, s1, 48
        linst s2                        ; way 3
        li    t0, 0x4242
        sd    t0, TD + 24(zero)         ; way 3's line, set 0
        ld    a0, 0(s2)                 ; hit way 3
        call  sig
        li    t0, 0x77
        sh    t0, 6(s2)                 ; far store way 3: dirty bit 35
        ld    a0, TT + 32(zero)         ; set 0's counter
        call  sig
        ld    a0, TD + 24(zero)
        call  sig
        ; a far load right behind a tget into its line: waits for the bytes
        li    t0, TD + 24
        li    t1, FAR
        li    t2, 8
        tget  tg1, t0, c0, t1, t2
        ld    a0, 0(s2)
        call  sig
        twait tg1
        ; a far store right behind a tget into its line
        li    t0, TD + 24
        li    t1, FAR + 8
        tget  tg1, t0, c0, t1, t2
        li    t0, 0x99
        sb    t0, 1(s2)
        twait tg1
        ld    a0, TD + 24(zero)
        call  sig
        ; a far miss in set 1
        addi  t0, s1, 8
fx1:    lw    a0, 4(t0)
        li    a0, C_DMISS
        la    a1, fx1
        addi  a2, s1, 12
        call  chkt
        ; tdata not 8-aligned: the access stays in one word
        li    t0, TD + 4
        csrw  tdata, t0
        li    t0, 0x1111222233334444
        sd    t0, TD + 0(zero)
        li    t0, 0x5555666677778888
        sd    t0, TD + 8(zero)
        lw    a0, 0(s1)                 ; way 0 at TD+4: 0x11112222
        call  sig
        lh    a0, 2(s1)                 ; TD+6
        call  sig
        lbu   a0, 3(s1)                 ; TD+7
        call  sig
        li    t0, 0x12345678
        sw    t0, 0(s1)
        ld    a0, TD(zero)
        call  sig
fm1:    ld    a0, 0(s1)                 ; TD+4: in one word? no, and misaligned: lsfault
        li    a0, C_LSFAULT
        la    a1, fm1
        mv    a2, s1
        call  chkt
        li    t0, TD + 2                ; tdata 2 mod 8
        csrw  tdata, t0
fm2:    lw    a0, 0(s1)                 ; TD+2: inside one word, but misaligned: lsfault
        li    a0, C_LSFAULT
        la    a1, fm2
        mv    a2, s1
        call  chkt
        li    s5, 0x5a
fm3:    sh    s5, 4(s1)                 ; TD+6: halfword-aligned: fine
        li    a0, 0
        li    a1, 0
        li    a2, 0
        call  chkt
        lh    a0, 4(s1)
        call  sig
fm4:    sw    s5, 4(s1)                 ; TD+6 as a word: lsfault, nothing written
        li    a0, C_LSFAULT
        la    a1, fm4
        addi  a2, s1, 4
        call  chkt
        lb    a0, 1(s1)                 ; bytes are always aligned
        call  sig
        ld    a0, TD(zero)
        call  sig
        li    t0, TD + 4
        csrw  tdata, t0
        ld    a0, TT(zero)              ; set 0's ways and counter
        call  sig
        ld    a0, TT + 32(zero)
        call  sig

; ---- user mode, windows (64 KiB stores)
        li    s0, 1
        slli  s0, s0, 63
        li    t0, 48 << 8
        or    t0, t0, s0
        csrw  wdata, t0                 ; identity [0, 0xc000)
        li    t0, 60 | 4 << 8 | 52 << 16
        or    t0, t0, s0
        csrw  wstack, t0                ; 0xf000.. -> 0xd000..
        li    t0, 63 << 8
        or    t0, t0, s0
        csrw  wcode, t0
        li    t1, 0xd200                ; the table (physical)
        li    t0, KB
        sd    t0, 0(t1)                 ; way 0: B
        sd    zero, 8(t1)
        sd    zero, 16(t1)              ; counter
        li    t1, 0xd400                ; the line (physical)
        li    t0, 0xabcd
        sd    t0, 0(t1)
        li    t0, 3 | 0 << 6 | 2 << 12 | FA   ; 8-byte lines, 1 set, 2 ways
        csrw  tgeom, t0
        li    t0, 0xf200
        csrw  ttag, t0
        li    t0, 0xf400
        csrw  tdata, t0
        la    t0, back1
        sd    t0, uexit(zero)
        la    a0, user1
        call  to_user
user1:
        ld    s3, 0(s1)                 ; 0xabcd through the windows
        li    t0, 0x5151
        sw    t0, 4(s1)                 ; physical 0xd404, counter bit 32
ux1:    ld    a0, 8(s1)                 ; dmiss, to the supervisor (no utvec)
        li    a0, C_DMISS
        la    a1, ux1
        addi  a2, s1, 8
        call  chkt
        la    t0, utrap_rec
        csrw  utvec, t0
ux2:    ld    a0, 8(s1)                 ; dmiss, to the program's handler
        li    a0, C_DMISS
        la    a1, ux2
        addi  a2, s1, 8
        call  chkt
        li    t0, 0xc400                ; lines outside the windows
        csrw  tdata, t0
ux3:    ld    a0, 0(s1)
        li    a0, C_LSFAULT
        la    a1, ux3
        mv    a2, s1
        call  chkt
        li    t0, 0xf400
        csrw  tdata, t0
        li    t0, 0xc800                ; table outside the windows
        csrw  ttag, t0
ux4:    sd    zero, 0(s1)
        li    a0, C_LSFAULT
        la    a1, ux4
        li    a2, 0xc800
        call  chkt
        csrw  utvec, zero
        li    a7, UEXIT
        svc
back1:
        csrw  wdata, zero
        csrw  wstack, zero
        csrw  wcode, zero
        mv    a0, s3
        call  sig
        li    t1, 0xd200
        ld    a0, 16(t1)                ; counter: bit 32
        call  sig
        li    t1, 0xd400
        ld    a0, 0(t1)
        call  sig
        csrw  tgeom, zero
        csrw  ttag, zero
        csrw  tdata, zero
        j     done
