; =============================================================================
; blk.s: block device 0 (device window 0x2000, inbox node = ncores)
; =============================================================================
;
; What it checks (common/platform.h)
;   * Identify ROM (0x2000, 64 bytes): "STBD", version 1, log2 block size 9,
;     capacity in blocks (8192 with no disk image), 256 blocks per command,
;     queue depth 4.
;   * A command is 32 bytes written to the submission port (0x2100):
;     u8 op (1 read, 2 write, 3 flush), u8 reply core, u16 id, u32 blocks,
;     u64 lba, u64 byte offset into the capability, 8 bytes reserved. It runs
;     once a capability for the data has been given to the device's node
;     (cgive to node ncores); the capability then comes back to the reply
;     core (core 0 when the reply core does not exist), from sender ncores.
;   * The completion port (0x2200) yields 16-byte entries: u16 id, u16
;     status, u32 blocks moved (0 on error), 8 reserved; an empty queue
;     reads as zeros.
;   * Write then read back moves exactly the bytes (multi-block too, up to
;     the last block of the disk).
;   * Errors, checked in this order: 1 unknown op; 2 lba / count out of
;     range or more than 256 blocks; 3 offset not 8-byte aligned or the
;     bytes do not fit the capability; 4 not memory, or read without W /
;     write without R. Flush ignores the count, lba and capability.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

B_ID = 0x2000                           ; identify ROM
B_SQ = 0x2100                           ; submission port
B_CQ = 0x2200                           ; completion port
OP_RD = 1                               ; read blocks into memory
OP_WR = 2                               ; write blocks from memory
OP_FL = 3                               ; flush

        .data                           ; data Local Store
        .align 8                        ; transfer buffers
cmd:    .space 32                       ; one command
cqe:    .space 16                       ; one completion entry
idb:    .space 64                       ; identify ROM copy
blkbuf: .space 1024                     ; two blocks of data

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test

; ---- identify ----------------------------------------------------------------------------
        la    s1, idb                   ; s1 = buffer
        li    t0, B_ID                  ; identify ROM
        li    t1, 64                    ; all 64 bytes
        tget  tg1, s1, c3, t0, t1       ; read it
        ld    a0, 0(s1)                 ; magic, version, log2 block size
        li    a1, 0x0009000144425453    ; "STBD", 1, 9
        call  chk                       ; check
        ld    a0, 8(s1)                 ; capacity
        li    a1, 8192                  ; blocks (4 MiB: the default disk)
        call  chk                       ; check
        ld    a0, 16(s1)                ; max blocks per command | queue depth << 32
        li    a1, 256 | 4 << 32         ; expected
        call  chk                       ; check
        ld    a0, 56(s1)                ; reserved
        li    a1, 0                     ; zero
        call  chk                       ; check
        li    t0, B_CQ                  ; completion port, nothing completed yet
        li    t1, 16                    ; one entry
        la    t2, cqe                   ; buffer
        li    t3, -1                    ; fill with ones first
        sd    t3, 0(t2)                 ; word 0
        tget  tg1, t2, c3, t0, t1       ; read
        ld    a0, 0(t2)                 ; an empty queue reads as zeros
        li    a1, 0                     ; expected
        call  chk                       ; check

; ---- a 4 KiB data area, filled with a pattern ----------------------------------------
        li    t0, 0x100000              ; 1 MiB
        csplit c5, c0, t0               ; c0 = [0, 1M)
        li    t0, 0x1000                ; 4 KiB
        csplit c6, c5, t0               ; c5 = [1M, 1M + 4K), c6 = the rest
        cmov  c7, c6                    ; park the rest in c7
        cmov  c6, c5                    ; c6 = the 4 KiB data area: what blkdo hands to the device
        la    s2, blkbuf                ; s2 = D-LS data
        li    t0, 0                     ; t0 = word index
        li    t1, 0x9e3779b97f4a7c15    ; t1 = multiplier
fill:
        mul   t2, t0, t1                ; word i = i * multiplier
        slli  t3, t0, 3                 ; byte offset
        add   t3, s2, t3                ; address
        sd    t2, 0(t3)                 ; store
        addi  t0, t0, 1                 ; next
        li    t4, 128                   ; 128 words = 1 KiB
        bne   t0, t4, fill              ; loop
        li    t0, 0                     ; area offset 0
        li    t1, 1024                  ; two blocks
        tput  tg1, s2, c6, t0, t1       ; area[0..1K) = pattern

