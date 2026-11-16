; =============================================================================
; chan.s: rings of records in an atomic segment (one producer, one consumer)
; =============================================================================
;
; Two cores that share an atomic segment (`catomic`: copyable, reachable only
; by far atomics, revocable with the memory it was cut from) can pass short
; records through it without the kernel: a few far atomics instead of a
; message round trip (doc/t2-uses.md). A ring is a piece of the segment:
;
;   0 HEAD   bytes written so far (a multiple of 8; only the producer adds)
;   8 TAIL   bytes consumed so far (only the consumer writes it)
;  16 SLEEP  nonzero: the consumer may be asleep, the producer must wake it
;            by other means (a message) after publishing
;  24..63    reserved
;  64..      the data: records of one length word and the bytes, padded to
;            whole words; a record wraps around the end of the data
;
; A record is written word by word and published by adding its size to HEAD
; last: the consumer never sees half of one (atomics of one core take effect
; in order). The producer must be one thread at a time; so must the consumer.
; Neither trusts the other's words: lengths and positions are checked.
;
; The producer (chan_put: a program) reaches its ring through c6, where it
; holds it, a register that is its own across context switches; the
; consumer (chan_get: tty, alone on its core) through c10, where it puts the
; segment of all the rings right before the call (c10 survives traps but not
; a context switch: a program preempted between that copy and a use of c10
; faulted on it). Offsets are from the register's base; ring sizes are
; multiples of 8 and at least 80.
; Clobbers t0..t6, a0..a7.

CH_HEAD  = 0                            ; ring header: bytes written
CH_TAIL  = 8                            ; bytes consumed
CH_SLEEP = 16                           ; the consumer may be asleep
CH_DATA  = 64                           ; the records

; chan_put(a0 = ring offset, a1 = ring size, a2 = source (D-LS, any
; alignment), a3 = length) -> a0 = length and a1 = the SLEEP word, or a0 = -1
; if the record does not fit now (nothing written)
chan_put:
        mv    a6, a0                    ; a6 = the ring
        tamo.add a4, c6, a6, zero       ; a4 = HEAD (an atomic add of 0 reads)
        addi  t0, a6, CH_TAIL           ; a5 = TAIL
        tamo.add a5, c6, t0, zero       ; ...
        addi  a7, a1, -CH_DATA          ; a7 = the data's size
        sub   t1, a4, a5                ; used
        bgtu  t1, a7, cp_full           ; (damaged: treat as full)
        addi  t2, a3, 7                 ; the record: a length word and whole words
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        addi  t2, t2, 8                 ; ...
        sub   t3, a7, t1                ; room?
        bgtu  t2, t3, cp_full           ; no
        remu  t4, a4, a7                ; t4 = HEAD's position in the data
        addi  t0, a6, CH_DATA           ; the length word
        add   t0, t0, t4                ; ...
        tamo.swap zero, c6, t0, a3      ; ...
        mv    t5, a2                    ; t5 = next source byte
        add   t6, a2, a3                ; t6 = the end of the source
cp_word:
        bgeu  t5, t6, cp_pub            ; all of it
        addi  t4, t4, 8                 ; the next position
        bltu  t4, a7, cp_pos            ; (wrapping at the end)
        li    t4, 0                     ; ...
cp_pos:
        sub   t1, t6, t5                ; a whole aligned word left?
        andi  t3, t5, 7                 ; ...
        bnez  t3, cp_bytes              ; not aligned
        li    t3, 8                     ; ...
        bltu  t1, t3, cp_bytes          ; not whole
        ld    t1, 0(t5)                 ; yes: one load
        addi  t5, t5, 8                 ; ...
        j     cp_store                  ; ...
cp_bytes:
        li    t1, 0                     ; gather up to 8 bytes, lowest first
        li    t3, 0                     ; shift
cp_b:
        bgeu  t5, t6, cp_store          ; the end
        li    t0, 64                    ; a word is full
        bgeu  t3, t0, cp_store          ; ...
        lbu   t0, 0(t5)                 ; ...
        sll   t0, t0, t3                ; ...
        or    t1, t1, t0                ; ...
        addi  t5, t5, 1                 ; ...
        addi  t3, t3, 8                 ; ...
        j     cp_b                      ; ...
