; =============================================================================
; plat.s: the platform table (device window 0x1000)
; =============================================================================
;
; What it checks (common/platform.h)
;   * Header (32 bytes): "STPD", u16 version 1, u16 entry size 32, u16
;     entries 9, u16 cores, u32 total length 320, u32 checksum, u16 entries
;     of the capability save table (256, the default), u16 entries of the
;     overlay map (16, the default), 8 bytes reserved (zero).
;   * checksum = the sum of all 320 bytes with the checksum field taken as
;     zero, mod 2^32.
;   * The nine entries (u16 type, u16 index, u16 space, u16 node, u64 info,
;     u64 base, u64 size): system memory (T3, 64 MiB), cluster store (T2,
;     256 KiB), console (info 3 = output | input), the platform table itself,
;     block device 0 (node = ncores, info = 32768 blocks), the framebuffer
;     (1280 x 800, stride 5120, format 1 = XRGB8888, at 0x3000000 in T3,
;     16 MiB), the timer (info = 1000000 ticks per second), the pointer
;     (window 0x4100, 16 bytes; info 0x0307 = buttons left | right | middle,
;     wheel y | wheel x << 8) and the network interface (window 0x4200,
;     0x20 bytes; info = MTU 1500). "node" is
;     0xffff when nothing can be given to the device.
;   * Bytes past the table (still inside the window) read as zero.

        .include "lib/conf.s"           ; harness: _start, sig/chk/chkt/done, trap recorder

        .data                           ; data Local Store
        .align 8                        ; transfer buffer
tbl:    .space 320                      ; the table
past:   .space 32                       ; bytes after it
; expected entries: (type | index << 16 | space << 32 | node << 48), info, base, size
expect: .dword 1 | 0 << 16 | 3 << 32 | 0xffff << 48, 0, 0, 0x4000000             ; memory: T3
        .dword 1 | 1 << 16 | 2 << 32 | 0xffff << 48, 0, 0, 0x40000               ; memory: T2
        .dword 2 | 0 << 16 | 4 << 32 | 0xffff << 48, 3, 0, 0x100                 ; console
        .dword 3 | 0 << 16 | 4 << 32 | 0xffff << 48, 1, 0x1000, 320             ; platform table
        .dword 4 | 0 << 16 | 4 << 32, 32768, 0x2000, 0x300                        ; block device (node patched in: ncores)
        .dword 5 | 0 << 16 | 3 << 32 | 0xffff << 48, 1280 | 800 << 16 | 5120 << 32 | 1 << 48, 0x3000000, 0x1000000 ; framebuffer
        .dword 6 | 0 << 16 | 4 << 32 | 0xffff << 48, 1000000, 0x3000, 0x20      ; timer
        .dword 7 | 0 << 16 | 4 << 32 | 0xffff << 48, 0x0307, 0x4100, 0x10       ; pointer
        .dword 8 | 0 << 16 | 4 << 32 | 0xffff << 48, 1500, 0x4200, 0x20         ; network interface

        .text                           ; instruction Local Store
main:
        csrr  t0, coreid                ; which core?
        bnez  t0, park                  ; only core 0 runs the test
        la    s1, tbl                   ; s1 = table buffer
        li    t0, 0x1000                ; the platform table's window
        li    t1, 352                   ; the table and 32 bytes past it
        tget  tg1, s1, c3, t0, t1       ; read it
        twait tg1                       ; wait for it

; ---- header ----------------------------------------------------------------------------------
        ld    a0, 0(s1)                 ; magic, version, entry size
        li    a1, 0x0020000144505453    ; "STPD", 1, 32
        call  chk                       ; check
        ld    a0, 8(s1)                 ; entries, cores, length
        csrr  a1, ncores                ; cores
        slli  a1, a1, 16                ; in bits 16..31
        ori   a1, a1, 9                 ; 9 entries
        li    t0, 320 << 32             ; total length 320
        or    a1, a1, t0                ; expected
        call  chk                       ; check
        lwu   s2, 16(s1)                ; s2 = the stored checksum
        lwu   a0, 20(s1)                ; the save table's and the overlay map's entries
        li    a1, 256 | 16 << 16        ; the defaults
        call  chk                       ; check
        ld    a0, 24(s1)                ; reserved
        li    a1, 0                     ; zero
        call  chk                       ; check

; ---- checksum --------------------------------------------------------------------------------
        li    t0, 0                     ; t0 = byte index
        li    t1, 0                     ; t1 = sum
ck_loop:
        add   t2, s1, t0                ; address of byte t0
        lbu   t2, 0(t2)                 ; the byte
        add   t1, t1, t2                ; add it
        addi  t0, t0, 1                 ; next
        li    t3, 320                   ; table length
        bne   t0, t3, ck_loop           ; loop
        andi  t2, s2, 0xff              ; take the checksum field's own bytes back out
        sub   t1, t1, t2                ; byte 16
        srli  t3, s2, 8                 ; next byte
        andi  t2, t3, 0xff              ; byte 17
        sub   t1, t1, t2                ; out
        srli  t3, s2, 16                ; next byte
        andi  t2, t3, 0xff              ; byte 18
        sub   t1, t1, t2                ; out
        srli  t2, s2, 24                ; byte 19
        sub   t1, t1, t2                ; out
        li    t2, 0xffffffff            ; mod 2^32
        and   a0, t1, t2                ; the computed checksum
        mv    a1, s2                    ; must equal the stored one
        call  chk                       ; check

; ---- entries ----------------------------------------------------------------------------------
        la    s3, expect                ; s3 = expected entries
        csrr  t0, ncores                ; block device node = ncores
        slli  t0, t0, 48                ; in bits 48..63
        ld    t1, 128(s3)               ; entry 4, first word
        or    t1, t1, t0                ; patch the node in
        sd    t1, 128(s3)               ; store
        li    s4, 0                     ; s4 = word index 0..31
en_loop:
        slli  t0, s4, 3                 ; byte offset
        add   t1, s1, t0                ; table word
        ld    a0, 32(t1)                ; (entries start after the 32-byte header)
        add   t1, s3, t0                ; expected word
        ld    a1, 0(t1)                 ; expected
        call  chk                       ; check
        addi  s4, s4, 1                 ; next
        li    t0, 36                    ; 9 entries x 4 words
        bne   s4, t0, en_loop           ; loop

; ---- past the end ---------------------------------------------------------------------------------
        la    t0, past                  ; the 32 bytes after the table
        ld    a0, 0(t0)                 ; first word
        ld    t1, 8(t0)                 ; second
        or    a0, a0, t1                ; combined
        ld    t1, 24(t0)                ; last
        or    a0, a0, t1                ; combined
        li    a1, 0                     ; all zero
        call  chk                       ; check
        j     done                      ; print the signature and the verdict
