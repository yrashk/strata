; =============================================================================
; fw.s: Strata Firmware Interface (SFI) v1, reference library
; =============================================================================
;
; The firmware is not a resident runtime that an OS calls into through a
; table of entry points. It is a *library*: the boot ROM includes it, and so
; can any OS that wants it (the demo kernel does). An OS is free to replace
; any routine with its own. The contract is the API below plus two
; hardware facts:
;
;   * The machine describes itself in a platform table (magic "STPD") that
;     sits in device space at offset 0x1000. Every device, memory tier and
;     core count is listed there; nothing has to be probed.
;   * Devices are reached only through capabilities derived from the device
;     root capability c3 that core 0 receives at reset.
;
; Register conventions (in addition to the general calling convention):
;   gp  must hold the address of the label GPBASE, which the including
;       program defines at the start of its .data (firmware state is
;       addressed relative to it, so it may live anywhere in the D-LS)
;   c0  memory root (owned by the caller)    c2  console output (copyable)
;   c3  device root (copyable)               c9  buffer argument for block I/O
;   c10, c11  OS image (code, data) shares, used by fw_start_core
;   c12..c15  clobbered by firmware routines
;   capability table slots 62 (block device window) and 63 (console window)
;   transfer tags tg12..tg15 are used by firmware routines
;
; API summary (results in a0; t0..t6 and a0..a7 clobbered unless stated):
;   fw_init()                    read and verify the platform table; 0 or -1
;   fw_cores()                   number of cores
;   fw_ndev()                    number of platform table entries
;   fw_dev(i)                    D-LS address of entry i, or 0
;   fw_find(type, n)             D-LS address of the n-th entry of a type, or 0
;   fw_mem(space)                bytes of memory in a space (2 = T2, 3 = T3)
;   fw_describe()                print the platform inventory
;   fw_window(base, size)        c13 = capability for a device-space window
;   fw_blk_open(entry)           open a block device; 0 or -1
;   fw_blk_blocks()              capacity of the open block device, in blocks
;   fw_blk_read(lba, n, off)     read n blocks into c9 at offset off; status
;   fw_blk_write(lba, n, off)    write n blocks from c9 at offset off; status
;   fw_getc()                    next console input byte (blocks; 4 = end)
;   fw_puts(addr, len)           print len bytes from D-LS
;   fw_putc(ch), fw_putnl(), fw_putdec(v), fw_puthex(v)
;   fw_start_core(core)          give a core the OS image shares and c3
;
; Platform table layout: see common/platform.h. Entry types:
;   1 memory, 2 console, 3 platform table, 4 block device, 5 framebuffer
;   (PT_FB), 6 timer (PT_TIMER), 7 pointer (PT_POINTER), 8 network (PT_NET),
;   9 sound (PT_SOUND; only on a machine that has it).

FW_DEV_PLAT   = 0x1000                  ; device-space offset of the platform table
FW_PLAT_MAX   = 512                     ; bytes of D-LS reserved for the table
FW_CON_BASE   = 0x0000                  ; console window base
FW_CON_LEN    = 0x100                   ; console window length
FW_CON_IN     = 0x8                     ; console input port, relative to its window
FW_BLK_SQ     = 0x100                   ; submission port, relative to the block window
FW_BLK_CQ     = 0x200                   ; completion port, relative to the block window
FW_SLOT_BLK   = 62                      ; capability-table slot for the block window
FW_SLOT_CON   = 63                      ; capability-table slot for the console window
FW_MAGIC_PLAT = 0x44505453              ; "STPD" read as a little-endian 32-bit word
FW_MAGIC_BLK  = 0x44425453              ; "STBD"

        .data                           ; firmware state lives in the caller's D-LS
        .align 8                        ; transfer buffers must be 8-byte aligned
fw_plat:   .space FW_PLAT_MAX           ; copy of the platform table
fw_cmd:    .space 32                    ; block-device command being built
fw_cqe:    .space 16                    ; last completion entry read
fw_ident:  .space 64                    ; block-device identify data
fw_blk_node: .dword 0                   ; cgive node number of the open block device
fw_blk_cap:  .dword 0                   ; its capacity in blocks
fw_cid:    .dword 0                     ; command identifier counter
fw_inch:   .space 8                     ; console input byte
fw_outch:  .space 8                     ; console output byte for fw_putc
fw_num:    .space 24                    ; digit buffer for number printing
fw_num_end:                             ; one past the digit buffer
fw_hex:    .ascii "0123456789abcdef"    ; hex digit table
fw_tnames: .ascii "?        memory   console  platform block    fb       timer    pointer  net      sound    "
                                        ; entry type names, 9 characters each, by type number
