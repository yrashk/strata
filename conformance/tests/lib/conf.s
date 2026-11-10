; =============================================================================
; conformance/tests/lib/conf.s: the harness every conformance test includes
; =============================================================================
;
; A test is a bare-metal program. It `.include`s this file FIRST (before any
; code or data of its own), so that:
;   * the harness's variables sit at fixed low D-LS addresses, reachable
;     with `ld rd, name(zero)` from anywhere, including trap handlers;
;   * `_start` (I-LS address 0, where every core begins) is the harness's:
;     it sets a stack, installs the recording trap handler and jumps to the
;     test's `main` on every core.
;
; The test then records results:
;   sig   (a0 = value)                    append a value to the SIGNATURE
;   chk   (a0 = got, a1 = expected)       append `got`; count a failure if it
;                                         differs from `expected`
;   chkt  (a0 = cause, a1 = epc, a2 = tval)  check the last trap recorded by
;                                         the handler (all zero: "no trap"),
;                                         then forget it
;   done                                  print the signature and the verdict,
;                                         then halt (core 0 only)
;
; Output (console), one line per entry, then the verdict:
;   sig 0123456789abcdef                  every signature entry, in order
;   bad <index> / got <v> / exp <v>       one triple per failed check (first 32)
;   pass | fail                           the verdict
; The runner (conformance/run.sh) requires "pass" and identical "sig" lines on
; every machine. Signatures must not hold timing-visible values (cycle
; counts, NOW, tpoll results that depend on latency).
;
; Register use: sig/chk clobber only t5, t6 (and ra, by the call); chkt
; clobbers t5, t6. done clobbers everything. Tests must not keep values in
; t5/t6 across these calls. The stack pointer starts at 0xc000 (D-LS above
; it is free for tests that probe the top of the Local Store).
;
; Trap handler (supervisor: tvec = trap_rec; user: utvec = utrap_rec):
; records cause, epc and tval into tcause/tepc/ttval, counts the trap in
; tcount, and resumes at epc + 4, the instruction after the trapping one.
; Two ways to resume elsewhere, both only in the supervisor handler:
;   * tresume != 0: resume at that address in SUPERVISOR mode (one-shot; it
;     is cleared). Used when epc + 4 is no good (instruction fetch faults) or
;     to get out of user mode after an expected trap.
;   * `svc` with a7 = UEXIT from user mode: not recorded; resume at the
;     address in `uexit` in supervisor mode. This is how user-mode code
;     returns to the test (tresume is left alone).

; ---- cause numbers (common/stx.h, emu/emu.c) -----------------------------
C_ILLEGAL = 1                           ; undefined or malformed instruction
C_LSFAULT = 2                           ; Local Store address out of range or misaligned
C_CAPINV  = 3                           ; capability not valid (empty, revoked)
C_PERM    = 4                           ; capability lacks the permission
C_BOUNDS  = 5                           ; offset/length outside the capability
C_XALIGN  = 6                           ; memory transfer not 8-byte aligned
C_IFAULT  = 7                           ; instruction fetch outside the I-LS / misaligned
C_XMISS   = 8                           ; xcall/xret to a far address with no mapping
C_PEND    = 9                           ; (CCR.PTRAP) pending-transfer trap
C_CAPOP   = 10                          ; capability operation not allowed
C_PRIV    = 11                          ; supervisor-only operation in user mode
C_HALT    = 12                          ; halt in user mode
C_STOP    = 13                          ; core-control stop taken in user mode
C_SVC     = 14                          ; svc in user mode
UEXIT     = 0x5ec                       ; a7 value: `svc` that leaves user mode

; ---- capability permission bits and spaces (cperms = space << 8 | perms) ----
P_R = 1                                 ; read (tget)
P_W = 2                                 ; write (tput); a capability without D and with W is linear
P_X = 4                                 ; execute (tgetx, xmap, xcall)
P_A = 8                                 ; atomic (tamo)
P_D = 16                                ; duplicable: copies allowed, may be overwritten
P_V = 32                                ; revoker of a revocation domain
SP_T2 = 2                               ; cluster store
SP_T3 = 3                               ; system memory
SP_DEV = 4                              ; device space
SP_CORE = 5                             ; core control
SP_EP = 6                               ; endpoint

        .data                           ; harness variables: the first bytes of D-LS
