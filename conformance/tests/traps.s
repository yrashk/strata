; =============================================================================
; traps.s: trap causes, precise epc / tval, supervisor and user routing,
; banked CSRs, eret, svc, privileged operations and the user-mode inbox rule
; =============================================================================
;
; What it checks (the rules, as emu/emu.c implements them)
;   * Every trap records cause, epc (the address of the instruction that
;     trapped: nothing after it has run) and tval, then jumps to the trap
;     vector. Causes produced here: 1 illegal, 2 lsfault, 3 capinv, 4 perm,
;     5 bounds, 6 xalign, 8 xmiss, 10 capop (supervisor); 11 priv, 12 halt,
;     13 stop, 14 svc (user mode). 7 ifault: branch.s. 9 pend: xfer-pend.s.
;   * Illegal (tval = the instruction word): every unassigned opcode, SYS
;     with an unknown imm16, svc in supervisor mode, a transfer sub-op > 2,
;     tamo with an unknown op or nonzero reserved bits, a capability op whose
;     capability-register field has bit 4 set, CAP2 functions > 7, xmap with
;     an index >= 16.
;   * Two register banks of trap state: in supervisor mode cause/epc/tval/
;     tvec name the supervisor's, in user mode the user's (ucause/uepc/utval/
;     utvec name the user bank explicitly, from supervisor mode).
;   * In user mode a trap goes to the user handler (utvec) when one is
;     installed, except halt (12), stop (13), priv (11) and svc (14), which
;     always go to the supervisor; so does any trap when utvec = 0, or when
;     the user handler's own first instruction traps.
;   * In user mode these are privileged (cause 11, tval = the instruction):
;     writing status, corebase, corecount, ucause..ipend (CSRs 18..24);
;     reading sscratch and ipend; csave / crestore; cdom / crevoke / cundom /
;     cmkep; and the inbox: ctake (any or named sender), cpoll, tany with bit
;     16. cgive with no core window (corecount = 0) is capop.
;   * eret in supervisor mode returns to epc in the mode status bit 1 names
;     (set: supervisor); in user mode it jumps to uepc and stays in user mode.
;   * status reads bit 0 = "in supervisor mode", bit 1 = "eret returns to
;     supervisor". A trap from user mode clears bit 1, a trap from
;     supervisor mode sets it.
;   * A core-control stop request (ipend) is held while in supervisor mode
;     and taken (cause 13, epc = the first user instruction, tval 0) as soon
;     as the core is in user mode.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store
        .align 8                        ; transfer buffers are 8-byte aligned
buf:    .space 64                       ; transfer scratch
one:    .dword 1                        ; a core-control word: bit 0 = stop

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test

; ---- reset state of status: supervisor, eret returns to supervisor ------------
        csrr  a0, status                ; a0 = status
        li    a1, 3                     ; expected: bit 0 (supervisor) | bit 1 (spp = supervisor)
        call  chk                       ; check
        li    t0, 0                     ; t0 = 0
        csrw  status, t0                ; clear bit 1: eret would now enter user mode
        csrr  a0, status                ; a0 = status
        li    a1, 1                     ; expected: still supervisor, spp = user
        call  chk                       ; check
        li    t0, 2                     ; t0 = bit 1
        csrw  status, t0                ; back to "eret returns to supervisor"
        csrr  a0, status                ; read back
        li    a1, 3                     ; expected: 3
        call  chk                       ; check

