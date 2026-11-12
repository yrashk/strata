; =============================================================================
; clock.s: the timer, and why a device "interrupt" is just a transfer
; =============================================================================
;
; What it shows
;   * Finding a device. Core 0 reads the platform table (device space 0x1000)
;     and looks for the timer entry (type 6): where its registers are and how
;     many ticks make a second. It then cuts a capability for exactly the
;     timer's 32 bytes of device space out of its device root c3.
;   * Reading a register is a transfer. NOW (offset 0) and FREQ (offset 8)
;     are 8-byte registers: a `tget` of 8 bytes copies one into the D-LS.
;     Writing DEADLINE (offset 0x10) is a `tput` of 8 bytes.
;   * Waiting for time is a transfer too. A read of WAIT (offset 0x18) does
;     not finish until NOW >= DEADLINE; then it delivers NOW. Until then its
;     tag stays busy, exactly like a slow memory read. Nothing else stops:
;     the core keeps running, other cores keep running.
;   * There are no interrupts, and none are needed. `tany` waits until any
;     of several things is ready: here, "the WAIT transfer on tag 1 has
;     finished" OR "a capability has arrived in my inbox" (core 1 hands back
;     a result). Whichever happens first is handled first; this is how a
;     Strata program waits for a device and something else at once.
;
; Expected output (lines starting with '@' contain times, which differ from
; run to run and between machines):
;   timer at device offset 12288, 1000000 ticks per second
;   FREQ register says 1000000
;   @ NOW at start:    0000001234
;   core 1 finished while we waited: 1^2 + ... + 300^2 = 9045050
;   tick 1
;   @   NOW = start +  0000005000
;   ... (4 ticks, 5000 ticks = 5 ms apart)
;   @ elapsed:         0000020000 ticks
;   every WAIT ended at or after its DEADLINE: yes
;
; With the real-time timer on a slow machine (the RTL simulator runs a few
; thousand cycles per millisecond of host time) core 1 may finish only after
; the first tick: then its line comes after "tick 1". The program does not
; care which comes first; that is the point of `tany`.

TICKS   = 4                             ; how many ticks to wait for
PERIOD  = 5000                          ; ticks between them: 5000 us = 5 ms
PT_TIMER = 6                            ; platform table entry type of a timer
PLAT    = 0x1000                        ; device-space offset of the platform table
PLATMAX = 512                           ; bytes of D-LS set aside for the table
R_FREQ  = 0x08                          ; timer register offsets: FREQ (NOW is 0)
R_DL    = 0x10                          ; DEADLINE
R_WAIT  = 0x18                          ; WAIT
NSQ     = 300                           ; core 1 sums the squares of 1..NSQ

        .data                           ; data Local Store (one per core)
        .align 8                        ; transfer buffers must be 8-byte aligned
plat:   .space PLATMAX                  ; core 0: copy of the platform table
treg:   .space 8                        ; a timer register value read with tget
dlbuf:  .space 8                        ; the DEADLINE value being written
wbuf:   .space 8                        ; where the WAIT transfer puts NOW when it completes
mbox:   .space 8                        ; core 1: its result, on the way to system memory
m_at:   .ascii "timer at device offset " ; message pieces follow, each with an end label
m_at_e:                                 ; end of the text above
m_tps:  .ascii ", "                     ; separator
m_tps_e:                                ; end of the text above
m_tps2: .ascii " ticks per second\n"    ; rest of that line
m_tps2_e:                               ; end of the text above
m_freq: .ascii "FREQ register says "    ; label for the FREQ value
m_freq_e:                               ; end of the text above
m_start: .ascii "@ NOW at start:    "   ; '@': a line with a time in it
m_start_e:                              ; end of the text above
m_gift: .ascii "core 1 finished while we waited: 1^2 + ... + 300^2 = " ; core 1's result line
m_gift_e:                               ; end of the text above
m_tick: .ascii "tick "                  ; tick line
m_tick_e:                               ; end of the text above
m_now:  .ascii "@   NOW = start +  "    ; time of a tick, relative to the start
m_now_e:                                ; end of the text above
m_el:   .ascii "@ elapsed:         "    ; total time
m_el_e:                                 ; end of the text above
m_el2:  .ascii " ticks\n"               ; unit
m_el2_e:                                ; end of the text above
m_ok:   .ascii "every WAIT ended at or after its DEADLINE: " ; the check
m_ok_e:                                 ; end of the text above
m_yes:  .ascii "yes\n"                  ; verdict
m_no:   .ascii "no!\n"                  ; verdict (same length as "yes\n")
m_none: .ascii "no timer in the platform table\n" ; for machines without one
m_none_e:                               ; end of the text above

        .text                           ; instruction Local Store; execution starts at 0
