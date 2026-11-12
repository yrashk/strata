; =============================================================================
; bootrom.s: Strata boot ROM: from reset to a running OS
; =============================================================================
;
; Every core starts here at I-LS address 0. Core 0:
;   1. reads and verifies the platform table (fw_init) and prints it;
;   2. finds and opens block device 0;
;   3. reads the boot header from block 0 and checks its magic "STBOOT01";
;   4. reads the OS code and data images, and the kernel's far image (its
;      code units), off the disk into a load area in system memory, through
;      a capability it then cuts to their exact size;
;   5. turns those into read-only shares and gives a copy of the code and
;      data shares (plus the device root) to every other core; core 0 alone
;      keeps the far image share in c12;
;   6. like every core, copies the images into its own Local Stores (code at
;      I-LS 0x4000, data at D-LS 0xA000) and jumps to the OS with a0 = core id.
; Other cores wait in step 5 for the shares, then do step 6. Before step 4
; core 0 checks that the images fit the machine's Local Stores (the platform
; table's sizes). If any step fails, core 0 prints why, gives every other
; core a copy of its console capability (not executable: "stop") and halts;
; a core whose first gift is not executable halts too. The boot ROM's stack
; is where reset put sp: the top of the D-LS.
;
; Boot header (block 0, little endian):
;    0  "STBOOT01"              24  u32 data blocks
;    8  u32 code LBA            28  u32 data D-LS address (0xA000)
;   12  u32 code blocks         32  u32 entry I-LS address (0x4000)
;   16  u32 code I-LS address   36  u32 directory LBA (used by the OS)
;   20  u32 data LBA            40  u32 first free LBA (used by the OS)
;                               44  u32 far image LBA (0 = none)
;                               48  u32 far image blocks
;                               52  u32 tag table LBA (used by fs)
;
; What the OS receives: c0 = system memory [0, 15 MiB), c1 = cluster store,
; c2 = console output, c3 = device root, c10/c11 = its own code/data shares,
; and on core 0 only c12 = a read+execute share of the far image, exactly
; [0xF30000, 0xF30000 + far bytes), c13 = more heap [16 MiB, 48 MiB) and
; c14 = the framebuffer window [48 MiB, 64 MiB) (on a 64 MiB machine). The 1 MiB load area above 15 MiB is not
; returned: it holds the OS images.

OS_TEXT = 0x4000                        ; I-LS address the OS code is loaded to
OS_DATA = 0xA000                        ; D-LS address the OS data is loaded to
LOADBASE = 0xF00000                     ; the top 1 MiB of system memory is the load area
TXT_OFF = 0x10000                       ; load-area offset for the code image
DAT_OFF = 0x20000                       ; load-area offset for the data image
FAR_OFF = 0x30000                       ; load-area offset for the far image (at most 0xD0000 bytes)
BOOT_MAGIC = 0x3130544f4f425453         ; "STBOOT01" as a little-endian 64-bit word

        .data                           ; boot ROM data, low in D-LS (the OS data goes higher)
        .align 8                        ; transfer buffers must be aligned
GPBASE:                                 ; base of our data: the firmware library addresses its state from gp
hdr:    .space 512                      ; copy of the boot header block
s_ban:  .ascii "Strata boot ROM, firmware interface v1\n" ; banner
s_ban_e:                                ; end of the text above
s_plat: .ascii "boot: platform table invalid\n" ; error messages
s_plat_e:                               ; end of the text above
s_nodisk: .ascii "boot: no block device\n"
s_nodisk_e:                             ; end of the text above
s_ioerr: .ascii "boot: disk read failed\n"
s_ioerr_e:                              ; end of the text above
s_nomag: .ascii "boot: block 0 is not bootable\n"
s_nomag_e:                              ; end of the text above
s_nofit: .ascii "boot: the OS does not fit this machine's Local Stores\n"
s_nofit_e:                              ; end of the text above
s_ls:   .ascii "  Local Stores: D-LS "  ; the Local Stores' sizes
s_ls_e:                                 ; end of the text above
s_lsi:  .ascii " KiB, I-LS "            ; ...
s_lsi_e:                                ; end of the text above
s_lsk:  .ascii " KiB per core\n"        ; ...
s_lsk_e:                                ; end of the text above
s_load: .ascii "boot: loading OS: "     ; progress message
s_load_e:                               ; end of the text above
s_blks: .ascii " code blocks, "         ; middle of the progress message
s_blks_e:                               ; end of the text above
s_fblk: .ascii " data blocks, "         ; more of the progress message
s_fblk_e:                               ; end of the text above
s_dblk: .ascii " far blocks\n"          ; end of the progress message
s_dblk_e:                               ; end of the text above
s_go:   .ascii "boot: starting cores, jumping to the OS\n\n"
s_go_e:                                 ; end of the text above

        .text                           ; boot ROM code, at I-LS address 0
