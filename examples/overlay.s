; =============================================================================
; overlay.s: running code that lives in system memory, loaded on demand
; =============================================================================
;
; What it shows
;   * Instructions also come only from a Local Store (the I-LS). Code kept in
;     system memory must be copied in with `tgetx` before it can run.
;   * `xcall rd, cN, ro` is the hardware assist that makes this cheap. It
;     looks up far address cN.base + ro in an 8-entry overlay map. On a hit
;     it is an ordinary call to the mapped I-LS address. On a miss it traps
;     with cause `xmiss` and tval = that far address. Software decides where
;     to load the code (`tgetx`), records the mapping (`xmap`) and returns
;     with `eret`, which re-executes the `xcall`; now it hits. Nothing has to
;     wait for the code to arrive: fetching from an I-LS range that a `tgetx`
;     is still filling stalls, exactly like loading from a D-LS range that a
;     `tget` is still filling. A `tgetx` also forgets any overlay mapping that
;     pointed into the range it overwrites.
;   * The policy is in software. Here it's two 64-byte I-LS slots with
;     round-robin replacement, but nothing in the hardware forces that.
;   * Far code must be position-independent. Strata branches and `jal` are
;     PC-relative, so code assembled at one address runs anywhere.
;
; Expected output:
;   result         = 150
;   calls          = 12
;   overlay misses = 3

SLOT0   = 0x7000                        ; I-LS address of overlay slot 0
SLOT1   = 0x7040                        ; I-LS address of overlay slot 1
SLOTSZ  = 64                            ; bytes per slot (16 instructions)

        .data                           ; data Local Store
        .align 8                        ; keep the words below aligned
hsave:  .space 32                       ; trap handler register save area (t0..t3)
nslot:  .dword 0                        ; next slot to replace (0 or 1)
misses: .dword 0                        ; overlay misses served by the handler
m_res:  .ascii "result         = "      ; output labels
m_res_e:                                ; end of the text above (its length = end - start)
m_cal:  .ascii "calls          = "      ; output text
m_cal_e:                                ; end of the text above (its length = end - start)
m_mis:  .ascii "overlay misses = "      ; output text
m_mis_e:                                ; end of the text above (its length = end - start)

        .text                           ; instruction Local Store
_start:                                 ; entry point: every core starts executing here, at I-LS address 0
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; core 0 only
        li    sp, 65536                 ; stack at the top of D-LS
        la    t0, handler               ; t0 = address of our trap handler
        csrw  tvec, t0                  ; install it: traps now jump there instead of stopping the core

        li    s2, 0                     ; s2 = accumulated result
        li    s3, 0                     ; s3 = number of far calls made

; ---- loop A: square(i) + cube(i) for i = 1..4 --------------------------------
        li    s1, 1                     ; s1 = i
loop_a:                                 ; loop over i for square and cube
        mv    a0, s1                    ; argument i
        la    a7, f_square              ; a7 = far offset of square() in T3
        xcall ra, c0, a7                ; call it (the first time: miss, load, retry)
        add   s2, s2, a0                ; add i^2
        mv    a0, s1                    ; argument i
        la    a7, f_cube                ; a7 = far offset of cube()
        xcall ra, c0, a7                ; call it
        add   s2, s2, a0                ; add i^3
        addi  s3, s3, 2                 ; two calls made
        addi  s1, s1, 1                 ; next i
        li    t0, 5                     ; loop bound
        blt   s1, t0, loop_a            ; while i < 5

; ---- loop B: sum_to(i) for i = 1..4 (evicts one of the two above) --------------
        li    s1, 1                     ; s1 = i
loop_b:                                 ; loop over i for sum_to
        mv    a0, s1                    ; argument i
        la    a7, f_sumto               ; a7 = far offset of sum_to()
        xcall ra, c0, a7                ; call it
        add   s2, s2, a0                ; add 1 + 2 + ... + i
        addi  s3, s3, 1                 ; one call made
        addi  s1, s1, 1                 ; next i
        li    t0, 5                     ; loop bound
        blt   s1, t0, loop_b            ; while i < 5

