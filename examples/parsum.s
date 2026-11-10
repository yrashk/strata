; =============================================================================
; parsum.s: parallel reduction by splitting a capability, on every core
; =============================================================================
;
; What it shows
;   * Dividing work is dividing ownership. Core 0 `csplit`s the array's
;     capability into one piece per core and `cgive`s each piece away. A core
;     can touch only its own piece, so the cores cannot interfere: no false
;     sharing, no locks, no coherence misses.
;   * Combining results uses far atomics. `catomic` turns an 8-byte segment
;     into an atomic-only capability that can be copied, so every core holds
;     it. `tamo.add` performs the add at the memory itself, indivisibly.
;   * Collecting deterministically. Each worker hands its piece back when it
;     is done. Core 0 takes them back *in core order* with `ctake c5, k`
;     (take only from core k) and `cjoin`s each onto the growing array, so at
;     the end it again owns the whole array through one capability, whatever
;     order the cores actually finished in.
;   * Every core uses the same double-buffered streaming routine (sum_seg),
;     written against "whatever segment is in c4".
;
; Expected output (4 cores):
;   serial   sum = 536854528
;   parallel sum = 536854528 on 4 cores
;   check: ok
;   array rejoined: 262144 bytes
;   @ serial   cycles = ...
;   @ parallel cycles = ...

N       = 32768                         ; array length in words (256 KiB)
ABYTES  = N * 8                         ; array size in bytes
CHUNK   = 1024                          ; words per transfer
CBYTES  = CHUNK * 8                     ; bytes per transfer

        .data                           ; data Local Store (one per core)
        .align 8                        ; transfer buffers must be aligned
bufA:   .space CBYTES                   ; streaming buffer A
bufB:   .space CBYTES                   ; streaming buffer B
m_ser:  .ascii "serial   sum = "        ; output labels
m_ser_e:                                ; end of the text above (its length = end - start)
m_par:  .ascii "parallel sum = "        ; output text
m_par_e:                                ; end of the text above (its length = end - start)
m_on:   .ascii " on "                   ; output text
m_on_e:                                 ; end of the text above
m_cores: .ascii " cores\n"             ; output text
m_cores_e:                              ; end of the text above
m_ok:   .ascii "check: ok\n"            ; output text
m_ok_e:                                 ; end of the text above (its length = end - start)
m_bad:  .ascii "check: MISMATCH\n"      ; output text
m_bad_e:                                ; end of the text above (its length = end - start)
m_rej:  .ascii "array rejoined: "       ; output text
m_rej_e:                                ; end of the text above (its length = end - start)
m_rej2: .ascii " bytes\n"               ; output text
m_rej2_e:                               ; end of the text above (its length = end - start)
m_ts:   .ascii "@ serial   cycles = "   ; output text
m_ts_e:                                 ; end of the text above (its length = end - start)
m_tp:   .ascii "@ parallel cycles = "   ; output text
m_tp_e:                                 ; end of the text above (its length = end - start)

        .text                           ; instruction Local Store
_start:                                 ; entry point: every core starts executing here, at I-LS address 0
        li    sp, 65536                 ; stack at the top of D-LS
        csrr  t0, coreid                ; which core?
        bnez  t0, worker                ; every other core is a helper

; =============================== core 0 =========================================
        li    t0, ABYTES                ; t0 = array size
        csplit c6, c0, t0               ; c0 = the array, c6 = everything after it
        li    t0, 8                     ; t0 = one word
        csplit c7, c6, t0               ; c6 = one word just after the array, c7 = the rest
        catomic c6, c6                  ; c6 becomes the atomic accumulator (copyable, atomics only)

; ---- fill the array with 0, 1, 2, ... ---------------------------------------------
        li    s2, 0                     ; s2 = far offset
        li    s3, 0                     ; s3 = next value
        li    s6, CBYTES                ; s6 = chunk size
        la    s5, bufA                  ; s5 = staging buffer
        li    s4, ABYTES / CBYTES       ; s4 = chunks to write
fill_chunk:                             ; loop: build and send one chunk
        mv    t0, s5                    ; t0 = cursor
        li    t1, CHUNK                 ; t1 = words left in the chunk
