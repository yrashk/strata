; =============================================================================
; lang/forth/os/platform.s: the StrataOS 0.1 platform layer
; =============================================================================
;
; Everything the Forth kernel needs from the machine, for a StrataOS process
; (compare lang/forth/bare/platform.s). These are internal routines: arguments
; in a0.., and plat_write / plat_key / plat_ticks / plat_ms / plat_fget /
; plat_fput clobber t0..t2, a0 and a1 at most (callers rely on that: the line
; editor keeps its buffer in a2..a4 across them).
;
; Capability registers. A StrataOS process keeps c0..c7 across a context
; switch and nothing else, so everything lives there:
;   c0  the arena below the heap: code mirror, source text, the parcel
;   c1  the job board (atomics only, copyable) when started with -n N;
;       otherwise the endpoint of `proc` (Forth asks it through (msg):
;       net.fs, the network server's endpoint for each request; httpd.fs, /~ps)
;   c2  endpoint of `fs`     c3  endpoint of `tty`     c4  endpoint of `pipe`
;   c5  the message buffer (4 KiB)
;   c6  the far heap behind far@ / far!  (heap-cap)
;   c7  scratch: the kernel's (the parcel coming back, a doorbell, the clock
;       while TICKS reads it) and, between kernel calls, the program's (tmp-cap)
; c8..c15 are lost whenever the process is switched out: not used.
;
; Messages (os/lib/sys.s describes the protocol; this is the lean part of it
; Forth needs): the 64-byte header 0 op, 8 handle, 16 length, 24 mode, 32
; result and the data from byte 64 are written into the buffer, the buffer is
; lent to the server with `csend c5, cE`, and svc WAIT_REPLY sleeps until it
; is back. Transfer tag tg9 belongs to these routines.
;
; Threads (`forth -n N`): thread 0 is the interpreter. In plat_init it cuts
; the job board, and for every other thread a 32 KiB page and a 4 KiB message
; buffer, from the top of the heap; fills the page with a copy of its code
; mirror; and gives the thread the page, the buffer and copies of the board
; and of the server endpoints. A worker's page is its own code mirror (svc
; SET_MIRROR in boot.s), so its code survives preemption too. Later code and
; the D-LS snapshot travel in the PARCEL, a piece of thread 0's arena that is
; given to the worker and given back (thread 0 never parts with its mirror:
; the dispatcher needs it at every switch-in). ctake and cgive between the
; threads are direct for cgive and emulated by the dispatcher for ctake.

OP_READ   = 1                           ; message ops: read a handle
OP_WRITE  = 2                           ; write a handle
OP_OPEN   = 3                           ; fs: open a file
OP_CLOSE  = 4                           ; close a handle
SVC_WAIT  = 1                           ; svc WAIT_REPLY: a1 doorbell core, a2 timeout, a3 awaited base, a4 register
SVC_EXIT  = 5                           ; svc EXIT: a1 = code
SVC_CLOCK = 10                          ; svc CLOCK: c7 = the clock (read-only timer NOW)
OP_LOOKUP = 25                          ; proc: a server's endpoint by name (it arrives in c6)
R_FS      = 2                           ; endpoint registers: fs
R_TTY     = 3                           ; tty
R_PIPE    = 4                           ; pipe
R_NET     = 6                           ; the network server (plat_msg: its endpoint is in c6 for one request)
PL_NAMEMAX = 200                        ; longest file name passed to fs

