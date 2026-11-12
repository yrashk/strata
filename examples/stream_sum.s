; =============================================================================
; stream_sum.s: summing an array that lives in system memory (T3)
; =============================================================================
;
; What it shows
;   * A load can't reach system memory. To compute on far data, the program
;     first moves it into the data Local Store with `tget`.
;   * You never *have* to wait for a transfer. Version 1 issues a `tget` and
;     immediately starts loading from the buffer. Each load that touches a
;     byte still in flight simply stalls until the byte arrives. That is
;     correct by construction, but compute and transfer don't overlap.
;   * Double buffering is a pure performance choice. Version 2 asks for chunk
;     k+1 before summing chunk k, so the Transfer Unit fills one buffer while
;     the core reads the other. It is the same program semantically and
;     returns the same answer, just faster.
;
; Lines starting with '@' carry timing. They differ between the emulator
; (which has no timing) and the RTL, and the comparison script ignores them.
;
; Expected output:
;   plain  sum = 134209536
;   double sum = 134209536
;   @ plain  cycles = ...
;   @ double cycles = ...

N       = 16384                         ; array length in 64-bit words (128 KiB)
CHUNK   = 1024                          ; words per transfer
CBYTES  = CHUNK * 8                     ; bytes per transfer (8 KiB)
NCHUNK  = N / CHUNK                     ; number of chunks (16)

        .data                           ; data Local Store
        .align 8                        ; transfers need 8-byte aligned LS addresses
bufA:   .space CBYTES                   ; first chunk buffer
bufB:   .space CBYTES                   ; second chunk buffer
m_pl:   .ascii "plain  sum = "          ; label for the plain result
m_pl_e:                                 ; end of the text above (its length = end - start)
m_db:   .ascii "double sum = "          ; label for the double-buffered result
m_db_e:                                 ; end of the text above (its length = end - start)
m_tp:   .ascii "@ plain  cycles = "     ; timing label, plain
m_tp_e:                                 ; end of the text above (its length = end - start)
m_td:   .ascii "@ double cycles = "     ; timing label, double-buffered
m_td_e:                                 ; end of the text above (its length = end - start)

        .text                           ; instruction Local Store, entry at 0
_start:                                 ; entry point: every core starts executing here, at I-LS address 0
        csrr  t0, coreid                ; t0 = core number
        bnez  t0, park                  ; this example runs on core 0 only

; ---- fill the far array with 0, 1, 2, ... N-1 --------------------------------
        li    s2, 0                     ; s2 = far byte offset of the current chunk
        li    s3, 0                     ; s3 = next value to write
        li    s6, CBYTES                ; s6 = chunk length in bytes (a transfer operand)
        la    s5, bufA                  ; s5 = staging buffer in D-LS
        li    s4, NCHUNK                ; s4 = chunks left to write
fill_chunk:                             ; loop: build and send one chunk
        mv    t0, s5                    ; t0 = write cursor in the staging buffer
        li    t1, CHUNK                 ; t1 = words left in this chunk
fill_word:                              ; loop: one word of the chunk
        sd    s3, 0(t0)                 ; store the value (stalls while the previous tput still reads it)
        addi  s3, s3, 1                 ; next value
        addi  t0, t0, 8                 ; next word
        addi  t1, t1, -1                ; one word fewer
        bnez  t1, fill_word             ; until the chunk is full
        tput  tg0, s5, c0, s2, s6       ; copy the chunk to T3 at offset s2 through root capability c0
        add   s2, s2, s6                ; advance the far offset
        addi  s4, s4, -1                ; one chunk fewer
        bnez  s4, fill_chunk            ; until the whole array is written

; ---- version 1: plain, transfer then compute --------------------------------
        csrr  s10, cycle                ; s10 = start time
        li    s1, 0                     ; s1 = running sum
        li    s2, 0                     ; s2 = far offset
        li    s4, NCHUNK                ; s4 = chunks left
