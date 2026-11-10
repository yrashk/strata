; =============================================================================
; mandel.s: an ASCII Mandelbrot set, drawn by every core into one frame
; =============================================================================
;
; What it shows
;   * A shared output image without shared writes. The 24-row frame lives in
;     system memory. Core 0 `csplit`s its capability into one band of rows per
;     core and gives each band away. Each core can write only its own rows; a
;     stray write into another band is a trap, not a silent glitch.
;   * Results are gathered by handing ownership back, in a fixed order. Core 0
;     takes band k back with `ctake c5, k` (only a gift from core k counts) and
;     `cjoin`s it on. `cgive` completes only after the giver's row transfers
;     have landed, so the joined frame is complete. One transfer then brings
;     the whole picture in for printing.
;   * Reusing a buffer is safe by construction. Each core renders a row into
;     one D-LS buffer and `tput`s it; the very next row's stores into that
;     buffer stall until the previous `tput` has read it. No `twait` needed.
;
; Arithmetic is fixed point with 24 fractional bits (1.0 = 1 << 24).

W       = 63                            ; characters per row
RB      = 64                            ; bytes per row: 63 characters + newline
H       = 24                            ; rows in the frame
FBYTES  = RB * H                        ; frame size in bytes
FRAC    = 24                            ; fixed-point fraction bits
MAXIT   = 40                            ; iteration limit
X0      = -36909875                     ; left edge,  -2.2 in fixed point
DX      = 798915                        ; column step, 3.0 / 63
Y0      = -19293798                     ; top row centre, -1.15
DY      = 1677722                       ; row step, 0.1

        .data                           ; data Local Store (one per core)
        .align 8                        ; transfer buffers must be aligned
row:    .space RB                       ; one rendered row
frame:  .space FBYTES                   ; core 0 only: the whole frame, for printing
pal:    .ascii " .:-=+*%#@"             ; shades, from "escaped at once" to "never escaped"
title:  .ascii "Mandelbrot set, rows shared out between " ; caption, first part
title_e:                                ; end of the text above
title2: .ascii " cores\n"              ; caption, second part
title2_e:                               ; end of the text above

        .text                           ; instruction Local Store
_start:
        li    sp, 65536                 ; stack at the top of D-LS
        csrr  s0, coreid                ; s0 = core number
        csrr  s7, ncores                ; s7 = number of cores
        addi  t0, s7, H - 1             ; rows per core = ceil(H / cores):
        li    t1, H                     ;   (H + cores - 1) / cores
        divu  s8, t0, s7                ; s8 = rows per core
        li    t0, RB                    ; bytes per row
        mul   s9, s8, t0                ; s9 = bytes per band
        bnez  s0, others                ; the other cores wait for their band

; ---- core 0: carve the frame into bands and hand them out ------------------------
        li    t0, FBYTES                ; t0 = frame size
        csplit c6, c0, t0               ; c0 = the frame, c6 = the rest of memory
        li    t0, FBYTES                ; t0 = frame size again
        bleu  s9, t0, band0             ; a band never exceeds the frame
        mv    s9, t0                    ; (only with one core: the band is the whole frame)
band0:
        csplit c5, c0, s9               ; c0 = band 0, c5 = the rest of the frame
        li    s3, 1                     ; s3 = next core to hand a band to
give:
        bge   s3, s7, mine              ; every core has a band
        clen  t1, c5                    ; t1 = frame bytes still unassigned
        mv    t2, s9                    ; t2 = a full band ...
        bleu  t2, t1, give_cut          ; ... if that much is left
        mv    t2, t1                    ; otherwise whatever is left (possibly nothing)
give_cut:
        csplit c7, c5, t2               ; c5 = this core's band, c7 = the rest
        cgive c5, s3                    ; core s3 now owns it (c5 becomes empty)
        cmov  c5, c7                    ; the rest moves back into c5
        addi  s3, s3, 1                 ; next core
        j     give                      ; continue
mine:
        cclear c5                       ; drop the (empty) unassigned remainder: a live capability
                                        ; may not be overwritten, so we discard it explicitly
        cmov  c4, c0                    ; render() writes through c4
        j     draw                      ; go render our rows
others:
        ctake c4, zero                  ; receive our band, from core 0 only
draw:
        mul   a0, s0, s8                ; a0 = first frame row of this core
        clen  t0, c4                    ; t0 = bytes in our band
        li    t1, RB                    ; bytes per row
        divu  a1, t0, t1                ; a1 = rows in our band
        call  render                    ; draw them into the segment in c4
        bnez  s0, give_back             ; the other cores return their band
        csrr  s7, ncores                ; s7 again (render uses s1..s11 as scratch)

; ---- core 0: collect the bands in order and print ----------------------------------
        li    s3, 1                     ; s3 = next core to collect from