cp_store:
        addi  t0, a6, CH_DATA           ; -> the ring
        add   t0, t0, t4                ; ...
        tamo.swap zero, c6, t0, t1      ; ...
        j     cp_word                   ; ...
cp_pub:
        tamo.add zero, c6, a6, t2       ; publish: HEAD += the record
        addi  t0, a6, CH_SLEEP          ; is the consumer awake?
        tamo.add a1, c6, t0, zero       ; ...
        mv    a0, a3                    ; written
        ret                             ; done
cp_full:
        li    a0, -1                    ; no room
        ret                             ; done

; chan_get(a0 = ring offset, a1 = ring size, a2 = destination (D-LS,
; 8-aligned, with room for the length rounded up to a word), a3 = most
; bytes accepted) -> a0 = the record's length (consumed), 0 if the ring is
; empty, -1 if it is damaged or the record is longer than a3 (nothing
; consumed; chan_reset starts it again); a1 = TAIL afterwards
chan_get:
        mv    a6, a0                    ; a6 = the ring
        tamo.add a4, c10, a6, zero      ; a4 = HEAD
        addi  t0, a6, CH_TAIL           ; a5 = TAIL
        tamo.add a5, c10, t0, zero      ; ...
        beq   a4, a5, cg_empty          ; nothing
        addi  a7, a1, -CH_DATA          ; a7 = the data's size
        sub   t1, a4, a5                ; used: a whole number of words, within the data
        bgtu  t1, a7, cg_bad            ; ...
        andi  t2, t1, 7                 ; ...
        bnez  t2, cg_bad                ; ...
        remu  t4, a5, a7                ; t4 = TAIL's position
        addi  t0, a6, CH_DATA           ; the length word
        add   t0, t0, t4                ; ...
        tamo.add t3, c10, t0, zero      ; t3 = the length
        bgtu  t3, a3, cg_bad            ; too long for the caller
        addi  t2, t3, 7                 ; its words
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        addi  t2, t2, 8                 ; t2 = the record's size
        bgtu  t2, t1, cg_bad            ; more than was published
        mv    t5, a2                    ; t5 = the destination
        addi  t6, t2, -8                ; t6 = bytes of words left
cg_word:
        beqz  t6, cg_done               ; all of them
        addi  t4, t4, 8                 ; the next position
        bltu  t4, a7, cg_pos            ; (wrapping at the end)
        li    t4, 0                     ; ...
cg_pos:
        addi  t0, a6, CH_DATA           ; <- the ring
        add   t0, t0, t4                ; ...
        tamo.add t1, c10, t0, zero      ; ...
        sd    t1, 0(t5)                 ; ...
        addi  t5, t5, 8                 ; ...
        addi  t6, t6, -8                ; ...
        j     cg_word                   ; ...
cg_done:
        add   t1, a5, t2                ; TAIL past it: the room is the producer's again
        addi  t0, a6, CH_TAIL           ; ...
        tamo.swap zero, c10, t0, t1     ; ...
        mv    a1, t1                    ; ...
        mv    a0, t3                    ; its length
        ret                             ; done (a1 = TAIL)
cg_empty:
        li    a0, 0                     ; empty
        mv    a1, a5                    ; ...
        ret                             ; done
cg_bad:
        li    a0, -1                    ; damaged, or too long
        mv    a1, a5                    ; ...
        ret                             ; done

; chan_sleep(a0 = ring offset, a1 = value): set the SLEEP word
chan_sleep:
        addi  t0, a0, CH_SLEEP          ; ...
        tamo.swap zero, c10, t0, a1     ; ...
        ret                             ; done

; chan_reset(a0 = ring offset): empty the ring (HEAD = TAIL = SLEEP = 0)
chan_reset:
        tamo.swap zero, c10, a0, zero   ; HEAD
        addi  t0, a0, CH_TAIL           ; TAIL
        tamo.swap zero, c10, t0, zero   ; ...
        addi  t0, a0, CH_SLEEP          ; SLEEP
        tamo.swap zero, c10, t0, zero   ; ...
        ret                             ; done
