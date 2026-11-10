; =============================================================================
; gfx.s: a Mandelbrot set in colour, every core painting its own band
; =============================================================================
;
; What it shows
;   * The framebuffer is ordinary system memory. The platform table (entry
;     type 5) says where it is and what shape the display has: width, height,
;     bytes per row (the stride) and pixel format (1: 4 bytes per pixel,
;     blue, green, red, unused). The program draws whatever size it is told;
;     nothing about the screen is built in (try `strata-emu -r 640x480`).
;   * Sharing a read-only capability. Core 0 cuts a window onto the platform
;     table out of its device root, takes away the write permission and gives
;     every other core a copy, so each core reads the geometry itself.
;   * Ownership again does the synchronisation. Core 0 cuts the visible part
;     of the framebuffer out of its memory capability, `csplit`s it into one
;     band of rows per core and gives each band away. A core can write only
;     its own band. When it is done it gives the band back; `cgive` completes
;     only after the core's own transfers into it have landed, so once core 0
;     has every band back, the picture in memory is complete.
;   * Showing it is one device write. Core 0 writes the framebuffer
;     controller's PRESENT port (device space 0x4000): "this frame is
;     complete" (the simulators' window scans the framebuffer memory out
;     live, opening at the first write into it, so the bands appear as they
;     are drawn; PRESENT refreshes it at once and is the frame -F captures).
;     Reading VSYNC (0x4008) is a transfer that completes at the
;     next 60 Hz refresh, so waiting for the display is waiting for a transfer.
;   * Overlapping work and transfers. Each core renders a row of the picture
;     into one of two D-LS buffers while the previous row is still being
;     written out from the other one.
;
; The picture is computed at half the resolution and each point painted as
; a 2 x 2 block of pixels (with an odd height the last pixel row stays
; black). Arithmetic is fixed point with 24 fractional bits.
;
; Expected output (lines starting with '@' contain frame numbers, which
; depend on time):
;   framebuffer: 1280 x 800, 5120 bytes per row, format 1, at 0x0000000003000000
;   rendered by 8 cores; presented, waited for 3 refreshes
;   @ refresh 0000000012 ...

PT_FB   = 5                             ; platform table entry type of a framebuffer
PLAT    = 0x1000                        ; device-space offset of the platform table
PLATMAX = 512                           ; bytes of D-LS set aside for the table
FBCTL   = 0x4000                        ; device-space offset of the framebuffer controller
R_VSYNC = 0x08                          ; its VSYNC port (PRESENT is at offset 0)
FORMAT  = 1                             ; the only pixel format we know: XRGB8888
MAXSTRIDE = 10240                       ; bytes per row of the widest display (2560 pixels)
FRAC    = 24                            ; fixed-point fraction bits
MAXIT   = 64                            ; iteration limit
NVSYNC  = 3                             ; refreshes to wait for after presenting
P_RD    = 0x11                          ; permissions R (1) and D (16): read-only, copyable

        .data                           ; data Local Store (one per core)
        .align 8                        ; transfer buffers must be 8-byte aligned
rowbuf: .space 2 * MAXSTRIDE            ; two row buffers, used in turn
plat:   .space PLATMAX                  ; copy of the platform table
reg:    .space 8                        ; core 0: a device register
g_d:    .dword 0                        ; geometry, filled in by geometry(): step between points
g_x0:   .dword 0                        ; cx of the left edge
g_y0:   .dword 0                        ; cy of the top edge
g_cw:   .dword 0                        ; points per row (width / 2)
g_ch:   .dword 0                        ; rows of points (height / 2)
g_stride: .dword 0                      ; bytes per pixel row
g_base: .dword 0                        ; framebuffer address in system memory
g_info: .dword 0                        ; the entry's info word
pal:    .word 0x421e0f, 0x19071a, 0x09012f, 0x040449 ; 16 colours (0x00RRGGBB, stored B, G, R, 0):
        .word 0x000764, 0x0c2c8a, 0x1852b1, 0x397dd1 ;   from deep blue through white
        .word 0x86b5e5, 0xd3ecf8, 0xf1e9bf, 0xf8c95f ;   to gold and brown; the escape
        .word 0xffaa00, 0xcc8000, 0x995700, 0x6a3403 ;   time picks one, cycling
