; =============================================================================
; gfx.s: drawing into surfaces through D-LS strips (StrataOS graphics library)
; =============================================================================
;
; Memory is explicit I/O, so a picture is never drawn "in place": nothing can
; store into system memory. Everything here renders into a *strip* of rows
; in the data Local Store and then sends the strip out with one `tput` (one
; per row when the rows are not contiguous in the target). Two strip
; buffers of 5 KiB (one 1280-pixel row each; wider rects are drawn in
; vertical slices) are all the D-LS it needs: a full redraw of a 1280 x 800
; screen is 800 transfers of 5 KiB, a terminal line 16 rows of one tile, a
; lattice pulse a few hundred pixels.
;
; Surfaces
;   A surface is a rectangle of XRGB8888 pixels (bytes B, G, R, unused) in
;   memory reached through a capability. Its *descriptor* (48 bytes in D-LS):
;     S_CAP    0  the capability register (0..15) that reaches it
;     S_OFF    8  byte offset of pixel (0, 0) inside that capability
;     S_W     16  width in pixels (even)
;     S_H     24  height in pixels
;     S_STRIDE 32 bytes from one row to the next (a multiple of 8)
;   The capability register is data: the library reaches it through a small
;   table of `tput`/`tget` instructions, one per register. The framebuffer,
;   a client's surface and a surface pool are all just descriptors.
;
; Display lists
;   What to draw is a list of *items* (96 bytes each). An item is a handler
;   (an I-LS address), a bounding box and up to seven parameters:
;     I_FN 0  handler      I_X0 8, I_Y0 16, I_X1 24, I_Y1 32: box, x1/y1
;     I_P0 40 .. I_P6 88   parameters (see each handler)        exclusive
;   gfx_render(surface, rect, items, count) draws the rect: for each strip
;   of rows it collects the items whose box meets the strip (the *active*
;   list), calls every active item's handler for every row of the strip,
;   back to front, and sends the strip out. Handlers draw one row: they get
;     a0 = the item   a1 = y   a2 = the D-LS address of pixel x = 0 of this
;     row in the strip (only addresses inside the clip are ever touched)
;     a3, a4 = the clip [x0, x1) of the strip
;   and may clobber t0..t6 and a0..a7 (s registers, sp and gp are kept). New
;   kinds of item (a terminal grid, the lattice, a Mandelbrot row) are just
;   new handlers: the library does not need to know them.
;
; Alignment: transfers move whole 8-byte words, so the library widens every
; rect to even x, and a blit's x, width and source x must be even. When a
; rect had to be widened, or the caller asks for it, the strip is first
; read back from the surface (G_LOAD) so the extra pixels keep their colour.
;
; Calls clobber t0..t6 and a0..a7; s registers, sp, gp and tp are kept.
; Transfer tags: tg8 (strips out), tg9 (reads: blits, read-back).

; ---- surface descriptor ------------------------------------------------------
S_CAP    = 0                            ; capability register number
S_OFF    = 8                            ; offset of pixel (0, 0) in it
S_W      = 16                           ; width (pixels)
S_H      = 24                           ; height (pixels)
S_STRIDE = 32                           ; bytes per row
S_SIZE   = 48                           ; bytes per descriptor

; ---- display-list item -------------------------------------------------------
I_FN     = 0                            ; handler address
I_X0     = 8                            ; box: left
I_Y0     = 16                           ; box: top
I_X1     = 24                           ; box: right (exclusive)
I_Y1     = 32                           ; box: bottom (exclusive)
I_P0     = 40                           ; parameters
I_P1     = 48                           ; ...
I_P2     = 56                           ; ...
I_P3     = 64                           ; ...
I_P4     = 72                           ; ...
I_P5     = 80                           ; ...
I_P6     = 88                           ; ...
I_SIZE   = 96                           ; bytes per item

; ---- font descriptor (os/lib/font/font.s) ------------------------------------
F_TAB    = 0                            ; glyph table
F_FIRST  = 8                            ; first code
F_COUNT  = 16                           ; number of codes
F_ADV    = 24                           ; advance in pixels
F_ROWS   = 32                           ; rows (bytes) per glyph

; ---- options -----------------------------------------------------------------
G_LOAD   = 1                            ; gfx_render flag: read the strip first
OPAQUE   = 256                          ; alpha of an opaque colour
NOBG     = -1                           ; text background: transparent
GFX_STRIPB = 2560                       ; bytes per strip buffer (640 px of a row; wider
                                        ; rects are drawn in slices)
GFX_MAXACT = 192                        ; most items active in one strip

; ---- render state (gfx_st block offsets) -------------------------------------
GS_SURF  = 0                            ; the surface descriptor
GS_ITEMS = 8                            ; the item list
GS_COUNT = 16                           ; number of items
GS_Y1    = 24                           ; bottom of the rect (exclusive)
GS_RPS   = 32                           ; rows per strip
GS_Y0    = 40                           ; top of the rect
GS_X1    = 48                           ; right of the rect (exclusive)

        .data                           ; library state lives in the D-LS
        .align 8                        ; transfer buffers must be 8-byte aligned
gfx_buf:  .space 2 * GFX_STRIPB         ; two strip buffers, used in turn
gfx_act:  .space GFX_MAXACT * 8         ; the active list: item addresses
gfx_st:   .space 56                     ; render state (GS_*)
gfx_lbase: .dword 0                     ; list builder: first item
gfx_lcnt: .dword 0                      ; list builder: items so far
gfx_lmax: .dword 0                      ; list builder: capacity
gfx_tmp:  .space I_SIZE                 ; the item of an immediate call
gfx_dummy: .space I_SIZE                ; where items go when a list is full
gfx_rect: .space 32                     ; the rect of an immediate call
        .text                           ; code follows

; =============================================================================
; Transfers through a capability register named by a number
; =============================================================================

; gfx_xput(a0 = capability register 0..15, a1 = D-LS address, a2 = offset,
; a3 = length): tput on tg8 through c<a0>
gfx_xput:                               ; routine entry
        la    t0, gfx_puts              ; the table of tput stubs
        slli  t1, a0, 3                 ; 8 bytes per stub
        add   t0, t0, t1                ; this register's stub
        jr    t0                        ; run it (it returns to our caller)