fw_s_hdr:  .ascii "platform: "          ; text used by fw_describe
fw_s_hdr_e:
fw_s_cores: .ascii " cores, "           ; text after the core count
fw_s_cores_e:
fw_s_ent:  .ascii " entries\n"          ; text after the entry count
fw_s_ent_e:
fw_s_ind:  .ascii "  "                  ; indent for each entry line
fw_s_sp:   .ascii " space "             ; label before the space number
fw_s_sp_e:
fw_s_base: .ascii " base "              ; label before the base
fw_s_base_e:
fw_s_size: .ascii " size "              ; label before the size
fw_s_size_e:
fw_s_info: .ascii " info "              ; label before the info word
fw_s_info_e:

        .text                           ; firmware code, part of the caller's I-LS image

; -----------------------------------------------------------------------------
; fw_window(a0 = base, a1 = size) -> c13 = device-space capability [base, base+size)
; Cut from a copy of the device root c3 (which is copyable).
; -----------------------------------------------------------------------------
fw_window:
        cmov  c12, c3                   ; c12 = a copy of the device root (c3 keeps its own)
        csplit c13, c12, a0             ; c12 = [0, base), c13 = [base, end)
        csplit c14, c13, a1             ; c13 = [base, base + size), c14 = the remainder
        cclear c12                      ; drop the pieces we do not need
        cclear c14                      ; (copyable caps: nothing is lost)
        ret                             ; result in c13

; -----------------------------------------------------------------------------
; fw_init() -> a0 = 0 if the platform table is valid, -1 otherwise
; -----------------------------------------------------------------------------
fw_init:
        addi  sp, sp, -8                ; room for the return address
        sd    ra, 0(sp)                 ; save it
        li    a0, FW_DEV_PLAT           ; window base: the platform table
        li    a1, FW_PLAT_MAX           ; window size: generous upper bound
        call  fw_window                 ; c13 = platform table window
        la    t0, fw_plat               ; t0 = D-LS copy of the table
        li    t1, 32                    ; first read just the 32-byte header
        tget  tg14, t0, c13, zero, t1   ; header -> D-LS
        lwu   t2, 12(t0)                ; t2 = total table length (load waits for the header)
        li    t3, FW_PLAT_MAX           ; bound it by our buffer
        bltu  t3, t2, fi_bad            ; a table larger than the buffer is rejected
        tget  tg14, t0, c13, zero, t2   ; now read the whole table
        lwu   t3, 0(t0)                 ; t3 = magic
        li    t4, FW_MAGIC_PLAT         ; expected "STPD"
        bne   t3, t4, fi_bad            ; wrong magic: not a platform table
        li    t5, 0                     ; t5 = byte sum
        li    t6, 0                     ; t6 = byte index
fi_sum:
        add   t3, t0, t6                ; t3 = address of the byte
        lbu   t3, 0(t3)                 ; t3 = the byte
        addi  t4, t6, -16               ; t4 = index relative to the checksum field
        sltiu t4, t4, 4                 ; t4 = 1 if the byte is part of the checksum field
        bnez  t4, fi_skip               ; those bytes count as zero
        add   t5, t5, t3                ; add the byte
fi_skip:
        addi  t6, t6, 1                 ; next byte
        bltu  t6, t2, fi_sum            ; over the whole table
        slli  t5, t5, 32                ; keep the low 32 bits of the sum:
        srli  t5, t5, 32                ;   shift out and back
        lwu   t3, 16(t0)                ; t3 = stored checksum
        bne   t3, t5, fi_bad            ; mismatch: corrupted table
        li    a0, FW_CON_BASE           ; console window base
        li    a1, FW_CON_LEN            ; console window size
        call  fw_window                 ; c13 = console window (output and input ports)
        csave c13, FW_SLOT_CON          ; keep it in the capability table for fw_getc
        li    a0, 0                     ; success
        j     fi_ret                    ; return
fi_bad:
        li    a0, -1                    ; failure
fi_ret:
        cclear c13                      ; do not leave a window lying around in c13
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; release the slot
        ret                             ; done