m_fb:   .ascii "framebuffer: "          ; message pieces follow, each with an end label
m_fb_e:                                 ; end of the text above
m_x:    .ascii " x "                    ; between width and height
m_x_e:                                  ; end of the text above
m_st:   .ascii ", "                     ; before the stride
m_st_e:                                 ; end of the text above
m_st2:  .ascii " bytes per row, format " ; after the stride
m_st2_e:                                ; end of the text above
m_at:   .ascii ", at "                  ; before the address
m_at_e:                                 ; end of the text above
m_by:   .ascii "rendered by "           ; the summary line
m_by_e:                                 ; end of the text above
m_by2:  .ascii " cores; presented, waited for 3 refreshes\n" ; its end
m_by2_e:                                ; end of the text above
m_vs:   .ascii "@ refresh "             ; '@': a line with a frame number in it
m_vs_e:                                 ; end of the text above
m_bad:  .ascii "no XRGB8888 framebuffer here\n" ; for other machines
m_bad_e:                                ; end of the text above

        .text                           ; instruction Local Store
_start:
        li    sp, 65536                 ; stack at the top of D-LS
        csrr  s0, coreid                ; s0 = core number
        csrr  s7, ncores                ; s7 = number of cores
        bnez  s0, others                ; the other cores wait for their capabilities

; ---- core 0: a read-only window onto the platform table, for everyone ----------
        cmov  c8, c3                    ; c8 = a copy of the device root (it is copyable)
        li    t0, PLAT                  ; where the platform table starts
        csplit c9, c8, t0               ; c8 = [0, PLAT), c9 = [PLAT, end)
        li    t0, PLATMAX               ; the part we read
        csplit c10, c9, t0              ; c9 = the table window, c10 = the rest
        cclear c8                       ; drop the pieces we do not need
        cclear c10                      ; (copies of a copyable capability: nothing is lost)
        li    t0, P_RD                  ; keep only "read" and "copyable"
        crestrict c9, c9, t0            ; c9 can no longer write to device space
        li    s8, 1                     ; s8 = next core to give a copy to
share:
        bge   s8, s7, shared            ; every core has one
        cgive c9, s8                    ; a copy for core s8 (c9 is copyable: we keep ours)
        addi  s8, s8, 1                 ; next core
        j     share                     ; continue
shared:
        call  geometry                  ; read the table: framebuffer address and shape
        bnez  a0, bad                   ; not a framebuffer we can draw on
        la    a0, m_fb                  ; "framebuffer: "
        li    a1, m_fb_e - m_fb         ; length
        call  print_str                 ; print it
        la    s1, g_info                ; s1 = the info word
        ld    a0, 0(s1)                 ; width = bits 0..15
        andi  a0, a0, 0xffff            ; keep them
        call  print_dec                 ; print it
        la    a0, m_x                   ; " x "
        li    a1, m_x_e - m_x           ; length
        call  print_str                 ; print it
        ld    a0, 0(s1)                 ; height = bits 16..31
        srli  a0, a0, 16                ; down to bit 0
        andi  a0, a0, 0xffff            ; keep 16 bits
        call  print_dec                 ; print it
        la    a0, m_st                  ; ", "
        li    a1, m_st_e - m_st         ; length
        call  print_str                 ; print it
        la    t0, g_stride              ; the stride
        ld    a0, 0(t0)                 ; load it
        call  print_dec                 ; print it
        la    a0, m_st2                 ; " bytes per row, format "
        li    a1, m_st2_e - m_st2       ; length
        call  print_str                 ; print it
        ld    a0, 0(s1)                 ; the format = bits 48..63
        srli  a0, a0, 48                ; down to bit 0
        call  print_dec                 ; print it
        la    a0, m_at                  ; ", at "
        li    a1, m_at_e - m_at         ; length
        call  print_str                 ; print it
        la    t0, g_base                ; the address
        ld    a0, 0(t0)                 ; load it
        call  print_hex                 ; print it
        call  print_nl                  ; end the line

