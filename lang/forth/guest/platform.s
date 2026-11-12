; =============================================================================
; lang/forth/guest/platform.s: the platform layer of Forth as a StrataOS guest
; =============================================================================
;
; The bare-metal layer (lang/forth/bare/platform.s) with the guest's devices:
; the same register conventions (arguments in a0.., clobber t0..t2, a0 and a1
; at most: the line editor keeps its buffer in a2..a4 and out_type its cursor
; in t3..t5 across these), the same memory routines.
;
; Capability registers (guest/boot.s and guest/init.s put them there):
;   c0  T3 [0, 1 MiB) of the arena   the kernel's: I-LS mirror, source, snapshot
;   c1  the job board (atomics only, copyable)
;   c2  the console: an endpoint to StrataOS's tty server (read + write)
;   c3  the clock: the timer's NOW (offset 0) and FREQ (8), read-only
;   c4  core control over the guest's own cores
;   c5  this core's console message buffer (4 KiB of the arena)
;   c8  T3 [2 MiB, end) of the arena  the heap behind far@ / far!
;   (c9: no framebuffer; c12: no cluster store)
;
; The console is a message to the tty server, as a StrataOS program's is, but
; sent by hand: a guest runs in supervisor mode and has no svc. The 64-byte
; header (0 op, 8 handle, 16 length, 24 mode, 32 result) and the data go into
; the message buffer, the buffer goes to tty with `csend c5, c2` and comes
; back, answered, with `crecv c5, c2` (from the tty's node only: a worker's
; doorbell in core 0's inbox is not taken by mistake). StrataOS takes one
; 4 KiB request at a time from each guest core, so every core has its own
; buffer and waits for its answer before it sends again.
;
; Input: READ in the tty's cooked mode (the tty echoes and edits; a READ
; returns one line). The tty serves a guest's READ only while the console is
; attached to it (`guest IMAGE` attaches it; Ctrl-] gives it back to StrataOS):
; until then the READ waits there. End of input (Ctrl-D) is 0x04 here, as
; bare metal's console gives at the end of a -i file. BYE sends CLOSE, which
; gives the console back to StrataOS, and halts (`guest stop` reclaims the
; cores).

OP_READ    = 1                          ; tty: read the console
OP_WRITE   = 2                          ; tty: write to the console
OP_CLOSE   = 4                          ; tty: close (a guest: give the console back)

; pl_con(a0 = op, a1 = the header's length, a2 = mode, a3 = data bytes already
; at pl_msg + 64) -> a0 = the result; the answered header is back in pl_msg,
; any data the server returned is at offset 64 of c5. Clobbers t0..t2, a0.
pl_con:                                 ; leaf
        la    t0, pl_msg                ; the header
        sd    a0, 0(t0)                 ; op
        sd    zero, 8(t0)               ; handle 0: the console
        sd    a1, 16(t0)                ; length
        sd    a2, 24(t0)                ; mode
        sd    zero, 32(t0)              ; result
        addi  t1, a3, 64 + 7            ; header and data, rounded up to 8 bytes
        srli  t1, t1, 3                 ; (transfers to far memory move doublewords)
        slli  t1, t1, 3                 ; ...
        tput  tg14, t0, c5, zero, t1    ; D-LS -> the buffer
        twait 1 << 14                   ; all of it is in before the buffer leaves
        csend c5, c2                    ; lend the buffer to the tty server
        crecv c5, c2                    ; its answer: the buffer, from the tty's node
        li    t1, 64                    ; the answered header -> D-LS
        tget  tg14, t0, c5, zero, t1    ; ...
        ld    a0, 32(t0)                ; the result (the load waits for the tget)
        ret                             ; done

; plat_write(a0 = D-LS address, a1 = length): console output, a WRITE per
; PL_CHUNK bytes
plat_write:                             ; ...
        addi  sp, sp, -40               ; frame: the callers' registers
        sd    ra, 0(sp)                 ; ...
        sd    a2, 8(sp)                 ; ...
        sd    a3, 16(sp)                ; ...
        sd    t3, 24(sp)                ; ...
        sd    t4, 32(sp)                ; ...
        mv    t3, a0                    ; t3 = cursor
        add   t4, a0, a1                ; t4 = end