collect:
        bge   s3, s7, show              ; all bands are back
        ctake c5, s3                    ; take core s3's band back (its rows are complete)
        cjoin c4, c5                    ; append it: c4 grows back into the whole frame
        addi  s3, s3, 1                 ; next core
        j     collect                   ; continue
show:
        la    a0, title                 ; the caption
        li    a1, title_e - title       ; its length
        call  print_str                 ; print it
        mv    a0, s7                    ; the core count
        call  print_dec                 ; print it
        la    a0, title2                ; " cores"
        li    a1, title2_e - title2     ; length
        call  print_str                 ; print it
        la    s1, frame                 ; s1 = D-LS frame buffer
        li    t0, FBYTES                ; t0 = frame size
        tget  tg0, s1, c4, zero, t0     ; one transfer brings the whole picture in
        mv    a0, s1                    ; the frame
        li    a1, FBYTES                ; all of it
        call  print_str                 ; print it (the tput waits behind the tget, in order)
        li    a0, 0                     ; exit code
        halt                            ; stop (after the console transfer drains)
give_back:
        li    t0, 0                     ; t0 = core 0
        cgive c4, t0                    ; return our band (waits until all our rows have landed)
        li    a0, 0                     ; exit code
        halt                            ; stop

; -----------------------------------------------------------------------------
; render(a0 = first frame row, a1 = row count): draw rows into the segment
; in c4, row i of this core going to segment offset i * RB.
; -----------------------------------------------------------------------------
render:                                 ; routine entry
        beqz  a1, r_none                ; an empty band: nothing to draw
        mv    s4, a1                    ; s4 = rows to draw
        li    s9, 4 << FRAC             ; s9 = escape radius squared, 4.0
        li    s10, MAXIT                ; s10 = iteration limit
        la    s11, pal                  ; s11 = shade table
        li    t0, DY                    ; t0 = row step
        mul   s6, a0, t0                ; s6 = first row * DY
        li    t0, Y0                    ; t0 = top edge
        add   s6, s6, t0                ; s6 = cy of our first row
        li    s1, 0                     ; s1 = row within our band
        li    s7, RB                    ; s7 = bytes per row, a transfer operand
r_row:                                  ; loop: one row per iteration
        la    s2, row                   ; s2 = cursor in the row buffer
        li    s5, X0                    ; s5 = cx of column 0
        li    s3, W                     ; s3 = columns left
r_col:                                  ; loop: one column (character) per iteration
        li    t0, 0                     ; t0 = zx = 0
        li    t1, 0                     ; t1 = zy = 0
        li    t2, 0                     ; t2 = iteration count
r_iter:                                 ; loop: one Mandelbrot iteration z = z^2 + c
        mul   t3, t0, t0                ; t3 = zx * zx (in 48 fraction bits)
        srai  t3, t3, FRAC              ; back to 24 fraction bits: zx^2
        mul   t4, t1, t1                ; t4 = zy * zy
        srai  t4, t4, FRAC              ; zy^2
        add   t5, t3, t4                ; t5 = |z|^2
        blt   s9, t5, r_out             ; escaped once |z|^2 > 4
        mul   t1, t0, t1                ; t1 = zx * zy
        srai  t1, t1, FRAC - 1          ; times 2, back to 24 fraction bits
        add   t1, t1, s6                ; zy = 2 zx zy + cy
        sub   t0, t3, t4                ; t0 = zx^2 - zy^2
        add   t0, t0, s5                ; zx = zx^2 - zy^2 + cx
        addi  t2, t2, 1                 ; one more iteration
        blt   t2, s10, r_iter           ; keep going up to the limit
r_out:                                  ; t2 = iterations taken; pick a shade
        li    t3, 9                     ; t3 = last shade index
        mul   t3, t2, t3                ; t3 = iterations * 9
        divu  t3, t3, s10               ; t3 = shade index 0..9
        add   t3, s11, t3               ; t3 = address of the shade character
        lbu   t3, 0(t3)                 ; t3 = the character
        sb    t3, 0(s2)                 ; put it in the row (waits if the last row's tput still reads here)
        addi  s2, s2, 1                 ; next column in the buffer
        li    t0, DX                    ; t0 = column step
        add   s5, s5, t0                ; cx of the next column
        addi  s3, s3, -1                ; one column fewer
        bnez  s3, r_col                 ; until the row is complete
        li    t0, '\n'                  ; newline character
        sb    t0, 0(s2)                 ; end the row with it
        mul   t1, s1, s7                ; t1 = segment offset of this row
        la    t0, row                   ; t0 = row buffer
        tput  tg0, t0, c4, t1, s7       ; write the row into our part of the frame
        li    t0, DY                    ; t0 = row step
        add   s6, s6, t0                ; cy of the next row
        addi  s1, s1, 1                 ; next row
        blt   s1, s4, r_row             ; until our band is drawn
r_none:
        ret                             ; done

        .include "lib/print.s"          ; console helpers