; ---- core 0: cut out the framebuffer and deal it out in bands ------------------
        la    t0, g_base                ; framebuffer address
        ld    s2, 0(t0)                 ; s2 = it
        la    t0, g_stride              ; stride
        ld    s4, 0(t0)                 ; s4 = it
        la    t0, g_info                ; info word
        ld    t1, 0(t0)                 ; t1 = it
        srli  t1, t1, 16                ; height ...
        andi  t1, t1, 0xffff            ; ... in t1
        mul   s3, t1, s4                ; s3 = height * stride: the part the display shows
        csplit c6, c0, s2               ; c0 = memory below the framebuffer, c6 = from it on
        csplit c7, c6, s3               ; c6 = exactly the visible framebuffer, c7 = what follows
        call  band_rows                 ; a0 = rows of points per core
        slli  t1, s4, 1                 ; bytes per row of points (two pixel rows)
        mul   s9, a0, t1                ; s9 = bytes per band
        bleu  s9, s3, band0             ; a band never exceeds the framebuffer
        mv    s9, s3                    ; (with one core: the band is all of it)
band0:
        csplit c5, c6, s9               ; c6 = band 0, c5 = the rest of the framebuffer
        li    s8, 1                     ; s8 = next core to hand a band to
give:
        bge   s8, s7, mine              ; every core has its band
        clen  t1, c5                    ; t1 = bytes still unassigned
        mv    t2, s9                    ; t2 = a full band ...
        bleu  t2, t1, give_cut          ; ... if that much is left
        mv    t2, t1                    ; otherwise whatever is left (possibly nothing)
give_cut:
        csplit c8, c5, t2               ; c5 = this core's band, c8 = the rest
        cgive c5, s8                    ; core s8 owns it now (c5 becomes empty)
        cmov  c5, c8                    ; the rest moves back into c5
        addi  s8, s8, 1                 ; next core
        j     give                      ; continue
mine:
        cclear c5                       ; the empty remainder: discard it
        cmov  c4, c6                    ; render() draws through c4
        j     draw                      ; draw our own band
others:
        ctake c9, zero                  ; the platform table window, from core 0 only
        ctake c4, zero                  ; then our band (gifts from one sender arrive in order)
        call  geometry                  ; the same geometry core 0 sees
draw:
        call  band_rows                 ; a0 = rows of points per core
        mul   a0, s0, a0                ; a0 = first row of points of this core
        clen  t0, c4                    ; t0 = bytes in our band
        la    t1, g_stride              ; bytes per pixel row
        ld    t1, 0(t1)                 ; load it
        slli  t1, t1, 1                 ; bytes per row of points
        divu  a1, t0, t1                ; a1 = rows of points in our band
        call  render                    ; draw them
        bnez  s0, give_back             ; the other cores return their band

; ---- core 0: collect the bands in order, then show the picture -----------------
        csrr  s7, ncores                ; s7 = number of cores (render used the s registers)
        li    s8, 1                     ; s8 = next core to collect from
collect:
        bge   s8, s7, show              ; all bands are back
        ctake c5, s8                    ; band of core s8 (its rows have all landed)
        cjoin c4, c5                    ; append it: c4 grows back into the whole framebuffer
        addi  s8, s8, 1                 ; next core
        j     collect                   ; continue