_start:                                 ; (sp: the top of the D-LS, from reset)
        la    gp, GPBASE                ; gp = our data base (the firmware library needs it)
        csrr  s0, coreid                ; s0 = this core
        bnez  s0, secondary             ; only core 0 runs the boot sequence

        la    a0, s_ban                 ; banner
        li    a1, s_ban_e - s_ban       ; its length
        call  fw_puts                   ; print it
        call  fw_init                   ; read and check the platform table
        bnez  a0, bad_plat              ; -1: no valid platform table
        call  fw_describe               ; print what the machine contains
        la    a0, s_ls                  ; "  Local Stores: D-LS "
        li    a1, s_ls_e - s_ls         ; length
        call  fw_puts                   ; print
        call  ls_size                   ; a0 = D-LS bytes
        srli  a0, a0, 10                ; KiB
        call  fw_putdec                 ; print
        la    a0, s_lsi                 ; " KiB, I-LS "
        li    a1, s_lsi_e - s_lsi       ; length
        call  fw_puts                   ; print
        call  ls_size                   ; a1 = I-LS bytes
        srli  a0, a1, 10                ; KiB
        call  fw_putdec                 ; print
        la    a0, s_lsk                 ; " KiB per core\n"
        li    a1, s_lsk_e - s_lsk       ; length
        call  fw_puts                   ; print

        li    a0, 4                     ; entry type 4 = block device
        li    a1, 0                     ; the first one
        call  fw_find                   ; a0 = its platform entry, or 0
        beqz  a0, no_disk               ; none found
        call  fw_blk_open               ; open it
        bnez  a0, no_disk               ; it did not identify as a block device

        li    t0, LOADBASE              ; split point: 15 MiB
        csplit c9, c0, t0               ; c0 = [0, 15 MiB) stays for the OS, c9 = from 15 MiB on
        clen  t1, c9                    ; how much memory lies above 15 MiB?
        li    t0, 0x100000              ; the load area is 1 MiB
        bleu  t1, t0, no_high           ; a 16 MiB machine: nothing above the load area
        csplit c15, c9, t0              ; c9 = the load area, c15 = [16 MiB, end): kept for the OS
no_high:                                ; (the firmware leaves c15 alone)

        li    a0, 0                     ; block 0
        li    a1, 1                     ; one block
        li    a2, 0                     ; to load-area offset 0
        call  fw_blk_read               ; read the boot header
        bnez  a0, io_error              ; device reported an error
        la    s1, hdr                   ; s1 = D-LS copy of the header
        li    t1, 512                   ; one block
        tget  tg0, s1, c9, zero, t1     ; bring it into the Local Store
        ld    t0, 0(s1)                 ; t0 = magic (waits for the transfer)
        li    t1, BOOT_MAGIC            ; expected value
        bne   t0, t1, no_magic          ; not a boot disk
        call  ls_size                   ; a0 = D-LS bytes, a1 = I-LS bytes
        lwu   t0, 12(s1)                ; code blocks
        slli  t0, t0, 9                 ; code bytes
        li    t1, OS_TEXT               ; where they go
        add   t0, t0, t1                ; the end of the code
        bltu  a1, t0, no_fit            ; past the I-LS
        lwu   t0, 24(s1)                ; data blocks
        slli  t0, t0, 9                 ; data bytes
        li    t1, OS_DATA               ; where they go
        add   t0, t0, t1                ; the end of the data
        bltu  a0, t0, no_fit            ; past the D-LS

        la    a0, s_load                ; "boot: loading OS: "
        li    a1, s_load_e - s_load     ; length
        call  fw_puts                   ; print
        lwu   a0, 12(s1)                ; code block count
        call  fw_putdec                 ; print
        la    a0, s_blks                ; " code blocks, "
        li    a1, s_blks_e - s_blks     ; length
        call  fw_puts                   ; print
        lwu   a0, 24(s1)                ; data block count
        call  fw_putdec                 ; print
        la    a0, s_fblk                ; " data blocks, "
        li    a1, s_fblk_e - s_fblk     ; length
        call  fw_puts                   ; print
        lwu   a0, 48(s1)                ; far image block count
        call  fw_putdec                 ; print
        la    a0, s_dblk                ; " far blocks\n"
        li    a1, s_dblk_e - s_dblk     ; length
        call  fw_puts                   ; print

        lwu   a0, 8(s1)                 ; code LBA
        lwu   a1, 12(s1)                ; code blocks
        li    a2, TXT_OFF               ; load-area offset for code
        call  fw_blk_read               ; disk -> system memory (device DMA)
        bnez  a0, io_error              ; failed
        lwu   a0, 20(s1)                ; data LBA
        lwu   a1, 24(s1)                ; data blocks
        li    a2, DAT_OFF               ; load-area offset for data
        call  fw_blk_read               ; disk -> system memory
        bnez  a0, io_error              ; failed
        lwu   s4, 44(s1)                ; s4 = next far image block to read
        lwu   s5, 48(s1)                ; s5 = far image blocks left (0: none on this disk)
        li    s6, FAR_OFF               ; s6 = load-area offset for them