; ---- plain CSRs -------------------------------------------------------------------
        csrr  a0, ncores                ; a0 = core count (no core window)
        li    a1, 8                     ; the suite runs on 8-core machines
        call  chk                       ; check
        li    t0, 0x123456789           ; a value
        csrw  scratch, t0               ; scratch is plain read/write
        csrr  a0, scratch               ; read it back
        li    a1, 0x123456789           ; expected: the value
        call  chk                       ; check
        csrw  sscratch, t0              ; sscratch: supervisor scratch, read/write here
        csrr  a0, sscratch              ; read back
        li    a1, 0x123456789           ; expected: the value
        call  chk                       ; check
        li    t0, 65                    ; 65 = 64 + 1
        csrw  xslot, t0                 ; xslot keeps only 6 bits
        csrr  a0, xslot                 ; read back
        li    a1, 1                     ; expected: 65 & 63
        call  chk                       ; check
        csrw  xslot, zero               ; back to exact-match overlay mapping
        csrr  a0, corecount             ; no core window yet
        li    a1, 0                     ; expected 0
        call  chk                       ; check
        csrr  a0, corebase              ; window base
        li    a1, 0                     ; expected 0
        call  chk                       ; check
        csrr  a0, utvec                 ; the user trap vector: none at reset
        li    a1, 0                     ; expected 0
        call  chk                       ; check

; ---- cause 1, illegal: every unassigned opcode (tval = the instruction word) -----
ill_00: .word 0x0b << 26                ; opcode 0x0b: unassigned
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_00                ; expected epc
        li    a2, 0x0b << 26            ; expected tval: the word
        call  chkt                      ; check
ill_01: .word 0x0c << 26                ; opcode 0x0c: unassigned
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_01                ; expected epc
        li    a2, 0x0c << 26            ; expected tval
        call  chkt                      ; check
ill_02: .word 0x0d << 26                ; opcode 0x0d
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_02                ; expected epc
        li    a2, 0x0d << 26            ; expected tval
        call  chkt                      ; check
ill_03: .word 0x0e << 26                ; opcode 0x0e
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_03                ; expected epc
        li    a2, 0x0e << 26            ; expected tval
        call  chkt                      ; check
ill_04: .word 0x0f << 26                ; opcode 0x0f
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_04                ; expected epc
        li    a2, 0x0f << 26            ; expected tval
        call  chkt                      ; check
ill_05: .word 0x17 << 26                ; opcode 0x17 (between the loads and the stores)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_05                ; expected epc
        li    a2, 0x17 << 26            ; expected tval
        call  chkt                      ; check
ill_06: .word 0x1c << 26                ; opcode 0x1c
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_06                ; expected epc
        li    a2, 0x1c << 26            ; expected tval
        call  chkt                      ; check
ill_07: .word 0x1d << 26                ; opcode 0x1d
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_07                ; expected epc
        li    a2, 0x1d << 26            ; expected tval
        call  chkt                      ; check
ill_08: .word 0x1e << 26                ; opcode 0x1e
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_08                ; expected epc
        li    a2, 0x1e << 26            ; expected tval
        call  chkt                      ; check
ill_09: .word 0x1f << 26                ; opcode 0x1f
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_09                ; expected epc
        li    a2, 0x1f << 26            ; expected tval
        call  chkt                      ; check
ill_10: .word 0x26 << 26                ; opcode 0x26 (between the branches and jal)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_10                ; expected epc
        li    a2, 0x26 << 26            ; expected tval
        call  chkt                      ; check
ill_11: .word 0x27 << 26                ; opcode 0x27
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_11                ; expected epc
        li    a2, 0x27 << 26            ; expected tval
        call  chkt                      ; check
ill_12: .word 0x2a << 26                ; opcode 0x2a
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_12                ; expected epc
        li    a2, 0x2a << 26            ; expected tval
        call  chkt                      ; check
ill_13: .word 0x2b << 26                ; opcode 0x2b
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_13                ; expected epc
        li    a2, 0x2b << 26            ; expected tval
        call  chkt                      ; check
ill_14: .word 0x2c << 26                ; opcode 0x2c
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_14                ; expected epc
        li    a2, 0x2c << 26            ; expected tval
        call  chkt                      ; check
ill_15: .word 0x2d << 26                ; opcode 0x2d
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_15                ; expected epc
        li    a2, 0x2d << 26            ; expected tval
        call  chkt                      ; check
ill_16: .word 0x2e << 26                ; opcode 0x2e
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_16                ; expected epc
        li    a2, 0x2e << 26            ; expected tval
        call  chkt                      ; check
ill_17: .word 0x2f << 26                ; opcode 0x2f
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_17                ; expected epc
        li    a2, 0x2f << 26            ; expected tval
        call  chkt                      ; check
