; =============================================================================
; swcache.s: a software-managed cache built on `ltag` / `linst`
; =============================================================================
;
; What it shows
;   * Strata has no hardware cache. When access patterns are irregular, a
;     program builds its own cache in the data Local Store, and *it* decides
;     the geometry, which lines live where, and when they are fetched.
;   * The hardware supplies only the expensive part of a lookup:
;       ltag rd, rs   looks up far offset rs in a set-associative tag table
;                     in D-LS. On a hit rd = LS address of the cached byte;
;                     on a miss rd has bit 63 set and holds the LS address
;                     of the victim slot to fill.
;       linst rs      records rs's line in that victim slot and advances the
;                     set's round-robin replacement counter.
;     The table's location and shape come from three CSRs:
;       ttag  = D-LS address of the tag table (per set: `ways` tag words + 1 counter word)
;       tdata = D-LS address of the line storage (sets * ways lines)
;       tgeom = log2(line bytes) | log2(sets) << 6 | ways << 12
;   * A miss is ordinary code: `tget` the line into the victim slot, `linst`,
;     then load. The load stalls until the line has arrived, so there's no
;     window in which the cache could return stale bytes.
;
; Workload: a 64 Ki-entry table in T3 (value[i] = 7*i + 3) read at 4000
; pseudo-random indices, 3/4 of them inside a 512-entry "hot" region.
; The result is checked against the formula.
;
; Expected output:
;   lookups = 4000
;   hits    = <deterministic count>
;   misses  = <deterministic count>
;   sum     = <sum>
;   check: ok

ENTRIES = 65536                         ; table length in 64-bit words (512 KiB in T3)
CHUNK   = 1024                          ; words per fill transfer
CBYTES  = CHUNK * 8                     ; bytes per fill transfer
LINE_LG = 6                             ; 64-byte cache lines
SETS_LG = 5                             ; 32 sets
WAYS    = 4                             ; 4-way set associative
NLOOK   = 4000                          ; number of lookups

        .data                           ; data Local Store
        .align 64                       ; line storage aligned to the line size
lines:  .space (1 << SETS_LG) * WAYS << LINE_LG ; 32 sets * 4 ways * 64 B = 8 KiB of cached lines
tags:   .space (1 << SETS_LG) * (WAYS + 1) * 8  ; tag table: zero means "empty" (valid tags have bit 0 set)
stage:  .space CBYTES                   ; staging buffer for initialising the far table
m_lk:   .ascii "lookups = "             ; output labels and their ends
m_lk_e:                                 ; end of the text above (its length = end - start)
m_hit:  .ascii "hits    = "             ; output text
m_hit_e:                                ; end of the text above (its length = end - start)
m_mis:  .ascii "misses  = "             ; output text
m_mis_e:                                ; end of the text above (its length = end - start)
m_sum:  .ascii "sum     = "             ; output text
m_sum_e:                                ; end of the text above (its length = end - start)
m_ok:   .ascii "check: ok\n"            ; output text
m_ok_e:                                 ; end of the text above (its length = end - start)
m_bad:  .ascii "check: MISMATCH\n"      ; output text
m_bad_e:                                ; end of the text above (its length = end - start)

        .text                           ; instruction Local Store
_start:                                 ; entry point: every core starts executing here, at I-LS address 0
        csrr  t0, coreid                ; which core are we?
        bnez  t0, park                  ; only core 0 runs this example

; ---- write value[i] = 7*i + 3 to the far table ---------------------------------
        li    s2, 0                     ; s2 = far offset of the current chunk
        li    s3, 3                     ; s3 = next value (7*0 + 3)
        li    s6, CBYTES                ; s6 = chunk size in bytes
        la    s5, stage                 ; s5 = staging buffer
        li    s4, ENTRIES / CHUNK       ; s4 = chunks to write
init_chunk:                             ; loop: build and send one chunk of the table
        mv    t0, s5                    ; t0 = cursor in the staging buffer
        li    t1, CHUNK                 ; t1 = words left in the chunk
init_word:                              ; loop: one table entry
        sd    s3, 0(t0)                 ; store a value (waits while the previous tput still reads it)
        addi  s3, s3, 7                 ; the next value is 7 more
        addi  t0, t0, 8                 ; next word
        addi  t1, t1, -1                ; one fewer
        bnez  t1, init_word             ; fill the chunk
        tput  tg1, s5, c0, s2, s6       ; send the chunk to T3
        add   s2, s2, s6                ; next far offset
        addi  s4, s4, -1                ; one chunk fewer
        bnez  s4, init_chunk            ; until the table is written

; ---- describe the cache to the hardware ---------------------------------------
        la    t0, tags                  ; t0 = tag table address
        csrw  ttag, t0                  ; tell ltag/linst where the tags live
        la    t0, lines                 ; t0 = line storage address
        csrw  tdata, t0                 ; tell ltag where line slots start
        li    t0, LINE_LG | SETS_LG << 6 | WAYS << 12 ; t0 = geometry word
        csrw  tgeom, t0                 ; set line size, set count and associativity