plain_loop:                             ; loop: one chunk, fetched then summed
        tget  tg0, s5, c0, s2, s6       ; request chunk into bufA (logically complete now)
        mv    a0, s5                    ; a0 = buffer to sum
        call  sum_chunk                 ; its first load stalls until the data is there
        add   s2, s2, s6                ; next chunk offset
        addi  s4, s4, -1                ; one chunk fewer
        bnez  s4, plain_loop            ; until done
        csrr  s11, cycle                ; s11 = end time
        sub   s11, s11, s10             ; s11 = elapsed cycles, plain
        mv    s9, s1                    ; s9 = plain sum, kept for printing

; ---- version 2: double buffered -----------------------------------------------
        csrr  s10, cycle                ; s10 = start time
        li    s1, 0                     ; s1 = running sum
        li    s2, 0                     ; s2 = far offset
        la    s7, bufA                  ; s7 = buffer to compute on
        la    s8, bufB                  ; s8 = buffer to fill next
        tget  tg0, s7, c0, s2, s6       ; prime: chunk 0 into the compute buffer
        add   s2, s2, s6                ; next offset
        li    s4, NCHUNK                ; s4 = chunks left to sum
dbl_loop:                               ; loop: one chunk, with the next one prefetched
        addi  s4, s4, -1                ; this iteration consumes one chunk
        beqz  s4, dbl_sum               ; on the last chunk there is nothing left to prefetch
        tget  tg1, s8, c0, s2, s6       ; prefetch the next chunk into the other buffer
        add   s2, s2, s6                ; advance the far offset
dbl_sum:                                ; sum the current chunk
        mv    a0, s7                    ; a0 = compute buffer
        call  sum_chunk                 ; sum it while the prefetch runs
        mv    t0, s7                    ; swap the roles of the two buffers:
        mv    s7, s8                    ;   the prefetched buffer becomes the compute buffer
        mv    s8, t0                    ;   and the one just summed will be refilled
        bnez  s4, dbl_loop              ; until every chunk is summed
        csrr  t0, cycle                 ; t0 = end time
        sub   s10, t0, s10              ; s10 = elapsed cycles, double-buffered

; ---- report ------------------------------------------------------------------
        la    a0, m_pl                  ; "plain  sum = "
        li    a1, m_pl_e - m_pl         ; its length
        call  print_str                 ; print the label
        mv    a0, s9                    ; the plain sum
        call  print_dec                 ; print it
        call  print_nl                  ; newline
        la    a0, m_db                  ; "double sum = "
        li    a1, m_db_e - m_db         ; its length
        call  print_str                 ; print the label
        mv    a0, s1                    ; the double-buffered sum
        call  print_dec                 ; print it
        call  print_nl                  ; newline
        la    a0, m_tp                  ; "@ plain  cycles = "
        li    a1, m_tp_e - m_tp         ; its length
        call  print_str                 ; print the label
        mv    a0, s11                   ; plain elapsed cycles
        call  print_dec10               ; print as fixed-width digits (keeps traces comparable)
        call  print_nl                  ; newline
        la    a0, m_td                  ; "@ double cycles = "
        li    a1, m_td_e - m_td         ; its length
        call  print_str                 ; print the label
        mv    a0, s10                   ; double-buffered elapsed cycles
        call  print_dec10               ; print as fixed-width digits
        call  print_nl                  ; newline
park:                                   ; cores with nothing to do end up here
        li    a0, 0                     ; exit code 0
        halt                            ; stop (drains outstanding transfers first)

; -----------------------------------------------------------------------------
; sum_chunk(a0 = D-LS buffer): s1 += sum of CHUNK words, unrolled 4x
; -----------------------------------------------------------------------------
sum_chunk:                              ; routine entry
        li    t0, CHUNK / 4             ; t0 = groups of four words left
sc_loop:                                ; loop: four words per iteration
        ld    t1, 0(a0)                 ; word 0 of the group
        ld    t2, 8(a0)                 ; word 1
        ld    t3, 16(a0)                ; word 2
        ld    t4, 24(a0)                ; word 3
        add   s1, s1, t1                ; accumulate word 0
        add   s1, s1, t2                ; accumulate word 1
        add   s1, s1, t3                ; accumulate word 2
        add   s1, s1, t4                ; accumulate word 3
        addi  a0, a0, 32                ; next group
        addi  t0, t0, -1                ; one group fewer
        bnez  t0, sc_loop               ; until the chunk is done
        ret                             ; back to the caller

        .include "lib/print.s"          ; console helpers