; -----------------------------------------------------------------------------
; Table queries
; -----------------------------------------------------------------------------
fw_cores:
        lhu   a0, fw_plat+10-GPBASE(gp)      ; header field: number of cores
        ret                             ; done

fw_ndev:
        lhu   a0, fw_plat+8-GPBASE(gp)       ; header field: number of entries
        ret                             ; done

fw_dev:                                 ; a0 = entry index
        lhu   t0, fw_plat+8-GPBASE(gp)       ; t0 = number of entries
        bgeu  a0, t0, fd_none           ; out of range
        slli  a0, a0, 5                 ; a0 = index * 32
        la    t0, fw_plat+32            ; t0 = first entry
        add   a0, t0, a0                ; a0 = address of the entry
        ret                             ; done
fd_none:
        li    a0, 0                     ; no such entry
        ret                             ; done

fw_find:                                ; a0 = type, a1 = index among that type
        lhu   t0, fw_plat+8-GPBASE(gp)       ; t0 = entries left to look at
        la    t1, fw_plat+32            ; t1 = current entry
ff_loop:
        beqz  t0, ff_none               ; ran out of entries
        lhu   t2, 0(t1)                 ; t2 = entry type
        lhu   t3, 2(t1)                 ; t3 = entry index
        bne   t2, a0, ff_next           ; wrong type
        bne   t3, a1, ff_next           ; wrong instance
        mv    a0, t1                    ; found: return its address
        ret                             ; done
ff_next:
        addi  t1, t1, 32                ; next entry
        addi  t0, t0, -1                ; one fewer to look at
        j     ff_loop                   ; continue
ff_none:
        li    a0, 0                     ; not found
        ret                             ; done

fw_mem:                                 ; a0 = space number
        lhu   t0, fw_plat+8-GPBASE(gp)       ; t0 = entries left
        la    t1, fw_plat+32            ; t1 = current entry
fm_loop:
        beqz  t0, fm_none               ; not found
        lhu   t2, 0(t1)                 ; t2 = type
        lhu   t3, 4(t1)                 ; t3 = space
        addi  t2, t2, -1                ; type 1 (memory) becomes 0
        bnez  t2, fm_next               ; not a memory entry
        bne   t3, a0, fm_next           ; different space
        ld    a0, 24(t1)                ; size in bytes
        ret                             ; done
fm_next:
        addi  t1, t1, 32                ; next entry
        addi  t0, t0, -1                ; one fewer
        j     fm_loop                   ; continue
fm_none:
        li    a0, 0                     ; no such memory
        ret                             ; done

; -----------------------------------------------------------------------------
; fw_describe(): print the platform inventory, one line per entry
; -----------------------------------------------------------------------------
fw_describe:
        addi  sp, sp, -24               ; room for ra, s0, s1
        sd    ra, 0(sp)                 ; save ra
        sd    s0, 8(sp)                 ; save s0 (callee-saved, we use it)
        sd    s1, 16(sp)                ; save s1
        la    a0, fw_s_hdr              ; "platform: "
        li    a1, fw_s_hdr_e - fw_s_hdr ; length
        call  fw_puts                   ; print
        call  fw_cores                  ; a0 = core count
        call  fw_putdec                 ; print it
        la    a0, fw_s_cores            ; " cores, "
        li    a1, fw_s_cores_e - fw_s_cores ; length
        call  fw_puts                   ; print
        call  fw_ndev                   ; a0 = entry count
        mv    s0, a0                    ; s0 = entries left
        call  fw_putdec                 ; print the count
        la    a0, fw_s_ent              ; " entries\n"
        li    a1, fw_s_ent_e - fw_s_ent ; length
        call  fw_puts                   ; print
        la    s1, fw_plat+32            ; s1 = current entry
fdsc_loop:
        beqz  s0, fdsc_done             ; all entries printed
        la    a0, fw_s_ind              ; indent
        li    a1, 2                     ; two spaces
        call  fw_puts                   ; print
        lhu   t0, 0(s1)                 ; t0 = type
        sltiu t1, t0, 10                ; known types are 1..9
        bnez  t1, fdsc_known            ; keep known types
        li    t0, 0                     ; unknown types print as "?"