sigptr: .dword sigbuf                   ; next free signature slot
nfail:  .dword 0                        ; failed checks so far
tcause: .dword 0                        ; cause of the last recorded trap (0: none)
tepc:   .dword 0                        ; its epc
ttval:  .dword 0                        ; its tval
tcount: .dword 0                        ; traps recorded since start
tresume: .dword 0                       ; one-shot: resume address (supervisor) for the next trap
uexit:  .dword 0                        ; where `li a7, UEXIT; svc` continues (supervisor)
hsave:  .dword 0, 0                     ; the handler's save area for t5, t6
line:   .ascii "sig 0123456789abcdef\n" ; output line: 4-character prefix, 16 hex digits, newline
        .align 8                        ; keep what follows 8-byte aligned
hexdig: .ascii "0123456789abcdef"       ; hex digit table (16 bytes: the prefixes below stay 4-byte aligned)
p_sig:  .ascii "sig "                   ; line prefix: a signature entry
p_bad:  .ascii "bad "                   ; line prefix: index of a failed check
p_got:  .ascii "got "                   ; line prefix: the value it produced
p_exp:  .ascii "exp "                   ; line prefix: the value it should have produced
passm:  .ascii "pass\n"                 ; verdict: every check passed
failm:  .ascii "fail\n"                 ; verdict: some check failed
        .align 8                        ; tables below hold dwords
fails:  .space 24 * 32                  ; (index, got, expected) of the first 32 failures
dbuf:   .dword 0                        ; devrd / devwr transfer buffer
sigbuf: .space 8 * 1024                 ; the signature: up to 1024 entries
sigend:                                 ; one past the signature buffer
        .align 8                        ; the test's own data starts aligned

        .text                           ; I-LS address 0: every core starts here
_start:
        li    sp, 0xc000                ; stack below the top 16 KiB of the D-LS
        la    t0, trap_rec              ; t0 = the recording trap handler
        csrw  tvec, t0                  ; install it (supervisor trap vector)
        j     main                      ; the test's own entry point (all cores)

; -----------------------------------------------------------------------------
; park: a core with nothing to do halts (a0 = 0)
; -----------------------------------------------------------------------------
park:
        li    a0, 0                     ; exit code 0
        halt                            ; stop this core

; -----------------------------------------------------------------------------
; sig(a0): append a0 to the signature. Clobbers t6.
; -----------------------------------------------------------------------------
sig:
        ld    t6, sigptr(zero)          ; t6 = next free slot
        sd    a0, 0(t6)                 ; store the value
        addi  t6, t6, 8                 ; advance
        sd    t6, sigptr(zero)          ; remember the new end
        ret                             ; back to the test