; ---- write 1 block at lba 5, read it back elsewhere -------------------------------------------
        li    a0, OP_WR                 ; write
        li    a1, 0                     ; reply to core 0
        li    a2, 0x1111                ; id
        li    a3, 1                     ; one block
        li    a4, 5                     ; lba 5
        li    a5, 0                     ; from area offset 0
        call  blkdo                     ; run it
        li    a1, 0x1111 | 0 << 16 | 1 << 32 ; id, status OK, 1 block
        call  chk                       ; check
        li    a0, OP_RD                 ; read
        li    a1, 0                     ; reply to core 0
        li    a2, 0x2222                ; id
        li    a3, 1                     ; one block
        li    a4, 5                     ; lba 5
        li    a5, 2048                  ; into area offset 2 KiB
        call  blkdo                     ; run it
        li    a1, 0x2222 | 1 << 32      ; id, OK, 1 block
        call  chk                       ; check
        li    a0, 2048                  ; compare area[2K..] with the pattern's first block
        li    a1, 512                   ; 512 bytes
        call  cmpblk                    ; a0 = number of differing words
        li    a1, 0                     ; expected: none
        call  chk                       ; check

; ---- two blocks at the end of the disk ---------------------------------------------------------
        li    a0, OP_WR                 ; write
        li    a1, 0                     ; reply to core 0
        li    a2, 0x3333                ; id
        li    a3, 2                     ; two blocks
        li    a4, 8190                  ; the last two
        li    a5, 0                     ; from offset 0
        call  blkdo                     ; run it
        li    a1, 0x3333 | 2 << 32      ; OK, 2 blocks
        call  chk                       ; check
        li    a0, OP_RD                 ; read
        li    a1, 200                   ; reply to core 200: no such core, so core 0
        li    a2, 0x4444                ; id
        li    a3, 2                     ; two blocks
        li    a4, 8190                  ; the last two
        li    a5, 2048                  ; into offset 2 KiB
        call  blkdo                     ; run it (the capability comes back to core 0)
        li    a1, 0x4444 | 2 << 32      ; OK, 2 blocks
        call  chk                       ; check
        li    a0, 2048                  ; compare
        li    a1, 1024                  ; both blocks
        call  cmpblk                    ; differing words
        li    a1, 0                     ; none
        call  chk                       ; check
        li    a0, OP_RD                 ; read a block nobody wrote
        li    a1, 0                     ; reply
        li    a2, 0x5555                ; id
        li    a3, 1                     ; one
        li    a4, 100                   ; lba 100
        li    a5, 0                     ; into offset 0
        call  blkdo                     ; run it
        li    a1, 0x5555 | 1 << 32      ; OK
        call  chk                       ; check
        la    t0, blkbuf                ; read area[0..8) back
        li    t1, 0                     ; offset 0
        li    t2, 8                     ; one word
        tget  tg1, t0, c6, t1, t2       ; get it
        ld    a0, 0(t0)                 ; the word
        li    a1, 0                     ; a fresh disk is zeros
        call  chk                       ; check
        li    a0, OP_RD                 ; zero blocks at lba = capacity
        li    a1, 0                     ; reply
        li    a2, 0x5556                ; id
        li    a3, 0                     ; none
        li    a4, 8192                  ; lba = capacity
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x5556                ; OK, 0 blocks
        call  chk                       ; check

; ---- flush ---------------------------------------------------------------------------------------
        li    a0, OP_FL                 ; flush
        li    a1, 0                     ; reply
        li    a2, 0x6666                ; id
        li    a3, 7                     ; a count (flush ignores it, echoes it back)
        li    a4, -1                    ; an lba no read could use
        li    a5, 3                     ; a misaligned offset
        call  blkdo                     ; run it
        li    a1, 0x6666 | 7 << 32      ; OK, count echoed
        call  chk                       ; check

