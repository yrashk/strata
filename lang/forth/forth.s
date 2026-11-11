; =============================================================================
; forth.s: Strata Forth, the kernel
; =============================================================================
;
; A Forth for a machine whose memory is explicit I/O. The kernel is small:
; the outer interpreter, a native-code compiler, the dictionary, number
; parsing, catch/throw, and the primitives. Everything else (control
; structures, strings, defining words, printing, the disassembler, the
; Strata words for tiers, capabilities and cores) is Forth, in core.fs,
; which is embedded in the image's far section and compiled at start-up.
;
; The design in one page (lang/forth/README.md has the long version)
;
;   * Native code, subroutine threaded. A colon definition is machine code:
;     a call (`jal`) per word, simple primitives copied inline, literals as
;     `addi`/`lui`/`ori`, a literal followed by + - and or xor shifts @ ! c@
;     c! folded into one instruction, and a call just before `;` turned into
;     a jump (tail call). Data stack: TOS in s1, the rest in memory at s0
;     (growing down). Return stack: the machine stack, sp. DO-loop index and
;     limit live in s2/s3, locals are addressed from s4.
;
;   * Code is installed, not stored. Stores cannot reach the instruction
;     Local Store. The compiler assembles a definition into a D-LS staging
;     buffer; `;` pads it to 8 bytes, `tput`s it to far memory and `tgetx`es
;     it from there into the I-LS. Far memory holds an identity mirror of
;     the I-LS (far offset == I-LS address in capability c0), so code can
;     always be read back (`code@`, `see`, inlining) and handed to other
;     cores. The kernel installs itself the same way: .text is only a boot
;     stub; the kernel proper is in .far and is `tgetx`ed at power-on.
;
;   * Other cores are workers. They receive the image (code mirror + a
;     snapshot of the data space) by being lent capability c0, and jobs
;     through a "board" in the cluster store that every core reaches with
;     far atomics; a copy of the board capability, given with `cgive`, is
;     the doorbell in both directions.
;
; Register conventions of all Forth code (compiled and kernel):
;   s0 data stack pointer (points at the second item)   s1 top of stack
;   sp return stack                                     s2/s3 DO index/limit
;   s4 locals frame                                     ra return address
;   t*, a*, s5..s11 scratch: any word may clobber them
;
; Capability registers (core 0): c0 the system far region (code mirror,
; core.fs text, D-LS snapshot), c1 the job board, c7 the kernel's scratch
; register (the image coming back, a doorbell). The rest are the platform's
; and the program's: see the platform file for what they hold. (c0..c7 are
; all a StrataOS process keeps across a context switch, hence these numbers.)
;
; Transfer tags used by the kernel: tg10 timer, tg11 source text, tg12 the
; far cache, tg13 code install and snapshots, tg14 console input, tg15
; console output. User transfers through capability cN use tag tgN.

        .include "config.s"             ; ORIGIN, PLAT_OS, PLAT_ECHO for this build

; ---- memory map ----------------------------------------------------------------
TRAMP     = ORIGIN + PLAT_STUB          ; I-LS: 8 one-instruction trampolines for `xexec`
NTRAMP    = 8                           ; how many
KSTART    = TRAMP + 0x40                ; I-LS: where the kernel proper is installed
CODE_LIMIT = 0x10000                    ; I-LS: compiled code may grow up to here
DS_TOP    = 0x9F00                      ; D-LS: data stack is empty when s0 = DS_TOP
DS_BOTTOM = 0x9800                      ; D-LS: lowest data stack cell (224 cells)
RS_TOP    = 0x10000                     ; D-LS: the return stack grows down from the top
SNAP_LEN  = DS_BOTTOM                   ; D-LS bytes a worker core receives as its image
STAGE_SZ  = 4096                        ; bytes of the code staging buffer (one definition)
SRCBUF_SZ = 264                         ; bytes of srcbuf, the line buffer for far text
EF_FRAME  = 64 + SRCBUF_SZ              ; EVALUATE-FAR's frame on the return stack

; ---- dictionary headers (in D-LS, 8-byte aligned) ------------------------------------
H_LINK    = 0                           ; u16: previous header (all words, newest first)
H_HASH    = 2                           ; u16: next header in the same hash bucket
H_XT      = 4                           ; u16: I-LS address of the code
H_SIZE    = 6                           ; u16: code bytes (inline body length for F_INL)
H_FLAGS   = 8                           ; u8: F_* flags
H_FOLD    = 9                           ; u8: FD_* literal folding kind, 0 = none
H_NLEN    = 10                          ; u8: name length
H_NAME    = 11                          ; the name; the data field follows, 8-aligned
NBUCKETS  = 64                          ; hash buckets (a power of two)
F_IMM     = 1                           ; immediate
F_INL     = 2                           ; compile by copying the body inline
F_HIDDEN  = 4                           ; not found (a definition in progress)
F_CREATE  = 8                           ; compiles as a literal: its data field address
F_CONST   = 16                          ; compiles as a literal: the cell in its data field
F_VALUE   = 32                          ; compiles as a load of its data field
F_PAGER   = 64                          ; may run paged code (EXECUTE, CATCH, ...: see "Code paging"); a
                                        ;   resident one's H_FOLD is its entry in the gateway unit
FD_ADD    = 1                           ; lit +      -> addi s1, s1, v
FD_SUB    = 2                           ; lit -      -> addi s1, s1, -v
FD_AND    = 3                           ; lit and    -> andi s1, s1, v
FD_OR     = 4                           ; lit or     -> ori  s1, s1, v
FD_XOR    = 5                           ; lit xor    -> xori s1, s1, v
FD_SHL    = 6                           ; lit lshift -> slli s1, s1, v
FD_SHR    = 7                           ; lit rshift -> srli s1, s1, v
FD_SAR    = 8                           ; lit arshift -> srai s1, s1, v
FD_LD     = 9                           ; lit @      -> ld  s1, v(zero)
FD_ST     = 10                          ; lit !      -> sd  s1, v(zero); drop
FD_LDB    = 11                          ; lit c@     -> lbu s1, v(zero)
FD_STB    = 12                          ; lit c!     -> sb  s1, v(zero); drop

; ---- the job board (cluster store, reached with far atomics through c1)  ---------
B_GEN     = 0                           ; generation of the published image
B_CEND    = 8                           ; I-LS end of the published code
B_SNAP    = 16                          ; bytes of the published D-LS snapshot
B_SLOTS   = 64                          ; per-core job slots start here
SLOT_SZ   = 128                         ; bytes per slot
S_CMD     = 0                           ; slot: command (CMD_RUN, CMD_HALT)
S_XT      = 8                           ; slot: the xt to run
S_NARGS   = 16                          ; slot: arguments passed
S_STATUS  = 24                          ; slot: the job's throw code (0 = ok)
S_NRES    = 32                          ; slot: results returned
S_ARGS    = 40                          ; slot: 8 cells, arguments in, results out
CMD_RUN   = 1                           ; run the xt
CMD_HALT  = 2                           ; stop the core
P_R       = 1                           ; capability permission bits (cperms low byte)
P_W       = 2                           ; write
P_X       = 4                           ; execute (tgetx)
P_A       = 8                           ; atomics
P_D       = 16                          ; duplicable

; ---- the software cache behind far@ / far! (ltag / linst) ---------------------------
FC_LSH    = 6                           ; 64-byte lines
FC_SLG    = 5                           ; 32 sets
FC_WAYS   = 2                           ; 2 ways
FC_SETS   = 1 << FC_SLG                 ; sets
FC_LINE   = 1 << FC_LSH                 ; bytes per line
FC_SPAN   = (FC_WAYS + 1) * 8           ; tag table bytes per set: a tag per way + the round-robin counter
FC_GEOM   = FC_LSH | FC_SLG << 6 | FC_WAYS << 12 ; the tgeom CSR value