; ---- report -------------------------------------------------------------------
        la    a0, m_res                 ; "result         = "
        li    a1, m_res_e - m_res       ; label length
        mv    a2, s2                    ; the result
        call  print_kv                  ; print
        la    a0, m_cal                 ; "calls          = "
        li    a1, m_cal_e - m_cal       ; label length
        mv    a2, s3                    ; call count
        call  print_kv                  ; print
        la    a0, m_mis                 ; "overlay misses = "
        li    a1, m_mis_e - m_mis       ; label length
        ld    a2, misses(zero)          ; miss count kept by the handler
        call  print_kv                  ; print
park:                                   ; cores with nothing to do end up here
        li    a0, 0                     ; exit code
        halt                            ; stop

; -----------------------------------------------------------------------------
; Trap handler. Serves overlay misses; any other trap stops the core with
; exit code 100 + cause. Must preserve every register the program uses, so it
; saves the four temporaries it needs into hsave (addressed from x0: no free
; register is needed to find the save area).
; -----------------------------------------------------------------------------
handler:                                ; trap handler: tvec points here
        sd    t0, hsave+0(zero)         ; save t0
        sd    t1, hsave+8(zero)         ; save t1
        sd    t2, hsave+16(zero)        ; save t2
        sd    t3, hsave+24(zero)        ; save t3
        csrr  t0, cause                 ; t0 = why we trapped
        li    t1, 8                     ; 8 = xmiss
        bne   t0, t1, fatal             ; anything else is a bug in this program
        csrr  t0, tval                  ; t0 = far address of the code
        cbase t1, c0                    ; t1 = where our memory capability starts
        sub   t0, t0, t1                ; t0 = the code's offset within c0
        li    t3, SLOTSZ                ; t3 = bytes to load
        ld    t1, nslot(zero)           ; t1 = slot to replace
        xori  t2, t1, 1                 ; t2 = the other slot
        sd    t2, nslot(zero)           ; next time, replace the other one (round robin)
        bnez  t1, use_slot1             ; pick the code path for this slot (xmap's index is an immediate)
        li    t2, SLOT0                 ; t2 = I-LS address of slot 0
        tgetx tg2, t2, c0, t0, t3       ; copy the code from T3 into the instruction LS
        xmap  0, t2, c0, t0             ; map entry 0: far address -> slot 0 (replacing what was there)
        j     loaded                    ; continue
use_slot1:                              ; load into slot 1
        li    t2, SLOT1                 ; t2 = I-LS address of slot 1
        tgetx tg2, t2, c0, t0, t3       ; copy the code into slot 1
        xmap  1, t2, c0, t0             ; map entry 1: far address -> slot 1
loaded:                                 ; the code is on its way; fetching it stalls until it lands
        ld    t1, misses(zero)          ; t1 = miss counter
        addi  t1, t1, 1                 ; count this miss
        sd    t1, misses(zero)          ; store it back
        ld    t0, hsave+0(zero)         ; restore t0
        ld    t1, hsave+8(zero)         ; restore t1
        ld    t2, hsave+16(zero)        ; restore t2
        ld    t3, hsave+24(zero)        ; restore t3
        eret                            ; return to the xcall, which now hits
fatal:                                  ; unexpected trap
        addi  a0, t0, 100               ; exit code 100 + cause
        halt                            ; stop the core

; =============================================================================
; Far code: assembled into system memory (T3), never present in the I-LS at
; start-up. Labels here are offsets within T3. Each routine fits in a slot.
; =============================================================================
        .far                            ; switch to the system-memory section
        .align 64                       ; each routine starts on a slot boundary
f_square:                               ; a0 = a0 * a0
        mul   a0, a0, a0                ; square the argument
        ret                             ; return through ra (set by xcall)

        .align 64                       ; next slot-sized routine
f_cube:                                 ; a0 = a0^3
        mul   t0, a0, a0                ; t0 = a0^2
        mul   a0, t0, a0                ; a0 = a0^3
        ret                             ; return

        .align 64                       ; next routine
f_sumto:                                ; a0 = 1 + 2 + ... + a0, with a loop
        mv    t0, a0                    ; t0 = counter, from n down to 1
        li    a0, 0                     ; a0 = sum
st_loop:                                ; loop: add the counter, count down
        add   a0, a0, t0                ; add the counter
        addi  t0, t0, -1                ; count down
        bnez  t0, st_loop               ; PC-relative branch: works wherever the code is loaded
        ret                             ; return

        .text                           ; back to the instruction LS for the library
        .include "lib/print.s"          ; console helpers