; ---- errors ----------------------------------------------------------------------------------------
        li    a0, 9                     ; unknown op
        li    a1, 0                     ; reply
        li    a2, 0x7001                ; id
        li    a3, 1                     ; one block
        li    a4, -1                    ; and a bad lba: the op is checked first
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x7001 | 1 << 16      ; status 1 (bad op), 0 blocks
        call  chk                       ; check
        li    a0, OP_RD                 ; read
        li    a1, 0                     ; reply
        li    a2, 0x7002                ; id
        li    a3, 1                     ; one block
        li    a4, 8192                  ; lba = capacity
        li    a5, 3                     ; and a bad offset: lba is checked first
        call  blkdo                     ; run it
        li    a1, 0x7002 | 2 << 16      ; status 2 (lba)
        call  chk                       ; check
        li    a0, OP_RD                 ; read
        li    a1, 0                     ; reply
        li    a2, 0x7003                ; id
        li    a3, 2                     ; two blocks
        li    a4, 8191                  ; the last block: the second is past the end
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x7003 | 2 << 16      ; status 2
        call  chk                       ; check
        li    a0, OP_RD                 ; read
        li    a1, 0                     ; reply
        li    a2, 0x7004                ; id
        li    a3, 257                   ; more than 256 blocks
        li    a4, 0                     ; lba 0
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x7004 | 2 << 16      ; status 2
        call  chk                       ; check
        li    a0, OP_RD                 ; read
        li    a1, 0                     ; reply
        li    a2, 0x7005                ; id
        li    a3, 1                     ; one block
        li    a4, 0                     ; lba 0
        li    a5, 4                     ; misaligned offset
        call  blkdo                     ; run it
        li    a1, 0x7005 | 3 << 16      ; status 3 (range)
        call  chk                       ; check
        li    a0, OP_RD                 ; read
        li    a1, 0                     ; reply
        li    a2, 0x7006                ; id
        li    a3, 1                     ; one block
        li    a4, 0                     ; lba 0
        li    a5, 4096 - 256            ; the block would run past the 4 KiB capability
        call  blkdo                     ; run it
        li    a1, 0x7006 | 3 << 16      ; status 3
        call  chk                       ; check
        li    t0, P_R | P_X             ; read-only
        crestrict c6, c6, t0            ; restrict the data area in place
        li    a0, OP_RD                 ; a read into memory the device may not write
        li    a1, 0                     ; reply
        li    a2, 0x7007                ; id
        li    a3, 1                     ; one block
        li    a4, 0                     ; lba 0
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x7007 | 4 << 16      ; status 4 (perm)
        call  chk                       ; check
        li    a0, OP_WR                 ; a write from it is fine
        li    a1, 0                     ; reply
        li    a2, 0x7008                ; id
        li    a3, 1                     ; one block
        li    a4, 9                     ; lba 9
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x7008 | 1 << 32      ; OK
        call  chk                       ; check
        cclear c6                       ; drop the read-only area
        li    t0, 0x1000                ; another 4 KiB
        csplit c8, c7, t0               ; c7 = 4 KiB, c8 = the rest
        li    t0, P_W                   ; write-only
        crestrict c6, c7, t0            ; c6 = write-only area
        li    a0, OP_WR                 ; a write needs R
        li    a1, 0                     ; reply
        li    a2, 0x7009                ; id
        li    a3, 1                     ; one block
        li    a4, 0                     ; lba 0
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x7009 | 4 << 16      ; status 4
        call  chk                       ; check
        cclear c6                       ; drop it
        cmov  c6, c3                    ; a device capability (copy of c3)
        li    a0, OP_RD                 ; read into device space
        li    a1, 0                     ; reply
        li    a2, 0x700a                ; id
        li    a3, 1                     ; one block
        li    a4, 0                     ; lba 0
        li    a5, 0                     ; offset
        call  blkdo                     ; run it
        li    a1, 0x700a | 4 << 16      ; status 4: not memory
        call  chk                       ; check
        j     done                      ; print the signature and the verdict

; -----------------------------------------------------------------------------
; blkdo(a0 op, a1 reply, a2 id, a3 blocks, a4 lba, a5 offset): submit the
; command, hand c6 to the device, take it back, return a0 = completion word 0.
; -----------------------------------------------------------------------------
blkdo:
        la    t0, cmd                   ; t0 = command buffer
        sb    a0, 0(t0)                 ; op
        sb    a1, 1(t0)                 ; reply core
        sh    a2, 2(t0)                 ; id
        sw    a3, 4(t0)                 ; blocks
        sd    a4, 8(t0)                 ; lba
        sd    a5, 16(t0)                ; byte offset
        sd    zero, 24(t0)              ; reserved
        li    t1, B_SQ                  ; submission port
        li    t2, 32                    ; one command
        tput  tg13, t0, c3, t1, t2      ; submit
        csrr  t3, ncores                ; the device's node number
        cgive c6, t3                    ; hand it the data capability: the command runs
        ctake c6, t3                    ; and take it back (from sender ncores)
        la    t0, cqe                   ; completion buffer
        li    t1, B_CQ                  ; completion port
        li    t2, 16                    ; one entry
        tget  tg13, t0, c3, t1, t2      ; read it
        ld    a0, 0(t0)                 ; id | status << 16 | blocks << 32
        ret                             ; back

; -----------------------------------------------------------------------------
; cmpblk(a0 = area offset, a1 = bytes): compare area[a0 ..] with the pattern
; (blkbuf), one word at a time; a0 = number of differing words.
; -----------------------------------------------------------------------------
cmpblk:
        mv    t4, a0                    ; t4 = area offset
        add   t5, a0, a1                ; t5 = end offset
        la    t6, blkbuf                ; t6 = pattern word
        li    a0, 0                     ; differences
cb_loop:
        la    t0, cqe                   ; 8-byte scratch (cqe + 8)
        addi  t0, t0, 8                 ; t0 = scratch
        li    t2, 8                     ; one word
        tget  tg12, t0, c6, t4, t2      ; read area word
        ld    t1, 0(t0)                 ; the word (waits)
        ld    t3, 0(t6)                 ; the pattern word
        beq   t1, t3, cb_same           ; equal?
        addi  a0, a0, 1                 ; no: count it
cb_same:
        addi  t4, t4, 8                 ; next area word
        addi  t6, t6, 8                 ; next pattern word
        bltu  t4, t5, cb_loop           ; until the end
        ret                             ; back
