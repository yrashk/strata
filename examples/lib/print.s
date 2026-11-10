; =============================================================================
; lib/print.s: console output helpers shared by the examples
; =============================================================================
;
; The console is a *device segment* (far tier T4). Every core boots with a
; capability for it in register c2 (write-only, duplicable). Printing is an
; ordinary transfer: `tput` copies bytes out of the data Local Store (D-LS)
; into the device. There is no load or store that can reach a device.
;
; None of these routines waits for its transfer to finish. They don't need to:
; a transfer's effect is defined to happen when it issues, and the hardware
; stalls any later store into a byte range that a transfer is still reading.
; So a caller can reuse its buffer immediately, and the worst case is that
; the store waits.
;
; Calling convention used by every example:
;   a0..a7  arguments and results        t0..t6  temporaries (caller-saved)
;   s0..s11 callee-saved                 ra      return address
;   sp      stack pointer (the stack lives in D-LS, like all data)
;
; Transfer tag tg15 is reserved for console output.

        .data                           ; following bytes go to the data Local Store
numbuf: .space 24                       ; digit scratch buffer, filled right to left
numend:                                 ; label: one byte past the end of numbuf
nlchar: .ascii "\n"                     ; a single newline character
hexdig: .ascii "0123456789abcdef"       ; digit lookup table for print_hex
        .text                           ; back to the instruction Local Store

; -----------------------------------------------------------------------------
; print_str(a0 = D-LS address, a1 = length in bytes)
; -----------------------------------------------------------------------------
print_str:                              ; routine entry
        tput  tg15, a0, c2, zero, a1    ; send a1 bytes from D-LS[a0] to console offset 0
        ret                             ; return at once; the device drains in the background

; -----------------------------------------------------------------------------
; print_nl(): print a newline
; -----------------------------------------------------------------------------
print_nl:                               ; routine entry
        la    a0, nlchar                ; a0 = address of the newline byte
        li    a1, 1                     ; a1 = one byte
        j     print_str                 ; tail call: print_str returns straight to our caller

; -----------------------------------------------------------------------------
; print_dec(a0 = unsigned 64-bit value): print in decimal
; -----------------------------------------------------------------------------
print_dec:                              ; routine entry
        la    t0, numend                ; t0 = write cursor, starts one past the buffer
        li    t1, 10                    ; t1 = the divisor, 10
pd_loop:                                ; loop: one decimal digit per iteration
        remu  t2, a0, t1                ; t2 = lowest decimal digit of a0
        divu  a0, a0, t1                ; a0 = a0 / 10, dropping that digit
        addi  t2, t2, '0'               ; turn the digit into its ASCII character
        addi  t0, t0, -1                ; move the cursor one byte left
        sb    t2, 0(t0)                 ; store the character (stalls if an earlier print still reads this byte)
        bnez  a0, pd_loop               ; repeat while digits remain
        mv    a0, t0                    ; a0 = address of the first character
        la    t1, numend                ; t1 = end of the buffer
        sub   a1, t1, t0                ; a1 = number of characters
        j     print_str                 ; tail call to send them

; -----------------------------------------------------------------------------
; print_hex(a0 = 64-bit value): print as 0x followed by 16 hex digits
; -----------------------------------------------------------------------------
print_hex:                              ; routine entry
        la    t0, numend                ; t0 = write cursor, one past the buffer
        la    t3, hexdig                ; t3 = base of the digit table
        li    t1, 16                    ; t1 = digits left to produce
ph_loop:                                ; loop: one hex digit per iteration
        andi  t2, a0, 15                ; t2 = lowest nibble
        add   t2, t3, t2                ; t2 = address of its character in the table
        lbu   t2, 0(t2)                 ; t2 = the character
        addi  t0, t0, -1                ; move the cursor left
        sb    t2, 0(t0)                 ; store the character
        srli  a0, a0, 4                 ; shift the next nibble down
        addi  t1, t1, -1                ; one digit fewer to go
        bnez  t1, ph_loop               ; loop until all 16 are written
        li    t2, 'x'                   ; t2 = 'x'
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store 'x'
        li    t2, '0'                   ; t2 = '0'
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store '0' so the text reads 0x...
        mv    a0, t0                    ; a0 = start of the text
        li    a1, 18                    ; a1 = 2 + 16 characters
        j     print_str                 ; tail call to send them

; -----------------------------------------------------------------------------
; print_dec10(a0 = value): print exactly 10 decimal digits, zero-padded
;
; Used for timing values. Its instruction sequence does not depend on the
; value, so a program's instruction trace is the same on the emulator and the
; RTL even though the printed cycle counts differ.
; -----------------------------------------------------------------------------
print_dec10:                            ; routine entry
        la    t0, numend                ; t0 = write cursor, one past the buffer
        li    t1, 10                    ; t1 = the divisor
        li    t3, 10                    ; t3 = digits left to produce (always 10)
pd10_loop:                              ; loop: one digit per iteration, always 10 iterations
        remu  t2, a0, t1                ; t2 = lowest decimal digit
        divu  a0, a0, t1                ; drop that digit
        addi  t2, t2, '0'               ; to ASCII
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; store the character
        addi  t3, t3, -1                ; one digit fewer
        bnez  t3, pd10_loop             ; fixed trip count, whatever the value
        mv    a0, t0                    ; a0 = first character
        li    a1, 10                    ; a1 = 10 characters
        j     print_str                 ; tail call to send them

; -----------------------------------------------------------------------------
; print_kv(a0 = label address, a1 = label length, a2 = value):
; print "<label><value in decimal>\n". Needs a valid stack pointer.
; -----------------------------------------------------------------------------
print_kv:                               ; routine entry
        addi  sp, sp, -16               ; make room for two saved words on the stack
        sd    ra, 0(sp)                 ; save our return address (the calls below overwrite ra)
        sd    a2, 8(sp)                 ; save the value: a2 is caller-saved, so the calls may clobber it
        call  print_str                 ; print the label
        ld    a0, 8(sp)                 ; a0 = the value
        call  print_dec                 ; print it
        call  print_nl                  ; end the line
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; release the stack space
        ret                             ; back to the caller