; ---- instruction encodings the compiler emits (asm/isa.h) -----------------------------
; Values with opcode >= 0x20 are written as negative numbers so that `li` can
; build them in two instructions; only their low 32 bits are ever stored.
OP_ALU    = 0x00                        ; register-register ALU group
OP_ADDI   = 0x01                        ; opcodes (bits 31..26)
OP_ANDI   = 0x02                        ; and immediate (zero-extended)
OP_ORI    = 0x03                        ; or immediate
OP_XORI   = 0x04                        ; xor immediate
OP_SLLI   = 0x05                        ; shift left immediate
OP_SRLI   = 0x06                        ; logical shift right immediate
OP_SRAI   = 0x07                        ; arithmetic shift right immediate
OP_LUI    = 0x0A                        ; load upper immediate
OP_LD     = 0x10                        ; load doubleword
OP_LBU    = 0x16                        ; load byte unsigned
OP_SD     = 0x18                        ; store doubleword
OP_SB     = 0x1B                        ; store byte
OP_BEQ    = 0x20                        ; branch if equal
OP_JAL    = 0x28                        ; jump and link
OP_JALR   = 0x29                        ; jump and link through a register
OP_XCALL  = 0x3E                        ; xcall / xret (the overlay map)
OP_XMAP   = 0x3D                        ; xmap / xunmap
R_ZERO    = 0                           ; register numbers
R_RA      = 1                           ; return address
R_SP      = 2                           ; return stack
R_GP      = 3                           ; paged code: 0x10000, the base of its calls of resident code
R_TP      = 4                           ; paged code: TPV, the base of its calls of other units
R_T0      = 5                           ; scratch
R_S0      = 8                           ; data stack pointer
R_S1      = 9                           ; top of stack
R_S4      = 20                          ; locals frame
R_T5      = 30                          ; scratch (paged code: the far address of a call)
NEG32     = 0x100000000                 ; subtracted to make a 32-bit pattern negative
I_NOP     = OP_ADDI << 26               ; addi zero, zero, 0
I_PUSH1   = OP_ADDI << 26 | R_S0 << 21 | R_S0 << 16 | 0xFFF8 ; addi s0, s0, -8
I_PUSH2   = OP_SD << 26 | R_S1 << 21 | R_S0 << 16 ; sd s1, 0(s0)
I_POP1    = OP_LD << 26 | R_S1 << 21 | R_S0 << 16 ; ld s1, 0(s0)
I_POP2    = OP_ADDI << 26 | R_S0 << 21 | R_S0 << 16 | 8 ; addi s0, s0, 8
I_PRO1    = OP_ADDI << 26 | R_SP << 21 | R_SP << 16 | 0xFFF8 ; addi sp, sp, -8
I_PRO2    = OP_SD << 26 | R_RA << 21 | R_SP << 16 ; sd ra, 0(sp)
I_EPI1    = OP_LD << 26 | R_RA << 21 | R_SP << 16 ; ld ra, 0(sp)
I_EPI2    = OP_ADDI << 26 | R_SP << 21 | R_SP << 16 | 8 ; addi sp, sp, 8
I_PRET    = (OP_JALR << 26 | R_RA << 16) - NEG32 ; jalr zero, ra, 0 (ret)
I_XRET    = (OP_XCALL << 26 | R_RA << 16 | 16) - NEG32 ; xret ra (a far link too: see "Code paging")
I_RET     = I_PRET + PLAT_PAGE * (I_XRET - I_PRET) ; the return of a word (xret ra under StrataOS)
I_CALL    = (OP_JAL << 26 | R_RA << 21) - NEG32 ; jal ra, <offset>
I_JMP     = (OP_JAL << 26) - NEG32      ; jal zero, <offset>
I_JALT0   = (OP_JAL << 26 | R_T0 << 21) - NEG32 ; jal t0, <offset> (the compact prologue)
I_ORIT1Z  = OP_ORI << 26 | 6 << 21      ; ori t1, zero, <imm> (a D-LS address: compact stubs, string literals)
I_LIT2    = OP_ADDI << 26 | 7 << 21     ; addi t2, zero, <imm> (a string literal's length)
I_MVT0    = OP_ADDI << 26 | R_T0 << 21 | R_S1 << 16 ; addi t0, s1, 0
I_BEQZT0  = (OP_BEQ << 26 | R_T0 << 21) - NEG32 ; beq t0, zero, <offset>
I_LI_S1   = OP_ADDI << 26 | R_S1 << 21  ; addi s1, zero, <imm>
I_LUI_S1  = OP_LUI << 26 | R_S1 << 21   ; lui s1, <imm>
I_ORI_S1  = OP_ORI << 26 | R_S1 << 21 | R_S1 << 16 ; ori s1, s1, <imm>
I_SLL16   = OP_SLLI << 26 | R_S1 << 21 | R_S1 << 16 | 16 ; slli s1, s1, 16
I_LDLOC   = OP_LD << 26 | R_S1 << 21 | R_S4 << 16 ; ld s1, <8i>(s4)
I_LDS1    = OP_LD << 26 | R_S1 << 21 | R_S1 << 16 ; ld s1, 0(s1)
I_LUIT0   = OP_LUI << 26 | R_T0 << 21   ; lui t0, <imm>
I_ORIT0   = OP_ORI << 26 | R_T0 << 21 | R_T0 << 16 ; ori t0, t0, <imm>
I_LDS1T0  = OP_LD << 26 | R_S1 << 21 | R_T0 << 16 ; ld s1, 0(t0)
I_LT_MV   = OP_ADDI << 26 | R_T0 << 21 | R_S4 << 16 ; addi t0, s4, 0 (locals teardown 1)
I_LT_LD   = OP_LD << 26 | R_S4 << 21 | R_T0 << 16 ; ld s4, <8n>(t0) (locals teardown 2)
I_LT_SP   = OP_ADDI << 26 | R_SP << 21 | R_T0 << 16 ; addi sp, t0, <8n+8> (locals teardown 3)
I_FOLDI   = R_S1 << 21 | R_S1 << 16     ; rd = rs1 = s1, for the folded ALU forms
I_FOLDM   = R_S1 << 21                  ; rd = s1, base zero, for the folded memory forms
I_GCALL   = (OP_JALR << 26 | R_RA << 21 | R_GP << 16) - NEG32 ; jalr ra, gp, <a - 0x10000>: paged code calls resident a
I_GJUMP   = (OP_JALR << 26 | R_GP << 16) - NEG32 ; jalr zero, gp, <a - 0x10000>: ... jumps to it
I_GPRO    = (OP_JALR << 26 | R_T0 << 21 | R_GP << 16) - NEG32 ; jalr t0, gp, <k_enter - 0x10000>: the prologue
I_TPT5    = OP_ADDI << 26 | R_T5 << 21 | R_TP << 16 ; addi t5, tp, <a - TPV>: a unit's far address, near TPV
I_LUIT5   = OP_LUI << 26 | R_T5 << 21   ; lui t5, <a >> 16>: ... anywhere
I_ORIT5   = OP_ORI << 26 | R_T5 << 21 | R_T5 << 16 ; ori t5, t5, <a & 0xFFFF>
I_XCALL   = (OP_XCALL << 26 | R_RA << 21 | R_T5 << 16) - NEG32 ; xcall ra, c0, t5: call a unit
I_XJUMP   = (OP_XCALL << 26 | R_T5 << 16) - NEG32 ; xcall zero, c0, t5: jump into a unit
I_XUNMAP  = (OP_XMAP << 26 | 16) - NEG32 ; xunmap <idx << 21>
MAXFIX    = 16                          ; self-references a definition may hold (relocated at `;`)

; =============================================================================
; Data Local Store
; =============================================================================
        .data                           ; everything below goes to the D-LS of every core
        .align 8                        ; cells are 8-byte aligned
v_state:  .dword 0                      ; STATE: 0 interpreting, -1 compiling
v_base:   .dword 10                     ; BASE: the number base
v_here:   .dword dict0                  ; HERE: next free byte of data space
v_chere:  .dword 0                      ; next free I-LS address for code (set at start-up)
v_cbase:  .dword 0                      ; I-LS address of staging byte 0 (everything below is installed)
v_latest: .dword 0                      ; newest header
v_curxt:  .dword 0                      ; xt of the definition being compiled (for RECURSE)
v_curnt:  .dword 0                      ; its header (0 for :NONAME)
v_open:   .dword 0                      ; 1 while a definition is open
v_src:    .dword 0                      ; input buffer address
v_srclen: .dword 0                      ; input buffer length
v_in:     .dword 0                      ; >IN: parse offset in it
v_srcid:  .dword 0                      ; 0 console, -1 a string (EVALUATE), 1 far text
v_fpos:   .dword 0                      ; far text: c0 offset of the next line
v_fend:   .dword 0                      ; far text: c0 offset of its end
v_line:   .dword 0                      ; far text: current line number
v_handler: .dword 0                     ; the innermost CATCH frame (0 = none)
v_litend: .dword 0                      ; chere right after the last compiled 16-bit literal
v_litval: .dword 0                      ; that literal's value
v_callend: .dword 0                     ; chere right after the last compiled call
v_callxt: .dword 0                      ; that call's target
v_nloc:   .dword 0                      ; locals declared in the current definition
v_ename:  .dword 0                      ; the word being interpreted (for error messages)
v_elen:   .dword 0                      ; its length
v_obn:    .dword 0                      ; bytes waiting in the output buffer
v_col:    .dword 0                      ; output column (0 = at the start of a line)
v_echo:   .dword PLAT_ECHO              ; echo typed characters (raw console, or input that is not a console)
v_nlflush: .dword 1                     ; send output at every newline (0: only when the buffer is full)
v_exit:   .dword 0                      ; the exit code BYE hands to the platform
v_cmd:    .dword 0, 0                   ; text the platform wants interpreted instead of the console: address, length
v_fname:  .dword s_corefs               ; name (zero-terminated) of the far text being interpreted
v_efname: .dword s_corefs               ; that name when the last error was thrown
v_moff:   .dword 0                      ; I-LS address minus this = c0 offset of its mirror (per core)
v_ftop:   .dword A_FILES                ; INCLUDED: c0 offset where the next file's text goes (a stack)
v_fdepth: .dword 0                      ; INCLUDED: nesting depth
v_nofile: .dword 0                      ; INCLUDED: an xt ( a u -- ) for a name that is no file (KVAR 39; os.fs: the pack of ports)
v_tooling: .dword 0                     ; 1 while a tool file is loaded for one command
v_inlmax: .dword PLAT_INLINE            ; primitives whose bodies have at most this many bytes are copied inline
v_paged:  .dword 0                      ; KVAR 37, code paging: +0 1 once new code goes into units (StrataOS, one thread),
v_climit: .dword CODE_LIMIT             ;   +8 where code space ends (the I-LS's end, or the unit store's),
v_nxmap:  .dword 0                      ;   +16 the overlay map's entries (NXMAP), +24 the gateway's entries
v_ngw:    .dword 0                      ;   (resident words that may page, called from units through it)
v_noname: .dword 0                      ; paged: the :NONAME being compiled pushes its xt at `;`
v_callst: .dword 0                      ; chere where the last call began (with v_callend, v_callxt)
v_callkd: .dword 0                      ; its kind: 0 jal, 1 jalr gp (never a tail call), 2 xcall
v_nfix:   .dword 0                      ; self-references in the definition (relocated at `;`)
v_fix:    .space MAXFIX * 8             ; their staging offsets (each a lui, ori pair)
msave:    .space 24 + NBUCKETS * 2      ; the dictionary before a tool file: here, chere, latest, bucket heads
fnames:   .space 4 * 32                 ; names of the files being included, by depth (zero-terminated)
v_epoch:  .dword 1                      ; bumped for every word the interpreter runs
v_pubep:  .dword 0                      ; epoch of the last published image
v_gen:    .dword 0                      ; generation of the published image
v_lent:   .dword -1                     ; core that holds c0 now (-1: we do)
v_ncores: .dword 1                      ; cores this Forth may use (set by the platform)
v_heapc:  .dword 8                      ; capability register behind far@ / far! (set by the platform)
v_plat:   .dword PLAT_OS                ; 0 bare metal, 1 StrataOS
v_worker: .dword 0                      ; 1 on a worker core (running jobs)
v_jitn:   .dword 0                      ; code installs done
v_jitb:   .dword 0                      ; code bytes installed
v_jittr:  .dword 0                      ; nonzero: report every install
v_xinst:  .dword 0                      ; xexec trampoline installs
v_fstat:  .dword 0, 0, 0                ; far cache: hits, misses, write-backs
v_amsg:   .dword 0, 0                   ; ABORT" message: address, length
v_esrc:   .dword 0                      ; source id when the last error was thrown
v_eline:  .dword 0                      ; line number then
v_tcause: .dword 0                      ; last hardware fault: cause
v_tepc:   .dword 0                      ; its pc
v_ttval:  .dword 0                      ; its tval
v_kbuf:   .dword 0                      ; console input byte lands here
v_tsave:  .space 32                     ; trap_entry: registers a unit's miss (plat_miss) keeps
h_plain:  .space 16                     ; a header with no flags: cg_target of a kernel helper
v_tbuf:   .dword 0                      ; a trampoline being installed: insn, ret
v_tick:   .dword 0                      ; timer reads land here
v_wgen:   .space 16 * 8                 ; per worker: image generation it holds
v_busy:   .space 16 * 8                 ; per worker: 1 while running a job
v_ttags:  .space NTRAMP * 8             ; per trampoline: the instruction in it
v_lsaved: .space 8 * 8                  ; LEAVE bookkeeping space for core.fs (unused by the kernel)
v_bucket: .space NBUCKETS * 2           ; hash bucket heads (u16 header addresses)
        .align 8                        ; buffers
tib:      .space 256                    ; terminal input buffer
obuf:     .space 256                    ; console output buffer
inlbuf:   .space 256                    ; a primitive's body, fetched for inlining
srcbuf:   .space SRCBUF_SZ              ; a chunk of far source text
numbuf:   .space 72                     ; number formatting, right to left
numend:                                 ; one past numbuf
locnames: .space 16 * 16                ; local names: length byte + 15 characters each
        .align 64                       ; cache lines must be line-aligned
fc_lines: .space FC_SETS * FC_WAYS * FC_LINE ; far cache: line storage
fc_tags:  .space FC_SETS * FC_SPAN      ; far cache: tag table (ltag/linst format)
fc_dirty: .space FC_SETS * FC_WAYS      ; far cache: a dirty byte per line
        .align 8                        ; the staging buffer holds instructions
stage:    .space STAGE_SZ               ; code being compiled, before it is installed
; ---- messages ------------------------------------------------------------------
s_ok:     .asciz " ok"                  ; after a line was interpreted
s_compiled: .asciz " compiled"          ; after a line inside a definition
s_core:   .asciz "core "                ; worker error prefix
s_colon:  .asciz ": "                   ; separator
s_corefs: .asciz "core.fs"              ; error inside the embedded core.fs
s_stars:  .asciz "*** "                 ; error marker
s_fault:  .asciz "fault "               ; hardware fault
s_atpc:   .asciz " at pc "              ; ...
s_tval:   .asciz ", tval "              ; ...
s_error:  .asciz "error "               ; unknown throw code
s_jit:    .asciz "[jit: tput+tgetx "    ; install report
s_jit2:   .asciz " bytes -> I-LS "      ; ...
s_causes: .asciz "none"                 ; trap cause names, in cause order (common/stx.h)
          .asciz "illegal"              ; 1
          .asciz "lsfault"              ; 2
          .asciz "capinv"               ; 3
          .asciz "perm"                 ; 4
          .asciz "bounds"               ; 5
          .asciz "xalign"               ; 6
          .asciz "ifault"               ; 7
          .asciz "xmiss"                ; 8
          .asciz "pend"                 ; 9
          .asciz "capop"                ; 10
          .asciz "priv"                 ; 11
          .asciz "halt"                 ; 12
          .asciz "stop"                 ; 13
          .asciz "svc"                  ; 14
          .asciz "?"                    ; beyond
          .asciz "?"                    ; ...
errtab:                                 ; u16 -code, message
          .half 3                       ; -3
          .asciz "stack overflow"       ; ...
          .half 4                       ; -4
          .asciz "stack underflow"      ; ...
          .half 8                       ; -8
          .asciz "dictionary overflow"  ; ...
          .half 9                       ; -9
          .asciz "invalid memory address" ; ...
          .half 13                      ; -13
          .asciz "undefined word"       ; ...
          .half 14                      ; -14
          .asciz "interpreting a compile-only word" ; ...
          .half 16                      ; -16
          .asciz "missing name"         ; ...
          .half 18                      ; -18
          .asciz "line too long"        ; ...
          .half 19                      ; -19
          .asciz "name too long"        ; ...
          .half 21                      ; -21
          .asciz "unsupported operation" ; ...
          .half 22                      ; -22
          .asciz "control structure mismatch" ; ...
          .half 24                      ; -24
          .asciz "invalid numeric argument" ; ...
          .half 300                     ; -300
          .asciz "code space (I-LS) full" ; ...
          .half 301                     ; -301
          .asciz "definition too long (staging buffer)" ; ...
          .half 302                     ; -302
          .asciz "core busy (await it first)" ; ...
          .half 303                     ; -303
          .asciz "core is not running a job" ; ...
          .half 304                     ; -304
          .asciz "unexpected capability received (dropped)" ; ...
          .half 305                     ; -305
          .asciz "no such worker core"  ; ...
          .half 306                     ; -306
          .asciz "not available on this platform" ; ...
          .half 307                     ; -307
          .asciz "too many locals"      ; ...
          .half 308                     ; -308
          .asciz "one thread only: start Forth with -n N for N cores" ; ...
          .half 309                     ; -309
          .asciz "no such file"         ; ...
          .half 310                     ; -310
          .asciz "file too large"       ; ...
          .half 311                     ; -311
          .asciz "definition longer than a code unit" ; ...
          .half 0                       ; end
          .align 2                      ; u16 entries follow
kvars:                                  ; KVAR n -> address (for core.fs)
          .half v_state                 ; 0 STATE
          .half v_base                  ; 1 BASE
          .half v_in                    ; 2 >IN
          .half v_amsg                  ; 3 ABORT" message (addr, len)
          .half v_jitn                  ; 4 code installs, bytes, trace flag
          .half v_fstat                 ; 5 far cache hits, misses, write-backs
          .half v_xinst                 ; 6 xexec trampoline installs
          .half v_srcid                 ; 7 SOURCE-ID
          .half v_ncores                ; 8 cores usable
          .half v_tcause                ; 9 last fault: cause, epc, tval
          .half v_gen                   ; 10 image generation
          .half v_lent                  ; 11 core holding c0 (-1 = us)
          .half v_echo                  ; 12 echo typed input
          .half v_here                  ; 13 HERE's variable
          .half v_chere                 ; 14 code HERE's variable
          .half v_epoch                 ; 15 words run (publish epoch)
          .half stage                   ; 16 the staging buffer
          .half v_cbase                 ; 17 staging base
          .half v_nloc                  ; 18 locals count
          .half v_curxt                 ; 19 xt being compiled
          .half v_busy                  ; 20 worker busy flags
          .half v_heapc                 ; 21 heap capability register number
          .half kend                    ; 22 (a value) end of the kernel in the I-LS
          .half v_plat                  ; 23 platform: 0 bare metal, 1 StrataOS
          .half v_jittr                 ; 24 report code installs
          .half v_latest                ; 25 LATEST's variable
          .half v_col                   ; 26 output column
          .half v_worker                ; 27 1 on a worker core
          .half v_bucket                ; 28 the hash bucket heads (NBUCKETS u16)
          .half v_fname                 ; 29 name of the far text being interpreted (zero-terminated)
          .half v_exit                  ; 30 the exit code of BYE
          .half v_nlflush               ; 31 flush output at every newline
          .half v_cmd                   ; 32 the platform's command line (addr, len; len 0 = the console)
          .half v_ename                 ; 33 the word an error message names (addr, len)
          .half v_tooling               ; 34 nonzero while a tool file is loaded for one command
          .half msave                   ; 35 the dictionary before that file: here, chere, latest
          .half v_inlmax                ; 36 inline bodies of up to this many bytes (INLINE-LIMIT)
          .half v_paged                 ; 37 code paging: on, the code limit, NXMAP, gateway entries
          .half plat_handles            ; 38 standard handles 0..2: the server's endpoint register (3 cells), its id (3)
          .half v_nofile                ; 39 INCLUDED: the xt ( a u -- ) run for a name that is no file (0: "no such file")
          .half v_ftop                  ; 40 INCLUDED: c0 offset where the next file's text goes (sys.fs puts a pack member there)
          .half plat_lkname             ; 41 the name (8 bytes, zero-padded) of the server (msg) register 6 asks proc for: "net"
        .align 8                        ; the dictionary starts here
dict0:                                  ; first header


; =============================================================================
; .text: the boot stub, the worker loop, the xexec trampolines (per platform)
; =============================================================================
; Bare metal: lang/forth/bare/boot.s (every core starts there; core 0 installs
; the kernel from far memory, the others wait for jobs). StrataOS:
; lang/forth/os/boot.s (the program's entry; thread 0 declares the code mirror
; and installs the kernel, other threads wait for their page).
        .include "boot.s"               ; the platform's .text

; =============================================================================
; .far: the kernel proper
; =============================================================================
; Assembled into system memory at offsets equal to the I-LS addresses it runs
; at (the .org below), so the far image *is* the I-LS mirror. The boot stub
; copies [KSTART, kend) into the I-LS; compiled code continues after kend.
;
; Internal routines (not Forth words) take arguments in a0.., return in a0,
; may clobber t0..t6 and a0..a7, and keep s0..s11 intact. The ones that call
; others save ra on the return stack. Forth words (labels p_*) follow the
; Forth register conventions in the file header.
        .far                            ; system memory
        .org  KSTART                    ; far offset == I-LS address

; -----------------------------------------------------------------------------
; cold: core 0 starts here
; -----------------------------------------------------------------------------
cold:                                   ; entered from the boot stub
        li    sp, RS_TOP                ; return stack at the top of D-LS
        li    s0, DS_TOP                ; empty data stack
        li    s1, 0                     ; a tidy top-of-stack register
        li    gp, 0x10000               ; the bases of paged code's calls: resident code
        li    tp, TPV                   ;   below gp, units around tp ("Code paging")
        la    t0, trap_entry            ; t0 = our trap handler
        csrw  tvec, t0                  ; faults become THROWs (see trap_entry)
        call  plat_init                 ; the platform: capabilities, other cores, v_ncores
        call  core_reset                ; per-core state: trampolines, far cache
        la    t0, kpage                 ; compiled code starts at kpage (over the code only paging and start-up run: see there)
        sd    t0, v_chere(zero)         ; next free I-LS address
        sd    t0, v_cbase(zero)         ; nothing staged yet
        call  build_dict                ; headers for every kernel word
        call  p_paging                  ; StrataOS, one thread: core.fs on goes into units
        call  plat_source               ; a0 = c0 offset of core.fs, a1 = its length
        mv    t1, a0                    ; t1 = offset
        mv    t0, a1                    ; t0 = length
        addi  s0, s0, -8                ; push the c0 offset
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t1                    ; t1 is the new top
        addi  s0, s0, -8                ; push the length
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
        addi  s0, s0, -8                ; push the xt of evaluate-far
        sd    s1, 0(s0)                 ; the old top goes to memory
        la    s1, p_evalfar             ; s1 = address of p_evalfar
        call  p_catch                   ; compile core.fs, catching any error
        mv    a0, s1                    ; a0 = the throw code (0 = loaded)
        beqz  a0, cold_ok               ; loaded
        call  report_error              ; say what went wrong (file and line)
        call  rollback                  ; drop a half-compiled definition
cold_ok:                                ; core.fs printed the banner if it loaded
        li    s0, DS_TOP                ; start with an empty stack
        ld    a0, v_cmd(zero)           ; a command line from the platform, to interpret
        ld    a1, v_cmd+8(zero)         ; instead of the console (length 0: none)
        beqz  a1, quit                  ; none: the interpreter loop
        addi  s0, s0, -8                ; push the address
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, a0                    ; a0 is the new top
        addi  s0, s0, -8                ; push the length
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, a1                    ; a1 is the new top
        addi  s0, s0, -8                ; push the xt of EVALUATE
        sd    s1, 0(s0)                 ; the old top goes to memory
        la    s1, p_evaluate            ; s1 = address of p_evaluate
        call  p_catch                   ; interpret it, catching any error
        mv    a0, s1                    ; a0 = the throw code
        beqz  a0, cold_end              ; it ran to its end
        call  report_error              ; say what went wrong
        li    t0, 1                     ; and leave with exit code 1
        sd    t0, v_exit(zero)          ; ...
cold_end:                               ; a command line never falls into the console loop
        ld    t0, v_col(zero)           ; end the last line of output
        beqz  t0, p_bye                 ; (nothing on it)
        call  out_cr                    ; a newline
        j     p_bye                     ; flush, stop the workers, leave

; -----------------------------------------------------------------------------
; core_reset: state that belongs to this core, never to a snapshot
; -----------------------------------------------------------------------------
core_reset:                             ; leaf
        la    t0, v_ttags               ; t0 = trampoline tags
        li    t1, NTRAMP                ; t1 = how many
        li    t2, -1                    ; an impossible instruction: "slot empty"
cr_tt:                                  ; loop over the tags
        sd    t2, 0(t0)                 ; mark the slot empty
        addi  t0, t0, 8                 ; next tag
        addi  t1, t1, -1                ; one fewer
        bnez  t1, cr_tt                 ; until all are done
        la    t0, fc_tags               ; the far cache's tag table
        csrw  ttag, t0                  ; tells ltag/linst where it is
        la    t0, fc_lines              ; the line storage
        csrw  tdata, t0                 ; tells ltag where lines live
        li    t0, FC_GEOM               ; line size, sets, ways
        csrw  tgeom, t0                 ; the cache geometry
        la    t0, fc_tags               ; clear the tag table (0 = no line)
        li    t1, FC_SETS * FC_SPAN + FC_SETS * FC_WAYS ; tags and the dirty bytes after them
cr_fc:                                  ; loop: clear 8 bytes
        sd    zero, 0(t0)               ; clear
        addi  t0, t0, 8                 ; next
        addi  t1, t1, -8                ; 8 fewer
        bgtz  t1, cr_fc                 ; until done
        sd    zero, v_obn(zero)         ; nothing buffered for output
        sd    zero, v_col(zero)         ; at the start of a line
        sd    zero, v_handler(zero)     ; no CATCH frame
        sd    zero, v_open(zero)        ; no definition open
        sd    zero, v_state(zero)       ; interpreting
        sd    zero, v_nloc(zero)        ; no locals
        li    t0, -1                    ; -1: we hold c0 ourselves
        sd    t0, v_lent(zero)          ; nothing lent
        ret                             ; done

; -----------------------------------------------------------------------------
; Console output: a line buffer, flushed at newline, when full and before input
; out_char(a0) / out_flush clobber t0..t2, a0, a1 only.
; -----------------------------------------------------------------------------
out_char:                               ; leaf except for the flush tail call
        ld    t0, v_obn(zero)           ; t0 = bytes buffered
        la    t1, obuf                  ; t1 = the buffer
        add   t1, t1, t0                ; t1 = next free byte
        sb    a0, 0(t1)                 ; store (waits if the last flush still reads it)
        addi  t0, t0, 1                 ; one more byte
        sd    t0, v_obn(zero)           ; remember
        ld    t2, v_col(zero)           ; t2 = column
        addi  t2, t2, 1                 ; advance
        sd    t2, v_col(zero)           ; remember
        li    t1, 10                    ; newline?
        beq   a0, t1, oc_nl             ; yes: new line, flush
        li    t1, 256                   ; buffer size
        bgeu  t0, t1, out_flush         ; full: flush
        ret                             ; otherwise keep buffering
oc_nl:                                  ; end of a line
        sd    zero, v_col(zero)         ; column 0
        ld    t1, v_nlflush(zero)       ; send every line at once?
        bnez  t1, out_flush             ; yes (a console)
        li    t1, 256 - 8               ; no: only when the buffer is nearly full
        bgeu  t0, t1, out_flush         ; ...
        ret                             ; keep buffering
out_flush:                              ; send whatever is buffered
        ld    a1, v_obn(zero)           ; a1 = bytes buffered
        beqz  a1, of_none               ; nothing to send
        sd    zero, v_obn(zero)         ; the buffer is empty again (refilling it waits on the transfer)
        la    a0, obuf                  ; a0 = the bytes
        j     plat_write                ; tail call: the platform sends them
of_none:                                ; nothing buffered
        ret                             ; done

out_cr:                                 ; print a newline
        li    a0, 10                    ; '\n'
        j     out_char                  ; tail call
out_space:                              ; print a space
        li    a0, 32                    ; ' '
        j     out_char                  ; tail call

; out_type(a0 = address, a1 = length); clobbers t0..t5, a0, a1
out_type:                               ; print a string
        mv    t5, ra                    ; out_char does not touch t5
        mv    t3, a0                    ; t3 = cursor
        add   t4, a0, a1                ; t4 = end
ot_loop:                                ; one byte per iteration
        bgeu  t3, t4, ot_done           ; until the end
        lbu   a0, 0(t3)                 ; a0 = the byte
        call  out_char                  ; print it
        addi  t3, t3, 1                 ; next
        j     ot_loop                   ; continue
ot_done:                                ; finished
        jr    t5                        ; return

; out_str(a0 = zero-terminated string); clobbers t0..t5, a0, a1
out_str:                                ; print a C string
        mv    t5, ra                    ; out_char does not touch t5
        mv    t3, a0                    ; t3 = cursor
os_loop:                                ; one byte per iteration
        lbu   a0, 0(t3)                 ; a0 = the byte
        beqz  a0, os_done               ; zero ends it
        call  out_char                  ; print it
        addi  t3, t3, 1                 ; next
        j     os_loop                   ; continue
os_done:                                ; finished
        jr    t5                        ; return

; fmt_num(a0 = value, a1 = base, a2 = 1 if signed) -> a0 = text, a1 = length
fmt_num:                                ; leaf
        la    t0, numend                ; t0 = write cursor (right to left)
        li    t3, 0                     ; t3 = 1 if negative
        beqz  a2, fn_loop               ; unsigned: digits as is
        bgez  a0, fn_loop               ; non-negative: digits as is
        li    t3, 1                     ; remember the sign
        sub   a0, zero, a0              ; and use the magnitude
fn_loop:                                ; one digit per iteration
        remu  t1, a0, a1                ; t1 = lowest digit
        divu  a0, a0, a1                ; drop it
        li    t2, 10                    ; letters start at digit 10
        blt   t1, t2, fn_dig            ; 0..9
        addi  t1, t1, 'a' - 10 - '0'    ; 10.. become a..
fn_dig:                                 ; t1 = digit value, adjusted
        addi  t1, t1, '0'               ; to ASCII
        addi  t0, t0, -1                ; cursor left
        sb    t1, 0(t0)                 ; store
        bnez  a0, fn_loop               ; more digits
        beqz  t3, fn_done               ; positive: done
        li    t1, '-'                   ; the sign
        addi  t0, t0, -1                ; cursor left
        sb    t1, 0(t0)                 ; store it
fn_done:                                ; t0 = first character
        mv    a0, t0                    ; a0 = text
        la    t1, numend                ; t1 = end
        sub   a1, t1, t0                ; a1 = length
        ret                             ; done

; print_dec(a0): signed decimal; clobbers t0..t5, a0..a2
print_dec:                              ; print a signed decimal number
        li    a1, 10                    ; base 10
        li    a2, 1                     ; signed
        mv    t6, ra                    ; fmt_num and out_type leave t6 alone
        call  fmt_num                   ; to text
        mv    ra, t6                    ; our return address
        j     out_type                  ; tail call: print it

; print_hex(a0): "0x" and hex digits; clobbers t0..t6, a0..a2
print_hex:                              ; print an unsigned hex number
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; save the value
        li    a0, '0'                   ; "0"
        call  out_char                  ; print
        li    a0, 'x'                   ; "x"
        call  out_char                  ; print
        ld    a0, 8(sp)                 ; the value
        li    a1, 16                    ; base 16
        li    a2, 0                     ; unsigned
        call  fmt_num                   ; to text
        call  out_type                  ; print it
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop the frame
        ret                             ; done

; -----------------------------------------------------------------------------
; Console input
; -----------------------------------------------------------------------------
; key_in -> a0: flush pending output (so prompts show), then read one byte
key_in:                                 ; clobbers t0..t2, a0, a1
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  out_flush                 ; show everything printed so far
        call  plat_key                  ; a0 = the next byte (0x04 at end of input)
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; accept_line(a0 = buffer, a1 = capacity) -> a0 = length, or -1 at end of input.
; Echoes when the console is raw (PLAT_ECHO); Enter shows as a space.
accept_line:                            ; clobbers t0..t5, a0..a4
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    a2, a0                    ; a2 = buffer
        mv    a3, a1                    ; a3 = capacity
        li    a4, 0                     ; a4 = length so far
al_loop:                                ; one key per iteration
        call  key_in                    ; a0 = key
        li    t0, 10                    ; newline
        beq   a0, t0, al_done           ; ends the line
        li    t0, 13                    ; carriage return
        beq   a0, t0, al_done           ; ends it too
        li    t0, 4                     ; end of input (Ctrl-D, or the end of a -i file)
        beq   a0, t0, al_eof            ; handled below
        li    t0, 8                     ; backspace
        beq   a0, t0, al_bs             ; delete a character
        li    t0, 127                   ; delete key
        beq   a0, t0, al_bs             ; same
        li    t0, 9                     ; tab
        bne   a0, t0, al_ctl            ; not a tab
        li    a0, 32                    ; a tab is a space
al_ctl:                                 ; a0 = character
        li    t0, 32                    ; other control characters
        blt   a0, t0, al_loop           ; are ignored
        bgeu  a4, a3, al_loop           ; the buffer is full: ignore
        add   t0, a2, a4                ; t0 = where it goes
        sb    a0, 0(t0)                 ; store it
        addi  a4, a4, 1                 ; one more
        ld    t0, v_echo(zero)          ; echo?
        beqz  t0, al_loop               ; no
        call  out_char                  ; show it
        j     al_loop                   ; next key
al_bs:                                  ; rub out the last character
        beqz  a4, al_loop               ; nothing to rub out
        addi  a4, a4, -1                ; one fewer
        ld    t0, v_echo(zero)          ; echo?
        beqz  t0, al_loop               ; no
        li    a0, 8                     ; back
        call  out_char                  ; call out_char
        li    a0, 32                    ; blank
        call  out_char                  ; call out_char
        li    a0, 8                     ; back again
        call  out_char                  ; call out_char
        j     al_loop                   ; next key
al_eof:                                 ; end of input
        bnez  a4, al_done               ; a last line without a newline still counts
        li    a0, -1                    ; nothing: report the end
        j     al_ret                    ; return
al_done:                                ; the line is complete
        ld    t0, v_echo(zero)          ; echo?
        beqz  t0, al_len                ; no
        call  out_space                 ; Enter shows as a space, output follows on this line
al_len:                                 ; return the length
        mv    a0, a4                    ; a0 = length
al_ret:                                 ; common exit
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; -----------------------------------------------------------------------------
; Parsing the input buffer (v_src, v_srclen, >IN)
; -----------------------------------------------------------------------------
; parse_name -> a0 = address, a1 = length (0 at the end of the buffer)
parse_name:                             ; leaf; clobbers t0..t6
        ld    t0, v_src(zero)           ; t0 = buffer
        ld    t1, v_srclen(zero)        ; t1 = its length
        ld    t2, v_in(zero)            ; t2 = >IN
        li    t5, 32                    ; anything <= space is a delimiter
pn_skip:                                ; skip leading delimiters
        bgeu  t2, t1, pn_empty          ; ran out: no name
        add   t3, t0, t2                ; t3 = address of the character
        lbu   t4, 0(t3)                 ; t4 = the character
        bgtu  t4, t5, pn_start          ; a name starts here
        addi  t2, t2, 1                 ; skip it
        j     pn_skip                   ; continue
pn_start:                               ; t2 = start of the name
        mv    t6, t2                    ; t6 = start
pn_scan:                                ; find its end
        bgeu  t2, t1, pn_end            ; end of buffer ends it
        add   t3, t0, t2                ; address
        lbu   t4, 0(t3)                 ; character
        bleu  t4, t5, pn_end            ; a delimiter ends it
        addi  t2, t2, 1                 ; next
        j     pn_scan                   ; continue
pn_end:                                 ; t2 = one past the name
        add   a0, t0, t6                ; a0 = address of the name
        sub   a1, t2, t6                ; a1 = its length
        bgeu  t2, t1, pn_set            ; at the end: nothing to skip
        addi  t2, t2, 1                 ; skip the delimiter
pn_set:                                 ; store >IN
        sd    t2, v_in(zero)            ; >IN
        ret                             ; done
pn_empty:                               ; no name left
        sd    t2, v_in(zero)            ; >IN at the end
        add   a0, t0, t2                ; an address at the end
        li    a1, 0                     ; length 0
        ret                             ; done

; parse_char(a0 = delimiter) -> a0 = address, a1 = length, up to the delimiter
parse_char:                             ; leaf; clobbers t0..t4
        ld    t0, v_src(zero)           ; buffer
        ld    t1, v_srclen(zero)        ; length
        ld    t2, v_in(zero)            ; >IN
        mv    t3, t2                    ; t3 = start
pc_scan:                                ; look for the delimiter
        bgeu  t2, t1, pc_end            ; end of buffer
        add   t4, t0, t2                ; address
        lbu   t4, 0(t4)                 ; character
        beq   t4, a0, pc_end            ; found it
        addi  t2, t2, 1                 ; next
        j     pc_scan                   ; continue
pc_end:                                 ; t2 = delimiter position (or the end)
        add   a0, t0, t3                ; a0 = start
        sub   a1, t2, t3                ; a1 = length
        bgeu  t2, t1, pc_set            ; at the end
        addi  t2, t2, 1                 ; step over the delimiter
pc_set:                                 ; store >IN
        sd    t2, v_in(zero)            ; >IN
        ret                             ; done

; -----------------------------------------------------------------------------
; The dictionary: headers in D-LS, in NBUCKETS hash chains, names case-blind
; -----------------------------------------------------------------------------
; hash_name(a0 = name, a1 = length) -> a0 = address of the bucket head
hash_name:                              ; leaf; clobbers t0..t3
        mv    t0, a1                    ; h = length
        li    t1, 0                     ; i = 0
hn_loop:                                ; one character per iteration
        bgeu  t1, a1, hn_done           ; all done
        add   t2, a0, t1                ; address of character i
        lbu   t2, 0(t2)                 ; the character
        addi  t3, t2, -'A'              ; lower case without a branch:
        sltiu t3, t3, 26                ;   t3 = 1 for A..Z
        slli  t3, t3, 5                 ;   32 or 0
        add   t2, t2, t3                ;   added
        slli  t3, t0, 5                 ; h * 32
        add   t0, t0, t3                ; h * 33
        xor   t0, t0, t2                ; ^ c
        addi  t1, t1, 1                 ; next
        j     hn_loop                   ; continue
hn_done:                                ; t0 = hash
        andi  t0, t0, NBUCKETS - 1      ; the bucket number
        slli  t0, t0, 1                 ; 2 bytes per head
        la    t1, v_bucket              ; the bucket array
        add   a0, t1, t0                ; a0 = address of the head
        ret                             ; done

; find_name(a0 = name, a1 = length) -> a0 = header, or 0
find_name:                              ; clobbers t0..t4, a0..a4
        mv    a2, a0                    ; a2 = name
        mv    a3, a1                    ; a3 = length
        mv    a4, ra                    ; hash_name leaves a4 alone
        call  hash_name                 ; a0 = bucket head address
        lhu   t0, 0(a0)                 ; t0 = first header in the bucket
fd_loop:                                ; walk the chain
        beqz  t0, fd_none               ; end of chain: not found
        lbu   t1, H_FLAGS(t0)           ; flags
        andi  t1, t1, F_HIDDEN          ; hidden?
        bnez  t1, fd_next               ; skip it
        lbu   t1, H_NLEN(t0)            ; name length
        bne   t1, a3, fd_next           ; must match
        li    t1, 0                     ; i = 0
fd_cmp:                                 ; compare the names, case-blind
        bgeu  t1, a3, fd_hit            ; every character matched
        add   t2, a2, t1                ; our character i
        lbu   t2, 0(t2)                 ; ...
        addi  t3, t2, -'A'              ; to lower case
        sltiu t3, t3, 26                ; ...
        slli  t3, t3, 5                 ; ...
        add   t2, t2, t3                ; ...
        add   t4, t0, t1                ; the header's character i
        lbu   t4, H_NAME(t4)            ; ...
        addi  t3, t4, -'A'              ; to lower case
        sltiu t3, t3, 26                ; ...
        slli  t3, t3, 5                 ; ...
        add   t4, t4, t3                ; ...
        bne   t2, t4, fd_next           ; differ: next header
        addi  t1, t1, 1                 ; next character
        j     fd_cmp                    ; continue
fd_hit:                                 ; found
        mv    a0, t0                    ; a0 = header
        jr    a4                        ; return
fd_next:                                ; try the next header in the bucket
        lhu   t0, H_HASH(t0)            ; follow the chain
        j     fd_loop                   ; continue
fd_none:                                ; not found
        li    a0, 0                     ; 0
        jr    a4                        ; return

; make_header(a0 = name, a1 = length) -> a0 = new header, linked and visible,
; xt = the current code address; HERE moves past it (8-aligned)
make_header:                            ; clobbers t0..t3, a0..a5
        beqz  a1, mh_empty              ; a name is required
        li    t0, 31                    ; at most 31 characters
        bgtu  a1, t0, mh_long           ; too long
        mv    a2, a0                    ; a2 = name
        mv    a3, a1                    ; a3 = length
        mv    a4, ra                    ; hash_name leaves a4 alone
        ld    a5, v_here(zero)          ; a5 = HERE
        addi  a5, a5, 7                 ; round up
        srli  a5, a5, 3                 ; to a multiple
        slli  a5, a5, 3                 ; of 8: the header address
        li    t0, DS_BOTTOM - 64        ; leave room for the name and a cell or two
        bgeu  a5, t0, mh_full           ; the dictionary is full
        call  hash_name                 ; a0 = bucket head address
        lhu   t1, 0(a0)                 ; t1 = old head
        sh    t1, H_HASH(a5)            ; chain behind us
        sh    a5, 0(a0)                 ; we are the new head
        ld    t1, v_latest(zero)        ; t1 = previous newest word
        sh    t1, H_LINK(a5)            ; link to it
        sd    a5, v_latest(zero)        ; we are the newest
        ld    a0, v_chere(zero)         ; our xt: the next code address (callers may change it)
        call  xt_enc                    ; (a unit's code: encoded, see hxt)
        sh    a0, H_XT(a5)              ; ...
        sh    zero, H_SIZE(a5)          ; no code yet
        sb    zero, H_FLAGS(a5)         ; no flags
        sb    zero, H_FOLD(a5)          ; no folding
        sb    a3, H_NLEN(a5)            ; the name length
        li    t1, 0                     ; i = 0
mh_copy:                                ; copy the name
        bgeu  t1, a3, mh_end            ; done
        add   t2, a2, t1                ; source character
        lbu   t3, 0(t2)                 ; ...
        add   t2, a5, t1                ; destination
        sb    t3, H_NAME(t2)            ; ...
        addi  t1, t1, 1                 ; next
        j     mh_copy                   ; continue
mh_end:                                 ; HERE moves past the header
        addi  t1, a5, H_NAME + 7        ; name start + 7
        add   t1, t1, a3                ; + length
        srli  t1, t1, 3                 ; round down to 8
        slli  t1, t1, 3                 ; = aligned end
        sd    t1, v_here(zero)          ; HERE = the data field
        mv    a0, a5                    ; a0 = header
        jr    a4                        ; return
mh_empty:                               ; zero-length name
        li    a0, -16                   ; attempt to use a zero-length string as a name
        j     throw_a0                  ; error
mh_long:                                ; name too long
        li    a0, -19                   ; definition name too long
        j     throw_a0                  ; error
mh_full:                                ; dictionary full
        li    a0, -8                    ; dictionary overflow
        j     throw_a0                  ; error

; nt_dfa(a0 = header) -> a0 = its data field address
nt_dfa:                                 ; leaf; clobbers t0
        lbu   t0, H_NLEN(a0)            ; name length
        add   a0, a0, t0                ; skip it
        addi  a0, a0, H_NAME + 7        ; and the fixed part, rounding up
        srli  a0, a0, 3                 ; to a multiple
        slli  a0, a0, 3                 ; of 8
        ret                             ; done

; hxt(a0 = header) -> a0 = its xt. Resident code is at its I-LS address (under
; StrataOS 0x8000..0xFFFF); code in a unit (see "Code paging") is at a far
; offset in c0, UBASE and up, which H_XT holds as (xt - UBASE) / 8: below 0x8000.
hxt:                                    ; leaf; clobbers t0
        lhu   a0, H_XT(a0)              ; ...
xt_dec:                                 ; (a0 = an H_XT value)
        li    t0, PLAT_PAGE * 0x8000    ; (0 on bare metal: nothing is paged there)
        bgeu  a0, t0, hx_r              ; resident
        slli  a0, a0, 3                 ; a unit's
        li    t0, UBASE                 ; ...
        add   a0, a0, t0                ; ...
hx_r:                                   ; ...
        ret                             ; done
; xt_enc(a0 = xt) -> a0 = what H_XT holds for it
xt_enc:                                 ; leaf; clobbers t0
        srli  t0, a0, 16                ; resident (below 64 KiB): itself
        beqz  t0, xe_r                  ; ...
        li    t0, UBASE                 ; a unit's
        sub   a0, a0, t0                ; ...
        srli  a0, a0, 3                 ; ...
xe_r:                                   ; ...
        ret                             ; done
; xt_name(a0 = xt) -> a0 = the header with that xt, or 0
xt_name:                                ; leaf; clobbers t0..t2
        ld    t0, v_latest(zero)        ; walk every word, newest first
xn_loop:                                ; ...
        beqz  t0, xn_none               ; not found
        lhu   t1, H_XT(t0)              ; its xt
        li    t2, PLAT_PAGE * 0x8000    ; (decoded as hxt does)
        bgeu  t1, t2, xn_cmp            ; ...
        slli  t1, t1, 3                 ; ...
        li    t2, UBASE                 ; ...
        add   t1, t1, t2                ; ...
xn_cmp:                                 ; ...
        beq   t1, a0, xn_hit            ; this one
        lhu   t0, H_LINK(t0)            ; older
        j     xn_loop                   ; on to xn_loop
xn_none:                                ; no such word
        li    t0, 0                     ; ...
xn_hit:                                 ; found
        mv    a0, t0                    ; header
        ret                             ; done

; -----------------------------------------------------------------------------
; number(a0 = text, a1 = length) -> a0 = value, a1 = 1 if it is a number.
; Accepts a sign, $hex #decimal %binary prefixes, and 'c' character literals.
; -----------------------------------------------------------------------------
number:                                 ; leaf; clobbers t0..t2, a0..a5
        ld    a5, v_base(zero)          ; a5 = base
        mv    a2, a0                    ; a2 = cursor
        add   a3, a0, a1                ; a3 = end
        li    a4, 0                     ; a4 = 1 if negative
        li    a0, 0                     ; a0 = value
        beqz  a1, nb_fail               ; empty is not a number
        li    t0, 3                     ; 'c' is three characters
        bne   a1, t0, nb_prefix         ; not that
        lbu   t1, 0(a2)                 ; first
        li    t0, 39                    ; a quote
        bne   t1, t0, nb_prefix         ; not a character literal
        lbu   t1, 2(a2)                 ; last
        bne   t1, t0, nb_prefix         ; not a character literal
        lbu   a0, 1(a2)                 ; the character is the value
        li    a1, 1                     ; it is a number
        ret                             ; done
nb_prefix:                              ; a sign may come first: -$10
        lbu   t1, 0(a2)                 ; first character
        li    t0, '-'                   ; minus?
        bne   t1, t0, nb_pfx            ; no
        li    a4, 1                     ; negative
        addi  a2, a2, 1                 ; skip it
        bgeu  a2, a3, nb_fail           ; a lone minus is not a number
nb_pfx:                                 ; base prefixes
        lbu   t1, 0(a2)                 ; first character
        li    t0, '$'                   ; hex
        bne   t1, t0, nb_p2             ; no
        li    a5, 16                    ; base 16
        j     nb_skip                   ; skip the prefix
nb_p2:                                  ; decimal?
        li    t0, '#'                   ; decimal
        bne   t1, t0, nb_p3             ; no
        li    a5, 10                    ; base 10
        j     nb_skip                   ; skip it
nb_p3:                                  ; binary?
        li    t0, '%'                   ; binary
        bne   t1, t0, nb_sign           ; no prefix
        li    a5, 2                     ; base 2
nb_skip:                                ; step over the prefix
        addi  a2, a2, 1                 ; one more
nb_sign:                                ; optional minus
        bgeu  a2, a3, nb_fail           ; nothing left
        lbu   t1, 0(a2)                 ; character
        li    t0, '-'                   ; minus
        bne   t1, t0, nb_digits         ; no sign
        xori  a4, a4, 1                 ; negative (or positive again: --5)
        addi  a2, a2, 1                 ; skip it
        bgeu  a2, a3, nb_fail           ; a lone minus is not a number
nb_digits:                              ; one digit per iteration
        bgeu  a2, a3, nb_done           ; all digits read
        lbu   t1, 0(a2)                 ; character
        addi  t0, t1, -'A'              ; to lower case
        sltiu t0, t0, 26                ; ...
        slli  t0, t0, 5                 ; ...
        add   t1, t1, t0                ; ...
        addi  t2, t1, -'0'              ; t2 = value if 0..9
        li    t0, 10                    ; t0 = 10
        bltu  t2, t0, nb_have           ; a decimal digit
        addi  t2, t1, -'a'              ; a..z?
        li    t0, 26                    ; t0 = 26
        bgeu  t2, t0, nb_fail           ; not a digit at all
        addi  t2, t2, 10                ; a = 10
nb_have:                                ; t2 = digit value
        bgeu  t2, a5, nb_fail           ; too big for the base
        mul   a0, a0, a5                ; shift the value
        add   a0, a0, t2                ; add the digit
        addi  a2, a2, 1                 ; next
        j     nb_digits                 ; continue
nb_done:                                ; apply the sign
        beqz  a4, nb_ok                 ; positive
        sub   a0, zero, a0              ; negate
nb_ok:                                  ; success
        li    a1, 1                     ; it is a number
        ret                             ; done
nb_fail:                                ; failure
        li    a1, 0                     ; not a number
        ret                             ; done

; -----------------------------------------------------------------------------
; local_find(a0 = name, a1 = length) -> a0 = local index, or -1
; -----------------------------------------------------------------------------
local_find:                             ; leaf; clobbers t0..t6, a0..a3
        ld    a2, v_nloc(zero)          ; a2 = locals declared
        li    a3, 0                     ; a3 = index
lf_loop:                                ; one local per iteration
        bgeu  a3, a2, lf_none           ; not a local
        slli  t0, a3, 4                 ; 16 bytes per entry
        la    t1, locnames              ; table
        add   t0, t0, t1                ; t0 = entry
        lbu   t1, 0(t0)                 ; its length
        bne   t1, a1, lf_next           ; must match
        li    t1, 0                     ; character index
lf_cmp:                                 ; compare, case-blind
        bgeu  t1, a1, lf_hit            ; matched
        add   t2, a0, t1                ; ours
        lbu   t2, 0(t2)                 ; ...
        addi  t3, t2, -'A'              ; lower case
        sltiu t3, t3, 26                ; ...
        slli  t3, t3, 5                 ; ...
        add   t2, t2, t3                ; ...
        add   t4, t0, t1                ; the local's
        lbu   t4, 1(t4)                 ; ...
        addi  t3, t4, -'A'              ; lower case
        sltiu t3, t3, 26                ; ...
        slli  t3, t3, 5                 ; ...
        add   t4, t4, t3                ; ...
        bne   t2, t4, lf_next           ; differ
        addi  t1, t1, 1                 ; next character
        j     lf_cmp                    ; continue
lf_hit:                                 ; found
        mv    a0, a3                    ; its index
        ret                             ; done
lf_next:                                ; next local
        addi  a3, a3, 1                 ; one more
        j     lf_loop                   ; continue
lf_none:                                ; not a local
        li    a0, -1                    ; -1
        ret                             ; done

; =============================================================================
; The code generator: staging, installing, calls, literals, folding, inlining
; =============================================================================
; cg(a0 = instruction): append one instruction at chere (in the staging buffer)
cg:                                     ; leaf; clobbers t0..t2
        ld    t0, v_chere(zero)         ; t0 = its I-LS address
        ld    t1, v_climit(zero)        ; the end of code space (64 KiB, or the unit store's)
        addi  t1, t1, -8                ; ...
        bgeu  t0, t1, cg_full           ; out of code space
        ld    t1, v_cbase(zero)         ; t1 = I-LS address of staging byte 0
        sub   t1, t0, t1                ; t1 = staging offset
        li    t2, STAGE_SZ              ; the staging buffer is finite
        bgeu  t1, t2, cg_long           ; this definition is too long
        la    t2, stage                 ; t2 = staging buffer
        add   t2, t2, t1                ; t2 = where the instruction goes
        sw    a0, 0(t2)                 ; store it
        addi  t0, t0, 4                 ; advance chere
        sd    t0, v_chere(zero)         ; v_chere = t0
        ret                             ; done
cg_full:                                ; the I-LS is full
        li    a0, -300                  ; code space full
        j     throw_a0                  ; error
cg_long:                                ; staging overflow
        li    a0, -301                  ; definition too long
        j     throw_a0                  ; error

; cg_align: pad chere to a multiple of 8 with nops
cg_align:                               ; clobbers t0..t2, a0
        mv    t6, ra                    ; cg leaves t6 alone
ca_loop:                                ; until aligned
        ld    t0, v_chere(zero)         ; chere
        andi  t0, t0, 7                 ; misalignment
        beqz  t0, ca_done               ; aligned
        li    a0, I_NOP                 ; a nop
        call  cg                        ; emit it
        j     ca_loop                   ; again
ca_done:                                ; aligned
        jr    t6                        ; return

; cg2(a0, a1): emit two instructions
cg2:                                    ; clobbers t0..t2, t6, a0
        mv    t6, ra                    ; cg leaves t6 and a1 alone
        call  cg                        ; first
        mv    a0, a1                    ; second
        mv    ra, t6                    ; our caller
        j     cg                        ; tail call

; cg_push: the two instructions that make room for a new top of stack
cg_push:                                ; clobbers t0..t2, t6, a0, a1
        li    a0, I_PUSH1               ; addi s0, s0, -8
        li    a1, I_PUSH2               ; sd s1, 0(s0)
        j     cg2                       ; tail call

; cg_lit(a0 = value): push a literal (1, 2 or 6 instructions after the push)
cg_lit:                                 ; clobbers t0..t3, t6, a0, a1
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; save the value
        call  cg_push                   ; room for it
        ld    a0, 8(sp)                 ; the value
        slli  t3, a0, 48                ; does it fit in 16 signed bits?
        srai  t3, t3, 48                ; ...
        bne   t3, a0, cl_32             ; no
        andi  t3, a0, 0xFFFF            ; the immediate field
        li    a0, I_LI_S1               ; addi s1, zero, imm
        or    a0, a0, t3                ; ...
        call  cg                        ; emit
        ld    t0, v_chere(zero)         ; remember where it ended
        sd    t0, v_litend(zero)        ; (a following + - @ ! ... may fold into it)
        ld    t0, 8(sp)                 ; and its value
        sd    t0, v_litval(zero)        ; v_litval = t0
        j     cl_ret                    ; done
cl_32:                                  ; 32 signed bits?
        slli  t3, a0, 32                ; ...
        srai  t3, t3, 32                ; ...
        bne   t3, a0, cl_64             ; no: the long form
        srli  t3, a0, 16                ; the upper half
        andi  t3, t3, 0xFFFF            ; ...
        li    a0, I_LUI_S1              ; lui s1, upper
        or    a0, a0, t3                ; ...
        call  cg                        ; emit
        ld    t3, 8(sp)                 ; the lower half
        andi  t3, t3, 0xFFFF            ; ...
        li    a0, I_ORI_S1              ; ori s1, s1, lower
        or    a0, a0, t3                ; ...
        call  cg                        ; emit
        j     cl_ret                    ; done
cl_64:                                  ; 64 bits: lui, ori, slli, ori, slli, ori
        srli  t3, a0, 48                ; bits 63..48
        li    a0, I_LUI_S1              ; lui s1, ...
        or    a0, a0, t3                ; ...
        call  cg                        ; emit
        ld    t3, 8(sp)                 ; bits 47..32
        srli  t3, t3, 32                ; ...
        andi  t3, t3, 0xFFFF            ; ...
        li    a0, I_ORI_S1              ; ori s1, s1, ...
        or    a0, a0, t3                ; ...
        call  cg                        ; emit
        li    a0, I_SLL16               ; slli s1, s1, 16
        call  cg                        ; emit
        ld    t3, 8(sp)                 ; bits 31..16
        srli  t3, t3, 16                ; ...
        andi  t3, t3, 0xFFFF            ; ...
        li    a0, I_ORI_S1              ; ori s1, s1, ...
        or    a0, a0, t3                ; ...
        call  cg                        ; emit
        li    a0, I_SLL16               ; slli s1, s1, 16
        call  cg                        ; emit
        ld    t3, 8(sp)                 ; bits 15..0
        andi  t3, t3, 0xFFFF            ; ...
        li    a0, I_ORI_S1              ; ori s1, s1, ...
        or    a0, a0, t3                ; ...
        call  cg                        ; emit
cl_ret:                                 ; common exit
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; jal_to(a0 = base instruction, a1 = target) -> a0 = jal from chere to target
jal_to:                                 ; leaf; clobbers t0
        ld    t0, v_chere(zero)         ; the jal will be at chere
        sub   t0, a1, t0                ; byte distance
        srai  t0, t0, 2                 ; in instructions
        slli  t0, t0, 43                ; keep 21 bits
        srli  t0, t0, 43                ; ...
        or    a0, a0, t0                ; into the offset field
        ret                             ; done

; cg_call(a0 = xt): compile a call
cg_call:                                ; clobbers t0..t2, a0, a1
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; save the target
        mv    a1, a0                    ; target
        li    a0, I_CALL                ; jal ra, ...
        call  jal_to                    ; a0 = the call instruction
        call  cg                        ; emit
        ld    t0, v_chere(zero)         ; remember where it ended
        sd    t0, v_callend(zero)       ; (`;` right here turns it into a jump)
        ld    t0, 8(sp)                 ; and the target
        sd    t0, v_callxt(zero)        ; v_callxt = t0
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; -----------------------------------------------------------------------------
; Code paging (StrataOS, one thread: PAGING turned it on at the end of start-up).
; Code compiled from then on goes into CODE UNITS: 2^XSLOT-byte, slot-aligned
; pieces of a store in far memory (c0 [UBASE, UEND)), each holding whole
; definitions. StrataOS pages them: a call of a unit that is not in the I-LS
; misses (xmiss), and the dispatcher copies the unit into a slot of the code
; cache (the I-LS after the resident code, which the code mirror covers),
; maps it and retries. So a unit's code runs at whatever slot it got, and
; must not depend on where that is:
;   * a call of a unit (or of a word in the same unit) is an xcall by far
;     address: addi t5, tp, a - TPV (or lui, ori); xcall ra, c0, t5. It leaves
;     a far link, which xret follows into the caller's unit wherever it is
;     now, paging it back in if it was evicted meanwhile;
;   * a call of resident code is jalr ra, gp, a - 0x10000 (gp = 0x10000): a
;     plain link into the slot, safe because that code never pages, unless it
;     is marked F_PAGER (it may run paged code: EXECUTE, CATCH, EVALUATE ...,
;     and every word that calls one of those): such a word is called through
;     its entry in the GATEWAY (unit 0 of the store: jalr zero, gp, a - 0x10000
;     per word), by an xcall like a unit, and returns with xret;
;   * the prologue and the return are jalr t0, gp, k_enter / jalr zero, gp,
;     k_exit; a variable's stub jalr zero, gp, k_var: k_exit, k_var and k_val
;     return with xret ra, which follows a far link and, for a plain one, is jr.
; A definition is staged as before and placed at `;`: where the last one ended,
; or, if it does not fit there, at the start of the next unit (its few
; absolute references to itself, RECURSE, a quotation's xt, the DOES> code's
; address, are lui/ori pairs recorded in v_fix and moved with it). Installing
; it is a tput to its unit's far copy: since that unit may be in the cache,
; the overlay map is cleared (xunmap): what is needed comes back on demand.
; -----------------------------------------------------------------------------
; cg_target(a0 = xt, a1 = its header or 0): compile a call of a word, as the
; code being compiled needs it (see above)
cg_target:                              ; clobbers t0..t6, a0..a2
        ld    t0, v_paged(zero)         ; compiling into units?
        beqz  t0, cg_call               ; no: resident code calls with jal (a tail call)
        j     ct_unit                   ; yes: see the paging part (kpage)

; cg_fold(a0 = FD_ kind) -> a0 = 1 if the last literal was folded into the operation
cg_fold:                                ; clobbers t0..t3, t6, a0, a1
        ld    t0, v_litend(zero)        ; the last literal ended at ...
        ld    t1, v_chere(zero)         ; ... and code ends at ...
        bne   t0, t1, fo_no             ; something came after it: no folding
        ld    t2, v_litval(zero)        ; t2 = the literal (16-bit signed)
        li    t3, FD_ADD                ; dispatch on the kind
        beq   a0, t3, fo_add            ; +
        li    t3, FD_SUB                ; -
        beq   a0, t3, fo_sub            ; ...
        li    t3, FD_LD                 ; @
        beq   a0, t3, fo_ld             ; ...
        li    t3, FD_LDB                ; c@
        beq   a0, t3, fo_ldb            ; ...
        li    t3, FD_ST                 ; !
        beq   a0, t3, fo_st             ; ...
        li    t3, FD_STB                ; c!
        beq   a0, t3, fo_stb            ; ...
        li    t3, FD_SHL                ; shifts: 0..63 only
        bltu  a0, t3, fo_logic          ; and / or / xor
        li    t3, 63                    ; shift range
        bltu  t3, t2, fo_no             ; out of range (or negative)
        li    t3, FD_SHL                ; which shift
        li    a1, OP_SLLI << 26 | I_FOLDI ; slli s1, s1, v
        beq   a0, t3, fo_alu            ; ...
        li    t3, FD_SHR                ; t3 = FD_SHR
        li    a1, OP_SRLI << 26 | I_FOLDI ; srli s1, s1, v
        beq   a0, t3, fo_alu            ; ...
        li    a1, OP_SRAI << 26 | I_FOLDI ; srai s1, s1, v
        j     fo_alu                    ; on to fo_alu
fo_logic:                               ; and / or / xor take 0..65535
        bltz  t2, fo_no                 ; negative: not representable
        li    t3, FD_AND                ; which
        li    a1, OP_ANDI << 26 | I_FOLDI ; andi s1, s1, v
        beq   a0, t3, fo_alu            ; ...
        li    t3, FD_OR                 ; t3 = FD_OR
        li    a1, OP_ORI << 26 | I_FOLDI ; ori s1, s1, v
        beq   a0, t3, fo_alu            ; ...
        li    a1, OP_XORI << 26 | I_FOLDI ; xori s1, s1, v
        j     fo_alu                    ; on to fo_alu
fo_sub:                                 ; x - v = x + (-v)
        sub   t2, zero, t2              ; -v
        li    t3, 32767                 ; must still fit
        blt   t3, t2, fo_no             ; (v was -32768)
fo_add:                                 ; addi s1, s1, v
        li    a1, OP_ADDI << 26 | I_FOLDI ; a1 = OP_ADDI << 26 | I_FOLDI
fo_alu:                                 ; drop the literal's push and load, emit one ALU op
        addi  t1, t1, -12               ; chere back over push, push, li
        sd    t1, v_chere(zero)         ; v_chere = t1
        andi  t2, t2, 0xFFFF            ; the immediate
        or    a0, a1, t2                ; the instruction
        j     fo_emit1                  ; emit it
fo_ld:                                  ; ld s1, v(zero): keep the push, replace the li
        li    a1, OP_LD << 26 | I_FOLDM ; a1 = OP_LD << 26 | I_FOLDM
        j     fo_mem                    ; on to fo_mem
fo_ldb:                                 ; lbu s1, v(zero)
        li    a1, OP_LBU << 26 | I_FOLDM ; a1 = OP_LBU << 26 | I_FOLDM
fo_mem:                                 ; D-LS addresses only
        bltz  t2, fo_no                 ; negative: not an address
        addi  t1, t1, -4                ; back over the li only
        sd    t1, v_chere(zero)         ; v_chere = t1
        or    a0, a1, t2                ; the load
        j     fo_emit1                  ; emit it
fo_st:                                  ; sd s1, v(zero); then pop
        li    a1, OP_SD << 26 | I_FOLDM ; a1 = OP_SD << 26 | I_FOLDM
        j     fo_store                  ; on to fo_store
fo_stb:                                 ; sb s1, v(zero); then pop
        li    a1, OP_SB << 26 | I_FOLDM ; a1 = OP_SB << 26 | I_FOLDM
fo_store:                               ; the value is the old top: drop push and li
        bltz  t2, fo_no                 ; not an address
        addi  t1, t1, -12               ; back over the whole literal
        sd    t1, v_chere(zero)         ; v_chere = t1
        addi  sp, sp, -8                ; frame (we call cg three times)
        sd    ra, 0(sp)                 ; save the return address
        or    a0, a1, t2                ; the store
        call  cg                        ; emit
        li    a0, I_POP1                ; then pop:
        li    a1, I_POP2                ; ld s1, 0(s0); addi s0, s0, 8
        call  cg2                       ; emit
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; drop the frame
        j     fo_yes                    ; folded
fo_emit1:                               ; emit the one instruction in a0
        mv    t6, ra                    ; cg leaves t6 alone
        call  cg                        ; emit
        mv    ra, t6                    ; restore
fo_yes:                                 ; folded
        sd    zero, v_litend(zero)      ; the literal is gone
        li    a0, 1                     ; yes
        ret                             ; done
fo_no:                                  ; not folded
        li    a0, 0                     ; no
        ret                             ; done

; cg_inline(a0 = xt, a1 = body bytes): copy a primitive's body. The body is
; read back from the far mirror of the I-LS: code is never readable in place.
cg_inline:                              ; clobbers t0..t6, a0..a2
        beqz  a1, ci_none               ; an empty body (e.g. chars)
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; xt
        sd    a1, 16(sp)                ; size
        call  reclaim                   ; we need c0 at home
        ld    a0, 8(sp)                 ; xt
        andi  t3, a0, 4                 ; t3 = its offset in its doubleword (0 or 4)
        sub   a0, a0, t3                ; a0 = the doubleword
        ld    t1, 16(sp)                ; size
        add   t1, t1, t3                ; + the offset
        addi  t1, t1, 7                 ; round up
        srli  t1, t1, 3                 ; to whole
        slli  t1, t1, 3                 ; doublewords
        la    t0, inlbuf                ; destination
        tget  tg13, t0, c0, a0, t1      ; the body comes back from far memory
        ld    t5, 16(sp)                ; end offset = offset + size
        add   t5, t5, t3                ; ...
        sd    t5, 16(sp)                ; ...
        la    t4, inlbuf                ; t4 = buffer (t3 = first byte of the body)
ci_loop:                                ; one instruction per iteration
        ld    t5, 16(sp)                ; size
        bgeu  t3, t5, ci_done           ; all copied
        add   t6, t4, t3                ; address
        lw    a0, 0(t6)                 ; the instruction (this load waits for the tget)
        call  cg                        ; emit it (cg keeps t3..t6)
        addi  t3, t3, 4                 ; next
        j     ci_loop                   ; continue
ci_done:                                ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
ci_none:                                ; nothing to do
        ret                             ; done

; compile_nt(a0 = header): compile one use of a word
compile_nt:                             ; clobbers t0..t6, a0..a2
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the header
        lbu   t0, H_FLAGS(a0)           ; flags
        andi  t1, t0, F_CREATE          ; a CREATEd word ...
        bnez  t1, cn_create             ; ... is its data field address
        andi  t1, t0, F_CONST           ; a CONSTANT ...
        bnez  t1, cn_const              ; ... is its value
        andi  t1, t0, F_VALUE           ; a VALUE ...
        bnez  t1, cn_value              ; ... is a load
        andi  t1, t0, F_PAGER           ; a word that may page is called (its fold byte
        bnez  t1, cn_call               ;   is its entry in the gateway)
        lbu   a0, H_FOLD(a0)            ; folding kind
        beqz  a0, cn_plain              ; none
        call  cg_fold                   ; try to fold the last literal into it
        bnez  a0, cn_ret                ; done in one instruction
cn_plain:                               ; inline or call
        ld    a0, 8(sp)                 ; header
        lbu   t0, H_FLAGS(a0)           ; flags
        andi  t1, t0, F_INL             ; inline?
        beqz  t1, cn_call               ; no: a call
        lhu   a1, H_SIZE(a0)            ; body size
        ld    t1, v_inlmax(zero)        ; bodies of up to 4 instructions (16 bytes, INLINE-LIMIT) are
        bgtu  a1, t1, cn_long           ; copied; longer ones are called (the I-LS is small)
        call  hxt                       ; body address (a1 survives)
        call  cg_inline                 ; copy it
        j     cn_ret                    ; done
cn_long:                                ; a long primitive: call it, but never as a tail call:
        mv    a1, a0                    ; 2>r, 2r> and 2r@ work on the return stack, and the
        call  hxt                       ; epilogue before a jump would pop the wrong cell
        call  cg_target                 ; ...
        sd    zero, v_callend(zero)     ; (`;` right here must not turn it into a jump)
        j     cn_ret                    ; done
cn_call:                                ; a call
        ld    a1, 8(sp)                 ; the header
        mv    a0, a1                    ; target
        call  hxt                       ; ...
        call  cg_target                 ; emit
        j     cn_ret                    ; done
cn_create:                              ; push the data field address
        call  nt_dfa                    ; a0 = data field
        call  cg_lit                    ; literal
        j     cn_ret                    ; done
cn_const:                               ; push the value
        call  nt_dfa                    ; a0 = data field
        ld    a0, 0(a0)                 ; the value
        call  cg_lit                    ; literal
        j     cn_ret                    ; done
cn_value:                               ; push the data field, then fetch
        call  nt_dfa                    ; a0 = data field
        call  cg_lit                    ; literal
        li    a0, FD_LD                 ; fold with @: ld s1, dfa(zero)
        call  cg_fold                   ; call cg_fold
        bnez  a0, cn_ret                ; folded
        li    a0, I_LDS1                ; else ld s1, 0(s1)
        call  cg                        ; call cg
cn_ret:                                 ; common exit
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; cg_exit(a0 = 1 to turn a just-compiled call into a jump): locals teardown,
; then the epilogue
cg_exit:                                ; clobbers t0..t6, a0, a1
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    zero, 8(sp)               ; tail target (0 = none)
        sd    a0, 16(sp)                ; the kind of exit
        li    t0, 1                     ; a tail call wanted?
        bne   a0, t0, ce_locals         ; no
        ld    t0, v_callend(zero)       ; was the last thing compiled a call?
        ld    t1, v_chere(zero)         ; t1 = v_chere
        bne   t0, t1, ce_locals         ; no
        ld    t2, v_paged(zero)         ; paged code: see ce_unit (kpage)
        bnez  t2, ce_unit               ; ...
ce_back:                                ; a jal
        addi  t1, t1, -4                ; take the call back
ce_tail:                                ; ...
        sd    t1, v_chere(zero)         ; v_chere = t1
        ld    t0, v_callxt(zero)        ; its target
        sd    t0, 8(sp)                 ; becomes a jump target
ce_locals:                              ; tear down a locals frame
        ld    t3, v_nloc(zero)          ; t3 = locals
        beqz  t3, ce_epi                ; none
        li    a0, I_LT_MV               ; addi t0, s4, 0
        call  cg                        ; call cg
        slli  t3, t3, 3                 ; 8 * n
        li    a0, I_LT_LD               ; ld s4, 8n(t0): the caller's frame
        or    a0, a0, t3                ; ...
        call  cg                        ; call cg
        addi  t3, t3, 8                 ; 8n + 8
        li    a0, I_LT_SP               ; addi sp, t0, 8n+8: drop the frame
        or    a0, a0, t3                ; ...
        call  cg                        ; call cg
ce_epi:                                 ; the epilogue
        ld    a1, 8(sp)                 ; tail target?
        beqz  a1, ce_ret                ; no
        li    a0, I_EPI1                ; ld ra, 0(sp)
        li    a1, I_EPI2                ; addi sp, sp, 8
        call  cg2                       ; call cg2
        ld    a1, 8(sp)                 ; the target again
        ld    t0, v_paged(zero)         ; paged: see ce_ujump (kpage)
        bnez  t0, ce_ujump              ; ...
ce_jal:                                 ; ...
        li    a0, I_JMP                 ; jal zero, target
        call  jal_to                    ; call jal_to
        call  cg                        ; call cg
        j     ce_done                   ; done
ce_ret:                                 ; a plain return
        ld    t0, 16(sp)                ; DOES> needs the full three instructions
        li    t1, 2                     ; (its does-code starts a fixed 12 bytes on)
        beq   t0, t1, ce_full           ; ...
        call  cg_ret                    ; compact or full, as the platform builds
        j     ce_done                   ; done
ce_full:                                ; always three instructions
        call  cg_retf                   ; ld ra, 0(sp); addi sp, sp, 8; ret
ce_done:                                ; common exit
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done

; begin_def: open a definition at chere (8-aligned): state, prologue
begin_def:                              ; clobbers t0..t2, t6, a0, a1
        li    t0, 1                     ; a definition is open
        sd    t0, v_open(zero)          ; v_open = t0
        li    t0, -1                    ; compiling
        sd    t0, v_state(zero)         ; v_state = t0
        sd    zero, v_nloc(zero)        ; no locals yet
        sd    zero, v_litend(zero)      ; no literal to fold
        sd    zero, v_callend(zero)     ; no call to turn into a jump
        sd    zero, v_nfix(zero)        ; no pairs to move
        j     cg_pro                    ; tail call: the prologue

; cg_pro: compile a definition's prologue: save ra on the return stack. With
; PLAT_COMPACT it is one instruction, `jal t0, k_enter` (the two live in the
; kernel once), and a plain return is `j k_exit`: 12 bytes less per word, two
; jumps more per call. StrataOS programs have 32 KiB of code space.
cg_pro:                                 ; clobbers t0..t2, t6, a0, a1
        ld    t0, v_paged(zero)         ; paged: jalr t0, gp, k_enter
        beqz  t0, cp_res                ; ...
        li    a0, I_GPRO                ; ...
        la    a1, k_enter               ; ...
        j     cg_gp                     ; ...
cp_res:                                 ; ...
        li    t0, PLAT_COMPACT          ; compact code?
        bnez  t0, cp_short              ; yes
        li    a0, I_PRO1                ; addi sp, sp, -8
        li    a1, I_PRO2                ; sd ra, 0(sp)
        j     cg2                       ; tail call
cp_short:                               ; one instruction
        li    a0, I_JALT0               ; jal t0, k_enter
        la    a1, k_enter               ; ...
        mv    t1, ra                    ; jal_to clobbers only t0
        call  jal_to                    ; a0 = the instruction
        mv    ra, t1                    ; ...
        j     cg                        ; tail call
k_enter:                                ; the shared prologue (entered with jal t0)
        addi  sp, sp, -8                ; room on the return stack
        sd    ra, 0(sp)                 ; save the return address
        jr    t0                        ; back into the word
k_exit:                                 ; the shared return (entered with j)
        ld    ra, 0(sp)                 ; the word's return address
        addi  sp, sp, 8                 ; pop it
        xret  ra                        ; return to the word's caller (a far link too)

; cg_ret: compile "restore ra and return" (no tail call, no locals)
cg_ret:                                 ; clobbers t0..t6, a0, a1
        ld    t0, v_paged(zero)         ; paged: jalr zero, gp, k_exit
        beqz  t0, cr_res                ; ...
        li    a0, I_GJUMP               ; ...
        la    a1, k_exit                ; ...
        j     cg_gp                     ; ...
cr_res:                                 ; ...
        li    t0, PLAT_COMPACT          ; compact code?
        bnez  t0, cr_short              ; yes
cg_retf:                                ; the full form: three instructions
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        li    a0, I_EPI1                ; ld ra, 0(sp)
        li    a1, I_EPI2                ; addi sp, sp, 8
        call  cg2                       ; call cg2
        li    a0, I_RET                 ; jalr zero, ra, 0
        call  cg                        ; call cg
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
cr_short:                               ; one instruction
        li    a0, I_JMP                 ; jal zero, k_exit
        la    a1, k_exit                ; ...
        mv    t1, ra                    ; jal_to clobbers only t0
        call  jal_to                    ; a0 = the instruction
        mv    ra, t1                    ; ...
        j     cg                        ; tail call

; end_def: pad, place (paged code), record the size, reveal, install
end_def:                                ; clobbers t0..t6, a0..a5
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  cg_align                  ; whole doublewords
        ld    t0, v_paged(zero)         ; paged code: in one unit
        beqz  t0, ed_rec                ; ...
        j     ed_place                  ; (see kpage)
ed_rec:                                 ; ...
        ld    t0, v_curnt(zero)         ; the header (0 for :noname)
        beqz  t0, ed_anon               ; nothing to record
        ld    t1, v_chere(zero)         ; end
        ld    t2, v_curxt(zero)         ; start
        sub   t1, t1, t2                ; size
        sh    t1, H_SIZE(t0)            ; record it
        lbu   t1, H_FLAGS(t0)           ; flags
        andi  t1, t1, 0xFF ^ F_HIDDEN   ; reveal
        sb    t1, H_FLAGS(t0)           ; ...
ed_anon:                                ; close
        sd    zero, v_open(zero)        ; no definition open
        sd    zero, v_state(zero)       ; interpreting
        sd    zero, v_nloc(zero)        ; locals are gone
        ld    t0, v_noname(zero)        ; paged :NONAME: its xt now that it is placed
        beqz  t0, ed_inst               ; ...
        sd    zero, v_noname(zero)      ; ...
        addi  s0, s0, -8                ; ...
        sd    s1, 0(s0)                 ; ...
        ld    s1, v_curxt(zero)         ; ...
ed_inst:                                ; ...
        call  flush_code                ; install it
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
ed_long:                                ; it fits no unit
        li    a0, -311                  ; definition longer than a code unit
        j     throw_a0                  ; error

; flush_code: install everything staged: tput to the far mirror, tgetx into
; the I-LS. Pads to 8 bytes first.
flush_code:                             ; clobbers t0..t6, a0..a5
        ld    t0, v_chere(zero)         ; end of code
        ld    t1, v_cbase(zero)         ; start of what is staged
        beq   t0, t1, fl_none           ; nothing staged
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  cg_align                  ; whole doublewords
        call  reclaim                   ; c0 must be at home
        ld    t1, v_cbase(zero)         ; start (= its far offset: the mirror is an identity map)
        ld    t2, v_chere(zero)         ; end
        sub   t2, t2, t1                ; bytes
        la    t3, stage                 ; the staged instructions
        tput  tg13, t3, c0, t1, t2      ; D-LS -> far mirror (or its unit)
        srli  t3, t1, 16                ; a unit?
        bnez  t3, fl_unit               ; ...
        tgetx tg13, t1, c0, t1, t2      ; far mirror -> I-LS: the code is live
        j     fl_count                  ; ...
fl_unit:                                ; a unit: StrataOS pages it in when it is called
        twait 1 << 13                   ; (from far memory: the tput must be there)
        call  f_unmap                   ; and a stale copy of it may be in the cache
fl_count:                               ; ...
        ld    t3, v_jitn(zero)          ; count installs
        addi  t3, t3, 1                 ; one more
        sd    t3, v_jitn(zero)          ; v_jitn = t3
        ld    t3, v_jitb(zero)          ; and bytes
        add   t3, t3, t2                ; ...
        sd    t3, v_jitb(zero)          ; v_jitb = t3
        ld    t3, v_jittr(zero)         ; reporting installs?
        beqz  t3, fl_done               ; no
        addi  sp, sp, -16               ; save start and size
        sd    t1, 0(sp)                 ; ...
        sd    t2, 8(sp)                 ; ...
        la    a0, s_jit                 ; "[jit: tput+tgetx "
        call  out_str                   ; call out_str
        ld    a0, 8(sp)                 ; bytes
        call  print_dec                 ; call print_dec
        la    a0, s_jit2                ; " bytes -> I-LS "
        call  out_str                   ; call out_str
        ld    a0, 0(sp)                 ; address
        call  print_hex                 ; call print_hex
        li    a0, ']'                   ; a0 = ']'
        call  out_char                  ; call out_char
        call  out_space                 ; call out_space
        addi  sp, sp, 16                ; pop
fl_done:                                ; everything is installed
        ld    t0, v_chere(zero)         ; staging restarts here
        sd    t0, v_cbase(zero)         ; v_cbase = t0
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
fl_none:                                ; nothing to do
        ret                             ; done

; code_patch(a0 = instruction, a1 = I-LS address): change one installed
; instruction: fetch its doubleword from the mirror, patch, put it back,
; reinstall it
code_patch:                             ; clobbers t0..t6, a0, a1
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; instruction
        sd    a1, 16(sp)                ; address
        call  reclaim                   ; c0 must be at home
        ld    a0, 8(sp)                 ; instruction
        ld    a1, 16(sp)                ; address
        srli  t0, a1, 3                 ; its doubleword
        slli  t0, t0, 3                 ; ...
        la    t1, v_tbuf                ; 8 bytes of D-LS
        li    t2, 8                     ; one doubleword
        tget  tg13, t1, c0, t0, t2      ; mirror -> D-LS
        andi  t3, a1, 4                 ; which half
        add   t3, t1, t3                ; ...
        sw    a0, 0(t3)                 ; patch (waits for the tget)
        tput  tg13, t1, c0, t0, t2      ; D-LS -> mirror (or its unit)
        srli  t3, t0, 16                ; a unit?
        bnez  t3, cp_unit               ; ...
        tgetx tg13, t0, c0, t0, t2      ; mirror -> I-LS
        j     cp_done                   ; ...
cp_unit:                                ; a unit: its far copy changed
        twait 1 << 13                   ; ...
        call  f_unmap                   ; ...
cp_done:                                ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done

; -----------------------------------------------------------------------------
; The interpreter
; -----------------------------------------------------------------------------
; INTERPRET ( -- ): interpret the rest of the input buffer
p_interpret:                            ; Forth word
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
in_loop:                                ; one word per iteration
        call  parse_name                ; a0/a1 = next name
        beqz  a1, in_done               ; the buffer is used up
        sd    a0, v_ename(zero)         ; remember it for error messages
        sd    a1, v_elen(zero)          ; v_elen = a1
        ld    t0, v_state(zero)         ; compiling?
        beqz  t0, in_find               ; no: no locals to look at
        ld    t0, v_nloc(zero)          ; any locals?
        beqz  t0, in_find               ; no
        call  local_find                ; a0 = local index or -1
        bltz  a0, in_find               ; not a local
        slli  a0, a0, 3                 ; 8 * index
        addi  sp, sp, -8                ; save it
        sd    a0, 0(sp)                 ; ...
        call  cg_push                   ; room for the value
        ld    a0, 0(sp)                 ; offset
        addi  sp, sp, 8                 ; drop the frame
        li    t0, I_LDLOC               ; ld s1, 8i(s4)
        or    a0, a0, t0                ; ...
        call  cg                        ; call cg
        j     in_loop                   ; next word
in_find:                                ; a dictionary word?
        ld    a0, v_ename(zero)         ; name
        ld    a1, v_elen(zero)          ; a1 = v_elen
        call  find_name                 ; a0 = header or 0
        beqz  a0, in_num                ; not a word: a number?
        ld    t0, v_state(zero)         ; compiling?
        beqz  t0, in_exec               ; no: run it
        lbu   t1, H_FLAGS(a0)           ; immediate?
        andi  t1, t1, F_IMM             ; ...
        bnez  t1, in_exec               ; yes: run it now
        call  compile_nt                ; compile it
        j     in_loop                   ; next word
in_exec:                                ; run the word
        call  hxt                       ; a0 = its xt (EXECUTE runs a unit's code too)
in_xt:                                  ; a0 = the xt
        addi  sp, sp, -8                ; save it
        sd    a0, 0(sp)                 ; ...
        ld    t0, v_open(zero)          ; inside a definition?
        bnez  t0, in_go                 ; yes: leave its code staged
        call  flush_code                ; else install anything staged (e.g. CREATE stubs)
in_go:                                  ; call it
        ld    t0, 0(sp)                 ; the code
        addi  sp, sp, 8                 ; drop the frame
        ld    t1, v_epoch(zero)         ; one more word run: the image may differ
        addi  t1, t1, 1                 ; one more
        sd    t1, v_epoch(zero)         ; v_epoch = t1
        addi  s0, s0, -8                ; execute it
        sd    s1, 0(s0)                 ; ...
        mv    s1, t0                    ; ...
        call  p_execute                 ; ...
        li    t0, DS_TOP                ; stack check: underflow?
        bltu  t0, s0, in_under          ; s0 above the top: too many pops
        li    t0, DS_BOTTOM             ; overflow?
        bltu  s0, t0, in_over           ; below the bottom
        j     in_loop                   ; next word
in_num:                                 ; a number?
        ld    a0, v_ename(zero)         ; name
        ld    a1, v_elen(zero)          ; a1 = v_elen
        call  number                    ; a0 = value, a1 = ok
        beqz  a1, in_undef              ; neither word nor number
        ld    t0, v_state(zero)         ; compiling?
        bnez  t0, in_lit                ; yes: a literal
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, a0                    ; a0 is the new top
        li    t0, DS_BOTTOM             ; overflow?
        bltu  s0, t0, in_over           ; ...
        j     in_loop                   ; next word
in_lit:                                 ; compile a literal
        call  cg_lit                    ; call cg_lit
        j     in_loop                   ; next word
in_done:                                ; the buffer is used up
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        xret  ra                        ; done (a word that may page: see "Code paging")
in_undef:                               ; unknown: maybe a tool the platform loads on demand
        ld    t0, v_state(zero)         ; only when interpreting (a definition cannot
        bnez  t0, in_u13                ; call a word that is forgotten again)
        ld    a0, v_ename(zero)         ; the name
        ld    a1, v_elen(zero)          ; ...
        call  plat_tool                 ; a0, a1 = the file that defines it (a0 = 0: none)
        beqz  a0, in_u13                ; not a tool
        addi  s0, s0, -32               ; push file name, file length, word name, word length
        sd    s1, 24(s0)                ; the old top goes to memory
        sd    a0, 16(s0)                ; the file's name
        sd    a1, 8(s0)                 ; its length
        ld    t0, v_ename(zero)         ; the word's name (in the input buffer)
        sd    t0, 0(s0)                 ; ...
        ld    s1, v_elen(zero)          ; its length
        call  p_tool                    ; load the file, run the word, forget the file
        li    t0, DS_TOP                ; stack check: underflow?
        bltu  t0, s0, in_under          ; s0 above the top: too many pops
        li    t0, DS_BOTTOM             ; overflow?
        bltu  s0, t0, in_over           ; below the bottom
        j     in_loop                   ; next word
in_u13:                                 ; really unknown
        li    a0, -13                   ; undefined word
        j     throw_a0                  ; error
in_under:                               ; underflow
        li    a0, -4                    ; stack underflow
        j     throw_a0                  ; error
in_over:                                ; overflow
        li    a0, -3                    ; stack overflow
        j     throw_a0                  ; error

; spec_save / spec_restore: the 7 cells of the input source (v_src..v_line)
spec_save:                              ; a0 = 56-byte destination; leaf
        la    t0, v_src                 ; source fields
        li    t1, 7                     ; seven cells
ss_loop:                                ; copy
        ld    t2, 0(t0)                 ; ...
        sd    t2, 0(a0)                 ; ...
        addi  t0, t0, 8                 ; next cell
        addi  a0, a0, 8                 ; next cell
        addi  t1, t1, -1                ; one fewer
        bnez  t1, ss_loop               ; if t1 is nonzero, go to ss_loop
        ret                             ; done
spec_restore:                           ; a0 = 56-byte source; leaf
        la    t0, v_src                 ; source fields
        li    t1, 7                     ; seven cells
sr_loop:                                ; copy back
        ld    t2, 0(a0)                 ; ...
        sd    t2, 0(t0)                 ; ...
        addi  t0, t0, 8                 ; next cell
        addi  a0, a0, 8                 ; next cell
        addi  t1, t1, -1                ; one fewer
        bnez  t1, sr_loop               ; if t1 is nonzero, go to sr_loop
        ret                             ; done

; EVALUATE ( addr u -- ): interpret a string
p_evaluate:                             ; Forth word
        addi  sp, sp, -64               ; frame: ra + the saved source
        sd    ra, 0(sp)                 ; save the return address
        addi  a0, sp, 8                 ; save the current source
        call  spec_save                 ; call spec_save
        sd    s1, v_srclen(zero)        ; the string is the source
        ld    t0, 0(s0)                 ; ...
        sd    t0, v_src(zero)           ; v_src = t0
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        sd    zero, v_in(zero)          ; from its start
        li    t0, -1                    ; source id -1: a string
        sd    t0, v_srcid(zero)         ; v_srcid = t0
        call  p_interpret               ; interpret it
        addi  a0, sp, 8                 ; restore the source
        call  spec_restore              ; call spec_restore
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 64                ; pop
        xret  ra                        ; done (it may page)

; refill_far -> a0 = 1 if a line of far text is now the input buffer, 0 at
; its end. One tget of up to 256 bytes per line: lines are at most 248 bytes.
refill_far:                             ; clobbers t0..t6, a0..a3
        ld    t0, v_fpos(zero)          ; t0 = c0 offset of the line
        ld    t1, v_fend(zero)          ; t1 = end of the text
        bgeu  t0, t1, rf_end            ; no more lines
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  reclaim                   ; c0 must be at home
        ld    t0, v_fpos(zero)          ; reload
        ld    t1, v_fend(zero)          ; t1 = v_fend
        srli  t2, t0, 3                 ; t2 = doubleword containing it
        slli  t2, t2, 3                 ; ...
        sub   t3, t1, t2                ; t3 = bytes left from there
        li    t4, 256                   ; at most 256
        bleu  t3, t4, rf_n              ; ...
        mv    t3, t4                    ; ...
rf_n:                                   ; t3 = bytes to look at
        addi  t4, t3, 7                 ; transfer whole doublewords
        srli  t4, t4, 3                 ; ...
        slli  t4, t4, 3                 ; ...
        la    t5, srcbuf                ; destination
        tget  tg11, t5, c0, t2, t4      ; the text arrives (scanning it waits for it)
        sub   t6, t0, t2                ; t6 = offset of the line in srcbuf
        add   a0, t5, t6                ; a0 = line start in D-LS
        add   a1, t5, t3                ; a1 = end of valid bytes
        mv    a2, a0                    ; a2 = scan cursor
rf_scan:                                ; find the newline
        bgeu  a2, a1, rf_nonl           ; none in the chunk
        lbu   a3, 0(a2)                 ; character
        li    t4, 10                    ; newline?
        beq   a3, t4, rf_nl             ; found
        addi  a2, a2, 1                 ; next
        j     rf_scan                   ; continue
rf_nonl:                                ; no newline: the last line, or too long
        add   t4, t2, t3                ; far offset of the chunk end
        bltu  t4, t1, rf_long           ; more text follows: the line is too long
        sub   a3, a2, t5                ; consumed up to the end
        j     rf_set                    ; the last line
rf_nl:                                  ; a2 = the newline
        sub   a3, a2, t5                ; offset of the newline in srcbuf
        addi  a3, a3, 1                 ; the next line starts after it
rf_set:                                 ; a0 = line, a2 = its end, a3 = srcbuf bytes consumed
        add   t4, t2, a3                ; next line's offset
        sd    t4, v_fpos(zero)          ; v_fpos = t4
        sd    a0, v_src(zero)           ; the line is the input buffer
        sub   t4, a2, a0                ; its length
        sd    t4, v_srclen(zero)        ; v_srclen = t4
        sd    zero, v_in(zero)          ; parse from its start
        ld    t4, v_line(zero)          ; count lines
        addi  t4, t4, 1                 ; one more
        sd    t4, v_line(zero)          ; v_line = t4
        li    a0, 1                     ; a line
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
rf_long:                                ; too long
        li    a0, -18                   ; parsed string overflow
        j     throw_a0                  ; error
rf_end:                                 ; end of text
        li    a0, 0                     ; no line
        ret                             ; done

; EVALUATE-FAR ( foff u -- ): interpret u bytes of text at c0 offset foff,
; line by line (how core.fs is loaded, and INCLUDEd files under StrataOS)
p_evalfar:                              ; Forth word
        addi  sp, sp, -EF_FRAME         ; frame: ra, the saved source, the line buffer
        sd    ra, 0(sp)                 ; save the return address
        addi  a0, sp, 8                 ; save the current source
        call  spec_save                 ; call spec_save
        la    t0, srcbuf                ; the outer source may be a line of far text in
        addi  t1, sp, 64                ; srcbuf (an INCLUDE inside a file): keep it
        li    t2, SRCBUF_SZ / 8         ; doublewords
ef_keep:                                ; copy srcbuf to the frame
        ld    t3, 0(t0)                 ; ...
        sd    t3, 0(t1)                 ; ...
        addi  t0, t0, 8                 ; next
        addi  t1, t1, 8                 ; ...
        addi  t2, t2, -1                ; one fewer
        bnez  t2, ef_keep               ; until all are copied
        ld    t0, 0(s0)                 ; t0 = offset
        sd    t0, v_fpos(zero)          ; first line
        add   t1, t0, s1                ; end
        sd    t1, v_fend(zero)          ; v_fend = t1
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        li    t0, 1                     ; source id 1: far text
        sd    t0, v_srcid(zero)         ; v_srcid = t0
        sd    zero, v_line(zero)        ; line numbers from 1
ef_loop:                                ; one line per iteration
        call  refill_far                ; next line
        beqz  a0, ef_done               ; the end
        call  p_interpret               ; interpret it
        j     ef_loop                   ; continue
ef_done:                                ; finished
        la    t0, srcbuf                ; the outer line back into srcbuf
        addi  t1, sp, 64                ; from the frame
        li    t2, SRCBUF_SZ / 8         ; doublewords
ef_back:                                ; copy it back
        ld    t3, 0(t1)                 ; ...
        sd    t3, 0(t0)                 ; ...
        addi  t0, t0, 8                 ; next
        addi  t1, t1, 8                 ; ...
        addi  t2, t2, -1                ; one fewer
        bnez  t2, ef_back               ; until all are back
        addi  a0, sp, 8                 ; restore the source
        call  spec_restore              ; call spec_restore
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, EF_FRAME          ; pop
        xret  ra                        ; done (it may page)

; -----------------------------------------------------------------------------
; CATCH and THROW. A frame on the return stack: ra, s0..s4, the previous
; handler, the input source (7 cells): 14 cells.
; -----------------------------------------------------------------------------
CF_SIZE   = 112                         ; bytes per catch frame
p_catch:                                ; CATCH ( i*x xt -- j*x 0 | i*x n )
        mv    t3, s1                    ; t3 = xt (spec_save leaves t3 alone)
        ld    s1, 0(s0)                 ; pop it
        addi  s0, s0, 8                 ; one cell off the data stack
        addi  sp, sp, -CF_SIZE          ; the frame
        sd    ra, 0(sp)                 ; where CATCH returns
        sd    s0, 8(sp)                 ; the data stack as it is now
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; loop registers
        sd    s3, 32(sp)                ; ...
        sd    s4, 40(sp)                ; locals frame
        ld    t1, v_handler(zero)       ; the enclosing frame
        sd    t1, 48(sp)                ; ...
        addi  a0, sp, 56                ; the input source
        call  spec_save                 ; (clobbers only t0..t2, a0)
        sd    sp, v_handler(zero)       ; we are the innermost frame
        addi  s0, s0, -8                ; run the xt
        sd    s1, 0(s0)                 ; ...
        mv    s1, t3                    ; ...
        call  p_execute                 ; ...
        ld    t1, 48(sp)                ; it returned normally: unlink the frame
        sd    t1, v_handler(zero)       ; v_handler = t1
        ld    ra, 0(sp)                 ; our return address
        addi  sp, sp, CF_SIZE           ; drop the frame
        addi  s0, s0, -8                ; push 0
        sd    s1, 0(s0)                 ; the old top goes to memory
        li    s1, 0                     ; s1 = 0
        xret  ra                        ; done (it may page: a far link)
p_throw:                                ; THROW ( k*x n -- k*x | i*x n )
        bnez  s1, th_go                 ; 0 THROW does nothing
        ld    s1, 0(s0)                 ; drop the 0
        addi  s0, s0, 8                 ; one cell off the data stack
        ret                             ; done
th_go:                                  ; a real throw
        mv    a0, s1                    ; a0 = the code
throw_a0:                               ; throw code a0 (also used by the kernel)
        ld    t0, v_srcid(zero)         ; where were we? (for the message)
        sd    t0, v_esrc(zero)          ; v_esrc = t0
        ld    t0, v_line(zero)          ; t0 = v_line
        sd    t0, v_eline(zero)         ; v_eline = t0
        ld    t0, v_fname(zero)         ; and in which far text
        sd    t0, v_efname(zero)        ; v_efname = t0
rethrow_a0:                             ; pass a caught error on: where it happened stays as recorded
        ld    t0, v_handler(zero)       ; the innermost frame
        beqz  t0, th_none               ; none (cannot happen under QUIT)
        mv    sp, t0                    ; unwind the return stack to it
        ld    s0, 8(sp)                 ; the data stack as it was
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; loop registers
        ld    s3, 32(sp)                ; ...
        ld    s4, 40(sp)                ; locals frame
        ld    t1, 48(sp)                ; unlink
        sd    t1, v_handler(zero)       ; v_handler = t1
        mv    t3, a0                    ; keep the code (spec_restore uses a0)
        addi  a0, sp, 56                ; the input source as it was
        call  spec_restore              ; call spec_restore
        addi  s0, s0, -8                ; push the code
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t3                    ; t3 is the new top
        ld    ra, 0(sp)                 ; CATCH's return address
        addi  sp, sp, CF_SIZE           ; drop the frame
        xret  ra                        ; CATCH returns n
th_none:                                ; no handler at all
        call  report_error              ; say so
        ld    t0, v_worker(zero)        ; a worker goes back to waiting for jobs
        beqz  t0, quit                  ; the main core starts over
        li    sp, RS_TOP                ; empty return stack
        la    t0, w_loop                ; the worker loop in .text
        jr    t0                        ; ...

; trap_entry: a hardware fault becomes THROW -(256 + cause)
trap_entry:                             ; tvec points here
        sd    t0, v_tsave(zero)         ; (a code unit's miss goes on: keep what we use)
        csrr  t0, cause                 ; why
        addi  t0, t0, -8                ; xmiss: the platform pages the unit in (StrataOS)
        beqz  t0, plat_miss             ;   and retries, or comes back to te_fault
te_fault:                               ; a fault
        csrr  t0, cause                 ; why
        sd    t0, v_tcause(zero)        ; remember for the message
        csrr  t1, epc                   ; where
        sd    t1, v_tepc(zero)          ; v_tepc = t1
        csrr  t1, tval                  ; what
        sd    t1, v_ttval(zero)         ; v_ttval = t1
        li    a0, -256                  ; code = -256 - cause
        sub   a0, a0, t0                ; ...
        j     throw_a0                  ; unwind to the innermost CATCH

; -----------------------------------------------------------------------------
; Files (platforms that have them: plat_load reads one into far memory)
; -----------------------------------------------------------------------------
; INCLUDED ( i*x addr u -- j*x ): interpret the file named addr u. Its text
; is read into far memory at v_ftop (a stack, for nested includes) and
; interpreted there line by line, like core.fs; errors say "file:line:".
p_included:                             ; Forth word
        addi  sp, sp, -32               ; frame: ra, the name slot, two saved cells
        sd    ra, 0(sp)                 ; save the return address
        ld    t0, v_fdepth(zero)        ; a name slot per nesting depth (the last one is shared)
        li    t1, 3                     ; ...
        bleu  t0, t1, ic_slot           ; ...
        mv    t0, t1                    ; ...
ic_slot:                                ; t0 = slot number
        slli  t0, t0, 5                 ; 32 bytes each
        la    t1, fnames                ; ...
        add   t1, t1, t0                ; t1 = the slot
        sd    t1, 8(sp)                 ; remember it
        mv    t2, s1                    ; t2 = name length, at most 31 are kept
        li    t3, 31                    ; ...
        bleu  t2, t3, ic_len            ; ...
        mv    t2, t3                    ; ...
ic_len:                                 ; t2 = bytes to copy
        sd    t2, 16(sp)                ; (for an error message)
        ld    t3, 0(s0)                 ; t3 = the name
        add   t4, t1, t2                ; zero-terminate the copy
        sb    zero, 0(t4)               ; ...
ic_copy:                                ; copy the name into the slot, last byte first
        beqz  t2, ic_load               ; done
        addi  t2, t2, -1                ; one fewer
        add   t4, t3, t2                ; source byte
        lbu   t5, 0(t4)                 ; ...
        add   t4, t1, t2                ; destination
        sb    t5, 0(t4)                 ; ...
        j     ic_copy                   ; continue
ic_load:                                ; read the file into far memory
        ld    a0, 0(s0)                 ; a0 = name
        mv    a1, s1                    ; a1 = its length
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        ld    a2, v_ftop(zero)          ; a2 = where the text goes
        call  reclaim                   ; c0 must be at home
        call  plat_load                 ; a0 = bytes, or a throw code
        bgez  a0, ic_run                ; loaded
        ld    t0, 8(sp)                 ; the message names the file:
        sd    t0, v_ename(zero)         ; "*** nofile.fs: no such file"
        ld    t1, 16(sp)                ; ...
        sd    t1, v_elen(zero)          ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 32                ; pop
        ld    t2, v_nofile(zero)        ; a word for names that are no file?
        beqz  t2, throw_a0              ; no: the error
        li    t3, -309                  ; and only for "no such file"
        bne   a0, t3, throw_a0          ; ...
        sd    zero, v_nofile(zero)      ; yes: once (it sets KVAR 39 again if it wants to)
        addi  s0, s0, -16               ; it gets the name back (still in memory there,
        mv    s1, t1                    ; its length cut to 31) and runs instead (a tail call
        addi  s0, s0, -8                ; through EXECUTE: it returns to INCLUDED's caller)
        sd    s1, 0(s0)                 ; ...
        mv    s1, t2                    ; ...
        j     p_execute                 ; ...
ic_run:                                 ; a0 = length of the text
        ld    t0, v_fname(zero)         ; keep the outer file's name
        sd    t0, 16(sp)                ; ...
        ld    t1, v_ftop(zero)          ; and where its text ends
        sd    t1, 24(sp)                ; ...
        ld    t0, 8(sp)                 ; errors now name this file
        sd    t0, v_fname(zero)         ; ...
        ld    t0, v_fdepth(zero)        ; one level deeper
        addi  t0, t0, 1                 ; ...
        sd    t0, v_fdepth(zero)        ; ...
        addi  t2, a0, 7                 ; the next file goes after this one's text,
        srli  t2, t2, 3                 ; 8-aligned
        slli  t2, t2, 3                 ; ...
        add   t2, t2, t1                ; ...
        sd    t2, v_ftop(zero)          ; ...
        addi  s0, s0, -24               ; push the offset, the length, the xt of evaluate-far
        sd    s1, 16(s0)                ; the old top goes to memory
        sd    t1, 8(s0)                 ; the offset
        sd    a0, 0(s0)                 ; the length
        la    s1, p_evalfar             ; the xt
        call  p_catch                   ; interpret the text, catching errors
        mv    a0, s1                    ; a0 = the throw code
        ld    s1, 0(s0)                 ; pop it
        addi  s0, s0, 8                 ; one cell off the data stack
        ld    t0, v_fdepth(zero)        ; back to the outer level
        addi  t0, t0, -1                ; ...
        sd    t0, v_fdepth(zero)        ; ...
        ld    t0, 24(sp)                ; its text ends where it did
        sd    t0, v_ftop(zero)          ; ...
        ld    t0, 16(sp)                ; and its name is current again
        sd    t0, v_fname(zero)         ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 32                ; pop
        bnez  a0, rethrow_a0            ; pass an error on (it knows where it happened)
        xret  ra                        ; done (it may page)

; tool_mark: remember the dictionary: data space, code space, the newest
; word, the hash buckets. tool_release forgets everything defined since.
; Both are also Forth words, (MARK) and (RELEASE) ( -- ): one level only.
tool_mark:                              ; clobbers t0..t6, a0..a5
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  flush_code                ; nothing staged: chere is where code really ends
        la    t0, msave                 ; the save area
        ld    t1, v_here(zero)          ; data space
        sd    t1, 0(t0)                 ; ...
        ld    t1, v_chere(zero)         ; code space
        sd    t1, 8(t0)                 ; ...
        ld    t1, v_latest(zero)        ; the newest word
        sd    t1, 16(t0)                ; ...
        la    t1, v_bucket              ; the bucket heads
        li    t2, NBUCKETS / 4          ; doublewords of them
tm_copy:                                ; copy them
        ld    t3, 0(t1)                 ; ...
        sd    t3, 24(t0)                ; ...
        addi  t0, t0, 8                 ; next
        addi  t1, t1, 8                 ; ...
        addi  t2, t2, -1                ; one fewer
        bnez  t2, tm_copy               ; continue
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
tool_release:                           ; leaf; clobbers t0..t3
        la    t0, msave                 ; the save area
        ld    t1, 0(t0)                 ; data space
        sd    t1, v_here(zero)          ; ...
        ld    t1, 8(t0)                 ; code space (nothing is staged)
        sd    t1, v_chere(zero)         ; ...
        sd    t1, v_cbase(zero)         ; ...
        ld    t1, 16(t0)                ; the newest word
        sd    t1, v_latest(zero)        ; ...
        la    t1, v_bucket              ; the bucket heads
        li    t2, NBUCKETS / 4          ; doublewords of them
tr_copy:                                ; copy them back
        ld    t3, 24(t0)                ; ...
        sd    t3, 0(t1)                 ; ...
        addi  t0, t0, 8                 ; next
        addi  t1, t1, 8                 ; ...
        addi  t2, t2, -1                ; one fewer
        bnez  t2, tr_copy               ; continue
        ret                             ; done

; (MSG) ( handle len mode op reg -- result ): one request to a server through
; endpoint register reg (StrataOS: 1 proc, 2 fs, 3 tty, 4 pipe, 6 the network
; server, looked up through proc each time), waiting for the answer; data moves with
; `5 tput` / `5 tget` at offset 64 of the message buffer. Bare metal: -306.
p_msg:                                  ; Forth word
        j     plat_msg                  ; tail call: the platform sends it

; (TOOL) ( i*x fa fu na nu -- j*x ): include the file fa fu, run the word
; na nu it defines, and forget the file again: a tool that costs no code
; space while it is not running (the interpreter calls this for a word the
; platform knows as a tool: `see`, `words`, ... under StrataOS)
p_tool:                                 ; Forth word
        addi  sp, sp, -40               ; frame: ra, word name, its length, nested?, throw code
        sd    ra, 0(sp)                 ; save the return address
        sd    s1, 8(sp)                 ; the word's length
        ld    t0, 0(s0)                 ; its name
        sd    t0, 16(sp)                ; ...
        ld    s1, 8(s0)                 ; leave ( fa fu )
        addi  s0, s0, 16                ; two cells off the data stack
        ld    t0, v_tooling(zero)       ; a tool using a tool? the outer one forgets both
        sd    t0, 24(sp)                ; ...
        bnez  t0, tl_load               ; nested: no mark
        call  tool_mark                 ; remember the dictionary
        li    t0, 1                     ; a tool is loaded
        sd    t0, v_tooling(zero)       ; ...
tl_load:                                ; include the file
        addi  s0, s0, -8                ; push the xt of INCLUDED
        sd    s1, 0(s0)                 ; the old top goes to memory
        la    s1, p_included            ; ...
        call  p_catch                   ; interpret the file, catching errors
        mv    a0, s1                    ; a0 = the throw code
        ld    s1, 0(s0)                 ; pop it
        addi  s0, s0, 8                 ; one cell off the data stack
        bnez  a0, tl_end                ; it failed
        ld    a0, 16(sp)                ; the word: it must exist now
        ld    a1, 8(sp)                 ; ...
        call  find_name                 ; a0 = header, or 0
        mv    t0, a0                    ; ...
        li    a0, -13                   ; undefined word, if the file did not define it
        beqz  t0, tl_end                ; ...
        mv    a0, t0                    ; push its xt
        call  hxt                       ; ...
        addi  s0, s0, -8                ; ...
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, a0                    ; ...
        call  p_catch                   ; run it (it parses its own arguments), catching errors
        mv    a0, s1                    ; a0 = the throw code
        ld    s1, 0(s0)                 ; pop it
        addi  s0, s0, 8                 ; one cell off the data stack
tl_end:                                 ; a0 = 0 or what went wrong
        sd    a0, 32(sp)                ; keep it
        ld    t0, 24(sp)                ; nested?
        bnez  t0, tl_out                ; yes: nothing to forget here
        beqz  a0, tl_rel                ; no error: no half-compiled definition
        call  rollback                  ; drop a definition the error left open
tl_rel:                                 ; forget the file
        call  tool_release              ; the dictionary as it was
        sd    zero, v_tooling(zero)     ; no tool loaded
tl_out:                                 ; pass an error on
        ld    a0, 32(sp)                ; the throw code
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 40                ; pop
        bnez  a0, rethrow_a0            ; (it knows where it happened)
        xret  ra                        ; done (it may page)

; -----------------------------------------------------------------------------
; QUIT: the read-interpret loop on the console
; -----------------------------------------------------------------------------
quit:                                   ; never returns
        li    sp, RS_TOP                ; empty return stack
        sd    zero, v_handler(zero)     ; no CATCH frames
q_loop:                                 ; one line per iteration
        sd    zero, v_srcid(zero)       ; the console is the source
        la    a0, tib                   ; read a line
        li    a1, 255                   ; a1 = 255
        call  accept_line               ; a0 = length, -1 at end of input
        bltz  a0, p_bye                 ; end of input: leave
        la    t0, tib                   ; the line is the input buffer
        sd    t0, v_src(zero)           ; v_src = t0
        sd    a0, v_srclen(zero)        ; v_srclen = a0
        sd    zero, v_in(zero)          ; clear v_in
        addi  s0, s0, -8                ; push the xt of INTERPRET
        sd    s1, 0(s0)                 ; the old top goes to memory
        la    s1, p_interpret           ; s1 = address of p_interpret
        call  p_catch                   ; run it, catching errors
        mv    a0, s1                    ; a0 = throw code
        ld    s1, 0(s0)                 ; pop it
        addi  s0, s0, 8                 ; one cell off the data stack
        bnez  a0, q_err                 ; an error
        la    a0, s_ok                  ; " ok"
        ld    t0, v_state(zero)         ; compiling?
        beqz  t0, q_say                 ; no
        la    a0, s_compiled            ; " compiled"
q_say:                                  ; a0 = the prompt
        call  out_str                   ; print it
        call  out_cr                    ; end the line
        j     q_loop                    ; next line
q_err:                                  ; something was thrown
        call  report_error              ; say what
        li    s0, DS_TOP                ; empty the data stack
        call  rollback                  ; drop a half-compiled definition
        j     q_loop                    ; next line

; rollback: forget the definition being compiled after an error
rollback:                               ; clobbers t0..t3, a0, a1
        ld    t0, v_open(zero)          ; is one open?
        beqz  t0, rb_state              ; no
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        ld    t0, v_curnt(zero)         ; its header (0 for :noname)
        beqz  t0, rb_code               ; no header
        addi  a0, t0, H_NAME            ; its name
        lbu   a1, H_NLEN(t0)            ; ...
        call  hash_name                 ; a0 = its bucket (it is the head)
        ld    t0, v_curnt(zero)         ; header
        lhu   t1, H_HASH(t0)            ; unlink from the bucket
        sh    t1, 0(a0)                 ; ...
        lhu   t1, H_LINK(t0)            ; and from the word list
        sd    t1, v_latest(zero)        ; v_latest = t1
        sd    t0, v_here(zero)          ; give its space back
rb_code:                                ; give the code space back
        ld    t0, v_cbase(zero)         ; where it started (staged alone: `:` installed the
        sd    t0, v_chere(zero)         ;   rest; v_curxt may be a quotation's)
        sd    zero, v_noname(zero)      ; (a paged :NONAME's xt is not pushed)
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; drop the frame
rb_state:                               ; back to interpreting
        sd    zero, v_open(zero)        ; clear v_open
        sd    zero, v_state(zero)       ; clear v_state
        sd    zero, v_nloc(zero)        ; clear v_nloc
        ret                             ; done

; report_error(a0 = throw code): one line describing the error
report_error:                           ; clobbers t0..t6, a0..a3
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the code
        li    t0, -1                    ; ABORT is silent
        beq   a0, t0, re_ret            ; ...
        ld    t0, v_col(zero)           ; start a fresh line
        beqz  t0, re_core               ; if t0 is zero, go to re_core
        call  out_cr                    ; call out_cr
re_core:                                ; on a worker, say which core
        ld    t0, v_worker(zero)        ; t0 = v_worker
        beqz  t0, re_where              ; the main core needs no prefix
        la    a0, s_core                ; "core "
        call  out_str                   ; call out_str
        csrr  a0, coreid                ; ...
        call  print_dec                 ; call print_dec
        la    a0, s_colon               ; ": "
        call  out_str                   ; call out_str
re_where:                               ; inside core.fs (or other far text)?
        ld    t0, v_esrc(zero)          ; source id at the throw
        li    t1, 1                     ; far text
        bne   t0, t1, re_stars          ; no
        ld    a0, v_efname(zero)        ; the file's name ("core.fs" for the embedded text)
        call  out_str                   ; call out_str
        li    a0, ':'                   ; a colon
        call  out_char                  ; call out_char
        ld    a0, v_eline(zero)         ; line
        call  print_dec                 ; call print_dec
        la    a0, s_colon               ; ": "
        call  out_str                   ; call out_str
re_stars:                               ; the message proper
        la    a0, s_stars               ; "*** "
        call  out_str                   ; call out_str
        ld    a0, 8(sp)                 ; code
        li    t0, -2                    ; ABORT" has its own message
        bne   a0, t0, re_word           ; ...
        ld    a0, v_amsg(zero)          ; the message
        ld    a1, v_amsg+8(zero)        ; ...
        call  out_type                  ; call out_type
        j     re_nl                     ; done
re_word:                                ; the offending word
        ld    a1, v_elen(zero)          ; a1 = v_elen
        beqz  a1, re_msg                ; none
        ld    a0, v_ename(zero)         ; a0 = v_ename
        call  out_type                  ; call out_type
        la    a0, s_colon               ; ": "
        call  out_str                   ; call out_str
re_msg:                                 ; the text for the code
        ld    a0, 8(sp)                 ; code
        li    t0, -256                  ; hardware faults are -256 - cause (cause 0..15)
        bgt   a0, t0, re_table          ; above: not a fault
        li    t0, -272                  ; t0 = -272
        ble   a0, t0, re_table          ; below: not a fault either
        la    a0, s_fault               ; "fault "
        call  out_str                   ; call out_str
        ld    t0, v_tcause(zero)        ; the cause names follow each other
        la    a0, s_causes              ; a0 = address of s_causes
re_cn:                                  ; skip t0 names
        beqz  t0, re_cname              ; found it
re_cs:                                  ; skip one name
        lbu   t1, 0(a0)                 ; ...
        addi  a0, a0, 1                 ; one more
        bnez  t1, re_cs                 ; up to its zero
        addi  t0, t0, -1                ; one fewer
        j     re_cn                     ; on to re_cn
re_cname:                               ; a0 = the cause's name
        call  out_str                   ; call out_str
        la    a0, s_atpc                ; " at pc "
        call  out_str                   ; call out_str
        ld    a0, v_tepc(zero)          ; a0 = v_tepc
        call  print_hex                 ; call print_hex
        la    a0, s_tval                ; ", tval "
        call  out_str                   ; call out_str
        ld    a0, v_ttval(zero)         ; a0 = v_ttval
        call  print_hex                 ; call print_hex
        j     re_nl                     ; done
re_table:                               ; look the code up
        sub   a2, zero, a0              ; a2 = -code
        la    a3, errtab                ; a3 = table cursor
re_tl:                                  ; entries: u16 code, text, 0
        lbu   t0, 0(a3)                 ; code, low byte
        lbu   t1, 1(a3)                 ; high byte
        slli  t1, t1, 8                 ; ...
        or    t0, t0, t1                ; ...
        beqz  t0, re_unknown            ; end of table
        addi  a0, a3, 2                 ; the text
        beq   t0, a2, re_text           ; this one
re_ts:                                  ; skip the text
        lbu   t1, 0(a0)                 ; ...
        addi  a0, a0, 1                 ; one more
        bnez  t1, re_ts                 ; if t1 is nonzero, go to re_ts
        mv    a3, a0                    ; next entry
        j     re_tl                     ; on to re_tl
re_text:                                ; print it
        call  out_str                   ; call out_str
        j     re_nl                     ; done
re_unknown:                             ; "error <n>"
        la    a0, s_error               ; a0 = address of s_error
        call  out_str                   ; call out_str
        ld    a0, 8(sp)                 ; ...
        call  print_dec                 ; call print_dec
re_nl:                                  ; end the line
        call  out_cr                    ; call out_cr
        call  out_flush                 ; and show it
re_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; -----------------------------------------------------------------------------
; Lending the image: c0 travels to a worker and comes back
; -----------------------------------------------------------------------------
; reclaim: if c0 is lent to a worker, take it back (the worker returns it
; right after loading the image, before it runs anything)
reclaim:                                ; clobbers t0
        ld    t0, v_lent(zero)          ; who has it
        bltz  t0, rc_home               ; we do
        ctake c7, t0                    ; take it back from that core only
        li    t0, -1                    ; home again
        sd    t0, v_lent(zero)          ; v_lent = t0
        j     plat_home                 ; tail call: the platform puts it back where it lives
rc_home:                                ; c0 is ours
        ret                             ; done

; publish: the workers' copy of the image: chere and the D-LS snapshot
publish:                                ; clobbers t0..t6, a0..a5
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  reclaim                   ; c0 at home
        call  plat_publish              ; the platform's part (StrataOS: a copy of the code)
        li    t0, FAR_SNAP              ; where the snapshot goes
        li    t1, SNAP_LEN              ; how much: D-LS below the data stack
        tput  tg13, zero, c0, t0, t1    ; D-LS -> far memory
        ld    t2, v_gen(zero)           ; a new generation
        addi  t2, t2, 1                 ; one more
        sd    t2, v_gen(zero)           ; v_gen = t2
        li    t0, B_GEN                 ; tell the board
        tamo.swap zero, c1, t0, t2      ; ...
        li    t0, B_CEND                ; the code end
        ld    t2, v_chere(zero)         ; t2 = v_chere
        tamo.swap zero, c1, t0, t2      ; ...
        li    t0, B_SNAP                ; the snapshot length
        tamo.swap zero, c1, t0, t1      ; ...
        ld    t0, v_epoch(zero)         ; published as of now
        sd    t0, v_pubep(zero)         ; v_pubep = t0
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; check_worker(a0 = core) -> a0 = board slot offset; throws if not a worker
check_worker:                           ; leaf; clobbers t0
        blez  a0, cw_bad                ; core 0 is us (and negatives are nonsense)
        ld    t0, v_ncores(zero)        ; cores we may use
        bgeu  a0, t0, cw_bad            ; out of range
        slli  a0, a0, 7                 ; * SLOT_SZ
        addi  a0, a0, B_SLOTS           ; + slots start
        ret                             ; done
cw_bad:                                 ; not one of our workers
        li    a0, -305                  ; no such core
        ld    t0, v_ncores(zero)        ; unless this Forth has one thread only:
        addi  t0, t0, -1                ; (a StrataOS process started without -n)
        bnez  t0, throw_a0              ; several cores: error -305
        ld    t0, v_plat(zero)          ; on bare metal one core is one core
        beqz  t0, throw_a0              ; error -305
        li    a0, -308                  ; say how to get more
        j     throw_a0                  ; error

; ?THREADS ( -- ): throw unless this Forth may talk to other cores (GIVE and TAKE
; of a single StrataOS thread would trap into the kernel)
p_qthreads:                             ; Forth word
        ld    t0, v_ncores(zero)        ; cores we may use
        addi  t0, t0, -1                ; more than one?
        bnez  t0, qt_ok                 ; yes
        ld    t0, v_plat(zero)          ; one bare-metal core: the hardware answers
        beqz  t0, qt_ok                 ; ...
        li    a0, -308                  ; one thread only
        j     throw_a0                  ; error
qt_ok:                                  ; fine
        ret                             ; done

; SPAWN ( x1..xn n xt core -- ): run xt on a worker with n arguments
p_spawn:                                ; Forth word
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s1, 8(sp)                 ; core
        ld    t0, 0(s0)                 ; xt
        sd    t0, 16(sp)                ; ...
        ld    t0, 8(s0)                 ; n
        sd    t0, 24(sp)                ; ...
        ld    s1, 16(s0)                ; pop the three
        addi  s0, s0, 24                ; three cells off the data stack
        li    t1, 8                     ; at most 8 arguments
        bgtu  t0, t1, sp_badn           ; ...
        ld    a0, 8(sp)                 ; core
        call  check_worker              ; valid?
        ld    t0, 8(sp)                 ; core
        slli  t0, t0, 3                 ; its busy flag
        ld    t1, v_busy(t0)            ; ...
        bnez  t1, sp_busy               ; still running a job
        call  out_flush                 ; our output first
        call  flush_code                ; everything installed
        ld    t0, v_epoch(zero)         ; anything run since the last publish?
        ld    t1, v_pubep(zero)         ; t1 = v_pubep
        beq   t0, t1, sp_fresh          ; no
        call  publish                   ; yes: publish a new image
sp_fresh:                               ; does the worker have this generation?
        ld    t0, 8(sp)                 ; core
        slli  t1, t0, 3                 ; ...
        ld    t2, v_wgen(t1)            ; its generation
        ld    t3, v_gen(zero)           ; current
        beq   t2, t3, sp_job            ; up to date
        sd    t3, v_wgen(t1)            ; it will be
        call  reclaim                   ; c0 home (it may be lent to another core)
        ld    t0, 8(sp)                 ; core
        call  plat_lend                 ; lend it the image (t0 = the core, kept)
        sd    t0, v_lent(zero)          ; remember who has it
sp_job:                                 ; write the job into its slot
        ld    a0, 8(sp)                 ; core
        call  check_worker              ; a0 = slot
        mv    a2, a0                    ; a2 = slot
        ld    t0, 24(sp)                ; n
        addi  t1, a2, S_NARGS           ; ...
        tamo.swap zero, c1, t1, t0      ; arguments
        ld    t0, 16(sp)                ; xt
        addi  t1, a2, S_XT              ; ...
        tamo.swap zero, c1, t1, t0      ; ...
        ld    t2, 24(sp)                ; i = n
sp_args:                                ; arguments, top of stack last
        beqz  t2, sp_go                 ; all written
        addi  t2, t2, -1                ; i - 1
        slli  t1, t2, 3                 ; its cell
        add   t1, t1, a2                ; ...
        addi  t1, t1, S_ARGS            ; ...
        tamo.swap zero, c1, t1, s1      ; the top of stack
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        j     sp_args                   ; next
sp_go:                                  ; ring the doorbell
        li    t0, CMD_RUN               ; command
        addi  t1, a2, S_CMD             ; ...
        tamo.swap zero, c1, t1, t0      ; ...
        ld    t0, 8(sp)                 ; core
        cgive c1, t0                    ; a copy of the board capability is the doorbell
        slli  t0, t0, 3                 ; mark it busy
        li    t1, 1                     ; t1 = 1
        sd    t1, v_busy(t0)            ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 32                ; pop
        ret                             ; done
sp_badn:                                ; too many arguments
        li    a0, -24                   ; invalid numeric argument
        j     throw_a0                  ; error
sp_busy:                                ; already running something
        li    a0, -302                  ; core busy
        j     throw_a0                  ; error

; AWAIT ( core -- y1..ym ): wait for a worker's job; its final stack (top 8)
p_await:                                ; Forth word
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s1, 8(sp)                 ; core
        mv    a0, s1                    ; valid?
        call  check_worker              ; call check_worker
        ld    s1, 0(s0)                 ; pop the core
        addi  s0, s0, 8                 ; one cell off the data stack
        ld    t0, 8(sp)                 ; core
        slli  t0, t0, 3                 ; busy?
        ld    t1, v_busy(t0)            ; ...
        beqz  t1, aw_idle               ; nothing to wait for
aw_take:                                ; take what it sends
        ld    t0, 8(sp)                 ; from that core only
        ctake c7, t0                    ; ...
        cperms t1, c7                   ; what is it?
        andi  t2, t1, P_X               ; the image coming back?
        beqz  t2, aw_tok                ; no
        call  plat_home                 ; the image is home (the platform knows where)
        li    t2, -1                    ; t2 = -1
        sd    t2, v_lent(zero)          ; v_lent = t2
        j     aw_take                   ; keep waiting for the doorbell
aw_tok:                                 ; the doorbell?
        andi  t2, t1, P_A               ; an atomics capability (the board)
        cclear c7                       ; drop it either way
        beqz  t2, aw_odd                ; something else: the job sent us a capability
        ld    t0, 8(sp)                 ; not busy any more
        slli  t0, t0, 3                 ; ...
        sd    zero, v_busy(t0)          ; ...
        ld    a0, 8(sp)                 ; its slot
        call  check_worker              ; call check_worker
        mv    a2, a0                    ; a2 = slot
        addi  t0, a2, S_NRES            ; results
        tamo.add t3, c1, t0, zero       ; t3 = how many
        li    t2, 0                     ; i = 0
aw_res:                                 ; push them, deepest first
        bgeu  t2, t3, aw_status         ; all pushed
        slli  t1, t2, 3                 ; cell i
        add   t1, t1, a2                ; ...
        addi  t1, t1, S_ARGS            ; ...
        tamo.add t4, c1, t1, zero       ; the value
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t4                    ; t4 is the new top
        addi  t2, t2, 1                 ; next
        j     aw_res                    ; on to aw_res
aw_status:                              ; the job's throw code
        addi  t0, a2, S_STATUS          ; ...
        tamo.add a0, c1, t0, zero       ; ...
        bnez  a0, aw_fail               ; it failed (it printed why)
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done
aw_fail:                                ; rethrow the worker's error here
        j     throw_a0                  ; on to throw_a0
aw_idle:                                ; nothing running there
        li    a0, -303                  ; core not running a job
        j     throw_a0                  ; error
aw_odd:                                 ; an unexpected capability (it was dropped)
        li    a0, -304                  ; unexpected capability
        j     throw_a0                  ; error

; worker_run: called by the worker loop in .text for each job
worker_run:                             ; on a worker core
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; back to the worker loop
        li    s0, DS_TOP                ; a fresh data stack
        li    s1, 0                     ; s1 = 0
        la    t0, trap_entry            ; faults become THROWs here too
        csrw  tvec, t0                  ; ...
        call  core_reset                ; our own trampolines, cache, flags
        li    t0, 1                     ; we are a worker
        sd    t0, v_worker(zero)        ; v_worker = t0
        sd    zero, v_elen(zero)        ; no word being interpreted
        csrr  t0, coreid                ; read the job from our slot
        slli  t0, t0, 7                 ; ...
        addi  a2, t0, B_SLOTS           ; a2 = slot
        addi  t0, a2, S_NARGS           ; argument count
        tamo.add t3, c1, t0, zero       ; t3 = n
        li    t2, 0                     ; i = 0
wr_args:                                ; push the arguments
        bgeu  t2, t3, wr_run            ; all pushed
        slli  t1, t2, 3                 ; cell i
        add   t1, t1, a2                ; ...
        addi  t1, t1, S_ARGS            ; ...
        tamo.add t4, c1, t1, zero       ; the value
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t4                    ; t4 is the new top
        addi  t2, t2, 1                 ; next
        j     wr_args                   ; on to wr_args
wr_run:                                 ; run the xt under CATCH
        addi  t0, a2, S_XT              ; the xt
        tamo.add t4, c1, t0, zero       ; ...
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t4                    ; t4 is the new top
        call  p_catch                   ; run
        mv    a0, s1                    ; a0 = throw code
        ld    s1, 0(s0)                 ; pop it
        addi  s0, s0, 8                 ; one cell off the data stack
        li    t0, DS_TOP                ; did the job pop more than it had?
        bgeu  t0, s0, wr_depth          ; no
        li    a0, -4                    ; stack underflow
        sd    zero, v_elen(zero)        ; (no word to blame)
wr_depth:                               ; a0 = the job's status
        addi  sp, sp, -8                ; keep the code
        sd    a0, 0(sp)                 ; ...
        beqz  a0, wr_ok                 ; fine
        call  report_error              ; say what went wrong ("core N: ...")
        li    s0, DS_TOP                ; no results
wr_ok:                                  ; return the top 8 cells of the stack
        csrr  t0, coreid                ; our slot again
        slli  t0, t0, 7                 ; ...
        addi  a2, t0, B_SLOTS           ; a2 = slot
        li    t0, DS_TOP                ; depth = (DS_TOP - s0) / 8
        sub   t3, t0, s0                ; ...
        srai  t3, t3, 3                 ; ...
        li    t0, 8                     ; at most 8
        bleu  t3, t0, wr_n              ; ...
        mv    t3, t0                    ; ...
wr_n:                                   ; t3 = results
        addi  t0, a2, S_NRES            ; ...
        tamo.swap zero, c1, t0, t3      ; ...
        mv    t2, t3                    ; i = n
wr_res:                                 ; top of stack goes to the highest cell
        beqz  t2, wr_status             ; done
        addi  t2, t2, -1                ; one fewer
        slli  t1, t2, 3                 ; cell i
        add   t1, t1, a2                ; ...
        addi  t1, t1, S_ARGS            ; ...
        tamo.swap zero, c1, t1, s1      ; ...
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        j     wr_res                    ; on to wr_res
wr_status:                              ; the throw code
        ld    t1, 0(sp)                 ; ...
        addi  sp, sp, 8                 ; drop the frame
        addi  t0, a2, S_STATUS          ; ...
        tamo.swap zero, c1, t0, t1      ; ...
        call  out_flush                 ; our output goes out before the doorbell
        cgive c1, zero                  ; ring core 0 (completes after our transfers)
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; to the worker loop

; BYE ( -- ): halt the workers, then this core
p_bye:                                  ; Forth word (also reached at end of input)
        call  out_flush                 ; everything printed
        ld    a4, v_ncores(zero)        ; cores
        li    a5, 1                     ; k = 1
by_loop:                                ; tell each worker to stop
        bgeu  a5, a4, by_done           ; all told
        slli  t0, a5, 7                 ; its slot
        addi  t0, t0, B_SLOTS + S_CMD   ; ...
        li    t1, CMD_HALT              ; halt
        tamo.swap zero, c1, t0, t1      ; ...
        cgive c1, a5                    ; ring
        addi  a5, a5, 1                 ; next
        j     by_loop                   ; on to by_loop
by_done:                                ; now us
        ld    a0, v_exit(zero)          ; the exit code
        j     plat_bye                  ; the platform stops this core / process

; -----------------------------------------------------------------------------
; xexec: run one instruction built at run time. Strata instructions name
; capability registers and tags in immediate fields, so a word like
; "tget through capability register n" is made by assembling the instruction
; and installing it into a trampoline (tput to the mirror + tgetx), cached:
; NTRAMP slots, direct mapped by a hash of the instruction.
; -----------------------------------------------------------------------------
; XEXEC ( a0 a1 a2 insn -- a0' ): run insn with a0..a2 loaded; result: a0
p_xexec:                                ; Forth word
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s1, 8(sp)                 ; the instruction
        srli  t0, s1, 11                ; hash: insn ^ insn >> 11 ^ insn >> 21
        xor   t0, t0, s1                ; ...
        srli  t1, s1, 21                ; ...
        xor   t0, t0, t1                ; ...
        andi  t0, t0, NTRAMP - 1        ; slot
        slli  t2, t0, 3                 ; its tag
        ld    t1, v_ttags(t2)           ; what it holds
        slli  t3, s1, 32                ; compare the low 32 bits only
        srli  t3, t3, 32                ; ...
        beq   t1, t3, xe_run            ; already installed
        sd    t3, v_ttags(t2)           ; it will hold this one
        sw    s1, v_tbuf(zero)          ; the instruction ...
        li    t1, I_RET                 ; ... followed by ret
        sw    t1, v_tbuf+4(zero)        ; ...
        call  reclaim                   ; c0 home
        ld    t0, 8(sp)                 ; recompute the slot address
        srli  t1, t0, 11                ; ...
        xor   t1, t1, t0                ; ...
        srli  t0, t0, 21                ; ...
        xor   t1, t1, t0                ; ...
        andi  t1, t1, NTRAMP - 1        ; ...
        slli  t1, t1, 3                 ; ...
        li    t2, TRAMP                 ; the trampolines' address (too large for an addi under StrataOS)
        add   t1, t1, t2                ; t1 = I-LS address (= its c0 offset)
        la    t2, v_tbuf                ; source
        li    t3, 8                     ; one doubleword
        ld    t4, v_moff(zero)          ; where the mirror is in c0: the address minus this
        sub   t4, t1, t4                ; (0 everywhere but in a StrataOS worker thread)
        tput  tg13, t2, c0, t4, t3      ; to the mirror
        tgetx tg13, t1, c0, t4, t3      ; into the I-LS
        ld    t0, v_xinst(zero)         ; count installs
        addi  t0, t0, 1                 ; one more
        sd    t0, v_xinst(zero)         ; v_xinst = t0
        ld    t0, 8(sp)                 ; slot number again
        srli  t1, t0, 11                ; ...
        xor   t1, t1, t0                ; ...
        srli  t0, t0, 21                ; ...
        xor   t0, t1, t0                ; ...
        andi  t0, t0, NTRAMP - 1        ; ...
xe_run:                                 ; t0 = slot
        slli  t0, t0, 3                 ; its address
        li    t1, TRAMP                 ; ...
        add   t0, t0, t1                ; ...
        ld    a2, 0(s0)                 ; operands
        ld    a1, 8(s0)                 ; ...
        ld    a0, 16(s0)                ; ...
        addi  s0, s0, 24                ; three popped; s1 is replaced below
        jalr  ra, t0, 0                 ; run the instruction
        mv    s1, a0                    ; result
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; -----------------------------------------------------------------------------
; The far cache: far@ far! farc@ farc! over the platform's heap capability.
; ltag finds a line in the tag table; a miss writes back a dirty victim and
; fetches the line (plat_fput / plat_fget), then linst records it.
; -----------------------------------------------------------------------------
; fc_wb(a0 = line index): write the line back if it is dirty
fc_wb:                                  ; clobbers t0..t6, a0..a2
        la    t0, fc_dirty              ; dirty?
        add   t0, t0, a0                ; ...
        lbu   t1, 0(t0)                 ; ...
        beqz  t1, fw_clean              ; no
        sb    zero, 0(t0)               ; it will be clean
        li    t2, FC_WAYS               ; set = index / ways, way = index % ways
        divu  t3, a0, t2                ; ...
        remu  t4, a0, t2                ; ...
        li    t2, FC_SPAN               ; tag entry = tags + set * span + 8 * way
        mul   t3, t3, t2                ; ...
        slli  t4, t4, 3                 ; ...
        add   t3, t3, t4                ; ...
        la    t2, fc_tags               ; t2 = address of fc_tags
        add   t3, t3, t2                ; ...
        ld    t3, 0(t3)                 ; the tag: line << 1 | 1
        srli  a1, t3, 1                 ; the line number
        slli  a1, a1, FC_LSH            ; its far address
        slli  a0, a0, FC_LSH            ; the line's D-LS address
        la    t2, fc_lines              ; t2 = address of fc_lines
        add   a0, a0, t2                ; ...
        li    a2, FC_LINE               ; one line
        ld    t0, v_fstat+16(zero)      ; count write-backs
        addi  t0, t0, 1                 ; one more
        sd    t0, v_fstat+16(zero)      ; ...
        j     plat_fput                 ; tail call: D-LS -> far
fw_clean:                               ; nothing to do
        ret                             ; done

; fc_addr(a0 = far address, a1 = 1 if writing) -> a0 = its D-LS address
fc_addr:                                ; clobbers t0..t6, a0..a2
        ltag  t0, a0                    ; look it up
        bltz  t0, fa_miss               ; bit 63: a miss (t0 = victim line)
        ld    t1, v_fstat(zero)         ; a hit
        addi  t1, t1, 1                 ; one more
        sd    t1, v_fstat(zero)         ; v_fstat = t1
        beqz  a1, fa_hit                ; reading: done
        la    t1, fc_lines              ; mark the line dirty
        sub   t1, t0, t1                ; ...
        srli  t1, t1, FC_LSH            ; line index
        la    t2, fc_dirty              ; t2 = address of fc_dirty
        add   t1, t1, t2                ; ...
        sb    a1, 0(t1)                 ; ...
fa_hit:                                 ; t0 = the byte
        mv    a0, t0                    ; ...
        ret                             ; done
fa_miss:                                ; fetch the line
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; far address
        sd    a1, 16(sp)                ; writing?
        slli  t0, t0, 1                 ; clear bit 63:
        srli  t0, t0, 1                 ; the victim line's D-LS address
        sd    t0, 24(sp)                ; ...
        la    t1, fc_lines              ; its index
        sub   a0, t0, t1                ; ...
        srli  a0, a0, FC_LSH            ; ...
        call  fc_wb                     ; write the victim back if dirty
        ld    a0, 24(sp)                ; the line
        ld    a1, 8(sp)                 ; far address
        srli  a1, a1, FC_LSH            ; of the whole line
        slli  a1, a1, FC_LSH            ; ...
        li    a2, FC_LINE               ; one line
        call  plat_fget                 ; far -> D-LS (loads below wait for it)
        ld    a0, 8(sp)                 ; record the line in the tag table
        linst a0                        ; ...
        ld    t1, v_fstat+8(zero)       ; count the miss
        addi  t1, t1, 1                 ; one more
        sd    t1, v_fstat+8(zero)       ; ...
        ld    t0, 24(sp)                ; line
        la    t1, fc_lines              ; dirty if writing
        sub   t1, t0, t1                ; ...
        srli  t1, t1, FC_LSH            ; ...
        la    t2, fc_dirty              ; t2 = address of fc_dirty
        add   t1, t1, t2                ; ...
        ld    a1, 16(sp)                ; ...
        sb    a1, 0(t1)                 ; ...
        ld    a0, 8(sp)                 ; the byte's address in the line
        andi  a0, a0, FC_LINE - 1       ; ...
        add   a0, a0, t0                ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 32                ; pop
        ret                             ; done

; -----------------------------------------------------------------------------
; Defining words
; -----------------------------------------------------------------------------
; stub(a0 = header, a1 = address, a2 = 1 to load through it): the 24-byte code
; of a CREATEd word (push a1) or a CONSTANT/VALUE (push the cell at a1)
cg_stub:                                ; clobbers t0..t3, t6, a0..a2
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a1, 8(sp)                 ; address
        sd    a2, 16(sp)                ; load?
        li    t0, PLAT_COMPACT          ; compact code?
        beqz  t0, cs_full               ; no: 24 bytes, all inline
        slli  a1, a1, 48                ; yes, 8 bytes: ori t1, zero, address
        srli  a1, a1, 48                ; (a D-LS address has 16 bits)
        li    a0, I_ORIT1Z              ; ...
        or    a0, a0, a1                ; ...
        call  cg                        ; call cg
        la    a1, k_var                 ; then j k_var (CREATE: push t1) ...
        ld    t0, 16(sp)                ; ...
        beqz  t0, cs_j                  ; ...
        la    a1, k_val                 ; ... or j k_val (CONSTANT, VALUE: push the cell at t1)
cs_j:                                   ; a1 = the target
        ld    t0, v_paged(zero)         ; in a unit: jalr zero, gp, target
        bnez  t0, cs_unit               ; ...
        li    a0, I_JMP                 ; jal zero, target (DOES> patches this one)
        call  jal_to                    ; a0 = the instruction
        call  cg                        ; call cg
        j     cs_done                   ; 8 bytes
k_var:                                  ; the shared body of a CREATEd word: push its address
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t1                    ; the address
        xret  ra                        ; done (a unit's stub was called by xcall)
k_val:                                  ; the shared body of a CONSTANT or VALUE
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, 0(t1)                 ; the cell
        xret  ra                        ; done
k_does:                                 ; the shared start of does-code (entered with jal t0
        addi  s0, s0, -8                ; (jalr t0, gp: paged) from the does-code, which the stub jumped to with
        sd    s1, 0(s0)                 ; t1 = the word's address): push the address,
        mv    s1, t1                    ; ...
        addi  sp, sp, -8                ; then the prologue
        sd    ra, 0(sp)                 ; save the return address
        jr    t0                        ; back into the does-code
cs_full:                                ; the inline form
        call  cg_push                   ; push
        ld    t3, 8(sp)                 ; address
        srli  t3, t3, 16                ; upper half
        ld    t0, 16(sp)                ; load?
        li    a0, I_LUI_S1              ; lui s1 (CREATE)
        beqz  t0, cs_1                  ; if t0 is zero, go to cs_1
        li    a0, I_LUIT0               ; lui t0 (CONSTANT, VALUE)
cs_1:                                   ; ...
        or    a0, a0, t3                ; ...
        call  cg                        ; call cg
        ld    t3, 8(sp)                 ; lower half
        andi  t3, t3, 0xFFFF            ; ...
        ld    t0, 16(sp)                ; ...
        li    a0, I_ORI_S1              ; ori s1, s1
        beqz  t0, cs_2                  ; if t0 is zero, go to cs_2
        li    a0, I_ORIT0               ; ori t0, t0
cs_2:                                   ; ...
        or    a0, a0, t3                ; ...
        call  cg                        ; call cg
        ld    t0, 16(sp)                ; ...
        beqz  t0, cs_3                  ; CREATE: ret, nop (does> patches the ret)
        li    a0, I_LDS1T0              ; ld s1, 0(t0)
        li    a1, I_RET                 ; ret
        call  cg2                       ; call cg2
        j     cs_done                   ; on to cs_done
cs_3:                                   ; ...
        li    a0, I_RET                 ; ret
        li    a1, I_NOP                 ; nop
        call  cg2                       ; call cg2
cs_done:                                ; 24 bytes (8 when compact)
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done

; new_word -> a0 = header of a new visible word named by the next input word,
; with chere 8-aligned as its xt
new_word:                               ; clobbers t0..t6, a0..a5
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  cg_align                  ; xts are 8-aligned
        ld    t0, v_paged(zero)         ; paged: a 16-byte stub must not cross into the
        beqz  t0, nw_name               ;   next unit (a definition moves at `;` instead)
        j     nw_unit                   ; (see kpage)
nw_name:                                ; ...
        call  parse_name                ; the name
        sd    a0, v_ename(zero)         ; (for error messages)
        sd    a1, v_elen(zero)          ; v_elen = a1
        call  make_header               ; a0 = header
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; CREATE ( "name" -- )
p_create:                               ; Forth word
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  new_word                  ; a0 = header
        sd    a0, 8(sp)                 ; ...
        li    t0, F_CREATE              ; compiles as a literal
        sb    t0, H_FLAGS(a0)           ; ...
        li    t0, 24 - 16 * PLAT_COMPACT ; code size (the compact stub has 8 bytes, 16 in a unit)
        ld    t1, v_paged(zero)         ; ...
        slli  t1, t1, 3                 ; ...
        add   t0, t0, t1                ; ...
        sh    t0, H_SIZE(a0)            ; ...
        ld    a1, v_here(zero)          ; data field = HERE
        li    a2, 0                     ; push the address
        call  cg_stub                   ; the code
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; CONSTANT ( x "name" -- ) and VALUE ( x "name" -- ) share this
p_constant:                             ; Forth word
        li    a3, F_CONST               ; compiles as the value
        j     cv_common                 ; on to cv_common
p_value:                                ; Forth word
        li    a3, F_VALUE               ; compiles as a load
cv_common:                              ; a3 = flags
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a3, 8(sp)                 ; ...
        call  new_word                  ; a0 = header
        ld    t0, 8(sp)                 ; flags
        sb    t0, H_FLAGS(a0)           ; ...
        li    t0, 24 - 16 * PLAT_COMPACT ; code size (the compact stub has 8 bytes)
        sh    t0, H_SIZE(a0)            ; ...
        ld    a1, v_here(zero)          ; data field
        sd    s1, 0(a1)                 ; holds x
        addi  t0, a1, 8                 ; HERE past it
        sd    t0, v_here(zero)          ; v_here = t0
        ld    s1, 0(s0)                 ; pop x
        addi  s0, s0, 8                 ; one cell off the data stack
        li    a2, 1                     ; load through the address
        call  cg_stub                   ; the code
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done

; : ( "name" -- )
p_colon:                                ; Forth word
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  flush_code                ; install CREATE stubs etc.; chere aligned
        call  new_word                  ; a0 = header
        lbu   t0, H_FLAGS(a0)           ; hide it until ;
        ori   t0, t0, F_HIDDEN          ; ...
        sb    t0, H_FLAGS(a0)           ; ...
        sd    a0, v_curnt(zero)         ; being defined
        ld    t0, v_chere(zero)         ; its code
        sd    t0, v_curxt(zero)         ; v_curxt = t0
        call  begin_def                 ; compile state, prologue
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; :NONAME ( -- xt )
p_noname:                               ; Forth word
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  flush_code                ; chere aligned
        ld    t0, v_chere(zero)         ; the xt
        sd    t0, v_curxt(zero)         ; v_curxt = t0
        sd    zero, v_curnt(zero)       ; no header
        ld    t1, v_paged(zero)         ; paged: `;` pushes it, where it put the definition
        sd    t1, v_noname(zero)        ; ...
        bnez  t1, nn_def                ; ...
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
nn_def:                                 ; ...
        call  begin_def                 ; compile state, prologue
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; ; ( -- ): end the definition (immediate)
p_semi:                                 ; Forth word
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        ld    t0, v_open(zero)          ; is one open?
        beqz  t0, p_mismatch            ; no
        li    a0, 1                     ; a call right before ; becomes a jump
        call  cg_exit                   ; epilogue
        call  end_def                   ; reveal and install
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
p_mismatch:                             ; ; without :
        li    a0, -22                   ; control structure mismatch
        j     throw_a0                  ; error

; EXIT ( -- ): compile a return (immediate)
p_exit:                                 ; Forth word
        li    a0, 0                     ; no tail call
        j     cg_exit                   ; tail call

; DOES> ( -- ): compile (does>), end this part, start the does-code (immediate)
p_does:                                 ; Forth word
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        ld    t0, v_paged(zero)         ; paged: the does-code's address is a literal,
        bnez  t0, ds_unit               ;   for (does>x)
        la    a0, p_pdoes               ; call (does>)
        call  cg_call                   ; call cg_call
        li    a0, 2                     ; then return, always in full (12 bytes: ld, addi, ret)
        call  cg_exit                   ; call cg_exit
        sd    zero, v_nloc(zero)        ; the does-code has no locals
        li    t0, PLAT_COMPACT          ; compact code?
        bnez  t0, ds_short              ; yes
        call  cg_pro                    ; the does-code's prologue (its stub pushed the address)
        j     ds_pro                    ; ...
ds_short:                               ; one instruction pushes the address and saves ra
        li    a0, I_JALT0               ; jal t0, k_does
        la    a1, k_does                ; ...
        call  jal_to                    ; a0 = the instruction
        call  cg                        ; call cg
ds_pro:                                 ; the does-code proper follows
        sd    zero, v_litend(zero)      ; nothing to fold across
        sd    zero, v_callend(zero)     ; clear v_callend
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done
; (does>): at run time of a defining word, make the newest word jump to the
; does-code (12 bytes past our return address) instead of returning
p_pdoes:                                ; Forth word
        addi  a0, ra, 12                ; the does-code
        ld    t0, v_latest(zero)        ; the word CREATE just made
        lbu   t1, H_FLAGS(t0)           ; it is no longer a plain address
        andi  t1, t1, 0xFF ^ (F_CREATE | F_INL) ; ...
        sb    t1, H_FLAGS(t0)           ; ...
        lhu   t2, H_XT(t0)              ; its stub
        srli  t3, t2, 15                ; in a unit (H_XT < 0x8000 under StrataOS)?
        li    t4, PLAT_PAGE             ; ...
        bgeu  t3, t4, pd_res            ; no
        j     pd_unit                   ; yes: see there (kpage)
pd_res:                                 ; resident
        addi  t2, t2, 16 - 12 * PLAT_COMPACT ; the stub's ret (compact: its jump, 4 bytes in)
        sub   t3, a0, t2                ; jal zero, does-code
        srai  t3, t3, 2                 ; ...
        slli  t3, t3, 43                ; ...
        srli  t3, t3, 43                ; ...
        li    t4, I_JMP                 ; t4 = I_JMP
        or    t3, t3, t4                ; ...
pd_put:                                 ; t3 = the instruction for address t2
        ld    t4, v_cbase(zero)         ; still staged?
        bltu  t2, t4, pd_far            ; no: patch the installed code
        sub   t5, t2, t4                ; staging offset
        la    t6, stage                 ; t6 = address of stage
        add   t6, t6, t5                ; ...
        sw    t3, 0(t6)                 ; patch
        ret                             ; back into the defining word
pd_far:                                 ; already installed
        mv    a0, t3                    ; instruction
        mv    a1, t2                    ; address
        addi  sp, sp, -8                ; keep our return address
        sd    ra, 0(sp)                 ; save the return address
        call  code_patch                ; call code_patch
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; back into the defining word

; POSTPONE ( "name" -- ) (immediate)
p_postpone:                             ; Forth word
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  parse_name                ; the name
        sd    a0, v_ename(zero)         ; v_ename = a0
        sd    a1, v_elen(zero)          ; v_elen = a1
        call  find_name                 ; a0 = header
        beqz  a0, in_u13                ; unknown
        lbu   t0, H_FLAGS(a0)           ; immediate?
        andi  t0, t0, F_IMM             ; ...
        bnez  t0, pp_imm                ; yes: compile a call to it
        call  cg_lit                    ; no: compile "header compile-name"
        la    a0, p_compname            ; a0 = address of p_compname
        la    a1, h_plain               ; (a word that does not page)
        call  cg_target                 ; call it
        j     pp_ret                    ; on to pp_ret
pp_imm:                                 ; an immediate word
        mv    a1, a0                    ; ...
        call  hxt                       ; ...
        call  cg_target                 ; call it
pp_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; COMPILE-NAME ( nt -- ): compile one use of the word, as the compiler would
p_compname:                             ; Forth word
        mv    a0, s1                    ; header
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        j     compile_nt                ; tail call

; ' ( "name" -- xt )
p_tick:                                 ; Forth word
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  parse_name                ; the name
        sd    a0, v_ename(zero)         ; v_ename = a0
        sd    a1, v_elen(zero)          ; v_elen = a1
        call  find_name                 ; a0 = header
        beqz  a0, in_u13                ; unknown
        call  hxt                       ; its xt
        mv    t0, a0                    ; ...
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; -----------------------------------------------------------------------------
; Small compiler words
; -----------------------------------------------------------------------------
p_lbrack:                               ; [ ( -- ): interpret (immediate)
        sd    zero, v_state(zero)       ; STATE = 0
        ret                             ; done
p_rbrack:                               ; ] ( -- ): compile
        li    t0, -1                    ; STATE = -1
        sd    t0, v_state(zero)         ; v_state = t0
        ret                             ; done
p_literal:                              ; LITERAL ( x -- ) (immediate)
        mv    a0, s1                    ; the value
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        j     cg_lit                    ; tail call: compile it
p_compile:                              ; COMPILE, ( xt -- ): compile a call
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s1, 8(sp)                 ; the xt
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        ld    a0, 8(sp)                 ; its header, for how to call it (0: none)
        call  xt_name                   ; ...
        mv    a1, a0                    ; ...
        ld    a0, 8(sp)                 ; ...
        call  cg_target                 ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done
p_xtlit:                                ; XTLITERAL ( xt -- ): compile it as a literal (immediate
        ld    t0, v_paged(zero)         ;   use: ;] ); paged, an xt in this definition is a
        beqz  t0, p_literal             ;   lui, ori pair that moves with it at `;`
        j     xl_unit                   ; (see kpage)
p_insn:                                 ; INSN, ( u -- ): compile one instruction
        mv    a0, s1                    ; the instruction
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        j     cg                        ; tail call
p_recurse:                              ; RECURSE ( -- ) (immediate)
        ld    a0, v_curxt(zero)         ; the definition being compiled
        ld    a1, v_curnt(zero)         ; (its header: 0 for :NONAME)
        j     cg_target                 ; tail call
p_immediate:                            ; IMMEDIATE ( -- )
        ld    t0, v_latest(zero)        ; newest word
        lbu   t1, H_FLAGS(t0)           ; ...
        ori   t1, t1, F_IMM             ; ...
        sb    t1, H_FLAGS(t0)           ; ...
        ret                             ; done
p_backslash:                            ; \ ( -- ): comment to the end of the line (immediate)
        ld    t0, v_srclen(zero)        ; >IN = end
        sd    t0, v_in(zero)            ; v_in = t0
        ret                             ; done
p_paren:                                ; ( ( -- ): comment up to ) (immediate)
        li    a0, ')'                   ; delimiter
        j     parse_char                ; tail call (result ignored)
p_mark:                                 ; MARK ( -- dest ): a branch target here
        sd    zero, v_litend(zero)      ; nothing folds across a label
        sd    zero, v_callend(zero)     ; clear v_callend
        ld    t0, v_chere(zero)         ; chere
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
        ret                             ; done
p_ifc:                                  ; IF, ( -- orig ): pop; branch forward if zero
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        li    a0, I_MVT0                ; mv t0, s1
        li    a1, I_POP1                ; ld s1, 0(s0)
        call  cg2                       ; call cg2
        li    a0, I_POP2                ; addi s0, s0, 8
        call  cg                        ; call cg
        ld    t0, v_chere(zero)         ; orig = the branch
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
        li    a0, I_BEQZT0              ; beq t0, zero, (resolved later)
        call  cg                        ; call cg
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
p_aheadc:                               ; AHEAD, ( -- orig ): jump forward
        ld    t0, v_chere(zero)         ; orig
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
        li    a0, I_JMP                 ; jal zero, (resolved later)
        j     cg                        ; tail call
p_resolve:                              ; RESOLVE ( orig dest -- ): aim the branch at orig to dest
        mv    a1, s1                    ; a1 = dest
        ld    a0, 0(s0)                 ; a0 = orig
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        sd    zero, v_litend(zero)      ; dest may be here: a label
        sd    zero, v_callend(zero)     ; clear v_callend
        ld    t0, v_cbase(zero)         ; the branch must still be staged
        bltu  a0, t0, rs_bad            ; ...
        sub   t1, a0, t0                ; its staging offset
        la    t2, stage                 ; t2 = address of stage
        add   t2, t2, t1                ; t2 = its address
        lw    t3, 0(t2)                 ; t3 = the branch
        sub   t4, a1, a0                ; distance
        srai  t4, t4, 2                 ; in instructions
        srli  t5, t3, 26                ; opcode
        andi  t5, t5, 63                ; ...
        li    t6, OP_JAL                ; a jal has 21 offset bits
        beq   t5, t6, rs_jal            ; ...
        srli  t3, t3, 16                ; a branch has 16: clear them
        slli  t3, t3, 16                ; ...
        andi  t4, t4, 0xFFFF            ; ...
        or    t3, t3, t4                ; ...
        sw    t3, 0(t2)                 ; patched
        ret                             ; done
rs_jal:                                 ; jal
        srli  t3, t3, 21                ; clear the offset
        slli  t3, t3, 21                ; ...
        slli  t4, t4, 43                ; 21 bits
        srli  t4, t4, 43                ; ...
        or    t3, t3, t4                ; ...
        sw    t3, 0(t2)                 ; patched
        ret                             ; done
rs_bad:                                 ; not in this definition
        li    a0, -22                   ; control structure mismatch
        j     throw_a0                  ; error
p_prologue:                             ; PROLOGUE, ( -- ): save ra (for quotations)
        j     cg_pro                    ; tail call
p_epilogue:                             ; EPILOGUE, ( -- ): restore ra and return
        j     cg_ret                    ; tail call
p_codeat:                               ; CODE@ ( a -- insn ): read code back from the far mirror
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  reclaim                   ; c0 home
        srli  t0, s1, 3                 ; its doubleword
        slli  t0, t0, 3                 ; ...
        la    t1, v_tbuf                ; t1 = address of v_tbuf
        li    t2, 8                     ; t2 = 8
        tget  tg13, t1, c0, t0, t2      ; far mirror -> D-LS
        andi  t3, s1, 4                 ; which half
        add   t3, t3, t1                ; ...
        lwu   s1, 0(t3)                 ; the instruction (waits for the tget)
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
p_codestore:                            ; CODE! ( insn a -- ): change code (staged or installed)
        mv    a1, s1                    ; address
        ld    a0, 0(s0)                 ; instruction
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        ld    t0, v_cbase(zero)         ; staged?
        bltu  a1, t0, code_patch        ; no: tail call, patch through far memory
        sub   t1, a1, t0                ; staging offset
        la    t2, stage                 ; t2 = address of stage
        add   t2, t2, t1                ; ...
        sw    a0, 0(t2)                 ; patch
        ret                             ; done
p_install:                              ; INSTALL ( -- ): install staged code now
        j     flush_code                ; tail call
p_plocal:                               ; (LOCAL) ( addr u -- ): declare a local
        ld    t0, v_nloc(zero)          ; count
        li    t1, 16                    ; at most 16
        bgeu  t0, t1, pl_many           ; ...
        slli  t2, t0, 4                 ; entry
        la    t3, locnames              ; t3 = address of locnames
        add   t2, t2, t3                ; ...
        li    t1, 15                    ; names are cut to 15 characters
        bleu  s1, t1, pl_len            ; ...
        mv    s1, t1                    ; t1 is the new top
pl_len:                                 ; s1 = length
        sb    s1, 0(t2)                 ; ...
        ld    t3, 0(s0)                 ; name
        li    t4, 0                     ; i
pl_copy:                                ; copy it
        bgeu  t4, s1, pl_done           ; ...
        add   t5, t3, t4                ; ...
        lbu   t5, 0(t5)                 ; ...
        add   t6, t2, t4                ; ...
        sb    t5, 1(t6)                 ; ...
        addi  t4, t4, 1                 ; one more
        j     pl_copy                   ; on to pl_copy
pl_done:                                ; one more local
        addi  t0, t0, 1                 ; one more
        sd    t0, v_nloc(zero)          ; v_nloc = t0
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        ret                             ; done
pl_many:                                ; too many
        li    a0, -307                  ; too many locals
        j     throw_a0                  ; error
p_localq:                               ; LOCAL? ( addr u -- i -1 | 0 )
        mv    a1, s1                    ; length
        ld    a0, 0(s0)                 ; name
        addi  s0, s0, 8                 ; pop one (the other is replaced)
        addi  sp, sp, -8                ; frame (local_find clobbers every t register)
        sd    ra, 0(sp)                 ; save the return address
        call  local_find                ; a0 = index or -1
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        bltz  a0, lq_no                 ; not a local
        mv    s1, a0                    ; index
        addi  s0, s0, -8                ; push -1
        sd    s1, 0(s0)                 ; the old top goes to memory
        li    s1, -1                    ; s1 = -1
        ret                             ; done
lq_no:                                  ; not found
        li    s1, 0                     ; 0
        ret                             ; done

; -----------------------------------------------------------------------------
; Data space, parsing, dictionary access
; -----------------------------------------------------------------------------
p_here:                                 ; HERE ( -- addr )
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, v_here(zero)          ; s1 = v_here
p_here_e:                               ; (inline body ends here)
        ret                             ; done
p_allot:                                ; ALLOT ( n -- )
        ld    t0, v_here(zero)          ; HERE
        add   t0, t0, s1                ; + n
        li    t1, DS_BOTTOM - 16        ; must stay below the data stack
        bgeu  t0, t1, al_full           ; ...
        sd    t0, v_here(zero)          ; v_here = t0
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        ret                             ; done
al_full:                                ; out of data space
        li    a0, -8                    ; dictionary overflow
        j     throw_a0                  ; error
p_comma:                                ; , ( x -- )
        ld    t0, v_here(zero)          ; HERE
        sd    s1, 0(t0)                 ; store
        addi  t0, t0, 8                 ; advance
        li    t1, DS_BOTTOM - 16        ; room?
        bgeu  t0, t1, al_full           ; ...
        sd    t0, v_here(zero)          ; v_here = t0
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        ret                             ; done
p_ccomma:                               ; C, ( c -- )
        ld    t0, v_here(zero)          ; HERE
        sb    s1, 0(t0)                 ; store
        addi  t0, t0, 1                 ; advance
        sd    t0, v_here(zero)          ; v_here = t0
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        ret                             ; done
p_align:                                ; ALIGN ( -- )
        ld    t0, v_here(zero)          ; HERE
        addi  t0, t0, 7                 ; round up
        srli  t0, t0, 3                 ; ...
        slli  t0, t0, 3                 ; ...
        sd    t0, v_here(zero)          ; v_here = t0
        ret                             ; done
p_latest:                               ; LATEST ( -- nt )
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, v_latest(zero)        ; s1 = v_latest
p_latest_e:                             ; (inline body ends here)
        ret                             ; done
p_chere:                                ; CHERE ( -- a ): next code address
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, v_chere(zero)         ; s1 = v_chere
p_chere_e:                              ; (inline body ends here)
        ret                             ; done
p_source:                               ; SOURCE ( -- addr u )
        addi  s0, s0, -16               ; push two
        sd    s1, 8(s0)                 ; ...
        ld    t0, v_src(zero)           ; t0 = v_src
        sd    t0, 0(s0)                 ; ...
        ld    s1, v_srclen(zero)        ; s1 = v_srclen
        ret                             ; done
p_parsename:                            ; PARSE-NAME ( -- addr u )
        addi  sp, sp, -8                ; frame (parse_name clobbers every t register)
        sd    ra, 0(sp)                 ; save the return address
        call  parse_name                ; a0/a1
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        addi  s0, s0, -16               ; push both
        sd    s1, 8(s0)                 ; ...
        sd    a0, 0(s0)                 ; ...
        mv    s1, a1                    ; a1 is the new top
        ret                             ; done
p_parse:                                ; PARSE ( c -- addr u )
        mv    a0, s1                    ; delimiter
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  parse_char                ; a0/a1
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        addi  s0, s0, -8                ; push the address (the length replaces c)
        sd    a0, 0(s0)                 ; ...
        mv    s1, a1                    ; a1 is the new top
        ret                             ; done
p_findname:                             ; FIND-NAME ( addr u -- nt | 0 )
        mv    a1, s1                    ; length
        ld    a0, 0(s0)                 ; name
        addi  s0, s0, 8                 ; pop one
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  find_name                 ; call find_name
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        mv    s1, a0                    ; result
        ret                             ; done
p_numberq:                              ; NUMBER? ( addr u -- n -1 | 0 )
        mv    a1, s1                    ; length
        ld    a0, 0(s0)                 ; text
        mv    t6, ra                    ; number is a leaf that leaves t6 alone
        call  number                    ; a0 = value, a1 = ok
        mv    ra, t6                    ; ...
        beqz  a1, nq_no                 ; not a number
        sd    a0, 0(s0)                 ; value
        li    s1, -1                    ; true
        ret                             ; done
nq_no:                                  ; not a number
        addi  s0, s0, 8                 ; drop the address
        li    s1, 0                     ; false
        ret                             ; done
p_namext:                               ; NAME>XT ( nt -- xt ): its code (a unit's: a far offset)
        mv    a0, s1                    ; ...
        mv    t6, ra                    ; (hxt is a leaf)
        call  hxt                       ; ...
        mv    ra, t6                    ; ...
        mv    s1, a0                    ; ...
        ret                             ; done
p_xtname:                               ; XT>NAME ( xt -- nt | 0 )
        mv    a0, s1                    ; ...
        mv    t6, ra                    ; (xt_name is a leaf)
        call  xt_name                   ; ...
        mv    ra, t6                    ; ...
        mv    s1, a0                    ; ...
        ret                             ; done

; -----------------------------------------------------------------------------
; Input and output words
; -----------------------------------------------------------------------------
p_emit:                                 ; EMIT ( c -- )
        mv    a0, s1                    ; the character
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        j     out_char                  ; tail call
p_type:                                 ; TYPE ( addr u -- )
        mv    a1, s1                    ; length
        ld    a0, 0(s0)                 ; address
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        j     out_type                  ; tail call
p_flush:                                ; FLUSH ( -- ): send buffered output now
        j     out_flush                 ; tail call

; SLIT, ( addr u -- ) and DOTQ, ( addr u -- ): compile a string literal (the
; string is in data space already): three instructions,
;   ori t1, zero, addr ; addi t2, zero, u ; jal k_slit   (S": push both)
;   ori t1, zero, addr ; addi t2, zero, u ; jal k_dotq   (.": print it)
p_dotqc:                                ; Forth word
        la    a2, k_dotq                ; the helper that prints
        j     sl_common                 ; shared
p_slitc:                                ; Forth word
        la    a2, k_slit                ; the helper that pushes
sl_common:                              ; a2 = the helper
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a2, 8(sp)                 ; the helper
        ld    a0, 0(s0)                 ; the address (16 bits: data space)
        slli  a0, a0, 48                ; ...
        srli  a0, a0, 48                ; ...
        li    t0, I_ORIT1Z              ; ori t1, zero, addr
        or    a0, a0, t0                ; ...
        slli  a1, s1, 49                ; the length (15 bits)
        srli  a1, a1, 49                ; ...
        li    t0, I_LIT2                ; addi t2, zero, u
        or    a1, a1, t0                ; ...
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        call  cg2                       ; compile the two
        ld    a0, 8(sp)                 ; and the call (resident: jal, and a `;` right
        la    a1, h_plain               ;   after it makes it a jump; paged: jalr gp)
        call  cg_target                 ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done
k_slit:                                 ; run time of S": push t1 (address), t2 (length)
        addi  s0, s0, -16               ; two cells
        sd    s1, 8(s0)                 ; the old top goes to memory
        sd    t1, 0(s0)                 ; the address
        mv    s1, t2                    ; the length
        ret                             ; done
k_dotq:                                 ; run time of .": print t2 bytes at t1
        mv    a0, t1                    ; the address
        mv    a1, t2                    ; the length
        j     out_type                  ; tail call
p_key:                                  ; KEY ( -- c )
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  key_in                    ; a0 = the byte
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        addi  s0, s0, -8                ; push it
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, a0                    ; a0 is the new top
        ret                             ; done
p_accept:                               ; ACCEPT ( addr n -- n2 )
        mv    a1, s1                    ; capacity
        ld    a0, 0(s0)                 ; buffer
        addi  s0, s0, 8                 ; pop one
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  accept_line               ; a0 = length or -1
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        bgez  a0, ac_ok                 ; a line
        li    a0, 0                     ; end of input reads as an empty line
ac_ok:                                  ; ...
        mv    s1, a0                    ; length
        ret                             ; done
p_dot:                                  ; . ( n -- ): signed, in BASE, then a space
        li    a2, 1                     ; signed
        j     dot_common                ; on to dot_common
p_udot:                                 ; U. ( u -- )
        li    a2, 0                     ; unsigned
dot_common:                             ; a2 = signed?
        mv    a0, s1                    ; the number
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        ld    a1, v_base(zero)          ; base
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  fmt_num                   ; text
        call  out_type                  ; print
        call  out_space                 ; and a space
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done

; -----------------------------------------------------------------------------
; Machine words: stacks, memory blocks, time, the far cache, cores
; -----------------------------------------------------------------------------
p_pick:                                 ; PICK ( xu..x0 u -- xu..x0 xu )
        slli  t0, s1, 3                 ; 8u
        add   t0, t0, s0                ; address of xu
        ld    s1, 0(t0)                 ; ...
p_pick_e:                               ; (inline body ends here)
        ret                             ; done
p_fill:                                 ; FILL ( addr u c -- )
        ld    t0, 8(s0)                 ; addr
        ld    t1, 0(s0)                 ; u
        add   t1, t1, t0                ; end
fi_loop:                                ; ...
        bgeu  t0, t1, fi_done           ; ...
        sb    s1, 0(t0)                 ; ...
        addi  t0, t0, 1                 ; one more
        j     fi_loop                   ; on to fi_loop
fi_done:                                ; ...
        ld    s1, 16(s0)                ; pop three
        addi  s0, s0, 24                ; three cells off the data stack
        ret                             ; done
p_move:                                 ; MOVE ( src dst u -- ): overlap-safe byte copy
        ld    t0, 8(s0)                 ; src
        ld    t1, 0(s0)                 ; dst
        mv    t2, s1                    ; u
        ld    s1, 16(s0)                ; pop three
        addi  s0, s0, 24                ; three cells off the data stack
        beqz  t2, mv_done               ; nothing
        bltu  t1, t0, mv_fwd            ; dst below src: forwards is safe
        add   t0, t0, t2                ; else backwards from the ends
        add   t1, t1, t2                ; ...
mv_back:                                ; ...
        addi  t0, t0, -1                ; one fewer
        addi  t1, t1, -1                ; one fewer
        lbu   t3, 0(t0)                 ; ...
        sb    t3, 0(t1)                 ; ...
        addi  t2, t2, -1                ; one fewer
        bnez  t2, mv_back               ; if t2 is nonzero, go to mv_back
        ret                             ; done
mv_fwd:                                 ; forwards
        lbu   t3, 0(t0)                 ; ...
        sb    t3, 0(t1)                 ; ...
        addi  t0, t0, 1                 ; one more
        addi  t1, t1, 1                 ; one more
        addi  t2, t2, -1                ; one fewer
        bnez  t2, mv_fwd                ; if t2 is nonzero, go to mv_fwd
mv_done:                                ; ...
        ret                             ; done
p_ticks:                                ; TICKS ( -- us ): the timer
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  plat_ticks                ; a0 = microseconds since power-on
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, a0                    ; a0 is the new top
        ret                             ; done
p_ms:                                   ; MS ( n -- ): wait n milliseconds
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s1, 8(sp)                 ; n (out_flush clobbers a0)
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        call  out_flush                 ; show output before sleeping
        ld    a0, 8(sp)                 ; n
        call  plat_ms                   ; call plat_ms
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; drop the frame
        ret                             ; done
p_faddr:                                ; common: a0 = far address, a1 = write? -> a0 = D-LS
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  fc_addr                   ; call fc_addr
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done
p_farat:                                ; FAR@ ( fa -- x ): cached far fetch
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    a0, s1                    ; address
        li    a1, 0                     ; reading
        call  fc_addr                   ; a0 = D-LS address
        ld    s1, 0(a0)                 ; the cell
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done
p_farcat:                               ; FARC@ ( fa -- c )
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    a0, s1                    ; address
        li    a1, 0                     ; reading
        call  fc_addr                   ; call fc_addr
        lbu   s1, 0(a0)                 ; the byte
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done
p_farstore:                             ; FAR! ( x fa -- ): cached far store
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    a0, s1                    ; address
        li    a1, 1                     ; writing
        call  fc_addr                   ; call fc_addr
        ld    t0, 0(s0)                 ; x
        sd    t0, 0(a0)                 ; ...
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done
p_farcstore:                            ; FARC! ( c fa -- )
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    a0, s1                    ; address
        li    a1, 1                     ; writing
        call  fc_addr                   ; call fc_addr
        ld    t0, 0(s0)                 ; c
        sb    t0, 0(a0)                 ; ...
        ld    s1, 8(s0)                 ; pop both
        addi  s0, s0, 16                ; two cells off the data stack
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done
p_fflush:                               ; FFLUSH ( -- ): write every dirty line back
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    zero, 8(sp)               ; line index
ff_loop:                                ; ...
        ld    a0, 8(sp)                 ; ...
        li    t0, FC_SETS * FC_WAYS     ; all lines
        bgeu  a0, t0, ff_done           ; ...
        call  fc_wb                     ; write back if dirty
        ld    a0, 8(sp)                 ; next
        addi  a0, a0, 1                 ; one more
        sd    a0, 8(sp)                 ; ...
        j     ff_loop                   ; on to ff_loop
ff_done:                                ; ...
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 16                ; drop the frame
        ret                             ; done
p_finval:                               ; FINVAL ( -- ): write back, then forget every line
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  p_fflush                  ; call p_fflush
        la    t0, fc_tags               ; clear the tag table
        li    t1, FC_SETS * FC_SPAN     ; t1 = FC_SETS * FC_SPAN
fv_loop:                                ; ...
        sd    zero, 0(t0)               ; ...
        addi  t0, t0, 8                 ; next cell
        addi  t1, t1, -8                ; ...
        bgtz  t1, fv_loop               ; ...
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done
p_cores:                                ; CORES ( -- n ): cores this Forth may use
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, v_ncores(zero)        ; s1 = v_ncores
p_cores_e:                              ; (inline body ends here)
        ret                             ; done
p_coreid:                               ; CORE# ( -- n ): this core
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        csrr  s1, coreid                ; ...
p_coreid_e:                             ; (inline body ends here)
        ret                             ; done
p_cycles:                               ; CYCLES ( -- n ): the cycle counter
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        csrr  s1, cycle                 ; ...
p_cycles_e:                             ; (inline body ends here)
        ret                             ; done
p_instret:                              ; INSTRET ( -- n ): instructions retired
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        csrr  s1, instret               ; ...
p_instret_e:                            ; (inline body ends here)
        ret                             ; done
p_reclaim:                              ; (RECLAIM) ( -- ): take c0 back from a worker
        j     reclaim                   ; tail call
p_publish:                              ; PUBLISH ( -- ): publish the image for workers now
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  flush_code                ; call flush_code
        call  publish                   ; call publish
        ld    ra, 0(sp)                 ; restore the return address
        addi  sp, sp, 8                 ; drop the frame
        ret                             ; done
; pg_mirror: the end of p_paging. SET_MIRROR: the code mirror is the resident
; code, up to kboot; the code cache follows it (StrataOS rounds up to a slot).
; After this svc (a switch may come with it) nothing in kboot..kend may run: it
; is not reloaded on a switch-in, so this is in resident code.
pg_mirror:                              ; (p_paging's frame: ra)
        li    a0, 7                     ; SET_MIRROR
        li    a1, ORIGIN                ; ...
        la    a2, kboot                 ; ...
        sub   a2, a2, a1                ; ...
        svc                             ; a1 = NXMAP
        sd    a1, v_nxmap(zero)         ; (f_unmap clears that many entries)
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; back to cold
p_litq:                                 ; (LIT?) ( -- x -1 | 0 ): if the last thing compiled
        ld    t0, v_litend(zero)        ;   is a 16-bit literal (push; addi s1, zero, x), take
        ld    t1, v_chere(zero)         ;   it back and give its value (OF compares with it
        addi  s0, s0, -8                ;   in place)
        sd    s1, 0(s0)                 ; ...
        li    s1, 0                     ; ...
        bne   t0, t1, lq_ret            ; no
        addi  t1, t1, -12               ; yes
        sd    t1, v_chere(zero)         ; ...
        sd    zero, v_litend(zero)      ; ...
        ld    s1, v_litval(zero)        ; ...
        addi  s0, s0, -8                ; ...
        sd    s1, 0(s0)                 ; ...
        li    s1, -1                    ; ...
lq_ret:                                 ; ...
        ret                             ; done
p_units:                                ; UNIT-STATS ( -- misses slots ): code units paged in
        addi  sp, sp, -8                ;   so far (StrataOS: svc UNITS), and the code cache's
        sd    ra, 0(sp)                 ;   slots that hold one now (bare metal: 0 0)
        call  plat_units                ; a0, a1
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 8                 ; ...
        addi  s0, s0, -16               ; ...
        sd    s1, 8(s0)                 ; ...
        sd    a0, 0(s0)                 ; ...
        mv    s1, a1                    ; ...
        ret                             ; done
p_kvar:                                 ; KVAR ( n -- addr ): kernel variables for core.fs
        slli  s1, s1, 1                 ; 2 bytes per entry
        la    t0, kvars                 ; table of addresses
        add   t0, t0, s1                ; ...
        lhu   s1, 0(t0)                 ; ...
        ret                             ; done

; -----------------------------------------------------------------------------
; Primitives. Each starts 8-aligned; the body ends at the _e label, followed by
; `ret`. Bodies of F_INL words are copied into colon definitions, so they
; must not call anything and may only branch inside themselves.
; -----------------------------------------------------------------------------
        .align 8                        ; ...
p_dup:  addi  s0, s0, -8                ; DUP ( x -- x x ): room
        sd    s1, 0(s0)                 ; the copy goes below
p_dup_e: ret                            ; return
        .align 8                        ; ...
p_drop: ld    s1, 0(s0)                 ; DROP ( x -- ): second becomes top
        addi  s0, s0, 8                 ; one cell off the data stack
p_drop_e: ret                           ; return
        .align 8                        ; ...
p_swap: ld    t0, 0(s0)                 ; SWAP ( a b -- b a ): t0 = a
        sd    s1, 0(s0)                 ; b below
        mv    s1, t0                    ; a on top
p_swap_e: ret                           ; return
        .align 8                        ; ...
p_over: ld    t0, 0(s0)                 ; OVER ( a b -- a b a ): t0 = a
        addi  s0, s0, -8                ; room
        sd    s1, 0(s0)                 ; b
        mv    s1, t0                    ; a on top
p_over_e: ret                           ; return
        .align 8                        ; ...
p_rot:  ld    t0, 0(s0)                 ; ROT ( a b c -- b c a ): t0 = b
        ld    t1, 8(s0)                 ; t1 = a
        sd    t0, 8(s0)                 ; b deepest
        sd    s1, 0(s0)                 ; c next
        mv    s1, t1                    ; a on top
p_rot_e: ret                            ; return
        .align 8                        ; ...
p_mrot: ld    t0, 0(s0)                 ; -ROT ( a b c -- c a b ): t0 = b
        ld    t1, 8(s0)                 ; t1 = a
        sd    s1, 8(s0)                 ; c deepest
        sd    t1, 0(s0)                 ; a next
        mv    s1, t0                    ; b on top
p_mrot_e: ret                           ; return
        .align 8                        ; ...
p_nip:  addi  s0, s0, 8                 ; NIP ( a b -- b )
p_nip_e: ret                            ; return
        .align 8                        ; ...
p_tuck: ld    t0, 0(s0)                 ; TUCK ( a b -- b a b ): t0 = a
        addi  s0, s0, -8                ; room
        sd    s1, 8(s0)                 ; b deepest
        sd    t0, 0(s0)                 ; a next
p_tuck_e: ret                           ; return
        .align 8                        ; ...
p_2dup: ld    t0, 0(s0)                 ; 2DUP ( a b -- a b a b ): t0 = a
        addi  s0, s0, -16               ; room for two
        sd    s1, 8(s0)                 ; b
        sd    t0, 0(s0)                 ; a
p_2dup_e: ret                           ; return
        .align 8                        ; ...
p_2drop: ld   s1, 8(s0)                 ; 2DROP ( a b -- )
        addi  s0, s0, 16                ; two cells off the data stack
p_2drop_e: ret                          ; return
        .align 8                        ; ...
p_2swap: ld   t0, 0(s0)                 ; 2SWAP ( a b c d -- c d a b ): t0 = c
        ld    t1, 8(s0)                 ; t1 = b
        ld    t2, 16(s0)                ; t2 = a
        sd    t0, 16(s0)                ; c deepest
        sd    s1, 8(s0)                 ; then d
        sd    t2, 0(s0)                 ; then a
        mv    s1, t1                    ; b on top
p_2swap_e: ret                          ; return
        .align 8                        ; ...
p_2over: ld   t0, 16(s0)                ; 2OVER ( a b c d -- a b c d a b ): t0 = a
        ld    t1, 8(s0)                 ; t1 = b
        addi  s0, s0, -16               ; room for two
        sd    s1, 8(s0)                 ; d
        sd    t0, 0(s0)                 ; a
        mv    s1, t1                    ; b on top
p_2over_e: ret                          ; return
        .align 8                        ; ...
p_qdup: beqz  s1, p_qdup_e              ; ?DUP ( x -- x x | 0 ): zero stays single
        addi  s0, s0, -8                ; room
        sd    s1, 0(s0)                 ; copy
p_qdup_e: ret                           ; return
        .align 8                        ; ...
p_plus: ld    t0, 0(s0)                 ; + ( a b -- a+b )
        addi  s0, s0, 8                 ; one cell off the data stack
        add   s1, t0, s1                ; ...
p_plus_e: ret                           ; return
        .align 8                        ; ...
p_minus: ld   t0, 0(s0)                 ; - ( a b -- a-b )
        addi  s0, s0, 8                 ; one cell off the data stack
        sub   s1, t0, s1                ; ...
p_minus_e: ret                          ; return
        .align 8                        ; ...
p_star: ld    t0, 0(s0)                 ; * ( a b -- a*b )
        addi  s0, s0, 8                 ; one cell off the data stack
        mul   s1, t0, s1                ; ...
p_star_e: ret                           ; return
        .align 8                        ; ...
p_slash: ld   t0, 0(s0)                 ; / ( a b -- a/b ), symmetric
        addi  s0, s0, 8                 ; one cell off the data stack
        div   s1, t0, s1                ; ...
p_slash_e: ret                          ; return
        .align 8                        ; ...
p_mod:  ld    t0, 0(s0)                 ; MOD ( a b -- a%b ), sign of a
        addi  s0, s0, 8                 ; one cell off the data stack
        rem   s1, t0, s1                ; ...
p_mod_e: ret                            ; return
        .align 8                        ; ...
p_smod: ld    t0, 0(s0)                 ; /MOD ( a b -- rem quot )
        rem   t1, t0, s1                ; remainder
        div   s1, t0, s1                ; quotient on top
        sd    t1, 0(s0)                 ; remainder below
p_smod_e: ret                           ; return
        .align 8                        ; ...
p_uslash: ld  t0, 0(s0)                 ; U/ ( u1 u2 -- u1/u2 )
        addi  s0, s0, 8                 ; one cell off the data stack
        divu  s1, t0, s1                ; ...
p_uslash_e: ret                         ; return
        .align 8                        ; ...
p_umod: ld    t0, 0(s0)                 ; UMOD ( u1 u2 -- u1%u2 )
        addi  s0, s0, 8                 ; one cell off the data stack
        remu  s1, t0, s1                ; ...
p_umod_e: ret                           ; return
        .align 8                        ; ...
p_umulh: ld   t0, 0(s0)                 ; UM*HI ( u1 u2 -- hi ): high 64 bits of the product
        addi  s0, s0, 8                 ; one cell off the data stack
        mulhu s1, t0, s1                ; ...
p_umulh_e: ret                          ; return
        .align 8                        ; ...
p_negate: sub s1, zero, s1              ; NEGATE ( n -- -n )
p_negate_e: ret                         ; return
        .align 8                        ; ...
p_abs:  srai  t0, s1, 63                ; ABS ( n -- |n| ): t0 = 0 or -1
        xor   s1, s1, t0                ; flip if negative
        sub   s1, s1, t0                ; and add one
p_abs_e: ret                            ; return
        .align 8                        ; ...
p_min:  ld    t0, 0(s0)                 ; MIN ( a b -- min )
        addi  s0, s0, 8                 ; one cell off the data stack
        bge   t0, s1, p_min_e           ; a >= b: keep b
        mv    s1, t0                    ; else a
p_min_e: ret                            ; return
        .align 8                        ; ...
p_max:  ld    t0, 0(s0)                 ; MAX ( a b -- max )
        addi  s0, s0, 8                 ; one cell off the data stack
        bge   s1, t0, p_max_e           ; b >= a: keep b
        mv    s1, t0                    ; else a
p_max_e: ret                            ; return
        .align 8                        ; ...
p_and:  ld    t0, 0(s0)                 ; AND ( a b -- a&b )
        addi  s0, s0, 8                 ; one cell off the data stack
        and   s1, t0, s1                ; ...
p_and_e: ret                            ; return
        .align 8                        ; ...
p_or:   ld    t0, 0(s0)                 ; OR ( a b -- a|b )
        addi  s0, s0, 8                 ; one cell off the data stack
        or    s1, t0, s1                ; ...
p_or_e: ret                             ; return
        .align 8                        ; ...
p_xor:  ld    t0, 0(s0)                 ; XOR ( a b -- a^b )
        addi  s0, s0, 8                 ; one cell off the data stack
        xor   s1, t0, s1                ; ...
p_xor_e: ret                            ; return
        .align 8                        ; ...
p_invert: sub s1, zero, s1              ; INVERT ( x -- ~x ): -x ...
        addi  s1, s1, -1                ; ... - 1
p_invert_e: ret                         ; return
        .align 8                        ; ...
p_lshift: ld  t0, 0(s0)                 ; LSHIFT ( x n -- x<<n )
        addi  s0, s0, 8                 ; one cell off the data stack
        sll   s1, t0, s1                ; ...
p_lshift_e: ret                         ; return
        .align 8                        ; ...
p_rshift: ld  t0, 0(s0)                 ; RSHIFT ( x n -- x>>n ), logical
        addi  s0, s0, 8                 ; one cell off the data stack
        srl   s1, t0, s1                ; ...
p_rshift_e: ret                         ; return
        .align 8                        ; ...
p_arshift: ld t0, 0(s0)                 ; ARSHIFT ( x n -- x>>n ), arithmetic
        addi  s0, s0, 8                 ; one cell off the data stack
        sra   s1, t0, s1                ; ...
p_arshift_e: ret                        ; return
        .align 8                        ; ...
p_inc:  addi  s1, s1, 1                 ; 1+
p_inc_e: ret                            ; return
        .align 8                        ; ...
p_dec:  addi  s1, s1, -1                ; 1-
p_dec_e: ret                            ; return
        .align 8                        ; ...
p_2star: slli s1, s1, 1                 ; 2*
p_2star_e: ret                          ; return
        .align 8                        ; ...
p_2slash: srai s1, s1, 1                ; 2/
p_2slash_e: ret                         ; return
        .align 8                        ; ...
p_cells: slli s1, s1, 3                 ; CELLS ( n -- 8n )
p_cells_e: ret                          ; return
        .align 8                        ; ...
p_cellp: addi s1, s1, 8                 ; CELL+
p_cellp_e: ret                          ; return
        .align 8                        ; ...
p_chars:                                ; CHARS ( n -- n ): nothing to do
p_chars_e: ret                          ; return
        .align 8                        ; ...
p_eq:   ld    t0, 0(s0)                 ; = ( a b -- flag )
        addi  s0, s0, 8                 ; one cell off the data stack
        sub   t0, t0, s1                ; zero if equal
        sltiu s1, t0, 1                 ; 1 if equal
        sub   s1, zero, s1              ; -1 if equal
p_eq_e: ret                             ; return
        .align 8                        ; ...
p_ne:   ld    t0, 0(s0)                 ; <> ( a b -- flag )
        addi  s0, s0, 8                 ; one cell off the data stack
        sub   t0, t0, s1                ; nonzero if different
        sltu  s1, zero, t0              ; 1 if different
        sub   s1, zero, s1              ; -1
p_ne_e: ret                             ; return
        .align 8                        ; ...
p_lt:   ld    t0, 0(s0)                 ; < ( a b -- flag )
        addi  s0, s0, 8                 ; one cell off the data stack
        slt   s1, t0, s1                ; ...
        sub   s1, zero, s1              ; ...
p_lt_e: ret                             ; return
        .align 8                        ; ...
p_gt:   ld    t0, 0(s0)                 ; > ( a b -- flag )
        addi  s0, s0, 8                 ; one cell off the data stack
        slt   s1, s1, t0                ; ...
        sub   s1, zero, s1              ; ...
p_gt_e: ret                             ; return
        .align 8                        ; ...
p_ult:  ld    t0, 0(s0)                 ; U< ( a b -- flag )
        addi  s0, s0, 8                 ; one cell off the data stack
        sltu  s1, t0, s1                ; ...
        sub   s1, zero, s1              ; ...
p_ult_e: ret                            ; return
        .align 8                        ; ...
p_ugt:  ld    t0, 0(s0)                 ; U> ( a b -- flag )
        addi  s0, s0, 8                 ; one cell off the data stack
        sltu  s1, s1, t0                ; ...
        sub   s1, zero, s1              ; ...
p_ugt_e: ret                            ; return
        .align 8                        ; ...
p_zeq:  sltiu s1, s1, 1                 ; 0= ( x -- flag )
        sub   s1, zero, s1              ; ...
p_zeq_e: ret                            ; return
        .align 8                        ; ...
p_zlt:  srai  s1, s1, 63                ; 0< ( n -- flag ): the sign, spread
p_zlt_e: ret                            ; return
        .align 8                        ; ...
p_zgt:  slt   s1, zero, s1              ; 0> ( n -- flag )
        sub   s1, zero, s1              ; ...
p_zgt_e: ret                            ; return
        .align 8                        ; ...
p_zne:  sltu  s1, zero, s1              ; 0<> ( x -- flag )
        sub   s1, zero, s1              ; ...
p_zne_e: ret                            ; return
        .align 8                        ; ...
p_fetch: ld   s1, 0(s1)                 ; @ ( addr -- x )
p_fetch_e: ret                          ; return
        .align 8                        ; ...
p_store: ld   t0, 0(s0)                 ; ! ( x addr -- )
        sd    t0, 0(s1)                 ; ...
        ld    s1, 8(s0)                 ; the third item becomes the top
        addi  s0, s0, 16                ; two cells off the data stack
p_store_e: ret                          ; return
        .align 8                        ; ...
p_cfetch: lbu s1, 0(s1)                 ; C@ ( addr -- c )
p_cfetch_e: ret                         ; return
        .align 8                        ; ...
p_cstore: ld  t0, 0(s0)                 ; C! ( c addr -- )
        sb    t0, 0(s1)                 ; ...
        ld    s1, 8(s0)                 ; the third item becomes the top
        addi  s0, s0, 16                ; two cells off the data stack
p_cstore_e: ret                         ; return
        .align 8                        ; ...
p_wfetch: lhu s1, 0(s1)                 ; W@ ( addr -- u16 )
p_wfetch_e: ret                         ; return
        .align 8                        ; ...
p_wstore: ld  t0, 0(s0)                 ; W! ( u16 addr -- )
        sh    t0, 0(s1)                 ; ...
        ld    s1, 8(s0)                 ; the third item becomes the top
        addi  s0, s0, 16                ; two cells off the data stack
p_wstore_e: ret                         ; return
        .align 8                        ; ...
p_lfetch: lwu s1, 0(s1)                 ; L@ ( addr -- u32 )
p_lfetch_e: ret                         ; return
        .align 8                        ; ...
p_lstore: ld  t0, 0(s0)                 ; L! ( u32 addr -- )
        sw    t0, 0(s1)                 ; ...
        ld    s1, 8(s0)                 ; the third item becomes the top
        addi  s0, s0, 16                ; two cells off the data stack
p_lstore_e: ret                         ; return
        .align 8                        ; ...
p_pstore: ld  t0, 0(s0)                 ; +! ( n addr -- )
        ld    t1, 0(s1)                 ; ...
        add   t1, t1, t0                ; ...
        sd    t1, 0(s1)                 ; ...
        ld    s1, 8(s0)                 ; the third item becomes the top
        addi  s0, s0, 16                ; two cells off the data stack
p_pstore_e: ret                         ; return
        .align 8                        ; ...
p_tor:  addi  sp, sp, -8                ; >R ( x -- ) ( R: -- x )
        sd    s1, 0(sp)                 ; ...
        ld    s1, 0(s0)                 ; the second item becomes the top
        addi  s0, s0, 8                 ; one cell off the data stack
p_tor_e: ret                            ; return
        .align 8                        ; ...
p_rfrom: addi s0, s0, -8                ; R> ( -- x ) ( R: x -- )
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, 0(sp)                 ; ...
        addi  sp, sp, 8                 ; drop the frame
p_rfrom_e: ret                          ; return
        .align 8                        ; ...
p_rat:  addi  s0, s0, -8                ; R@ ( -- x ) ( R: x -- x )
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, 0(sp)                 ; ...
p_rat_e: ret                            ; return
        .align 8                        ; ...
p_rdrop: addi sp, sp, 8                 ; RDROP ( R: x -- )
p_rdrop_e: ret                          ; return
        .align 8                        ; ...
p_2tor: ld    t0, 0(s0)                 ; 2>R ( a b -- ) ( R: -- a b )
        addi  sp, sp, -16               ; a frame on the return stack
        sd    t0, 8(sp)                 ; a deeper
        sd    s1, 0(sp)                 ; b on top
        ld    s1, 8(s0)                 ; the third item becomes the top
        addi  s0, s0, 16                ; two cells off the data stack
p_2tor_e: ret                           ; return
        .align 8                        ; ...
p_2rfrom: addi s0, s0, -16              ; 2R> ( -- a b ) ( R: a b -- )
        sd    s1, 8(s0)                 ; ...
        ld    t0, 8(sp)                 ; a
        sd    t0, 0(s0)                 ; ...
        ld    s1, 0(sp)                 ; b
        addi  sp, sp, 16                ; drop the frame
p_2rfrom_e: ret                         ; return
        .align 8                        ; ...
p_2rat: addi  s0, s0, -16               ; 2R@ ( -- a b )
        sd    s1, 8(s0)                 ; ...
        ld    t0, 8(sp)                 ; ...
        sd    t0, 0(s0)                 ; ...
        ld    s1, 0(sp)                 ; ...
p_2rat_e: ret                           ; return
        .align 8                        ; ...
p_i:    addi  s0, s0, -8                ; I ( -- n ): the loop index lives in s2
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, s2                    ; s2 is the new top
p_i_e:  ret                             ; return
        .align 8                        ; ...
p_j:    addi  s0, s0, -8                ; J ( -- n ): the outer index, saved by the inner DO
        sd    s1, 0(s0)                 ; the old top goes to memory
        ld    s1, 0(sp)                 ; ...
p_j_e:  ret                             ; return
        .align 8                        ; ...
p_unloop: ld  s2, 0(sp)                 ; UNLOOP: restore the outer loop registers
        ld    s3, 8(sp)                 ; ...
        addi  sp, sp, 16                ; drop the frame
p_unloop_e: ret                         ; return
        .align 8                        ; ...
p_execute: mv t0, s1                    ; EXECUTE ( i*x xt -- j*x )
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; one cell off the data stack
        srli  t1, t0, 16                ; a unit's code (a far offset)?
        bnez  t1, ex_unit               ; ...
        bltz  ra, ex_far                ; called with a far link (from a unit, by the gateway)?
        jr    t0                        ; no: a tail jump, it returns to our caller
ex_far:                                 ; yes: call it from here (a primitive returns with
        addi  sp, sp, -8                ;   ret, which cannot follow a far link), then xret
        sd    ra, 0(sp)                 ; ...
        jalr  ra, t0, 0                 ; ...
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 8                 ; ...
        xret  ra                        ; ...
ex_unit:                                ; a unit: jump into it (StrataOS pages it in); it
        srli  t0, t0, 2                 ;   returns with xret to our caller (the low bits
        slli  t0, t0, 2                 ;   go, as jr ignores them)
        xcall zero, c0, t0              ;   ...
p_execute_e:                            ; ...
        .align 8                        ; ...
p_depth: li   t0, DS_TOP                ; DEPTH ( -- n )
        sub   t0, t0, s0                ; bytes used
        srai  t0, t0, 3                 ; cells
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
p_depth_e: ret                          ; return
        .align 8                        ; ...
p_spat: mv    t0, s0                    ; SP@ ( -- addr ): where the second item is
        addi  s0, s0, -8                ; push
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, t0                    ; t0 is the new top
p_spat_e: ret                           ; return
        .align 8                        ; ...
p_rpat: addi  s0, s0, -8                ; RP@ ( -- addr )
        sd    s1, 0(s0)                 ; the old top goes to memory
        mv    s1, sp                    ; sp is the new top
p_rpat_e: ret                           ; return

        .include "platform.s"           ; key/emit, timer, far cache backing, capabilities, bye

; =============================================================================
; The paging part (kpage..kboot) and the start-up part (kboot..kend). Code only
; paged mode runs: with threads (forth -n N) and on bare metal compiled code
; starts at kpage and overwrites it (cold puts chere there). Code only start-up
; runs, before core.fs: in paged mode the code mirror ends at kboot, and the
; code cache that follows it overwrites this part. (So nothing here may run
; once core.fs is being compiled; PAGING ends in resident code, pg_mirror.)
; =============================================================================
        .align 8                        ; ...
kpage:                                  ; ...
ce_unit:                                ; cg_exit, paged: only an xcall becomes a jump (a
        ld    t2, v_callkd(zero)        ;   resident word may return with ret, which cannot
        li    t3, 2                     ;   follow its caller's far link)
        bne   t2, t3, ce_locals         ; ...
        ld    t1, v_callst(zero)        ; take the whole call back (1 to 3 instructions)
        ld    t2, v_nfix(zero)          ; and its recorded pair, if it had one
        beqz  t2, ce_tail               ; ...
        slli  t3, t2, 3                 ; ...
        ld    t3, v_fix-8(t3)           ; ...
        ld    t4, v_cbase(zero)         ; ...
        sub   t4, t1, t4                ; ...
        bltu  t3, t4, ce_tail           ; ...
        addi  t2, t2, -1                ; ...
        sd    t2, v_nfix(zero)          ; ...
        j     ce_tail                   ; ...
ce_ujump:                               ; cg_exit, paged: a jump into another unit is an xcall
        ld    t0, v_cbase(zero)         ; (one into this definition, a recursion, a jal:
        bgeu  a1, t0, ce_jal            ;   it moves with it)
        mv    a0, a1                    ; xcall zero, c0, target
        li    a1, R_ZERO                ; ...
        call  cg_far                    ; ...
        j     ce_done                   ; ...
pd_unit:                                ; (does>), a stub in a unit: jalr zero, gp, does-code
        mv    a1, a0                    ;   at stub + 4
        mv    a0, t2                    ; ...
        mv    t6, ra                    ; ...
        call  xt_dec                    ; ...
        mv    ra, t6                    ; ...
        addi  t2, a0, 4                 ; ...
        li    t3, 0x10000               ; ...
        sub   t3, a1, t3                ; ...
        andi  t3, t3, 0xFFFF            ; ...
        li    t4, I_GJUMP               ; ...
        or    t3, t3, t4                ; ...
        j     pd_put                    ; ...
xl_unit:                                ; XTLITERAL, paged
        ld    t0, v_cbase(zero)         ; ...
        bltu  s1, t0, p_literal         ; ...
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; ...
        call  p_literal                 ; (a code address is >= 0x10000: lui, ori)
        ld    t0, v_chere(zero)         ; ...
        addi  t0, t0, -8                ; ...
        call  fix_add                   ; ...
        ld    ra, 0(sp)                 ; ...
        addi  sp, sp, 8                 ; ...
        ret                             ; ...
; f_unmap: clear the overlay map, entries v_nxmap-1 .. 0 (none before PAGING):
; a unit whose far copy changed may be in the cache
f_unmap:                                ; leaf; clobbers t0, t1
        ld    t0, v_nxmap(zero)         ; (an index past the platform's map is illegal:
        li    t1, 16                    ;   jump into the run of xunmaps)
        sub   t1, t1, t0                ; ...
        slli  t1, t1, 2                 ; ...
        la    t0, fu_run                ; ...
        add   t0, t0, t1                ; ...
        jr    t0                        ; ...
fu_run:                                 ; ...
        xunmap 15                       ; .
        xunmap 14                       ; .
        xunmap 13                       ; .
        xunmap 12                       ; .
        xunmap 11                       ; .
        xunmap 10                       ; .
        xunmap 9                        ; .
        xunmap 8                        ; .
        xunmap 7                        ; .
        xunmap 6                        ; .
        xunmap 5                        ; .
        xunmap 4                        ; .
        xunmap 3                        ; .
        xunmap 2                        ; .
        xunmap 1                        ; .
        xunmap 0                        ; .
        ret                             ; done
ct_unit:                                ; cg_target, paged
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the xt
        sd    a1, 16(sp)                ; the header
        srli  t2, a0, 16                ; a unit's code: xcall
        bnez  t2, ct_x                  ; ...
        beqz  a1, ct_anon               ; resident: may it page?
        lbu   t1, H_FLAGS(a1)           ; ...
        andi  t1, t1, F_PAGER           ; ...
        beqz  t1, ct_res                ; no: jalr gp
        lbu   t2, H_FOLD(a1)            ; yes: through its gateway entry
        slli  t2, t2, 2                 ; ...
        li    a0, UBASE                 ; ...
        add   a0, a0, t2                ; ...
ct_x:                                   ; an xcall of a0
        li    a1, R_RA                  ; ...
        call  cg_far                    ; ...
        j     ct_ret                    ; ...
ct_anon:                                ; resident with no name (a quotation): EXECUTE runs it
        call  cg_lit                    ; push the xt
        ld    a0, v_ngw(zero)           ; EXECUTE's entry is the gateway's last
        addi  a0, a0, -1                ; ...
        slli  a0, a0, 2                 ; ...
        li    t0, UBASE                 ; ...
        add   a0, a0, t0                ; ...
        j     ct_x                      ; ...
ct_res:                                 ; jalr ra, gp, xt - 0x10000
        ld    t0, v_chere(zero)         ; it starts here
        sd    t0, v_callst(zero)        ; ...
        li    a0, I_GCALL               ; ...
        ld    a1, 8(sp)                 ; ...
        call  cg_gp                     ; ...
        ld    t0, v_chere(zero)         ; never a tail call (a primitive returns with ret)
        sd    t0, v_callend(zero)       ; ...
        ld    t0, 8(sp)                 ; ...
        sd    t0, v_callxt(zero)        ; ...
        li    t0, 1                     ; ...
        sd    t0, v_callkd(zero)        ; ...
ct_ret:                                 ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done

; cg_gp(a0 = instruction, a1 = resident address): emit a0 | (a1 - 0x10000): an
; access through gp from paged code
cg_gp:                                  ; clobbers t0..t2, a0
        li    t0, 0x10000               ; ...
        sub   t0, a1, t0                ; ...
        andi  t0, t0, 0xFFFF            ; ...
        or    a0, a0, t0                ; ...
        j     cg                        ; tail call

; cg_far(a0 = far address in c0, a1 = R_RA to call, R_ZERO to jump): t5 = a0
; (addi t5, tp, a0 - TPV, or lui, ori), then xcall a1, c0, t5. An address in
; the definition being compiled (staged: at or after cbase) is a lui, ori pair
; recorded in v_fix, since the definition may move at `;`.
cg_far:                                 ; clobbers t0..t2, t6, a0, a1
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the address
        sd    a1, 16(sp)                ; the link register
        ld    t0, v_chere(zero)         ; the call starts here
        sd    t0, v_callst(zero)        ; ...
        ld    t1, v_cbase(zero)         ; in this definition?
        bltu  a0, t1, cf_out            ; ...
        call  fix_add                   ; yes: a pair to move with it (t0 = chere)
        j     cf_long                   ; ...
cf_out:                                 ; near tp: one addi
        li    t0, TPV                   ; ...
        sub   t1, a0, t0                ; ...
        slli  t2, t1, 48                ; a 16-bit signed difference?
        srai  t2, t2, 48                ; ...
        bne   t2, t1, cf_long           ; no
        andi  t1, t1, 0xFFFF            ; ...
        li    a0, I_TPT5                ; addi t5, tp, d
        or    a0, a0, t1                ; ...
        call  cg                        ; ...
        j     cf_x                      ; ...
cf_long:                                ; lui t5, a >> 16; ori t5, t5, a & 0xFFFF
        ld    a0, 8(sp)                 ; ...
        srli  a1, a0, 16                ; ...
        li    a0, I_LUIT5               ; ...
        or    a0, a0, a1                ; ...
        ld    a1, 8(sp)                 ; ...
        andi  a1, a1, 0xFFFF            ; ...
        li    t1, I_ORIT5               ; ...
        or    a1, a1, t1                ; ...
        call  cg2                       ; ...
cf_x:                                   ; xcall ra / zero, c0, t5
        li    a0, I_XCALL               ; ...
        ld    t0, 16(sp)                ; ...
        bnez  t0, cf_e                  ; ...
        li    a0, I_XJUMP               ; ...
cf_e:                                   ; ...
        call  cg                        ; ...
        ld    t0, v_chere(zero)         ; `;` right after it makes it a jump
        sd    t0, v_callend(zero)       ; ...
        ld    t0, 8(sp)                 ; ...
        sd    t0, v_callxt(zero)        ; ...
        li    t0, 2                     ; ...
        sd    t0, v_callkd(zero)        ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done

; fix_add(t0 = the code address where a lui, ori pair holding an address in
; this definition starts): record it (its staging offset)
fix_add:                                ; leaf; clobbers t1, t2
        ld    t1, v_nfix(zero)          ; ...
        li    t2, MAXFIX                ; ...
        bgeu  t1, t2, cg_long           ; too many: "definition too long"
        slli  t2, t1, 3                 ; ...
        addi  t1, t1, 1                 ; ...
        sd    t1, v_nfix(zero)          ; ...
        ld    t1, v_cbase(zero)         ; ...
        sub   t1, t0, t1                ; ...
        sd    t1, v_fix(t2)             ; ...
        ret                             ; done
; fix_get(a0 = staging offset of a lui, ori pair) -> a1 = the 32-bit value it loads
fix_get:                                ; leaf; clobbers t0, t1
        la    t0, stage                 ; ...
        add   t0, t0, a0                ; ...
        lwu   a1, 0(t0)                 ; the lui's immediate
        slli  a1, a1, 48                ; ...
        srli  a1, a1, 32                ; ...
        lwu   t1, 4(t0)                 ; the ori's
        andi  t1, t1, 0xFFFF            ; ...
        or    a1, a1, t1                ; ...
        ret                             ; done
; fix_put(a0 = staging offset of a lui, ori pair, a1 = value): make it load a1
fix_put:                                ; leaf; clobbers t0..t2
        la    t0, stage                 ; ...
        add   t0, t0, a0                ; ...
        lwu   t1, 0(t0)                 ; the lui: its immediate is a1 >> 16
        srli  t1, t1, 16                ; ...
        slli  t1, t1, 16                ; ...
        srli  t2, a1, 16                ; ...
        andi  t2, t2, 0xFFFF            ; ...
        or    t1, t1, t2                ; ...
        sw    t1, 0(t0)                 ; ...
        lwu   t1, 4(t0)                 ; the ori: a1 & 0xFFFF
        srli  t1, t1, 16                ; ...
        slli  t1, t1, 16                ; ...
        andi  t2, a1, 0xFFFF            ; ...
        or    t1, t1, t2                ; ...
        sw    t1, 4(t0)                 ; ...
        ret                             ; done


cs_unit:                                ; ...
        li    a0, I_GJUMP               ; ...
        call  cg_gp                     ; ...
        ld    t0, 16(sp)                ; a CREATEd word's has room for what DOES> puts
        bnez  t0, cs_done               ;   there (lui, ori, xcall): 16 bytes
        li    a0, I_NOP                 ; ...
        li    a1, I_NOP                 ; ...
        call  cg2                       ; ...
        j     cs_done                   ; ...
nw_unit:                                ; new_word, paged: a stub that would cross a unit
        ld    t0, v_chere(zero)         ; ...
        addi  t1, t0, 15                ; ...
        xor   t1, t1, t0                ; ...
        srli  t1, t1, XSLOT             ; ...
        beqz  t1, nw_name               ; ...
        call  flush_code                ; (what is staged stays where it is)
        ld    t0, v_chere(zero)         ; the next unit
        addi  t0, t0, (1 << XSLOT) - 1  ; ...
        srli  t0, t0, XSLOT             ; ...
        slli  t0, t0, XSLOT             ; ...
        sd    t0, v_chere(zero)         ; ...
        sd    t0, v_cbase(zero)         ; ...
        j     nw_name                   ; ...
ds_unit:                                ; in a unit: lit <does-code> (does>x) ; then the does-code
        li    a0, UBASE                 ; (a lui, ori pair: set below, moved with the definition)
        call  cg_lit                    ; ...
        ld    t0, v_chere(zero)         ; ...
        addi  t0, t0, -8                ; ...
        sd    t0, 8(sp)                 ; ...
        li    a0, I_GCALL               ; jalr ra, gp, (does>x)
        la    a1, p_pdoesx              ; ...
        call  cg_gp                     ; ...
        li    a0, 0                     ; return
        call  cg_exit                   ; ...
        sd    zero, v_nloc(zero)        ; the does-code has no locals
        ld    t0, 8(sp)                 ; the literal: the does-code starts here
        call  fix_add                   ; ...
        ld    a0, 8(sp)                 ; ...
        ld    t0, v_cbase(zero)         ; ...
        sub   a0, a0, t0                ; ...
        ld    a1, v_chere(zero)         ; ...
        call  fix_put                   ; ...
        li    a0, I_GPRO                ; jalr t0, gp, k_does: push the address, save ra
        la    a1, k_does                ; ...
        call  cg_gp                     ; ...
        j     ds_pro                    ; ...

; (DOES>X) ( a -- ): (does>) for a defining word in a unit: the newest word,
; which CREATE made in a unit, jumps to the does-code at far address a
; (lui t5, ori t5, xcall zero, c0, t5 in its stub after the ori t1)
p_pdoesx:                               ; Forth word
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s1, 8(sp)                 ; a
        ld    s1, 0(s0)                 ; pop
        addi  s0, s0, 8                 ; ...
        ld    t0, v_latest(zero)        ; the word CREATE just made: not a plain address
        lbu   t1, H_FLAGS(t0)           ; any more
        andi  t1, t1, 0xFF ^ (F_CREATE | F_INL) ; ...
        sb    t1, H_FLAGS(t0)           ; ...
        mv    a0, t0                    ; its stub + 4, +8, +12
        call  hxt                       ; ...
        addi  a0, a0, 4                 ; ...
        sd    a0, 16(sp)                ; ...
        ld    t0, 8(sp)                 ; lui t5, a >> 16
        srli  t0, t0, 16                ; ...
        li    t1, I_LUIT5               ; ...
        or    a0, t0, t1                ; ...
        ld    a1, 16(sp)                ; ...
        call  pd_one                    ; ...
        ld    t0, 8(sp)                 ; ori t5, t5, a & 0xFFFF
        andi  t0, t0, 0xFFFF            ; ...
        li    t1, I_ORIT5               ; ...
        or    a0, t0, t1                ; ...
        ld    a1, 16(sp)                ; ...
        addi  a1, a1, 4                 ; ...
        call  pd_one                    ; ...
        li    a0, I_XJUMP               ; xcall zero, c0, t5
        ld    a1, 16(sp)                ; ...
        addi  a1, a1, 8                 ; ...
        call  pd_one                    ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 32                ; ...
        ret                             ; back into the defining word
pd_one:                                 ; (a0 = instruction, a1 = address): staged or installed
        ld    t0, v_cbase(zero)         ; still staged?
        bltu  a1, t0, code_patch        ; no: through far memory (a tail call)
        sub   t1, a1, t0                ; staging offset
        la    t2, stage                 ; ...
        add   t2, t2, t1                ; ...
        sw    a0, 0(t2)                 ; patch
        ret                             ; ...

ed_place:                               ; end_def, paged: the definition in one unit
        ld    t1, v_cbase(zero)         ; its start (only it is staged: `:` installed the rest)
        ld    t2, v_chere(zero)         ; its end
        sub   t3, t2, t1                ; its size
        li    t4, 1 << XSLOT            ; at most a unit
        bgtu  t3, t4, ed_long           ; ...
        addi  t5, t2, -1                ; the last byte in the same unit as the first?
        xor   t5, t5, t1                ; ...
        srli  t5, t5, XSLOT             ; ...
        beqz  t5, ed_rec                ; yes: it stays
        addi  t5, t1, (1 << XSLOT) - 1  ; no: it goes to the start of the next unit
        srli  t5, t5, XSLOT             ; ...
        slli  t5, t5, XSLOT             ; ...
        add   t6, t5, t3                ; (which must be in the store)
        ld    t0, v_climit(zero)        ; ...
        bgtu  t6, t0, cg_full           ; ...
        sub   a3, t5, t1                ; a3 = how far it moves
        sd    t5, v_cbase(zero)         ; ...
        sd    t6, v_chere(zero)         ; ...
        ld    t0, v_curxt(zero)         ; ...
        add   t0, t0, a3                ; ...
        sd    t0, v_curxt(zero)         ; ...
        li    a4, 0                     ; a4 = its recorded pairs: they move too
ed_fix:                                 ; ...
        ld    t0, v_nfix(zero)          ; ...
        bgeu  a4, t0, ed_hdr            ; ...
        slli  t0, a4, 3                 ; ...
        ld    a0, v_fix(t0)             ; ...
        call  fix_get                   ; a1 = the address
        add   a1, a1, a3                ; moved
        call  fix_put                   ; ...
        addi  a4, a4, 1                 ; ...
        j     ed_fix                    ; ...
ed_hdr:                                 ; and the header's xt
        ld    t0, v_curnt(zero)         ; ...
        beqz  t0, ed_rec                ; ...
        ld    a0, v_curxt(zero)         ; ...
        call  xt_enc                    ; ...
        ld    t0, v_curnt(zero)         ; ...
        sh    a0, H_XT(t0)              ; ...
        j     ed_rec                    ; ...
        .align 8                        ; ...
kboot:                                  ; ...
; p_paging: from now on code goes into units, paged by StrataOS (see "Code
; paging"; cold calls this before it compiles core.fs). Not on bare metal, nor
; with threads (forth -n N: a worker installs the code from the parcel, where
; the store would be; every word stays resident there, as before).
p_paging:                               ; (start-up)
        li    t0, PLAT_PAGE             ; a platform that pages?
        beqz  t0, pg_ret                ; ...
        ld    t0, v_ncores(zero)        ; one thread?
        addi  t0, t0, -1                ; ...
        bnez  t0, pg_ret                ; ...
        ld    t0, v_paged(zero)         ; once
        bnez  t0, pg_ret                ; ...
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        li    t0, XSLOT                 ; slot mapping: units of 2^XSLOT bytes
        csrw  xslot, t0                 ; ...
        ld    t0, v_latest(zero)        ; the gateway (unit 0): jalr zero, gp, xt for every
        la    t1, stage                 ;   resident word that may page; H_FOLD = its entry
        li    t2, 0                     ; t2 = entries
pg_w:                                   ; ...
        beqz  t0, pg_wd                 ; ...
        lbu   t3, H_FLAGS(t0)           ; ...
        andi  t3, t3, F_PAGER           ; ...
        beqz  t3, pg_n                  ; ...
        li    t3, 255                   ; (room for 255 of them, and EXECUTE's)
        bgeu  t2, t3, pg_n              ; ...
        sb    t2, H_FOLD(t0)            ; ...
        lhu   a0, H_XT(t0)              ; ...
        call  pg_ent                    ; ...
pg_n:                                   ; ...
        lhu   t0, H_LINK(t0)            ; ...
        j     pg_w                      ; ...
pg_wd:                                  ; and last, EXECUTE's (for an xt with no name)
        la    a0, p_execute             ; ...
        call  pg_ent                    ; ...
        sd    t2, v_ngw(zero)           ; ...
        slli  t2, t2, 2                 ; stage -> unit 0
        addi  t2, t2, 7                 ; ...
        srli  t2, t2, 3                 ; ...
        slli  t2, t2, 3                 ; ...
        la    t1, stage                 ; ...
        li    t3, UBASE                 ; ...
        tput  tg13, t1, c0, t3, t2      ; ...
        twait 1 << 13                   ; ...
        li    t0, UBASE + (1 << XSLOT)  ; code goes on in unit 1
        sd    t0, v_chere(zero)         ; ...
        sd    t0, v_cbase(zero)         ; ...
        li    t0, UEND                  ; up to the end of the store
        sd    t0, v_climit(zero)        ; ...
        li    t0, 1                     ; paging
        sd    t0, v_paged(zero)         ; ...
        j     pg_mirror                 ; the code mirror ends at kboot (resident: see there)
pg_ret:                                 ; ...
        ret                             ; done
pg_ent:                                 ; (a0 = xt, t1 = where, t2 = count): one entry
        li    t3, 0x10000               ; jalr zero, gp, xt - 0x10000
        sub   t3, a0, t3                ; ...
        andi  t3, t3, 0xFFFF            ; ...
        li    t4, I_GJUMP               ; ...
        or    t3, t3, t4                ; ...
        sw    t3, 0(t1)                 ; ...
        addi  t1, t1, 4                 ; ...
        addi  t2, t2, 1                 ; ...
        ret                             ; ...
; build_dict: make a header for every entry of the kernel word table
build_dict:                             ; clobbers t0..t3, a0..a7
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        la    a6, ktable                ; a6 = cursor in the table
bd_loop:                                ; one entry per iteration
        lbu   a7, 0(a6)                 ; xt, low byte
        lbu   t0, 1(a6)                 ; xt, high byte
        slli  t0, t0, 8                 ; ...
        or    a7, a7, t0                ; a7 = xt
        beqz  a7, bd_done               ; xt 0 ends the table
        addi  a0, a6, 6                 ; a0 = the name (zero-terminated)
        mv    a1, a0                    ; a1 = cursor to find its end
bd_len:                                 ; find the terminating zero
        lbu   t0, 0(a1)                 ; character
        beqz  t0, bd_got                ; end
        addi  a1, a1, 1                 ; next
        j     bd_len                    ; continue
bd_got:                                 ; a1 = address of the zero
        sub   a1, a1, a0                ; a1 = length
        call  make_header               ; a0 = header (a6, a7 survive)
        sh    a7, H_XT(a0)              ; the xt
        lbu   t0, 2(a6)                 ; size, low byte
        lbu   t1, 3(a6)                 ; size, high byte
        slli  t1, t1, 8                 ; ...
        or    t0, t0, t1                ; t0 = size
        sh    t0, H_SIZE(a0)            ; code bytes
        lbu   t0, 4(a6)                 ; flags
        sb    t0, H_FLAGS(a0)           ; ...
        lbu   t0, 5(a6)                 ; fold kind
        sb    t0, H_FOLD(a0)            ; ...
        lbu   t0, H_NLEN(a0)            ; name length
        add   a6, a6, t0                ; skip the entry: 6 + name + 1
        addi  a6, a6, 7                 ; ...
        j     bd_loop                   ; next entry
bd_done:                                ; all made
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
        .include "init.s"               ; the platform's start-up: plat_init

        .align 8                        ; compiled code starts on a doubleword
kend:                                   ; end of the kernel image

; -----------------------------------------------------------------------------
; The kernel word table, read once at start-up by build_dict. Entries: u16 xt,
; u16 size (the inline body for F_INL words, else 0), u8 flags, u8 fold kind,
; the name, zero-terminated. An xt of 0 ends it. It lives high in the D-LS,
; where the growing dictionary later overwrites it.
; -----------------------------------------------------------------------------
        .data                           ; D-LS
        .org  0x8000                    ; out of the way of the dictionary at start-up
ktable:                                 ; the table
        .half p_dup, p_dup_e - p_dup    ; dup: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "dup"                    ; name
        .half p_drop, p_drop_e - p_drop ; drop: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "drop"                   ; name
        .half p_swap, p_swap_e - p_swap ; swap: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "swap"                   ; name
        .half p_over, p_over_e - p_over ; over: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "over"                   ; name
        .half p_rot, p_rot_e - p_rot    ; rot: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "rot"                    ; name
        .half p_mrot, p_mrot_e - p_mrot ; -rot: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "-rot"                   ; name
        .half p_nip, p_nip_e - p_nip    ; nip: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "nip"                    ; name
        .half p_tuck, p_tuck_e - p_tuck ; tuck: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "tuck"                   ; name
        .half p_2dup, p_2dup_e - p_2dup ; 2dup: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2dup"                   ; name
        .half p_2drop, p_2drop_e - p_2drop; 2drop: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2drop"                  ; name
        .half p_2swap, p_2swap_e - p_2swap; 2swap: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2swap"                  ; name
        .half p_2over, p_2over_e - p_2over; 2over: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2over"                  ; name
        .half p_qdup, p_qdup_e - p_qdup ; ?dup: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "?dup"                   ; name
        .half p_plus, p_plus_e - p_plus ; +: xt, inline body bytes
        .byte F_INL, FD_ADD             ; inline, folds with a literal
        .asciz "+"                      ; name
        .half p_minus, p_minus_e - p_minus; -: xt, inline body bytes
        .byte F_INL, FD_SUB             ; inline, folds with a literal
        .asciz "-"                      ; name
        .half p_star, p_star_e - p_star ; *: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "*"                      ; name
        .half p_slash, p_slash_e - p_slash; /: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "/"                      ; name
        .half p_mod, p_mod_e - p_mod    ; mod: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "mod"                    ; name
        .half p_smod, p_smod_e - p_smod ; /mod: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "/mod"                   ; name
        .half p_uslash, p_uslash_e - p_uslash; u/: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "u/"                     ; name
        .half p_umod, p_umod_e - p_umod ; umod: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "umod"                   ; name
        .half p_umulh, p_umulh_e - p_umulh; um*hi: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "um*hi"                  ; name
        .half p_negate, p_negate_e - p_negate; negate: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "negate"                 ; name
        .half p_abs, p_abs_e - p_abs    ; abs: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "abs"                    ; name
        .half p_min, p_min_e - p_min    ; min: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "min"                    ; name
        .half p_max, p_max_e - p_max    ; max: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "max"                    ; name
        .half p_and, p_and_e - p_and    ; and: xt, inline body bytes
        .byte F_INL, FD_AND             ; inline, folds with a literal
        .asciz "and"                    ; name
        .half p_or, p_or_e - p_or       ; or: xt, inline body bytes
        .byte F_INL, FD_OR              ; inline, folds with a literal
        .asciz "or"                     ; name
        .half p_xor, p_xor_e - p_xor    ; xor: xt, inline body bytes
        .byte F_INL, FD_XOR             ; inline, folds with a literal
        .asciz "xor"                    ; name
        .half p_invert, p_invert_e - p_invert; invert: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "invert"                 ; name
        .half p_lshift, p_lshift_e - p_lshift; lshift: xt, inline body bytes
        .byte F_INL, FD_SHL             ; inline, folds with a literal
        .asciz "lshift"                 ; name
        .half p_rshift, p_rshift_e - p_rshift; rshift: xt, inline body bytes
        .byte F_INL, FD_SHR             ; inline, folds with a literal
        .asciz "rshift"                 ; name
        .half p_arshift, p_arshift_e - p_arshift; arshift: xt, inline body bytes
        .byte F_INL, FD_SAR             ; inline, folds with a literal
        .asciz "arshift"                ; name
        .half p_inc, p_inc_e - p_inc    ; 1+: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "1+"                     ; name
        .half p_dec, p_dec_e - p_dec    ; 1-: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "1-"                     ; name
        .half p_2star, p_2star_e - p_2star; 2*: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2*"                     ; name
        .half p_2slash, p_2slash_e - p_2slash; 2/: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2/"                     ; name
        .half p_cells, p_cells_e - p_cells; cells: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "cells"                  ; name
        .half p_cellp, p_cellp_e - p_cellp; cell+: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "cell+"                  ; name
        .half p_chars, p_chars_e - p_chars; chars: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "chars"                  ; name
        .half p_eq, p_eq_e - p_eq       ; =: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "="                      ; name
        .half p_ne, p_ne_e - p_ne       ; <>: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "<>"                     ; name
        .half p_lt, p_lt_e - p_lt       ; <: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "<"                      ; name
        .half p_gt, p_gt_e - p_gt       ; >: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz ">"                      ; name
        .half p_ult, p_ult_e - p_ult    ; u<: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "u<"                     ; name
        .half p_ugt, p_ugt_e - p_ugt    ; u>: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "u>"                     ; name
        .half p_zeq, p_zeq_e - p_zeq    ; 0=: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "0="                     ; name
        .half p_zlt, p_zlt_e - p_zlt    ; 0<: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "0<"                     ; name
        .half p_zgt, p_zgt_e - p_zgt    ; 0>: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "0>"                     ; name
        .half p_zne, p_zne_e - p_zne    ; 0<>: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "0<>"                    ; name
        .half p_fetch, p_fetch_e - p_fetch; @: xt, inline body bytes
        .byte F_INL, FD_LD              ; inline, folds with a literal
        .asciz "@"                      ; name
        .half p_store, p_store_e - p_store; !: xt, inline body bytes
        .byte F_INL, FD_ST              ; inline, folds with a literal
        .asciz "!"                      ; name
        .half p_cfetch, p_cfetch_e - p_cfetch; c@: xt, inline body bytes
        .byte F_INL, FD_LDB             ; inline, folds with a literal
        .asciz "c@"                     ; name
        .half p_cstore, p_cstore_e - p_cstore; c!: xt, inline body bytes
        .byte F_INL, FD_STB             ; inline, folds with a literal
        .asciz "c!"                     ; name
        .half p_wfetch, p_wfetch_e - p_wfetch; w@: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "w@"                     ; name
        .half p_wstore, p_wstore_e - p_wstore; w!: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "w!"                     ; name
        .half p_lfetch, p_lfetch_e - p_lfetch; l@: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "l@"                     ; name
        .half p_lstore, p_lstore_e - p_lstore; l!: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "l!"                     ; name
        .half p_pstore, p_pstore_e - p_pstore; +!: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "+!"                     ; name
        .half p_tor, p_tor_e - p_tor    ; >r: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz ">r"                     ; name
        .half p_rfrom, p_rfrom_e - p_rfrom; r>: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "r>"                     ; name
        .half p_rat, p_rat_e - p_rat    ; r@: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "r@"                     ; name
        .half p_rdrop, p_rdrop_e - p_rdrop; rdrop: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "rdrop"                  ; name
        .half p_2tor, p_2tor_e - p_2tor ; 2>r: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2>r"                    ; name
        .half p_2rfrom, p_2rfrom_e - p_2rfrom; 2r>: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2r>"                    ; name
        .half p_2rat, p_2rat_e - p_2rat ; 2r@: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "2r@"                    ; name
        .half p_i, p_i_e - p_i          ; i: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "i"                      ; name
        .half p_j, p_j_e - p_j          ; j: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "j"                      ; name
        .half p_unloop, p_unloop_e - p_unloop; unloop: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "unloop"                 ; name
        .half p_depth, p_depth_e - p_depth; depth: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "depth"                  ; name
        .half p_spat, p_spat_e - p_spat ; sp@: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "sp@"                    ; name
        .half p_rpat, p_rpat_e - p_rpat ; rp@: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "rp@"                    ; name
        .half p_here, p_here_e - p_here ; here: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "here"                   ; name
        .half p_latest, p_latest_e - p_latest; latest: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "latest"                 ; name
        .half p_chere, p_chere_e - p_chere; chere: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "chere"                  ; name
        .half p_pick, p_pick_e - p_pick ; pick: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "pick"                   ; name
        .half p_cores, p_cores_e - p_cores; cores: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "cores"                  ; name
        .half p_coreid, p_coreid_e - p_coreid; core#: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "core#"                  ; name
        .half p_cycles, p_cycles_e - p_cycles; cycles: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "cycles"                 ; name
        .half p_instret, p_instret_e - p_instret; instret: xt, inline body bytes
        .byte F_INL, 0                  ; inline
        .asciz "instret"                ; name
        .half p_execute, 0              ; execute: xt (called, not inlined)
        .byte F_PAGER, 0                ; it may run paged code
        .asciz "execute"                ; name
        .half p_emit, 0                 ; emit: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "emit"                   ; name
        .half p_type, 0                 ; type: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "type"                   ; name
        .half p_key, 0                  ; key: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "key"                    ; name
        .half p_accept, 0               ; accept: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "accept"                 ; name
        .half p_dot, 0                  ; .: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "."                      ; name
        .half p_udot, 0                 ; u.: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "u."                     ; name
        .half p_flush, 0                ; flush: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "flush"                  ; name
        .half p_bye, 0                  ; bye: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "bye"                    ; name
        .half p_evaluate, 0             ; evaluate: xt (called, not inlined)
        .byte F_PAGER, 0                ; it may run paged code
        .asciz "evaluate"               ; name
        .half p_evalfar, 0              ; evaluate-far: xt (called, not inlined)
        .byte F_PAGER, 0                ; it may run paged code
        .asciz "evaluate-far"           ; name
        .half p_interpret, 0            ; interpret: xt (called, not inlined)
        .byte F_PAGER, 0                ; it may run paged code
        .asciz "interpret"              ; name
        .half p_catch, 0                ; catch: xt (called, not inlined)
        .byte F_PAGER, 0                ; it may run paged code
        .asciz "catch"                  ; name
        .half p_throw, 0                ; throw: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "throw"                  ; name
        .half p_colon, 0                ; :: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz ":"                      ; name
        .half p_semi, 0                 ; ;: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz ";"                      ; name
        .half p_noname, 0               ; :noname: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz ":noname"                ; name
        .half p_create, 0               ; create: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "create"                 ; name
        .half p_constant, 0             ; constant: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "constant"               ; name
        .half p_value, 0                ; value: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "value"                  ; name
        .half p_does, 0                 ; does>: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "does>"                  ; name
        .half p_pdoes, 0                ; (does>): xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "(does>)"                ; name
        .half p_postpone, 0             ; postpone: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "postpone"               ; name
        .half p_compname, 0             ; compile-name: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "compile-name"           ; name
        .half p_tick, 0                 ; ': xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "'"                      ; name
        .half p_lbrack, 0               ; [: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "["                      ; name
        .half p_rbrack, 0               ; ]: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "]"                      ; name
        .half p_literal, 0              ; literal: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "literal"                ; name
        .half p_compile, 0              ; compile,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "compile,"               ; name
        .half p_insn, 0                 ; insn,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "insn,"                  ; name
        .half p_slitc, 0                ; slit,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "slit,"                  ; name
        .half p_dotqc, 0                ; dotq,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "dotq,"                  ; name
        .half p_recurse, 0              ; recurse: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "recurse"                ; name
        .half p_immediate, 0            ; immediate: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "immediate"              ; name
        .half p_backslash, 0            ; \: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "\\"                     ; name
        .half p_paren, 0                ; (: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "("                      ; name
        .half p_exit, 0                 ; exit: xt (called, not inlined)
        .byte F_IMM, 0                  ; immediate
        .asciz "exit"                   ; name
        .half p_mark, 0                 ; mark: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "mark"                   ; name
        .half p_ifc, 0                  ; if,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "if,"                    ; name
        .half p_aheadc, 0               ; ahead,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "ahead,"                 ; name
        .half p_resolve, 0              ; resolve: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "resolve"                ; name
        .half p_prologue, 0             ; prologue,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "prologue,"              ; name
        .half p_epilogue, 0             ; epilogue,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "epilogue,"              ; name
        .half p_codeat, 0               ; code@: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "code@"                  ; name
        .half p_codestore, 0            ; code!: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "code!"                  ; name
        .half p_install, 0              ; install: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "install"                ; name
        .half p_plocal, 0               ; (local): xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "(local)"                ; name
        .half p_localq, 0               ; local?: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "local?"                 ; name
        .half p_allot, 0                ; allot: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "allot"                  ; name
        .half p_comma, 0                ; ,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz ","                      ; name
        .half p_ccomma, 0               ; c,: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "c,"                     ; name
        .half p_align, 0                ; align: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "align"                  ; name
        .half p_source, 0               ; source: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "source"                 ; name
        .half p_parsename, 0            ; parse-name: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "parse-name"             ; name
        .half p_parse, 0                ; parse: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "parse"                  ; name
        .half p_findname, 0             ; find-name: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "find-name"              ; name
        .half p_numberq, 0              ; number?: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "number?"                ; name
        .half p_xtname, 0               ; xt>name: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "xt>name"                ; name
        .half p_fill, 0                 ; fill: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "fill"                   ; name
        .half p_move, 0                 ; move: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "move"                   ; name
        .half p_ticks, 0                ; ticks: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "ticks"                  ; name
        .half p_ms, 0                   ; ms: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "ms"                     ; name
        .half p_farat, 0                ; far@: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "far@"                   ; name
        .half p_farstore, 0             ; far!: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "far!"                   ; name
        .half p_farcat, 0               ; farc@: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "farc@"                  ; name
        .half p_farcstore, 0            ; farc!: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "farc!"                  ; name
        .half p_fflush, 0               ; fflush: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "fflush"                 ; name
        .half p_finval, 0               ; finval: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "finval"                 ; name
        .half p_spawn, 0                ; spawn: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "spawn"                  ; name
        .half p_await, 0                ; await: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "await"                  ; name
        .half p_publish, 0              ; publish: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "publish"                ; name
        .half p_reclaim, 0              ; (reclaim): xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "(reclaim)"              ; name
        .half p_xexec, 0                ; xexec: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "xexec"                  ; name
        .half p_kvar, 0                 ; kvar: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "kvar"                   ; name
        .half p_qthreads, 0             ; ?threads: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "?threads"               ; name
        .half p_included, 0             ; included: xt (called, not inlined)
        .byte F_PAGER, 0                ; it may run paged code
        .asciz "included"               ; name
        .half p_msg, 0                  ; (msg): xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "(msg)"                  ; name
        .half p_tool, 0                 ; (tool): xt (called, not inlined)
        .byte F_PAGER, 0                ; it may run paged code
        .asciz "(tool)"                 ; name
        .half tool_mark, 0              ; (mark): xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "(mark)"                 ; name
        .half tool_release, 0           ; (release): xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "(release)"              ; name
        .half p_litq, 0                 ; (lit?): xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "(lit?)"                 ; name
        .half p_units, 0                ; unit-stats: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "unit-stats"             ; name
        .half p_namext, 0               ; name>xt: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "name>xt"                ; name
        .half p_xtlit, 0                ; xtliteral: xt (called, not inlined)
        .byte 0, 0                      ; ordinary
        .asciz "xtliteral"              ; name
        .half 0                         ; end of the table
        .org  DS_TOP - 8                ; extend the D-LS image to the top of the data stack: a
        .dword 0                        ; StrataOS context switch saves the image's data extent

; =============================================================================
; The embedded source text (core.fs and what follows it), per platform: the
; labels core_fs and core_fs_end in the image's .far section. Bare metal puts
; it after the I-LS mirror (bare/source.s); the StrataOS image has it below
; the mirror, where it is assembled first (os/boot.s; os/source.s is empty).
; =============================================================================
        .include "source.s"             ; the platform's embedding, if it goes last