show:
        cmov  c8, c3                    ; a copy of the device root
        li    t0, FBCTL                 ; the framebuffer controller's offset
        csplit c9, c8, t0               ; c8 = [0, FBCTL), c9 = [FBCTL, end)
        li    t0, 16                    ; its two 8-byte ports
        csplit c10, c9, t0              ; c9 = the controller's window, c10 = the rest
        cclear c8                       ; drop the pieces
        cclear c10                      ; we keep only c9
        la    s1, reg                   ; s1 = an 8-byte buffer (its contents do not matter)
        li    t1, 8                     ; 8 bytes
        tput  tg0, s1, c9, zero, t1     ; PRESENT: the display now shows the framebuffer
        la    a0, m_by                  ; "rendered by "
        li    a1, m_by_e - m_by         ; length
        call  print_str                 ; print it
        mv    a0, s7                    ; core count
        call  print_dec                 ; print it
        la    a0, m_by2                 ; the rest of the line
        li    a1, m_by2_e - m_by2       ; length
        call  print_str                 ; print it
        li    s8, NVSYNC                ; s8 = refreshes left to wait for
vsync:
        li    t0, R_VSYNC               ; the VSYNC port
        li    t1, 8                     ; 8 bytes: the frame number
        tget  tg1, s1, c9, t0, t1       ; completes at the next refresh
        la    a0, m_vs                  ; "@ refresh "
        li    a1, m_vs_e - m_vs         ; length
        call  print_str                 ; print it (meanwhile the read may still be waiting)
        ld    a0, 0(s1)                 ; a0 = the frame number: this load waits for the refresh
        call  print_dec10               ; always 10 digits: the same instructions whatever the value
        call  print_nl                  ; end the line
        addi  s8, s8, -1                ; one fewer
        bnez  s8, vsync                 ; until we have seen NVSYNC refreshes
        li    a0, 0                     ; exit code
        halt                            ; stop (the window keeps the last frame until we exit)
give_back:
        cgive c4, zero                  ; return our band to core 0 (after our rows have landed)
        li    a0, 0                     ; exit code
        halt                            ; stop
bad:
        la    a0, m_bad                 ; complain
        li    a1, m_bad_e - m_bad       ; length
        call  print_str                 ; print it
        li    a0, 1                     ; exit code 1
        halt                            ; give up

; -----------------------------------------------------------------------------
; geometry() -> a0 = 0, or 1 if there is no framebuffer we can draw on.
; Reads the platform table through c9, finds the framebuffer entry and works
; out the view: the set from -2.25 to 0.75 across and -1.125 to 1.125 down,
; widened in one direction to keep points square, centred on (-0.75, 0).
; -----------------------------------------------------------------------------
geometry:                               ; routine entry
        la    t0, plat                  ; t0 = D-LS copy of the table
        li    t1, PLATMAX               ; bytes to read (past the table they read as 0)
        tget  tg0, t0, c9, zero, t1     ; platform table -> D-LS
        lhu   t2, 8(t0)                 ; t2 = number of entries (waits for the tget)
        addi  t3, t0, 32                ; t3 = first entry
g_find:                                 ; loop: one entry
        beqz  t2, g_bad                 ; no framebuffer entry
        lhu   t4, 0(t3)                 ; t4 = entry type
        li    t5, PT_FB                 ; the type we want
        beq   t4, t5, g_found           ; found it
        addi  t3, t3, 32                ; next entry
        addi  t2, t2, -1                ; one fewer left
        j     g_find                    ; continue
g_found:
        ld    t0, 8(t3)                 ; t0 = info: width | height << 16 | stride << 32 | format << 48
        srli  t1, t0, 48                ; t1 = format
        li    t2, FORMAT                ; the one we can draw
        bne   t1, t2, g_bad             ; anything else: give up
        la    t6, g_d                   ; t6 = our geometry variables
        sd    t0, g_info - g_d(t6)      ; keep the info word
        ld    t1, 16(t3)                ; t1 = framebuffer address
        sd    t1, g_base - g_d(t6)      ; keep it
        srli  t1, t0, 32                ; stride ...
        li    t2, 0xffff                ; (a 16-bit field)
        and   t1, t1, t2                ; ... in t1
        sd    t1, g_stride - g_d(t6)    ; keep it
        and   t1, t0, t2                ; t1 = width
        srli  t1, t1, 1                 ; points per row = width / 2
        sd    t1, g_cw - g_d(t6)        ; keep it
        srli  t2, t0, 16                ; height ...
        andi  t2, t2, 0xffff            ; ... in t2
        srli  t2, t2, 1                 ; rows of points = height / 2
        sd    t2, g_ch - g_d(t6)        ; keep it
        li    t3, 3 << FRAC             ; 3.0: the width of the view
        divu  t3, t3, t1                ; t3 = step if the width decides
        li    t4, 9 << (FRAC - 2)       ; 2.25: the height of the view
        divu  t4, t4, t2                ; t4 = step if the height decides
        bgeu  t3, t4, g_step            ; take the larger step, so all of the view fits
        mv    t3, t4                    ; (the height decides)