gfx_puts:                               ; stub k: tput through ck, return
        tput  tg8, a1, c0, a2, a3       ; c0
        ret                             ; done
        tput  tg8, a1, c1, a2, a3       ; c1
        ret                             ; done
        tput  tg8, a1, c2, a2, a3       ; c2
        ret                             ; done
        tput  tg8, a1, c3, a2, a3       ; c3
        ret                             ; done
        tput  tg8, a1, c4, a2, a3       ; c4
        ret                             ; done
        tput  tg8, a1, c5, a2, a3       ; c5
        ret                             ; done
        tput  tg8, a1, c6, a2, a3       ; c6
        ret                             ; done
        tput  tg8, a1, c7, a2, a3       ; c7
        ret                             ; done
        tput  tg8, a1, c8, a2, a3       ; c8 (bare metal only: c8..c15 are the kernel's in StrataOS)
        ret                             ; done
        tput  tg8, a1, c9, a2, a3       ; c9
        ret                             ; done
        tput  tg8, a1, c10, a2, a3      ; c10
        ret                             ; done
        tput  tg8, a1, c11, a2, a3      ; c11
        ret                             ; done
        tput  tg8, a1, c12, a2, a3      ; c12
        ret                             ; done
        tput  tg8, a1, c13, a2, a3      ; c13
        ret                             ; done
        tput  tg8, a1, c14, a2, a3      ; c14
        ret                             ; done
        tput  tg8, a1, c15, a2, a3      ; c15
        ret                             ; done

; gfx_xget(a0 = capability register, a1 = D-LS address, a2 = offset, a3 =
; length): tget on tg9 through c<a0>
gfx_xget:                               ; routine entry
        la    t0, gfx_gets              ; the table of tget stubs
        slli  t1, a0, 3                 ; 8 bytes per stub
        add   t0, t0, t1                ; this register's stub
        jr    t0                        ; run it
gfx_gets:                               ; stub k: tget through ck, return
        tget  tg9, a1, c0, a2, a3       ; c0
        ret                             ; done
        tget  tg9, a1, c1, a2, a3       ; c1
        ret                             ; done
        tget  tg9, a1, c2, a2, a3       ; c2
        ret                             ; done
        tget  tg9, a1, c3, a2, a3       ; c3
        ret                             ; done
        tget  tg9, a1, c4, a2, a3       ; c4
        ret                             ; done
        tget  tg9, a1, c5, a2, a3       ; c5
        ret                             ; done
        tget  tg9, a1, c6, a2, a3       ; c6
        ret                             ; done
        tget  tg9, a1, c7, a2, a3       ; c7
        ret                             ; done
        tget  tg9, a1, c8, a2, a3       ; c8
        ret                             ; done
        tget  tg9, a1, c9, a2, a3       ; c9
        ret                             ; done
        tget  tg9, a1, c10, a2, a3      ; c10
        ret                             ; done
        tget  tg9, a1, c11, a2, a3      ; c11
        ret                             ; done
        tget  tg9, a1, c12, a2, a3      ; c12
        ret                             ; done
        tget  tg9, a1, c13, a2, a3      ; c13
        ret                             ; done
        tget  tg9, a1, c14, a2, a3      ; c14
        ret                             ; done
        tget  tg9, a1, c15, a2, a3      ; c15
        ret                             ; done

; =============================================================================
; gfx_render(a0 = surface, a1 = rect [x0, y0, x1, y1] (4 dwords), a2 = items,
; a3 = number of items, a4 = flags: G_LOAD reads the strip back first)
; Draws the rect of the surface from the display list, strip by strip.
; =============================================================================
gfx_render:                             ; routine entry
        addi  sp, sp, -112              ; frame: ra and s0..s11
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and every s register we use
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        sd    s3, 32(sp)                ; ...
        sd    s4, 40(sp)                ; ...
        sd    s5, 48(sp)                ; ...
        sd    s6, 56(sp)                ; ...
        sd    s7, 64(sp)                ; ...
        sd    s8, 72(sp)                ; ...
        sd    s9, 80(sp)                ; ...
        sd    s10, 88(sp)               ; ...
        sd    s11, 96(sp)               ; ...
        la    t6, gfx_st                ; t6 = the render state
        sd    a0, GS_SURF(t6)           ; keep the surface
        sd    a2, GS_ITEMS(t6)          ; the items
        sd    a3, GS_COUNT(t6)          ; and how many
        mv    s11, a4                   ; s11 = flags
        ld    s1, 0(a1)                 ; s1 = x0
        ld    s3, 8(a1)                 ; s3 = y0
        ld    s2, 16(a1)                ; s2 = x1
        ld    t3, 24(a1)                ; t3 = y1
        ld    t4, S_W(a0)               ; t4 = surface width
        ld    t5, S_H(a0)               ; t5 = surface height
        bgez  s1, gr_c1                 ; clip x0 at 0
        li    s1, 0                     ; (it was negative)
gr_c1:  bgez  s3, gr_c2                 ; clip y0 at 0
        li    s3, 0                     ; (it was negative)
gr_c2:  ble   s2, t4, gr_c3             ; clip x1 at the width
        mv    s2, t4                    ; (it was past the edge)
gr_c3:  ble   t3, t5, gr_c4             ; clip y1 at the height
        mv    t3, t5                    ; (it was past the edge)
gr_c4:  or    t0, s1, s2                ; an odd edge?
        andi  t0, t0, 1                 ; bit 0 of either
        beqz  t0, gr_even               ; both even: nothing to widen
        ori   s11, s11, G_LOAD          ; widened: keep the extra pixels by reading them first
        srli  s1, s1, 1                 ; x0 down to even ...
        slli  s1, s1, 1                 ; ...
        addi  s2, s2, 1                 ; x1 up to even ...
        srli  s2, s2, 1                 ; ...
        slli  s2, s2, 1                 ; ...
gr_even:
        bge   s1, s2, gr_done           ; nothing left to draw
        bge   s3, t3, gr_done           ; (empty either way)
        sd    t3, GS_Y1(t6)             ; keep y1
        sd    s3, GS_Y0(t6)             ; and y0
        sd    s2, GS_X1(t6)             ; and x1: wide rects are drawn in slices
        la    s9, gfx_buf               ; s9 = the buffer to fill next
        li    t0, GFX_STRIPB            ; one buffer further on ...
        add   s10, s9, t0               ; ... s10 = the other one
gr_slice:                               ; loop: one slice of at most GFX_STRIPB / 4 pixels
        la    t6, gfx_st                ; the render state
        ld    s2, GS_X1(t6)             ; the slice ends at x1 ...
        bge   s1, s2, gr_done           ; (every slice drawn)
        li    t0, GFX_STRIPB / 4        ; ... or a buffer's width further on
        add   t0, s1, t0                ; ...
        ble   s2, t0, gr_sl1            ; ...
        mv    s2, t0                    ; ...
gr_sl1: ld    s3, GS_Y0(t6)             ; from the top again
        sub   s8, s2, s1                ; width of the slice
        slli  s8, s8, 2                 ; s8 = bytes per strip row
        li    t0, GFX_STRIPB            ; strip buffer size
        divu  t0, t0, s8                ; rows that fit
        sd    t0, GS_RPS(t6)            ; rows per strip
gr_strip:                               ; loop: one strip
        la    t6, gfx_st                ; the render state
        ld    t3, GS_Y1(t6)             ; y1
        blt   s3, t3, gr_st1            ; rows left in this slice?
        mv    s1, s2                    ; no: the next slice starts where this one ended
        j     gr_slice                  ; ...
gr_st1:
        ld    t0, GS_RPS(t6)            ; rows per strip
        add   s4, s3, t0                ; s4 = end of this strip ...
        ble   s4, t3, gr_act            ; ... unless that is past y1
        mv    s4, t3                    ; (the last strip is shorter)
gr_act:                                 ; collect the items that meet the strip
        ld    t0, GS_ITEMS(t6)          ; t0 = item cursor
        ld    t1, GS_COUNT(t6)          ; t1 = items left
        la    s6, gfx_act               ; s6 = the active list
        mv    s7, s6                    ; s7 = its end so far
        la    t2, gfx_act + GFX_MAXACT * 8 ; t2 = its capacity end
gr_a_loop:                              ; loop: one item
        beqz  t1, gr_a_done             ; no more items
        ld    t4, I_Y0(t0)              ; top
        bge   t4, s4, gr_a_next         ; starts below the strip
        ld    t4, I_Y1(t0)              ; bottom
        bge   s3, t4, gr_a_next         ; ends above it
        ld    t4, I_X0(t0)              ; left
        bge   t4, s2, gr_a_next         ; right of the rect
        ld    t4, I_X1(t0)              ; right
        bge   s1, t4, gr_a_next         ; left of it
        blt   t4, s2, gr_a_push         ; ---- occlusion: does it cover the whole strip?
        ld    t4, I_X0(t0)              ; (right edge covers; left edge?)
        bgt   t4, s1, gr_a_push         ; ...
        ld    t4, I_Y0(t0)              ; top edge
        ld    t5, I_Y1(t0)              ; bottom edge
        ld    t3, I_FN(t0)              ; and is it opaque? by kind:
        la    t6, gfx_h_cpanel          ; a cut-corner panel: opaque, but only clear of
        beq   t3, t6, gr_o_cp           ;   its corners
        la    t6, gfx_h_rect            ; a rectangle: if its alpha is opaque
        beq   t3, t6, gr_o_rect         ; ...
        la    t6, gfx_h_grid            ; the grid: always
        beq   t3, t6, gr_o_rows         ; ...
        la    t6, gfx_h_blit            ; a blit: always (its box lies within its source)
        beq   t3, t6, gr_o_rows         ; ...
        j     gr_a_push                 ; anything else: assume it lets things show through
gr_o_cp:
        ld    t3, I_P2(t0)              ; clear of the chamfers: rows [y0 + c, y1 - c)
        add   t4, t4, t3                ; ...
        sub   t5, t5, t3                ; ...
gr_o_rect:
        ld    t3, I_P1(t0)              ; opaque?
        li    t6, OPAQUE                ; ...
        blt   t3, t6, gr_a_push         ; no
gr_o_rows:
        bgt   t4, s3, gr_a_push         ; covers every row of the strip?
        blt   t5, s4, gr_a_push         ; ...
        la    s7, gfx_act               ; yes: nothing before it can show; drop it all
gr_a_push:
        bgeu  s7, t2, gr_a_done         ; the list is full: draw what we have
        sd    t0, 0(s7)                 ; active
        addi  s7, s7, 8                 ; one more
gr_a_next:
        addi  t0, t0, I_SIZE            ; next item
        addi  t1, t1, -1                ; one fewer left
        j     gr_a_loop                 ; continue
gr_a_done:
        andi  t0, s11, G_LOAD           ; read the strip back first?
        beqz  t0, gr_rows               ; no
        mv    a0, s9                    ; into the buffer being filled
        call  gr_xfer_get               ; the strip's rows from the surface
gr_rows:
        mv    s0, s3                    ; s0 = the row being drawn
        slli  t0, s1, 2                 ; x0 in bytes
        sub   s5, s9, t0                ; s5 = address of pixel x = 0 of the first row
gr_row:                                 ; loop: one row
        bge   s0, s4, gr_out            ; the strip is drawn
        la    s6, gfx_act               ; s6 = active cursor
gr_item:                                ; loop: one active item
        bgeu  s6, s7, gr_row_next       ; every item is drawn on this row
        ld    a0, 0(s6)                 ; a0 = the item
        addi  s6, s6, 8                 ; next one after this
        ld    t0, I_Y0(a0)              ; its top
        blt   s0, t0, gr_item           ; not started yet on this row
        ld    t0, I_Y1(a0)              ; its bottom
        bge   s0, t0, gr_item           ; already over
        ld    t0, I_FN(a0)              ; the handler
        mv    a1, s0                    ; a1 = y
        mv    a2, s5                    ; a2 = row base
        mv    a3, s1                    ; a3 = clip x0
        mv    a4, s2                    ; a4 = clip x1
        jalr  ra, t0, 0                 ; draw the item's part of this row
        j     gr_item                   ; next item
gr_row_next:
        addi  s0, s0, 1                 ; next row
        add   s5, s5, s8                ; its pixels follow in the buffer
        j     gr_row                    ; continue
gr_out:
        mv    a0, s9                    ; send the buffer just drawn
        call  gr_xfer_put               ; to the surface
        mv    t0, s9                    ; swap buffers: the next strip is drawn in the other
        mv    s9, s10                   ;   one while this one may still be going out
        mv    s10, t0                   ;   (a store into it waits until it has)
        mv    s3, s4                    ; next strip starts where this one ended
        j     gr_strip                  ; continue
gr_done:
        ld    ra, 0(sp)                 ; restore the return address
        ld    s0, 8(sp)                 ; and the s registers
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        ld    s4, 40(sp)                ; ...
        ld    s5, 48(sp)                ; ...
        ld    s6, 56(sp)                ; ...
        ld    s7, 64(sp)                ; ...
        ld    s8, 72(sp)                ; ...
        ld    s9, 80(sp)                ; ...
        ld    s10, 88(sp)               ; ...
        ld    s11, 96(sp)               ; ...
        addi  sp, sp, 112               ; pop the frame
        ret                             ; done

; gr_xfer_put / gr_xfer_get (a0 = strip buffer): move rows s3..s4-1, columns
; s1..s2-1 between the buffer (s8 bytes per row) and the surface. One
; transfer for the whole strip when the rect spans whole rows of the surface.
gr_xfer_put:                            ; routine entry
        li    a5, 1                     ; a5 = direction: put
        j     gr_xfer                   ; shared body
gr_xfer_get:                            ; routine entry
        li    a5, 0                     ; a5 = direction: get
gr_xfer:
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the buffer cursor
        sd    a5, 16(sp)                ; the direction
        la    t6, gfx_st                ; the render state
        ld    t5, GS_SURF(t6)           ; t5 = the surface
        ld    t0, S_STRIDE(t5)          ; stride
        mul   t1, s3, t0                ; first row's offset
        slli  t2, s1, 2                 ; plus x0 in bytes
        add   t1, t1, t2                ; ...
        ld    t2, S_OFF(t5)             ; plus the surface's own offset
        add   t1, t1, t2                ; t1 = far offset of the first pixel
        sd    t1, 24(sp)                ; keep it
        sub   t3, s4, s3                ; rows in the strip
        sd    t3, 32(sp)                ; keep it (rows left)
        sd    t0, 40(sp)                ; and the stride
        bne   t0, s8, gx_rows           ; rows not contiguous: one transfer per row
        mul   a3, t3, s8                ; contiguous: the whole strip at once
        li    t3, 1                     ; as one "row"
        sd    t3, 32(sp)                ; ...
        j     gx_one                    ; send it
gx_rows:
        mv    a3, s8                    ; one row of bytes
gx_one:                                 ; loop: one transfer
        la    t6, gfx_st                ; the render state
        ld    t5, GS_SURF(t6)           ; the surface
        ld    a0, S_CAP(t5)             ; its capability register
        ld    a1, 8(sp)                 ; buffer cursor
        ld    a2, 24(sp)                ; far offset
        ld    t0, 16(sp)                ; direction
        beqz  t0, gx_get                ; get or put
        call  gfx_xput                  ; out
        j     gx_next                   ; next row
gx_get:
        call  gfx_xget                  ; in
gx_next:
        ld    t0, 8(sp)                 ; buffer cursor
        add   t0, t0, s8                ; next row in the buffer
        sd    t0, 8(sp)                 ; keep it
        ld    t0, 24(sp)                ; far offset
        ld    t1, 40(sp)                ; stride
        add   t0, t0, t1                ; next row in the surface
        sd    t0, 24(sp)                ; keep it
        ld    t0, 32(sp)                ; rows left
        addi  t0, t0, -1                ; one fewer
        sd    t0, 32(sp)                ; keep it
        mv    a3, s8                    ; later transfers are one row each
        bnez  t0, gx_one                ; more rows (a contiguous strip had just one)
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 48                ; pop the frame
        ret                             ; done

; =============================================================================
; Spans: the pixel loops every handler ends in
; =============================================================================

; gfx_dspan: draw [a5, a6) of the row, clipped to [a3, a4): a2 = row base,
; a7 = colour 0x00RRGGBB, t6 = alpha (0..256; 256 = opaque).
; Clobbers t0..t5, a5, a6; keeps a0..a4, a7, t6.
gfx_dspan:                              ; routine entry
        bge   a5, a3, ds_c1             ; clip the start ...
        mv    a5, a3                    ; ... at the clip's left edge
ds_c1:  ble   a6, a4, ds_c2             ; clip the end ...
        mv    a6, a4                    ; ... at its right edge
ds_c2:  bge   a5, a6, ds_ret            ; nothing left
        slli  t0, a5, 2                 ; start in bytes
        add   t0, a2, t0                ; t0 = first pixel's address
        slli  t1, a6, 2                 ; end in bytes
        add   t1, a2, t1                ; t1 = past the last pixel
        li    t2, OPAQUE                ; an opaque colour?
        blt   t6, t2, ds_blend          ; no: blend
        ; ---- fill: two pixels per store
        slli  t3, a7, 32                ; the colour in the upper half ...
        srli  t2, t3, 32                ; (t2 = the colour, upper bits clear)
        or    t3, t3, t2                ; ... t3 = two pixels of it
        andi  t4, t0, 4                 ; starting on an odd pixel?
        beqz  t4, ds_f_pairs            ; no
        sw    t2, 0(t0)                 ; that one alone
        addi  t0, t0, 4                 ; then pairs
ds_f_pairs:
        addi  t4, t1, -32               ; t4 = last start of a group of 8 pixels
ds_f_8:                                 ; loop: 8 pixels per round
        bgt   t0, t4, ds_f_2            ; fewer than 8 left
        sd    t3, 0(t0)                 ; pixels 0, 1
        sd    t3, 8(t0)                 ; 2, 3
        sd    t3, 16(t0)                ; 4, 5
        sd    t3, 24(t0)                ; 6, 7
        addi  t0, t0, 32                ; next group
        j     ds_f_8                    ; continue
ds_f_2:
        addi  t4, t1, -8                ; t4 = last start of a pair
ds_f_2l:                                ; loop: a pair per round
        bgt   t0, t4, ds_f_1            ; fewer than 2 left
        sd    t3, 0(t0)                 ; a pair
        addi  t0, t0, 8                 ; next
        j     ds_f_2l                   ; continue
ds_f_1:
        bgeu  t0, t1, ds_ret            ; nothing left
        sw    t2, 0(t0)                 ; the last odd pixel
ds_ret: ret                             ; done
        ; ---- blend: out = (pixel * (256 - a) + colour * a) / 256, per byte.
        ; Two pixels at a time: bytes 0, 2, 4, 6 and bytes 1, 3, 5, 7 are each
        ; four 16-bit lanes; 255 * 256 still fits a lane, so one multiply
        ; scales four bytes. A lone pixel at either end is blended as part of
        ; its pair and the neighbour put back (it lies inside the strip: clip
        ; edges are even).
ds_blend:
        blez  t6, ds_ret                ; alpha 0: nothing to do
        addi  sp, sp, -24               ; three spare registers
        sd    s0, 0(sp)                 ; s0 = 256 - alpha
        sd    s1, 8(sp)                 ; s1 = scratch
        sd    s2, 16(sp)                ; s2 = the original pair at an end
        li    t5, 0x00ff00ff            ; t5 = mask of bytes 0 and 2 ...
        slli  t2, t5, 32                ; ...
        or    t5, t5, t2                ; ... t5 = 0x00ff00ff00ff00ff
        slli  t2, a7, 32                ; colour pair ...
        srli  t3, t2, 32                ; ...
        or    t2, t2, t3                ; ... t2 = two pixels of the colour
        and   t3, t2, t5                ; colour bytes 0, 2, 4, 6
        mul   t3, t3, t6                ; times alpha: t3 = the colour's part, low lanes
        srli  t2, t2, 8                 ; bytes 1, 3, 5, 7 down
        and   t2, t2, t5                ; ...
        mul   t2, t2, t6                ; times alpha: t2 = the colour's part, high lanes
        li    s0, OPAQUE                ; 256 ...
        sub   s0, s0, t6                ; ... minus alpha
        andi  t4, t0, 4                 ; starting on an odd pixel?
        beqz  t4, ds_b_pairs            ; no
        addi  t0, t0, -4                ; its pair starts one pixel back
        ld    s2, 0(t0)                 ; s2 = the pair as it was
        mv    t4, s2                    ; blend all of it
        and   s1, t4, t5                ; bytes 0, 2, 4, 6
        mul   s1, s1, s0                ; times 256 - alpha
        add   s1, s1, t3                ; plus the colour's part
        srli  s1, s1, 8                 ; / 256
        and   s1, s1, t5                ; back in their lanes
        srli  t4, t4, 8                 ; bytes 1, 3, 5, 7
        and   t4, t4, t5                ; ...
        mul   t4, t4, s0                ; times 256 - alpha
        add   t4, t4, t2                ; plus the colour's part
        srli  t4, t4, 8                 ; / 256 ...
        and   t4, t4, t5                ; ... in their lanes
        slli  t4, t4, 8                 ; back up a byte
        or    t4, t4, s1                ; t4 = the blended pair
        srli  t4, t4, 32                ; keep its upper pixel ...
        slli  t4, t4, 32                ; ...
        slli  s2, s2, 32                ; and the original lower one ...
        srli  s2, s2, 32                ; ...
        or    t4, t4, s2                ; ... together
        sd    t4, 0(t0)                 ; store
        addi  t0, t0, 8                 ; whole pairs from here
ds_b_pairs:
        addi  a6, t1, -8                ; a6 = last start of a whole pair
ds_b_2:                                 ; loop: a pair per round
        bgt   t0, a6, ds_b_1            ; fewer than 2 left
        ld    t4, 0(t0)                 ; two pixels
        and   s1, t4, t5                ; bytes 0, 2, 4, 6
        mul   s1, s1, s0                ; times 256 - alpha
        add   s1, s1, t3                ; plus the colour's part
        srli  s1, s1, 8                 ; / 256
        and   s1, s1, t5                ; back in their lanes
        srli  t4, t4, 8                 ; bytes 1, 3, 5, 7
        and   t4, t4, t5                ; ...
        mul   t4, t4, s0                ; times 256 - alpha
        add   t4, t4, t2                ; plus the colour's part
        srli  t4, t4, 8                 ; / 256 ...
        and   t4, t4, t5                ; ... in their lanes
        slli  t4, t4, 8                 ; back up a byte
        or    t4, t4, s1                ; the blended pair
        sd    t4, 0(t0)                 ; store it
        addi  t0, t0, 8                 ; next
        j     ds_b_2                    ; continue
ds_b_1:
        bgeu  t0, t1, ds_b_end          ; nothing left
        ld    s2, 0(t0)                 ; one pixel left: s2 = its pair as it was
        mv    t4, s2                    ; blend all of it
        and   s1, t4, t5                ; bytes 0, 2, 4, 6
        mul   s1, s1, s0                ; times 256 - alpha
        add   s1, s1, t3                ; plus the colour's part
        srli  s1, s1, 8                 ; / 256
        and   s1, s1, t5                ; back in their lanes
        srli  t4, t4, 8                 ; bytes 1, 3, 5, 7
        and   t4, t4, t5                ; ...
        mul   t4, t4, s0                ; times 256 - alpha
        add   t4, t4, t2                ; plus the colour's part
        srli  t4, t4, 8                 ; / 256 ...
        and   t4, t4, t5                ; ... in their lanes
        slli  t4, t4, 8                 ; back up a byte
        or    t4, t4, s1                ; t4 = the blended pair
        slli  t4, t4, 32                ; keep its lower pixel ...
        srli  t4, t4, 32                ; ...
        srli  s2, s2, 32                ; and the original upper one ...
        slli  s2, s2, 32                ; ...
        or    t4, t4, s2                ; ... together
        sd    t4, 0(t0)                 ; store
ds_b_end:
        ld    s0, 0(sp)                 ; restore the spare registers
        ld    s1, 8(sp)                 ; ...
        ld    s2, 16(sp)                ; ...
        addi  sp, sp, 24                ; ...
        ret                             ; done

; =============================================================================
; Standard item handlers (see "Display lists" above for the calling convention)
; =============================================================================

; gfx_h_rect: a rectangle. P0 = colour, P1 = alpha (OPAQUE = fill).
gfx_h_rect:                             ; handler entry
        ld    a5, I_X0(a0)              ; span = the box's width
        ld    a6, I_X1(a0)              ; ...
        ld    a7, I_P0(a0)              ; colour
        ld    t6, I_P1(a0)              ; alpha
        j     gfx_dspan                 ; draw it (returns to the renderer)

; gfx_h_vgrad: a vertical gradient. P0 = colour at the top row, P1 = colour
; at the bottom row, P2 = alpha.
gfx_h_vgrad:                            ; handler entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; and the item
        ld    t0, I_Y0(a0)              ; top
        ld    t1, I_Y1(a0)              ; bottom (exclusive)
        sub   t2, a1, t0                ; t2 = rows from the top
        sub   t1, t1, t0                ; height ...
        addi  t1, t1, -1                ; ... minus one
        bgtz  t1, vg_h                  ; a single row ...
        li    t1, 1                     ; ... is all top colour
vg_h:   slli  t2, t2, 8                 ; t = rows * 256 / (height - 1)
        divu  t2, t2, t1                ; ...
        mv    t3, a1                    ; keep y
        ld    t4, I_P1(a0)              ; bottom colour
        ld    a0, I_P0(a0)              ; top colour
        mv    a1, t4                    ; ...
        mv    t5, a2                    ; keep the row base (gfx_lerp clobbers a2)
        mv    a2, t2                    ; mix
        call  gfx_lerp                  ; a0 = this row's colour
        mv    a7, a0                    ; colour for the span
        mv    a2, t5                    ; the row base again
        ld    a0, 8(sp)                 ; the item
        ld    a5, I_X0(a0)              ; span = the box's width
        ld    a6, I_X1(a0)              ; ...
        ld    t6, I_P2(a0)              ; alpha
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; pop the frame
        j     gfx_dspan                 ; draw (returns to the renderer)

; gfx_h_cframe: the 1-pixel outline of a box with 45-degree cut corners.
; P0 = colour, P1 = alpha, P2 = chamfer (pixels cut off each corner).
gfx_h_cframe:                           ; handler entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        ld    a7, I_P0(a0)              ; colour
        ld    t6, I_P1(a0)              ; alpha
        ld    t0, I_Y0(a0)              ; top
        sub   t0, a1, t0                ; r = rows below the top edge
        ld    t1, I_Y1(a0)              ; bottom
        sub   t1, t1, a1                ; rows to the bottom edge ...
        addi  t1, t1, -1                ; ... rb
        ble   t0, t1, cf_d              ; d = min(r, rb): distance from the nearer edge
        mv    t0, t1                    ; ...
cf_d:   ld    t2, I_P2(a0)              ; c = chamfer
        ld    t3, I_X0(a0)              ; x0
        ld    t4, I_X1(a0)              ; x1
        bnez  t0, cf_side               ; d = 0: the top or bottom edge itself
        add   a5, t3, t2                ; from x0 + c ...
        sub   a6, t4, t2                ; ... to x1 - c
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; pop the frame
        j     gfx_dspan                 ; one span
cf_side:
        bge   t0, t2, cf_vert           ; below the chamfer: the vertical sides
        sub   t5, t2, t0                ; c - d: how far in the diagonal is
        add   a5, t3, t5                ; left pixel x0 + c - d
        sub   t4, t4, t5                ; right pixel x1 - 1 - (c - d) ...
        addi  t4, t4, -1                ; ...
        j     cf_two                    ; draw both
cf_vert:
        mv    a5, t3                    ; left pixel x0
        addi  t4, t4, -1                ; right pixel x1 - 1
cf_two:
        sd    t4, 8(sp)                 ; keep the right pixel
        addi  a6, a5, 1                 ; one pixel wide
        call  gfx_dspan                 ; left
        ld    a5, 8(sp)                 ; right pixel
        addi  a6, a5, 1                 ; one pixel wide
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; pop the frame
        j     gfx_dspan                 ; right (returns to the renderer)

; gfx_h_cpanel: a filled box with 45-degree cut corners. P0 = colour,
; P1 = alpha, P2 = chamfer.
gfx_h_cpanel:                           ; handler entry
        ld    a7, I_P0(a0)              ; colour
        ld    t6, I_P1(a0)              ; alpha
        ld    t0, I_Y0(a0)              ; top
        sub   t0, a1, t0                ; r
        ld    t1, I_Y1(a0)              ; bottom
        sub   t1, t1, a1                ; ...
        addi  t1, t1, -1                ; rb
        ble   t0, t1, cp_d              ; d = min(r, rb)
        mv    t0, t1                    ; ...
cp_d:   ld    t2, I_P2(a0)              ; c
        sub   t2, t2, t0                ; inset = c - d ...
        bgez  t2, cp_in                 ; ... or 0 below the chamfer
        li    t2, 0                     ; ...
cp_in:  ld    a5, I_X0(a0)              ; x0 + inset
        add   a5, a5, t2                ; ...
        ld    a6, I_X1(a0)              ; x1 - inset
        sub   a6, a6, t2                ; ...
        j     gfx_dspan                 ; one span

; gfx_h_grid: background with a grid. P0 = background, P1 = line colour,
; P2 = spacing (a power of two), P3 = colour of the small crosses at every
; 4th crossing (-1: none), P4 = x origin of the grid, P5 = y origin.
gfx_h_grid:                             ; handler entry
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the item
        sd    s0, 16(sp)                ; s0, s1 (the cross loop)
        sd    s1, 24(sp)                ; ...
        li    t6, OPAQUE                ; everything here is opaque
        ld    t0, I_P5(a0)              ; y origin
        sub   t0, a1, t0                ; y relative to it
        ld    t1, I_P2(a0)              ; spacing
        addi  t2, t1, -1                ; spacing - 1 = the mask
        and   t3, t0, t2                ; row within a grid cell
        sd    t3, 32(sp)                ; keep it
        ld    a5, I_X0(a0)              ; the whole box ...
        ld    a6, I_X1(a0)              ; ...
        ld    a7, I_P0(a0)              ; ... in the background colour
        bnez  t3, gd_fill               ; not on a grid line
        ld    a7, I_P1(a0)              ; on one: the line colour
gd_fill:
        call  gfx_dspan                 ; fill the row
        ld    a0, 8(sp)                 ; the item
        ld    t3, 32(sp)                ; row within the cell
        beqz  t3, gd_marks              ; a grid line row: no dots needed
        ld    a7, I_P1(a0)              ; line colour for the vertical lines
        ld    t1, I_P2(a0)              ; spacing
        ld    t4, I_P4(a0)              ; x origin
        ld    t0, I_X0(a0)              ; start at the later of the box and the clip
        bge   t0, a3, gd_v0             ; ...
        mv    t0, a3                    ; ...
gd_v0:  sub   t5, t0, t4                ; relative to the origin ...
        addi  t2, t1, -1                ; ... rounded up to a grid column
        add   t5, t5, t2                ; ...
        neg   t0, t1                    ; (-spacing: the round-down mask)
        and   t5, t5, t0                ; ...
        add   t5, t5, t4                ; back to screen x: first line at or after the start
        ld    t3, I_X1(a0)              ; stop at the earlier of the box and the clip
        ble   t3, a4, gd_v              ; ...
        mv    t3, a4                    ; ...
gd_v:   bge   t5, t3, gd_marks          ; past the end
        slli  t0, t5, 2                 ; the pixel
        add   t0, a2, t0                ; ...
        sw    a7, 0(t0)                 ; line colour
        add   t5, t5, t1                ; next line
        j     gd_v                      ; continue
gd_marks:                               ; small crosses at every 4th crossing
        ld    a0, 8(sp)                 ; the item
        ld    a7, I_P3(a0)              ; cross colour
        bltz  a7, gd_ret                ; none
        ld    t1, I_P2(a0)              ; spacing
        slli  s1, t1, 2                 ; s1 = cross spacing: 4 cells
        ld    t0, I_P5(a0)              ; y origin
        sub   t0, a1, t0                ; y relative to it
        addi  t3, s1, -1                ; mask
        and   t0, t0, t3                ; row within a cross cell
        li    t4, 2                     ; arm length
        beqz  t0, gd_hbar               ; the crossing row: a short bar
        ble   t0, t4, gd_vdot           ; just below: the vertical arm
        sub   t0, s1, t0                ; rows to the next crossing
        ble   t0, t4, gd_vdot           ; just above: the vertical arm
        j     gd_ret                    ; elsewhere: nothing
gd_hbar:
        li    t5, 5                     ; a bar 5 wide ...
        li    t4, -2                    ; ... from x - 2
        j     gd_m                      ; draw them
gd_vdot:
        li    t5, 1                     ; one pixel ...
        li    t4, 0                     ; ... at x
gd_m:   sd    t5, 32(sp)                ; keep the width
        sd    t4, 40(sp)                ; and the offset
        ld    t3, I_P4(a0)              ; x origin
        sub   t0, a3, t3                ; clip x0 relative to it
        neg   t1, s1                    ; round down to a cross column ...
        and   t0, t0, t1                ; ...
        add   s0, t0, t3                ; ... back to screen x
        sub   s0, s0, s1                ; one column earlier (its bar may reach into the clip)
gd_ml:  bge   s0, a4, gd_ret            ; past the clip
        ld    t4, 40(sp)                ; offset
        add   a5, s0, t4                ; span start
        ld    t5, 32(sp)                ; width
        add   a6, a5, t5                ; span end
        call  gfx_dspan                 ; draw it (keeps a0..a4, a7, t6)
        add   s0, s0, s1                ; next cross column
        j     gd_ml                     ; continue
gd_ret:
        ld    ra, 0(sp)                 ; restore
        ld    s0, 16(sp)                ; ...
        ld    s1, 24(sp)                ; ...
        addi  sp, sp, 48                ; pop the frame
        ret                             ; done

; gfx_h_text: a line of text at scale 1. P0 = string (D-LS), P1 = length,
; P2 = font descriptor, P3 = foreground, P4 = background (NOBG: transparent),
; P5 = flags (bit 0: bold, drawn by widening each stroke one pixel right).
; The box is (x, y) .. (x + length * advance, y + rows).
gfx_h_text:                             ; handler entry
        addi  sp, sp, -48               ; frame: s0..s4
        sd    s0, 0(sp)                 ; ...
        sd    s1, 8(sp)                 ; ...
        sd    s2, 16(sp)                ; ...
        sd    s3, 24(sp)                ; ...
        sd    s4, 32(sp)                ; ...
        sd    s5, 40(sp)                ; ...
        ld    t0, I_P2(a0)              ; the font
        ld    t1, F_ROWS(t0)            ; rows per glyph
        ld    t2, I_Y0(a0)              ; top
        sub   t2, a1, t2                ; glyph row
        bgeu  t2, t1, tx_ret            ; outside the glyphs (box taller than the font)
        ld    s0, F_TAB(t0)             ; s0 = glyph table ...
        add   s0, s0, t2                ; ... at this row: glyph g's byte is s0 + g * rows
        mv    s1, t1                    ; s1 = rows (bytes per glyph)
        ld    s2, F_ADV(t0)             ; s2 = advance
        ld    t3, F_FIRST(t0)           ; first code
        ld    t4, F_COUNT(t0)           ; number of codes
        ld    a7, I_P3(a0)              ; a7 = foreground
        ld    t6, I_P4(a0)              ; t6 = background
        ld    s5, I_P5(a0)              ; s5 = flags
        ld    t0, I_X0(a0)              ; x of the first character
        ld    s3, I_P0(a0)              ; s3 = string cursor
        ld    s4, I_P1(a0)              ; s4 = characters left
tx_char:                                ; loop: one character
        beqz  s4, tx_ret                ; all done
        add   t5, t0, s2                ; t5 = x after this character
        ble   t5, a3, tx_next           ; wholly left of the clip
        bge   t0, a4, tx_ret            ; at or past the clip's right edge: done
        lbu   t1, 0(s3)                 ; the character
        sub   t1, t1, t3                ; minus the first code
        bltu  t1, t4, tx_have           ; in the table?
        li    t1, '?' - 32              ; no: a question mark (tables start at 32)
tx_have:
        mul   t1, t1, s1                ; glyph offset
        add   t1, s0, t1                ; this row's byte of it
        lbu   t1, 0(t1)                 ; t1 = 8 pixels, bit 7 leftmost
        andi  t2, s5, 1                 ; bold?
        beqz  t2, tx_bits               ; no
        srli  t2, t1, 1                 ; every stroke one pixel wider to the right
        or    t1, t1, t2                ; ...
tx_bits:
        slli  t1, t1, 56                ; bit 7 to the sign bit
        slli  t2, t0, 2                 ; t2 = address of the character's first pixel
        add   t2, a2, t2                ; ...
        mv    a5, t0                    ; a5 = x of the pixel
        mv    a6, s2                    ; a6 = pixels left in the cell
        blt   t0, a3, tx_slow           ; straddles the left clip edge
        bgt   t5, a4, tx_slow           ; or the right one
        bltz  t6, tx_tr                 ; transparent background: only the ink
tx_op:                                  ; loop: opaque, one pixel
        bltz  t1, tx_op_fg              ; ink here?
        sw    t6, 0(t2)                 ; no: background
        j     tx_op_n                   ; next
tx_op_fg:
        sw    a7, 0(t2)                 ; ink
tx_op_n:
        slli  t1, t1, 1                 ; next bit
        addi  t2, t2, 4                 ; next pixel
        addi  a6, a6, -1                ; one fewer
        bnez  a6, tx_op                 ; until the cell is done
        j     tx_next                   ; next character
tx_tr:                                  ; loop: transparent, one pixel
        beqz  t1, tx_next               ; no ink left in this row of the glyph
        bgez  t1, tx_tr_n               ; no ink here
        sw    a7, 0(t2)                 ; ink
tx_tr_n:
        slli  t1, t1, 1                 ; next bit
        addi  t2, t2, 4                 ; next pixel
        addi  a6, a6, -1                ; one fewer
        bnez  a6, tx_tr                 ; until the cell is done
        j     tx_next                   ; next character
tx_slow:                                ; loop: a cell cut by the clip, pixel by pixel
        blt   a5, a3, tx_s_n            ; left of the clip
        bge   a5, a4, tx_next           ; right of it: the rest is too
        bltz  t1, tx_s_fg               ; ink here?
        bltz  t6, tx_s_n                ; transparent: nothing
        sw    t6, 0(t2)                 ; background
        j     tx_s_n                    ; next
tx_s_fg:
        sw    a7, 0(t2)                 ; ink
tx_s_n:
        slli  t1, t1, 1                 ; next bit
        addi  t2, t2, 4                 ; next pixel
        addi  a5, a5, 1                 ; its x
        addi  a6, a6, -1                ; one fewer
        bnez  a6, tx_slow               ; until the cell is done
tx_next:
        mv    t0, t5                    ; next character's x
        addi  s3, s3, 1                 ; next character
        addi  s4, s4, -1                ; one fewer
        j     tx_char                   ; continue
tx_ret:
        ld    s0, 0(sp)                 ; restore
        ld    s1, 8(sp)                 ; ...
        ld    s2, 16(sp)                ; ...
        ld    s3, 24(sp)                ; ...
        ld    s4, 32(sp)                ; ...
        ld    s5, 40(sp)                ; ...
        addi  sp, sp, 48                ; pop the frame
        ret                             ; done

; gfx_h_texts: a line of text scaled up. P0..P4 as gfx_h_text (the
; background is not drawn: scaled text is always transparent), P5 unused,
; P6 = scale x | scale y << 16. Each glyph pixel becomes an
; sx x sy block; the box is length * advance * sx by rows * sy.
gfx_h_texts:                            ; handler entry
        addi  sp, sp, -80               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s6
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        sd    s3, 32(sp)                ; ...
        sd    s4, 40(sp)                ; ...
        sd    s5, 48(sp)                ; ...
        sd    s6, 56(sp)                ; ...
        ld    t0, I_P6(a0)              ; scales
        srli  t1, t0, 16                ; sy
        andi  s5, t0, 0xffff            ; s5 = sx
        ld    t2, I_Y0(a0)              ; top
        sub   t2, a1, t2                ; rows from the top
        divu  t2, t2, t1                ; glyph row
        ld    t0, I_P2(a0)              ; the font
        ld    t1, F_ROWS(t0)            ; rows per glyph
        bgeu  t2, t1, ts_ret            ; outside the glyphs
        ld    s0, F_TAB(t0)             ; s0 = glyph table at this row
        add   s0, s0, t2                ; ...
        mv    s1, t1                    ; s1 = bytes per glyph
        ld    s2, F_ADV(t0)             ; advance ...
        mul   s2, s2, s5                ; ... s2 = cell width on screen
        ld    t1, F_FIRST(t0)           ; first code
        sd    t1, 64(sp)                ; keep it
        ld    t1, F_COUNT(t0)           ; number of codes
        sd    t1, 72(sp)                ; keep it
        ld    s3, I_X0(a0)              ; s3 = x of the character
        ld    s4, I_P1(a0)              ; s4 = characters left
        ld    s6, I_P0(a0)              ; s6 = string cursor
        ld    a7, I_P3(a0)              ; a7 = ink colour
        li    t6, OPAQUE                ; opaque
ts_char:                                ; loop: one character
        beqz  s4, ts_ret                ; done
        add   t5, s3, s2                ; x after it
        ble   t5, a3, ts_next           ; left of the clip
        bge   s3, a4, ts_ret            ; right of it: done
        lbu   t1, 0(s6)                 ; the character
        ld    t2, 64(sp)                ; minus the first code
        sub   t1, t1, t2                ; ...
        ld    t2, 72(sp)                ; in the table?
        bltu  t1, t2, ts_have           ; yes
        li    t1, '?' - 32              ; no: a question mark
ts_have:
        mul   t1, t1, s1                ; glyph offset
        add   t1, s0, t1                ; this row's byte
        lbu   a0, 0(t1)                 ; a0 = 8 pixels
        slli  a0, a0, 56                ; bit 7 to the sign bit
        mv    a1, s3                    ; a1 = x of the first block
ts_px:                                  ; loop: one glyph pixel
        beqz  a0, ts_next               ; no ink left in this row
        bgez  a0, ts_px_n               ; no ink here
        mv    a5, a1                    ; a block sx wide
        add   a6, a1, s5                ; ...
        call  gfx_dspan                 ; draw it (keeps a0..a4, a7, t6)
ts_px_n:
        slli  a0, a0, 1                 ; next bit
        add   a1, a1, s5                ; next block
        j     ts_px                     ; continue
ts_next:
        add   s3, s3, s2                ; next character's x
        addi  s6, s6, 1                 ; next character
        addi  s4, s4, -1                ; one fewer
        j     ts_char                   ; continue
ts_ret:
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        ld    s4, 40(sp)                ; ...
        ld    s5, 48(sp)                ; ...
        ld    s6, 56(sp)                ; ...
        addi  sp, sp, 80                ; pop the frame
        ret                             ; done

; gfx_h_blit: copy a surface into the box. P0 = source surface descriptor,
; P1 = source x, P2 = source y of the box's top-left pixel. Each row is one
; `tget` straight from the source into the strip: no pixel passes through a
; register. Box x0, x1 and the source x must be even. Pixels of the box
; outside the source are left as they are.
gfx_h_blit:                             ; handler entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        ld    t6, I_P0(a0)              ; t6 = the source surface
        ld    t0, I_Y0(a0)              ; top of the box
        sub   t0, a1, t0                ; rows into the box
        ld    t1, I_P2(a0)              ; source y of the top
        add   t1, t1, t0                ; t1 = source row
        ld    t2, S_H(t6)               ; inside the source?
        bgeu  t1, t2, bl_ret            ; no (unsigned: negative rows too)
        ld    t2, I_X0(a0)              ; xs = max(box x0, clip x0)
        mv    t3, t2                    ; ...
        bge   t3, a3, bl_c1             ; ...
        mv    t3, a3                    ; ...
bl_c1:  ld    t4, I_X1(a0)              ; xe = min(box x1, clip x1)
        ble   t4, a4, bl_c2             ; ...
        mv    t4, a4                    ; ...
bl_c2:  ld    t5, I_P1(a0)              ; source x of the box's left edge ...
        sub   t2, t3, t2                ; ...
        add   t5, t5, t2                ; ... t5 = source x of xs
        bgez  t5, bl_c3                 ; left of the source?
        sub   t3, t3, t5                ; skip those pixels
        li    t5, 0                     ; ...
bl_c3:  ld    t2, S_W(t6)               ; source width
        sub   t2, t2, t5                ; pixels left in the source row
        sub   t0, t4, t3                ; pixels wanted
        ble   t0, t2, bl_c4             ; more than there are?
        mv    t0, t2                    ; only those
bl_c4:  blez  t0, bl_ret                ; nothing to copy
        slli  a3, t0, 2                 ; a3 = bytes
        slli  a1, t3, 2                 ; a1 = D-LS address of xs in the strip ...
        add   a1, a2, a1                ; ...
        ld    t2, S_STRIDE(t6)          ; a2 = far offset: row * stride ...
        mul   a2, t1, t2                ; ...
        slli  t5, t5, 2                 ; ... + x * 4 ...
        add   a2, a2, t5                ; ...
        ld    t2, S_OFF(t6)             ; ... + the surface's offset
        add   a2, a2, t2                ; ...
        ld    a0, S_CAP(t6)             ; through the source's capability
        call  gfx_xget                  ; one row in
bl_ret:
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; pop the frame
        ret                             ; done

; =============================================================================
; Colours
; =============================================================================

; gfx_lerp(a0 = colour a, a1 = colour b, a2 = t 0..256) -> a0 = a + (b - a) t / 256
; Clobbers t0..t4.
gfx_lerp:                               ; routine entry
        li    t4, 0x00ff00ff            ; mask of red and blue
        li    t0, 256                   ; 256 - t
        sub   t0, t0, a2                ; ...
        and   t1, a0, t4                ; a's red and blue
        mul   t1, t1, t0                ; times (256 - t)
        and   t2, a1, t4                ; b's red and blue
        mul   t2, t2, a2                ; times t
        add   t1, t1, t2                ; sum
        srli  t1, t1, 8                 ; / 256
        and   t1, t1, t4                ; red and blue of the result
        srli  t2, a0, 8                 ; a's green ...
        andi  t2, t2, 0xff              ; ...
        mul   t2, t2, t0                ; times (256 - t)
        srli  t3, a1, 8                 ; b's green ...
        andi  t3, t3, 0xff              ; ...
        mul   t3, t3, a2                ; times t
        add   t2, t2, t3                ; sum (green * 256)
        andi  t2, t2, 0xff00            ; = green in its place, rounded down
        or    a0, t1, t2                ; the colour
        ret                             ; done

; =============================================================================
; Building display lists
; =============================================================================

; gfx_list(a0 = item buffer, a1 = capacity in items): start a new list
gfx_list:                               ; routine entry
        la    t0, gfx_lbase             ; the builder's state
        sd    a0, 0(t0)                 ; first item
        sd    zero, gfx_lcnt - gfx_lbase(t0) ; none yet
        sd    a1, gfx_lmax - gfx_lbase(t0) ; capacity
        ret                             ; done

; gfx_add(a0 = handler, a1 = x0, a2 = y0, a3 = x1, a4 = y1) -> a0 = the new
; item (its parameters are the caller's to fill). A full list hands out a
; scratch item that is never drawn. Clobbers t0..t2.
gfx_add:                                ; routine entry
        la    t0, gfx_lbase             ; the builder's state
        ld    t1, gfx_lcnt - gfx_lbase(t0) ; items so far
        ld    t2, gfx_lmax - gfx_lbase(t0) ; capacity
        bgeu  t1, t2, ga_full           ; full
        addi  t2, t1, 1                 ; one more
        sd    t2, gfx_lcnt - gfx_lbase(t0) ; ...
        li    t2, I_SIZE                ; address of item t1
        mul   t1, t1, t2                ; ...
        ld    t2, 0(t0)                 ; ...
        add   t1, t1, t2                ; ...
        j     ga_fill                   ; fill in the common part
ga_full:
        la    t1, gfx_dummy             ; the scratch item
ga_fill:
        sd    a0, I_FN(t1)              ; handler
        sd    a1, I_X0(t1)              ; box
        sd    a2, I_Y0(t1)              ; ...
        sd    a3, I_X1(t1)              ; ...
        sd    a4, I_Y1(t1)              ; ...
        mv    a0, t1                    ; the item
        ret                             ; done

; gfx_count() -> a0 = items in the current list
gfx_count:                              ; routine entry
        la    t0, gfx_lcnt              ; the count
        ld    a0, 0(t0)                 ; ...
        ret                             ; done

; gfx_add_rect(a1 = x, a2 = y, a3 = w, a4 = h, a5 = colour, a6 = alpha) -> a0
gfx_add_rect:                           ; routine entry
        la    a0, gfx_h_rect            ; handler
        j     gar_box                   ; shared
; gfx_add_cpanel(a1..a4 = x, y, w, h, a5 = colour, a6 = alpha, a7 = chamfer)
gfx_add_cpanel:                         ; routine entry
        la    a0, gfx_h_cpanel          ; handler
        j     gar_box                   ; shared
; gfx_add_cframe(a1..a4 = x, y, w, h, a5 = colour, a6 = alpha, a7 = chamfer)
gfx_add_cframe:                         ; routine entry
        la    a0, gfx_h_cframe          ; handler
gar_box:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        add   a3, a1, a3                ; x1 = x + w
        add   a4, a2, a4                ; y1 = y + h
        call  gfx_add                   ; the item
        sd    a5, I_P0(a0)              ; colour
        sd    a6, I_P1(a0)              ; alpha
        sd    a7, I_P2(a0)              ; chamfer (ignored by rects)
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; pop the frame
        ret                             ; done

; gfx_add_text(a1 = x, a2 = y, a3 = string, a4 = length, a5 = font, a6 = fg,
; a7 = bg or NOBG) -> a0 = the item (P5 flags = 0: set bit 0 for bold)
gfx_add_text:                           ; routine entry
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a3, 8(sp)                 ; string
        sd    a4, 16(sp)                ; length
        ld    t0, F_ADV(a5)             ; width = length * advance
        mul   t0, t0, a4                ; ...
        add   a3, a1, t0                ; x1
        ld    t0, F_ROWS(a5)            ; height = rows
        add   a4, a2, t0                ; y1
        la    a0, gfx_h_text            ; handler
        call  gfx_add                   ; the item
        ld    t0, 8(sp)                 ; string
        sd    t0, I_P0(a0)              ; ...
        ld    t0, 16(sp)                ; length
        sd    t0, I_P1(a0)              ; ...
        sd    a5, I_P2(a0)              ; font
        sd    a6, I_P3(a0)              ; foreground
        sd    a7, I_P4(a0)              ; background
        sd    zero, I_P5(a0)            ; flags
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 32                ; pop the frame
        ret                             ; done

; gfx_add_texts(a1 = x, a2 = y, a3 = string, a4 = length, a5 = font, a6 = fg,
; a7 = sx | sy << 16) -> a0 = the item: scaled, transparent text
gfx_add_texts:                          ; routine entry
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a3, 8(sp)                 ; string
        sd    a4, 16(sp)                ; length
        ld    t0, F_ADV(a5)             ; width = length * advance * sx
        mul   t0, t0, a4                ; ...
        andi  t1, a7, 0xffff            ; ...
        mul   t0, t0, t1                ; ...
        add   a3, a1, t0                ; x1
        ld    t0, F_ROWS(a5)            ; height = rows * sy
        srli  t1, a7, 16                ; ...
        mul   t0, t0, t1                ; ...
        add   a4, a2, t0                ; y1
        la    a0, gfx_h_texts           ; handler
        call  gfx_add                   ; the item
        ld    t0, 8(sp)                 ; string
        sd    t0, I_P0(a0)              ; ...
        ld    t0, 16(sp)                ; length
        sd    t0, I_P1(a0)              ; ...
        sd    a5, I_P2(a0)              ; font
        sd    a6, I_P3(a0)              ; ink
        li    t0, NOBG                  ; transparent
        sd    t0, I_P4(a0)              ; ...
        sd    a7, I_P6(a0)              ; scales
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 32                ; pop the frame
        ret                             ; done

; gfx_add_blit(a1 = x, a2 = y, a3 = w, a4 = h, a5 = source surface, a6 =
; source x, a7 = source y) -> a0 = the item
gfx_add_blit:                           ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        add   a3, a1, a3                ; x1
        add   a4, a2, a4                ; y1
        la    a0, gfx_h_blit            ; handler
        call  gfx_add                   ; the item
        sd    a5, I_P0(a0)              ; source
        sd    a6, I_P1(a0)              ; source x
        sd    a7, I_P2(a0)              ; source y
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; pop the frame
        ret                             ; done

; =============================================================================
; Immediate drawing: one item, drawn at once (clients drawing into their
; own surfaces use these)
; =============================================================================

; gfx_fill(a0 = surface, a1 = x, a2 = y, a3 = w, a4 = h, a5 = colour)
gfx_fill:                               ; routine entry
        la    t0, gfx_tmp               ; the item
        la    t1, gfx_h_rect            ; a rectangle
        sd    t1, I_FN(t0)              ; ...
        sd    a5, I_P0(t0)              ; colour
        li    t1, OPAQUE                ; opaque
        sd    t1, I_P1(t0)              ; ...
        li    a6, 0                     ; no read-back needed (unless widened)
        j     gi_box                    ; draw it

; gfx_text(a0 = surface, a1 = x, a2 = y, a3 = string, a4 = length, a5 = font,
; a6 = fg, a7 = bg or NOBG)
gfx_text:                               ; routine entry
        la    t0, gfx_tmp               ; the item
        la    t1, gfx_h_text            ; text
        sd    t1, I_FN(t0)              ; ...
        sd    a3, I_P0(t0)              ; string
        sd    a4, I_P1(t0)              ; length
        sd    a5, I_P2(t0)              ; font
        sd    a6, I_P3(t0)              ; foreground
        sd    a7, I_P4(t0)              ; background
        sd    zero, I_P5(t0)            ; flags
        ld    t1, F_ADV(a5)             ; width
        mul   a3, t1, a4                ; ...
        ld    a4, F_ROWS(a5)            ; height
        li    a6, 0                     ; read-back only if transparent ...
        bgez  a7, gi_box                ; ...
        li    a6, G_LOAD                ; ... (the ink lands on what is there)
gi_box:                                 ; t0 = the item, a1..a4 = its box, a6 = flags
        add   a3, a1, a3                ; x1
        add   a4, a2, a4                ; y1
        sd    a1, I_X0(t0)              ; box
        sd    a2, I_Y0(t0)              ; ...
        sd    a3, I_X1(t0)              ; ...
        sd    a4, I_Y1(t0)              ; ...
        la    t1, gfx_rect              ; the rect to draw = the box
        sd    a1, 0(t1)                 ; ...
        sd    a2, 8(t1)                 ; ...
        sd    a3, 16(t1)                ; ...
        sd    a4, 24(t1)                ; ...
        mv    a1, t1                    ; rect
        mv    a2, t0                    ; items
        li    a3, 1                     ; one
        mv    a4, a6                    ; flags
        j     gfx_render                ; draw (returns to our caller)

; gfx_draw(a0 = surface, a1 = rect, a2 = items, a3 = count): gfx_render
; without read-back
gfx_draw:                               ; routine entry
        li    a4, 0                     ; no flags
        j     gfx_render                ; draw