pw_chunk:                               ; one message per iteration
        bgeu  t3, t4, pw_done           ; all sent
        sub   a3, t4, t3                ; a3 = bytes left
        li    t0, PL_CHUNK              ; at most a chunk
        bleu  a3, t0, pw_n              ; ...
        mv    a3, t0                    ; ...
pw_n:                                   ; copy them after the header
        la    t1, pl_msg                ; t1 = destination
        addi  t1, t1, 64                ; ...
        li    t0, 0                     ; t0 = index
pw_c:                                   ; one byte per iteration
        bgeu  t0, a3, pw_send           ; copied
        add   t2, t3, t0                ; ...
        lbu   t2, 0(t2)                 ; ...
        add   a0, t1, t0                ; ...
        sb    t2, 0(a0)                 ; ...
        addi  t0, t0, 1                 ; ...
        j     pw_c                      ; ...
pw_send:                                ; WRITE them
        add   t3, t3, a3                ; past them
        li    a0, OP_WRITE              ; ...
        mv    a1, a3                    ; length
        li    a2, 0                     ; mode
        call  pl_con                    ; a0 = bytes written
        j     pw_chunk                  ; next
pw_done:                                ; ...
        ld    t4, 32(sp)                ; restore
        ld    t3, 24(sp)                ; ...
        ld    a3, 16(sp)                ; ...
        ld    a2, 8(sp)                 ; ...
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 40                ; ...
        ret                             ; done

; plat_key -> a0 = the next input byte (0x04 at the end of input)
plat_key:                               ; a line is read when the last one is used up
        ld    t0, pl_kpos(zero)         ; t0 = next byte
        ld    t1, pl_klen(zero)         ; t1 = bytes read
        bltu  t0, t1, pk_byte           ; one is there
        ld    t2, pl_keof(zero)         ; the input has ended?
        bnez  t2, pk_eof                ; ...
        addi  sp, sp, -24               ; frame: the callers' registers
        sd    ra, 0(sp)                 ; ...
        sd    a2, 8(sp)                 ; ...
        sd    a3, 16(sp)                ; ...
        li    a0, OP_READ               ; READ a line (it waits for one)
        li    a1, PL_CHUNK              ; at most this much
        li    a2, 0                     ; mode: block
        li    a3, 0                     ; no data to send
        call  pl_con                    ; a0 = bytes, 0 at the end of input
        ld    a3, 16(sp)                ; ...
        ld    a2, 8(sp)                 ; ...
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 24                ; ...
        blez  a0, pk_end                ; the end (or an error: the same for us)
        sd    a0, pl_klen(zero)         ; the line -> pl_kbuf
        sd    zero, pl_kpos(zero)       ; ...
        la    t0, pl_kbuf               ; ...
        li    t1, 64                    ; ...
        addi  t2, a0, 7                 ; (whole doublewords)
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        tget  tg14, t0, c5, t1, t2      ; ...
        li    t0, 0                     ; the first byte
pk_byte:                                ; t0 = its index
        addi  t1, t0, 1                 ; one used
        sd    t1, pl_kpos(zero)         ; ...
        la    t1, pl_kbuf               ; ...
        add   t1, t1, t0                ; ...
        lbu   a0, 0(t1)                 ; this load waits for the tget
        ret                             ; done
pk_end:                                 ; no more input
        li    t0, 1                     ; ...
        sd    t0, pl_keof(zero)         ; ...
pk_eof:                                 ; ...
        li    a0, 4                     ; end of input
        ret                             ; done