ill_18: .word 0x37 << 26                ; opcode 0x37 (between tany and csrr)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_18                ; expected epc
        li    a2, 0x37 << 26            ; expected tval
        call  chkt                      ; check
ill_19: .word 0x3f << 26 | 0x3ffffff    ; opcode 0x3f, every other bit set
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_19                ; expected epc
        li    a2, 0xffffffff            ; expected tval (zero-extended word)
        call  chkt                      ; check

; ---- cause 1, illegal: malformed instructions of assigned opcodes ----------------
ill_20: .word 0x3a << 26 | 3            ; SYS with imm16 = 3 (0 halt, 1 eret, 2 svc)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_20                ; expected epc
        li    a2, 0x3a << 26 | 3        ; expected tval
        call  chkt                      ; check
ill_21: svc                             ; svc in supervisor mode is illegal
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_21                ; expected epc
        li    a2, 0x3a << 26 | 2        ; expected tval: the svc word
        call  chkt                      ; check
ill_22: .word 0x30 << 26 | 3 << 23      ; transfer with sub-op 3 (0 get, 1 put, 2 getx)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_22                ; expected epc
        li    a2, 0x30 << 26 | 3 << 23  ; expected tval
        call  chkt                      ; check
ill_23: .word 0x33 << 26 | 5            ; tamo with op 5 (0..4 assigned): checked before the capability
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_23                ; expected epc
        li    a2, 0x33 << 26 | 5        ; expected tval
        call  chkt                      ; check
ill_24: .word 0x33 << 26 | 8            ; tamo.add with a reserved bit (funct bit 3) set
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_24                ; expected epc
        li    a2, 0x33 << 26 | 8        ; expected tval
        call  chkt                      ; check
ill_25: .word 0x34 << 26 | 16 << 21     ; cmov with cd field = 16 (capability registers are 0..15)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_25                ; expected epc
        li    a2, 0x34 << 26 | 16 << 21 ; expected tval
        call  chkt                      ; check
ill_26: .word 0x34 << 26 | 18 << 16 | 6 ; cbase (fn 6) with cs field = 18
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_26                ; expected epc
        li    a2, 0x34 << 26 | 18 << 16 | 6 ; expected tval
        call  chkt                      ; check
ill_27: .word 0x35 << 26 | 8            ; CAP2 function 8 (0..7 assigned)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_27                ; expected epc
        li    a2, 0x35 << 26 | 8        ; expected tval
        call  chkt                      ; check
ill_28: .word 0x3d << 26 | 16 << 21     ; xmap with index 16 (0..15)
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, ill_28                ; expected epc
        li    a2, 0x3d << 26 | 16 << 21 ; expected tval
        call  chkt                      ; check

; ---- causes 2..6, 8, 10 in supervisor mode: precise epc and tval -------------------
        la    s1, buf                   ; s1 = D-LS buffer
        li    s2, 16                    ; s2 = a 16-byte length
        li    s3, 0x7777                ; s3 = a marker that must survive the faults below
lsf:    ld    s3, -8(zero)              ; address 0 - 8 wraps far outside the D-LS
        li    a0, C_LSFAULT             ; expected cause
        la    a1, lsf                   ; expected epc
        li    a2, -8                    ; expected tval: the effective address
        call  chkt                      ; check
        mv    a0, s3                    ; a0 = the load's destination
        li    a1, 0x7777                ; expected: untouched
        call  chk                       ; check
        li    t1, 24                    ; t1 = an offset
cinv:   tget  tg0, s1, c9, t1, s2       ; c9 is empty at reset
        li    a0, C_CAPINV              ; expected cause
        la    a1, cinv                  ; expected epc
        li    a2, 24                    ; expected tval: the offset
        call  chkt                      ; check
        li    t0, 4096                  ; t0 = 4 KiB
        csplit c5, c0, t0               ; c0 = [0, 4096) of T3, c5 = the rest
        cshare c6, c5                   ; c6 = a read-only copyable view (c5 consumed)
        li    t1, 32                    ; t1 = offset