fdsc_known:
        li    t1, 9                     ; name width
        mul   t0, t0, t1                ; t0 = offset of the name
        la    a0, fw_tnames             ; name table
        add   a0, a0, t0                ; this type's name
        li    a1, 9                     ; 9 characters
        call  fw_puts                   ; print the type name
        lhu   a0, 2(s1)                 ; instance index
        call  fw_putdec                 ; print it
        la    a0, fw_s_sp               ; " space "
        li    a1, fw_s_sp_e - fw_s_sp   ; length
        call  fw_puts                   ; print
        lhu   a0, 4(s1)                 ; space number
        call  fw_putdec                 ; print it
        la    a0, fw_s_base             ; " base "
        li    a1, fw_s_base_e - fw_s_base ; length
        call  fw_puts                   ; print
        ld    a0, 16(s1)                ; base
        call  fw_puthex                 ; print in hex
        la    a0, fw_s_size             ; " size "
        li    a1, fw_s_size_e - fw_s_size ; length
        call  fw_puts                   ; print
        ld    a0, 24(s1)                ; size
        call  fw_putdec                 ; print in decimal
        la    a0, fw_s_info             ; " info "
        li    a1, fw_s_info_e - fw_s_info ; length
        call  fw_puts                   ; print
        ld    a0, 8(s1)                 ; type-specific info (block count for disks)
        call  fw_putdec                 ; print it
        call  fw_putnl                  ; end the line
        addi  s1, s1, 32                ; next entry
        addi  s0, s0, -1                ; one fewer
        j     fdsc_loop                 ; continue
fdsc_done:
        ld    s1, 16(sp)                ; restore s1
        ld    s0, 8(sp)                 ; restore s0
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; -----------------------------------------------------------------------------
; fw_blk_open(a0 = platform entry of a block device) -> a0 = 0 or -1
; -----------------------------------------------------------------------------
fw_blk_open:
        addi  sp, sp, -16               ; room for ra and the entry pointer
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; save the entry
        lhu   t0, 6(a0)                 ; t0 = cgive node number of the device
        sd    t0, fw_blk_node-GPBASE(gp)     ; remember it
        ld    a1, 24(a0)                ; window size
        ld    a0, 16(a0)                ; window base
        call  fw_window                 ; c13 = the device's window
        la    t0, fw_ident              ; t0 = identify buffer
        li    t1, 64                    ; identify data is 64 bytes
        tget  tg14, t0, c13, zero, t1   ; read the identify ROM at window offset 0
        csave c13, FW_SLOT_BLK          ; keep the window in the capability table
        lwu   t1, 0(t0)                 ; t1 = magic (waits for the identify data)
        li    t2, FW_MAGIC_BLK          ; expected "STBD"
        bne   t1, t2, fbo_bad           ; not a block device we understand
        ld    t1, 8(t0)                 ; t1 = capacity in blocks
        sd    t1, fw_blk_cap-GPBASE(gp)      ; remember it
        li    a0, 0                     ; success
        j     fbo_ret                   ; return
fbo_bad:
        li    a0, -1                    ; failure
fbo_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

fw_blk_blocks:
        ld    a0, fw_blk_cap-GPBASE(gp)      ; capacity recorded by fw_blk_open
        ret                             ; done

; -----------------------------------------------------------------------------
; fw_blk_read / fw_blk_write(a0 = lba, a1 = blocks, a2 = byte offset in c9)
; -> a0 = status (0 ok, 1 bad op, 2 bad lba, 3 bad range, 4 bad capability)
;
; The command goes to the submission port; then the buffer capability c9 is
; *given* to the device. While the device owns it, nothing else can touch the
; buffer, which is DMA protection by construction. The device gives it back
; when the I/O is done, so `ctake` doubles as "wait for completion".
; -----------------------------------------------------------------------------
fw_blk_read:
        li    a3, 1                     ; opcode 1 = read
        j     fw_blk_io                 ; shared path
fw_blk_write:
        li    a3, 2                     ; opcode 2 = write
