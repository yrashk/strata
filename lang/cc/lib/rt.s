; =============================================================================
; rt.s: the StrataOS layer under the C library (and under the compiler)
; =============================================================================
;
; Files and the console are servers in StrataOS; a program asks them with
; messages (os/lib/sys.s explains the protocol). This file is the small part
; of that library a C program needs, with the C calling convention: arguments
; in a0.., result in a0; t0..t6, tp and a0..a7 are not kept, s registers are.
; It is included by lib/libc.s (every compiled program) and by cc.s (the
; compiler itself).
;
;   __init()                      handles 0..2 from the start-up block
;   open(name, mode) -> fd        mode 0 read, 1 write (truncate), 2 append
;   read(fd, buf, n) -> bytes     0 at the end, < 0 on error
;   write(fd, buf, n) -> bytes    all of them, or < 0
;   close(fd) -> 0 / -1
;   unlink(name) -> 0 / < 0
;   _exit(code)                   end the process (no flushing)
;
; One 1 KiB staging buffer, __buf, carries the data of every message: a
; transfer needs an 8-byte-aligned D-LS address, which a C buffer need not be.
; Transfer tag tg10 belongs to this file.

RT_STAGE = 1024                         ; bytes of data per message
RT_NHAND = 8                            ; handles per process
RT_START = 0x7F000                      ; arena offset of the start-up block

        .data                           ; D-LS
        .align 8                        ; transfer buffers are 8-byte aligned
__hdr:  .space 64                       ; the request header: 0 op, 8 handle, 16 length, 24 mode, 32 result
__buf:  .space RT_STAGE + 8             ; message data (and a terminating zero)
__sblk: .space 512                      ; the start-up block: 0 pid, 16 handles, 40 command line length, 64 its text
__htab: .space RT_NHAND * 16            ; handles: {endpoint register (0 = free), server id}

        .text                           ; I-LS
; __init(): read the start-up block, fill handles 0..2
__init:
        li    t0, __sblk                ; the start-up block -> D-LS
        li    t1, RT_START              ; (proc wrote it into the arena)
        li    t2, 512                   ; its size
        tget  tg10, t0, c0, t1, t2      ; arena -> D-LS
        li    t5, 0                     ; t5 = handle
__in_h:
        slli  t6, t5, 3                 ; its descriptor: block offset 16 + 8 h
        add   t6, t0, t6                ; ...
        ld    t6, 16(t6)                ; endpoint register << 32 | id, or -1
        slli  t4, t5, 4                 ; its table entry
        li    t3, __htab                ; ...
        add   t3, t3, t4                ; ...
        sd    zero, 0(t3)               ; assume none
        bltz  t6, __in_n                ; none
        srli  t4, t6, 32                ; endpoint register
        sd    t4, 0(t3)                 ; ...
        slli  t4, t6, 32                ; server id: the low half
        srli  t4, t4, 32                ; ...
        sd    t4, 8(t3)                 ; ...
__in_n:
        addi  t5, t5, 1                 ; next handle
        slti  t6, t5, 3                 ; three standard handles
        bnez  t6, __in_h                ; continue
        ret                             ; done

; __msg(a0 = endpoint register 2..4, a1 = op, a2 = handle, a3 = length,
;       a4 = mode, a5 = bytes of __buf to send) -> a0 = result; the reply's
; data is in the message buffer (c5) from offset 64
__msg:
        li    t0, __hdr                 ; build the header
        sd    a1, 0(t0)                 ; op
        sd    a2, 8(t0)                 ; handle
        sd    a3, 16(t0)                ; length
        sd    a4, 24(t0)                ; mode
        sd    zero, 32(t0)              ; result
        li    t1, 64                    ; header size
        tput  tg10, t0, c5, zero, t1    ; D-LS -> the message buffer
        beqz  a5, __ms_h                ; no data
        addi  a5, a5, 7                 ; whole words of it
        srli  a5, a5, 3                 ; ...
        slli  a5, a5, 3                 ; ...
        li    t2, __buf                 ; from the staging buffer
        tput  tg10, t2, c5, t1, a5      ; ... to offset 64
__ms_h:
        twait 1 << 10                   ; all of it must be in before the buffer leaves
        li    t2, 3                     ; which endpoint?
        beq   a0, t2, __ms_tty          ; c3
        bgt   a0, t2, __ms_pipe         ; c4
        csend c5, c2                    ; fs
        cbase a1, c2                    ; a1 = its core (for the doorbell)
        j     __ms_sent                 ; ...
__ms_tty:
        csend c5, c3                    ; tty
        cbase a1, c3                    ; ...
        j     __ms_sent                 ; ...