cperm:  tput  tg0, s1, c6, t1, s2       ; writing through a read-only capability
        li    a0, C_PERM                ; expected cause
        la    a1, cperm                 ; expected epc
        li    a2, 32                    ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 4096 - 8              ; t1 = last word of c0
cbnd:   tget  tg0, s1, c0, t1, s2       ; 16 bytes from there run past the end
        li    a0, C_BOUNDS              ; expected cause
        la    a1, cbnd                  ; expected epc
        li    a2, 4096 - 8              ; expected tval: the offset
        call  chkt                      ; check
        li    t1, 8                     ; t1 = an aligned offset
        addi  t2, s1, 4                 ; t2 = a misaligned D-LS address
cxal:   tget  tg0, t2, c0, t1, s2       ; misaligned Local Store address
        li    a0, C_XALIGN              ; expected cause
        la    a1, cxal                  ; expected epc
        li    a2, 8                     ; expected tval: the far offset (not the LS address)
        call  chkt                      ; check
        li    t1, 0x100                 ; t1 = an offset into c0 (which has X)
cxms:   xcall ra, c0, t1                ; no overlay mapping covers it
        li    a0, C_XMISS               ; expected cause
        la    a1, cxms                  ; expected epc
        li    a2, 0x100                 ; expected tval: the far address (c0 base 0 + 0x100)
        call  chkt                      ; check
        li    t1, 8192                  ; t1 = more than c0 holds
ccop:   csplit c7, c0, t1               ; split past the end
        li    a0, C_CAPOP               ; expected cause
        la    a1, ccop                  ; expected epc
        li    a2, 8192                  ; expected tval: the split offset
        call  chkt                      ; check

; ---- banked trap state: the supervisor bank so far --------------------------------
        csrr  a0, cause                 ; supervisor cause of the last trap
        li    a1, C_CAPOP               ; the csplit above
        call  chk                       ; check
        csrr  a0, epc                   ; supervisor epc (the handler moved it past the csplit)
        la    a1, ccop+4                ; the instruction after the csplit
        call  chk                       ; check
        csrr  a0, status                ; after a trap from supervisor mode
        li    a1, 3                     ; spp = supervisor
        call  chk                       ; check
        li    t0, 0x4444                ; t0 = a marker
        csrw  epc, t0                   ; supervisor epc = marker (user mode must not see it)

; ---- user mode, no user handler: everything goes to the supervisor ---------------
        la    a0, user1                 ; a0 = user entry point
        call  to_user                   ; drop to user mode (to_user never returns)
user1:
        csrr  a0, status                ; in user mode: bit 0 clear; bit 1 clear (spp = user)
        li    a1, 0                     ; expected 0
        call  chk                       ; check
        csrr  a0, epc                   ; the user bank's epc, not the supervisor's 0x4444
        li    a1, 0                     ; expected: user bank still at reset
        call  chk                       ; check
        csrr  a0, tvec                  ; the user bank's vector
        li    a1, 0                     ; expected: no user handler
        call  chk                       ; check
        csrr  a0, ucause                ; ucause is readable in user mode
        li    a1, 0                     ; expected 0
        call  chk                       ; check
upr1:   csrw  sscratch, zero            ; writing sscratch: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upr1                  ; expected epc
        li    a2, 0x39 << 26 | 23       ; expected tval: csrw sscratch, zero
        call  chkt                      ; check
upr2:   csrr  a0, sscratch              ; reading sscratch: privileged too
        li    a0, C_PRIV                ; expected cause
        la    a1, upr2                  ; expected epc
        li    a2, 0x38 << 26 | 10 << 21 | 23 ; expected tval: csrr a0, sscratch
        call  chkt                      ; check
upr3:   csrr  a0, ipend                 ; reading ipend: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upr3                  ; expected epc
        li    a2, 0x38 << 26 | 10 << 21 | 24 ; expected tval
        call  chkt                      ; check
upr4:   csrw  status, zero              ; writing status: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upr4                  ; expected epc
        li    a2, 0x39 << 26 | 18       ; expected tval
        call  chkt                      ; check
