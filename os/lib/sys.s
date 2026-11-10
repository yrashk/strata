; =============================================================================
; sys.s: the StrataOS 0.1 program library
; =============================================================================
;
; StrataOS 0.1 is a microkernel. A program never calls the kernel for files,
; the console or pipes: it sends a *message* to a server process. A message
; is the program's 4 KiB message buffer (capability c5, the last 4 KiB of its
; arena): the program writes a 64-byte header (and data after it) into the
; buffer, *lends* the buffer to the server with `csend c5, cE` through a
; send-only endpoint cE, and asks its core's kernel to wait with
; `svc` WAIT_REPLY. The server answers by giving the same buffer back with
; the result filled in; the buffer is in c5 again when the svc returns.
;
; Request header (bytes):  0 op   8 handle   16 length   24 mode   32 result
;   40 sender pid (stamped by the receiving core's kernel; servers trust it)
;   48..63 reserved; data from 64 (at most 4032 bytes per message).
; Results: >= 0 success; -1 failed, -2 interrupted, -3 would block, -4 no such
; file or program, -5 no free core, -6 no memory, -7 busy, -8 timed out.
;
; Capability registers of a time-shared process (the kernel saves c0..c7 on
; every context switch; c8..c15 do not survive a switch):
;   c0 the arena's program memory (832 KiB with one thread: [0, 0xD0000))
;   c1 endpoint of `proc` (processes, names)   c2 endpoint of `fs` (files)
;   c3 endpoint of `tty` (console)             c4 endpoint of `pipe`
;   c5 the message buffer                      c6 capabilities that arrive
;   c7 the clock: read-only timer NOW/FREQ        with a reply land here
; A reply may carry up to two capabilities: they arrive in c6 and c7 (the
; second one replaces the clock; `sys_clock` gets it back). Keep c6 free of
; linear capabilities while a call is out: what arrives would be dropped.
; A request may carry one too (an ATTACHMENT, e.g. a piece of the arena lent
; to the window server): send it with sys_msga, which uses svc SEND so that
; the attachment and the message leave together. Never `csend` it yourself:
; another process of the same core could send between the two, and the
; attachment would ride with its message.
;
; Handles: 0 stdin, 1 stdout, 2 stderr; more from sys_open / sys_pipe. Each
; handle names a server (its endpoint register: 2 fs, 3 tty, 4 pipe) and the
; server's id for it. READ, WRITE and CLOSE go to the handle's server.
;
; Every program starts like this (the kernel runs a program time-shared only
; if its second code word is the marker "SYS2"; anything else is a
; bare-metal program: it runs as threads in a window of cores):
;
;   _start: j     main                  ; skip the marker
;           .word 0x32535953            ; "SYS2": a StrataOS 0.1 program
;   main:   li    sp, 65536             ; stack at the top of the D-LS
;           call  sys_init              ; handles, arguments
;           ...
;           li    a0, 0                 ; exit code
;           call  sys_exit              ; flush stdout, end the process
;
; Calls clobber t0..t6 and a0..a7; s registers, sp, gp and tp are kept.
; Transfer tag tg10 belongs to the library.
;
; The API (stable; other agents' programs rely on it):
;   start/exit   sys_init, sys_exit(code), sys_pid, sys_cmdline -> a0 text, a1 len,
;                sys_args(buf) -> len, arg_next(cursor, end) -> word, len, next
;   handles      sys_read(h, buf, max) -> n (0 end, -2 interrupted), sys_readnb (-3 if
;                nothing), sys_write(h, buf, len), sys_close(h), sys_open(name, len,
;                mode 0 read / 1 write / 2 append) -> h, sys_pipe -> a0 read h, a1 write h,
;                sys_hdesc(h) -> descriptor, sys_hset(h, descriptor) (rearrange handles)
;   processes    sys_spawn(ncores, mode, cmd, len, h0, h1, h2) -> pid  (mode bit0: no
;                server endpoints; bit1: pin to core mode >> 8; ncores 0 = one thread,
;                N = N threads on N cores), sys_wait(pid or 0, nb) -> status, a1 = pid,
;                sys_kill(pid), sys_signal(pid), sys_catch(on), sys_ps(buf) -> n,
;                sys_info(buf), sys_cores(buf) -> n, sys_lookup(name, len, reg),
;                sys_sched(0, buf) / sys_sched(1, slice ticks)  (the time slice),
;                sys_register(name, len)
;   console      sys_conmode(0 cooked / 1 raw), sys_setfg(pid)
;   files        sys_dir(buf) -> n (32-byte records: name[24], u64 size), sys_unlink,
;                sys_stat(name, len) -> size, sys_statfs(buf), sys_readblk(n, buf);
;                names are paths ("/tag/tag/name": the file must carry the tags;
;                one without the leading "/" is under the current tag path),
;                sys_cwd(buf) -> len, sys_chdir(path, len, buf) -> len (cd)
;   tags         sys_query(buf, path, len) -> n (DIR of a tag path), sys_tags(buf,
;                path or 0, len) -> n (32-byte records: name[16], u64 files, u64
;                number), sys_tag(name, len, tag, len), sys_untag(name, len, tag, len)
;   devices      sys_devs(buf) -> n, sys_halt, sys_grantfb() (ws only: c6 memory, c7 ports)
;   time         sys_now -> ticks (1 us), sys_sleep(ticks) -> -8 / -2,
;                sys_notify_wait(timeout) -> bits / -8, sys_yield, sys_clock,
;                sys_mirror(offset, len) (programs that generate code),
;                sys_scratch(start, len) (D-LS not kept across switches)
;   messages     sys_msg(ep reg, op, handle, len, mode) -> result (data: sys_put before,
;                sys_get after), sys_msga(..., attachment reg): the same with a
;                capability attached (the only safe way to attach one)
;   window       ws_call(op, handle, data, len) through the endpoint in register ws_reg
;   output       out_str, out_chr, out_nl, out_dec, out_sdec, out_decw, out_pad,
;                out_hex, out_flush, err_str; input: in_line(buf, max) -> len / -1 / -2
;   strings      str_atoi, str_num, str_eq, str_has, str_len
; Exit status (sys_wait): bits 0..31 the code, bit 62 killed, bit 63 faulted
; (cause in bits 0..7).

; ---- message operations (by server) ------------------------------------------
OP_READ    = 1                          ; fs, tty, pipe: read a handle
OP_WRITE   = 2                          ; fs, tty, pipe: write a handle
OP_OPEN    = 3                          ; fs: open a file
OP_CLOSE   = 4                          ; fs, tty, pipe: close a handle
OP_SPAWN   = 5                          ; proc: start a program
OP_WAIT    = 6                          ; proc: wait for a child
OP_KILL    = 7                          ; proc: kill a process
OP_PIPE    = 8                          ; pipe: make a pipe
OP_PS      = 9                          ; proc: list processes
OP_DIR     = 10                         ; fs: list files
OP_UNLINK  = 11                         ; fs: delete a file
OP_TAG     = 12                         ; fs: give a file a tag
OP_UNTAG   = 13                         ; fs: take a tag from a file
OP_TAGS    = 14                         ; fs: list tags (all, or a file's)
OP_INFO    = 16                         ; proc: system summary
OP_SIGNAL  = 17                         ; proc: interrupt a process
OP_SETFG   = 18                         ; tty: the foreground process
OP_CONMODE = 19                         ; tty: cooked / raw
OP_CATCH   = 22                         ; proc: catch interrupts
OP_DEVS    = 23                         ; dev: the platform table
OP_HALT    = 24                         ; dev: stop the machine
OP_LOOKUP  = 25                         ; proc: a server's endpoint by name
OP_GRANTFB = 26                         ; dev: the framebuffer (for ws)
OP_STAT    = 27                         ; fs: a file's size
OP_REGISTER = 29                        ; proc: become a named server
OP_SCHED   = 30                         ; proc: the time slice and switch rates
OP_CORES   = 31                         ; proc: what every core is doing
OP_WHOIS   = 39                         ; proc: the pid registered under a name (dev, for GRANT_FB)
OP_STATFS  = 32                         ; fs: disk blocks (total, used, files)
OP_READBLK = 33                         ; fs: a raw disk block
OP_WCREATE = 40                         ; ws: create a window (surface in c6)
OP_WDAMAGE = 41                         ; ws: a rectangle changed
OP_WTEXT   = 42                         ; ws: draw text
OP_WFILL   = 43                         ; ws: fill a rectangle
OP_WEVENT  = 44                         ; ws: wait for an event
OP_WDESTROY = 45                        ; ws: close a window

; ---- svc functions (a0) --------------------------------------------------------
SVC_WAIT   = 1                          ; WAIT_REPLY: a1 doorbell core, a2 timeout, a3 awaited base
SVC_RECV   = 2                          ; RECEIVE (servers)
SVC_REPLY  = 3                          ; REPLY (servers)
SVC_YIELD  = 4                          ; YIELD
SVC_EXIT   = 5                          ; EXIT: a1 = code
SVC_NOTIFY = 6                          ; NOTIFY_WAIT: a2 timeout -> notification bits
SVC_MIRROR = 7                          ; SET_MIRROR: a1 arena offset, a2 length of a code mirror
SVC_CLOCK  = 10                         ; c7 = the clock again
SVC_SCRATCH = 11                        ; SET_SCRATCH: a1 D-LS start, a2 length (0: none)
SVC_SEND   = 12                         ; SEND: a1 endpoint register, a5 attachment register; then as WAIT_REPLY

SYS_MAX    = 4032                       ; data bytes per message
SYS_START  = 0x7F000                    ; arena offset of the start-up block (written by proc)
NHAND      = 8                          ; handles per process
E_INTR     = -2                         ; "interrupted"
E_TIMEOUT  = -8                         ; "timed out"

        .data                           ; library state in the program's D-LS
        .align 8                        ; transfer buffers must be 8-byte aligned
sys_hdr:   .space 64                    ; the request header being built / answered
sys_buf:   .space 4096                  ; staging for message data (aligned for transfers)
sys_start: .space 512                   ; the start-up block: pid, parent, handles, command line
sys_bufb:  .dword 0                     ; base of our message buffer (what the kernel waits for)
sys_intrf: .dword 0                     ; an interrupt arrived while we waited (-2 seen)
sys_htab:  .space NHAND * 16            ; handles: {server register, server id}, register 0 = free
out_buf:   .space 4096                  ; buffered standard output
out_len:   .dword 0                     ; bytes waiting in out_buf
in_buf:    .space 4096                  ; buffered standard input
in_pos:    .dword 0                     ; next byte to hand out
in_len:    .dword 0                     ; bytes in in_buf
in_eof:    .dword 0                     ; standard input has ended
sys_num:   .space 24                    ; digits for out_dec / out_hex
sys_num_end:                            ; one past them
sys_nl:    .ascii "\n"                  ; a newline
sys_hexd:  .ascii "0123456789abcdef"    ; hex digits

        .text                           ; library code

; =============================================================================
; Start-up and exit
; =============================================================================

; sys_init(): read the start-up block and set up handles 0..2
sys_init:
        cbase t0, c5                    ; our message buffer's base:
        la    t1, sys_bufb              ;   the kernel recognises our replies by it
        sd    t0, 0(t1)                 ; ...
        la    t0, sys_start             ; the start-up block -> D-LS
        li    t1, SYS_START             ; (proc wrote it into our arena)
        li    t2, 512                   ; its size
        tget  tg10, t0, c0, t1, t2      ; arena -> D-LS
        la    t3, sys_htab              ; clear the handle table
        li    t4, NHAND * 2             ; words in it
si_clr:
        sd    zero, 0(t3)               ; clear a word (the first store waits for nothing)
        addi  t3, t3, 8                 ; next
        addi  t4, t4, -1                ; one fewer
        bnez  t4, si_clr                ; continue
        li    t5, 0                     ; t5 = handle 0..2
si_h:
        slli  t6, t5, 3                 ; its descriptor: start-up block offset 16 + 8 h
        add   t6, t0, t6                ; ...
        ld    t6, 16(t6)                ; server register << 32 | id, or -1 (waits for the tget)
        bltz  t6, si_hn                 ; none
        la    t3, sys_htab              ; the handle's entry
        slli  t4, t5, 4                 ; 16 bytes each
        add   t3, t3, t4                ; ...
        srli  t4, t6, 32                ; server register
        sd    t4, 0(t3)                 ; ...
        slli  t4, t6, 32                ; server id: the low half
        srli  t4, t4, 32                ; ...
        sd    t4, 8(t3)                 ; ...
si_hn:
        addi  t5, t5, 1                 ; next handle
        li    t6, 3                     ; three standard handles
        blt   t5, t6, si_h              ; continue
        ret                             ; done

; sys_pid() -> a0 = our process id
sys_pid:
        la    t0, sys_start             ; the start-up block
        ld    a0, 0(t0)                 ; pid
        ret                             ; done

; sys_exit(a0 = code): flush standard output and end the process
sys_exit:
        addi  sp, sp, -16               ; frame
        sd    a0, 8(sp)                 ; keep the code
        call  out_flush                 ; nothing written may be lost
        ld    a1, 8(sp)                 ; the code
        li    a0, SVC_EXIT              ; "end me"
        svc                             ; does not return
        halt                            ; (never reached; halt also exits)

; =============================================================================
; The message call
; =============================================================================

; sys_msg(a0 = endpoint register 1..7, a1 = op, a2 = handle, a3 = length,
;         a4 = mode) -> a0 = result. Data must already be in the buffer.
sys_msg:
        la    t0, sys_hdr               ; build the header
        sd    a1, 0(t0)                 ; op
        sd    a2, 8(t0)                 ; handle
        sd    a3, 16(t0)                ; length
        sd    a4, 24(t0)                ; mode
        sd    zero, 32(t0)              ; result
        li    t1, 64                    ; header size
        tput  tg10, t0, c5, zero, t1    ; D-LS -> the buffer
        twait 1 << 10                   ; the header must be in before the buffer leaves
        la    t2, sm_tab                ; send through endpoint register a0:
        slli  t3, a0, 4                 ;   16 bytes per table entry
        add   t2, t2, t3                ;   ...
        jr    t2                        ;   (each entry sends and goes to sm_sent)
sm_tab:
        li    a1, -1                    ; c0: not an endpoint
        j     sm_fail                   ; .
        nop                             ; .
        nop                             ; .
        csend c5, c1                    ; c1: proc
        cbase a1, c1                    ; a1 = the core it names (for the doorbell)
        j     sm_sent                   ; .
        nop                             ; .
        csend c5, c2                    ; c2: fs
        cbase a1, c2                    ; .
        j     sm_sent                   ; .
        nop                             ; .
        csend c5, c3                    ; c3: tty
        cbase a1, c3                    ; .
        j     sm_sent                   ; .
        nop                             ; .
        csend c5, c4                    ; c4: pipe
        cbase a1, c4                    ; .
        j     sm_sent                   ; .
        nop                             ; .
        li    a1, -1                    ; c5: the buffer itself
        j     sm_fail                   ; .
        nop                             ; .
        nop                             ; .
        csend c5, c6                    ; c6: an endpoint from LOOKUP
        cbase a1, c6                    ; .
        j     sm_sent                   ; .
        nop                             ; .
        csend c5, c7                    ; c7: an endpoint from LOOKUP
        cbase a1, c7                    ; .
        j     sm_sent                   ; .
        nop                             ; .
sm_sent:
        li    a0, SVC_WAIT              ; wait for the buffer to come back
        li    a2, -1                    ; no timeout
        li    a3, 0                     ; awaited: our own buffer
        svc                             ; a0 = 0, or -2 if an interrupt woke us first
        bnez  a0, sm_again              ; the buffer is still out: keep waiting
sm_back:
        la    t0, sys_hdr               ; the answered header -> D-LS
        li    t1, 64                    ; ...
        tget  tg10, t0, c5, zero, t1    ; ...
        ld    a0, 32(t0)                ; the result (the load waits for the tget)
        ret                             ; done
sm_again:
        la    t0, sys_intrf             ; remember the interrupt for the program
        li    t1, 1                     ; ...
        sd    t1, 0(t0)                 ; ...
        li    a1, -1                    ; no doorbell this time
        j     sm_sent                   ; and wait again: the server answers every request
sm_fail:
        mv    a0, a1                    ; -1
        ret                             ; done

; sys_msga(a0 = endpoint register 1..7, a1 = op, a2 = handle, a3 = length,
;          a4 = mode, a5 = register 0..7 of a capability to attach) -> a0 =
; result. Like sys_msg, but the capability in register a5 travels with the
; message (the server gets it in c7; what the server sends back arrives in
; c6, then c7). The kernel sends both in one step (svc SEND), so no other
; process of this core can get between the attachment and its message:
; always attach this way, never with a `csend` of your own before sys_msg.
; -1 (nothing sent) if a register is empty or not an endpoint.
sys_msga:
        la    t0, sys_hdr               ; build the header
        sd    a1, 0(t0)                 ; op
        sd    a2, 8(t0)                 ; handle
        sd    a3, 16(t0)                ; length
        sd    a4, 24(t0)                ; mode
        sd    zero, 32(t0)              ; result
        li    t1, 64                    ; header size
        tput  tg10, t0, c5, zero, t1    ; D-LS -> the buffer
        twait 1 << 10                   ; the header must be in before the buffer leaves
        mv    a1, a0                    ; the endpoint's register
        li    a0, SVC_SEND              ; send both, then wait for the buffer to come back
        li    a2, -1                    ; no timeout
        li    a3, 0                     ; awaited: our own buffer
        li    a4, 0                     ; ...
        svc                             ; a0 = 0, -2 interrupted first, -1 not sent
        beqz  a0, sm_back               ; answered
        li    a1, -1                    ; not sent?
        beq   a0, a1, sm_fail           ; ...
        j     sm_again                  ; interrupted: the buffer is still out, keep waiting

; sys_put(a0 = address, a1 = length): data -> the buffer at offset 64
sys_put:
        la    t0, sys_buf               ; copy into the aligned staging buffer
        li    t1, 0                     ; index
spu_copy:
        beq   t1, a1, spu_send          ; copied
        add   t2, a0, t1                ; source byte
        lbu   t2, 0(t2)                 ; ...
        add   t3, t0, t1                ; destination
        sb    t2, 0(t3)                 ; ...
        addi  t1, t1, 1                 ; next
        j     spu_copy                  ; continue
spu_send:
        li    t3, SYS_MAX               ; a full message has no room for a terminator
        bgeu  t1, t3, spu_full          ; (it must not run past the 4 KiB buffer)
        add   t3, t0, t1                ; terminate with a zero byte (names, command lines)
        sb    zero, 0(t3)               ; ...
        addi  t1, t1, 1                 ; (the zero is sent too)
spu_full:
        addi  t1, t1, 7                 ; whole words
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        li    t2, 64                    ; after the header
        tput  tg10, t0, c5, t2, t1      ; D-LS -> the buffer
        ret                             ; done (sys_msg's twait orders it before the send)

; sys_get(a0 = address, a1 = length): the buffer's data (offset 64) -> a0
sys_get:
        beqz  a1, sg_done               ; nothing
        la    t0, sys_buf               ; staging
        li    t1, 64                    ; from the data
        addi  t2, a1, 7                 ; whole words
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        tget  tg10, t0, c5, t1, t2      ; the buffer -> D-LS
        li    t1, 0                     ; copy to the caller
sg_copy:
        beq   t1, a1, sg_done           ; copied
        add   t2, t0, t1                ; source byte (waits for the tget)
        lbu   t2, 0(t2)                 ; ...
        add   t3, a0, t1                ; destination
        sb    t2, 0(t3)                 ; ...
        addi  t1, t1, 1                 ; next
        j     sg_copy                   ; continue
sg_done:
        ret                             ; done

; sys_word(a0 = index) -> a0 = the 64-bit word data[index] of the last reply
sys_word:
        la    t0, sys_buf               ; staging
        slli  t1, a0, 3                 ; byte offset in the data
        addi  t1, t1, 64                ; in the buffer
        li    t2, 8                     ; one word
        tget  tg10, t0, c5, t1, t2      ; the buffer -> D-LS
        ld    a0, 0(t0)                 ; the word (waits for the tget)
        ret                             ; done

; =============================================================================
; Handles
; =============================================================================

; sys_hent(a0 = handle) -> a0 = its table entry, or 0 if the handle is not open
sys_hent:
        li    t0, NHAND                 ; in range?
        bgeu  a0, t0, sh_none           ; no
        la    t0, sys_htab              ; the entry
        slli  t1, a0, 4                 ; ...
        add   a0, t0, t1                ; ...
        ld    t1, 0(a0)                 ; its server register
        beqz  t1, sh_none               ; free
        ret                             ; done
sh_none:
        li    a0, 0                     ; not open
        ret                             ; done

; sys_hnew(a0 = server register, a1 = server id) -> a0 = a new handle, or -1
sys_hnew:
        la    t0, sys_htab              ; look for a free entry from 3 up
        li    t1, 3                     ; ...
shn_loop:
        li    t2, NHAND                 ; none left?
        bge   t1, t2, shn_full          ; ...
        slli  t3, t1, 4                 ; the entry
        add   t3, t0, t3                ; ...
        ld    t4, 0(t3)                 ; free?
        beqz  t4, shn_take              ; yes
        addi  t1, t1, 1                 ; next
        j     shn_loop                  ; continue
shn_take:
        sd    a0, 0(t3)                 ; server register
        sd    a1, 8(t3)                 ; server id
        mv    a0, t1                    ; the handle
        ret                             ; done
shn_full:
        li    a0, -1                    ; no free handle
        ret                             ; done

; sys_hdesc(a0 = handle) -> a0 = its descriptor (server << 32 | id), or -1
sys_hdesc:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save ra
        call  sys_hent                  ; the entry
        beqz  a0, shd_none              ; not open
        ld    t0, 0(a0)                 ; server register
        ld    t1, 8(a0)                 ; id
        slli  t0, t0, 32                ; combine
        or    a0, t0, t1                ; ...
        j     shd_ret                   ; return
shd_none:
        li    a0, -1                    ; none
shd_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 8                 ; release the frame
        ret                             ; done

; sys_hset(a0 = handle, a1 = descriptor or -1): make a handle name that
; (used by sh to rearrange its own handles); returns nothing
sys_hset:
        li    t0, NHAND                 ; in range?
        bgeu  a0, t0, shs_ret           ; no
        la    t0, sys_htab              ; the entry
        slli  t1, a0, 4                 ; ...
        add   t0, t0, t1                ; ...
        sd    zero, 0(t0)               ; assume none
        sd    zero, 8(t0)               ; ...
        bltz  a1, shs_ret               ; none
        srli  t1, a1, 32                ; server register
        sd    t1, 0(t0)                 ; ...
        slli  t1, a1, 32                ; id
        srli  t1, t1, 32                ; ...
        sd    t1, 8(t0)                 ; ...
shs_ret:
        ret                             ; done

; sys_read(a0 = handle, a1 = address, a2 = maximum) -> a0 = bytes (0 at end), or < 0
; sys_readnb: the same, but -3 instead of blocking
sys_readnb:
        li    a4, 1                     ; mode bit 0: do not block
        j     srd_go                    ; shared path
sys_read:
        li    a4, 0                     ; mode: block
srd_go:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; destination
        li    t0, SYS_MAX               ; at most one message of data
        bleu  a2, t0, srd_n             ; ...
        mv    a2, t0                    ; ...
srd_n:
        sd    a2, 16(sp)                ; the maximum
        call  sys_hent                  ; the handle's entry
        beqz  a0, srd_bad               ; not open
        ld    a2, 8(a0)                 ; server id
        ld    a0, 0(a0)                 ; server register
        li    a1, OP_READ               ; the request
        ld    a3, 16(sp)                ; length wanted
        call  sys_msg                   ; a0 = bytes or error
        blez  a0, srd_ret               ; nothing came
        mv    a1, a0                    ; copy them out
        sd    a0, 16(sp)                ; (keep the count)
        ld    a0, 8(sp)                 ; ...
        call  sys_get                   ; ...
        ld    a0, 16(sp)                ; the count
        j     srd_ret                   ; return
srd_bad:
        li    a0, -1                    ; not a handle
srd_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; sys_write(a0 = handle, a1 = address, a2 = length) -> a0 = bytes written, or < 0
sys_write:
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; handle
        sd    a1, 16(sp)                ; source
        sd    a2, 24(sp)                ; bytes left
        sd    zero, 32(sp)              ; bytes written
sw_loop:
        ld    a2, 24(sp)                ; bytes left
        beqz  a2, sw_done               ; none
        li    t0, SYS_MAX               ; at most one message per call
        bleu  a2, t0, sw_n              ; ...
        mv    a2, t0                    ; ...
sw_n:
        sd    a2, 40(sp)                ; this chunk
        ld    a0, 16(sp)                ; its bytes -> the buffer
        mv    a1, a2                    ; ...
        call  sys_put                   ; ...
        ld    a0, 8(sp)                 ; the handle's entry
        call  sys_hent                  ; ...
        beqz  a0, sw_bad                ; not open
        ld    a2, 8(a0)                 ; server id
        ld    a0, 0(a0)                 ; server register
        li    a1, OP_WRITE              ; the request
        ld    a3, 40(sp)                ; length
        li    a4, 0                     ; (no mode)
        call  sys_msg                   ; a0 = written
        blez  a0, sw_err                ; nothing written: stop
        ld    t0, 16(sp)                ; advance
        add   t0, t0, a0                ; ...
        sd    t0, 16(sp)                ; ...
        ld    t0, 24(sp)                ; ...
        sub   t0, t0, a0                ; ...
        sd    t0, 24(sp)                ; ...
        ld    t0, 32(sp)                ; ...
        add   t0, t0, a0                ; ...
        sd    t0, 32(sp)                ; ...
        j     sw_loop                   ; continue
sw_err:
        ld    t0, 32(sp)                ; anything written before?
        bnez  t0, sw_done               ; yes: report that
        j     sw_ret                    ; no: report the error in a0
sw_bad:
        li    a0, -1                    ; not a handle
        j     sw_ret                    ; return
sw_done:
        ld    a0, 32(sp)                ; bytes written
sw_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 48                ; release the frame
        ret                             ; done

; sys_close(a0 = handle) -> a0 = result
sys_close:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        call  sys_hent                  ; the entry
        beqz  a0, scl_bad               ; not open
        sd    a0, 8(sp)                 ; keep it
        ld    a2, 8(a0)                 ; server id
        ld    a0, 0(a0)                 ; server register
        li    a1, OP_CLOSE              ; the request
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = result
        ld    t0, 8(sp)                 ; the handle is free now
        sd    zero, 0(t0)               ; ...
        sd    zero, 8(t0)               ; ...
        j     scl_ret                   ; return
scl_bad:
        li    a0, -1                    ; not a handle
scl_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

; sys_open(a0 = name, a1 = length, a2 = mode: 0 read, 1 write, 2 append) -> a0 = handle or < 0
sys_open:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; name length
        sd    a2, 16(sp)                ; mode
        call  sys_put                   ; the name -> the buffer
        li    a0, 2                     ; fs
        li    a1, OP_OPEN               ; the request
        li    a2, 0                     ; (no handle)
        ld    a3, 8(sp)                 ; name length
        ld    a4, 16(sp)                ; mode
        call  sys_msg                   ; a0 = fs id or error
        bltz  a0, sop_ret               ; failed
        mv    a1, a0                    ; a handle for it
        li    a0, 2                     ; (fs)
        call  sys_hnew                  ; a0 = handle or -1
sop_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; sys_pipe() -> a0 = read handle, a1 = write handle (a0 < 0 on failure)
sys_pipe:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        li    a0, 4                     ; pipe
        li    a1, OP_PIPE               ; the request
        li    a2, 0                     ; ...
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = read id | write id << 8
        bltz  a0, spi_ret               ; failed
        sd    a0, 8(sp)                 ; keep both ids
        andi  a1, a0, 255               ; the read end
        li    a0, 4                     ; (pipe)
        call  sys_hnew                  ; a handle
        bltz  a0, spi_ret               ; none left
        ld    t0, 8(sp)                 ; the write end
        sd    a0, 8(sp)                 ; keep the read handle
        srli  a1, t0, 8                 ; ...
        andi  a1, a1, 255               ; ...
        li    a0, 4                     ; (pipe)
        call  sys_hnew                  ; a handle
        mv    a1, a0                    ; write handle
        ld    a0, 8(sp)                 ; read handle
spi_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

; =============================================================================
; proc: processes and names
; =============================================================================

; sys_spawn(a0 = ncores (0 = time-shared), a1 = mode (bit0 no server
; endpoints, bit1 pin to core a1 >> 8), a2 = command line, a3 = its length,
; a4 = handle for the child's 0, a5 = for 1, a6 = for 2 (-1 = none)) -> a0 = pid
sys_spawn:
        addi  sp, sp, -64               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; ncores
        sd    a1, 16(sp)                ; mode
        sd    a2, 24(sp)                ; command line
        sd    a3, 32(sp)                ; its length
        sd    a5, 48(sp)                ; handle for 1
        sd    a6, 56(sp)                ; handle for 2
        mv    a0, a4                    ; descriptor of handle 0
        call  sys_hdesc                 ; ...
        la    t0, sys_buf               ; data: ncores, d0, d1, d2, command line
        sd    a0, 8(t0)                 ; d0
        ld    a0, 48(sp)                ; descriptor of handle 1
        call  sys_hdesc                 ; ...
        la    t0, sys_buf               ; ...
        sd    a0, 16(t0)                ; d1
        ld    a0, 56(sp)                ; descriptor of handle 2
        call  sys_hdesc                 ; ...
        la    t0, sys_buf               ; ...
        sd    a0, 24(t0)                ; d2
        ld    t1, 8(sp)                 ; ncores
        sd    t1, 0(t0)                 ; ...
        ld    t1, 32(sp)                ; command line length
        li    t2, 440                   ; at most 440 bytes
        bleu  t1, t2, ssp_l             ; ...
        mv    t1, t2                    ; ...
ssp_l:
        sd    t1, 32(sp)                ; (clipped)
        li    t2, 0                     ; copy it after the four words
ssp_copy:
        beq   t2, t1, ssp_cd            ; copied
        ld    t3, 24(sp)                ; source
        add   t3, t3, t2                ; ...
        lbu   t3, 0(t3)                 ; ...
        add   t4, t0, t2                ; destination
        sb    t3, 32(t4)                ; ...
        addi  t2, t2, 1                 ; next
        j     ssp_copy                  ; continue
ssp_cd:
        add   t4, t0, t2                ; a terminating zero
        sb    zero, 32(t4)              ; ...
        addi  t1, t1, 40                ; bytes: 32 + text + zero, whole words
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        li    t2, 64                    ; after the header
        tput  tg10, t0, c5, t2, t1      ; D-LS -> the buffer
        li    a0, 1                     ; proc
        li    a1, OP_SPAWN              ; the request
        li    a2, 0                     ; ...
        ld    a3, 32(sp)                ; command line length
        ld    a4, 16(sp)                ; mode
        call  sys_msg                   ; a0 = pid or error
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 64                ; release the frame
        ret                             ; done

; sys_wait(a0 = pid or 0 for any child, a1 = 1 not to block) -> a0 = exit
; status (or < 0: -1 no such child, -2 interrupted, -3 still running), a1 = pid
sys_wait:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        mv    a2, a0                    ; handle = pid
        mv    a4, a1                    ; mode
        li    a0, 1                     ; proc
        li    a1, OP_WAIT               ; the request
        li    a3, 0                     ; ...
        call  sys_msg                   ; a0 = status
        sd    a0, 8(sp)                 ; keep it
        li    a0, 0                     ; data[0] = the pid
        call  sys_word                  ; ...
        mv    a1, a0                    ; ...
        ld    a0, 8(sp)                 ; status
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

; sys_simple(a0 = endpoint register, a1 = op, a2 = handle, a3 = length, a4 = mode)
; -> a0 = result: a call without data (tail of the wrappers below)
sys_simple:
        j     sys_msg                   ; nothing to add

; sys_kill(a0 = pid) -> a0 = 0 or < 0
sys_kill:
        mv    a2, a0                    ; handle = pid
        li    a0, 1                     ; proc
        li    a1, OP_KILL               ; the request
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        j     sys_msg                   ; (tail call)

; sys_signal(a0 = pid): an interrupt for that process
sys_signal:
        mv    a2, a0                    ; handle = pid
        li    a0, 1                     ; proc
        li    a1, OP_SIGNAL             ; the request
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        j     sys_msg                   ; (tail call)

; sys_catch(a0 = 1 catch interrupts / 0 default: be killed)
sys_catch:
        mv    a2, a0                    ; handle = on/off
        li    a0, 1                     ; proc
        li    a1, OP_CATCH              ; the request
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        j     sys_msg                   ; (tail call)

; sys_ps(a0 = buffer, at least 32 * 32 bytes) -> a0 = number of 32-byte records
sys_ps:
        li    a1, OP_PS                 ; the request
        j     sys_table                 ; shared path

; sys_sched(a0 = 0 read, a1 = buffer of 24 bytes) -> a0 = 0; buffer: u64 time slice
; (ticks), switches per second, KiB moved per second (since the last read).
; sys_sched(a0 = 1 set, a1 = slice in ticks, 100..100000) -> a0 = 0 or -1
sys_sched:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; buffer / slice
        sd    a0, 16(sp)                ; read / set
        mv    a2, a0                    ; handle = read / set
        mv    a3, a1                    ; length = the slice (set)
        li    a0, 1                     ; proc
        li    a1, OP_SCHED              ; the request
        li    a4, 0                     ; ...
        call  sys_msg                   ; ...
        bnez  a0, ssc_ret               ; failed
        ld    t0, 16(sp)                ; read: copy the data out
        bnez  t0, ssc_ret               ; ...
        ld    a0, 8(sp)                 ; ...
        li    a1, 24                    ; ...
        call  sys_get                   ; ...
        li    a0, 0                     ; ...
ssc_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; sys_cores(a0 = buffer, 16 * 32 bytes) -> a0 = number of 32-byte core records:
; u8 core, u8 pid running (0 none), u8 runnable, u8 processes, u8 flags (1
; unused, 2 server, 4 solo), 3 reserved, u32 switches, u32 KiB moved, 16 reserved
sys_cores:
        li    a1, OP_CORES              ; the request
        j     sys_table                 ; shared path

; sys_info(a0 = buffer of 64 bytes) -> a0 = 0; buffer: u64 cores, free heap,
; total memory, processes, kernel units loaded, context switches, KiB moved
; (PS records, 32 bytes: u8 pid, u8 state 1 running 2 ready 3 blocked 4
; zombie, u8 core, u8 parent, u8 flags 2 server, u8 cores (threads), 2
; reserved, u32 switches, u32 KiB moved, 16 bytes name)
sys_info:
        li    a1, OP_INFO               ; the request
sys_table:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; destination
        li    a0, 1                     ; proc
        li    a2, 0                     ; ...
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = count (PS) or 0 (INFO)
        bltz  a0, stb_ret               ; failed
        sd    a0, 16(sp)                ; keep the result
        slli  a1, a0, 5                 ; PS: 32 bytes per record
        bnez  a0, stb_get               ; ...
        li    a1, 64                    ; INFO: 64 bytes
stb_get:
        li    t0, SYS_MAX               ; at most one message of data
        bleu  a1, t0, stb_cp            ; ...
        mv    a1, t0                    ; ...
stb_cp:
        ld    a0, 8(sp)                 ; destination
        call  sys_get                   ; copy the data out
        ld    a0, 16(sp)                ; the result
stb_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; sys_lookup(a0 = name, a1 = length, a2 = register 2..7 to put the
; endpoint in) -> a0 = 0, or -4 if no such server
sys_lookup:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; length
        sd    a2, 16(sp)                ; register
        call  sys_put                   ; the name -> the buffer
        li    a0, 1                     ; proc
        li    a1, OP_LOOKUP             ; the request
        li    a2, 0                     ; ...
        ld    a3, 8(sp)                 ; name length
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = 0 and the endpoint in c6, or -4
        bnez  a0, slk_ret               ; none
        ld    t0, 16(sp)                ; where it goes
        la    t1, slk_tab               ; 12 bytes per entry: clear, move, return
        li    t2, 12                    ; ...
        mul   t0, t0, t2                ; ...
        add   t1, t1, t0                ; ...
        jr    t1                        ; ...
slk_tab:
        j     slk_ret                   ; c0: refused
        nop                             ; .
        nop                             ; .
        j     slk_ret                   ; c1: refused (proc stays)
        nop                             ; .
        nop                             ; .
        cclear c2                       ; c2
        cmov  c2, c6                    ; .
        j     slk_clr                   ; .
        cclear c3                       ; c3
        cmov  c3, c6                    ; .
        j     slk_clr                   ; .
        cclear c4                       ; c4
        cmov  c4, c6                    ; .
        j     slk_clr                   ; .
        j     slk_ret                   ; c5: refused
        nop                             ; .
        nop                             ; .
        j     slk_ret                   ; c6: it is already there
        nop                             ; .
        nop                             ; .
        cclear c7                       ; c7
        cmov  c7, c6                    ; .
        j     slk_clr                   ; .
slk_clr:
        cclear c6                       ; (the endpoint is copyable: do not leave the copy where
        li    a0, 0                     ;   replies' attachments arrive)
slk_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; sys_register(a0 = name, a1 = length) -> a0 = 0 or < 0
sys_register:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; length
        call  sys_put                   ; the name -> the buffer
        li    a0, 1                     ; proc
        li    a1, OP_REGISTER           ; the request
        li    a2, 0                     ; ...
        ld    a3, 8(sp)                 ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = result
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

; =============================================================================
; dev, fs and tty extras
; =============================================================================

; sys_dev(a0 = op, a1 = destination buffer or -1, a2 = handle) -> a0 = result:
; looks up "dev" into c6 and sends it a request without data
sys_dev:
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; op
        sd    a1, 16(sp)                ; destination
        sd    a2, 24(sp)                ; handle
        la    a0, sys_ndev              ; "dev"
        li    a1, 3                     ; ...
        li    a2, 6                     ; into c6
        call  sys_lookup                ; ...
        bnez  a0, sdv_ret               ; no dev server
        li    a0, 6                     ; through c6
        ld    a1, 8(sp)                 ; op
        ld    a2, 24(sp)                ; handle
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = result
        cclear c6                       ; drop the endpoint copy
        blez  a0, sdv_ret               ; nothing to copy out
        ld    t0, 16(sp)                ; a destination? (-1: none; 0 is a valid address)
        bltz  t0, sdv_ret               ; no
        sd    a0, 8(sp)                 ; keep the count
        slli  a1, a0, 5                 ; 32 bytes per record
        mv    a0, t0                    ; ...
        call  sys_get                   ; copy them out
        ld    a0, 8(sp)                 ; the count
sdv_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 32                ; release the frame
        ret                             ; done

; sys_devs(a0 = buffer, 32 * 16 bytes) -> a0 = platform-table entries copied
sys_devs:
        mv    a1, a0                    ; destination
        li    a0, OP_DEVS               ; the request
        li    a2, 0                     ; ...
        j     sys_dev                   ; (tail call)

; sys_grantfb() -> a0 = 0 with c6 = the framebuffer memory and c7 = the
; controller's ports 0x4000..0x400F (the clock in c7 is replaced: use
; sys_clock to get it back); -5 the caller is not registered as "ws", -7 a
; live process holds it, -1 none. The memory dies when the caller ends.
sys_grantfb:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save ra
        la    a0, sys_ndev              ; "dev"
        li    a1, 3                     ; ...
        li    a2, 6                     ; into c6
        call  sys_lookup                ; ...
        bnez  a0, sgf_ret               ; no dev server
        li    a0, 6                     ; through c6
        li    a1, OP_GRANTFB            ; ...
        li    a2, 0                     ; ...
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; 0: the memory replaced the endpoint in c6
        beqz  a0, sgf_ret               ; ...
        cclear c6                       ; refused: drop the endpoint copy
sgf_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 8                 ; release the frame
        ret                             ; done

; sys_halt(): stop the machine (through dev)
sys_halt:
        call  out_flush                 ; say everything first
        li    a0, OP_HALT               ; the request
        li    a1, -1                    ; (no data)
        li    a2, 0                     ; ...
        call  sys_dev                   ; does not return when it works
        li    a0, 1                     ; it did not: end at least this process
        j     sys_exit                  ; ...

; sys_fsdata(a0 = op, a1 = destination, a2 = record size, a3 = handle) -> a0 =
; count; copies count * size bytes of reply data out (fs DIR, STATFS, READBLK)
sys_fsdata:
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; destination
        sd    a2, 16(sp)                ; record size
        mv    a1, a0                    ; op
        mv    a2, a3                    ; handle
        li    a0, 2                     ; fs
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = count
        blez  a0, sfd_ret               ; nothing
        sd    a0, 24(sp)                ; keep it
        ld    t0, 16(sp)                ; bytes = count * size
        mul   a1, a0, t0                ; ...
        li    t0, SYS_MAX               ; at most one message
        bleu  a1, t0, sfd_cp            ; ...
        mv    a1, t0                    ; ...
sfd_cp:
        ld    a0, 8(sp)                 ; destination
        call  sys_get                   ; copy
        ld    a0, 24(sp)                ; the count
sfd_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 32                ; release the frame
        ret                             ; done

; sys_dir(a0 = buffer, 128 * 32 bytes) -> a0 = files; records: 24 bytes name, u64 size
sys_dir:
        mv    a1, a0                    ; destination
        li    a0, OP_DIR                ; the request
        li    a2, 32                    ; record size
        li    a3, 0                     ; ...
        j     sys_fsdata                ; (tail call)

; sys_query(a0 = buffer, 128 * 32 bytes, a1 = tag path, a2 = its length) ->
; a0 = files carrying every tag of the path (records as sys_dir), or -4
sys_query:
        mv    a3, a2                    ; length
        mv    a2, a1                    ; the path
        mv    a1, a0                    ; destination
        li    a0, OP_DIR                ; the request
        j     sys_fsq                   ; (tail call)

; sys_tags(a0 = buffer, 64 * 32 bytes, a1 = a file's path, a2 = its length (0:
; every tag)) -> a0 = tags; records: 16 bytes name, u64 files, u64 tag number
sys_tags:
        mv    a3, a2                    ; length
        mv    a2, a1                    ; the path
        mv    a1, a0                    ; destination
        li    a0, OP_TAGS               ; the request
; sys_fsq(a0 = op, a1 = destination, a2 = path, a3 = length) -> a0 = count;
; copies count 32-byte records of reply data out
sys_fsq:
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; op
        sd    a1, 16(sp)                ; destination
        sd    a3, 24(sp)                ; length
        mv    a0, a2                    ; the path -> the buffer
        mv    a1, a3                    ; ...
        call  sys_put                   ; ...
        li    a0, 2                     ; fs
        ld    a1, 8(sp)                 ; op
        li    a2, 0                     ; ...
        ld    a3, 24(sp)                ; length
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = count
        blez  a0, sfq_ret               ; nothing
        sd    a0, 8(sp)                 ; keep it
        slli  a1, a0, 5                 ; bytes
        li    t0, SYS_MAX               ; at most one message
        bleu  a1, t0, sfq_cp            ; ...
        mv    a1, t0                    ; ...
sfq_cp:
        ld    a0, 16(sp)                ; destination
        call  sys_get                   ; copy
        ld    a0, 8(sp)                 ; the count
sfq_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 32                ; release the frame
        ret                             ; done

; sys_tag(a0 = name, a1 = length, a2 = tag, a3 = its length) -> a0 = 0, -4 no
; such file, -6 no room for another tag, -1 bad tag name
; sys_untag: the same, taking the tag away (0 also if the file did not carry it)
sys_tag:
        li    a4, OP_TAG                ; the request
        j     sys_tagop                 ; shared path
sys_untag:
        li    a4, OP_UNTAG              ; the request
sys_tagop:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a4, 8(sp)                 ; op
        la    t0, sys_buf               ; data: the name, a zero byte, the tag
        li    t1, 0                     ; index
stg_a:
        beq   t1, a1, stg_z             ; the name is copied
        add   t2, a0, t1                ; ...
        lbu   t2, 0(t2)                 ; ...
        add   t3, t0, t1                ; ...
        sb    t2, 0(t3)                 ; ...
        addi  t1, t1, 1                 ; ...
        j     stg_a                     ; ...
stg_z:
        add   t3, t0, t1                ; the zero byte
        sb    zero, 0(t3)               ; ...
        addi  t1, t1, 1                 ; ...
        add   t4, t0, t1                ; t4 = where the tag goes
        li    t2, 0                     ; ...
stg_b:
        beq   t2, a3, stg_d             ; the tag is copied
        add   t3, a2, t2                ; ...
        lbu   t3, 0(t3)                 ; ...
        add   t5, t4, t2                ; ...
        sb    t3, 0(t5)                 ; ...
        addi  t2, t2, 1                 ; ...
        j     stg_b                     ; ...
stg_d:
        add   t1, t1, a3                ; t1 = the length
        sd    t1, 16(sp)                ; ...
        add   t3, t0, t1                ; and a terminating zero
        sb    zero, 0(t3)               ; ...
        addi  t2, t1, 8                 ; whole words, with it
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        li    t3, 64                    ; after the header
        tput  tg10, t0, c5, t3, t2      ; D-LS -> the buffer
        li    a0, 2                     ; fs
        ld    a1, 8(sp)                 ; op
        li    a2, 0                     ; ...
        ld    a3, 16(sp)                ; length
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = result
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; sys_statfs(a0 = buffer of 24 bytes) -> a0 = 3; u64 total blocks, used blocks, files
sys_statfs:
        mv    a1, a0                    ; destination
        li    a0, OP_STATFS             ; the request
        li    a2, 8                     ; three words
        li    a3, 0                     ; ...
        j     sys_fsdata                ; (tail call)

; sys_readblk(a0 = block number, a1 = buffer of 512 bytes) -> a0 = 512 or < 0
sys_readblk:
        mv    a3, a0                    ; handle = block number
        li    a0, OP_READBLK            ; the request
        li    a2, 1                     ; (count = bytes)
        j     sys_fsdata                ; (tail call)

; sys_unlink(a0 = name, a1 = length) -> a0 = 0 or -4
sys_unlink:
        li    a2, OP_UNLINK             ; the request
        j     sys_named                 ; shared path
; sys_stat(a0 = name, a1 = length) -> a0 = size or -4
sys_stat:
        li    a2, OP_STAT               ; the request
sys_named:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; length
        sd    a2, 16(sp)                ; op
        call  sys_put                   ; the name -> the buffer
        li    a0, 2                     ; fs
        ld    a1, 16(sp)                ; op
        li    a2, 0                     ; ...
        ld    a3, 8(sp)                 ; name length
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = result
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; sys_conmode(a0 = 0 cooked / 1 raw)
sys_conmode:
        mv    a2, a0                    ; handle = mode
        li    a0, 3                     ; tty
        li    a1, OP_CONMODE            ; the request
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        j     sys_msg                   ; (tail call)

; sys_setfg(a0 = pid): Ctrl-C now interrupts that process
sys_setfg:
        mv    a2, a0                    ; handle = pid
        li    a0, 3                     ; tty
        li    a1, OP_SETFG              ; the request
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        j     sys_msg                   ; (tail call)

; =============================================================================
; Time
; =============================================================================

; sys_now() -> a0 = timer ticks since power-on (1 tick = 1 us)
sys_now:
        la    t0, sys_num               ; 8 bytes of D-LS
        li    t1, 8                     ; NOW is an 8-byte register at port 0 of c7
        tget  tg10, t0, c7, zero, t1    ; read it (latched at byte 0)
        ld    a0, 0(t0)                 ; (waits for the read)
        ret                             ; done

; sys_sleep(a0 = ticks) -> a0 = -8 when the time is up, -2 if interrupted
sys_sleep:
        mv    a2, a0                    ; timeout
        li    a0, SVC_WAIT              ; WAIT_REPLY with nothing sent: a sleep
        li    a1, -1                    ; no doorbell
        li    a3, -1                    ; awaiting nothing
        svc                             ; ...
        ret                             ; done

; sys_notify_wait(a0 = timeout ticks, -1 none) -> a0 = notification bits
; (bit 0 = interrupt) or -8
sys_notify_wait:
        mv    a2, a0                    ; timeout
        li    a0, SVC_NOTIFY            ; NOTIFY_WAIT
        svc                             ; ...
        ret                             ; done

; sys_yield(): let another process of this core run
sys_yield:
        li    a0, SVC_YIELD             ; YIELD
        svc                             ; ...
        ret                             ; done

; sys_mirror(a0 = arena offset (c0 offset) of a far copy of the I-LS program
; range 0x8000.., a1 = its length): programs that generate code keep it
; there; the kernel reloads the I-LS from it on every switch-in
sys_mirror:
        mv    a2, a1                    ; length
        mv    a1, a0                    ; offset
        li    a0, SVC_MIRROR            ; ...
        svc                             ; ...
        ret                             ; done

; sys_scratch(a0 = D-LS start, a1 = length, 0 = none): that range of the
; program's data is scratch: a context switch neither saves nor restores it
; (its contents are undefined after the program was switched out); one range
sys_scratch:
        mv    a2, a1                    ; length
        mv    a1, a0                    ; start
        li    a0, SVC_SCRATCH           ; ...
        svc                             ; ...
        ret                             ; done

; sys_clock(): c7 = the clock again (after a reply put something else there)
sys_clock:
        li    a0, SVC_CLOCK             ; ...
        svc                             ; ...
        ret                             ; done

; sys_intr() -> a0 = 1 if an interrupt was seen since the last call (and clears it)
sys_intr:
        la    t0, sys_intrf             ; the flag
        ld    a0, 0(t0)                 ; ...
        sd    zero, 0(t0)               ; cleared
        ret                             ; done

; =============================================================================
; ws: the window server (endpoint in c4 after sys_lookup "ws", 4 by default)
; =============================================================================

; ws_call(a0 = op, a1 = handle, a2 = data address, a3 = data length) -> a0 = result
ws_call:
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; op
        sd    a1, 16(sp)                ; handle
        sd    a3, 24(sp)                ; length
        mv    a0, a2                    ; the data -> the buffer
        mv    a1, a3                    ; ...
        call  sys_put                   ; ...
        la    t0, ws_reg                ; through the ws endpoint register
        ld    a0, 0(t0)                 ; ...
        ld    a1, 8(sp)                 ; op
        ld    a2, 16(sp)                ; handle
        ld    a3, 24(sp)                ; length
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = result (CREATE: the surface is in c6)
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 32                ; release the frame
        ret                             ; done

        .data                           ; ws register and constant names
        .align 8                        ; ...
ws_reg:    .dword 4                     ; endpoint register of ws
sys_ndev:  .ascii "dev"                 ; the device manager's name
        .text                           ; back to code

; =============================================================================
; Arguments
; =============================================================================

; sys_cmdline() -> a0 = address of the command line ("prog args"), a1 = length
sys_cmdline:
        la    t0, sys_start             ; the start-up block
        ld    a1, 40(t0)                ; length
        addi  a0, t0, 64                ; text
        ret                             ; done

; sys_args(a0 = buffer) -> a0 = length of the arguments (the command line
; after the program name and its spaces), copied to the buffer
sys_args:
        la    t0, sys_start             ; the start-up block
        ld    t1, 40(t0)                ; command line length
        addi  t2, t0, 64                ; t2 = cursor
        add   t1, t2, t1                ; t1 = end
sar_name:
        bgeu  t2, t1, sar_sp            ; end of the text
        lbu   t3, 0(t2)                 ; skip the name
        li    t4, ' '                   ; ...
        beq   t3, t4, sar_sp            ; ...
        addi  t2, t2, 1                 ; ...
        j     sar_name                  ; ...
sar_sp:
        bgeu  t2, t1, sar_copy          ; end of the text
        lbu   t3, 0(t2)                 ; skip spaces
        li    t4, ' '                   ; ...
        bne   t3, t4, sar_copy          ; ...
        addi  t2, t2, 1                 ; ...
        j     sar_sp                    ; ...
sar_copy:
        li    t5, 0                     ; copy the rest
sar_c:
        add   t3, t2, t5                ; source
        bgeu  t3, t1, sar_done          ; end
        lbu   t3, 0(t3)                 ; ...
        add   t4, a0, t5                ; destination
        sb    t3, 0(t4)                 ; ...
        addi  t5, t5, 1                 ; next
        j     sar_c                     ; continue
sar_done:
        mv    a0, t5                    ; the length
        ret                             ; done

; arg_next(a0 = cursor, a1 = end) -> a0 = word start, a1 = word length (0 if
; none left), a2 = cursor after the word
arg_next:
        li    t1, ' '                   ; separator
an_skip:
        bgeu  a0, a1, an_none           ; nothing left
        lbu   t0, 0(a0)                 ; ...
        bne   t0, t1, an_word           ; a word starts
        addi  a0, a0, 1                 ; skip a space
        j     an_skip                   ; ...
an_word:
        mv    a2, a0                    ; cursor
an_w:
        bgeu  a2, a1, an_end            ; end of text
        lbu   t0, 0(a2)                 ; ...
        beq   t0, t1, an_end            ; a space ends it
        addi  a2, a2, 1                 ; ...
        j     an_w                      ; ...
an_end:
        sub   a1, a2, a0                ; length
        ret                             ; done
an_none:
        mv    a2, a0                    ; cursor
        li    a1, 0                     ; no word
        ret                             ; done

; =============================================================================
; Buffered standard output (handle 1) and standard error (handle 2)
; =============================================================================

; out_str(a0 = address, a1 = length)
out_str:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; source
        sd    a1, 16(sp)                ; length
os_loop:
        ld    t2, 16(sp)                ; bytes left
        beqz  t2, os_done               ; none
        la    t0, out_len               ; room in the buffer?
        ld    t1, 0(t0)                 ; ...
        li    t3, SYS_MAX               ; ...
        bltu  t1, t3, os_put            ; yes
        call  out_flush                 ; no: send what is there
        j     os_loop                   ; and retry
os_put:
        ld    t4, 8(sp)                 ; the next byte
        lbu   t5, 0(t4)                 ; ...
        la    t6, out_buf               ; append it
        add   t6, t6, t1                ; ...
        sb    t5, 0(t6)                 ; ...
        addi  t1, t1, 1                 ; ...
        sd    t1, 0(t0)                 ; ...
        addi  t4, t4, 1                 ; next byte
        sd    t4, 8(sp)                 ; ...
        addi  t2, t2, -1                ; one fewer
        sd    t2, 16(sp)                ; ...
        j     os_loop                   ; continue
os_done:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; out_chr(a0 = character)
out_chr:
        la    t0, sys_num               ; one byte of scratch
        sb    a0, 0(t0)                 ; ...
        mv    a0, t0                    ; ...
        li    a1, 1                     ; ...
        j     out_str                   ; (tail call)

; out_flush(): send buffered output to stdout
out_flush:
        la    t0, out_len               ; anything?
        ld    a2, 0(t0)                 ; ...
        beqz  a2, of_done               ; no
        sd    zero, 0(t0)               ; the buffer will be empty
        li    a0, 1                     ; stdout
        la    a1, out_buf               ; the bytes
        j     sys_write                 ; (tail call)
of_done:
        ret                             ; done

; out_nl(): a newline
out_nl:
        la    a0, sys_nl                ; "\n"
        li    a1, 1                     ; ...
        j     out_str                   ; (tail call)

; out_dec(a0 = value): unsigned decimal
out_dec:
        la    t0, sys_num_end           ; build the digits right to left
        li    t1, 10                    ; ...
od_loop:
        remu  t2, a0, t1                ; lowest digit
        divu  a0, a0, t1                ; drop it
        addi  t2, t2, '0'               ; ASCII
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; ...
        bnez  a0, od_loop               ; more digits
        mv    a0, t0                    ; the text
        la    t1, sys_num_end           ; its length
        sub   a1, t1, t0                ; ...
        j     out_str                   ; (tail call)

; out_sdec(a0 = value): signed decimal
out_sdec:
        bgez  a0, out_dec               ; not negative: as unsigned
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        sub   a0, zero, a0              ; the magnitude
        sd    a0, 8(sp)                 ; ...
        li    a0, '-'                   ; the sign
        call  out_chr                   ; ...
        ld    a0, 8(sp)                 ; the magnitude
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        j     out_dec                   ; (tail call)

; out_decw(a0 = value, a1 = width): unsigned decimal, right-aligned in a1 columns
out_decw:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; value
        sd    a1, 16(sp)                ; width
        li    t1, 1                     ; count its digits
        li    t2, 10                    ; ...
odw_cnt:
        divu  a0, a0, t2                ; drop a digit
        beqz  a0, odw_pad               ; none left
        addi  t1, t1, 1                 ; one more
        j     odw_cnt                   ; ...
odw_pad:
        ld    t0, 16(sp)                ; spaces = width - digits
        sub   a0, t0, t1                ; ...
        call  out_pad                   ; ...
        ld    a0, 8(sp)                 ; the value
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        j     out_dec                   ; (tail call)

; out_pad(a0 = count): that many spaces (nothing if <= 0)
out_pad:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; spaces left
op_loop:
        ld    t0, 8(sp)                 ; ...
        blez  t0, op_done               ; none
        addi  t0, t0, -1                ; one fewer
        sd    t0, 8(sp)                 ; ...
        li    a0, ' '                   ; a space
        call  out_chr                   ; ...
        j     op_loop                   ; continue
op_done:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

; out_hex(a0 = value, a1 = digits): the low a1 hex digits
out_hex:
        la    t0, sys_num_end           ; build right to left
        la    t3, sys_hexd              ; digit table
        mv    t1, a1                    ; digits to produce
ohx_loop:
        andi  t2, a0, 15                ; low nibble
        add   t2, t3, t2                ; its character
        lbu   t2, 0(t2)                 ; ...
        addi  t0, t0, -1                ; cursor left
        sb    t2, 0(t0)                 ; ...
        srli  a0, a0, 4                 ; next nibble
        addi  t1, t1, -1                ; one fewer
        bnez  t1, ohx_loop              ; ...
        mv    a0, t0                    ; the text
        la    t1, sys_num_end           ; ...
        sub   a1, t1, t0                ; ...
        j     out_str                   ; (tail call)

; err_str(a0 = address, a1 = length): to standard error at once (after
; flushing stdout, so the two stay in order on the console)
err_str:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; text
        sd    a1, 16(sp)                ; length
        call  out_flush                 ; stdout first
        li    a0, 2                     ; stderr
        ld    a1, 8(sp)                 ; ...
        ld    a2, 16(sp)                ; ...
        call  sys_write                 ; ...
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; =============================================================================
; Line-buffered standard input (handle 0)
; =============================================================================

; in_line(a0 = buffer, a1 = maximum) -> a0 = length of the next line (without
; its newline), or -1 at end of input (-2 if interrupted with nothing read)
in_line:
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; destination
        sd    a1, 16(sp)                ; maximum
        sd    zero, 24(sp)              ; bytes so far
il_loop:
        la    t0, in_pos                ; anything buffered?
        ld    t1, 0(t0)                 ; ...
        la    t2, in_len                ; ...
        ld    t3, 0(t2)                 ; ...
        bltu  t1, t3, il_byte           ; yes
        la    t4, in_eof                ; no: has input ended?
        ld    t5, 0(t4)                 ; ...
        bnez  t5, il_end                ; yes
        li    a0, 0                     ; read more from stdin
        la    a1, in_buf                ; ...
        li    a2, SYS_MAX               ; ...
        call  sys_read                  ; a0 = bytes
        la    t0, in_pos                ; restart the buffer
        sd    zero, 0(t0)               ; ...
        la    t2, in_len                ; ...
        sd    zero, 0(t2)               ; ...
        li    t1, E_INTR                ; interrupted?
        beq   a0, t1, il_intr           ; yes
        blez  a0, il_eof                ; nothing: end of input
        sd    a0, 0(t2)                 ; got some
        j     il_loop                   ; ...
il_eof:
        la    t4, in_eof                ; end of input
        li    t5, 1                     ; ...
        sd    t5, 0(t4)                 ; ...
        j     il_end                    ; ...
il_intr:
        ld    a0, 24(sp)                ; something read already?
        bnez  a0, il_out                ; return it
        li    a0, E_INTR                ; no: report the interrupt
        j     il_out                    ; ...
il_byte:
        la    t4, in_buf                ; the next byte
        add   t4, t4, t1                ; ...
        lbu   t5, 0(t4)                 ; ...
        addi  t1, t1, 1                 ; consumed
        sd    t1, 0(t0)                 ; ...
        li    t6, 10                    ; newline ends the line
        beq   t5, t6, il_line           ; ...
        ld    t6, 24(sp)                ; room left?
        ld    t3, 16(sp)                ; ...
        bgeu  t6, t3, il_loop           ; no: drop the byte
        ld    t3, 8(sp)                 ; store it
        add   t3, t3, t6                ; ...
        sb    t5, 0(t3)                 ; ...
        addi  t6, t6, 1                 ; one more
        sd    t6, 24(sp)                ; ...
        j     il_loop                   ; continue
il_end:
        ld    a0, 24(sp)                ; a last line without a newline?
        bnez  a0, il_out                ; yes: return it
        li    a0, -1                    ; end of input
        j     il_out                    ; ...
il_line:
        ld    a0, 24(sp)                ; the line's length
il_out:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 32                ; release the frame
        ret                             ; done

; =============================================================================
; Small string helpers
; =============================================================================

; str_atoi(a0 = text, a1 = length) -> a0 = its leading decimal number (0 if none)
str_atoi:
        add   t1, a0, a1                ; end
        li    t0, 0                     ; value
        li    t3, 10                    ; base
sa2_loop:
        bgeu  a0, t1, sa2_done          ; end of text
        lbu   t2, 0(a0)                 ; next character
        addi  t2, t2, -48               ; '0' -> 0
        bgeu  t2, t3, sa2_done          ; not a digit: stop
        mul   t0, t0, t3                ; shift
        add   t0, t0, t2                ; add the digit
        addi  a0, a0, 1                 ; next
        j     sa2_loop                  ; continue
sa2_done:
        mv    a0, t0                    ; the value
        ret                             ; done

; str_num(a0 = text, a1 = length) -> a0 = the decimal number, or -1 unless the
; whole text is digits
str_num:
        beqz  a1, sn_bad                ; empty
        add   t1, a0, a1                ; end
        li    t0, 0                     ; value
        li    t3, 10                    ; base
sn_loop:
        bgeu  a0, t1, sn_done           ; all digits
        lbu   t2, 0(a0)                 ; next character
        addi  t2, t2, -48               ; '0' -> 0
        bgeu  t2, t3, sn_bad            ; not a digit
        mul   t0, t0, t3                ; shift
        add   t0, t0, t2                ; add the digit
        addi  a0, a0, 1                 ; next
        j     sn_loop                   ; continue
sn_done:
        mv    a0, t0                    ; the value
        ret                             ; done
sn_bad:
        li    a0, -1                    ; not a number
        ret                             ; done

; str_eq(a0 = text, a1 = length, a2 = other, a3 = its length) -> a0 = 1 if equal
str_eq:
        bne   a1, a3, se_no             ; lengths differ
        li    t0, 0                     ; index
se_loop:
        beq   t0, a1, se_yes            ; all equal
        add   t1, a0, t0                ; ...
        lbu   t1, 0(t1)                 ; ...
        add   t2, a2, t0                ; ...
        lbu   t2, 0(t2)                 ; ...
        bne   t1, t2, se_no             ; differ
        addi  t0, t0, 1                 ; next
        j     se_loop                   ; ...
se_yes:
        li    a0, 1                     ; equal
        ret                             ; done
se_no:
        li    a0, 0                     ; different
        ret                             ; done

; str_has(a0 = text, a1 = length, a2 = pattern, a3 = its length) -> a0 = 1 if
; the pattern occurs in the text
str_has:
        beqz  a3, sh2_yes               ; the empty pattern is everywhere
        bltu  a1, a3, sh2_no            ; pattern longer than the text
        sub   t4, a1, a3                ; last starting position
        li    t0, 0                     ; t0 = starting position
sh2_at:
        bgtu  t0, t4, sh2_no            ; tried them all
        li    t1, 0                     ; t1 = index into the pattern
sh2_cmp:
        beq   t1, a3, sh2_yes           ; the whole pattern matched
        add   t2, a0, t0                ; text byte
        add   t2, t2, t1                ; ...
        lbu   t2, 0(t2)                 ; ...
        add   t3, a2, t1                ; pattern byte
        lbu   t3, 0(t3)                 ; ...
        bne   t2, t3, sh2_next          ; mismatch
        addi  t1, t1, 1                 ; next byte
        j     sh2_cmp                   ; continue
sh2_next:
        addi  t0, t0, 1                 ; next starting position
        j     sh2_at                    ; continue
sh2_yes:
        li    a0, 1                     ; found
        ret                             ; done
sh2_no:
        li    a0, 0                     ; not found
        ret                             ; done

; str_len(a0 = zero-terminated text, a1 = maximum) -> a0 = length
str_len:
        li    t0, 0                     ; length so far
sl_loop:
        beq   t0, a1, sl_done           ; maximum
        add   t1, a0, t0                ; ...
        lbu   t1, 0(t1)                 ; ...
        beqz  t1, sl_done               ; zero ends it
        addi  t0, t0, 1                 ; ...
        j     sl_loop                   ; ...
sl_done:
        mv    a0, t0                    ; length
        ret                             ; done

; =============================================================================
; net: TCP/IP through the network server (os/servers/net.s)
; =============================================================================
; The network server runs only after `net ADDRESS` was started (rc, or a
; shell). Its endpoint lives in c6 (net_init: LOOKUP "net"); c6 is otherwise
; where replies' capabilities arrive, which none of these calls bring, so a
; program that uses the network must not make calls that return a capability
; (sys_lookup into c6, sys_grantfb) afterwards, or call net_init again.
; Sockets are handles (server register 6): sys_read, sys_write and sys_close
; work on TCP connections as on files and pipes; READ blocks until data
; arrives and returns 0 when the peer has closed. Addresses are IPv4 in a
; register as a.b.c.d = a << 24 | b << 16 | c << 8 | d; ports are numbers.
;   net_init() -> 0, or -4 (no network server; one is started if none runs)
;   net_connect(ip, port) -> handle (TCP; -1 refused, -8 timed out)
;   net_listen(port) -> handle;  net_accept(listen handle, nb) -> handle (-3: none yet, nb = 1)
;   net_shutdown(handle): no more sending (FIN); reading goes on until the peer closes
;   net_udp(port, 0 = any) -> handle;  net_sendto(h, ip, port, buf, len) -> n
;   net_recvfrom(h, buf, max, nb) -> n, a1 = ip, a2 = port (-3: none, nb = 1)
;   net_ping(ip, bytes, timeout) -> round trip in ticks, or -8
;   net_stat(buf: 64 + 32 x 8 bytes) -> sockets; net_setip(ip)
;   net_aton(text, len) -> ip or -1;  out_ip(ip) prints a.b.c.d
; The server's protocol (ops 50..58 and READ/WRITE/CLOSE) is in the header
; of os/servers/net.s.

OP_NSTAT   = 50                         ; net: interface, counters and sockets
OP_NSETIP  = 51                         ; net: the interface's address
OP_NPING   = 52                         ; net: ICMP echo
OP_NCONN   = 53                         ; net: TCP connect
OP_NLISTEN = 54                         ; net: TCP listen
OP_NACCEPT = 55                         ; net: TCP accept
OP_NUBIND  = 56                         ; net: a UDP socket
OP_NUSEND  = 57                         ; net: send a datagram
OP_NURECV  = 58                         ; net: receive a datagram
OP_GETNET  = 59                         ; dev: the network interface's ports (for net)
NET_EP     = 6                          ; the register of the endpoint to net

        .data                           ; net names
        .align 8                        ; ...
net_name:  .ascii "net"                 ; the network server's name
net_cmd:   .ascii "net"                 ; how net_init starts one (its address: from the link)
net_cmd_e:                              ; ...
        .align 8                        ; ...
        .text                           ; back to code

; net_init() -> a0 = 0 (the endpoint in c6), -4 if no network server. One
; just started in the background may not be registered yet: it looks for
; half a second; then, if none runs, it starts one (`net`: its address comes from the link; its
; output on the console) and waits up to a second more for it.
net_init:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        li    t0, 30                    ; tries, 50 ms apart
        sd    t0, 8(sp)                 ; ...
        sd    zero, 16(sp)              ; not started one yet
ni_try:
        la    a0, net_name              ; LOOKUP "net" into c6
        li    a1, 3                     ; ...
        li    a2, NET_EP                ; ...
        call  sys_lookup                ; a0 = 0 or -4
        beqz  a0, ni_ok                 ; found
        ld    t0, 8(sp)                 ; (only after half a second)
        li    t1, 20                    ; ...
        bgt   t0, t1, ni_wait           ; ...
        ld    t0, 16(sp)                ; none: start one, once
        bnez  t0, ni_wait               ; ...
        li    t0, 1                     ; ...
        sd    t0, 16(sp)                ; ...
        call  net_start                 ; ...
ni_wait:
        ld    t0, 8(sp)                 ; tries left?
        addi  t0, t0, -1                ; ...
        sd    t0, 8(sp)                 ; ...
        blez  t0, ni_ret                ; no: -4
        li    a0, 50000                 ; wait 50 ms
        call  sys_sleep                 ; ...
        j     ni_try                    ; again
ni_ok:
        la    t0, net_up                ; (net_resolve knows it is done)
        li    t1, 1                     ; ...
        sd    t1, 0(t0)                 ; ...
ni_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; net_start(): spawn the network server with the default address, its standard
; output and error on the console (not ours: that may be a pipe it would keep open)
net_start:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        li    a0, 3                     ; a handle on the console (tty id 0)
        li    a1, 0                     ; ...
        call  sys_hnew                  ; ...
        sd    a0, 8(sp)                 ; ...
        bltz  a0, nsr_ret               ; (no handle free)
        li    a0, 0                     ; one thread, no pinning
        li    a1, 0                     ; ...
        la    a2, net_cmd               ; "net 10.0.0.1"
        li    a3, net_cmd_e - net_cmd   ; ...
        li    a4, -1                    ; no input
        ld    a5, 8(sp)                 ; output, errors: the console
        mv    a6, a5                    ; ...
        call  sys_spawn                 ; (not waited for)
        ld    a0, 8(sp)                 ; the handle is not needed any more
        li    a1, -1                    ; (dropped from the table only: the console stays open)
        call  sys_hset                  ; ...
nsr_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

; net_id(a0 = handle) -> a0 = the server's socket id, or -1 if not a socket
net_id:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save ra
        call  sys_hent                  ; the entry
        beqz  a0, nid_no                ; not open
        ld    t0, 0(a0)                 ; its server register
        li    t1, NET_EP                ; the network server's?
        bne   t0, t1, nid_no            ; no
        ld    a0, 8(a0)                 ; the id
        j     nid_ret                   ; ...
nid_no:
        li    a0, -1                    ; not a socket
nid_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 8                 ; release the frame
        ret                             ; done

; net_sock(a0 = result of a call that makes a socket) -> a0 = a handle for it, or the error
net_sock:
        bltz  a0, nsk_ret               ; an error: as it is
        mv    a1, a0                    ; the id
        li    a0, NET_EP                ; served by net
        j     sys_hnew                  ; (tail call) a handle, or -1
nsk_ret:
        ret                             ; done

; net_connect(a0 = ip, a1 = port) -> a0 = handle, or -1 refused, -8 timed out, -6 no socket free
net_connect:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save ra
        mv    a2, a0                    ; handle = ip
        mv    a3, a1                    ; length = port
        li    a0, NET_EP                ; net
        li    a1, OP_NCONN              ; CONNECT
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = socket id or error
        call  net_sock                  ; -> handle
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 8                 ; release the frame
        ret                             ; done

; net_listen(a0 = port) -> a0 = handle, or -7 port in use, -6 no socket free
net_listen:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save ra
        mv    a2, a0                    ; handle = port
        li    a0, NET_EP                ; net
        li    a1, OP_NLISTEN            ; LISTEN
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = socket id or error
        call  net_sock                  ; -> handle
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 8                 ; release the frame
        ret                             ; done

; net_accept(a0 = listening handle, a1 = 1 do not block) -> a0 = handle of the
; next connection, or -3 (none yet) / -1
net_accept:
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; mode
        call  net_id                    ; the listener's id
        bltz  a0, nac_ret               ; not a socket
        mv    a2, a0                    ; handle = id
        li    a0, NET_EP                ; net
        li    a1, OP_NACCEPT            ; ACCEPT
        li    a3, 0                     ; ...
        ld    a4, 8(sp)                 ; mode
        call  sys_msg                   ; a0 = new socket id or error
        call  net_sock                  ; -> handle
nac_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 16                ; release the frame
        ret                             ; done

; net_shutdown(a0 = handle) -> a0 = 0: nothing more will be sent (the peer sees
; the end once the data before it has gone); reading goes on
net_shutdown:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save ra
        call  net_id                    ; the id
        bltz  a0, nsh_ret               ; not a socket
        mv    a2, a0                    ; handle = id
        li    a0, NET_EP                ; net
        li    a1, OP_CLOSE              ; CLOSE with mode bit 0: sending only
        li    a3, 0                     ; ...
        li    a4, 1                     ; ...
        call  sys_msg                   ; ...
nsh_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 8                 ; release the frame
        ret                             ; done

; net_udp(a0 = port, 0 = any) -> a0 = handle of a UDP socket, or -7 / -6
net_udp:
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save ra
        mv    a2, a0                    ; handle = port
        li    a0, NET_EP                ; net
        li    a1, OP_NUBIND             ; UDP socket
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = socket id or error
        call  net_sock                  ; -> handle
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 8                 ; release the frame
        ret                             ; done

; net_sendto(a0 = handle, a1 = ip, a2 = port, a3 = buffer, a4 = length (1472
; at most)) -> a0 = bytes sent, or -1
net_sendto:
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; ip
        sd    a2, 16(sp)                ; port
        sd    a3, 24(sp)                ; buffer
        sd    a4, 32(sp)                ; length
        call  net_id                    ; the id
        bltz  a0, nst_ret               ; not a socket
        sd    a0, 40(sp)                ; ...
        la    t0, sys_buf               ; data: u64 ip, u64 port, the payload
        ld    t1, 8(sp)                 ; ...
        sd    t1, 0(t0)                 ; ...
        ld    t1, 16(sp)                ; ...
        sd    t1, 8(t0)                 ; ...
        ld    t1, 24(sp)                ; copy the payload after them
        ld    t2, 32(sp)                ; ...
        li    t3, 1472                  ; (one datagram at most)
        bleu  t2, t3, nst_n             ; ...
        mv    t2, t3                    ; ...
        sd    t2, 32(sp)                ; ...
nst_n:
        li    t3, 0                     ; index
nst_c:
        beq   t3, t2, nst_s             ; copied
        add   t4, t1, t3                ; source byte
        lbu   t4, 0(t4)                 ; ...
        add   t5, t0, t3                ; destination
        sb    t4, 16(t5)                ; ...
        addi  t3, t3, 1                 ; next
        j     nst_c                     ; ...
nst_s:
        addi  t2, t2, 16 + 7            ; whole words of data
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        li    t1, 64                    ; -> the buffer after the header
        tput  tg10, t0, c5, t1, t2      ; (sys_msg orders it before the send)
        li    a0, NET_EP                ; net
        li    a1, OP_NUSEND             ; SENDTO
        ld    a2, 40(sp)                ; the socket
        ld    a3, 32(sp)                ; length = 16 + payload
        addi  a3, a3, 16                ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = bytes sent
nst_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 48                ; release the frame
        ret                             ; done

; net_recvfrom(a0 = handle, a1 = buffer, a2 = maximum, a3 = 1 do not block)
; -> a0 = bytes (the datagram, cut to the maximum), a1 = sender's ip, a2 =
; its port; -3 none (a3 = 1), -2 interrupted, -1
net_recvfrom:
        addi  sp, sp, -40               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; buffer
        sd    a2, 16(sp)                ; maximum
        sd    a3, 24(sp)                ; mode
        call  net_id                    ; the id
        bltz  a0, nrf_ret               ; not a socket
        mv    a2, a0                    ; handle = id
        li    a0, NET_EP                ; net
        li    a1, OP_NURECV             ; RECVFROM
        ld    a3, 16(sp)                ; maximum
        li    t0, 1472                  ; ...
        bleu  a3, t0, nrf_m             ; ...
        mv    a3, t0                    ; ...
        sd    a3, 16(sp)                ; ...
nrf_m:
        ld    a4, 24(sp)                ; mode
        call  sys_msg                   ; a0 = bytes; data: u64 ip, u64 port, payload
        bltz  a0, nrf_ret               ; nothing
        sd    a0, 32(sp)                ; ...
        la    t0, sys_buf               ; the data -> D-LS
        addi  t1, a0, 16 + 7            ; whole words
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        li    t2, 64                    ; ...
        tget  tg10, t0, c5, t2, t1      ; ...
        twait 1 << 10                   ; ...
        ld    t1, 8(sp)                 ; the payload -> the caller's buffer
        ld    t2, 32(sp)                ; ...
        li    t3, 0                     ; ...
nrf_c:
        beq   t3, t2, nrf_d             ; copied
        add   t4, t0, t3                ; ...
        lbu   t4, 16(t4)                ; ...
        add   t5, t1, t3                ; ...
        sb    t4, 0(t5)                 ; ...
        addi  t3, t3, 1                 ; ...
        j     nrf_c                     ; ...
nrf_d:
        ld    a1, 0(t0)                 ; the sender
        ld    a2, 8(t0)                 ; ...
        ld    a0, 32(sp)                ; the count
nrf_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 40                ; release the frame
        ret                             ; done

; net_ping(a0 = ip, a1 = payload bytes (0..1400), a2 = timeout in ticks, 0 =
; one second) -> a0 = the round trip in ticks, -8 no answer in time, -1
net_ping:
        mv    a4, a2                    ; mode = timeout
        mv    a3, a1                    ; length = payload bytes
        mv    a2, a0                    ; handle = ip
        li    a0, NET_EP                ; net
        li    a1, OP_NPING              ; PING
        j     sys_msg                   ; (tail call)

; net_setip(a0 = ip) -> a0 = 0: the interface's address from now on
net_setip:
        mv    a2, a0                    ; handle = ip
        li    a0, NET_EP                ; net
        li    a1, OP_NSETIP             ; SETIP
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        j     sys_msg                   ; (tail call)

; net_stat(a0 = buffer of 64 + 32 x 8 bytes) -> a0 = sockets in use; the buffer:
; u64 ip, u64 device STATUS, u64 packets in, u64 packets out, u64 packets
; dropped (bad, or not for us), u64 socket slots, 2 reserved; then 32 bytes
; per socket: u8 id, u8 state, u8 protocol (6 TCP, 17 UDP), u8 flags, u16
; local port, u16 remote port, u32 remote ip, u32 owner pid, u32 bytes
; received not yet read, u32 bytes sent not yet acknowledged, u32 peer window,
; u32 retransmissions
net_stat:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; buffer
        li    a0, NET_EP                ; net
        li    a1, OP_NSTAT              ; STAT
        li    a2, 0                     ; ...
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = sockets
        bltz  a0, nsa_ret               ; ...
        sd    a0, 16(sp)                ; ...
        slli  a1, a0, 5                 ; 64 + 32 per socket
        addi  a1, a1, 64                ; ...
        ld    a0, 8(sp)                 ; ...
        call  sys_get                   ; ...
        ld    a0, 16(sp)                ; the count
nsa_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; net_aton(a0 = text, a1 = length) -> a0 = the address "a.b.c.d", or -1
net_aton:
        add   t1, a0, a1                ; end
        li    t0, 0                     ; the address so far
        li    t2, 0                     ; parts done
nat_part:
        li    t3, 0                     ; this part's value
        li    t4, 0                     ; its digits
nat_dig:
        bgeu  a0, t1, nat_add           ; the end of the text: the last part
        lbu   t5, 0(a0)                 ; a digit?
        addi  t6, t5, -48               ; ...
        li    t5, 10                    ; ...
        bgeu  t6, t5, nat_add           ; no: the part ends
        mul   t3, t3, t5                ; ...
        add   t3, t3, t6                ; ...
        addi  t4, t4, 1                 ; ...
        addi  a0, a0, 1                 ; ...
        j     nat_dig                   ; ...
nat_add:
        beqz  t4, nat_bad               ; no digits
        li    t6, 255                   ; a byte
        bgtu  t3, t6, nat_bad           ; ...
        slli  t0, t0, 8                 ; append it
        or    t0, t0, t3                ; ...
        addi  t2, t2, 1                 ; ...
        bgeu  a0, t1, nat_end           ; the end of the text
        lbu   t5, 0(a0)                 ; else a dot
        li    t6, '.'                   ; ...
        bne   t5, t6, nat_bad           ; ...
        addi  a0, a0, 1                 ; ...
        li    t5, 4                     ; (a fifth part?)
        bge   t2, t5, nat_bad           ; ...
        j     nat_part                  ; ...
nat_end:
        li    t5, 4                     ; four parts
        bne   t2, t5, nat_bad           ; ...
        mv    a0, t0                    ; the address
        ret                             ; done
nat_bad:
        li    a0, -1                    ; not an address
        ret                             ; done

; out_ip(a0 = ip): print it as a.b.c.d
out_ip:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; the address
        li    t0, 24                    ; first byte: bits 31..24
        sd    t0, 16(sp)                ; ...
oip_l:
        ld    t0, 16(sp)                ; this byte
        ld    a0, 8(sp)                 ; ...
        srl   a0, a0, t0                ; ...
        andi  a0, a0, 255               ; ...
        call  out_dec                   ; ...
        ld    t0, 16(sp)                ; next
        beqz  t0, oip_ret               ; that was the last
        addi  t0, t0, -8                ; ...
        sd    t0, 16(sp)                ; ...
        li    a0, '.'                   ; ...
        call  out_chr                   ; ...
        j     oip_l                     ; ...
oip_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done

; ---- names (DNS through the network server) -----------------------------------------------
OP_NRESOLVE = 60                        ; net: a host name -> IPv4 addresses
OP_NSETDNS = 61                         ; net: the resolvers

        .data                           ; ...
        .align 8                        ; ...
net_up:    .dword 0                     ; net_init has found the server
net_lhost: .ascii "localhost"           ; ...
        .align 8                        ; ...
        .text                           ; back to code

; net_resolve(a0 = name, a1 = length, a2 = buffer of 168 bytes or 0) -> a0 =
; its IPv4 address, -4 no such name, -8 no resolver answered (-1 bad name).
; A dotted quad or `localhost` needs no query; anything else goes to the
; network server (net_init first, if not done). The buffer, if given: u64
; count (<= 4), four u64 addresses, the canonical name (zero-terminated).
net_resolve:
        addi  sp, sp, -40               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; name
        sd    a1, 16(sp)                ; length
        sd    a2, 24(sp)                ; buffer
        call  net_aton                  ; a dotted quad?
        bgez  a0, nrs_one               ; ...
        ld    a0, 8(sp)                 ; localhost?
        ld    a1, 16(sp)                ; ...
        la    a2, net_lhost             ; ...
        li    a3, 9                     ; ...
        call  str_eq                    ; ...
        beqz  a0, nrs_q                 ; ...
        li    a0, 0x7f000001            ; 127.0.0.1
nrs_one:
        sd    a0, 32(sp)                ; the buffer: one address, the name itself
        ld    t0, 24(sp)                ; ...
        beqz  t0, nrs_ret               ; ...
        li    t1, 1                     ; ...
        sd    t1, 0(t0)                 ; ...
        sd    a0, 8(t0)                 ; ...
        ld    t1, 16(sp)                ; (127 bytes at most)
        li    t2, 127                   ; ...
        bleu  t1, t2, nrs_c             ; ...
        mv    t1, t2                    ; ...
nrs_c:
        ld    t3, 8(sp)                 ; ...
        li    t2, 0                     ; ...
nrs_cl:
        beq   t2, t1, nrs_cz            ; ...
        add   t4, t3, t2                ; ...
        lbu   t4, 0(t4)                 ; ...
        add   t5, t0, t2                ; ...
        sb    t4, 40(t5)                ; ...
        addi  t2, t2, 1                 ; ...
        j     nrs_cl                    ; ...
nrs_cz:
        add   t5, t0, t2                ; ...
        sb    zero, 40(t5)              ; ...
        ld    a0, 32(sp)                ; ...
        j     nrs_ret                   ; ...
nrs_q:
        la    t0, net_up                ; the server
        ld    t0, 0(t0)                 ; ...
        bnez  t0, nrs_s                 ; ...
        call  net_init                  ; ...
        bnez  a0, nrs_ret               ; (-4: none)
nrs_s:
        ld    a0, 8(sp)                 ; the name -> the buffer
        ld    a1, 16(sp)                ; ...
        call  sys_put                   ; ...
        li    a0, NET_EP                ; RESOLVE
        li    a1, OP_NRESOLVE           ; ...
        li    a2, 0                     ; ...
        ld    a3, 16(sp)                ; ...
        li    a4, 0                     ; ...
        call  sys_msg                   ; a0 = address or error
        bltz  a0, nrs_ret               ; ...
        sd    a0, 32(sp)                ; ...
        ld    a0, 24(sp)                ; the data, if wanted
        beqz  a0, nrs_r                 ; ...
        li    a1, 168                   ; ...
        call  sys_get                   ; ...
nrs_r:
        ld    a0, 32(sp)                ; ...
nrs_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 40                ; release the frame
        ret                             ; done

; net_setdns(a0 = first resolver, a1 = second (0: none)) -> a0 = 0
net_setdns:
        mv    a3, a1                    ; length = the second
        mv    a2, a0                    ; handle = the first
        li    a0, NET_EP                ; ...
        li    a1, OP_NSETDNS            ; ...
        li    a4, 0                     ; ...
        j     sys_msg                   ; (tail call)
; ---- files: rename and facets (fs RENAME, DIR's facet set) ------------------
OP_RENAME  = 15                         ; fs: rename a file (it gains the new path's tags)

; sys_rename(a0 = path, a1 = length, a2 = new path, a3 = its length) -> a0 = 0,
; -4 no such file, -1 bad new name, -6 no room for another tag. The file keeps
; its tags, blocks and directory entry and gains the new path's tags; another
; file of the new name is deleted.
sys_rename:
        li    a4, OP_RENAME             ; the request
        j     sys_tagop                 ; (the same data as TAG: path, 0, path)

; sys_facets() -> a0 = the facets of the last sys_query: a tag set (bit t =
; tag number t) of every other tag that a listed file carries, the ways to
; narrow the listing further; sys_tags(buf, 0, 0) gives the numbers' names
sys_facets:
        la    t0, sys_hdr               ; the reply's mode word
        ld    a0, 24(t0)                ; ...
        ret                             ; done

; ---- files: the current tag path (fs CWD) -------------------------------------
; Every process has a current tag path, the tag-system analogue of a working
; directory, kept by the file server: a path that does not start with "/" is
; read under it ("notes" in /src/demo is /src/demo/notes; sys_query with no
; path lists it). A child starts in its parent's (proc tells fs at SPAWN).
OP_CWD     = 20                         ; fs: get / set the current tag path
CWD_MAX    = 64                         ; its longest text

; sys_cwd(a0 = buffer of CWD_MAX bytes) -> a0 = the length of the current tag
; path, its text copied in ("/" at the root; "/src/demo", "/notes/-work")
sys_cwd:
        li    a2, 0                     ; mode 0: get
        li    a3, 0                     ; no data
        j     sys_cwdop                 ; shared path

; sys_chdir(a0 = path, a1 = length, a2 = buffer of CWD_MAX bytes) -> a0 = the
; new path's length, its text copied in; -4 no such tag (or no file carries
; them all), -1 too long. The path is relative to the current one unless it
; starts with "/"; ".." takes a component away; an empty path is "/"
sys_chdir:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a1, 8(sp)                 ; length
        sd    a2, 16(sp)                ; buffer
        call  sys_put                   ; the path -> the buffer
        ld    a0, 16(sp)                ; ...
        ld    a3, 8(sp)                 ; ...
        li    a2, 1                     ; mode 1: set
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
; sys_cwdop(a0 = buffer, a2 = mode, a3 = length of the data put) -> a0 = length
sys_cwdop:
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save ra
        sd    a0, 8(sp)                 ; buffer
        mv    a4, a2                    ; mode
        li    a0, 2                     ; fs
        li    a1, OP_CWD                ; ...
        li    a2, 0                     ; ...
        call  sys_msg                   ; a0 = length or < 0
        blez  a0, scw_ret               ; ...
        li    t0, CWD_MAX               ; (at most the buffer)
        bleu  a0, t0, scw_get           ; ...
        mv    a0, t0                    ; ...
scw_get:
        sd    a0, 16(sp)                ; the length
        mv    a1, a0                    ; the text -> the buffer
        ld    a0, 8(sp)                 ; ...
        call  sys_get                   ; ...
        ld    a0, 16(sp)                ; the length
scw_ret:
        ld    ra, 0(sp)                 ; restore ra
        addi  sp, sp, 24                ; release the frame
        ret                             ; done
