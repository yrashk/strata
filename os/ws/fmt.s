; =============================================================================
; fmt.s: numbers and strings into D-LS text buffers (for the HUD)
; =============================================================================
;
; Every routine writes at a0 and returns a0 = the address just past what it
; wrote, so calls chain: fmt_str, then fmt_dec at the returned address, ...
; Clobbers t0..t4.

; fmt_str(a0 = out, a1 = string, a2 = length) -> a0
fmt_str:                                ; routine entry
        beqz  a2, fs_ret                ; nothing (left)
        lbu   t0, 0(a1)                 ; a byte
        sb    t0, 0(a0)                 ; copied
        addi  a0, a0, 1                 ; next out
        addi  a1, a1, 1                 ; next in
        addi  a2, a2, -1                ; one fewer
        j     fmt_str                   ; continue
fs_ret: ret                             ; done

; fmt_cstr(a0 = out, a1 = string, a2 = most bytes) -> a0: copy up to a NUL
fmt_cstr:                               ; routine entry
        beqz  a2, fc_ret                ; the limit
        lbu   t0, 0(a1)                 ; a byte
        beqz  t0, fc_ret                ; the end
        sb    t0, 0(a0)                 ; copied
        addi  a0, a0, 1                 ; next out
        addi  a1, a1, 1                 ; next in
        addi  a2, a2, -1                ; one fewer
        j     fmt_cstr                  ; continue
fc_ret: ret                             ; done

; fmt_ch(a0 = out, a1 = byte) -> a0
fmt_ch:                                 ; routine entry
        sb    a1, 0(a0)                 ; the byte
        addi  a0, a0, 1                 ; past it
        ret                             ; done

; fmt_dec(a0 = out, a1 = value, a2 = at least this many digits) -> a0
fmt_dec:                                ; routine entry
        addi  sp, sp, -24               ; digits, right to left, on the stack
        mv    t0, sp                    ; t0 = end of the digit area + 1 ...
        addi  t0, t0, 24                ; ...
        li    t1, 10                    ; base
        li    t3, 0                     ; digits so far
fd_l:   remu  t2, a1, t1                ; lowest digit
        divu  a1, a1, t1                ; the rest
        addi  t2, t2, '0'               ; as a character
        addi  t0, t0, -1                ; one to the left
        sb    t2, 0(t0)                 ; store it
        addi  t3, t3, 1                 ; counted
        bnez  a1, fd_l                  ; more digits
        blt   t3, a2, fd_l              ; or zeros up to the minimum
        mv    t4, sp                    ; copy them out
        addi  t4, t4, 24                ; (t4 = end)
fd_c:   bgeu  t0, t4, fd_ret            ; all copied
        lbu   t2, 0(t0)                 ; a digit
        sb    t2, 0(a0)                 ; out
        addi  t0, t0, 1                 ; next
        addi  a0, a0, 1                 ; ...
        j     fd_c                      ; continue
fd_ret: addi  sp, sp, 24                ; pop the digits
        ret                             ; done

; fmt_tenths(a0 = out, a1 = value in tenths) -> a0: "123.4"
fmt_tenths:                             ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        li    t0, 10                    ; split the tenths off
        remu  t1, a1, t0                ; ...
        sd    t1, 8(sp)                 ; keep them
        divu  a1, a1, t0                ; whole part
        li    a2, 1                     ; at least one digit
        call  fmt_dec                   ; ...
        li    t0, '.'                   ; the point
        sb    t0, 0(a0)                 ; ...
        ld    t1, 8(sp)                 ; the tenths digit
        addi  t1, t1, '0'               ; ...
        sb    t1, 1(a0)                 ; ...
        addi  a0, a0, 2                 ; past both
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; pop the frame
        ret                             ; done

; fmt_hms(a0 = out, a1 = seconds) -> a0: "HH:MM:SS"
fmt_hms:                                ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        li    t0, 60                    ; seconds ...
        remu  t1, a1, t0                ; ...
        sd    t1, 8(sp)                 ; keep them
        divu  a1, a1, t0                ; minutes total
        remu  t1, a1, t0                ; minutes
        sd    t1, 16(sp)                ; keep them
        divu  a1, a1, t0                ; hours
        li    t0, 24                    ; within a day
        remu  a1, a1, t0                ; ...
        li    a2, 2                     ; two digits
        call  fmt_dec                   ; HH
        li    a1, ':'                   ; :
        call  fmt_ch                    ; ...
        ld    a1, 16(sp)                ; MM
        li    a2, 2                     ; ...
        call  fmt_dec                   ; ...
        li    a1, ':'                   ; :
        call  fmt_ch                    ; ...
        ld    a1, 8(sp)                 ; SS
        li    a2, 2                     ; ...
        call  fmt_dec                   ; ...
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 24                ; pop the frame
        ret                             ; done

; fmt_len(a0 = string) -> a0 = bytes before the first NUL
fmt_len:                                ; routine entry
        mv    t0, a0                    ; cursor
fl_l:   lbu   t1, 0(t0)                 ; a byte
        beqz  t1, fl_e                  ; the end
        addi  t0, t0, 1                 ; next
        j     fl_l                      ; continue
fl_e:   sub   a0, t0, a0                ; length
        ret                             ; done