upr5:   csrw  corebase, zero            ; writing corebase: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upr5                  ; expected epc
        li    a2, 0x39 << 26 | 15       ; expected tval
        call  chkt                      ; check
upr6:   csrw  corecount, zero           ; writing corecount: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upr6                  ; expected epc
        li    a2, 0x39 << 26 | 16       ; expected tval
        call  chkt                      ; check
upr7:   csrw  ucause, zero              ; writing ucause (CSR 19): privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upr7                  ; expected epc
        li    a2, 0x39 << 26 | 19       ; expected tval
        call  chkt                      ; check
upr8:   csrw  utvec, zero               ; writing utvec (CSR 22): privileged (use tvec instead)
        li    a0, C_PRIV                ; expected cause
        la    a1, upr8                  ; expected epc
        li    a2, 0x39 << 26 | 22       ; expected tval
        call  chkt                      ; check
upr9:   csrw  ipend, zero               ; writing ipend (CSR 24): privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upr9                  ; expected epc
        li    a2, 0x39 << 26 | 24       ; expected tval
        call  chkt                      ; check
        li    t0, 5                     ; t0 = sender 5
uin1:   ctake c5                        ; the inbox is the kernel's: ctake (any sender) is privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, uin1                  ; expected epc
        li    a2, 0x34 << 26 | 5 << 21 | 10 ; expected tval: ctake c5
        call  chkt                      ; check
uin2:   ctake c5, t0                    ; ctake from a named sender: privileged too
        li    a0, C_PRIV                ; expected cause
        la    a1, uin2                  ; expected epc
        li    a2, 0x34 << 26 | 5 << 21 | 5 << 11 | 16 | 10 ; expected tval: ctake c5, t0
        call  chkt                      ; check
uin3:   cpoll a0                        ; cpoll: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, uin3                  ; expected epc
        li    a2, 0x34 << 26 | 10 << 21 | 15 ; expected tval
        call  chkt                      ; check
        li    t0, 0x10001               ; t0 = tag 0 | bit 16 (the inbox)
uin4:   tany  a0, t0                    ; waiting on the inbox: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, uin4                  ; expected epc
        li    a2, 0x36 << 26 | 10 << 21 | 5 << 16 ; expected tval: tany a0, t0
        call  chkt                      ; check
        li    t0, 1                     ; t0 = tag 0 only
        tany  a0, t0                    ; tags only: allowed in user mode; tag 0 is idle
        li    a1, 1                     ; expected: tag 0 ready
        call  chk                       ; check
        li    a0, 0                     ; expected no trap
        li    a1, 0                     ; (cause, epc, tval all 0)
        li    a2, 0                     ; nothing recorded
        call  chkt                      ; check
upc1:   csave c2, 3                     ; the save table is the supervisor's
        li    a0, C_PRIV                ; expected cause
        la    a1, upc1                  ; expected epc
        li    a2, 0x34 << 26 | 2 << 16 | 3 << 5 | 12 ; expected tval: csave c2, 3
        call  chkt                      ; check
upc2:   crestore c5, 3                  ; restoring from it: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upc2                  ; expected epc
        li    a2, 0x34 << 26 | 5 << 21 | 3 << 5 | 13 ; expected tval
        call  chkt                      ; check
upc3:   cdom  c5, c6                    ; making a revocation domain: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upc3                  ; expected epc
        li    a2, 0x35 << 26 | 5 << 21 | 6 << 16 ; expected tval
        call  chkt                      ; check
upc4:   crevoke c5, c6                  ; revoking: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upc4                  ; expected epc
        li    a2, 0x35 << 26 | 5 << 21 | 6 << 16 | 1 ; expected tval
        call  chkt                      ; check
upc5:   cundom c5, c6                   ; dissolving a domain: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upc5                  ; expected epc
        li    a2, 0x35 << 26 | 5 << 21 | 6 << 16 | 2 ; expected tval
        call  chkt                      ; check