g_step:
        sd    t3, 0(t6)                 ; g_d = the step
        mul   t4, t3, t1                ; the view's actual width
        srai  t4, t4, 1                 ; half of it
        li    t5, -3 << (FRAC - 2)      ; -0.75, the centre
        sub   t5, t5, t4                ; left edge = centre - half the width
        sd    t5, g_x0 - g_d(t6)        ; keep it
        mul   t4, t3, t2                ; the view's actual height
        srai  t4, t4, 1                 ; half of it
        neg   t4, t4                    ; top edge = 0 - half the height
        sd    t4, g_y0 - g_d(t6)        ; keep it
        li    a0, 0                     ; success
        ret                             ; done
g_bad:
        li    a0, 1                     ; no usable framebuffer
        ret                             ; done

; -----------------------------------------------------------------------------
; band_rows() -> a0 = rows of points per core, ceil(rows / cores)
; -----------------------------------------------------------------------------
band_rows:                              ; routine entry
        la    t0, g_ch                  ; rows of points
        ld    t0, 0(t0)                 ; load it
        csrr  t1, ncores                ; number of cores
        add   t0, t0, t1                ; rows + cores - 1 ...
        addi  t0, t0, -1                ; ...
        divu  a0, t0, t1                ; ... divided by cores
        ret                             ; done

; -----------------------------------------------------------------------------
; render(a0 = first row of points, a1 = number of rows): draw rows of points
; into the band in c4. Point row i of the band covers pixel rows 2i and 2i+1,
; that is band offsets 2i * stride and (2i + 1) * stride.
; -----------------------------------------------------------------------------
render:                                 ; routine entry
        beqz  a1, r_none                ; an empty band: nothing to draw
        mv    s4, a1                    ; s4 = rows left
        li    s9, 4 << FRAC             ; s9 = escape radius squared, 4.0
        li    s10, MAXIT                ; s10 = iteration limit
        la    s11, pal                  ; s11 = palette
        la    t0, g_d                   ; the geometry, worked out by geometry():
        ld    a2, 0(t0)                 ; a2 = step between points
        ld    a3, g_x0 - g_d(t0)        ; a3 = cx of the left edge
        ld    a4, g_cw - g_d(t0)        ; a4 = points per row
        ld    a5, g_stride - g_d(t0)    ; a5 = bytes per pixel row
        ld    t1, g_y0 - g_d(t0)        ; t1 = cy of the top edge
        mul   s6, a0, a2                ; s6 = first row * step
        add   s6, s6, t1                ; s6 = cy of our first row
        li    s1, 0                     ; s1 = band offset of the current pixel row pair
        la    s7, rowbuf                ; s7 = the row buffer to fill next
        li    t0, MAXSTRIDE             ; one buffer further on ...
        add   s8, s7, t0                ; ... s8 = the other buffer
r_row:                                  ; loop: one row of points
        mv    s2, s7                    ; s2 = cursor in the row buffer
        mv    s5, a3                    ; s5 = cx of the first point
        mv    s3, a4                    ; s3 = points left in the row
