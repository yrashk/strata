; =============================================================================
; stralog.s: Stralog, a Prolog for Strata, written in Strata assembly
; =============================================================================
;
; `stralog` is a StrataOS program: a Prolog top level, `stralog FILE...`
; consults files first, `stralog -g GOAL FILE...` runs a goal and halts. The
; design (cells, the solve loop, the windows, the far cache) is in
; lang/prolog/DESIGN.md; the language and its limits in README.md.
;
; How the program is laid out
;   * Resident (I-LS from 0x8000): this file's code, core.s (cells, the
;     windows, the far cache, unification, templates), solve.s (the solve
;     loop, control constructs, backtracking, exceptions) and os/lib/sys.s.
;   * Everything else is 4 KiB code units in the `.far` section, paged in by
;     StrataOS (xslot = 12). The far section is too large to travel in the
;     image with the Local Store sections (128 KiB at most), so the build
;     splits it into a second file, /bin/stralog.u, which start-up reads into
;     the arena at its own offsets before anything else runs.
;   * The rules for calls are cc's (lang/cc/cc.s): a unit calls a unit with
;     `la t6, f` / `xcall ra, c0, t6` and returns with `xret ra`; a unit
;     calls resident code with `jalr ra, gp, name-R` (gp = R = 0x10000);
;     resident code that a unit calls never calls a unit. The solve loop is
;     resident code that nothing calls: it calls units freely.
;   * A function in a unit starts with `jalr t6, gp, entN-R` (save ra and
;     s1..sN) and ends with `jalr zero, gp, lvN-R` (restore them, xret).
;
; Registers: a0..a7 arguments and results, t0..t6 scratch, s1..s11 kept by
; callees, gp = R. Variables are in the D-LS below 0x8000: `ld t0, v(zero)`.
;
; Memory is explicit. A cell refers to other cells by arena offset, never by
; D-LS address. Three windows in the D-LS hold the tops of the heap, the
; trail and the choicepoint stack; everything else (older stack cells, the
; atoms, the clauses, the findall area) is reached through a 4 KiB
; write-back far cache built on the tag table (ltag / linst). Every byte that
; moves between the two is a tget or a tput below, and statistics/0 counts
; them.

R        = 0x10000                      ; gp: the base for calls into resident code

; ---- cells: 64 bits, a tag in the low 3 ------------------------------------------------
T_REF    = 0                            ; a variable: the arena offset of the cell it names
T_STR    = 1                            ; a compound: the offset of its functor cell, + 1
T_ATM    = 3                            ; an atom: the offset of its record, + 3
T_INT    = 4                            ; an integer: value << 3, + 4 (61 bits)
T_FUN    = 5                            ; a functor cell: (atom offset >> 3) << 16 | arity << 3 | 5
T_TVAR   = 6                            ; in a template: variable i (i << 3 | 6)
END      = T_INT                        ; the empty continuation: the integer 0
MAXAR    = 255                          ; the largest arity