upc6:   cmkep c5, t0                    ; making an endpoint: privileged
        li    a0, C_PRIV                ; expected cause
        la    a1, upc6                  ; expected epc
        li    a2, 0x35 << 26 | 5 << 21 | 5 << 11 | 5 ; expected tval: cmkep c5, t0
        call  chkt                      ; check
upc7:   csavex c2, t0                   ; the register-indexed forms are the supervisor's too
        li    a0, C_PRIV                ; expected cause
        la    a1, upc7                  ; expected epc
        li    a2, 0x35 << 26 | 2 << 16 | 5 << 11 | 6 ; expected tval: csavex c2, t0
        call  chkt                      ; check
upc8:   crestorex c5, t0                ; ...
        li    a0, C_PRIV                ; expected cause
        la    a1, upc8                  ; expected epc
        li    a2, 0x35 << 26 | 5 << 21 | 5 << 11 | 7 ; expected tval: crestorex c5, t0
        call  chkt                      ; check
        li    t0, 1                     ; t0 = core 1
ugv:    cgive c2, t0                    ; user mode with no core window: nobody to give to
        li    a0, C_CAPOP               ; expected cause
        la    a1, ugv                   ; expected epc
        li    a2, 1                     ; expected tval: the target
        call  chkt                      ; check
usvc:   svc                             ; system call: to the supervisor, cause 14
        li    a0, C_SVC                 ; expected cause
        la    a1, usvc                  ; expected epc: the svc itself
        li    a2, 0                     ; expected tval: 0
        call  chkt                      ; check
uhlt:   halt                            ; halt in user mode: a trap to the supervisor
        li    a0, C_HALT                ; expected cause
        la    a1, uhlt                  ; expected epc
        li    a2, 0                     ; expected tval 0
        call  chkt                      ; check
uill:   .word 0x3f << 26                ; illegal in user mode, no user handler: supervisor
        li    a0, C_ILLEGAL             ; expected cause
        la    a1, uill                  ; expected epc
        li    a2, 0x3f << 26            ; expected tval
        call  chkt                      ; check

; ---- user mode with a user handler -------------------------------------------------
        la    t0, utrap_rec             ; t0 = the user-mode recorder
        csrw  tvec, t0                  ; in user mode tvec names utvec
        csrr  a0, tvec                  ; read it back
        la    a1, utrap_rec             ; expected: the handler
        call  chk                       ; check
uu1:    .word 0x3f << 26                ; illegal: now handled in user mode
        li    a0, C_ILLEGAL             ; expected cause (recorded by utrap_rec from the user bank)
        la    a1, uu1                   ; expected epc
        li    a2, 0x3f << 26            ; expected tval
        call  chkt                      ; check
        li    t1, 0x10000               ; t1 = past the D-LS
uu3:    sd    zero, 0(t1)               ; lsfault, handled in user mode
        li    a0, C_LSFAULT             ; expected cause
        la    a1, uu3                   ; expected epc
        li    a2, 0x10000               ; expected tval
        call  chkt                      ; check
        csrr  a0, cause                 ; user bank cause
        li    a1, C_LSFAULT             ; the last user-handled trap
        call  chk                       ; check
        csrr  a0, epc                   ; user bank epc: the handler set it to uu3 + 4
        la    a1, uu3+4                 ; expected
        call  chk                       ; check
uu4:    svc                             ; svc never goes to the user handler
        li    a0, C_SVC                 ; expected cause (recorded by the supervisor)
        la    a1, uu4                   ; expected epc
        li    a2, 0                     ; expected tval
        call  chkt                      ; check
uu5:    halt                            ; neither does halt
        li    a0, C_HALT                ; expected cause
        la    a1, uu5                   ; expected epc
        li    a2, 0                     ; expected tval
        call  chkt                      ; check