_start:
        csrr  s0, coreid                ; s0 = this core's number
        beqz  s0, main                  ; core 0 runs the clock
        li    t0, 1                     ; t0 = 1
        bne   s0, t0, rest              ; cores 2 and up have nothing to do

; ---- core 1: a little job that finishes while core 0 waits for the timer -----
        ctake c4, zero                  ; wait for a mailbox (8 bytes of system memory) from core 0
        li    t0, 1                     ; t0 = i, from 1
        li    t1, NSQ                   ; t1 = last i
        li    a0, 0                     ; a0 = running sum
sq_loop:                                ; loop: add i*i
        mul   t2, t0, t0                ; t2 = i^2
        add   a0, a0, t2                ; sum += i^2
        addi  t0, t0, 1                 ; i++
        bleu  t0, t1, sq_loop           ; until i > NSQ
        la    t0, mbox                  ; t0 = D-LS buffer
        sd    a0, 0(t0)                 ; put the sum there
        li    t1, 8                     ; one 8-byte word
        tput  tg0, t0, c4, zero, t1     ; write it into the mailbox
        cgive c4, zero                  ; hand the mailbox back to core 0 (only after the tput landed)
rest:
        li    a0, 0                     ; exit code
        halt                            ; this core is done

; ---- core 0: find the timer ---------------------------------------------------
main:
        cmov  c8, c3                    ; c8 = a copy of the device root (it is copyable)
        li    t0, PLAT                  ; where the platform table starts
        csplit c9, c8, t0               ; c8 = [0, PLAT), c9 = [PLAT, end of device space)
        li    t0, PLATMAX               ; how much of it we want
        csplit c10, c9, t0              ; c9 = the table window, c10 = everything after it
        cclear c8                       ; drop the pieces we do not need
        cclear c10                      ; (copies of a copyable capability: nothing is lost)
        la    s1, plat                  ; s1 = D-LS copy of the table
        li    t0, PLATMAX               ; read the whole window (bytes past the table read as 0)
        tget  tg0, s1, c9, zero, t0     ; platform table -> D-LS
        lhu   t2, 8(s1)                 ; t2 = number of entries (this load waits for the tget)
        addi  t3, s1, 32                ; t3 = first entry, after the 32-byte header
find:                                   ; loop: look at one entry
        beqz  t2, no_timer              ; ran out of entries
        lhu   t4, 0(t3)                 ; t4 = entry type
        li    t5, PT_TIMER              ; the type we want
        beq   t4, t5, found             ; found it
        addi  t3, t3, 32                ; next entry (32 bytes each)
        addi  t2, t2, -1                ; one fewer left
        j     find                      ; continue
no_timer:
        la    a0, m_none                ; complain
        li    a1, m_none_e - m_none     ; its length
        call  print_str                 ; print it
        li    a0, 1                     ; exit code 1
        halt                            ; give up