; -----------------------------------------------------------------------------
; chk(a0 = got, a1 = expected): append a0; on a mismatch count a failure and
; record (index, got, expected). Clobbers t5, t6.
; -----------------------------------------------------------------------------
chk:
        ld    t6, sigptr(zero)          ; t6 = next free slot
        sd    a0, 0(t6)                 ; the signature holds what we got
        addi  t6, t6, 8                 ; advance
        sd    t6, sigptr(zero)          ; remember the new end
        beq   a0, a1, chk_ok            ; as expected: nothing more to do
        ld    t5, nfail(zero)           ; t5 = failures so far (= this one's number)
        addi  t6, t5, 1                 ; one more
        sd    t6, nfail(zero)           ; store the count
        sltiu t6, t5, 32                ; room in the failure table?
        beqz  t6, chk_ok                ; no: only counted
        slli  t6, t5, 4                 ; t6 = 16 * n
        slli  t5, t5, 3                 ; t5 = 8 * n
        add   t5, t5, t6                ; t5 = 24 * n = this failure's table offset
        ld    t6, sigptr(zero)          ; t6 = one past the entry just written
        addi  t6, t6, -8                ; t6 = address of that entry
        addi  t6, t6, -sigbuf           ; t6 = its byte offset in the signature
        srli  t6, t6, 3                 ; t6 = its index
        sd    t6, fails(t5)             ; record the index
        sd    a0, fails+8(t5)           ; record what we got
        sd    a1, fails+16(t5)          ; record what was expected
chk_ok:
        ret                             ; back to the test

; -----------------------------------------------------------------------------
; chkt(a0 = cause, a1 = epc, a2 = tval): check the last recorded trap (pass
; zeros to check that none happened since the last chkt), then forget it.
; Clobbers t5, t6.
; -----------------------------------------------------------------------------
chkt:
        addi  sp, sp, -32               ; room for ra and the three arguments
        sd    ra, 0(sp)                 ; save the return address (we call chk)
        sd    a0, 8(sp)                 ; save the expected cause
        sd    a1, 16(sp)                ; save the expected epc
        sd    a2, 24(sp)                ; save the expected tval
        mv    a1, a0                    ; a1 = expected cause
        ld    a0, tcause(zero)          ; a0 = recorded cause
        call  chk                       ; check it
        ld    a1, 16(sp)                ; a1 = expected epc
        ld    a0, tepc(zero)            ; a0 = recorded epc
        call  chk                       ; check it
        ld    a1, 24(sp)                ; a1 = expected tval
        ld    a0, ttval(zero)           ; a0 = recorded tval
        call  chk                       ; check it
        sd    zero, tcause(zero)        ; forget the trap
        sd    zero, tepc(zero)          ; (all three fields)
        sd    zero, ttval(zero)         ; so the next chkt sees only new traps
        ld    a0, 8(sp)                 ; restore the arguments
        ld    a1, 16(sp)                ; (callers may reuse them)
        ld    a2, 24(sp)                ; restore a2
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 32                ; release the frame
        ret                             ; back to the test

; -----------------------------------------------------------------------------
; trap_rec: the supervisor trap handler (tvec). See the header for resuming.
; -----------------------------------------------------------------------------
trap_rec:
        sd    t5, hsave(zero)           ; save t5 (the first instruction must not fault)
        sd    t6, hsave+8(zero)         ; save t6
        csrr  t5, cause                 ; t5 = cause (supervisor bank)
        addi  t6, t5, -C_SVC            ; zero if it was an svc
        bnez  t6, tr_rec                ; not an svc: record it
        li    t6, UEXIT                 ; t6 = the "leave user mode" request code
        bne   a7, t6, tr_rec            ; an ordinary svc: record it
        ld    t6, uexit(zero)           ; t6 = where the test continues
        j     tr_go                     ; resume there, in supervisor mode, unrecorded
tr_rec:
        sd    t5, tcause(zero)          ; record the cause
        csrr  t5, epc                   ; t5 = address of the trapping instruction
        sd    t5, tepc(zero)            ; record it
        csrr  t5, tval                  ; t5 = trap value
        sd    t5, ttval(zero)           ; record it
        ld    t5, tcount(zero)          ; count the trap
        addi  t5, t5, 1                 ; one more
        sd    t5, tcount(zero)          ; store the count
        ld    t6, tresume(zero)         ; a resume address set by the test?
        bnez  t6, tr_sup                ; yes: go there
        csrr  t6, epc                   ; no: t6 = the trapping instruction
        addi  t6, t6, 4                 ; t6 = the instruction after it
        csrw  epc, t6                   ; return there (in the mode the trap came from)
        ld    t5, hsave(zero)           ; restore t5
        ld    t6, hsave+8(zero)         ; restore t6
        eret                            ; back to the interrupted code
tr_sup:
        sd    zero, tresume(zero)       ; the resume address is one-shot
tr_go:
        csrw  epc, t6                   ; return to it
        li    t6, 2                     ; status bit 1 = "eret returns to supervisor"
        csrw  status, t6                ; whatever mode the trap came from
        ld    t5, hsave(zero)           ; restore t5
        ld    t6, hsave+8(zero)         ; restore t6
        eret                            ; continue the test in supervisor mode

; -----------------------------------------------------------------------------
; utrap_rec: a user-mode trap handler (utvec): record, skip the instruction.
; In user mode cause/epc/tval read the user bank (ucause/uepc/utval).
; -----------------------------------------------------------------------------
utrap_rec:
        sd    t5, hsave(zero)           ; save t5
        sd    t6, hsave+8(zero)         ; save t6
        csrr  t5, cause                 ; t5 = cause (user bank)
        sd    t5, tcause(zero)          ; record it
        csrr  t5, epc                   ; t5 = trapping instruction (user bank)
        sd    t5, tepc(zero)            ; record it
        csrr  t5, tval                  ; t5 = trap value (user bank)
        sd    t5, ttval(zero)           ; record it
        ld    t5, tcount(zero)          ; count the trap
        addi  t5, t5, 1                 ; one more
        sd    t5, tcount(zero)          ; store it
        csrr  t6, epc                   ; t6 = trapping instruction
        addi  t6, t6, 4                 ; the next one
        csrw  epc, t6                   ; user eret goes to uepc
        ld    t5, hsave(zero)           ; restore t5
        ld    t6, hsave+8(zero)         ; restore t6
        eret                            ; user-mode eret: jump to uepc, stay in user mode

; -----------------------------------------------------------------------------
; to_user(a0 = entry): continue at `entry` in user mode. The user code comes
; back with `li a7, UEXIT; svc`, which resumes at `uexit` (set it first).
; -----------------------------------------------------------------------------
to_user:
        csrw  status, zero              ; status bit 1 clear: eret enters user mode
        csrw  epc, a0                   ; eret goes to the entry point
        eret                            ; drop to user mode

; -----------------------------------------------------------------------------
; devrd(a0 = device port) -> a0: an 8-byte read of a device register through
; c3 (core 0's device-space capability), tag 14. The load waits for the data.
; devwr(a0 = device port, a1 = value): an 8-byte write, waited for.
; Both clobber t0, t1.
; -----------------------------------------------------------------------------
devrd:
        la    t0, dbuf                  ; t0 = the transfer buffer
        li    t1, 8                     ; 8 bytes: one register
        tget  tg14, t0, c3, a0, t1      ; read the register (one byte per beat, ports a0..a0+7)
        ld    a0, 0(t0)                 ; the load waits until the bytes are there
        ret                             ; back to the caller
devwr:
        la    t0, dbuf                  ; t0 = the transfer buffer
        sd    a1, 0(t0)                 ; the value
        li    t1, 8                     ; 8 bytes
        tput  tg14, t0, c3, a0, t1      ; write the register
        twait tg14                      ; wait until it is done
        ret                             ; back to the caller

; -----------------------------------------------------------------------------
; done: print the signature and the verdict, halt with a0 = failures.
; -----------------------------------------------------------------------------
done:
        la    s0, sigbuf                ; s0 = first signature entry
        ld    s1, sigptr(zero)          ; s1 = one past the last
dn_sig:
        bgeu  s0, s1, dn_verdict        ; all printed?
        ld    a0, 0(s0)                 ; a0 = the entry
        la    a1, p_sig                 ; prefix "sig "
        call  prline                    ; print the line
        addi  s0, s0, 8                 ; next entry
        j     dn_sig                    ; loop
dn_verdict:
        ld    s2, nfail(zero)           ; s2 = failures
        beqz  s2, dn_pass               ; none: pass
        li    s3, 32                    ; at most 32 recorded
        bltu  s2, s3, dn_few            ; fewer than that?
        mv    s2, s3                    ; no: print the first 32
dn_few:
        la    s0, fails                 ; s0 = first failure record
dn_fail:
        ld    a0, 0(s0)                 ; a0 = index of the failed entry
        la    a1, p_bad                 ; prefix "bad "
        call  prline                    ; print it
        ld    a0, 8(s0)                 ; a0 = what it produced
        la    a1, p_got                 ; prefix "got "
        call  prline                    ; print it
        ld    a0, 16(s0)                ; a0 = what was expected
        la    a1, p_exp                 ; prefix "exp "
        call  prline                    ; print it
        addi  s0, s0, 24                ; next record
        addi  s2, s2, -1                ; one fewer to print
        bnez  s2, dn_fail               ; loop
        la    a0, failm                 ; "fail\n"
        j     dn_out                    ; print the verdict
dn_pass:
        la    a0, passm                 ; "pass\n"
dn_out:
        li    a1, 5                     ; both verdicts are 5 bytes
        tput  tg15, a0, c2, zero, a1    ; print it (c2: the console)
        ld    a0, nfail(zero)           ; exit code = number of failures
        halt                            ; stop (halt drains the output first)

; -----------------------------------------------------------------------------
; prline(a0 = value, a1 = address of a 4-character prefix): print
; "<prefix><16 hex digits>\n". Clobbers t0..t3.
; -----------------------------------------------------------------------------
prline:
        lwu   t0, 0(a1)                 ; t0 = the four prefix bytes
        sw    t0, line(zero)            ; put them at the start of the line
        la    t0, line+20               ; t0 = cursor, one past the last digit
        li    t1, 16                    ; t1 = digits to produce
pl_loop:
        andi  t2, a0, 15                ; t2 = lowest nibble
        lbu   t2, hexdig(t2)            ; t2 = its hex character
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store the digit
        srli  a0, a0, 4                 ; next nibble
        addi  t1, t1, -1                ; one fewer
        bnez  t1, pl_loop               ; until all 16 are done
        la    t0, line                  ; t0 = the line
        li    t1, 21                    ; 4 + 16 + 1 bytes
        tput  tg15, t0, c2, zero, t1    ; print it (a later store to `line` waits for this)
        ret                             ; back to done