r_col:                                  ; loop: one point
        mul   t6, s6, s6                ; a shortcut first: most of the black inside lies in two
        srai  t6, t6, FRAC              ;   shapes with a formula, so skip the iterations there.
        li    t3, 1 << (FRAC - 2)       ;   t6 = cy^2; t3 = 1/4
        sub   t3, s5, t3                ; t3 = cx - 1/4
        mul   t4, t3, t3                ; (cx - 1/4)^2, with 48 fraction bits
        srai  t4, t4, FRAC              ; back to 24
        add   t4, t4, t6                ; t4 = q = (cx - 1/4)^2 + cy^2
        add   t3, t4, t3                ; t3 = q + cx - 1/4
        mul   t3, t3, t4                ; q (q + cx - 1/4)
        srai  t3, t3, FRAC              ; back to 24 fraction bits
        srai  t5, t6, 2                 ; t5 = cy^2 / 4
        bge   t5, t3, r_inside          ; q (q + cx - 1/4) <= cy^2 / 4: in the main cardioid
        li    t3, 1 << FRAC             ; t3 = 1
        add   t3, s5, t3                ; cx + 1
        mul   t3, t3, t3                ; (cx + 1)^2
        srai  t3, t3, FRAC              ; back to 24 fraction bits
        add   t3, t3, t6                ; (cx + 1)^2 + cy^2
        li    t4, 1 << (FRAC - 4)       ; 1/16
        bge   t4, t3, r_inside          ; within 1/4 of -1: in the big disc on the left
        li    t0, 0                     ; t0 = zx = 0
        li    t1, 0                     ; t1 = zy = 0
        li    t2, 0                     ; t2 = iteration count
r_iter:                                 ; loop: z = z^2 + c
        mul   t3, t0, t0                ; zx * zx, with 48 fraction bits
        srai  t3, t3, FRAC              ; back to 24: zx^2
        mul   t4, t1, t1                ; zy * zy
        srai  t4, t4, FRAC              ; zy^2
        add   t5, t3, t4                ; |z|^2
        blt   s9, t5, r_out             ; escaped once |z|^2 > 4
        mul   t1, t0, t1                ; zx * zy
        srai  t1, t1, FRAC - 1          ; times 2, back to 24 fraction bits
        add   t1, t1, s6                ; zy = 2 zx zy + cy
        sub   t0, t3, t4                ; zx^2 - zy^2
        add   t0, t0, s5                ; zx = zx^2 - zy^2 + cx
        addi  t2, t2, 1                 ; one more iteration
        blt   t2, s10, r_iter           ; up to the limit
r_inside:
        li    t3, 0                     ; never escaped: inside the set, black
        j     r_paint                   ; paint it
r_out:
        andi  t3, t2, 15                ; t3 = palette index: escape time mod 16
        slli  t3, t3, 2                 ; times 4 bytes per entry
        add   t3, s11, t3               ; t3 = address of the colour
        lwu   t3, 0(t3)                 ; t3 = the colour, 0x00RRGGBB
r_paint:
        slli  t4, t3, 32                ; the same colour in the upper half
        or    t3, t3, t4                ; t3 = two pixels of it
        sd    t3, 0(s2)                 ; store both (waits if this buffer is still being sent)
        addi  s2, s2, 8                 ; next point in the buffer
        add   s5, s5, a2                ; cx of the next point
        addi  s3, s3, -1                ; one point fewer
        bnez  s3, r_col                 ; until the row is done
        mv    t1, a5                    ; one pixel row of bytes
        tput  tg0, s7, c4, s1, t1       ; the row to its first pixel row ...
        add   s1, s1, t1                ; next pixel row
        tput  tg0, s7, c4, s1, t1       ; ... and again to the second (a 2 x 2 block per point)
        add   s1, s1, t1                ; next pixel row pair
        mv    t0, s7                    ; switch buffers: the next row goes into the other one
        mv    s7, s8                    ;   while this one is still being sent
        mv    s8, t0                    ;   (s7 and s8 trade places)
        add   s6, s6, a2                ; cy of the next row
        addi  s4, s4, -1                ; one row fewer
        bnez  s4, r_row                 ; until our band is drawn
r_none:
        ret                             ; done

        .include "lib/print.s"          ; console helpers