fw_blk_io:
        crestore c13, FW_SLOT_BLK       ; c13 = block-device window (a copy; the slot keeps it)
        la    t0, fw_cmd                ; t0 = command buffer
        sb    a3, 0(t0)                 ; byte 0: opcode
        csrr  t1, coreid                ; t1 = this core
        sb    t1, 1(t0)                 ; byte 1: core to return the buffer to
        ld    t1, fw_cid-GPBASE(gp)          ; t1 = previous command id
        addi  t1, t1, 1                 ; next id
        sd    t1, fw_cid-GPBASE(gp)          ; remember it
        sh    t1, 2(t0)                 ; bytes 2-3: command id
        sw    a1, 4(t0)                 ; bytes 4-7: block count
        sd    a0, 8(t0)                 ; bytes 8-15: first block (LBA)
        sd    a2, 16(t0)                ; bytes 16-23: byte offset within the buffer capability
        sd    zero, 24(t0)              ; bytes 24-31: reserved
        li    t1, FW_BLK_SQ             ; t1 = submission port
        li    t2, 32                    ; t2 = command size
        tput  tg14, t0, c13, t1, t2     ; submit the command
        ld    t1, fw_blk_node-GPBASE(gp)     ; t1 = device node
        cgive c9, t1                    ; hand the buffer to the device (waits for the tput)
        ctake c9, t1                    ; wait for it to come back, from the device only: done
        la    t0, fw_cqe                ; t0 = completion buffer
        li    t1, FW_BLK_CQ             ; t1 = completion port
        li    t2, 16                    ; t2 = entry size
        tget  tg14, t0, c13, t1, t2     ; read the completion entry
        lhu   a0, 2(t0)                 ; a0 = status (waits for the entry)
        cclear c13                      ; drop the window copy
        ret                             ; done

; -----------------------------------------------------------------------------
; Console
; -----------------------------------------------------------------------------
fw_getc:                                ; -> a0 = next input byte (4 at end of input)
        crestore c13, FW_SLOT_CON       ; c13 = console window
        la    t0, fw_inch               ; t0 = one-byte buffer
        li    t1, FW_CON_IN             ; t1 = input port
        li    t2, 1                     ; one byte
        tget  tg13, t0, c13, t1, t2     ; read it (the device holds the transfer until a byte arrives)
        lbu   a0, 0(t0)                 ; a0 = the byte (waits for the transfer)
        cclear c13                      ; drop the window copy
        ret                             ; done

fw_puts:                                ; a0 = D-LS address, a1 = length
        tput  tg15, a0, c2, zero, a1    ; send to the console output port
        ret                             ; no need to wait

fw_putc:                                ; a0 = character
        la    t0, fw_outch              ; t0 = one-byte buffer
        sb    a0, 0(t0)                 ; store the character (waits if the last putc still reads it)
        li    t1, 1                     ; one byte
        tput  tg15, t0, c2, zero, t1    ; send it
        ret                             ; done

fw_putnl:
        li    a0, '\n'                  ; newline character
        j     fw_putc                   ; print it

fw_putdec:                              ; a0 = unsigned value
        la    t0, fw_num_end            ; t0 = cursor, one past the buffer
        li    t1, 10                    ; divisor
fpd_loop:
        remu  t2, a0, t1                ; lowest digit
        divu  a0, a0, t1                ; drop it
        addi  t2, t2, '0'               ; to ASCII
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store
        bnez  a0, fpd_loop              ; while digits remain
        mv    a0, t0                    ; first character
        la    t1, fw_num_end            ; end
        sub   a1, t1, t0                ; length
        j     fw_puts                   ; print

fw_puthex:                              ; a0 = value, printed as 0x + 16 digits
        la    t0, fw_num_end            ; cursor
        la    t3, fw_hex                ; digit table
        li    t1, 16                    ; digits to produce
fph_loop:
        andi  t2, a0, 15                ; low nibble
        add   t2, t3, t2                ; its character's address
        lbu   t2, 0(t2)                 ; the character
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store
        srli  a0, a0, 4                 ; next nibble
        addi  t1, t1, -1                ; one fewer
        bnez  t1, fph_loop              ; 16 digits
        li    t2, 'x'                   ; 'x'
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store
        li    t2, '0'                   ; '0'
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store
        mv    a0, t0                    ; start
        li    a1, 18                    ; 18 characters
        j     fw_puts                   ; print

; -----------------------------------------------------------------------------
; fw_start_core(a0 = core): give a secondary core what its boot ROM waits
; for, in this order: the OS code share (c10), the OS data share (c11), and a
; copy of the device root (c3). All three are copyable, so we keep ours.
; -----------------------------------------------------------------------------
fw_start_core:
        cgive c10, a0                   ; code image
        cgive c11, a0                   ; data image
        cgive c3, a0                    ; device root
        ret                             ; done