; ---- the lookup loop ------------------------------------------------------------
        li    s3, 12345                 ; s3 = pseudo-random state (fixed seed: deterministic)
        li    s4, NLOOK                 ; s4 = lookups left
        li    s7, 0                     ; s7 = sum of values read through the cache
        li    s8, 0                     ; s8 = sum of values computed from the formula
        li    s9, 0                     ; s9 = cache hits (load_cached counts them)
        li    s10, 1103515245           ; s10 = LCG multiplier
look:                                   ; loop: one cached lookup
        mul   s3, s3, s10               ; state = state * multiplier ...
        addi  s3, s3, 12345             ; ... + increment
        slli  s3, s3, 33                ; keep the low 31 bits:
        srli  s3, s3, 33                ;   shift up and back down to clear the high bits
        srli  t0, s3, 8                 ; t0 = random bits, dropping the weak low ones
        andi  t1, t0, 3                 ; t1 = 0..3, choose hot or cold
        srli  t0, t0, 2                 ; t0 = remaining random bits for the index
        beqz  t1, cold                  ; 1 in 4: anywhere in the table
        andi  t0, t0, 511               ; 3 in 4: inside the 512-entry hot region
        j     have_idx                  ; index chosen
cold:                                   ; cold path: pick an index anywhere
        li    t1, ENTRIES - 1           ; t1 = mask for a full-table index
        and   t0, t0, t1                ; t0 = index anywhere
have_idx:                               ; t0 now holds the index
        li    t1, 7                     ; t1 = 7
        mul   t1, t0, t1                ; t1 = 7 * index
        addi  t1, t1, 3                 ; t1 = expected value
        add   s8, s8, t1                ; accumulate the expected sum
        slli  a0, t0, 3                 ; a0 = far byte offset of the entry
        call  load_cached               ; a0 = value, through the software cache
        add   s7, s7, a0                ; accumulate the cached sum
        addi  s4, s4, -1                ; one lookup fewer
        bnez  s4, look                  ; until all lookups are done

; ---- report -----------------------------------------------------------------------
        la    a0, m_lk                  ; "lookups = "
        li    a1, m_lk_e - m_lk         ; label length
        li    a2, NLOOK                 ; value
        call  print_kv                  ; print the line
        la    a0, m_hit                 ; "hits    = "
        li    a1, m_hit_e - m_hit       ; label length
        mv    a2, s9                    ; hit count
        call  print_kv                  ; print
        la    a0, m_mis                 ; "misses  = "
        li    a1, m_mis_e - m_mis       ; label length
        li    a2, NLOOK                 ; a2 = lookups ...
        sub   a2, a2, s9                ; ... minus hits = misses
        call  print_kv                  ; print
        la    a0, m_sum                 ; "sum     = "
        li    a1, m_sum_e - m_sum       ; label length
        mv    a2, s7                    ; the sum read through the cache
        call  print_kv                  ; print
        la    a0, m_ok                  ; assume the check passes
        li    a1, m_ok_e - m_ok         ; its length
        beq   s7, s8, report            ; the cache returned exactly what the formula predicts
        la    a0, m_bad                 ; otherwise report a mismatch
        li    a1, m_bad_e - m_bad       ; its length
report:                                 ; print the verdict selected in a0/a1
        call  print_str                 ; print the verdict
park:                                   ; cores with nothing to do end up here
        li    a0, 0                     ; exit code
        halt                            ; stop

; -----------------------------------------------------------------------------
; load_cached(a0 = far byte offset in T3) -> a0 = 64-bit value at that offset
; -----------------------------------------------------------------------------
load_cached:                            ; routine entry
        ltag  t0, a0                    ; look the offset up in the tag table
        bltz  t0, lc_miss               ; bit 63 set means a miss
        ld    a0, 0(t0)                 ; hit: t0 is already the LS address of the word
        addi  s9, s9, 1                 ; count the hit
        ret                             ; done
lc_miss:                                ; miss path: fill the victim slot
        slli  t0, t0, 1                 ; clear bit 63 of the victim slot address:
        srli  t0, t0, 1                 ;   shift it out and back
        srli  t1, a0, LINE_LG           ; t1 = line number
        slli  t1, t1, LINE_LG           ; t1 = far offset of the line start
        li    t2, 1 << LINE_LG          ; t2 = one line, in bytes
        tget  tg0, t0, c0, t1, t2       ; fetch the whole line into the victim slot
        linst a0                        ; record the new line in the tag table
        andi  t1, a0, (1 << LINE_LG) - 1 ; t1 = byte offset within the line
        add   t0, t0, t1                ; t0 = LS address of the wanted word
        ld    a0, 0(t0)                 ; load it (stalls until the line has landed)
        ret                             ; done

        .include "lib/print.s"          ; console helpers