; plat_ticks -> a0 = microseconds since power-on: the clock's NOW
plat_ticks:                             ; a read of the timer through the clock window
        la    t0, v_tick                ; 8 bytes of D-LS
        li    t2, 8                     ; one register (NOW is at offset 0 of c3)
        tget  tg10, t0, c3, zero, t2    ; device -> D-LS
        ld    a0, v_tick(zero)          ; waits for it
        ret                             ; done

; plat_ms(a0 = milliseconds): sleep. The guest has the clock but no timer
; deadline (the DEADLINE / WAIT registers are StrataOS's), so this core
; watches NOW; it is a core of the guest's own, so the wait costs nobody else.
plat_ms:                                ; ...
        li    t0, 1000                  ; to microseconds
        mul   a2, a0, t0                ; a2 = delay
        mv    a1, ra                    ; plat_ticks leaves a1 and a2 alone
        call  plat_ticks                ; a0 = now
        add   a2, a0, a2                ; a2 = the deadline
pm_wait:                                ; ...
        call  plat_ticks                ; ...
        bltu  a0, a2, pm_wait           ; not yet
        mv    ra, a1                    ; ...
        ret                             ; done

; plat_fget(a0 = D-LS, a1 = far address, a2 = bytes): far cache fill
plat_fget:                              ; from the heap capability
        tget  tg12, a0, c8, a1, a2      ; heap -> D-LS
        ret                             ; done
; plat_fput(a0 = D-LS, a1 = far address, a2 = bytes): far cache write-back
plat_fput:                              ; to the heap capability
        tput  tg12, a0, c8, a1, a2      ; D-LS -> heap
        ret                             ; done

; plat_source -> a0 = c0 offset of the core.fs text, a1 = its length.
; It is embedded in the image's far section (bare/source.s), which StrataOS's
; loader copied into the arena.
plat_source:                            ; leaf
        la    a0, core_fs               ; start
        la    a1, core_fs_end           ; end
        sub   a1, a1, a0                ; length
        ret                             ; done

; plat_units -> a0, a1 = 0: nothing is paged
plat_units:                             ; ...
        li    a0, 0                     ; ...
        li    a1, 0                     ; ...
        ret                             ; ...

; plat_miss: trap_entry got an xmiss: nothing is paged here, a fault
plat_miss:                              ; ...
        j     te_fault                  ; ...

; plat_bye(a0 = exit code): give the console back to StrataOS (CLOSE) and stop
; this core (the workers were told already). The guest's cores stay StrataOS's
; guest cores, halted, until `guest stop` resets them.
plat_bye:                               ; never returns
        li    a0, OP_CLOSE              ; CLOSE the console: the tty gives it back
        li    a1, 0                     ; ...
        li    a2, 0                     ; ...
        li    a3, 0                     ; ...
        call  pl_con                    ; ...
        halt                            ; halting drains our transfers first

; plat_tool(a0 = name, a1 = length) -> a0 = 0: no word is loaded on demand
; (the tools are part of the embedded source)
plat_tool:                              ; leaf
        li    a0, 0                     ; not a tool
        ret                             ; done

; plat_load(a0 = name, a1 = length, a2 = c0 offset) -> a0 = bytes, or a throw
; code. A guest has no files (no endpoint to StrataOS's fs).
plat_load:                              ; leaf
        li    a0, -306                  ; not available on this platform
        ret                             ; done

; plat_msg: the body of (MSG), a request to a server. A guest has only the
; console's.
plat_msg:                               ; a Forth word's body
        li    a0, -306                  ; not available on this platform
        j     throw_a0                  ; error

; ---- lending the image to a worker (see "Lending the image" in forth.s) -------
; plat_lend(t0 = core): give the worker the image: all of c0. Keeps t0.
plat_lend:                              ; leaf
        cgive c0, t0                    ; it installs from it and gives it back
        ret                             ; done
; plat_home: the image came back into the scratch register: it is c0 again.
; Clobbers nothing.
plat_home:                              ; leaf
        cmov  c0, c7                    ; c0 is home
        ret                             ; done
; plat_publish: nothing more to publish than the snapshot
plat_publish:                           ; leaf
        ret                             ; done