found:
        ld    s2, 16(t3)                ; s2 = base: the timer's offset in device space
        ld    s3, 24(t3)                ; s3 = size of its register window
        ld    s4, 8(t3)                 ; s4 = info: ticks per second
        cmov  c8, c3                    ; another copy of the device root
        csplit c5, c8, s2               ; c8 = [0, base), c5 = [base, end)
        csplit c10, c5, s3              ; c5 = exactly the timer's registers, c10 = the rest
        cclear c8                       ; drop the pieces
        cclear c10                      ; we keep only c5: this program can touch nothing else there
        la    a0, m_at                  ; "timer at device offset "
        li    a1, m_at_e - m_at         ; length
        call  print_str                 ; print it
        mv    a0, s2                    ; the offset
        call  print_dec                 ; print it
        la    a0, m_tps                 ; ", "
        li    a1, m_tps_e - m_tps       ; length
        call  print_str                 ; print it
        mv    a0, s4                    ; ticks per second, from the table
        call  print_dec                 ; print it
        la    a0, m_tps2                ; " ticks per second\n"
        li    a1, m_tps2_e - m_tps2     ; length
        call  print_str                 ; print it

; ---- read two registers -------------------------------------------------------
        la    s1, treg                  ; s1 = 8-byte register buffer
        li    t0, R_FREQ                ; FREQ's offset in the timer window
        li    t1, 8                     ; registers are 8 bytes
        tget  tg0, s1, c5, t0, t1       ; FREQ -> treg
        la    a0, m_freq                ; label
        li    a1, m_freq_e - m_freq     ; length
        ld    a2, 0(s1)                 ; a2 = FREQ (waits for the tget)
        call  print_kv                  ; print "FREQ register says N\n"
        li    t1, 8                     ; 8 bytes again (print_kv clobbered t1)
        tget  tg0, s1, c5, zero, t1     ; NOW (offset 0) -> treg: the start time
        ld    s5, 0(s1)                 ; s5 = start (byte 0 latched all 8: no torn value)
        la    a0, m_start               ; "@ NOW at start: "
        li    a1, m_start_e - m_start   ; length
        call  print_str                 ; print it
        mv    a0, s5                    ; the start time
        call  print_dec10               ; always 10 digits: the same instructions whatever the value
        call  print_nl                  ; end the line

; ---- give core 1 a mailbox, then start the first wait --------------------------
        li    s7, 2                     ; s7 = what tany waits for: bit 1 = tag 1 (the WAIT)
        csrr  t0, ncores                ; t0 = number of cores
        li    t1, 2                     ; core 1 must exist for the helper
        bltu  t0, t1, no_helper         ; a single core: just the clock
        li    t0, 8                     ; mailbox size
        csplit c6, c0, t0               ; c0 = the first 8 bytes of system memory, c6 = the rest
        li    t0, 1                     ; core 1
        cgive c0, t0                    ; core 1 now owns the mailbox (c0 becomes empty)
        li    t0, 0x10000               ; bit 16 of a tany mask: "a capability arrived"
        or    s7, s7, t0                ; wait for that too
no_helper:
        li    s6, 0                     ; s6 = ticks seen so far
        li    s9, 0                     ; s9 = 0 while every WAIT behaved
        call  arm                       ; set DEADLINE and start the WAIT on tag 1

; ---- the event loop: wait for whichever comes first ------------------------------
events:
        beqz  s7, finish                ; nothing left to wait for
        tany  t0, s7                    ; t0 = the ready subset of s7 (blocks until it is not empty)
        mv    s8, t0                    ; s8 = it (the prints below clobber t registers)
        srli  t1, s8, 16                ; bit 16 down to bit 0
        andi  t1, t1, 1                 ; t1 = 1 if a capability is waiting
        beqz  t1, no_gift               ; no gift this time
        li    t0, 1                     ; core 1
        ctake c7, t0                    ; take the mailbox back (only a gift from core 1 counts)
        la    t0, mbox                  ; t0 = D-LS buffer
        li    t1, 8                     ; one word
        tget  tg0, t0, c7, zero, t1     ; read core 1's result out of it
        la    a0, m_gift                ; label
        li    a1, m_gift_e - m_gift     ; length
        ld    a2, 0(t0)                 ; a2 = the sum (waits for the tget)
        call  print_kv                  ; print the line
        li    t0, 0x10000               ; bit 16
        xor   s7, s7, t0                ; stop waiting for gifts