__ms_pipe:
        csend c5, c4                    ; pipe
        cbase a1, c4                    ; ...
__ms_sent:
        li    a0, 1                     ; WAIT_REPLY: until the buffer is back
        li    a2, -1                    ; no timeout
        li    a3, 0                     ; awaited: our own buffer
        svc                             ; a0 = 0, or -2 if an interrupt woke us first
        li    a1, -1                    ; (no doorbell when waiting again)
        bnez  a0, __ms_sent             ; the buffer is still out: keep waiting
        li    t0, __hdr                 ; the answered header -> D-LS
        li    t1, 64                    ; ...
        tget  tg10, t0, c5, zero, t1    ; ...
        ld    a0, 32(t0)                ; the result (the load waits for the tget)
        ret                             ; done

; __hent(a0 = fd) -> a0 = its table entry, or 0 if it is not open
__hent:
        sltiu t0, a0, RT_NHAND          ; in range?
        beqz  t0, __he_no               ; no
        slli  a0, a0, 4                 ; the entry
        addi  a0, a0, __htab            ; ...
        ld    t0, 0(a0)                 ; open?
        bnez  t0, __he_ret              ; yes
__he_no:
        li    a0, 0                     ; not a handle
__he_ret:
        ret                             ; done

; read(a0 = fd, a1 = buffer, a2 = n) -> a0 = bytes read (at most RT_STAGE per call)
read:
        addi  sp, sp, -32               ; frame
        sd    ra, 24(sp)                ; ...
        sd    a1, 0(sp)                 ; destination
        li    t0, RT_STAGE              ; one message's worth at most
        bleu  a2, t0, __rd_n            ; ...
        mv    a2, t0                    ; ...
__rd_n:
        sd    a2, 8(sp)                 ; the most wanted
        call  __hent                    ; the handle
        beqz  a0, __rd_bad              ; not open
        ld    a2, 8(a0)                 ; server id
        ld    a0, 0(a0)                 ; endpoint register
        li    a1, 1                     ; READ
        ld    a3, 8(sp)                 ; length
        li    a4, 0                     ; blocking
        li    a5, 0                     ; no data
        call  __msg                     ; a0 = bytes, 0 or an error
        blez  a0, __rd_ret              ; nothing to copy
        li    t0, __buf                 ; the data -> staging
        li    t1, 64                    ; ...
        addi  t2, a0, 7                 ; whole words
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        tget  tg10, t0, c5, t1, t2      ; ...
        ld    t1, 0(sp)                 ; and on to the caller's buffer
        add   t2, t0, a0                ; end of the data
__rd_cp:
        lbu   t3, 0(t0)                 ; a byte (the first load waits for the tget)
        sb    t3, 0(t1)                 ; ...
        addi  t0, t0, 1                 ; next
        addi  t1, t1, 1                 ; ...
        bltu  t0, t2, __rd_cp           ; continue
        j     __rd_ret                  ; done
__rd_bad:
        li    a0, -1                    ; not a handle
__rd_ret:
        ld    ra, 24(sp)                ; ...
        addi  sp, sp, 32                ; ...
        ret                             ; done

; write(a0 = fd, a1 = buffer, a2 = n) -> a0 = n, or < 0
write:
        addi  sp, sp, -48               ; frame
        sd    ra, 40(sp)                ; ...
        sd    a1, 8(sp)                 ; source
        sd    a2, 16(sp)                ; bytes left
        sd    a2, 24(sp)                ; the result
        call  __hent                    ; the handle
        sd    a0, 0(sp)                 ; its entry
        beqz  a0, __wr_bad              ; not open
__wr_loop:
        ld    a3, 16(sp)                ; bytes left
        beqz  a3, __wr_done             ; none
        li    t0, RT_STAGE              ; one message's worth
        bleu  a3, t0, __wr_n            ; ...
        mv    a3, t0                    ; ...
__wr_n:
        li    t0, __buf                 ; copy it into the staging buffer
        ld    t1, 8(sp)                 ; ...
        add   t2, t1, a3                ; end of this piece
__wr_cp:
        lbu   t3, 0(t1)                 ; a byte
        sb    t3, 0(t0)                 ; ...
        addi  t0, t0, 1                 ; next
        addi  t1, t1, 1                 ; ...
        bltu  t1, t2, __wr_cp           ; continue
        ld    t0, 0(sp)                 ; the handle's entry
        ld    a0, 0(t0)                 ; endpoint register
        ld    a2, 8(t0)                 ; server id
        li    a1, 2                     ; WRITE
        li    a4, 0                     ; no mode
        mv    a5, a3                    ; bytes of data
        call  __msg                     ; a0 = bytes taken (a pipe may take fewer)
        blez  a0, __wr_err              ; failed
        ld    t0, 8(sp)                 ; advance
        add   t0, t0, a0                ; ...
        sd    t0, 8(sp)                 ; ...
        ld    t0, 16(sp)                ; ...
        sub   t0, t0, a0                ; ...
        sd    t0, 16(sp)                ; ...
        j     __wr_loop                 ; the rest