fill_word:                              ; loop: one word of the chunk
        sd    s3, 0(t0)                 ; write the value
        addi  s3, s3, 1                 ; next value
        addi  t0, t0, 8                 ; next word
        addi  t1, t1, -1                ; one fewer
        bnez  t1, fill_word             ; until the chunk is full
        tput  tg0, s5, c0, s2, s6       ; send it to T3
        add   s2, s2, s6                ; next offset
        addi  s4, s4, -1                ; one chunk fewer
        bnez  s4, fill_chunk            ; until the array is written

; ---- serial: core 0 sums the whole array ------------------------------------------
        csrr  s10, cycle                ; start time
        cmov  c4, c0                    ; sum_seg works on c4: lend it the whole array
        li    a0, ABYTES                ; a0 = bytes to sum
        call  sum_seg                   ; s1 = sum
        cmov  c0, c4                    ; take the capability back into c0
        csrr  t0, cycle                 ; end time
        sub   s10, t0, s10              ; s10 = serial cycles
        mv    s9, s1                    ; s9 = serial sum

; ---- parallel: one piece per core ------------------------------------------------
        csrr  s11, cycle                ; start time
        csrr  s7, ncores                ; s7 = number of cores
        li    t0, ABYTES / CBYTES       ; t0 = chunks in the array
        divu  s6, t0, s7                ; s6 = chunks per core (the last core takes the remainder)
        li    t0, CBYTES                ; bytes per chunk
        mul   s6, s6, t0                ; s6 = bytes per core
        mv    s1, s6                    ; s1 = size of core 0's piece
        csplit c5, c0, s6               ; c0 = core 0's piece, c5 = everything after it
        li    s3, 1                     ; s3 = next core to hand a piece to
par_give:
        bge   s3, s7, par_mine          ; every other core has its piece
        cgive c6, s3                    ; a copy of the accumulator first (atomic caps are copyable)
        addi  t0, s7, -1                ; t0 = the last core's number
        beq   s3, t0, par_last          ; the last core gets all that remains
        csplit c8, c5, s6               ; c5 = this core's piece, c8 = the rest
        cgive c5, s3                    ; hand it over (c5 becomes empty)
        cmov  c5, c8                    ; the rest moves back into c5
        addi  s3, s3, 1                 ; next core
        j     par_give                  ; continue
par_last:
        cgive c5, s3                    ; the last core takes the remainder
par_mine:
        cmov  c4, c0                    ; our own piece goes into c4 for sum_seg
        clen  a0, c4                    ; a0 = its size
        call  sum_seg                   ; s1 = our partial sum (the other cores run meanwhile)
        tamo.add zero, c6, zero, s1     ; add it into the accumulator, at the memory
        csrr  s7, ncores                ; s7 again (sum_seg clobbers s2..s8)
        li    s3, 1                     ; s3 = next core to collect from
par_take:
        bge   s3, s7, par_done          ; all pieces are back
        ctake c5, s3                    ; take a piece back from core s3 only (its partial sum is in)
        cjoin c4, c5                    ; append it: c4 grows back towards the whole array
        addi  s3, s3, 1                 ; next core
        j     par_take                  ; continue
par_done:
        li    t0, 0                     ; t0 = 0
        tamo.add s8, c6, zero, t0       ; s8 = accumulator (an atomic add of 0 is an atomic read)
        csrr  t0, cycle                 ; end time
        sub   s11, t0, s11              ; s11 = parallel cycles
        cmov  c0, c4                    ; park the whole array in c0 again

; ---- report ------------------------------------------------------------------------------
        la    a0, m_ser                 ; "serial   sum = "
        li    a1, m_ser_e - m_ser       ; length
        mv    a2, s9                    ; serial sum
        call  print_kv                  ; print
        la    a0, m_par                 ; "parallel sum = "
        li    a1, m_par_e - m_par       ; length
        call  print_str                 ; print
        mv    a0, s8                    ; parallel sum
        call  print_dec                 ; print it
        la    a0, m_on                  ; " on "
        li    a1, m_on_e - m_on         ; length
        call  print_str                 ; print
        mv    a0, s7                    ; core count
        call  print_dec                 ; print it
        la    a0, m_cores               ; " cores\n"
        li    a1, m_cores_e - m_cores   ; length
        call  print_str                 ; print
        li    t0, N * (N - 1) / 2       ; t0 = expected sum, 0 + 1 + ... + N-1
        la    a0, m_ok                  ; assume both sums are right
        li    a1, m_ok_e - m_ok         ; length
        bne   s9, t0, bad               ; serial wrong?
        beq   s8, t0, verdict           ; parallel right too: keep "ok"