far_next:
        beqz  s5, no_far                ; all read
        mv    a1, s5                    ; this command's blocks ...
        li    t0, 256                   ; ... at most 256 (the device's limit per command)
        bleu  a1, t0, far_go            ; fits
        mv    a1, t0                    ; clip
far_go:
        sub   s5, s5, a1                ; blocks left after this command
        mv    a0, s4                    ; first block
        add   s4, s4, a1                ; the next command starts after these
        mv    a2, s6                    ; load-area offset
        slli  t0, a1, 9                 ; bytes in this command
        add   s6, s6, t0                ; the next offset
        call  fw_blk_read               ; disk -> system memory
        bnez  a0, io_error              ; failed
        j     far_next                  ; continue
no_far:

; ---- cut the load area into exact code, data and far capabilities -------------
        li    t0, TXT_OFF               ; offset of the code image
        csplit c10, c9, t0              ; c9 = [0, TXT_OFF), c10 = from the code image on
        lwu   t1, 12(s1)                ; code blocks
        slli  t1, t1, 9                 ; t1 = code bytes (blocks * 512)
        csplit c11, c10, t1             ; c10 = exactly the code, c11 = what follows it
        li    t0, DAT_OFF - TXT_OFF     ; distance from code start to data start
        sub   t0, t0, t1                ; t0 = size of the gap after the code
        csplit c12, c11, t0             ; c11 = the gap, c12 = from the data image on
        lwu   t1, 24(s1)                ; data blocks
        slli  t1, t1, 9                 ; t1 = data bytes
        csplit c13, c12, t1             ; c12 = exactly the data, c13 = the rest
        cclear c11                      ; drop the gap between the images (a live capability
                                        ; is never overwritten implicitly, so this is explicit)
        li    t0, FAR_OFF - DAT_OFF     ; distance from data start to far start
        sub   t0, t0, t1                ; t0 = size of the gap after the data
        csplit c14, c13, t0             ; c13 = that gap, c14 = from the far image on
        cclear c13                      ; drop the gap
        lwu   t1, 48(s1)                ; far blocks
        slli  t1, t1, 9                 ; t1 = far bytes (0 if there is no far image)
        csplit c13, c14, t1             ; c14 = exactly the far image, c13 = the rest
        cclear c13                      ; drop the unused rest of the load area
        cclear c9                       ; and the header block's piece: the load area now
                                        ; belongs to the OS images for good
        cshare c10, c10                 ; code becomes a non-writable share anyone may copy
        cshare c11, c12                 ; data becomes a non-writable share, in c11 (c12 is consumed)
        cshare c12, c14                 ; the far image: a read+execute share, in c12 (core 0 only)
        bnez  t1, far_kept              ; a far image exists: keep it
        cclear c12                      ; none: an empty share is no use to the OS
far_kept:
        cvalid t0, c15                  ; memory above 16 MiB?
        beqz  t0, high_done             ; no
        li    t0, 0x2000000             ; [16 MiB, 48 MiB) is more heap,
        clen  t1, c15                   ; (if the machine has that much)
        bleu  t1, t0, high_heap         ; ...
        csplit c14, c15, t0             ; c15 = [16, 48) MiB, c14 = the framebuffer window [48, 64) MiB
high_heap:
        cmov  c13, c15                  ; c13 = the second piece of heap
high_done:

        la    a0, s_go                  ; "starting cores"
        li    a1, s_go_e - s_go         ; length
        call  fw_puts                   ; print
        call  fw_cores                  ; a0 = number of cores
        mv    s2, a0                    ; s2 = core count
        li    s3, 1                     ; s3 = next core to start
start_next:
        bge   s3, s2, load_and_go       ; all secondary cores started
        mv    a0, s3                    ; which core
        call  fw_start_core             ; give it the code share, data share, device root
        addi  s3, s3, 1                 ; next core
        j     start_next                ; continue

; ---- secondary cores: wait for the images ---------------------------------------
secondary:
        ctake c10                       ; OS code share
        cperms t0, c10                  ; or core 0's "stop": not executable
        andi  t0, t0, 4                 ; X
        beqz  t0, sec_stop              ; stop
        ctake c11                       ; OS data share
        ctake c3                        ; device root

; ---- every core: copy the OS into its own Local Stores and jump --------------------
load_and_go:
        li    t0, OS_TEXT               ; destination in the I-LS
        clen  t1, c10                   ; code size
        tgetx tg0, t0, c10, zero, t1    ; system memory -> instruction Local Store
        li    t0, OS_DATA               ; destination in the D-LS
        clen  t1, c11                   ; data size
        tget  tg1, t0, c11, zero, t1    ; system memory -> data Local Store
                                        ; no wait needed: fetching or loading in-flight bytes stalls
        csrr  a0, coreid                ; the OS gets the core id in a0
        li    sp, 0                     ; the OS sets up its own stack
        li    t0, OS_TEXT               ; entry point
        jr    t0                        ; leave the boot ROM

; ---- failures -------------------------------------------------------------------------
bad_plat:
        la    a0, s_plat                ; "platform table invalid"
        li    a1, s_plat_e - s_plat     ; length
        j     fail                      ; report
no_disk:
        la    a0, s_nodisk              ; "no block device"
        li    a1, s_nodisk_e - s_nodisk ; length
        j     fail                      ; report
io_error:
        la    a0, s_ioerr               ; "disk read failed"
        li    a1, s_ioerr_e - s_ioerr   ; length
        j     fail                      ; report
no_magic:
        la    a0, s_nomag               ; "not bootable"
        li    a1, s_nomag_e - s_nomag   ; length
        j     fail                      ; report
no_fit:
        la    a0, s_nofit               ; "the OS does not fit"
        li    a1, s_nofit_e - s_nofit   ; length
fail:
        call  fw_puts                   ; print the message
        csrr  s2, ncores                ; every other core waits for its first gift:
        li    s3, 1                     ;   a copy of the console capability says stop
fail_stop:
        bge   s3, s2, fail_halt         ; all told
        cgive c2, s3                    ; (copyable: c2 stays)
        addi  s3, s3, 1                 ; next core
        j     fail_stop                 ; ...
fail_halt:
        li    a0, 1                     ; exit code 1
        halt                            ; stop this core
sec_stop:
        li    a0, 1                     ; core 0 could not boot
        halt                            ; stop this core

; ls_size() -> a0 = D-LS bytes, a1 = I-LS bytes: the platform table header's
; u16 KiB at 24 and 26 (0 in an older table: 64 KiB)
ls_size:
        lhu   a0, fw_plat+24-GPBASE(gp) ; D-LS KiB
        bnez  a0, lss_d                 ; ...
        li    a0, 64                    ; ...
lss_d:
        slli  a0, a0, 10                ; bytes
        lhu   a1, fw_plat+26-GPBASE(gp) ; I-LS KiB
        bnez  a1, lss_i                 ; ...
        li    a1, 64                    ; ...
lss_i:
        slli  a1, a1, 10                ; bytes
        ret                             ; done

        .include "fw.s"                 ; the firmware library