no_gift:
        andi  t1, s8, 2                 ; t1 = 2 if tag 1 (the WAIT) has completed
        beqz  t1, events                ; not yet: back to waiting
        addi  s6, s6, 1                 ; one more tick
        la    a0, m_tick                ; "tick "
        li    a1, m_tick_e - m_tick     ; length
        mv    a2, s6                    ; the tick number
        call  print_kv                  ; print "tick N\n"
        la    t0, wbuf                  ; where WAIT put NOW at the moment it completed
        ld    t1, 0(t0)                 ; t1 = that time
        bgeu  t1, s10, on_time          ; it must be at or after the DEADLINE we set (s10)
        li    s9, 1                     ; it was not: remember
on_time:
        la    a0, m_now                 ; "@   NOW = start + "
        li    a1, m_now_e - m_now       ; length
        call  print_str                 ; print it
        la    t0, wbuf                  ; the completion time again
        ld    a0, 0(t0)                 ; a0 = it
        sub   a0, a0, s5                ; minus the start time
        call  print_dec10               ; 10 digits
        call  print_nl                  ; end the line
        li    t0, TICKS                 ; how many ticks we want
        bgeu  s6, t0, last_tick         ; that was the last one
        call  arm                       ; otherwise wait for the next
        j     events                    ; and go back to waiting
last_tick:
        xori  s7, s7, 2                 ; stop waiting for tag 1
        j     events                    ; (the loop ends once nothing is left)

; ---- done: total time and the verdict -------------------------------------------
finish:
        la    s1, treg                  ; register buffer
        li    t1, 8                     ; 8 bytes
        tget  tg0, s1, c5, zero, t1     ; NOW -> treg
        la    a0, m_el                  ; "@ elapsed: "
        li    a1, m_el_e - m_el         ; length
        call  print_str                 ; print it
        ld    a0, 0(s1)                 ; a0 = NOW
        sub   a0, a0, s5                ; minus the start
        call  print_dec10               ; 10 digits
        la    a0, m_el2                 ; " ticks\n"
        li    a1, m_el2_e - m_el2       ; length
        call  print_str                 ; print it
        la    a0, m_ok                  ; the check
        li    a1, m_ok_e - m_ok         ; length
        call  print_str                 ; print it
        la    a0, m_yes                 ; "yes\n"
        beqz  s9, verdict               ; every WAIT was on time
        la    a0, m_no                  ; "no!\n"
verdict:
        li    a1, 4                     ; both answers are 4 bytes
        call  print_str                 ; print it
        li    a0, 0                     ; exit code
        halt                            ; stop (after the console output drains)

; -----------------------------------------------------------------------------
; arm(): DEADLINE = start + (ticks + 1) * PERIOD, then start a WAIT on tag 1.
; Neither transfer is waited for here: the WAIT's tag stays busy until the
; timer reaches the deadline, and tany above notices when it is done.
; -----------------------------------------------------------------------------
arm:                                    ; routine entry
        addi  t0, s6, 1                 ; t0 = number of the next tick
        li    t1, PERIOD                ; ticks per period
        mul   t0, t0, t1                ; t0 = its offset from the start
        add   s10, s5, t0               ; s10 = the deadline (absolute: no drift from late wakeups)
        la    t2, dlbuf                 ; t2 = the 8 bytes to write
        sd    s10, 0(t2)                ; (stalls if the last DEADLINE tput still reads them)
        li    t3, R_DL                  ; DEADLINE's offset
        li    t4, 8                     ; 8 bytes; the value takes effect when byte 7 lands
        tput  tg2, t2, c5, t3, t4       ; DEADLINE = s10
        la    t2, wbuf                  ; where NOW goes when the wait is over
        li    t3, R_WAIT                ; WAIT's offset
        tget  tg1, t2, c5, t3, t4       ; start waiting (transfers to one device stay in order,
                                        ; so this sees the new DEADLINE)
        ret                             ; return at once: the wait goes on in the background

        .include "lib/print.s"          ; console helpers
