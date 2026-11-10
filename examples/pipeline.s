; =============================================================================
; pipeline.s: a zero-copy producer/consumer pipeline between two cores
; =============================================================================
;
; What it shows
;   * Cores never share writable memory. A writable capability is linear:
;     at most one place in the whole machine holds it (a register, a save
;     slot or an inbox), and no instruction may overwrite or copy it. To give data to
;     another core you give it the *capability* (`cgive`), and your own copy
;     disappears.
;   * The hand-off is also the synchronisation. `cgive` completes only after
;     every transfer this core still has in flight has finished, so when the
;     consumer's `ctake` returns, the producer's writes are already in memory.
;     No locks, no fences, no flags to poll, and no cache-coherence traffic,
;     because there are no caches to keep coherent.
;   * The data never moves between cores. Each 4 KiB block stays where it
;     is in system memory; only a capability travels through the inbox.
;
; Core 0 (producer) owns two 4 KiB buffers in T3. For each of 8 blocks it
; takes a free buffer, fills it, and hands it to core 1. Core 1 (consumer)
; sums the block, checks the sum and hands the buffer back. With two
; buffers, core 0 fills block k+1 while core 1 sums block k.
;
; Expected output (printed by core 1):
;   block 0 sum = 130816 ok
;   block 1 sum = 642816 ok
;   ...
;   block 7 sum = 3714816 ok
;   8 blocks passed between cores, 0 locks taken

BLK     = 512                           ; words per block
BBYTES  = BLK * 8                       ; bytes per block (4 KiB)
ROUNDS  = 8                             ; blocks to send

        .data                           ; data Local Store (each core has its own)
        .align 8                        ; transfer buffers must be 8-byte aligned
buf:    .space BBYTES                   ; the block being built (core 0) or checked (core 1)
m_blk:  .ascii "block "                 ; output pieces
m_blk_e:                                ; end of the text above (its length = end - start)
m_sum:  .ascii " sum = "                ; output text
m_sum_e:                                ; end of the text above (its length = end - start)
m_ok:   .ascii " ok\n"                  ; output text
m_ok_e:                                 ; end of the text above (its length = end - start)
m_bad:  .ascii " WRONG\n"               ; output text
m_bad_e:                                ; end of the text above (its length = end - start)
m_end:  .ascii " blocks passed between cores, 0 locks taken\n"  ; output text
m_end_e:                                ; end of the text above (its length = end - start)

m_need: .ascii "this example needs at least 2 cores\n" ; output text
m_need_e:                               ; end of the text above

        .text                           ; instruction Local Store
_start:                                 ; entry point: every core starts executing here, at I-LS address 0
        li    sp, 65536                 ; stack at the top of D-LS
        csrr  t0, ncores                ; how many cores are there?
        li    t1, 2                     ; this example needs two
        bge   t0, t1, enough            ; fine
        la    a0, m_need                ; otherwise say so
        li    a1, m_need_e - m_need     ; its length
        call  print_str                 ; print it
        li    a0, 1                     ; exit code 1
        halt                            ; and stop
enough:
        li    s6, BBYTES                ; s6 = block size, a transfer operand
        la    s5, buf                   ; s5 = D-LS block buffer
        csrr  t0, coreid                ; which core are we?
        li    t1, 1                     ; core 1 is the consumer
        beq   t0, t1, consumer          ; go consume
        bnez  t0, idle                  ; cores 2 and up are not needed


; =============================== core 0: producer ===============================
producer:                               ; core 0 starts here
        csplit c5, c0, s6               ; c0 = [0, 4K) = buffer A, c5 = the rest of T3
        csplit c6, c5, s6               ; c5 = [4K, 8K) = buffer B, c6 = the rest (unused)
        li    s1, 0                     ; s1 = block number k
p_loop:                                 ; loop: one block per iteration
        li    t0, 2                     ; the first two rounds use the two fresh buffers
        bge   s1, t0, p_reuse           ; after that, wait for core 1 to return one
        beqz  s1, p_first               ; round 0 uses buffer A
        cmov  c4, c5                    ; round 1: buffer B moves into c4 (c5 becomes empty)
        j     p_fill                    ; go fill it