bad:                                    ; a sum was wrong
        la    a0, m_bad                 ; otherwise "MISMATCH"
        li    a1, m_bad_e - m_bad       ; length
verdict:                                ; a0/a1 hold the verdict text
        call  print_str                 ; print the verdict
        la    a0, m_rej                 ; "array rejoined: "
        li    a1, m_rej_e - m_rej       ; length
        call  print_str                 ; print
        clen  a0, c0                    ; a0 = length of the rejoined capability
        call  print_dec                 ; print it
        la    a0, m_rej2                ; " bytes\n"
        li    a1, m_rej2_e - m_rej2     ; length
        call  print_str                 ; print
        la    a0, m_ts                  ; "@ serial   cycles = "
        li    a1, m_ts_e - m_ts         ; length
        call  print_str                 ; print
        mv    a0, s10                   ; serial cycles
        call  print_dec10               ; fixed-width, keeps traces comparable
        call  print_nl                  ; newline
        la    a0, m_tp                  ; "@ parallel cycles = "
        li    a1, m_tp_e - m_tp         ; length
        call  print_str                 ; print
        mv    a0, s11                   ; parallel cycles
        call  print_dec10               ; fixed width
        call  print_nl                  ; newline
        li    a0, 0                     ; exit code
        halt                            ; stop

; =============================== other cores =====================================
worker:
        ctake c6                        ; receive the accumulator (core 0 sends it first)
        ctake c4                        ; receive our piece of the array
        clen  a0, c4                    ; a0 = its size
        call  sum_seg                   ; s1 = sum of our piece
        tamo.add zero, c6, zero, s1     ; add it into the accumulator
        li    t0, 0                     ; t0 = core 0
        cgive c4, t0                    ; return our piece: this is also the "done" signal
        li    a0, 0                     ; exit code
        halt                            ; stop

; -----------------------------------------------------------------------------
; sum_seg(a0 = bytes, a non-zero multiple of CBYTES) -> s1 = sum of the 64-bit words of
; the segment in c4, streamed through two D-LS buffers. Clobbers s2..s8, t*.
; -----------------------------------------------------------------------------
sum_seg:                                ; routine entry
        addi  sp, sp, -8                ; room for the return address
        sd    ra, 0(sp)                 ; save it
        li    s6, CBYTES                ; s6 = chunk size
        li    t0, CBYTES                ; t0 = chunk size, for the division
        divu  s4, a0, t0                ; s4 = chunks to sum
        li    s1, 0                     ; s1 = sum
        li    s2, 0                     ; s2 = far offset of the next chunk to fetch
        la    s7, bufA                  ; s7 = buffer to compute on
        la    s8, bufB                  ; s8 = buffer to fill next
        tget  tg0, s7, c4, s2, s6       ; prime: chunk 0
        add   s2, s2, s6                ; advance
ss_loop:                                ; loop: one chunk per iteration
        addi  s4, s4, -1                ; consuming one chunk
        beqz  s4, ss_sum                ; last chunk: nothing to prefetch
        tget  tg1, s8, c4, s2, s6       ; prefetch the next chunk into the other buffer
        add   s2, s2, s6                ; advance
ss_sum:                                 ; sum the current chunk
        mv    t5, s7                    ; t5 = cursor
        li    t0, CHUNK / 4             ; t0 = groups of four words
ss_word:                                ; loop: four words per iteration
        ld    t1, 0(t5)                 ; four loads (stall only if the data is still in flight)
        ld    t2, 8(t5)                 ; word 1
        ld    t3, 16(t5)                ; word 2
        ld    t4, 24(t5)                ; word 3
        add   s1, s1, t1                ; four adds
        add   s1, s1, t2                ; accumulate word 1
        add   s1, s1, t3                ; accumulate word 2
        add   s1, s1, t4                ; accumulate word 3
        addi  t5, t5, 32                ; next group
        addi  t0, t0, -1                ; one group fewer
        bnez  t0, ss_word               ; until the chunk is summed
        mv    t0, s7                    ; swap the buffers
        mv    s7, s8                    ; the prefetched buffer becomes the compute buffer
        mv    s8, t0                    ; the one just summed will be refilled
        bnez  s4, ss_loop               ; until every chunk is summed
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; release the stack slot
        ret                             ; done

        .include "lib/print.s"          ; console helpers
