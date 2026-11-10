; =============================================================================
; hw_os.s: the window server's machine layer on StrataOS
; =============================================================================
;
; The StrataOS edition of hw_bare.s: the same contract for the renderers
; (hw_fb, hw_present, hw_now), with the capabilities coming from the
; kernel's servers instead of the boot ROM, plus the window server's own
; small kernel interface. `ws` does not include os/lib/sys.s: its 40 KiB of
; D-LS go to the scene and the strips, so it keeps a 1 KiB staging buffer
; here instead of the library's three 4 KiB ones.
;
; Capability registers of `ws` once hw_init has run:
;   c0 the framebuffer window (16 MiB: the screen, then the windows' surfaces)
;   c1 proc      c2 the keyboard buffer when it is at home      c3 tty
;   c4 the framebuffer controller's ports (PRESENT at 0, VSYNC at 8)
;   c5 our message buffer        c6 the request being served
;   c7 its attachment (a client's band of pixels), else the clock
; RECEIVE empties c6 and c7, so nothing else may live there; hw_clock()
; fetches the clock again when no request is in hand.
;
; The keyboard: a second 4 KiB message buffer (the last 4 KiB of our
; arena) goes to tty as a READ (raw, with the pointer's events too: tty
; keeps the pointer's waiting device read, on a core of its own). tty answers it when a key arrives; the
; answer is not our own buffer, so our core's kernel queues it as a
; *request for this core's server*, which is us: a key wakes RECEIVE
; exactly like a client's request does (os_recv tells them apart by the
; buffer's base). No polling, and c5 stays free for calls.
;
;   hw_init() -> a0 = 0, or < 0: -1 no proc/dev answer, -2 not a server
;       (REGISTER refused), -3 no XRGB8888 framebuffer, -4 GRANT_FB refused,
;       -5 the screen is larger than 4 MiB
;   hw_present()             PRESENT: "this frame is complete"
;   hw_clock(), hw_now()     the clock back into c7; NOW in microseconds
;   hw_key_arm()             send the keyboard buffer (c2) to tty as a READ
;   hw_key_take() -> a0      the answer in c6 -> hw_kb, c2; a0 = bytes or < 0,
;                            a1 = pointer events (at hw_kb + 96)
;   os_msg(a0 = endpoint register, a1 = op, a2 = handle, a3 = length, a4 =
;       mode) -> a0 = result     os_put(a0 = bytes) / os_get(a0 = bytes):
;       os_buf <-> our buffer's data   os_call(a0, a1, a2): no data
;   os_recv(a0 = timeout) -> a0 = 1 a request (header in rq_hdr), 2 the
;       keyboard's answer, 0 nothing (timed out)
;   os_reply(a0 = result, a1 = 1: c7 goes back too)   rq_put / rq_get(a0 = bytes)
;   os_park() -> a0 = id     os_unpark(a0 = id) -> a0 = 0 / -1 (c6, rq_hdr)
;   os_say(a0 = text, a1 = length)   to the console
;   os_exit(a0 = code)       os_scratch(a0 = start, a1 = length)
;
; Tags: tg10 messages, tg13 device registers.

OS_START  = 0x7F000                     ; arena offset of the start-up block
OS_BUFSZ  = 1152                        ; staging bytes (PS: 32 records of 32)
OP_READ   = 1                           ; tty: read
OP_WRITE  = 2                           ; tty: write
OP_SPAWN  = 5                           ; proc: start a program
OP_WAIT   = 6                           ; proc: collect a child
OP_KILL   = 7                           ; proc: kill a process
OP_PS     = 9                           ; proc: the processes
OP_SIGNAL = 17                          ; proc: interrupt a process
OP_SETFG  = 18                          ; tty: the foreground process
OP_CONMODE = 19                         ; tty: cooked / raw
OP_CATCH  = 22                          ; proc: catch interrupts
OP_DEVS   = 23                          ; dev: the platform table
OP_LOOKUP = 25                          ; proc: a server's endpoint
OP_GRANTFB = 26                         ; dev: the framebuffer
OP_REGISTER = 29                        ; proc: become a named server
OP_SCHED  = 30                          ; proc: slice and switch rates
OP_CORES  = 31                          ; proc: what the cores do
HW_PT_FB  = 5                           ; platform table entry type: framebuffer
HW_FBCAP  = 0                           ; the framebuffer window's register
HW_SCRMAX = 0x400000                    ; the screen's share of the window: 4 MiB

        .data                           ; D-LS
        .align 8                        ; dwords and transfer buffers
hw_fb:    .space S_SIZE                 ; the screen as a surface
os_hdr:   .space 64                     ; the header of a call we make
rq_hdr:   .space 64                     ; the header of the request being served
os_buf:   .space OS_BUFSZ               ; staging for message data
hw_kb:    .space 160                    ; the keyboard's answer: header, 32 key bytes, 8 pointer events
hw_reg:   .dword 0                      ; a device register (PRESENT / NOW)
os_pid:   .dword 0                      ; our pid
os_hd:    .space 24                     ; our handles 0..2 (descriptors, for children)
rq_tok:   .dword 0                      ; reply token of the request being served
hw_kbase: .dword 0                      ; base of the keyboard buffer
hw_khome: .dword 0                      ; 1: the keyboard buffer is in c2
os_n_ws:  .ascii "ws\0\0\0\0\0\0"       ; our name
os_n_dev: .ascii "dev\0\0\0\0\0"        ; the device manager's
        .text                           ; code

; ---------------------------------------------------------------------------
; Calls to servers
; ---------------------------------------------------------------------------

; os_msg(a0 = endpoint register 1 / 3 / 6, a1 = op, a2 = handle, a3 = length,
; a4 = mode) -> a0 = result. Data must already be in the buffer (os_put).
os_msg:                                 ; routine entry
        la    t0, os_hdr                ; build the header
        sd    a1, 0(t0)                 ; op
        sd    a2, 8(t0)                 ; handle
        sd    a3, 16(t0)                ; length
        sd    a4, 24(t0)                ; mode
        sd    zero, 32(t0)              ; result
        li    t1, 64                    ; header size
        tput  tg10, t0, c5, zero, t1    ; D-LS -> the buffer
        twait 1 << 10                   ; in before the buffer leaves
        li    t1, 3                     ; which endpoint?
        beq   a0, t1, om_tty            ; tty
        li    t1, 6                     ; one from LOOKUP
        beq   a0, t1, om_c6             ; ...
        csend c5, c1                    ; proc
        cbase a1, c1                    ; a1 = its core (for the doorbell)
        j     om_wait                   ; ...
om_tty: csend c5, c3                    ; tty
        cbase a1, c3                    ; ...
        j     om_wait                   ; ...
om_c6:  csend c5, c6                    ; the looked-up server
        cbase a1, c6                    ; ...
om_wait:
        li    a0, 1                     ; WAIT_REPLY
        li    a2, -1                    ; no timeout
        li    a3, 0                     ; awaited: our own buffer
        svc                             ; a0 = 0, or -2 if an interrupt woke us first
        beqz  a0, om_back               ; the buffer is back
        li    a1, -1                    ; no doorbell this time
        j     om_wait                   ; keep waiting: every request is answered
om_back:
        la    t0, os_hdr                ; the answered header -> D-LS
        li    t1, 64                    ; ...
        tget  tg10, t0, c5, zero, t1    ; ...
        ld    a0, 32(t0)                ; the result (waits for the read)
        ret                             ; done

; os_call(a0 = endpoint register, a1 = op, a2 = handle) -> a0: no data
os_call:                                ; routine entry
        li    a3, 0                     ; no length
        li    a4, 0                     ; no mode
        j     os_msg                    ; the call

; os_put(a0 = bytes): os_buf -> our buffer's data
os_put:                                 ; routine entry
        addi  a0, a0, 7                 ; whole words
        srli  a0, a0, 3                 ; ...
        slli  a0, a0, 3                 ; ...
        la    t0, os_buf                ; from the staging buffer
        li    t1, 64                    ; after the header
        tput  tg10, t0, c5, t1, a0      ; (os_msg's twait orders it before the send)
        ret                             ; done

; os_get(a0 = bytes): our buffer's data -> os_buf
os_get:                                 ; routine entry
        beqz  a0, og_ret                ; nothing
        addi  a0, a0, 7                 ; whole words
        srli  a0, a0, 3                 ; ...
        slli  a0, a0, 3                 ; ...
        la    t0, os_buf                ; into the staging buffer
        li    t1, 64                    ; after the header
        tget  tg10, t0, c5, t1, a0      ; ...
        twait 1 << 10                   ; (callers read os_buf at once)
og_ret: ret                             ; done

; os_say(a0 = text, a1 = length): to the console
os_say:                                 ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a1, 8(sp)                 ; the length
        la    t0, os_buf                ; copy it into the staging buffer
        mv    t1, a1                    ; ...
osy_c:  beqz  t1, osy_s                 ; copied
        lbu   t2, 0(a0)                 ; ...
        sb    t2, 0(t0)                 ; ...
        addi  a0, a0, 1                 ; ...
        addi  t0, t0, 1                 ; ...
        addi  t1, t1, -1                ; ...
        j     osy_c                     ; ...
osy_s:  ld    a0, 8(sp)                 ; -> the buffer
        call  os_put                    ; ...
        li    a0, 3                     ; tty
        li    a1, OP_WRITE              ; WRITE
        li    a2, 1                     ; (standard output)
        ld    a3, 8(sp)                 ; ...
        li    a4, 0                     ; ...
        call  os_msg                    ; ...
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; pop the frame
        ret                             ; done

; os_exit(a0 = code): end the process
os_exit:                                ; routine entry
        mv    a1, a0                    ; the code
        li    a0, 5                     ; EXIT
        svc                             ; does not return
        halt                            ; (halt also exits)

; os_scratch(a0 = D-LS start, a1 = length; 0: none): that range is not kept
; across context switches from now on
os_scratch:                             ; routine entry
        mv    a2, a1                    ; length
        mv    a1, a0                    ; start
        li    a0, 11                    ; SET_SCRATCH
        svc                             ; ...
        ret                             ; done

; ---------------------------------------------------------------------------
; Serving
; ---------------------------------------------------------------------------

; os_recv(a0 = timeout in ticks) -> a0 = 1: a request in c6 (header in
; rq_hdr, token in rq_tok, attachment in c7); 2: the keyboard buffer came
; back (in c6); 0: nothing
os_recv:                                ; routine entry
        mv    a2, a0                    ; timeout
        li    a1, 0                     ; no tags
        li    a0, 2                     ; RECEIVE
        svc                             ; a0 = token, -1 nothing, -8 timed out
        bltz  a0, orc_no                ; not a request
        la    t0, rq_tok                ; keep the token
        sd    a0, 0(t0)                 ; ...
        cbase t1, c6                    ; the keyboard buffer?
        la    t0, hw_kbase              ; ...
        ld    t0, 0(t0)                 ; ...
        li    a0, 2                     ; (yes)
        beq   t0, t1, orc_ret           ; ...
        la    t0, rq_hdr                ; a request: its header -> D-LS
        li    t1, 64                    ; ...
        tget  tg10, t0, c6, zero, t1    ; ...
        twait 1 << 10                   ; ...
        li    a0, 1                     ; ...
        ret                             ; done
orc_no: li    a0, 0                     ; nothing
orc_ret:
        ret                             ; done

; os_reply(a0 = result, a1 = 1 to send c7 back first (a client's band: it
; lands in the client's c6), 0 not to): answer the request in c6 (rq_tok)
os_reply:                               ; routine entry
        la    t0, rq_hdr                ; the result into the header
        sd    a0, 32(t0)                ; ...
        li    t1, 64                    ; header -> the buffer
        tput  tg10, t0, c6, zero, t1    ; ...
        twait (1 << 10) | (1 << 8) | (1 << 9) ; before the buffer (and the band) leave
        mv    a2, a1                    ; flags: bit 0 = send c7 first
        la    t0, rq_tok                ; the token
        ld    a1, 0(t0)                 ; ...
        li    a0, 3                     ; REPLY
        svc                             ; ...
        ret                             ; done

; rq_put(a0 = bytes): os_buf -> the request's data
rq_put:                                 ; routine entry
        addi  a0, a0, 7                 ; whole words
        srli  a0, a0, 3                 ; ...
        slli  a0, a0, 3                 ; ...
        la    t0, os_buf                ; ...
        li    t1, 64                    ; ...
        tput  tg10, t0, c6, t1, a0      ; (os_reply waits for it)
        ret                             ; done

; rq_get(a0 = bytes): the request's data -> os_buf (at most OS_BUFSZ)
rq_get:                                 ; routine entry
        li    t0, OS_BUFSZ              ; clip
        bleu  a0, t0, rg_1              ; ...
        mv    a0, t0                    ; ...
rg_1:   addi  a0, a0, 7                 ; whole words
        srli  a0, a0, 3                 ; ...
        slli  a0, a0, 3                 ; ...
        beqz  a0, rg_ret                ; nothing
        la    t0, os_buf                ; ...
        li    t1, 64                    ; ...
        tget  tg10, t0, c6, t1, a0      ; ...
        twait 1 << 10                   ; ...
rg_ret: ret                             ; done

; os_park() -> a0 = park id of the request in c6 (-1: no room)
os_park:                                ; routine entry
        li    a0, 8                     ; PARK
        svc                             ; ...
        ret                             ; done

; os_unpark(a0 = park id) -> a0 = 0 and the request in c6 (header in
; rq_hdr), or -1 if its owner died
os_unpark:                              ; routine entry
        mv    a1, a0                    ; the id
        li    a0, 9                     ; UNPARK
        svc                             ; ...
        bnez  a0, oup_ret               ; gone
        la    t0, rq_hdr                ; its header -> D-LS
        li    t1, 64                    ; ...
        tget  tg10, t0, c6, zero, t1    ; ...
        twait 1 << 10                   ; ...
        li    a0, 0                     ; ...
oup_ret:
        ret                             ; done

; ---------------------------------------------------------------------------
; The machine
; ---------------------------------------------------------------------------

hw_init:                                ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        la    t0, os_buf                ; the start-up block: pid, parent, handles
        li    t1, OS_START              ; (proc wrote it into our arena)
        li    t2, 64                    ; ...
        tget  tg10, t0, c0, t1, t2      ; ...
        ld    t1, 0(t0)                 ; our pid (waits for the read)
        la    t2, os_pid                ; ...
        sd    t1, 0(t2)                 ; ...
        la    t2, os_hd                 ; our handles' descriptors, for children
        ld    t1, 16(t0)                ; ...
        sd    t1, 0(t2)                 ; ...
        ld    t1, 24(t0)                ; ...
        sd    t1, 8(t2)                 ; ...
        ld    t1, 32(t0)                ; ...
        sd    t1, 16(t2)                ; ...
        clen  t0, c0                    ; the keyboard buffer: our arena's last 4 KiB
        li    t1, 4096                  ; ...
        sub   t0, t0, t1                ; ...
        cclear c2                       ; (the fs endpoint: not used)
        csplit c2, c0, t0               ; c2 = it
        cbase t0, c2                    ; its base tells its answers from requests
        la    t1, hw_kbase              ; ...
        sd    t0, 0(t1)                 ; ...
        la    t1, hw_khome              ; it is at home
        li    t0, 1                     ; ...
        sd    t0, 0(t1)                 ; ...
        cclear c0                       ; the rest of the arena is not needed
        la    t0, os_buf                ; REGISTER "ws"
        la    t1, os_n_ws               ; ...
        ld    t1, 0(t1)                 ; ...
        sd    t1, 0(t0)                 ; ...
        li    a0, 8                     ; ...
        call  os_put                    ; ...
        li    a0, 1                     ; proc
        li    a1, OP_REGISTER           ; ...
        li    a2, 0                     ; ...
        li    a3, 2                     ; two letters
        li    a4, 0                     ; ...
        call  os_msg                    ; ...
        li    t0, -2                    ; (refused: not a server)
        bnez  a0, hi_fail               ; ...
        la    t0, os_buf                ; LOOKUP "dev"
        la    t1, os_n_dev              ; ...
        ld    t1, 0(t1)                 ; ...
        sd    t1, 0(t0)                 ; ...
        li    a0, 8                     ; ...
        call  os_put                    ; ...
        li    a0, 1                     ; proc
        li    a1, OP_LOOKUP             ; ...
        li    a2, 0                     ; ...
        li    a3, 3                     ; three letters
        li    a4, 0                     ; ...
        call  os_msg                    ; c6 = dev's endpoint
        li    t0, -1                    ; (no device manager)
        bnez  a0, hi_fail               ; ...
        li    a0, 6                     ; DEVS: the platform table's entries
        li    a1, OP_DEVS               ; ...
        li    a2, 0                     ; ...
        call  os_call                   ; a0 = entries
        li    t0, -1                    ; ...
        blez  a0, hi_fail6              ; ...
        sd    a0, 8(sp)                 ; keep the count
        slli  a0, a0, 5                 ; 32 bytes each
        call  os_get                    ; -> os_buf
        ld    t2, 8(sp)                 ; entries
        la    t3, os_buf                ; first entry
hi_find:
        li    t0, -3                    ; (no framebuffer)
        beqz  t2, hi_fail6              ; ...
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
        li    t6, -3                    ; (anything else: no)
        bne   t1, t2, hi_fail6b         ; ...
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
        srli  t3, t0, 32                ; stride
        and   t3, t3, t2                ; ...
        sd    t3, S_STRIDE(t5)          ; ...
        mul   t1, t1, t3                ; the screen must leave room for the surfaces
        li    t2, HW_SCRMAX             ; ...
        li    t6, -5                    ; (too large)
        bgtu  t1, t2, hi_fail6b         ; ...
        li    a0, 6                     ; GRANT_FB
        li    a1, OP_GRANTFB            ; ...
        li    a2, 0                     ; ...
        call  os_call                   ; 0: c6 = the memory, c7 = the ports
        li    t0, -4                    ; (refused)
        bnez  a0, hi_fail6              ; ...
        cmov  c0, c6                    ; c0 = the framebuffer window
        cclear c4                       ; (the pipe endpoint: not used)
        cmov  c4, c7                    ; c4 = the controller's ports
        call  hw_clock                  ; c7 = the clock again
        li    a0, 0                     ; success
        j     hi_ret                    ; ...
hi_fail6b:
        mv    t0, t6                    ; (the code)
hi_fail6:
        cclear c6                       ; drop dev's endpoint
hi_fail:
        mv    a0, t0                    ; the error
hi_ret: ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; pop the frame
        ret                             ; done

hw_present:                             ; routine entry
        la    t0, hw_reg                ; any 8 bytes
        li    t1, 8                     ; ...
        tput  tg13, t0, c4, zero, t1    ; PRESENT: the frame is complete
        ret                             ; done

; hw_clock(): c7 = the clock (RECEIVE and replies with capabilities take it)
hw_clock:                               ; routine entry
        li    a0, 10                    ; CLOCK
        svc                             ; ...
        ret                             ; done

hw_now:                                 ; routine entry
        la    t0, hw_reg                ; lands here
        li    t1, 8                     ; NOW: 8 bytes at port 0 of the clock
        twait 1 << 13                   ; (a PRESENT may still be reading hw_reg)
        tget  tg13, t0, c7, zero, t1    ; read it
        ld    a0, 0(t0)                 ; (waits for it)
        ret                             ; done

; hw_key_arm(): the keyboard buffer (in c2) goes to tty as a READ. It is
; given with the kernel's REPLY (a give to a core plus its doorbell), since
; it is not the buffer WAIT_REPLY sends.
hw_key_arm:                             ; routine entry
        la    t0, hw_khome              ; at home?
        ld    t1, 0(t0)                 ; ...
        beqz  t1, hka_ret               ; no: already out
        sd    zero, 0(t0)               ; out from now on
        la    t0, hw_kb                 ; the request: READ, up to 32 bytes
        li    t1, OP_READ               ; ...
        sd    t1, 0(t0)                 ; op
        sd    zero, 8(t0)               ; handle
        li    t1, 32                    ; ...
        sd    t1, 16(t0)                ; length
        li    t1, 2                     ; mode: wait; the pointer's events too
        sd    t1, 24(t0)                ; ...
        sd    zero, 32(t0)              ; result
        li    t1, 64                    ; the header -> the buffer
        tput  tg10, t0, c2, zero, t1    ; ...
        twait 1 << 10                   ; ...
        cclear c6                       ; (nothing is being served)
        cmov  c6, c2                    ; REPLY gives c6 ...
        cbase a1, c3                    ; ... to the core tty's endpoint names
        li    a2, 0                     ; nothing else
        li    a0, 3                     ; REPLY
        svc                             ; ...
hka_ret:
        ret                             ; done

; hw_key_take() -> a0 = bytes (in hw_kb + 64), or < 0 (-2: interrupted, the
; break key); a1 = pointer events (8 bytes each, at hw_kb + 96). The answered
; buffer (in c6) goes home to c2.
hw_key_take:                            ; routine entry
        la    t0, hw_kb                 ; header and data -> D-LS
        li    t1, 160                   ; ...
        tget  tg10, t0, c6, zero, t1    ; ...
        ld    a0, 32(t0)                ; the result (waits for the read)
        ld    a1, 24(t0)                ; pointer events
        li    t1, 8                     ; (at most 8)
        bleu  a1, t1, hkt_1             ; ...
        li    a1, 0                     ; (a reply without them)
hkt_1:  bgez  a0, hkt_2                 ; (none with an error)
        li    a1, 0                     ; ...
hkt_2:
        cmov  c2, c6                    ; home
        la    t0, hw_khome              ; ...
        li    t1, 1                     ; ...
        sd    t1, 0(t0)                 ; ...
        ret                             ; done