p_first:                                ; round 0
        cmov  c4, c0                    ; round 0: buffer A moves into c4
        j     p_fill                    ; go fill it
p_reuse:                                ; rounds 2 and later
        ctake c4                        ; block until core 1 hands a buffer back
p_fill:                                 ; c4 now owns a free buffer
        li    t0, 1000                  ; t0 = 1000
        mul   t1, s1, t0                ; t1 = first value of block k (1000 * k)
        mv    t2, s5                    ; t2 = cursor in the D-LS buffer
        li    t3, BLK                   ; t3 = words left
p_word:                                 ; loop: one word of the block
        sd    t1, 0(t2)                 ; write a value into the Local Store
        addi  t1, t1, 1                 ; next value
        addi  t2, t2, 8                 ; next word
        addi  t3, t3, -1                ; one fewer
        bnez  t3, p_word                ; until the block is built
        tput  tg0, s5, c4, zero, s6     ; copy the block into the buffer that c4 names
        li    t0, 1                     ; t0 = core 1
        cgive c4, t0                    ; hand the buffer over (waits for the tput; c4 becomes empty)
        addi  s1, s1, 1                 ; next block
        li    t0, ROUNDS                ; loop bound
        blt   s1, t0, p_loop            ; until every block is sent
        ctake c4                        ; take back the last two buffers so that,
        ctake c5                        ; at the end, core 0 owns everything again
        li    a0, 0                     ; exit code
        halt                            ; stop

; =============================== core 1: consumer ===============================
consumer:                               ; core 1 starts here
        li    s1, 0                     ; s1 = block number k
        li    s3, 0                     ; s3 = blocks that checked out
c_loop:                                 ; loop: one block per iteration
        ctake c4                        ; wait for the next block's capability
        tget  tg0, s5, c4, zero, s6     ; bring the block into our own Local Store
        li    t0, 0                     ; t0 = core 0
        cgive c4, t0                    ; return the buffer right away (cgive waits for the tget)
        mv    t2, s5                    ; t2 = cursor
        li    t3, BLK                   ; t3 = words left
        li    s2, 0                     ; s2 = sum
c_word:                                 ; loop: one word of the block
        ld    t1, 0(t2)                 ; read a word (it arrived before cgive completed)
        add   s2, s2, t1                ; accumulate
        addi  t2, t2, 8                 ; next word
        addi  t3, t3, -1                ; one fewer
        bnez  t3, c_word                ; until the block is summed
        li    t0, BBYTES * 125          ; expected sum = 512000 * k ...
        mul   s4, s1, t0                ;   (512 values * 1000 * k)
        li    t0, BLK * (BLK - 1) / 2   ; ... + 0 + 1 + ... + 511
        add   s4, s4, t0                ; s4 = expected sum
        la    a0, m_blk                 ; "block "
        li    a1, m_blk_e - m_blk       ; length
        call  print_str                 ; print it
        mv    a0, s1                    ; block number
        call  print_dec                 ; print it
        la    a0, m_sum                 ; " sum = "
        li    a1, m_sum_e - m_sum       ; length
        call  print_str                 ; print it
        mv    a0, s2                    ; the sum
        call  print_dec                 ; print it
        la    a0, m_ok                  ; assume it is right
        li    a1, m_ok_e - m_ok         ; length of " ok\n"
        bne   s2, s4, c_bad             ; compare with the expected sum
        addi  s3, s3, 1                 ; count a good block
        j     c_say                     ; print the verdict
c_bad:                                  ; the sum did not match
        la    a0, m_bad                 ; " WRONG\n"
        li    a1, m_bad_e - m_bad       ; its length
c_say:                                  ; a0/a1 hold the verdict text
        call  print_str                 ; print the verdict
        addi  s1, s1, 1                 ; next block
        li    t0, ROUNDS                ; loop bound
        blt   s1, t0, c_loop            ; until all blocks are checked
        mv    a0, s3                    ; number of good blocks
        call  print_dec                 ; print it
        la    a0, m_end                 ; closing line
        li    a1, m_end_e - m_end       ; its length
        call  print_str                 ; print it
        li    a0, 0                     ; exit code
        halt                            ; stop
idle:
        li    a0, 0                     ; exit code
        halt                            ; extra cores just stop

        .include "lib/print.s"          ; console helpers