uu6:    csrw  status, zero              ; nor priv
        li    a0, C_PRIV                ; expected cause
        la    a1, uu6                   ; expected epc
        li    a2, 0x39 << 26 | 18       ; expected tval
        call  chkt                      ; check
        csrr  a0, cause                 ; the user bank still holds the lsfault
        li    a1, C_LSFAULT             ; (svc / halt / priv went to the supervisor bank)
        call  chk                       ; check
        la    t0, ueret                 ; t0 = a target
        csrw  epc, t0                   ; user epc = target
        li    a0, 0                     ; a0 = 0 unless eret skips the next instruction
        eret                            ; user eret: jump to uepc, stay in user mode
        li    a0, 99                    ; (skipped)
ueret:
        li    a1, 0                     ; expected: landed on ueret
        call  chk                       ; check
        csrr  a0, status                ; still user mode?
        li    a1, 0                     ; expected: user, spp = user
        call  chk                       ; check
; the user handler's own first instruction faults: that goes to the supervisor
        la    t0, ubad_back             ; where the supervisor continues
        sd    t0, tresume(zero)         ; one-shot resume (also leaves user mode)
        li    t0, 0x10000               ; a user vector outside the I-LS
        csrw  tvec, t0                  ; utvec = 0x10000
uu7:    .word 0x3f << 26                ; illegal: to utvec, whose fetch faults: to the supervisor
        j     done                      ; (not reached)
ubad_back:                              ; supervisor mode again
        li    a0, C_IFAULT              ; expected cause: the fetch at utvec
        li    a1, 0x10000               ; expected epc: utvec
        li    a2, 0x10000               ; expected tval
        call  chkt                      ; check
        csrr  a0, ucause                ; the user bank recorded the illegal instruction
        li    a1, C_ILLEGAL             ; expected
        call  chk                       ; check
        csrr  a0, uepc                  ; its epc
        la    a1, uu7                   ; expected
        call  chk                       ; check
        csrr  a0, utval                 ; its tval
        li    a1, 0x3f << 26            ; expected
        call  chk                       ; check
        csrr  a0, utvec                 ; the supervisor reads utvec directly
        li    a1, 0x10000               ; expected
        call  chk                       ; check
        csrw  utvec, zero               ; and writes it: no user handler
        csrr  a0, status                ; back in supervisor mode (the handler set bit 1)
        li    a1, 3                     ; expected
        call  chk                       ; check
        csrr  a0, cause                 ; the supervisor bank: the ifault
        li    a1, C_IFAULT              ; expected
        call  chk                       ; check

; ---- cause 13, stop: held in supervisor mode, taken in user mode ------------------
        la    t0, one                   ; t0 = a word with bit 0 set
        li    t1, 0                     ; offset 0 = core 0's control word (this core)
        li    t2, 8                     ; one word
        tput  tg1, t0, c4, t1, t2       ; c4: core control (core 0 only); stop core 0
        twait tg1                       ; wait for the put
        csrr  a0, ipend                 ; the request is pending (supervisor mode is not stopped)
        li    a1, 1                     ; expected 1
        call  chk                       ; check
        csrw  ipend, zero               ; the supervisor can cancel it
        csrr  a0, ipend                 ; read back
        li    a1, 0                     ; expected 0
        call  chk                       ; check
        li    t0, 1                     ; or raise it itself
        csrw  ipend, t0                 ; ipend = 1
        la    t0, stop_back             ; where the supervisor continues
        sd    t0, tresume(zero)         ; one-shot resume
        la    a0, user2                 ; a0 = user entry
        call  to_user                   ; enter user mode: the stop is taken at once
user2:
        li    s5, 0x99                  ; (never runs: the stop comes first)
        j     done                      ; (not reached)
stop_back:
        li    a0, C_STOP                ; expected cause
        la    a1, user2                 ; expected epc: the first user instruction, not run
        li    a2, 0                     ; expected tval 0
        call  chkt                      ; check
        csrr  a0, ipend                 ; taking the stop clears the request
        li    a1, 0                     ; expected 0
        call  chk                       ; check
        mv    a0, s5                    ; the first user instruction did not run
        li    a1, 0                     ; expected: s5 still 0
        call  chk                       ; check
        ld    a0, tcount(zero)          ; traps recorded in all
        call  sig                       ; (part of the signature, not self-checked)
        j     done                      ; print the signature and the verdict
