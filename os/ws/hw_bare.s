; =============================================================================
; hw_bare.s: the window server's machine layer, bare-metal edition
; =============================================================================
;
; The renderers never touch a device: they draw into surface descriptors
; (gfx.s) and ask this layer to present a frame, wait for a refresh or read
; the clock. This file is the bare-metal version (the demo owns the whole
; machine: core 0's boot capabilities). The StrataOS `ws` replaces it with
; one that gets the same capabilities from the kernel's servers (GRANT_FB
; for the framebuffer window and the controller, the clock from c7) and
; keeps every routine's contract.
;
;   hw_init() -> a0 = 0, or 1 if there is no XRGB8888 framebuffer
;       fills hw_fb (the screen's surface descriptor) and hw_pool (system
;       memory for client surfaces), and sets up the capabilities:
;         c0 = [0, 16 MiB) (unused here)    c5 = [16, 48) MiB: the pool
;         c6 = the framebuffer window       c3 = the device root (kept)
;   hw_present()            PRESENT: "this frame is complete"
;   hw_vsync_issue()        start a VSYNC read on tg12 (tany on bit 12)
;   hw_vsync_wait()         wait for it; a0 = frame number
;   hw_now() -> a0          timer NOW (microseconds)
;   hw_key_issue()          start a one-byte console read on tg11
;   hw_key_get() -> a0      the byte (after tg11 completed)
;
; Tags: tg11 keyboard, tg12 VSYNC, tg13 device registers.

HW_PT_FB  = 5                           ; platform table entry: framebuffer
HW_PLAT   = 0x1000                      ; device offset of the platform table
HW_PLATMAX = 512                        ; bytes of it we read
HW_FBCTL  = 0x4000                      ; framebuffer controller: PRESENT
HW_VSYNC  = 0x4008                      ; VSYNC
HW_NOW    = 0x3000                      ; timer NOW
HW_CONIN  = 0x08                        ; console input port
HW_POOL   = 0x1000000                   ; 16 MiB: where the surface pool starts
HW_POOLEN = 0x2000000                   ; 32 MiB of it
HW_FBCAP  = 6                           ; the framebuffer's capability register
HW_POOLCAP = 5                          ; the pool's

        .data                           ; D-LS
        .align 8                        ; dwords and transfer buffers
hw_fb:    .space S_SIZE                 ; the screen as a surface
hw_pool:  .space S_SIZE                 ; the pool as one big surface (offsets only)
hw_plat:  .space HW_PLATMAX             ; copy of the platform table
hw_reg:   .dword 0                      ; a device register (PRESENT/NOW)
hw_vsr:   .dword 0                      ; the VSYNC read lands here
hw_keyb:  .dword 0                      ; the console read lands here
        .text                           ; code

hw_init:                                ; routine entry
        la    t0, hw_plat               ; the platform table ...
        li    t1, HW_PLATMAX            ; ...
        li    t2, HW_PLAT               ; ... at its device offset
        tget  tg13, t0, c3, t2, t1      ; read it
        lhu   t2, 8(t0)                 ; t2 = number of entries (waits for the read)
        addi  t3, t0, 32                ; t3 = first entry
hi_find:                                ; loop: one entry
        beqz  t2, hi_bad                ; no framebuffer
        lhu   t4, 0(t3)                 ; type
        li    t5, HW_PT_FB              ; framebuffer?
        beq   t4, t5, hi_found          ; yes
        addi  t3, t3, 32                ; next entry
        addi  t2, t2, -1                ; one fewer
        j     hi_find                   ; continue
hi_found:
        ld    t0, 8(t3)                 ; info: width | height << 16 | stride << 32 | format << 48
        srli  t1, t0, 48                ; format
        li    t2, 1                     ; XRGB8888
        bne   t1, t2, hi_bad            ; anything else: no
        ld    t6, 16(t3)                ; t6 = framebuffer address
        la    t5, hw_fb                 ; the screen's descriptor
        li    t1, HW_FBCAP              ; its capability register
        sd    t1, S_CAP(t5)             ; ...
        sd    zero, S_OFF(t5)           ; the window starts at the framebuffer
        li    t2, 0xffff                ; 16-bit fields
        and   t1, t0, t2                ; width
        sd    t1, S_W(t5)               ; ...
        srli  t1, t0, 16                ; height
        and   t1, t1, t2                ; ...
        sd    t1, S_H(t5)               ; ...
        srli  t1, t0, 32                ; stride
        and   t1, t1, t2                ; ...
        sd    t1, S_STRIDE(t5)          ; ...
        csplit c6, c0, t6               ; c0 = below the framebuffer, c6 = it and on
        li    t1, HW_POOL               ; c0 = [0, 16 MiB), c5 = the rest below the framebuffer
        csplit c5, c0, t1               ; ...
        la    t5, hw_pool               ; the pool's descriptor
        li    t1, HW_POOLCAP            ; its register
        sd    t1, S_CAP(t5)             ; ...
        sd    zero, S_OFF(t5)           ; offsets from the start of the pool
        li    a0, 0                     ; success
        ret                             ; done
hi_bad:
        li    a0, 1                     ; no usable framebuffer
        ret                             ; done

hw_present:                             ; routine entry
        la    t0, hw_reg                ; any 8 bytes
        li    t1, 8                     ; ...
        li    t2, HW_FBCTL              ; PRESENT
        tput  tg13, t0, c3, t2, t1      ; the frame is complete
        ret                             ; done

hw_vsync_issue:                         ; routine entry
        la    t0, hw_vsr                ; lands here
        li    t1, 8                     ; 8 bytes: the frame number
        li    t2, HW_VSYNC              ; VSYNC
        tget  tg12, t0, c3, t2, t1      ; completes at the next refresh
        ret                             ; done

hw_vsync_wait:                          ; routine entry
        la    t0, hw_vsr                ; the frame number ...
        ld    a0, 0(t0)                 ; ... (this load waits for the refresh)
        ret                             ; done

hw_now:                                 ; routine entry
        la    t0, hw_reg                ; lands here
        li    t1, 8                     ; NOW
        li    t2, HW_NOW                ; ...
        tget  tg13, t0, c3, t2, t1      ; read it
        ld    a0, 0(t0)                 ; (waits for it)
        ret                             ; done

hw_key_issue:                           ; routine entry
        la    t0, hw_keyb               ; lands here
        li    t1, 1                     ; one byte
        li    t2, HW_CONIN              ; console input
        tget  tg11, t0, c3, t2, t1      ; completes when a key arrives (device root)
        ret                             ; done

hw_key_get:                             ; routine entry
        la    t0, hw_keyb               ; the byte
        lbu   a0, 0(t0)                 ; (waits for it)
        ret                             ; done