; ---- the arena (c0) -------------------------------------------------------------------
; 0x00000 the far section: atoms.s's predefined atoms, the code units, boot.pl
A_ATOM   = 0x20000                      ; atoms made at run time
A_ATOMEND = 0x30000                     ; ...
A_HASH   = 0x30000                      ; the atom hash: NHASH heads
NHASH    = 1024                         ; ...
A_DB     = 0x32000                      ; predicates and clauses
A_DBEND  = 0x60000                      ; ...
A_FA     = 0x60000                      ; findall answers and exception balls, as templates
A_FAEND  = 0x7F000                      ; (0x7F000: the start-up block, the system's)
A_HEAP   = 0x80000                      ; the heap
A_HEAPEND = 0xC0000                     ; ... (with a 1 MiB arena: layout() sizes these three
                                        ;   regions from the arena's length, v_heapend ...)
HRESERVE = 4096                         ; heap kept for the resource error
A_TRAIL  = 0xC0000                      ; the trail: offsets of bound cells
A_TRAILEND = 0xC8000                    ; ...
A_CP     = 0xC8000                      ; the choicepoint stack
A_CPEND  = 0xD0000                      ; (the arena's program memory ends here)

; ---- atom record (arena) ----------------------------------------------------------------
AT_NEXT  = 0                            ; next record in its hash chain (0: none)
AT_LEN   = 8                            ; length of the name
AT_PRED  = 16                           ; first predicate record of this name (0: none)
AT_OPS   = 24                           ; operators: prefix | infix << 16 | postfix << 32
AT_NAME  = 40                           ; the name, padded to 8 bytes
NAMEMAX  = 1000                         ; the longest name
; an operator: priority | type << 12; types:
OPT_XFX  = 1                            ; .
OPT_XFY  = 2                            ; .
OPT_YFX  = 3                            ; .
OPT_FY   = 4                            ; .
OPT_FX   = 5                            ; .
OPT_XF   = 6                            ; .
OPT_YF   = 7                            ; .

; ---- predicate record (arena, A_DB) -----------------------------------------------------
PR_NEXT  = 0                            ; next predicate of the same name
PR_FUN   = 8                            ; its functor cell
PR_FIRST = 16                           ; first clause (0: none)
PR_LAST  = 24                           ; last clause
PR_FLAGS = 32                           ; PF_*
PR_BI    = 40                           ; builtin: a control id (< 256) or a unit routine's far address
PR_CONS  = 48                           ; the consult that last defined it
PR_ALL   = 56                           ; the next predicate made (v_preds: the last one)
PRSZ     = 64                           ; record size
PF_DYN   = 1                            ; dynamic
PF_SYS   = 2                            ; defined by boot.pl: not to be redefined by consult

; ---- clause record (arena, A_DB) --------------------------------------------------------
CL_NEXT  = 0                            ; next clause (0: none)
CL_BORN  = 8                            ; the generation that added it
CL_DIED  = 16                           ; the generation that retracted it (huge: alive)
CL_KEY   = 24                           ; first-argument key (0: a variable, matches anything)
CL_NVARS = 32                           ; variables in the template
CL_HEAD  = 40                           ; head template cell
CL_BODY  = 48                           ; body template cell
CL_PRED  = 56                           ; its predicate
CLSZ     = 64                           ; record size; template cells follow
ALIVE    = 0x7FFFFFFFFFFFFFFF           ; CL_DIED of a live clause

; ---- choicepoint frame (arena, A_CP) -------------------------------------------------------
CP_PREV  = 0                            ; the frame below
CP_KIND  = 8                            ; K_*
CP_H     = 16                           ; heap top to restore
CP_TR    = 24                           ; trail top to restore
CP_GOAL  = 32                           ; the goal (clause, catch, findall); the else branch (or)
CP_CONT  = 40                           ; the continuation to resume
CP_ALT   = 48                           ; next clause; findall: the answers' start
CP_AUX   = 56                           ; generation (clause), cut barrier (or, catch, findall)
CPSZ     = 64                           ; frame size
K_TOP    = 1                            ; the bottom: failing into it ends the goal
K_CLAUSE = 2                            ; more clauses
K_OR     = 3                            ; the other branch of a disjunction
K_CATCH  = 4                            ; catch/3
K_FINDALL = 5                           ; findall/3: collect the answers
K_DEAD   = 6                            ; removed by a soft cut: skipped

; ---- windows (D-LS descriptor) ----------------------------------------------------------
W_BASE   = 0                            ; WB: the arena offset of the window's first byte
W_MASK   = 8                            ; size - 1 (size: a power of two)
W_RING   = 16                           ; the D-LS ring: offset o lives at ring + (o & mask)
W_HALF   = 24                           ; bytes written out by a spill
W_LO     = 32                           ; the region's start
W_ID     = 40                           ; 0 heap, 1 trail, 2 choicepoints (which transfer tag)
W_SPILL  = 48                           ; spills
W_SLIDE  = 56                           ; slides down
W_BYTES  = 64                           ; bytes moved
WDSZ     = 72                           ; descriptor size
HWSZ     = 8192                         ; heap window
TWSZ     = 1024                         ; trail window
CWSZ     = 2048                         ; choicepoint window

; ---- the far cache: 32 sets of 2 ways of 64-byte lines ------------------------------------
FC_LSH   = 6                            ; 64-byte lines
FC_SLG   = 5                            ; 32 sets
FC_WAYS  = 2                            ; 2 ways
FC_SETS  = 1 << FC_SLG                  ; ...
FC_LINE  = 1 << FC_LSH                  ; ...
FC_NL    = FC_SETS * FC_WAYS            ; lines
FC_SPAN  = (FC_WAYS + 1) * 8            ; tag table bytes per set: a tag per way, a counter
FC_GEOM  = FC_LSH | FC_SLG << 6 | FC_WAYS << 12 ; the tgeom CSR

; ---- control constructs: PR_BI below 256 -------------------------------------------------
C_TRUE   = 1                            ; true
C_FAIL   = 2                            ; fail, false
C_CONJ   = 3                            ; ,/2
C_CUT    = 4                            ; !
C_OR     = 5                            ; ;/2 (with -> and *-> inside)
C_ITE    = 6                            ; ->/2
C_SOFT   = 7                            ; *->/2
C_NOT    = 8                            ; \+/1, not/1
C_CALL   = 9                            ; call/1..8
C_CATCH  = 10                           ; catch/3
C_THROW  = 11                           ; throw/1
C_FINDALL = 12                          ; findall/3
C_FAADD  = 13                           ; '$fa_add'/2
C_DCUT   = 14                           ; '$cut'/1
C_EXITC  = 15                           ; '$exit_catch'/1
C_SOFTCUT = 16                          ; '$softcut'/1
C_CHOICE = 17                           ; '$choice'/1
C_HALT   = 18                           ; halt/0, halt/1
C_LAST   = 18                           ; ...

; ---- streams (D-LS) --------------------------------------------------------------------
NSTREAM  = 4                            ; 0 user_input, 1 user_output, 2.. files and text
S_KIND   = 0                            ; SK_*
S_HAND   = 8                            ; OS handle
S_POS    = 16                           ; next byte (buffer index; text: arena offset)
S_LEN    = 24                           ; bytes in the buffer (text: end offset)
S_LINE   = 32                           ; line number
S_PEEK   = 40                           ; a character pushed back (-2: none)
S_EOF    = 48                           ; 1: the end was read
SSZ      = 56                           ; record size
SBUF     = 512                          ; buffer bytes per stream
SK_FREE  = 0                            ; not open
SK_IN    = 1                            ; an input handle (stdin or a file)
SK_OUT   = 2                            ; an output handle (stdout or a file)
SK_TEXT  = 3                            ; text in the arena (boot.pl, an atom being read)

KBUF     = 64                           ; the line editor: keys read at once
NHIST    = 8                            ; lines it remembers
HLINE    = 128                          ; bytes of each it keeps
SPMIN    = 0xE000 + 768                 ; recursion stops here with resource_error

        .include "atoms.s"              ; the predefined atoms: their labels are known from here on

; =============================================================================
        .text                           ; the program's first two words
_start: j     main                      ; skip the marker
        .word 0x32535953                ; "SYS2": a StrataOS program

; =============================================================================
        .data                           ; D-LS: the windows and the cache first (aligned, low)
; =============================================================================
hring:    .space HWSZ                   ; heap window ring            0x0000
cring:    .space CWSZ                   ; choicepoint window ring     0x2000
tring:    .space TWSZ                   ; trail window ring           0x2800
fc_lines: .space FC_NL * FC_LINE        ; far cache lines             0x2C00
fc_tags:  .space FC_SETS * FC_SPAN      ; its tag table (ltag / linst)
fc_dirty: .space FC_NL                  ; a dirty byte per line
        .align 8                        ; words
; ---- the windows ---------------------------------------------------------------------------
wh:       .dword A_HEAP, HWSZ - 1, hring, HWSZ / 2, A_HEAP, 0, 0, 0 ; heap
        .dword 0                         ; (continued)
wt:       .dword A_TRAIL, TWSZ - 1, tring, TWSZ / 2, A_TRAIL, 1, 0, 0 ; trail (layout() sets the bases)
        .dword 0                         ; (continued)
wc:       .dword A_CP, CWSZ - 1, cring, CWSZ / 2, A_CP, 2, 0, 0 ; choicepoints
        .dword 0                         ; (continued)
; ---- the machine ---------------------------------------------------------------------------
v_H:      .dword A_HEAP                 ; heap top
v_heapend: .dword A_HEAPEND              ; the regions, as layout() made them
v_trail:  .dword A_TRAIL                ; ...
v_trailend: .dword A_TRAILEND           ; ...
v_cp:     .dword A_CP                   ; ...
v_cpend:  .dword A_CPEND                ; ...
v_k0:     .dword 0                      ; bases for statistics: none
v_kheap:  .dword A_HEAP                 ; ...
v_katom:  .dword A_ATOM                 ; ...
v_kdb:    .dword A_DB                   ; ...
v_kfa:    .dword A_FA                   ; ...
v_hlim:   .dword A_HEAPEND - HRESERVE   ; the heap's limit (the reserve is for the error saying it is full)
v_HB:     .dword A_HEAP                 ; heap top when the newest choicepoint was made
v_TR:     .dword A_TRAIL                ; trail top
v_B:      .dword A_CP - CPSZ            ; newest choicepoint frame
v_CONT:   .dword END                    ; continuation
v_gen:    .dword 1                      ; database generation (logical update view)
v_fatop:  .dword A_FA                   ; findall area top
v_frame:  .dword 0                      ; the frame of the template being built or matched
v_ssp:    .dword 0                      ; sp of the solve loop (an exception goes back to it)
v_dbtop:  .dword A_DB                   ; next free byte of the clause store
v_atop:   .dword A_ATOM                 ; next free byte of the atom area
v_infer:  .dword 0                      ; calls made
v_fcmiss: .dword 0                      ; far cache misses
v_fcwb:   .dword 0                      ; far cache write-backs
v_cons:   .dword 0                      ; the consult in progress (0: none)
v_preds:  .dword 0                      ; the predicate made last (PR_ALL links them)
v_sin:    .dword 0                      ; current input stream
v_sout:   .dword 1                      ; current output stream
v_tty:    .dword 0                      ; 1: user_input is the console (raw while a line is typed)
v_hn:     .dword 0                      ; lines typed so far (the line editor's history)
v_kpos:   .dword 0                      ; keys read and not taken: kbuf[v_kpos..v_klen)
v_klen:   .dword 0                      ; ...
v_tmp:    .dword 0, 0, 0, 0             ; scratch words
; ---- streams ----------------------------------------------------------------------------
streams:  .space NSTREAM * SSZ          ; records
sbufs:    .space NSTREAM * SBUF         ; their buffers
NB:       .space NAMEMAX + 24           ; a name: the token being read, an atom being written
NB2:      .space 264                    ; a second name buffer (numbers, short names)
kbuf:     .space KBUF                   ; keys read from user_input
hist:     .space NHIST * HLINE          ; the last lines typed
hist_len: .space NHIST * 8              ; their lengths
        .align 8                        ; ...
m_ulname: .ascii "/bin/stralog.u"       ; the file of code units
m_ulname_e:                             ; ...
m_noul:   .ascii "stralog: cannot read /bin/stralog.u\n" ; ...
m_noul_e:                               ; ...
        .align 8                        ; ...

; =============================================================================
        .text                           ; resident code
; =============================================================================
main:
        lui   gp, 1                     ; gp = R
        call  sys_init                  ; handles, arguments
        li    t0, 12                    ; 4 KiB code units
        csrw  xslot, t0                 ; ...
        call  fc_init                   ; the far cache's tag table
        call  layout                    ; the stacks fill the arena
        call  load_units                ; /bin/stralog.u -> the arena at offset 0
        la    t6, pl_init               ; atoms, builtins, boot.pl (a unit)
        xcall ra, c0, t6                ; ...
        li    a0, at_dollar_start + T_ATM ; run '$start' (boot.pl)
        j     solve                     ; and never come back

; layout(): the heap, the trail and the choicepoint stack fill the arena's
; program memory from A_HEAP to its end (`-m N stralog` gives an arena of
; N MiB): the choicepoints a 32nd of it, the trail a 16th, at least 32 KiB each
layout:
        clen  t0, c0                    ; the end
        li    t1, 0xFFFF0000            ; (a multiple of 64 KiB is plenty)
        and   t0, t0, t1                ; ...
        sd    t0, v_cpend(zero)         ; ...
        srli  t1, t0, 5                 ; choicepoints
        li    t2, 0x8000                ; ...
        bgeu  t1, t2, lo_cp             ; ...
        mv    t1, t2                    ; ...
lo_cp:
        srli  t1, t1, 6                 ; whole frames
        slli  t1, t1, 6                 ; ...
        sub   t3, t0, t1                ; ...
        sd    t3, v_cp(zero)            ; ...
        sd    t3, wc+W_BASE(zero)       ; ...
        sd    t3, wc+W_LO(zero)         ; ...
        sd    t3, v_trailend(zero)      ; ...
        addi  t4, t3, -CPSZ             ; no frame yet
        sd    t4, v_B(zero)             ; ...
        srli  t1, t0, 4                 ; the trail
        bgeu  t1, t2, lo_tr             ; ...
        mv    t1, t2                    ; ...
lo_tr:
        srli  t1, t1, 6                 ; whole frames
        slli  t1, t1, 6                 ; ...
        sub   t3, t3, t1                ; ...
        sd    t3, v_trail(zero)         ; ...
        sd    t3, wt+W_BASE(zero)       ; ...
        sd    t3, wt+W_LO(zero)         ; ...
        sd    t3, v_TR(zero)            ; ...
        sd    t3, v_heapend(zero)       ; the heap: the rest
        li    t1, HRESERVE              ; ...
        sub   t3, t3, t1                ; ...
        sd    t3, v_hlim(zero)          ; ...
        ret                             ; done

; load_units(): read /bin/stralog.u into the arena from offset 0, through
; the heap window's ring as a staging buffer (nothing is on the heap yet)
load_units:
        addi  sp, sp, -40               ; frame
        sd    ra, 0(sp)                 ; ...
        sd    s1, 8(sp)                 ; s1 = handle
        sd    s2, 16(sp)                ; s2 = bytes in the buffer
        sd    s3, 24(sp)                ; s3 = arena offset of the buffer's first byte
        la    a0, m_ulname              ; open it
        li    a1, m_ulname_e - m_ulname ; ...
        li    a2, 0                     ; for reading
        call  sys_open                  ; a0 = handle or -1
        bltz  a0, lu_none               ; not there
        mv    s1, a0                    ; ...
        li    s2, 0                     ; empty
        li    s3, 0                     ; offset 0
lu_read:
        mv    a0, s1                    ; read what fits
        li    a1, hring                 ; ...
        add   a1, a1, s2                ; after what is there
        li    a2, SYS_MAX               ; at most a message
        call  sys_read                  ; a0 = bytes, 0 at the end
        blez  a0, lu_end                ; the end
        add   s2, s2, a0                ; ...
        li    t0, HWSZ - SYS_MAX        ; room for another read?
        bltu  s2, t0, lu_read           ; yes
        srli  t1, s2, 3                 ; whole words go out
        slli  t1, t1, 3                 ; ...
        li    t0, hring                 ; ...
        tput  tg6, t0, c0, s3, t1       ; D-LS -> arena
        twait 0x40                      ; (the ring is reused at once)
        add   s3, s3, t1                ; ...
        sub   s2, s2, t1                ; the odd bytes move to the front
        li    t2, 0                     ; ...
lu_mv:
        bgeu  t2, s2, lu_read           ; done
        add   t3, t0, t1                ; ...
        add   t3, t3, t2                ; ...
        lbu   t4, 0(t3)                 ; ...
        add   t3, t0, t2                ; ...
        sb    t4, 0(t3)                 ; ...
        addi  t2, t2, 1                 ; ...
        j     lu_mv                     ; ...
lu_end:
        addi  t1, s2, 7                 ; the rest, rounded up to words
        srli  t1, t1, 3                 ; ...
        slli  t1, t1, 3                 ; ...
        beqz  t1, lu_close              ; nothing
        li    t0, hring                 ; ...
        tput  tg6, t0, c0, s3, t1       ; D-LS -> arena
        twait 0x40                      ; ...
lu_close:
        mv    a0, s1                    ; close it
        call  sys_close                 ; ...
        ld    s3, 24(sp)                ; ...
        ld    s2, 16(sp)                ; ...
        ld    s1, 8(sp)                 ; ...
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 40                ; ...
        ret                             ; done
lu_none:
        la    a0, m_noul                ; no units: nothing can run
        li    a1, m_noul_e - m_noul     ; ...
        call  err_str                   ; ...
        li    a0, 2                     ; ...
        call  sys_exit                  ; ...

        .include "core.s"               ; cells, windows, the far cache, unification
        .include "solve.s"              ; the solve loop

; =============================================================================
; The code units (the far section, /bin/stralog.u)
; =============================================================================
        .include "init.s"               ; start-up: atoms, builtins, boot.pl
        .include "term.s"               ; compiling terms into templates; findall; copy
        .include "db.s"                 ; predicates, clauses, assert, retract
        .include "read.s"               ; the reader
        .include "write.s"              ; the writer
        .include "arith.s"              ; arithmetic
        .include "bi.s"                 ; builtins
        .include "io.s"                 ; streams
        .include "bootpl.s"             ; boot.pl, as text (generated)

; The system interface last: its 18 KiB of D-LS buffers go above everything
; of ours, which stays below 0x8000 (one-instruction loads and stores).
        .include "../../os/lib/sys.s"   ; ...