__wr_bad:
        li    a0, -1                    ; not a handle
__wr_err:
        sd    a0, 24(sp)                ; the error is the result
__wr_done:
        ld    a0, 24(sp)                ; n, or the error
        ld    ra, 40(sp)                ; ...
        addi  sp, sp, 48                ; ...
        ret                             ; done

; __name(a0 = string) -> a3 = its length, copied with its zero into __buf
; (at most RT_STAGE bytes); a5 = bytes to send
__name:
        li    t0, __buf                 ; destination
        li    a3, 0                     ; length
__nm_cp:
        lbu   t1, 0(a0)                 ; a byte
        sb    t1, 0(t0)                 ; ...
        beqz  t1, __nm_end              ; the zero ends it
        addi  a0, a0, 1                 ; next
        addi  t0, t0, 1                 ; ...
        addi  a3, a3, 1                 ; count
        slti  t1, a3, RT_STAGE          ; room?
        bnez  t1, __nm_cp               ; continue
        sb    zero, 0(t0)               ; cut
__nm_end:
        addi  a5, a3, 1                 ; the zero is sent too
        ret                             ; done

; open(a0 = name, a1 = mode: 0 read, 1 write, 2 append) -> a0 = fd, or < 0
open:
        addi  sp, sp, -16               ; frame
        sd    ra, 8(sp)                 ; ...
        mv    a4, a1                    ; mode
        call  __name                    ; the name -> __buf, a3 = length
        li    a0, 2                     ; fs
        li    a1, 3                     ; OPEN
        li    a2, 0                     ; no handle
        call  __msg                     ; a0 = fs id, or an error
        bltz  a0, __op_ret              ; failed
        li    t0, __htab + 48           ; a free handle from 3 up
        li    t1, 3                     ; ...
__op_find:
        ld    t2, 0(t0)                 ; free?
        beqz  t2, __op_take             ; yes
        addi  t0, t0, 16                ; next
        addi  t1, t1, 1                 ; ...
        slti  t2, t1, RT_NHAND          ; any left?
        bnez  t2, __op_find             ; continue
        li    a0, -1                    ; no free handle
        j     __op_ret                  ; ...
__op_take:
        li    t2, 2                     ; it is fs's
        sd    t2, 0(t0)                 ; ...
        sd    a0, 8(t0)                 ; its id there
        mv    a0, t1                    ; the fd
__op_ret:
        ld    ra, 8(sp)                 ; ...
        addi  sp, sp, 16                ; ...
        ret                             ; done

; close(a0 = fd) -> a0 = 0, or -1
close:
        addi  sp, sp, -16               ; frame
        sd    ra, 8(sp)                 ; ...
        call  __hent                    ; the handle
        beqz  a0, __cl_bad              ; not open
        sd    a0, 0(sp)                 ; its entry
        ld    a2, 8(a0)                 ; server id
        ld    a0, 0(a0)                 ; endpoint register
        li    a1, 4                     ; CLOSE
        li    a3, 0                     ; ...
        li    a4, 0                     ; ...
        li    a5, 0                     ; no data
        call  __msg                     ; a0 = result
        ld    t0, 0(sp)                 ; the handle is free now
        sd    zero, 0(t0)               ; ...
        li    a0, 0                     ; done
        j     __cl_ret                  ; ...
__cl_bad:
        li    a0, -1                    ; not a handle
__cl_ret:
        ld    ra, 8(sp)                 ; ...
        addi  sp, sp, 16                ; ...
        ret                             ; done

; unlink(a0 = name) -> a0 = 0, or < 0
unlink:
        addi  sp, sp, -16               ; frame
        sd    ra, 8(sp)                 ; ...
        call  __name                    ; the name -> __buf
        li    a0, 2                     ; fs
        li    a1, 11                    ; UNLINK
        li    a2, 0                     ; ...
        li    a4, 0                     ; ...
        call  __msg                     ; a0 = result
        ld    ra, 8(sp)                 ; ...
        addi  sp, sp, 16                ; ...
        ret                             ; done

; _exit(a0 = code): end the process
_exit:
        mv    a1, a0                    ; the code
        li    a0, 5                     ; EXIT
        svc                             ; does not return
        halt                            ; (not reached)