; -----------------------------------------------------------------------------
; Messages
; -----------------------------------------------------------------------------
; pl_call(a0 = server register 1..4 or 6, a1 = op, a2 = the server's id, a3 =
; length, a4 = mode) -> a0 = result. Data must be in the buffer already.
; Clobbers t0..t2, a0..a4.
pl_call:                                ; leaf
        la    t0, pl_hdr                ; build the header
        sd    a1, 0(t0)                 ; op
        sd    a2, 8(t0)                 ; handle
        sd    a3, 16(t0)                ; length
        sd    a4, 24(t0)                ; mode
        sd    zero, 32(t0)              ; result
        li    t1, 64                    ; header size
        tput  tg9, t0, c5, zero, t1     ; D-LS -> the buffer
        twait (1 << 9) | (1 << 5)       ; header and data (ours: tg9; Forth's `5 tput`: tg5) must be in before the buffer leaves
        li    t1, R_TTY                 ; which endpoint?
        beq   a0, t1, pc_tty            ; the console
        li    t1, R_PIPE                ; ...
        beq   a0, t1, pc_pipe           ; a pipe
        li    t1, 1                     ; ...
        beq   a0, t1, pc_c1             ; c1: proc
        li    t1, R_NET                 ; ...
        beq   a0, t1, pc_c6             ; c6: the network server's endpoint, for one request (plat_msg)
        csend c5, c2                    ; fs: lend it the buffer
        cbase a1, c2                    ; a1 = the core it names (for the doorbell)
        j     pc_wait                   ; ...
pc_tty:                                 ; tty
        csend c5, c3                    ; lend it the buffer
        cbase a1, c3                    ; a1 = its core
        j     pc_wait                   ; ...
pc_c1:                                  ; register 1
        csend c5, c1                    ; lend it the buffer
        cbase a1, c1                    ; a1 = its core
        j     pc_wait                   ; ...
pc_c6:                                  ; register 6
        csend c5, c6                    ; lend it the buffer
        cbase a1, c6                    ; a1 = its core
        j     pc_wait                   ; ...
pc_pipe:                                ; pipe
        csend c5, c4                    ; lend it the buffer
        cbase a1, c4                    ; a1 = its core
pc_wait:                                ; sleep until the buffer is back
        li    a0, SVC_WAIT              ; WAIT_REPLY
        li    a2, -1                    ; no timeout
        ld    a3, pl_bufb(zero)         ; awaited: 0 = the process's own buffer; a worker's own base
        li    a4, 5                     ; it comes back into c5
        svc                             ; a0 = 0, or -2 if an interrupt woke us first
        beqz  a0, pc_back               ; answered
        li    a1, -1                    ; the buffer is still out: no doorbell this time,
        j     pc_wait                   ; wait again (the server answers every request)
pc_back:                                ; the answered header -> D-LS
        la    t0, pl_hdr                ; ...
        li    t1, 64                    ; ...
        tget  tg9, t0, c5, zero, t1     ; ...
        ld    a0, 32(t0)                ; the result (the load waits for the tget)
        ret                             ; done

; pl_hcall(a0 = handle 0..2, a1 = op, a3 = length, a4 = mode) -> a0 = result,
; -1 if the handle is closed. Clobbers t0..t2, a0..a4.
pl_hcall:                               ; leaf (tail-calls pl_call)
        slli  t0, a0, 3                 ; the handle's table index
        ld    a2, pl_hid(t0)            ; the server's id
        ld    a0, pl_hreg(t0)           ; the server's register
        bnez  a0, pl_call               ; open: send
        li    a0, -1                    ; closed
        ret                             ; done

; plat_msg: the Forth word (MSG) ( handle len mode op reg -- result ), one
; request to a server (net.fs is built on it; forth.s's p_msg jumps here,
; with the data stack as it was). The header op, handle, length, mode goes to
; the server behind endpoint register reg (1 proc, 2 fs, 3 tty, 4 pipe, 6 the
; network server; anything else is fs) and the word sleeps until the answer
; is back. Request and reply data are the buffer's bytes from 64 on: Forth
; moves them itself with `5 tput` and `5 tget` (pl_call waits for tag tg5
; before the buffer leaves). With threads (-n N) c1 is the job board, so
; registers 1 and 6 fail (-1).
;
; Register 6 has no register of its own: c0..c7 are all taken, and proc's
; endpoint must stay in c1. So every request to the network server first
; asks proc for its endpoint (LOOKUP "net"), which arrives in c6, where the
; heap is: the heap waits in the scratch register c7 meanwhile, the request
; goes through the endpoint in c6, and the endpoint is dropped after the
; answer. LOOKUP's name covers the first 8 bytes of the request's data, which
; are kept in pl_save and put back. A proc round trip per network request;
; -4 if no network server runs.
plat_msg:                               ; a Forth word's body
        addi  sp, sp, -48               ; frame: ra, then op, handle, length, mode for register 6
        sd    ra, 0(sp)                 ; save the return address
        mv    a0, s1                    ; a0 = the register
        ld    a1, 0(s0)                 ; a1 = op
        ld    a4, 8(s0)                 ; a4 = mode
        ld    a3, 16(s0)                ; a3 = length
        ld    a2, 24(s0)                ; a2 = handle
        addi  s0, s0, 32                ; four cells off; the result replaces the fifth
        li    t0, 1                     ; register 1 (proc)
        beq   a0, t0, pm_c1             ; ...
        li    t0, R_NET                 ; or 6 (the network server, through proc)?
        bne   a0, t0, pm_call           ; neither: an ordinary request
pm_c1:                                  ; both need proc in c1
        ld    t0, v_ncores(zero)        ; threads: c1 is the job board
        li    t1, 1                     ; (v_ncores = 1: one thread)
        bne   t0, t1, pm_fail           ; no proc to ask
        bne   a0, t0, pm_net            ; register 6
pm_call:                                ; send it and wait
        call  pl_call                   ; a0 = the result
        j     pm_ret                    ; ...
pm_net:                                 ; the network server: its endpoint first
        sd    a1, 8(sp)                 ; keep the request
        sd    a2, 16(sp)                ; ...
        sd    a3, 24(sp)                ; ...
        sd    a4, 32(sp)                ; ...
        twait 1 << 5                    ; Forth's request data are in the buffer
        la    t0, pl_save               ; their first 8 bytes, which the name covers,
        li    t1, 64                    ; -> pl_save
        li    t2, 8                     ; ...
        tget  tg9, t0, c5, t1, t2       ; ...
        ld    t0, pl_save(zero)         ; (waits for the transfer)
        la    t0, pl_netnm              ; "net" -> LOOKUP's data
        tput  tg9, t0, c5, t1, t2       ; ...
        cclear c7                       ; the scratch register holds the heap meanwhile:
        cmov  c7, c6                    ; the endpoint arrives in c6
        li    a0, 1                     ; proc
        li    a1, OP_LOOKUP             ; LOOKUP "net"
        li    a2, 0                     ; ...
        li    a3, 3                     ; ...
        li    a4, 0                     ; ...
        call  pl_call                   ; a0 = 0, the endpoint in c6; or -4: no network server
        bnez  a0, pm_home               ; none
        la    t0, pl_save               ; the request's data as they were
        li    t1, 64                    ; ...
        li    t2, 8                     ; ...
        tput  tg9, t0, c5, t1, t2       ; (pl_call waits for it)
        li    a0, R_NET                 ; the request, through c6
        ld    a1, 8(sp)                 ; ...
        ld    a2, 16(sp)                ; ...
        ld    a3, 24(sp)                ; ...
        ld    a4, 32(sp)                ; ...
        call  pl_call                   ; a0 = the result
        cclear c6                       ; the endpoint is dropped
pm_home:                                ; the heap goes back
        cmov  c6, c7                    ; ...
        cclear c7                       ; (empty again, as after TICKS)
        j     pm_ret                    ; ...
pm_fail:                                ; no proc behind register 1
        li    a0, -1                    ; failed
pm_ret:                                 ; a0 = the result
        mv    s1, a0                    ; becomes the top of the stack
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 48                ; pop
        ret                             ; done

; plat_write(a0 = D-LS address (8-aligned), a1 = length): standard output
plat_write:                             ; clobbers t0..t2, a0, a1
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a3, 8(sp)                 ; callers keep values in a2..a4
        sd    a4, 16(sp)                ; ...
        sd    a2, 40(sp)                ; ...
        sd    a0, 24(sp)                ; the bytes
        sd    a1, 32(sp)                ; how many are left
pw_loop:                                ; one message per iteration
        ld    a0, 24(sp)                ; the bytes
        ld    a3, 32(sp)                ; their count
        addi  t1, a3, 7                 ; whole doublewords
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        li    t2, 64                    ; after the header
        tput  tg9, a0, c5, t2, t1       ; D-LS -> the buffer
        li    a0, 1                     ; handle 1
        li    a1, OP_WRITE              ; write
        li    a4, 0                     ; no mode
        call  pl_hcall                  ; a0 = bytes written
        blez  a0, pw_done               ; none: give up (a closed pipe, no handle)
        ld    a3, 32(sp)                ; all of them?
        sub   a3, a3, a0                ; a3 = bytes still to write
        sd    a3, 32(sp)                ; ...
        blez  a3, pw_done               ; yes
        ld    t0, 24(sp)                ; no (a full pipe): move the rest to the start
        add   t1, t0, a0                ; of the buffer (transfers start 8-aligned)
pw_mv:                                  ; a byte per iteration
        lbu   t2, 0(t1)                 ; ...
        sb    t2, 0(t0)                 ; ...
        addi  t0, t0, 1                 ; next
        addi  t1, t1, 1                 ; ...
        addi  a3, a3, -1                ; one fewer
        bnez  a3, pw_mv                 ; continue
        j     pw_loop                   ; and write them
pw_done:                                ; finished
        ld    a2, 40(sp)                ; restore
        ld    a4, 16(sp)                ; ...
        ld    a3, 8(sp)                 ; ...
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 48                ; pop
        ret                             ; done

; plat_key -> a0 = the next input byte (0x04 at the end of input). Input is
; read a message at a time (the cooked tty answers with a whole line).
plat_key:                               ; clobbers t0..t2, a0, a1
        ld    t0, pl_kpos(zero)         ; anything left in the buffer?
        ld    t1, pl_klen(zero)         ; ...
        bltu  t0, t1, pk_have           ; yes
        ld    t0, pl_keof(zero)         ; did the input end already?
        bnez  t0, pk_eof                ; yes: it stays ended
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a3, 8(sp)                 ; callers keep values in a2..a4
        sd    a4, 16(sp)                ; ...
        sd    a2, 24(sp)                ; ...
        li    a0, 0                     ; handle 0
        li    a1, OP_READ               ; read
        li    a3, PL_KSZ                ; at most a buffer full
        li    a4, 0                     ; blocking
        call  pl_hcall                  ; a0 = bytes, 0 at the end, < 0 on an error
        ld    a2, 24(sp)                ; restore
        ld    a4, 16(sp)                ; ...
        ld    a3, 8(sp)                 ; ...
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 32                ; pop
        blez  a0, pk_end                ; the end
        sd    a0, pl_klen(zero)         ; that many bytes
        addi  t1, a0, 7                 ; whole doublewords
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        la    t0, pl_kbuf               ; the buffer's data -> D-LS
        li    t2, 64                    ; ...
        tget  tg9, t0, c5, t2, t1       ; ...
        li    t0, 0                     ; start at its first byte
pk_have:                                ; t0 = position
        lbu   a0, pl_kbuf(t0)           ; the byte (waits for the tget)
        addi  t0, t0, 1                 ; advance
        sd    t0, pl_kpos(zero)         ; ...
        ret                             ; done
pk_end:                                 ; no more input
        li    t0, 1                     ; remember
        sd    t0, pl_keof(zero)         ; ...
pk_eof:                                 ; report the end
        li    a0, 4                     ; as Ctrl-D
        ret                             ; done

; plat_ticks -> a0 = microseconds since power-on, from the clock capability
; (svc CLOCK puts it into c7, the scratch register, for the read)
plat_ticks:                             ; clobbers t0..t2, a0
        li    a0, SVC_CLOCK             ; c7 = the clock (read-only timer NOW)
        svc                             ; ...
        la    t0, v_tick                ; 8 bytes of D-LS
        li    t2, 8                     ; NOW is an 8-byte register at port 0
        tget  tg10, t0, c7, zero, t2    ; read it
        ld    a0, v_tick(zero)          ; waits for the read
        cclear c7                       ; the scratch register is free again
        ret                             ; done

; plat_ms(a0 = milliseconds): sleep (a WAIT_REPLY with nothing awaited)
plat_ms:                                ; clobbers t0, a0, a1
        addi  sp, sp, -16               ; frame
        sd    a3, 0(sp)                 ; callers may keep values in a2, a3
        sd    a2, 8(sp)                 ; ...
        li    t0, 1000                  ; to timer ticks (1 us)
        mul   a2, a0, t0                ; a2 = the timeout
        li    a0, SVC_WAIT              ; WAIT_REPLY
        li    a1, -1                    ; no doorbell
        li    a3, -1                    ; awaiting nothing
        svc                             ; returns when the time is up
        ld    a2, 8(sp)                 ; restore
        ld    a3, 0(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

; plat_fget(a0 = D-LS, a1 = far address, a2 = bytes): far cache fill
plat_fget:                              ; from the heap capability
        tget  tg12, a0, c6, a1, a2      ; heap -> D-LS
        ret                             ; done
; plat_fput(a0 = D-LS, a1 = far address, a2 = bytes): far cache write-back
plat_fput:                              ; to the heap capability
        tput  tg12, a0, c6, a1, a2      ; D-LS -> heap
        ret                             ; done

; plat_source -> a0 = c0 offset of the embedded source text, a1 = its length.
; core.fs and os.fs are in the image's far section, which StrataOS placed in
; the arena at its own offsets.
plat_source:                            ; leaf
        la    a0, core_fs               ; start
        la    a1, core_fs_end           ; end
        sub   a1, a1, a0                ; length
        ret                             ; done

; plat_miss: trap_entry got an xmiss (v_tsave = t0): Forth has its own trap handler
; (faults become THROWs), so a code unit's miss comes here, not to the dispatcher.
; svc PAGE hands it over: the dispatcher pages the unit in, and eret retries the
; xcall / xret, every register as it was. A miss it cannot serve is a fault.
SVC_PAGE  = 14                          ; svc PAGE: a1 = the missed far address, a2 = the pc
plat_miss:                              ; in the trap handler
        sd    a0, v_tsave+8(zero)       ; keep what the svc uses
        sd    a1, v_tsave+16(zero)      ; ...
        sd    a2, v_tsave+24(zero)      ; ...
        li    a0, SVC_PAGE              ; PAGE
        csrr  a1, tval                  ; (bit 63: a return)
        csrr  a2, epc                   ; ...
        svc                             ; a0 = 0: it is in
        bnez  a0, pm_nopage             ; ...
        ld    a0, v_tsave+8(zero)       ; ...
        ld    a1, v_tsave+16(zero)      ; ...
        ld    a2, v_tsave+24(zero)      ; ...
        ld    t0, v_tsave(zero)         ; ...
        eret                            ; retry it
pm_nopage:                              ; not a unit: a fault after all
        j     te_fault                  ; ...

; plat_units -> a0 = code units the dispatcher paged in for us, a1 = cache slots in use
plat_units:                             ; clobbers a0, a1
        li    a0, 13                    ; svc UNITS
        svc                             ; ...
        ret                             ; ...

; plat_bye(a0 = exit code): end the process (the workers were told already)
plat_bye:                               ; never returns
        mv    a1, a0                    ; the code
        li    a0, SVC_EXIT              ; "end me"
        svc                             ; does not return
        halt                            ; (never reached; halt also exits)

; plat_tool(a0 = name, a1 = length) -> a0, a1 = name and length of the file
; that defines this word, if it is one of the tools loaded on demand (a0 = 0:
; it is not). The interpreter asks before it reports an undefined word.
; Names compare case-blind, like the dictionary's.
plat_tool:                              ; leaf; clobbers t0..t6
        la    t0, pl_tools              ; t0 = cursor in the table: u8 file, name, 0
pt_entry:                               ; one entry per iteration
        lbu   t1, 0(t0)                 ; t1 = its file number (0 ends the table)
        beqz  t1, pt_none               ; not a tool
        addi  t0, t0, 1                 ; t0 = the entry's name
        li    t3, 0                     ; t3 = index
pt_cmp:                                 ; compare with the word
        add   t4, t0, t3                ; the table's character
        lbu   t4, 0(t4)                 ; ...
        bgeu  t3, a1, pt_end            ; the word is used up
        beqz  t4, pt_skip               ; the table's name is shorter
        add   t5, a0, t3                ; the word's character
        lbu   t5, 0(t5)                 ; ...
        addi  t6, t5, -'A'              ; to lower case without a branch:
        sltiu t6, t6, 26                ;   1 for A..Z
        slli  t6, t6, 5                 ;   32 or 0
        add   t5, t5, t6                ;   added
        bne   t4, t5, pt_skip           ; they differ
        addi  t3, t3, 1                 ; next character
        j     pt_cmp                    ; continue
pt_end:                                 ; equal so far: equal if the table's name ends too
        beqz  t4, pt_hit                ; yes
pt_skip:                                ; next entry: skip past the name's zero
        lbu   t4, 0(t0)                 ; ...
        addi  t0, t0, 1                 ; ...
        bnez  t4, pt_skip               ; ...
        j     pt_entry                  ; continue
pt_hit:                                 ; t1 = 1: tools.fs; 2, 3, 4: see.fs, net.fs, udp.fs
        la    a0, pl_ftools             ; "/tools.fs"
        li    a1, 9                     ; ...
        addi  t1, t1, -1                ; file 1?
        beqz  t1, pt_ret                ; yes
        addi  t1, t1, -1                ; t1 = 0, 1, 2: the others have 7-byte names,
        slli  t2, t1, 3                 ; one after another from pl_fsee:
        sub   t1, t2, t1                ; t1 * 7
        la    a0, pl_fsee               ; ...
        add   a0, a0, t1                ; the name
        li    a1, 7                     ; its length
pt_ret:                                 ; a0, a1 = the file
        ret                             ; done
pt_none:                                ; not in the table
        li    a0, 0                     ; no file
        ret                             ; done

; plat_load(a0 = name, a1 = length, a2 = c0 offset, 8-aligned) -> a0 = the
; file's bytes, now at that offset in the arena, or a throw code (-309 no such
; file, -310 too large). Read through fs, PL_IOSZ bytes per message.
plat_load:                              ; clobbers t0..t2, a0..a5
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a2, 8(sp)                 ; where the text goes
        sd    zero, 16(sp)              ; bytes so far (or the error)
        sd    a1, 24(sp)                ; the name's length
        li    t0, PL_NAMEMAX            ; a name that long is no file
        bgtu  a1, t0, pl_nofile         ; ...
        la    t0, pl_iobuf              ; the name -> the bounce buffer
        li    t1, 0                     ; index
pl_nm:                                  ; a byte per iteration
        bgeu  t1, a1, pl_nmz            ; copied
        add   t2, a0, t1                ; source byte
        lbu   t2, 0(t2)                 ; ...
        add   a3, t0, t1                ; destination
        sb    t2, 0(a3)                 ; ...
        addi  t1, t1, 1                 ; next
        j     pl_nm                     ; continue
pl_nmz:                                 ; terminate it, as fs expects
        add   a3, t0, t1                ; ...
        sb    zero, 0(a3)               ; ...
        addi  t1, t1, 8                 ; the name and its zero, in whole doublewords
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        li    t2, 64                    ; after the header
        tput  tg9, t0, c5, t2, t1       ; D-LS -> the buffer
        li    a0, R_FS                  ; fs
        li    a1, OP_OPEN               ; open
        li    a2, 0                     ; (no handle)
        ld    a3, 24(sp)                ; the name's length
        li    a4, 0                     ; mode 0: read
        call  pl_call                   ; a0 = fs's id for the file, or an error
        bltz  a0, pl_nofile             ; no such file
        sd    a0, 32(sp)                ; the id
pl_rd:                                  ; a chunk per iteration
        li    a0, R_FS                  ; fs
        li    a1, OP_READ               ; read
        ld    a2, 32(sp)                ; the file
        li    a3, PL_IOSZ               ; a chunk
        li    a4, 0                     ; ...
        call  pl_call                   ; a0 = bytes, 0 at the end
        blez  a0, pl_cl                 ; the end
        sd    a0, 40(sp)                ; this chunk's bytes
        addi  t1, a0, 7                 ; whole doublewords
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        la    t0, pl_iobuf              ; the buffer's data -> D-LS
        li    t2, 64                    ; ...
        tget  tg9, t0, c5, t2, t1       ; ...
        ld    t2, 8(sp)                 ; where it goes in the arena
        ld    a3, 16(sp)                ; ...
        add   t2, t2, a3                ; ...
        add   a4, t2, t1                ; its end
        li    a5, A_PARCEL              ; the file area ends where the parcel starts
        bgtu  a4, a5, pl_big            ; too large
        tput  tg11, t0, c0, t2, t1      ; D-LS -> arena (ordered after the tget)
        ld    a0, 40(sp)                ; count the bytes
        add   a3, a3, a0                ; ...
        sd    a3, 16(sp)                ; ...
        li    t0, PL_IOSZ               ; a full chunk: there may be more
        bgeu  a0, t0, pl_rd             ; ...
pl_cl:                                  ; close the file
        li    a0, R_FS                  ; fs
        li    a1, OP_CLOSE              ; close
        ld    a2, 32(sp)                ; the file
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  pl_call                   ; ...
        ld    a0, 16(sp)                ; the length (or the error)
pl_ret:                                 ; common exit
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 48                ; pop
        ret                             ; done
pl_big:                                 ; it does not fit
        li    t0, -310                  ; file too large
        sd    t0, 16(sp)                ; (returned after the close)
        j     pl_cl                     ; ...
pl_nofile:                              ; fs does not know it
        li    a0, -309                  ; no such file
        j     pl_ret                    ; ...

; -----------------------------------------------------------------------------
; Threads: the parcel (thread 0's side)
; -----------------------------------------------------------------------------
; plat_publish: a copy of the compiled code goes into the parcel, at the
; offsets a worker reads it from (parcel offset == I-LS address). The copy
; starts at the last 1 KiB boundary below the end of the kernel, which every
; worker already has.
plat_publish:                           ; clobbers t0..t6
        li    t3, (kpage >> 10) << 10   ; t3 = cursor
        ld    t4, v_chere(zero)         ; t4 = end of the code
pp_loop:                                ; a chunk per iteration, through the bounce buffer
        bgeu  t3, t4, pp_done           ; all copied
        la    t5, pl_iobuf              ; the bounce buffer
        li    t6, PL_IOSZ               ; a chunk
        tget  tg13, t5, c0, t3, t6      ; mirror -> D-LS
        li    t0, A_PARCEL              ; its place in the parcel
        add   t0, t0, t3                ; ...
        tput  tg13, t5, c0, t0, t6      ; D-LS -> parcel (ordered after the tget)
        addi  t3, t3, PL_IOSZ           ; next chunk
        j     pp_loop                   ; continue
pp_done:                                ; the snapshot follows (publish in forth.s)
        ret                             ; done

; plat_lend(t0 = worker): give it the parcel. Keeps t0; clobbers t1.
plat_lend:                              ; leaf
        li    t1, A_PARCEL              ; c0 keeps [0, A_PARCEL): mirror, source, files
        csplit c7, c0, t1               ; c7 = the parcel
        cgive c7, t0                    ; the worker installs from it and gives it back
        ret                             ; done

; plat_home: the parcel came back into the scratch register: join it to c0
plat_home:                              ; leaf; clobbers nothing
        cjoin c0, c7                    ; c0 = [0, A_HEAP) again
        ret                             ; done

; -----------------------------------------------------------------------------
; Threads: a worker (entered from the stub in boot.s with c0 = its page)
; -----------------------------------------------------------------------------
plat_worker:                            ; a worker thread
        li    sp, RS_TOP                ; return stack at the top of the D-LS
        ctake c5, zero                  ; our message buffer
        ctake c1, zero                  ; a copy of the job board
        ctake c2, zero                  ; copies of thread 0's endpoints: fs,
        ctake c3, zero                  ; tty,
        ctake c4, zero                  ; pipe
w_loop:                                 ; wait for thread 0
        ctake c7, zero                  ; the parcel, or a doorbell
        cperms t0, c7                   ; t0 = space << 8 | permissions
        andi  t0, t0, P_X               ; executable memory?
        beqz  t0, w_job                 ; no: the doorbell
        li    t1, B_CEND                ; board offset of the published code end
        tamo.add t1, c1, t1, zero       ; t1 = code end (an atomic add of 0 is a read)
        li    t3, (kpage >> 10) << 10   ; t3 = cursor: where the parcel's copy starts
wl_code:                                ; a chunk per iteration: parcel -> our page -> I-LS
        bgeu  t3, t1, wl_snap           ; all installed
        li    t5, DS_BOTTOM             ; bounce through the (empty) data stack area
        li    t6, PL_IOSZ               ; a chunk
        tget  tg13, t5, c7, t3, t6      ; parcel -> D-LS (parcel offset == I-LS address)
        li    t4, ORIGIN                ; our page holds address a at offset a - ORIGIN
        sub   t4, t3, t4                ; ...
        tput  tg13, t5, c0, t4, t6      ; D-LS -> our mirror (ordered after the tget)
        tgetx tg13, t3, c0, t4, t6      ; mirror -> I-LS
        addi  t3, t3, PL_IOSZ           ; next chunk
        j     wl_code                   ; continue
wl_snap:                                ; the data space
        li    t1, B_SNAP                ; board offset of the snapshot length
        tamo.add t2, c1, t1, zero       ; t2 = snapshot bytes
        li    t1, PG_SNAP               ; where the snapshot is in the parcel
        tget  tg13, zero, c7, t1, t2    ; it arrives at D-LS 0
        cgive c7, zero                  ; give the parcel back (completes after our transfers)
        j     w_loop                    ; and wait for the job
w_job:                                  ; the doorbell: a job or a halt
        cclear c7                       ; drop the doorbell (a copy)
        csrr  t0, coreid                ; t0 = our thread number
        slli  t0, t0, 7                 ; times SLOT_SZ (128)
        addi  t0, t0, B_SLOTS + S_CMD   ; t0 = board offset of our command
        tamo.add t1, c1, t0, zero       ; t1 = the command
        li    t2, CMD_RUN               ; t2 = run
        bne   t1, t2, w_halt            ; anything else: stop
        cbase t0, c5                    ; replies to our messages come back in our own buffer:
        sd    t0, pl_bufb(zero)         ; that is the base we wait for (the snapshot had thread 0's)
        li    t0, ORIGIN                ; and our mirror starts at offset 0 of our page
        sd    t0, v_moff(zero)          ; (xexec installs its trampolines there)
        call  worker_run                ; run the job (it rings back when done)
        j     w_loop                    ; next
w_halt:                                 ; thread 0 said bye
        li    a0, 0                     ; exit code
        halt                            ; this thread ends
