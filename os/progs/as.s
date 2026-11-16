; =============================================================================
; as.s: the Strata assembler, written in Strata assembly
; =============================================================================
;
; A second implementation of sasm (asm/sasm.c). It accepts the same
; language and writes byte-identical STX2 images. It runs in two ways,
; chosen by the registers it is started with:
;
;   * Bare metal (a1 = 0, every register is 0 at reset): the source is read
;     from the console input port until end of input, the image is written
;     to the console output as raw bytes. Text origin 0. Only core 0 works.
;       strata-emu -c 1 -i prog.s as.stx > prog.stx
;   * Under StrataOS (`run as < prog.s > prog`, a0 = input length, a1 = 1):
;     c0 is a 1 MiB arena holding the input at offset 0x80000; the image is
;     written at offset 0xC0000 (256 KiB at most) and the program exits with
;     a0 = its length. Text origin 0x8000 (where StrataOS programs live).
;
; `.include` lines are accepted and skipped: a program has no file system.
; Supply included files as more input instead: concatenate them into the
; input (on the host, or as several inputs once `run` accepts more than one
; `<` file; it takes one today). Line numbers in messages count lines of the
; whole input. Errors print `line N: message` and stop (bare metal: halt with
; a0 = 1; StrataOS: exit with a0 = 0, so no output).
;
; A StrataOS program (text origin 0x8000) is assembled, as sasm does by
; default, with paged code and far data (asm/sasm.c, "paged code and far
; data"): its code is cut into groups of functions, the pinned ones stay in
; .text, the others are packed into 2 KiB code units in a section of their
; own (kind 5, the image's first), and a 4 KiB far data cache is appended to
; .data. `as` has no command line: the directives `.resident` (no paging,
; sasm's -r) and `.near` (no far data cache, sasm's -n) turn them off, and
; `.pinned` keeps a function resident. Bare metal (origin 0) is unchanged.
;
; How it works
;   * Before pass 1, a pre-scan (up to four more passes over the source, as
;     sasm's prescan) finds the .text labels, the functions (call targets),
;     the labels whose address is taken, the regions and the groups.
;   * Two passes over the source, like sasm. Pass 1 defines the symbols and
;     measures each section; pass 2 encodes. The size of every `li` is
;     decided in pass 1 (1, 2 or 6 instructions) and replayed in pass 2.
;     With paged code pass 1 repeats until the layout of the groups stops
;     changing; a symbol is defined in a pass 1 if its record carries that
;     pass's generation number.
;   * Loads and stores reach only the data Local Store (D-LS), so all tables
;     live there: symbols, keywords, the line buffer. The source stays in
;     system memory and is streamed through a 1 KiB D-LS window, once per
;     pass, with `tget`.
;   * Emission within a section only moves forward (`.org` cannot go back;
;     paged groups go to the units in source order), so after pass 1 the
;     place of every section in the output file is known. Pass 2 writes each
;     section through its own 256-byte D-LS window straight to its final
;     place, flushing a full window with `tput` (and zero windows over a
;     gap, such as the rest of a code unit).
;   * Nothing ever waits for a transfer: a load from a D-LS range that a
;     `tget` is still filling stalls, and so does a store into a range that
;     a `tput` is still reading.
;
; Register conventions (besides the usual a/t/s/ra/sp roles)
;   tp   pass number (1 or 2)          s11  current section record
;   s10  expression cursor (only inside the expression evaluator)
;
; D-LS map (everything below 0xA000, the limit for StrataOS programs)
;   0x0000 initialised tables and variables     0x1800 character classes
;   0x1900 keyword hash heads                   0x1B00 small scratch buffers
;   0x1C00 the units' output window   0x1D00 a line's labels   0x1E00 the entry's target
;   0x2000 source window   0x2400 line buffer   0x2800 output windows
;   0x2C00 li sizes        0x3000 symbol hash heads
;   0x3800..0xA000 record heap (keywords, then symbols and, with paged code,
;                  the region table; bare metal: to 0xE000)
;   stack: down from 0x10000 (StrataOS gives it to the running program)

; ---- encoding constants (mirrors asm/isa.h) ----------------------------------
OP_ALU   = 0x00                         ; register-register ALU group
OP_ADDI  = 0x01                         ; add immediate
OP_ORI   = 0x03                         ; or immediate
OP_SLLI  = 0x05                         ; shift left immediate
OP_LUI   = 0x0A                         ; load upper immediate
OP_JAL   = 0x28                         ; jump and link
OP_JALR  = 0x29                         ; jump and link register
OP_TWAIT = 0x31                         ; wait for transfer tags
OP_CAP   = 0x34                         ; capability group
OP_CSRW  = 0x39                         ; write a CSR
OP_XCALL = 0x3E                         ; xcall / xret
CF_BASE  = 6                            ; capability group: cbase
ALU_ADD  = 0                            ; ALU function: add
ALU_ORF  = 3                            ; ALU function: or
XRET_FN  = 16                           ; xcall group: the return bit (xret)
CSR_TTAG = 8                            ; CSR numbers the start-up stub writes: ttag
CSR_TDATA = 9                           ; tdata
CSR_TGEOM = 10                          ; tgeom
CSR_XSLOT = 25                          ; xslot
RT6      = 31                           ; t6: the scratch register of the rewrites
RT0      = 5                            ; t0: the stub's scratch register
ILS_BYTES = 65536                       ; instruction Local Store size
DLS_BYTES = 65536                       ; data Local Store size
T2_BYTES = 262144                       ; cluster store size
T3_BYTES = 67108864                     ; system memory size (64 MiB)
SK_ILS   = 1                            ; STX section kinds: instruction LS
SK_DLS   = 2                            ; data LS
SK_T3    = 3                            ; system memory
SK_T2    = 4                            ; cluster store
SK_UNITS = 5                            ; paged code units (image offsets)
S_UNITS  = 4                            ; section index of the units
UNIT     = 2048                         ; code unit size (sasm's default -u 2)
ULG      = 11                           ; its log2 (the stub's xslot)
GEOM     = 6 | 5 << 6 | 2 << 12 | 1 << 16 ; tgeom: 64-byte lines, 32 sets, 2 ways, FA
CLINES   = 4096                         ; the far data cache: lines (sasm's -c 4)
CTAGS    = 768                          ; and tags (32 sets, 2 ways, 3 dwords)
FL_TL    = 1                            ; symbol record flags: a .text label
FL_FUNC  = 2                            ; a function (a call target)
FL_TAKEN = 4                            ; its address is taken
RG_GRP   = 0                            ; region record (16 bytes): its group (u16, the group's first region)
RG_JOIN  = 2                            ; joined to the next region (u8)
RG_PIN   = 3                            ; the region is pinned (u8)
RG_GPIN  = 4                            ; group: pinned (u8: 1, or 2 if larger than a unit)
RG_BASE  = 8                            ; group: where it starts (u32)
RG_LOC   = 12                           ; group: where it is now (u32; its size after layout_groups)
RGSZ     = 16                           ; record size
W_NOP    = OP_ADDI << 26                ; instructions of the rewrites: nop
W_JR6    = OP_JALR << 26 | RT6 << 16    ; jalr zero, t6, 0
W_ORI6   = OP_ORI << 26 | RT6 << 21     ; ori t6, zero, 0
W_XC6    = OP_XCALL << 26 | RT6 << 16 | 15 ; xcall zero, c15, t6
W_XRET   = OP_XCALL << 26 | XRET_FN     ; xret zero
W_CBASE  = OP_CAP << 26 | 1 << 21 | 15 << 16 | CF_BASE ; cbase ra, c15
W_ADDRA  = 1 << 21 | 1 << 16 | RT6 << 11 | ALU_ADD ; add ra, ra, t6
W_T6ONE  = OP_ADDI << 26 | RT6 << 21 | 1 ; addi t6, zero, 1
W_T6SH   = OP_SLLI << 26 | RT6 << 21 | RT6 << 16 | 63 ; slli t6, t6, 63
W_ORRA   = 1 << 21 | 1 << 16 | RT6 << 11 | ALU_ORF ; or ra, ra, t6
W_XSL1   = OP_ADDI << 26 | RT0 << 21 | ULG ; addi t0, zero, ULG
W_CSRW0  = OP_CSRW << 26 | RT0 << 16    ; csrw 0, t0

; ---- instruction formats: index into the handler table `jtab` --------------
F_R      = 0                            ; rd, rs1, rs2
F_I      = 1                            ; rd, rs1, signed imm16
F_IU     = 2                            ; rd, rs1, unsigned imm16
F_SH     = 3                            ; rd, rs1, shift amount
F_LUI    = 4                            ; rd, imm16
F_LD     = 5                            ; reg, offset(base) (loads and stores)
F_B      = 6                            ; rs1, rs2, target
F_JAL    = 7                            ; rd, target
F_XF     = 8                            ; tag, ls, cap, offset, length
F_TWAIT  = 9                            ; tag list or mask
F_TPOLL  = 10                           ; rd, tag list or mask
F_AMO    = 11                           ; rd, cap, addr, value
F_CDCS   = 12                           ; cd, cs
F_CDCSRX = 13                           ; cd, cs, rs
F_RDCS   = 14                           ; rd, cs
F_CPOLL  = 15                           ; rd
F_CSRX   = 16                           ; cs, rs
F_CTAKE  = 17                           ; cd [, rs]
F_CD     = 18                           ; cd
F_CSSLOT = 19                           ; cs, slot
F_CDSLOT = 20                           ; cd, slot
F_CSRR   = 21                           ; rd, csr
F_CSRW   = 22                           ; csr, rs
F_SYS    = 23                           ; no operands: op, imm = fn
F_RRK    = 24                           ; rd, rs: imm = fn (ltag, mv, seqz)
F_LINST  = 25                           ; rs (linst)
F_XMAP   = 26                           ; idx, rs1, cap, rs2
F_XUNMAP = 27                           ; idx
F_XCALL  = 28                           ; rd, cap, rs
P_R0     = 29                           ; rd, rs: ALU fn with rs1 = zero (snez, neg)
P_LI     = 30                           ; rd, value (fn = 1 for la)
P_J      = 31                           ; target, rd = fn (j, call)
P_RET    = 32                           ; ret
P_TFENCE = 33                           ; tfence
P_BZ     = 34                           ; rs, target: compare with zero (fn = swap)
P_B2     = 35                           ; rs1, rs2, target with swapped registers
D_SECT   = 36                           ; .text .data .far .cluster (fn = index)
D_NOP    = 37                           ; .global .globl
D_ASCII  = 38                           ; .ascii (fn = 0), .asciz .string (fn = 1)
D_DATA   = 39                           ; .byte .half .word .dword (fn = width)
D_SPACE  = 40                           ; .space .zero
D_ALIGN  = 41                           ; .align
D_ORG    = 42                           ; .org
D_EQU    = 43                           ; .equ .set
F_XRET   = 44                           ; rs (xret)
F_CSEND  = 45                           ; cs, ce (csend)
F_MKEP   = 46                           ; cd, rs (cmkep)
P_JR     = 47                           ; rs (jr: xret rs with paged code)
P_JALR   = 48                           ; rd, rs, imm (jalr, rewritten in paged code)
D_RES    = 49                           ; .resident (the pre-scan's)
D_NEAR   = 50                           ; .near (the pre-scan's)
D_PIN    = 51                           ; .pinned (the pre-scan's)
ANY      = 255                          ; operand count not checked up front
GX       = 1 << 4                       ; h_gen operand kinds: x register
GC       = 2 << 4                       ; capability register
GCSR     = 3 << 4                       ; CSR
GM       = 4 << 4                       ; offset(base): offset (signed 16 bits), base in rs1
GE       = 5 << 4                       ; an expression, + 16 * its range (check_imm's)
QRD      = 0                            ; h_gen operand fields: rd
QRS1     = 1                            ; rs1
QRS2     = 2                            ; rs2
QIMM     = 3                            ; the 16-bit immediate
QFN7     = 4                            ; function: value << 7
QFN5     = 5                            ; function: (value & 63) << 5
QFN      = 6                            ; function: value
K_OP     = 1                            ; keyword class: instruction or directive
K_REG    = 2                            ; keyword class: integer register name
K_CSR    = 3                            ; keyword class: CSR name
KS_NONE  = 0                            ; keyword group step: none
KS_FMT   = 1                            ; the format (a register's or CSR's number) + 1
KS_OP    = 2                            ; the opcode + 1
KS_FN    = 3                            ; the function + 1
KS_FN2   = 4                            ; the function * 2

; ---- memory map ----------------------------------------------------------------
STACKTOP = 0x10000                      ; top of the D-LS: the stack grows down
CCLASS   = 0x1800                       ; 256 character-class bytes
KWHASH   = 0x1900                       ; 256 keyword chain heads (u16 record addresses)
KWMASK   = 255                          ; keyword hash mask
MBUF     = 0x1B00                       ; lower-cased mnemonic (64 bytes)
NUMBUF   = 0x1B40                       ; decimal digits for messages (32 bytes)
HDRBUF   = 0x1B60                       ; STX header staging (16 bytes)
BYTEBUF  = 0x1B70                       ; console input byte (8 bytes)
OPS      = 0x1B80                       ; up to 8 operand pointers
MAXOPS   = 8                            ; operand limit, as in sasm
UWIN     = 0x1C00                       ; the units' output window (256 bytes)
LABS     = 0x1D00                       ; a line's labels: up to 8 of (name, length, hash)
MAXLABS  = 8                            ; (sasm's pre-scan keeps 8)
ENTBUF   = 0x1E00                       ; the entry's `j` target (255 characters and a NUL)
INBUF    = 0x2000                       ; source window (also input gathering and output copying)
INSZ     = 1024                         ; its size
LINEBUF  = 0x2400                       ; current line, NUL-terminated
LINEMAX  = 1000                         ; longest line accepted
WINBUF   = 0x2800                       ; four section output windows (the units': UWIN)
WINSZ    = 256                          ; bytes per window
LITAB    = 0x2C00                       ; li sizes, 2 bits each
LIMAX    = 4096                         ; li/la limit
SYMHASH  = 0x3000                       ; 1024 symbol chain heads (u16)
SYMMASK  = 1023                         ; symbol hash mask
HEAP     = 0x3800                       ; record heap start
HEAPEND  = 0xA000                       ; record heap end (StrataOS data limit)
HEAPEND_BARE = 0xE000                   ; ... on bare metal (8 KiB of stack above it)

; ---- arena layouts in system memory (offsets within c0) ------------------------
IN_OS    = 0x80000                      ; StrataOS: input
INMAX_OS = 0x40000                      ; at most 256 KiB of it
OUT_OS   = 0xC0000                      ; StrataOS: output
OUTMAX_OS = 0x40000                     ; at most 256 KiB of it
ORG_OS   = 0x8000                       ; StrataOS: text origin
OUT_BARE = 0x100000                     ; bare metal: output
OUTMAX_BARE = 0x700000                  ; at most 7 MiB of it
IN_BARE  = 0x800000                     ; bare metal: input
INMAX_BARE = 0x7F0000                   ; at most this much of it
CON_IN   = 8                            ; console input port in device space

; ---- character classes ------------------------------------------------------------
C_SP     = 1                            ; isspace
C_SS     = 2                            ; may start a symbol: letter _ . $
C_SC     = 4                            ; may continue a symbol: also digits
C_DG     = 8                            ; decimal digit
C_HX     = 16                           ; hexadecimal digit

; ---- section record (one per section, SREC bytes) ------------------------------------
S_LOC    = 0                            ; current location
S_LO     = 8                            ; lowest address emitted (-1 = none)
S_SIZE   = 16                           ; highest location reached
S_LIMIT  = 24                           ; size of the address space
S_KIND   = 32                           ; STX section kind
S_WBASE  = 40                           ; pass 2: address of the window's first byte
S_WBUF   = 48                           ; pass 2: D-LS address of the window
S_FADJ   = 56                           ; pass 2: arena offset of address 0 of the section
S_HDR    = 64                           ; file offset of the section header
S_BASE   = 72                           ; section base: lowest address rounded down to 8
SREC     = 80                           ; record size
NSECT    = 5                            ; .text .data .far .cluster and the units

; ---- symbol / keyword record (in the heap, 8-byte aligned) -----------------------
R_VAL    = 0                            ; value (8 bytes)
R_NEXT   = 8                            ; next record in the chain (u16, 0 = end)
R_LEN    = 10                           ; name length (u8)
R_SECT   = 11                           ; section, 255 = none (keywords: class)
R_REG    = 12                           ; .text label: its region (u16, 0xFFFF = none)
R_FL     = 14                           ; flags (FL_TL, FL_FUNC, FL_TAKEN)
R_GEN    = 15                           ; the pass 1 that defined it (0 = not yet)
R_NAME   = 16                           ; name bytes follow

; =============================================================================
        .data                           ; D-LS image: tables and variables
; =============================================================================
        .align 8                        ; variables are 64-bit words
v_mode:   .dword 0                      ; 1 = under StrataOS, 0 = bare metal
v_hend:   .dword HEAPEND                ; record heap end (bare metal: HEAPEND_BARE)
v_org:    .dword 0                      ; text origin
v_inbase: .dword 0                      ; arena offset of the source
v_inlen:  .dword 0                      ; source length
v_outbase: .dword 0                     ; arena offset of the image
v_outmax: .dword 0                      ; largest image allowed
v_line:   .dword 0                      ; current line number
v_pos:    .dword 0                      ; source bytes consumed
v_chunk:  .dword 0                      ; source offset of the window contents
v_heap:   .dword 0                      ; heap top
v_lii:    .dword 0                      ; li index (counts li/la lines)
v_cs:     .dword 0                      ; current section index
v_undef:  .dword 0                      ; expression used an undefined symbol
v_esect:  .dword 0                      ; section of the label it used, -1 if none
v_nops:   .dword 0                      ; operand count of the current line
v_rest:   .dword 0                      ; text after the mnemonic
v_op:     .dword 0                      ; opcode of the current instruction
v_fn:     .dword 0                      ; function field / flag of it
v_fmt:    .dword 0                      ; format of the current instruction
v_total:  .dword 0                      ; image length
v_count:  .dword 0                      ; number of sections in the image

v_paged:  .dword -1                     ; paged code: 1, 0, -1 = by the text origin
v_far:    .dword -1                     ; far data: 1, 0, -1 = by the text origin
v_gen:    .dword 0                      ; generation of the current pass 1
v_first:  .dword 0                      ; line of the first .text instruction (0 = none)
v_firstj: .dword 0                      ; 1 if it is `j`
v_own15:  .dword 0                      ; first line naming c15 (0 = none)
v_owncode: .dword 0                     ; first line paging code itself (xcall, xmap, csrw xslot ...)
v_owncache: .dword 0                    ; first line managing a data cache (ltag, csrw ttag ...)
v_psect:  .dword 0                      ; pre-scan: the section a line starts in
v_ltext:  .dword 0                      ; pre-scan: 1 if the line is .text code (not a section directive)
v_nlabs:  .dword 0                      ; labels of the line (in LABS)
v_mk:     .dword 0                      ; its mnemonic: 0 none, 1 a mnemonic (MBUF), 2 `name = expr`
v_mrec:   .dword 0                      ; its keyword record, 0 if unknown
v_mfmt:   .dword 0                      ; its format, 255 if none
v_mop:    .dword 0                      ; its opcode
v_mfn:    .dword 0                      ; its function
v_mrest:  .dword 0                      ; the text after it (after `=` for `name = expr`)
v_regctr: .dword -1                     ; the last region started (-1 = none yet)
v_nreg:   .dword 0                      ; number of regions
v_regs:   .dword 0                      ; the region table (RGSZ bytes per region)
v_lastreg: .dword -1                    ; pre-scan: region of the last .text line
v_lastterm: .dword 1                    ; pre-scan: its last instruction ended it
v_laid:   .dword 0                      ; 1 once layout_groups has placed the groups
v_pend:   .dword 0                      ; the end of the pinned code
v_lreg:   .dword -1                     ; the current line's region, -1 if not paged code
v_lgrp:   .dword -1                     ; its group
v_lgrec:  .dword 0                      ; the group's record
v_lpaged: .dword 0                      ; 1 if the group is paged (not pinned)
v_uloc:   .dword 0                      ; the location of the section the line was moved to
v_entry:  .dword 0                      ; 1 once the entry's target is in ENTBUF
v_stubat: .dword 0                      ; where pass 1 put the start-up stub
v_cacheat: .dword 0                     ; and where it put the cache

sects:                                  ; section records: .text .data .far .cluster, the units
        .dword 0, 0, 0, ILS_BYTES, SK_ILS, 0, WINBUF, 0 ; .text: loc, lo, size, limit, kind, window
        .dword 0, 0                     ; header offset, base
        .dword 0, 0, 0, DLS_BYTES, SK_DLS, 0, WINBUF + 256, 0 ; .data
        .dword 0, 0                     ; header offset, base
        .dword 0, 0, 0, T3_BYTES, SK_T3, 0, WINBUF + 512, 0 ; .far
        .dword 0, 0                     ; header offset, base
        .dword 0, 0, 0, T2_BYTES, SK_T2, 0, WINBUF + 768, 0 ; .cluster
        .dword 0, 0                     ; header offset, base
        .dword 0, 0, 0, 0x100000, SK_UNITS, 0, UWIN, 0 ; the units (image offsets, 1 MiB at most)
        .dword 0, 0                     ; header offset, base
sorder: .byte 4, 0, 1, 2, 3             ; the order of the sections in the image: the units first
        .align 8                        ; (the tables below are words)

jtab:                                   ; handler for each format, by format number
        .word h_gen, h_gen, h_gen, h_gen, h_gen, h_gen, h_b, h_jal ; F_R .. F_JAL
        .word h_xf, h_twait, h_tpoll, h_gen, h_gen, h_gen, h_gen, h_gen ; F_XF .. F_CPOLL
        .word h_gen, h_ctake, h_gen, h_gen, h_gen, h_gen, h_gen, h_gen ; F_CSRX .. F_SYS
        .word h_gen, h_gen, h_gen, h_gen, h_gen, h_gen, h_li, h_j ; F_RRK .. P_J
        .word h_ret, h_tfence, h_bz, h_b2, d_sect, d_nop, d_ascii, d_data ; P_RET .. D_DATA
        .word d_space, d_align, d_org, d_equ, h_gen, h_gen, h_gen, h_jr ; D_SPACE .. P_JR
        .word h_jalr, d_nop, d_nop, d_nop ; P_JALR .. D_PIN

ez_ops: .asciz "|^&<>+-*/%"             ; e_bin's operators
ez_lvl: .byte 0, 1, 2, 3, 3, 4, 4, 5     ; and their levels
        .byte 5, 5                      ; ...
        .align 4                        ; (words follow)
ez_jt:  .word ez_or, ez_xor, ez_and, ez_shl, ez_shr, ez_add, ez_sub, ez_mul ; and code
        .word ez_div, ez_rem            ; ...

gdesc:                                  ; h_gen's operands, 4 specs per format (0: none)
        .byte GX|QRD, GX|QRS1, GX|QRS2, 0, GX|QRD, GX|QRS1, GE|QIMM, 0 ; F_R; F_I
        .byte GX|QRD, GX|QRS1, GE+16|QIMM, 0, GX|QRD, GX|QRS1, GE+32|QIMM, 0 ; F_IU; F_SH
        .byte GX|QRD, GE+48|QIMM, 0, 0, GX|QRD, GM|QIMM, 0, 0 ; F_LUI; F_LD
        .dword 0, 0                     ; F_B .. F_TWAIT (their own handlers)
        .byte 0, 0, 0, 0, GX|QRD, GC|QFN7, GX|QRS1, GX|QRS2 ; F_TPOLL; F_AMO
        .byte GC|QRD, GC|QRS1, 0, 0, GC|QRD, GC|QRS1, GX|QRS2, 0 ; F_CDCS; F_CDCSRX
        .byte GX|QRD, GC|QRS1, 0, 0, GX|QRD, 0, 0, 0 ; F_RDCS; F_CPOLL
        .byte GC|QRS1, GX|QRS2, 0, 0, GC|QRD, 0, 0, 0 ; F_CSRX; F_CTAKE (one operand)
        .byte GC|QRD, 0, 0, 0, GC|QRS1, GE+64|QFN5, 0, 0 ; F_CD; F_CSSLOT
        .byte GC|QRD, GE+64|QFN5, 0, 0, GX|QRD, GCSR|QIMM, 0, 0 ; F_CDSLOT; F_CSRR
        .byte GCSR|QIMM, GX|QRS1, 0, 0, 0, 0, 0, 0 ; F_CSRW; F_SYS
        .byte GX|QRD, GX|QRS1, 0, 0, GX|QRS1, 0, 0, 0 ; F_RRK; F_LINST
        .byte GE+80|QRD, GX|QRS1, GC|QFN, GX|QRS2, GE+80|QRD, 0, 0, 0 ; F_XMAP; F_XUNMAP
        .byte GX|QRD, GC|QFN, GX|QRS1, 0, GX|QRD, GX|QRS2, 0, 0 ; F_XCALL; P_R0
        .dword 0, 0, 0, 0, 0, 0, 0      ; P_LI .. D_EQU (their own handlers)
        .byte GX|QRS1, 0, 0, 0, GC|QRS1, GC|QRD, 0, 0 ; F_XRET; F_CSEND
        .byte GC|QRD, GX|QRS2, 0, 0     ; F_MKEP
        .align 8                        ; (variables follow)

; Keyword table, in groups: class, format (a register's or CSR's number),
; operand count, opcode, function, step; then the group's names, separated
; by blanks. Each name after the first adds the step to its predecessor's
; fields: KS_NONE nothing, KS_FMT 1 to the format (the number), KS_OP 1 to
; the opcode, KS_FN 1 to the function, KS_FN2 doubles the function. Copied
; into the keyword hash at start-up; a class of 0 ends it.
kwtab:                                  ; keyword table (copied into the keyword hash at start-up)
        .byte K_OP, F_R, 3, 0x00, 0, KS_FN ; the ALU group, functions 0..15
        .asciz "add sub and or xor sll srl sra slt sltu mul mulhu divu remu div rem" ; ...
        .byte K_OP, F_I, 3, 0x01, 0, KS_NONE ; rd = rs1 + imm
        .asciz "addi"                   ; ...
        .byte K_OP, F_I, 3, 0x08, 0, KS_OP ; set if less than immediate (signed, unsigned)
        .asciz "slti sltiu"             ; ...
        .byte K_OP, P_JALR, 3, 0x29, 0, KS_NONE ; jump and link register (rewritten in paged code)
        .asciz "jalr"                   ; ...
        .byte K_OP, F_IU, 3, 0x02, 0, KS_OP ; and, or, xor immediate (zero-extended)
        .asciz "andi ori xori"          ; ...
        .byte K_OP, F_SH, 3, 0x05, 0, KS_OP ; shifts by an immediate
        .asciz "slli srli srai"         ; ...
        .byte K_OP, F_LUI, 2, 0x0A, 0, KS_NONE ; load upper immediate
        .asciz "lui"                    ; ...
        .byte K_OP, F_LD, 2, 0x10, 0, KS_OP ; loads, opcodes 0x10..0x16
        .asciz "ld lw lwu lh lhu lb lbu" ; ...
        .byte K_OP, F_LD, 2, 0x18, 0, KS_OP ; stores, opcodes 0x18..0x1B
        .asciz "sd sw sh sb"            ; ...
        .byte K_OP, F_B, 3, 0x20, 0, KS_OP ; branches, opcodes 0x20..0x25
        .asciz "beq bne blt bge bltu bgeu" ; ...
        .byte K_OP, F_JAL, 2, 0x28, 0, KS_NONE ; jump and link
        .asciz "jal"                    ; ...
        .byte K_OP, F_XF, 5, 0x30, 0, KS_FN ; transfers: get, put, get code
        .asciz "tget tput tgetx"        ; ...
        .byte K_OP, F_TWAIT, ANY, 0x31, 0, KS_NONE ; wait for tags
        .asciz "twait"                  ; ...
        .byte K_OP, F_TPOLL, ANY, 0x32, 0, KS_NONE ; poll tags
        .asciz "tpoll"                  ; ...
        .byte K_OP, F_AMO, 4, 0x33, 0, KS_FN ; far atomics, functions 0..4
        .asciz "tamo.add tamo.swap tamo.cas tamo.and tamo.or" ; ...
        .byte K_OP, F_CDCS, 2, 0x34, 0, KS_NONE ; move a capability
        .asciz "cmov"                   ; ...
        .byte K_OP, F_CDCSRX, 3, 0x34, 1, KS_NONE ; split a capability
        .asciz "csplit"                 ; ...
        .byte K_OP, F_CDCS, 2, 0x34, 2, KS_FN ; join, read-only share, atomic-only
        .asciz "cjoin cshare catomic"   ; ...
        .byte K_OP, F_CDCSRX, 3, 0x34, 5, KS_NONE ; drop permissions
        .asciz "crestrict"              ; ...
        .byte K_OP, F_RDCS, 2, 0x34, 6, KS_FN ; base, length, permissions
        .asciz "cbase clen cperms"      ; ...
        .byte K_OP, F_CSRX, 2, 0x34, 9, KS_NONE ; give a capability to a node
        .asciz "cgive"                  ; ...
        .byte K_OP, F_CTAKE, ANY, 0x34, 10, KS_NONE ; take one from the inbox
        .asciz "ctake"                  ; ...
        .byte K_OP, F_CD, 1, 0x34, 11, KS_NONE ; clear a capability register
        .asciz "cclear"                 ; ...
        .byte K_OP, F_CSSLOT, 2, 0x34, 12, KS_NONE ; capability -> table slot
        .asciz "csave"                  ; ...
        .byte K_OP, F_CDSLOT, 2, 0x34, 13, KS_NONE ; table slot -> capability
        .asciz "crestore"               ; ...
        .byte K_OP, F_RDCS, 2, 0x34, 14, KS_NONE ; capability validity
        .asciz "cvalid"                 ; ...
        .byte K_OP, F_CPOLL, 1, 0x34, 15, KS_NONE ; inbox senders
        .asciz "cpoll"                  ; ...
        .byte K_OP, F_CDCS, 2, 0x35, 0, KS_FN ; revocation domains: make, revoke, dissolve
        .asciz "cdom crevoke cundom"    ; ...
        .byte K_OP, F_CSEND, 2, 0x35, 3, KS_NONE ; send a capability to an endpoint
        .asciz "csend"                  ; ...
        .byte K_OP, F_CDCS, 2, 0x35, 4, KS_NONE ; receive one
        .asciz "crecv"                  ; ...
        .byte K_OP, F_MKEP, 2, 0x35, 5, KS_NONE ; make an endpoint capability
        .asciz "cmkep"                  ; ...
        .byte K_OP, F_CSRX, 2, 0x35, 6, KS_NONE ; capability -> table slot x[rs]
        .asciz "csavex"                 ; ...
        .byte K_OP, F_MKEP, 2, 0x35, 7, KS_NONE ; table slot x[rs] -> capability
        .asciz "crestorex"              ; ...
        .byte K_OP, F_RRK, 2, 0x36, 0, KS_NONE ; wait for any of tags or the inbox
        .asciz "tany"                   ; ...
        .byte K_OP, F_CSRR, 2, 0x38, 0, KS_NONE ; read a CSR
        .asciz "csrr"                   ; ...
        .byte K_OP, F_CSRW, 2, 0x39, 0, KS_NONE ; write a CSR
        .asciz "csrw"                   ; ...
        .byte K_OP, F_SYS, 0, 0x3A, 0, KS_FN ; the system group: stop, return from a trap, a service
        .asciz "halt eret svc"          ; ...
        .byte K_OP, F_RRK, 2, 0x3B, 0, KS_NONE ; software cache lookup
        .asciz "ltag"                   ; ...
        .byte K_OP, F_LINST, 1, 0x3C, 0, KS_NONE ; software cache install
        .asciz "linst"                  ; ...
        .byte K_OP, F_XMAP, 4, 0x3D, 0, KS_NONE ; map an overlay
        .asciz "xmap"                   ; ...
        .byte K_OP, F_XUNMAP, 1, 0x3D, 16, KS_NONE ; unmap an overlay (the unmap bit)
        .asciz "xunmap"                 ; ...
        .byte K_OP, F_XCALL, 3, 0x3E, 0, KS_NONE ; call through an overlay
        .asciz "xcall"                  ; ...
        .byte K_OP, F_XRET, 1, 0x3E, 16, KS_NONE ; return through a far link
        .asciz "xret"                   ; ...
        .byte K_OP, F_SYS, 0, 0x01, 0, KS_NONE ; pseudo: addi zero, zero, 0
        .asciz "nop"                    ; ...
        .byte K_OP, F_RRK, 2, 0x01, 0, KS_NONE ; pseudo: addi rd, rs, 0
        .asciz "mv"                     ; ...
        .byte K_OP, F_RRK, 2, 0x09, 1, KS_NONE ; pseudo: sltiu rd, rs, 1
        .asciz "seqz"                   ; ...
        .byte K_OP, P_R0, 2, 0x00, 9, KS_NONE ; pseudo: sltu rd, zero, rs
        .asciz "snez"                   ; ...
        .byte K_OP, P_R0, 2, 0x00, 1, KS_NONE ; pseudo: sub rd, zero, rs
        .asciz "neg"                    ; ...
        .byte K_OP, P_LI, 2, 0, 0, KS_FN ; pseudo: load immediate (sized in pass 1), address (2 instructions)
        .asciz "li la"                  ; ...
        .byte K_OP, P_J, 1, 0x28, 0, KS_FN ; pseudo: jal zero / jal ra, target (rd = function)
        .asciz "j call"                 ; ...
        .byte K_OP, P_RET, 0, 0x29, 0, KS_NONE ; pseudo: jalr zero, ra, 0 (xret ra with paged code)
        .asciz "ret"                    ; ...
        .byte K_OP, P_JR, 1, 0x29, 0, KS_NONE ; pseudo: jalr zero, rs, 0 (xret rs with paged code)
        .asciz "jr"                     ; ...
        .byte K_OP, P_TFENCE, 0, 0x31, 0, KS_NONE ; pseudo: twait 0xffff
        .asciz "tfence"                 ; ...
        .byte K_OP, P_BZ, 2, 0x20, 0, KS_OP ; pseudo: beq, bne, blt, bge rs, zero
        .asciz "beqz bnez bltz bgez"    ; ...
        .byte K_OP, P_BZ, 2, 0x22, 1, KS_OP ; pseudo: blt, bge zero, rs (swapped)
        .asciz "bgtz blez"              ; ...
        .byte K_OP, P_B2, 3, 0x22, 0, KS_OP ; pseudo: blt, bge, bltu, bgeu rs2, rs1 (swapped)
        .asciz "bgt ble bgtu bleu"      ; ...
        .byte K_OP, D_SECT, ANY, 0, 0, KS_FN ; directives: the sections 0..3
        .asciz ".text .data .far .cluster" ; ...
        .byte K_OP, D_RES, ANY, 0, 0, KS_FMT ; directives the pre-scan reads: no paged code,
        .asciz ".resident .near .pinned" ; no far data cache, keep this function resident
        .byte K_OP, D_NOP, ANY, 0, 0, KS_NONE ; directives: ignored
        .asciz ".global .globl"         ; ...
        .byte K_OP, D_ASCII, ANY, 0, 0, KS_FN ; string bytes, without and with a NUL
        .asciz ".ascii .asciz"          ; ...
        .byte K_OP, D_ASCII, ANY, 0, 1, KS_NONE ; the same as .asciz
        .asciz ".string"                ; ...
        .byte K_OP, D_DATA, ANY, 0, 1, KS_FN2 ; values of widths 1, 2, 4, 8
        .asciz ".byte .half .word .dword" ; ...
        .byte K_OP, D_SPACE, ANY, 0, 0, KS_NONE ; fill bytes: size [, fill]
        .asciz ".space .zero"           ; ...
        .byte K_OP, D_ALIGN, ANY, 0, 0, KS_NONE ; pad to a power of two
        .asciz ".align"                 ; ...
        .byte K_OP, D_ORG, ANY, 0, 0, KS_NONE ; pad up to an address
        .asciz ".org"                   ; ...
        .byte K_OP, D_EQU, ANY, 0, 0, KS_NONE ; define a constant: name, value
        .asciz ".equ .set"              ; ...
        .byte K_REG, 0, 0, 0, 0, KS_FMT ; integer registers x0..x31
        .asciz "zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6" ; ...
        .byte K_REG, 8, 0, 0, 0, KS_NONE ; x8, other name
        .asciz "fp"                     ; ...
        .byte K_CSR, 0, 0, 0, 0, KS_FMT ; CSRs 0..28
        .asciz "cycle instret cause epc tval tvec ccr coreid ttag tdata tgeom ncores scratch stalls takefrom corebase corecount reserved17 status ucause uepc utval utvec sscratch ipend xslot wdata wstack wcode" ; ...
        .byte 0                         ; end of the table

s_include: .asciz ".include"            ; the line form sasm reads as an include
m_line:   .asciz "line "                ; error message prefix
m_colon:  .asciz ": "                   ; after the line number
m_as:     .asciz "as: "                 ; prefix for errors outside any line
m_sp:     .asciz " "                    ; between a message and a name
m_nl:     .asciz "\n"                   ; end of a message
m_usage:  .asciz "as: usage: run as < prog.s > prog\n" ; StrataOS without `>`
m_inbig:  .asciz "input too large"      ; source does not fit
m_outbig: .asciz "output too large"     ; image does not fit
m_long:   .asciz "line too long"        ; longer than LINEMAX
m_full:   .asciz "symbol table full"    ; heap exhausted
m_redef:  .asciz "symbol redefined:"    ; label or constant defined twice
m_nlong:  .asciz "symbol name too long" ; more than 255 characters
m_later:  .asciz "uses a symbol defined later" ; constant with a forward reference
m_unkd:   .asciz "unknown directive"    ; no such directive
m_unki:   .asciz "unknown instruction"  ; no such mnemonic
m_nops:   .asciz "wrong number of operands" ; operand count mismatch
m_many:   .asciz "too many operands"    ; more than 8
m_junk:   .asciz "junk after expression:" ; text left over
m_paren:  .asciz "expected ')'"         ; unbalanced parenthesis
m_chr:    .asciz "bad character literal" ; malformed 'c'
m_bad:    .asciz "bad expression near"  ; nothing an expression can start with
m_undef:  .asciz "undefined symbol"     ; pass 2 reference to an unknown name
m_div0:   .asciz "division by zero"     ; / or % by 0
m_xreg:   .asciz "expected integer register, got" ; bad x register
m_creg:   .asciz "expected capability register c0..c15, got" ; bad c register
m_tag:    .asciz "expected transfer tag tg0..tg15, got" ; bad tag
m_csr:    .asciz "CSR number out of range" ; not 0..0xffff
m_mem:    .asciz "expected offset(register), got" ; bad memory operand
m_simm:   .asciz "immediate does not fit in signed 16 bits" ; range
m_uimm:   .asciz "immediate does not fit in unsigned 16 bits" ; range
m_imm:    .asciz "immediate does not fit in 16 bits" ; range
m_shamt:  .asciz "shift amount out of range" ; not 0..63
m_slot:   .asciz "capability slot out of range 0..63" ; not 0..63
m_xidx:   .asciz "overlay map index out of range 0..15" ; not 0..15
m_tags:   .asciz "expected a list of tags or one mask" ; bad twait/tpoll operand
m_tpoll:  .asciz "tpoll rd, tags"       ; too few operands
m_sect:   .asciz "branch target is in another section:" ; cross-section branch
m_balign: .asciz "branch target not 4-byte aligned" ; odd target
m_range:  .asciz "branch target out of range" ; too far
m_ialign: .asciz "instruction not 4-byte aligned" ; misplaced instruction
m_ovf:    .asciz "section overflows its address space" ; past the limit
m_limax:  .asciz "too many li/la"       ; li size table full
m_la:     .asciz "la address out of range" ; not 0..0x7fffffff
m_str:    .asciz "expected string"      ; no opening quote
m_unterm: .asciz "unterminated string"  ; no closing quote
m_space:  .asciz ".space needs a known non-negative size" ; bad size
m_align:  .asciz ".align needs a power of two" ; bad alignment
m_org:    .asciz ".org cannot move backwards" ; bad address
m_equ:    .asciz ".equ name, value"     ; wrong operand count
m_c15:    .asciz "paged code uses c15 (.resident)" ; c15 is the kernel's
m_owncode: .asciz "pages its own code (.resident)" ; xcall, xmap, csrw xslot
m_owncache: .asciz "has its own data cache (.near)" ; ltag, csrw ttag
m_entry:  .asciz "the first instruction must be j" ; paged code or far data
m_jalr:   .asciz "paged code: only jalr ra, rs, 0" ; (rs not ra or t6)
m_orgp:   .asciz ".org in paged code"   ; (.resident)
m_ent2:   .asciz "the entry's target is not code" ; j to a constant
m_settle: .asciz "the layout does not settle" ; 21 passes
m_room:   .asciz "no room for two code units" ; past 0x10000
m_dfar:   .asciz "the far data cache ends past 0xA000 (.near)" ; too much data
s_c15:    .asciz "c15"                  ; the operands the pre-scan looks for
s_xslot:  .asciz "xslot"                ; ...
s_ttag:   .asciz "ttag"                 ; ...
s_tdata:  .asciz "tdata"                ; ...
s_tgeom:  .asciz "tgeom"                ; ...
s_pinit:  .asciz "__pinit"              ; the start-up stub
s_fclines: .asciz "__fc_lines"          ; the far data cache's lines
s_fctags: .asciz "__fc_tags"            ; and its tags

        .align 8                        ; 64-bit table entries
ranges: .dword -32768, 32767            ; 0: signed 16 bits (lowest, highest)
        .dword 0, 65535                 ; 1: unsigned 16 bits
        .dword 0, 63                    ; 2: shift amount
        .dword -32768, 65535            ; 3: lui immediate (either reading)
        .dword 0, 63                    ; 4: capability table slot
        .dword 0, 15                    ; 5: overlay map index
rmsgs:  .dword m_simm, m_uimm, m_shamt, m_imm, m_slot, m_xidx ; message for each range

; =============================================================================
        .text                           ; code
; =============================================================================

; ---- entry ---------------------------------------------------------------------------
_start:                                 ; entry: I-LS 0 (bare metal) or 0x8000 (StrataOS)
        li    sp, STACKTOP              ; stack at the top of the D-LS
        csrr  t0, coreid                ; which core is this?
        beqz  t0, st_main               ; core 0 does the work
        li    a0, 0                     ; every other core
        halt                            ; stops at once
st_main:                                ; core 0 continues here
        mv    s0, a0                    ; s0 = input length (StrataOS)
        mv    s1, a1                    ; s1 = 1 under StrataOS with `> file`
        call  init_tables               ; character classes, hash heads, keywords
        li    t0, 1                     ; StrataOS flag value
        beq   s1, t0, st_os             ; started by StrataOS's `run`
        cvalid t0, c3                   ; bare metal has the device root in c3
        bnez  t0, st_bare               ; so this is bare metal
        li    a0, m_usage               ; StrataOS without an output file
        call  print_z                   ; explain
        li    a0, 0                     ; no output
        halt                            ; exit
st_os:                                  ; StrataOS: arena layout of `run`
        sd    t0, v_mode(zero)          ; mode 1: StrataOS
        li    t0, IN_OS                 ; input offset in the arena
        sd    t0, v_inbase(zero)        ; remember
        sd    s0, v_inlen(zero)         ; input length
        li    t0, OUT_OS                ; output offset in the arena
        sd    t0, v_outbase(zero)       ; remember
        li    t0, OUTMAX_OS             ; output limit
        sd    t0, v_outmax(zero)        ; remember
        li    t0, ORG_OS                ; StrataOS programs live at I-LS 0x8000
        sd    t0, v_org(zero)           ; text origin
        li    t0, INMAX_OS              ; input limit
        bleu  s0, t0, st_go             ; fits
        li    a0, m_inbig               ; too large
        j     fail                      ; report
st_bare:                                ; bare metal: our own layout of system memory
        sd    zero, v_mode(zero)        ; mode 0: bare metal
        li    t0, HEAPEND_BARE          ; the whole D-LS below the stack for records
        sd    t0, v_hend(zero)          ; ...
        sd    zero, v_org(zero)         ; text origin 0
        li    t0, IN_BARE               ; input offset in system memory
        sd    t0, v_inbase(zero)        ; remember
        li    t0, OUT_BARE              ; output offset
        sd    t0, v_outbase(zero)       ; remember
        li    t0, OUTMAX_BARE           ; output limit
        sd    t0, v_outmax(zero)        ; remember
        call  read_console              ; console input -> system memory
st_go:                                  ; both modes: assemble
        call  prescan                   ; labels, functions, regions, groups
        li    s2, 0                     ; s2 = pass 1 iterations done
st_p1:                                  ; loop: one pass 1
        ld    t0, v_gen(zero)           ; a new generation of definitions
        addi  t0, t0, 1                 ; (symbols of an earlier pass 1 read as undefined)
        sd    t0, v_gen(zero)           ; ...
        li    a0, 1                     ; pass 1: symbols and sizes
        call  run_pass                  ; over the whole source
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, st_chk                ; no: one pass 1 is enough
        call  layout_groups             ; place the groups: a0 = 1 if anything moved
        beqz  s2, st_again              ; (the first layout always counts as a change)
        beqz  a0, st_chk                ; settled
st_again:                               ; the layout changed
        li    t0, 20                    ; sasm gives up after 21 passes
        beq   s2, t0, st_unsettled      ; ...
        addi  s2, s2, 1                 ; one more
        j     st_p1                     ; again
st_unsettled:                           ; error: the layout keeps moving
        li    a0, m_settle              ; does not settle
        j     fail_noline               ; report
st_chk:                                 ; the limits of paged code and far data
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, st_chkfar             ; no
        ld    t1, v_far(zero)           ; the stub: 2 instructions for paging,
        li    t2, 9                     ; 9 for the cache,
        mul   t1, t1, t2                ; ...
        addi  t1, t1, 2 + 3             ; 3 for the jump on
        slli  t1, t1, 2                 ; bytes
        ld    t2, v_pend(zero)          ; the end of the pinned code
        add   t1, t1, t2                ; and the stub
        li    t2, 2 * UNIT              ; and two units
        add   t1, t1, t2                ; ...
        li    t2, 0x10000               ; must fit the I-LS
        bgeu  t2, t1, st_chkfar         ; they do
        li    a0, m_room                ; no room for the units
        j     fail_noline               ; report
st_chkfar:                              ; far data: the cache must end below 0xA000
        ld    t0, v_far(zero)           ; far data?
        beqz  t0, st_lay                ; no
        ld    t1, sects+SREC+S_SIZE(zero) ; the end of .data with the cache
        li    t2, 0xA000                ; StrataOS's limit
        bgeu  t2, t1, st_lay            ; below it
        li    a0, m_dfar                ; too much data
        j     fail_noline               ; report
st_lay:                                 ; the image
        call  layout                    ; place the sections in the image
        li    a0, 2                     ; pass 2: encode
        call  run_pass                  ; over the whole source again
        call  finish                    ; last windows and the headers
        ld    t0, v_mode(zero)          ; which mode?
        beqz  t0, st_copy               ; bare metal: print the image
        ld    a0, v_total(zero)         ; StrataOS: exit code = image length
        halt                            ; back to the kernel
st_copy:                                ; bare metal: the image goes to the console
        call  copy_out                  ; image -> console
        li    a0, 0                     ; success
        halt                            ; stop (after the console drains)

; ---- init_tables(): character classes, empty hashes, the keyword table -------------
init_tables:                            ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        li    a0, CCLASS                ; clear the class table
        li    a1, 256                   ; 256 bytes
        call  zero_mem                  ; zero it
        li    a0, KWHASH                ; clear the keyword heads
        li    a1, 512                   ; 256 u16 heads
        call  zero_mem                  ; zero them
        li    a0, SYMHASH               ; clear the symbol heads
        li    a1, 2048                  ; 1024 u16 heads
        call  zero_mem                  ; zero them
        li    a0, 9                     ; \t \n \v \f \r
        li    a1, 13                    ; ...
        li    a2, C_SP                  ; are white space
        call  set_class                 ; mark them
        li    a0, ' '                   ; the blank
        li    a1, ' '                   ; alone
        li    a2, C_SP                  ; is white space
        call  set_class                 ; mark it
        li    a0, 'A'                   ; upper-case letters
        li    a1, 'Z'                   ; ...
        li    a2, C_SS | C_SC           ; start and continue symbols
        call  set_class                 ; mark them
        li    a0, 'a'                   ; lower-case letters
        li    a1, 'z'                   ; ...
        li    a2, C_SS | C_SC           ; start and continue symbols
        call  set_class                 ; mark them
        li    a0, '_'                   ; underscore
        li    a1, '_'                   ; alone
        li    a2, C_SS | C_SC           ; is a symbol character
        call  set_class                 ; mark it
        li    a0, '.'                   ; dot
        li    a1, '.'                   ; alone
        li    a2, C_SS | C_SC           ; is a symbol character
        call  set_class                 ; mark it
        li    a0, '$'                   ; dollar
        li    a1, '$'                   ; alone
        li    a2, C_SS | C_SC           ; is a symbol character
        call  set_class                 ; mark it
        li    a0, '0'                   ; decimal digits
        li    a1, '9'                   ; ...
        li    a2, C_SC | C_DG | C_HX    ; continue symbols, digits, hex digits
        call  set_class                 ; mark them
        li    a0, 'a'                   ; a..f
        li    a1, 'f'                   ; ...
        li    a2, C_HX                  ; are hex digits
        call  set_class                 ; mark them
        li    a0, 'A'                   ; A..F
        li    a1, 'F'                   ; ...
        li    a2, C_HX                  ; are hex digits
        call  set_class                 ; mark them
        li    t0, HEAP                  ; the heap starts empty
        sd    t0, v_heap(zero)          ; heap top
        li    s0, kwtab                 ; s0 = keyword table cursor
it_grp:                                 ; loop: one group of the table
        lbu   a6, 0(s0)                 ; a6 = class
        beqz  a6, it_done               ; 0: end of table
        lbu   a5, 1(s0)                 ; a5 = format (or number)
        lbu   t1, 2(s0)                 ; operand count
        slli  t1, t1, 8                 ; into bits 8..15
        or    a5, a5, t1                ; merge
        lbu   t1, 3(s0)                 ; opcode
        slli  t1, t1, 16                ; into bits 16..23
        or    a5, a5, t1                ; merge
        lbu   t1, 4(s0)                 ; function
        slli  t1, t1, 24                ; into bits 24..31
        or    a5, a5, t1                ; merge: a5 = the first record's value
        lbu   s1, 5(s0)                 ; s1 = step
        addi  s0, s0, 6                 ; s0 = the names
it_name:                                ; loop: one name of the group
        lbu   t0, 0(s0)                 ; next character
        li    t1, ' '                   ; a blank between names?
        bne   t0, t1, it_n1             ; no
        addi  s0, s0, 1                 ; skip it
        j     it_name                   ; continue
it_n1:                                  ; the end of the group?
        bnez  t0, it_one                ; no: a name
        addi  s0, s0, 1                 ; past the NUL
        j     it_grp                    ; next group
it_one:                                 ; a name: its length and hash
        mv    a0, s0                    ; a0 = the name
        li    a1, 0                     ; a1 = length
        li    a2, 0                     ; a2 = hash
it_h:                                   ; loop: one character
        add   t0, s0, a1                ; character
        lbu   t0, 0(t0)                 ; ...
        beqz  t0, it_ins                ; the NUL ends it
        li    t1, ' '                   ; and so does a blank
        beq   t0, t1, it_ins            ; ...
        slli  t1, a2, 5                 ; hash * 32
        add   a2, a2, t1                ; hash * 33
        add   a2, a2, t0                ; + character
        addi  a1, a1, 1                 ; one more
        j     it_h                      ; continue
it_ins:                                 ; add the record
        add   s0, s0, a1                ; past the name
        li    a3, KWHASH                ; keyword heads
        li    a4, KWMASK                ; their mask
        call  insert                    ; (keeps a5, a6)
        li    t1, 1                     ; the next name's value: by the step
        li    t0, KS_FMT                ; the format
        beq   s1, t0, it_step           ; ...
        slli  t1, t1, 16                ; the opcode
        li    t0, KS_OP                 ; ...
        beq   s1, t0, it_step           ; ...
        slli  t1, t1, 8                 ; the function
        li    t0, KS_FN                 ; ...
        beq   s1, t0, it_step           ; ...
        srli  t1, a5, 24                ; the function doubled: add it again
        slli  t1, t1, 24                ; ...
        li    t0, KS_FN2                ; ...
        beq   s1, t0, it_step           ; ...
        li    t1, 0                     ; none
it_step:                                ; step
        add   a5, a5, t1                ; ...
        j     it_name                   ; next name
it_done:                                ; table copied
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 24                ; pop
        ret                             ; done

; zero_mem(a0 = address, a1 = length): both multiples of 8
zero_mem:                               ; routine entry (leaf)
        beqz  a1, zm_ret                ; nothing left
        sd    zero, 0(a0)               ; clear 8 bytes
        addi  a0, a0, 8                 ; advance
        addi  a1, a1, -8                ; count down
        j     zero_mem                  ; continue
zm_ret:                                 ; all cleared
        ret                             ; done

; set_class(a0 = first char, a1 = last char, a2 = class bits)
set_class:                              ; routine entry (leaf)
        bltu  a1, a0, sc_ret            ; range done
        lbu   t0, CCLASS(a0)            ; current bits
        or    t0, t0, a2                ; add the new ones
        sb    t0, CCLASS(a0)            ; store
        addi  a0, a0, 1                 ; next character
        j     set_class                 ; continue
sc_ret:                                 ; range done
        ret                             ; done

; ---- read_console(): bare metal: console input -> system memory --------------------
; Reads one byte at a time from the console input port (device offset 8 of
; the device root c3) until the end-of-input byte 0x04, gathering 1 KiB in
; the D-LS before each `tput` to system memory.
read_console:                           ; routine entry (leaf)
        li    t0, BYTEBUF               ; t0 = one-byte landing slot
        li    t1, CON_IN                ; t1 = console input port
        li    t2, 1                     ; t2 = one byte per read
        li    t3, INBUF                 ; t3 = gathering buffer
        li    t4, 0                     ; t4 = bytes read
        ld    t5, v_inbase(zero)        ; t5 = where the source goes
        li    t6, INMAX_BARE            ; t6 = input limit
rc_loop:                                ; loop: one input byte
        tget  tg1, t0, c3, t1, t2       ; read a byte (waits until one arrives)
        lbu   a0, 0(t0)                 ; the byte (the load waits for the transfer)
        li    a1, 4                     ; end-of-input marker
        beq   a0, a1, rc_end            ; no more input
        bgeu  t4, t6, rc_big            ; would not fit
        andi  a2, t4, INSZ - 1          ; position in the gathering buffer
        add   a3, t3, a2                ; its address
        sb    a0, 0(a3)                 ; keep the byte
        addi  t4, t4, 1                 ; one more
        andi  a2, t4, INSZ - 1          ; buffer full?
        bnez  a2, rc_loop               ; not yet
        add   a4, t5, t4                ; end of the full buffer's place
        addi  a4, a4, -INSZ             ; its start
        li    a5, INSZ                  ; whole buffer
        tput  tg2, t3, c0, a4, a5       ; to system memory (later stores wait for it)
        j     rc_loop                   ; continue
rc_end:                                 ; end of input: write the partial buffer
        andi  a2, t4, INSZ - 1          ; bytes in the partial buffer
        beqz  a2, rc_done               ; none
        sub   a4, t4, a2                ; source offset of the partial buffer
        add   a4, t5, a4                ; its place in system memory
        addi  a5, a2, 7                 ; round its length
        srli  a5, a5, 3                 ; up to
        slli  a5, a5, 3                 ; whole words
        tput  tg2, t3, c0, a4, a5       ; write it
rc_done:                                ; input stored
        sd    t4, v_inlen(zero)         ; source length
        ret                             ; done
rc_big:                                 ; error: input too large
        li    a0, m_inbig               ; input too large
        j     fail                      ; report

; ---- run_pass(a0 = pass number) --------------------------------------------------------
run_pass:                               ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    tp, a0                    ; tp = pass
        li    t0, sects                 ; t0 = first section record
        li    t1, NSECT                 ; t1 = sections left
        li    t2, -1                    ; t2 = "nothing emitted yet"
rp_reset:                               ; loop: reset one section record
        sd    zero, S_LOC(t0)           ; location 0
        sd    t2, S_LO(t0)              ; no lowest address yet
        li    t3, 2                     ; pass 2 keeps the sizes pass 1 measured
        beq   tp, t3, rp_keep           ; ...
        sd    zero, S_SIZE(t0)          ; pass 1 (each of them) measures again
rp_keep:                                ; record reset
        addi  t0, t0, SREC              ; next record
        addi  t1, t1, -1                ; one fewer
        bnez  t1, rp_reset              ; all five
        ld    t0, v_org(zero)           ; text origin
        sd    t0, sects+S_LOC(zero)     ; .text starts there
        sd    zero, v_cs(zero)          ; start in .text
        li    s11, sects                ; s11 = its record
        sd    zero, v_lii(zero)         ; first li
        li    t0, -1                    ; no region yet
        sd    t0, v_regctr(zero)        ; ...
rp_rew:                                 ; back to the start of the source
        call  rewind                    ; ...
rp_loop:                                ; loop: one source line
        call  read_line                 ; next line into LINEBUF
        beqz  a0, rp_done               ; end of the source
        call  do_line                   ; assemble it
        j     rp_loop                   ; continue
rp_done:                                ; end of the source
        ld    t0, v_paged(zero)         ; paged code or far data?
        ld    t1, v_far(zero)           ; ...
        or    t0, t0, t1                ; ...
        beqz  t0, rp_ret                ; neither: nothing more
        sd    zero, v_cs(zero)          ; the start-up stub goes into .text
        li    s11, sects                ; ...
        li    t0, 2                     ; pass 2 puts it where pass 1 did
        beq   tp, t0, rp_stub           ; ...
        ld    t1, v_pend(zero)          ; paged code: after the pinned code
        ld    t0, v_paged(zero)         ; ...
        bnez  t0, rp_st1                ; ...
        ld    t1, S_SIZE(s11)           ; otherwise after the code
        addi  t1, t1, 3                 ; rounded up to a word
        srli  t1, t1, 2                 ; ...
        slli  t1, t1, 2                 ; ...
        bnez  t1, rp_st1                ; (if there is any)
        ld    t1, v_org(zero)           ; or at the text origin
rp_st1:                                 ; pass 1: remember the place
        sd    t1, v_stubat(zero)        ; ...
        ld    t0, sects+SREC+S_SIZE(zero) ; and the end of .data, for the cache
        sd    t0, v_cacheat(zero)       ; ...
rp_stub:                                ; emit the stub
        ld    t1, v_stubat(zero)        ; its place
        sd    t1, S_LOC(s11)            ; ...
        call  emit_stub                 ; __pinit
        ld    t0, v_far(zero)           ; far data?
        beqz  t0, rp_ret                ; no
        li    t0, 1                     ; the cache goes into .data
        sd    t0, v_cs(zero)            ; ...
        li    s11, sects + SREC         ; ...
        ld    t1, v_cacheat(zero)       ; after the program's data
        sd    t1, S_LOC(s11)            ; ...
        call  emit_cache                ; __fc_lines, __fc_tags
        sd    zero, v_cs(zero)          ; back to .text
        li    s11, sects                ; ...
rp_ret:                                 ; pass done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; pass done

; rewind(): read the source again from its first line
rewind:                                 ; routine entry (leaf)
        sd    zero, v_line(zero)        ; no line read yet
        sd    zero, v_pos(zero)         ; at the start of the source
        li    t0, -1                    ; no window contents yet: a huge window
        srli  t0, t0, 1                 ; offset puts every position "before" it
        sd    t0, v_chunk(zero)         ; and forces a fetch
        ret                             ; done

; ---- read_line() -> a0 = 1 if a line was read, 0 at the end -------------------------
; Like fgets plus sasm's cleanup: the line ends at '\n', and its text ends
; at the first '\r' or NUL (the rest of the line is skipped).
read_line:                              ; routine entry (leaf)
        ld    t0, v_pos(zero)           ; t0 = source position
        ld    t1, v_inlen(zero)         ; t1 = source length
        bltu  t0, t1, rl_go             ; something left
        li    a0, 0                     ; end of source
        ret                             ; done
rl_go:                                  ; there is a line to read
        ld    a0, v_line(zero)          ; count the line
        addi  a0, a0, 1                 ; (before any error about it)
        sd    a0, v_line(zero)          ; store
        ld    t2, v_chunk(zero)         ; t2 = source offset of the window
        li    t3, LINEBUF               ; t3 = destination
        li    t4, 0                     ; t4 = characters kept
        li    t5, 0                     ; t5 = 1 once the text has ended
rl_next:                                ; loop: one source character
        bgeu  t0, t1, rl_end            ; source exhausted: last line
        sub   t6, t0, t2                ; t6 = position in the window
        li    a1, INSZ                  ; window size
        bltu  t6, a1, rl_have           ; inside the window
        srli  t2, t0, 10                ; window start = position
        slli  t2, t2, 10                ; rounded down to 1 KiB
        ld    a2, v_inbase(zero)        ; source base in the arena
        add   a2, a2, t2                ; arena offset of the window
        li    a3, INBUF                 ; D-LS window
        tget  tg1, a3, c0, a2, a1       ; fetch 1 KiB (loads below wait for it)
        sub   t6, t0, t2                ; position in the new window
rl_have:                                ; the character is in the window
        lbu   a0, INBUF(t6)             ; a0 = the character
        addi  t0, t0, 1                 ; consumed
        li    a1, '\n'                  ; end of line?
        beq   a0, a1, rl_end            ; yes
        bnez  t5, rl_next               ; text already ended: skip
        li    a1, '\r'                  ; carriage return ends the text
        beq   a0, a1, rl_stop           ; ...
        beqz  a0, rl_stop               ; so does NUL
        li    a1, LINEMAX               ; room left?
        bgeu  t4, a1, rl_long           ; no
        add   a2, t3, t4                ; destination
        sb    a0, 0(a2)                 ; keep the character
        addi  t4, t4, 1                 ; one more
        j     rl_next                   ; continue
rl_stop:                                ; CR or NUL: the text ends here
        li    t5, 1                     ; ignore the rest of the line
        j     rl_next                   ; continue
rl_end:                                 ; end of the line
        add   a2, t3, t4                ; end of the text
        sb    zero, 0(a2)               ; terminate it
        sd    t0, v_pos(zero)           ; remember the position
        sd    t2, v_chunk(zero)         ; and the window
        li    a0, 1                     ; a line was read
        ret                             ; done
rl_long:                                ; error: line too long
        li    a0, m_long                ; line too long
        j     fail                      ; report

; ---- do_line(): assemble the line in LINEBUF ----------------------------------------
; Handlers for each format are jumped to (not called) with the frame of
; do_line still in place; they may use s0..s4 and end with `j dl_ret`.
do_line:                                ; routine entry
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and the registers the handlers use
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        sd    s3, 32(sp)                ; ...
        sd    s4, 40(sp)                ; ...
        li    t0, -1                    ; not (yet) a line of paged code
        sd    t0, v_lreg(zero)          ; ...
        sd    zero, v_lpaged(zero)      ; ...
        li    a0, LINEBUF               ; the raw line
        call  is_include                ; an .include line?
        bnez  a0, dl_ret                ; yes: skipped (supply the file as input)
        li    a0, LINEBUF               ; the line
        call  strip_comment             ; cut ; # // comments
        li    a0, LINEBUF               ; the line
        call  trim                      ; drop surrounding white space
        mv    s0, a0                    ; s0 = cursor
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, dl_label              ; no
        ld    t0, v_cs(zero)            ; a .text line?
        bnez  t0, dl_label              ; no
        call  map_line                  ; to where its group is
dl_label:                               ; loop: one leading label
        lbu   t0, 0(s0)                 ; next character
        lbu   t0, CCLASS(t0)            ; its class
        andi  t0, t0, C_SS              ; can it start a symbol?
        beqz  t0, dl_nolabel            ; no: no label here
        mv    a0, s0                    ; scan the name
        li    a1, -1                    ; of any length
        call  scan_sym                  ; a0 = end, a1 = length, a2 = hash
        lbu   t0, 0(a0)                 ; character after it
        li    t1, ':'                   ; a label?
        bne   t0, t1, dl_nolabel        ; no
        mv    s1, a0                    ; s1 = the colon
        mv    a0, s0                    ; name
        ld    a3, S_LOC(s11)            ; value = current location
        ld    a4, v_cs(zero)            ; in the current section
        call  sym_define                ; define the label
        addi  a0, s1, 1                 ; after the colon
        call  skipws                    ; skip blanks
        mv    s0, a0                    ; continue there
        j     dl_label                  ; several labels may share a line
dl_nolabel:                             ; no (more) labels
        lbu   t0, 0(s0)                 ; anything left?
        beqz  t0, dl_ret                ; no: done
        lbu   t1, CCLASS(t0)            ; its class
        andi  t1, t1, C_SS              ; a name?
        beqz  t1, dl_mnem               ; no: cannot be `name = expr`
        mv    a0, s0                    ; scan it
        li    a1, -1                    ; any length
        call  scan_sym                  ; a0 = end, a1 = length, a2 = hash
        mv    s1, a1                    ; s1 = length
        mv    s2, a2                    ; s2 = hash
        call  skipws                    ; blanks after the name
        lbu   t0, 0(a0)                 ; next character
        li    t1, '='                   ; assignment?
        bne   t0, t1, dl_mnem           ; no
        lbu   t0, 1(a0)                 ; "==" is not one
        beq   t0, t1, dl_mnem           ; (falls to an instruction error)
        addi  a0, a0, 1                 ; the expression
        call  eval                      ; a0 = value, a1 = undefined?
        beqz  a1, dl_set                ; fully known
        li    t0, 1                     ; pass 1?
        bne   tp, t0, dl_set            ; pass 2 already reported it
        li    a0, m_later               ; forward reference in a constant
        mv    a1, s0                    ; name
        mv    a2, s1                    ; its length
        j     fail_n                    ; report
dl_set:                                 ; define the constant
        mv    a3, a0                    ; value
        mv    a0, s0                    ; name
        mv    a1, s1                    ; length
        mv    a2, s2                    ; hash
        li    a4, -1                    ; no section
        call  sym_define                ; define the constant
        j     dl_ret                    ; done
dl_mnem:                                ; a mnemonic or directive
        mv    a0, s0                    ; copy it into MBUF
        call  get_mnem                  ; a0 = the operands, a1 = length, a2 = hash
        sd    a0, v_rest(zero)          ; the operands follow
        li    a0, MBUF                  ; look the mnemonic up
        li    a3, KWHASH                ; among the keywords
        li    a4, KWMASK                ; ...
        call  find                      ; a0 = record or 0
        mv    s1, a0                    ; s1 = record
        lbu   t0, MBUF(zero)            ; first character
        li    t1, '.'                   ; directive?
        beq   t0, t1, dl_dir            ; yes
        ld    a0, v_rest(zero)          ; instructions: split the operands
        call  split_ops                 ; (before the lookup, like sasm)
        li    a0, m_unki                ; message if unknown
        j     dl_check                  ; check the record
dl_dir:                                 ; a directive
        li    a0, m_unkd                ; message if unknown
dl_check:                               ; validate the keyword record
        beqz  s1, dl_unknown            ; no such keyword
        lbu   t0, R_SECT(s1)            ; class
        li    t1, K_OP                  ; must be an instruction or directive
        bne   t0, t1, dl_unknown        ; (not a register or CSR name)
        ld    t0, R_VAL(s1)             ; packed fields
        andi  t1, t0, 255               ; t1 = format
        sd    t1, v_fmt(zero)           ; (h_gen's descriptor)
        srli  t2, t0, 8                 ; operand count
        andi  t2, t2, 255               ; t2 = operand count
        srli  t3, t0, 16                ; opcode
        andi  t3, t3, 255               ; t3 = opcode
        sd    t3, v_op(zero)            ; remember
        srli  t3, t0, 24                ; function
        andi  t3, t3, 255               ; t3 = function
        sd    t3, v_fn(zero)            ; remember
        li    t3, ANY                   ; count checked by the handler?
        beq   t2, t3, dl_go             ; yes
        ld    t3, v_nops(zero)          ; operands given
        bne   t2, t3, dl_count          ; wrong number
dl_go:                                  ; dispatch on the format
        slli  t1, t1, 2                 ; table index
        lwu   t1, jtab(t1)              ; handler address
        jr    t1                        ; run it
dl_count:                               ; error: wrong operand count
        li    a0, m_nops                ; wrong operand count
        li    a1, MBUF                  ; for this mnemonic
        j     fail_s                    ; report
dl_unknown:                             ; error: unknown mnemonic or directive
        li    a1, MBUF                  ; the mnemonic
        j     fail_s                    ; report (message in a0)
dl_ret:                                 ; every handler ends here
        ld    t0, v_lreg(zero)          ; a line of paged code?
        bltz  t0, dl_out                ; no
        ld    t1, v_lgrec(zero)         ; its group goes on
        ld    t2, S_LOC(s11)            ; from here
        sw    t2, RG_LOC(t1)            ; ...
        ld    t2, v_uloc(zero)          ; the section's own location back
        sd    t2, S_LOC(s11)            ; ...
        sd    zero, v_cs(zero)          ; and .text
        li    s11, sects                ; ...
dl_out:                                 ; line done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        ld    s4, 40(sp)                ; ...
        addi  sp, sp, 48                ; pop
        ret                             ; line done

; ---- instruction handlers (jumped to from do_line) ----------------------------------
h_b:                                    ; rs1, rs2, target
        ld    a0, OPS(zero)             ; first register
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = it
        ld    a0, OPS+8(zero)           ; second register
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = it
        ld    a0, OPS+16(zero)          ; target
h_bt:                                   ; common part of the branches: target in a0
        mv    s2, a0                    ; s2 = target
        ld    a0, v_op(zero)            ; to a function in another group of paged code?
        mv    a1, s0                    ; ...
        mv    a2, s1                    ; ...
        mv    a3, s2                    ; ...
        call  pbranch                   ; then it is rewritten
        bnez  a0, dl_ret                ; (it was)
        mv    a0, s2                    ; an ordinary branch
        li    a1, 16                    ; 16-bit word offset
        call  pcrel                     ; a0 = offset
        mv    a3, a0                    ; immediate
        j     h_enc_i01                 ; encode

h_bz:                                   ; rs, target compared with zero
        ld    a0, OPS(zero)             ; the register
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = it
        li    s1, 0                     ; s1 = zero
        ld    t0, v_fn(zero)            ; swapped?
        beqz  t0, h_bz1                 ; no
        mv    s1, s0                    ; swap: zero first
        li    s0, 0                     ; ...
h_bz1:                                  ; registers in place
        ld    a0, OPS+8(zero)           ; target
        j     h_bt                      ; encode as a branch

h_b2:                                   ; rs1, rs2, target with registers swapped
        ld    a0, OPS(zero)             ; first register
        call  xreg                      ; number
        mv    s1, a0                    ; goes second
        ld    a0, OPS+8(zero)           ; second register
        call  xreg                      ; number
        mv    s0, a0                    ; goes first
        ld    a0, OPS+16(zero)          ; target
        j     h_bt                      ; encode as a branch

h_jal:                                  ; rd, target
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        li    t0, 2                     ; jal zero or jal ra?
        bgeu  s0, t0, hjl_go            ; no: always as written
        ld    a1, OPS+8(zero)           ; target
        seqz  a2, s0                    ; jal zero is a jump
        call  ptransfer                 ; paged code: rewritten?
        bnez  a0, dl_ret                ; (it was)
hjl_go:                                 ; as written
        ld    a0, OPS+8(zero)           ; target
        j     h_jt                      ; common part
h_j:                                    ; j / call: rd from the table
        ld    s0, v_fn(zero)            ; rd = 0 or 1
        bnez  s0, hj_x                  ; call
        ld    t0, v_line(zero)          ; the program's first instruction?
        ld    t1, v_first(zero)         ; ...
        bne   t0, t1, hj_x              ; no
        ld    t0, v_paged(zero)         ; with paged code or far data
        ld    t1, v_far(zero)           ; ...
        or    t0, t0, t1                ; ...
        beqz  t0, hj_x                  ; neither: as written
        ld    a0, OPS(zero)             ; the entry: keep its target
        li    a1, ENTBUF                ; (255 characters of it, as sasm)
        li    a2, 255                   ; ...
hj_cp:                                  ; loop: copy one character
        lbu   t0, 0(a0)                 ; character
        beqz  t0, hj_cpe                ; end
        beqz  a2, hj_cpe                ; or no more room
        sb    t0, 0(a1)                 ; keep it
        addi  a0, a0, 1                 ; next
        addi  a1, a1, 1                 ; ...
        addi  a2, a2, -1                ; ...
        j     hj_cp                     ; continue
hj_cpe:                                 ; copied
        sb    zero, 0(a1)               ; terminate
        li    t0, 1                     ; the stub jumps on to it
        sd    t0, v_entry(zero)         ; ...
        li    a0, s_pinit               ; and the entry jumps to the stub
        j     h_jt                      ; (j __pinit)
hj_x:                                   ; any other j or call
        mv    a0, s0                    ; rd
        ld    a1, OPS(zero)             ; target
        seqz  a2, s0                    ; j is a jump
        call  ptransfer                 ; paged code: rewritten?
        bnez  a0, dl_ret                ; (it was)
        ld    a0, OPS(zero)             ; target
h_jt:                                   ; common part of jal/j/call: target in a0
        li    a1, 21                    ; 21-bit word offset
        call  pcrel                     ; a0 = offset
        li    t0, 0x1fffff              ; keep 21 bits
        and   a0, a0, t0                ; ...
        ld    t0, v_op(zero)            ; opcode
        slli  t0, t0, 26                ; into place
        or    a0, a0, t0                ; merge
        slli  t0, s0, 21                ; rd into place
        or    a0, a0, t0                ; merge
        call  emit_insn                 ; emit
        j     dl_ret                    ; done

h_xf:                                   ; tag, ls, cap, offset, length
        ld    a0, OPS(zero)             ; tag
        call  tagreg                    ; number
        mv    s0, a0                    ; s0 = tag
        ld    a0, OPS+8(zero)           ; LS address register
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = it
        ld    a0, OPS+16(zero)          ; capability
        call  creg                      ; number
        mv    s2, a0                    ; s2 = it
        ld    a0, OPS+24(zero)          ; offset register
        call  xreg                      ; number
        mv    s3, a0                    ; s3 = it
        ld    a0, OPS+32(zero)          ; length register
        call  xreg                      ; a0 = it (bits 0..4)
        slli  t0, s3, 5                 ; offset register: bits 5..9
        or    a0, a0, t0                ; merge
        slli  t0, s2, 10                ; capability: bits 10..13
        or    a0, a0, t0                ; merge
        slli  t0, s1, 14                ; LS register: bits 14..18
        or    a0, a0, t0                ; merge
        slli  t0, s0, 19                ; tag: bits 19..22
        or    a0, a0, t0                ; merge
        ld    t0, v_fn(zero)            ; get / put / getx
        slli  t0, t0, 23                ; bits 23..25
        or    a0, a0, t0                ; merge
        ld    t0, v_op(zero)            ; opcode
        slli  t0, t0, 26                ; bits 26..31
        or    a0, a0, t0                ; merge
        call  emit_insn                 ; emit
        j     dl_ret                    ; done

h_twait:                                ; tag list or mask
        li    a0, OPS                   ; all operands
        ld    a1, v_nops(zero)          ; how many
        call  tagmask                   ; a0 = mask
        mv    a3, a0                    ; immediate
        li    s0, 0                     ; rd = 0
        li    s1, 0                     ; rs1 = 0
        j     h_enc_i01                 ; encode

h_tpoll:                                ; rd, tag list or mask
        ld    a1, v_nops(zero)          ; operands
        li    t0, 2                     ; need at least two
        bltu  a1, t0, h_tpbad           ; too few
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        li    a0, OPS+8                 ; the tags
        ld    a1, v_nops(zero)          ; operands
        addi  a1, a1, -1                ; minus rd
        call  tagmask                   ; a0 = mask
        mv    a3, a0                    ; immediate
        li    s1, 0                     ; rs1 = 0
        j     h_enc_i01                 ; encode
h_tpbad:                                ; error: tpoll needs two operands
        li    a0, m_tpoll               ; usage
        j     fail                      ; report

h_ctake:                                ; cd [, rs]
        ld    t0, v_nops(zero)          ; operands
        li    t1, 2                     ; with a sender?
        bne   t0, t1, h_ct1             ; no
        ld    a0, OPS(zero)             ; cd
        call  creg                      ; number
        mv    s0, a0                    ; s0 = cd
        ld    a0, OPS+8(zero)           ; sender register
        call  xreg                      ; number
        mv    a3, a0                    ; rs2 field
        li    s1, 0                     ; no rs1
        ld    a4, v_fn(zero)            ; function
        ori   a4, a4, 16                ; "only from that sender"
        j     h_enc_r01                 ; encode
h_ct1:                                  ; ctake cd
        li    t1, 1                     ; otherwise exactly one operand
        bne   t0, t1, dl_count          ; wrong number
        j     h_gen                     ; (as cclear)
h_ret:                                  ; ret = jalr zero, ra, 0 (paged code: xret ra)
        li    s1, 1                     ; rs1 = ra
h_xr:                                   ; jalr zero, s1, 0 or xret s1
        ld    t0, v_paged(zero)         ; paged code?
        bnez  t0, h_xr1                 ; yes: xret
        li    s0, 0                     ; rd = zero
        li    a3, 0                     ; offset 0
        j     h_enc_i01                 ; encode
h_xr1:                                  ; xret s1: returns through a far link too
        slli  a0, s1, 16                ; rs1
        li    t0, W_XRET                ; xret
        or    a0, a0, t0                ; ...
        call  emit_insn                 ; emit
        j     dl_ret                    ; done

h_jr:                                   ; jr rs = jalr zero, rs, 0 (paged code: xret rs)
        ld    a0, OPS(zero)             ; rs
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs
        j     h_xr                      ; encode

h_jalr:                                 ; jalr rd, rs, imm
        ld    a0, OPS+16(zero)          ; immediate
        call  eval                      ; value
        mv    s2, a0                    ; s2 = immediate
        li    a1, 0                     ; signed 16 bits
        call  check_imm                 ; pass 2 range check
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; rs
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, hjr_as                ; no: as written
        bnez  s0, hjr_lp                ; jalr zero, rs, 0
        beqz  s2, h_xr1                 ; is xret rs, everywhere
hjr_lp:                                 ; in paged code only jalr ra, rs, 0
        ld    t0, v_lpaged(zero)        ; is this paged code?
        beqz  t0, hjr_as                ; no: as written
        li    t0, 1                     ; rd must be ra
        bne   s0, t0, hjr_bad           ; ...
        bnez  s2, hjr_bad               ; no offset
        beq   s1, t0, hjr_bad           ; rs not ra
        li    t0, RT6                   ; nor t6
        beq   s1, t0, hjr_bad           ; ...
        ld    a0, S_LOC(s11)            ; ra = a far link to the instruction after
        addi  a0, a0, 4 * 8             ; (7 for the link, the jalr)
        call  flink                     ; ...
        li    s0, 0                     ; jalr zero, rs, 0
        li    a3, 0                     ; ...
        j     h_enc_i01                 ; encode
hjr_as:                                 ; jalr rd, rs, imm
        mv    a3, s2                    ; immediate
        j     h_enc_i01                 ; encode
hjr_bad:                                ; error: another jalr in paged code
        li    a0, m_jalr                ; only jalr ra, rs, 0
        j     fail                      ; report

h_tfence:                               ; tfence = twait 0xffff
        li    s0, 0                     ; rd
        li    s1, 0                     ; rs1
        li    a3, 0xffff                ; every tag
        j     h_enc_i01                 ; encode

h_li:                                   ; rd, value (fn = 1 for la)
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        ld    a1, OPS+8(zero)           ; expression
        ld    a2, v_fn(zero)            ; la?
        call  do_li                     ; emit 1, 2 or 6 instructions
        j     dl_ret                    ; done

; h_gen: the formats gdesc describes. The word is opcode << 26 | function
; (the immediate of F_SYS, F_RRK) | each operand's field; an operand's spec
; is a kind (GX x register, GC capability register, GCSR a CSR, GM
; offset(base), GE + 16 * range an expression, range as in check_imm) and
; where it goes (QRD, QRS1, QRS2 register fields; QIMM the 16-bit
; immediate; QFN7, QFN5, QFN into the function: << 7, & 63 << 5, as is).
h_gen:                                  ; the described formats
        ld    t0, v_op(zero)            ; opcode
        slli  s0, t0, 26                ; s0 = the word
        ld    t0, v_fn(zero)            ; function (or immediate)
        or    s0, s0, t0                ; ...
        ld    s1, v_fmt(zero)           ; s1 = the descriptor's offset
        slli  s1, s1, 2                 ; (4 specs per format)
        li    s2, 0                     ; s2 = operand index
hg_op:                                  ; loop: one operand
        li    t0, 4                     ; all four done?
        beq   s2, t0, hg_emit           ; ...
        add   t0, s1, s2                ; its spec
        lbu   s3, gdesc(t0)             ; s3 = it
        beqz  s3, hg_emit               ; none: done
        slli  t0, s2, 3                 ; the operand's text
        ld    a0, OPS(t0)               ; ...
        srli  s4, s3, 4                 ; s4 = kind
        li    t0, GX >> 4               ; x register
        beq   s4, t0, hg_x              ; ...
        li    t0, GC >> 4               ; capability register
        beq   s4, t0, hg_c              ; ...
        li    t0, GCSR >> 4             ; CSR
        beq   s4, t0, hg_csr            ; ...
        li    t0, GM >> 4               ; offset(base)
        beq   s4, t0, hg_m              ; ...
        call  eval                      ; an expression
        addi  a1, s4, -(GE >> 4)        ; its range
hg_rng:                                 ; check the value's range (pass 2)
        mv    s4, a0                    ; s4 = value
        call  check_imm                 ; ...
        mv    a0, s4                    ; ...
        j     hg_put                    ; ...
hg_m:                                   ; offset(base)
        call  memop                     ; a0 = offset, a1 = base
        slli  t0, a1, 16                ; the base goes in rs1
        or    s0, s0, t0                ; ...
        li    a1, 0                     ; the offset: signed 16 bits
        j     hg_rng                    ; ...
hg_x:                                   ; x register
        call  xreg                      ; number
        j     hg_put                    ; ...
hg_c:                                   ; capability register
        call  creg                      ; number
        j     hg_put                    ; ...
hg_csr:                                 ; CSR
        call  csrnum                    ; number
hg_put:                                 ; a0 into its field
        andi  t0, s3, 15                ; the field
        li    t1, QIMM                  ; the immediate
        beq   t0, t1, hg_imm            ; ...
        li    t1, QFN7                  ; function, << 7
        beq   t0, t1, hg_f7             ; ...
        li    t1, QFN5                  ; function, & 63 << 5
        beq   t0, t1, hg_f5             ; ...
        li    t1, QFN                   ; function, as is
        beq   t0, t1, hg_or             ; ...
        andi  a0, a0, 31                ; a register: rd << 21, rs1 << 16, rs2 << 11
        li    t1, 5                     ; ...
        mul   t1, t0, t1                ; ...
        li    t2, 21                    ; ...
        sub   t1, t2, t1                ; ...
        sll   a0, a0, t1                ; ...
        j     hg_or                     ; ...
hg_imm:                                 ; the immediate
        li    t1, 0xffff                ; 16 bits
        and   a0, a0, t1                ; ...
        j     hg_or                     ; ...
hg_f7:                                  ; function << 7
        slli  a0, a0, 7                 ; ...
        j     hg_or                     ; ...
hg_f5:                                  ; function & 63 << 5
        andi  a0, a0, 63                ; ...
        slli  a0, a0, 5                 ; ...
hg_or:                                  ; into the word
        or    s0, s0, a0                ; ...
        addi  s2, s2, 1                 ; next operand
        j     hg_op                     ; continue
hg_emit:                                ; all operands placed
        mv    a0, s0                    ; emit
        call  emit_insn                 ; ...
        j     dl_ret                    ; done

h_enc_i01:                              ; emit op | rd = s0 | rs1 = s1 | imm = a3
        ld    a0, v_op(zero)            ; opcode
        mv    a1, s0                    ; rd
        mv    a2, s1                    ; rs1
        call  enc_i                     ; emit
        j     dl_ret                    ; done

h_enc_r01:                              ; emit op | rd = s0 | rs1 = s1 | rs2 = a3 | funct = a4
        ld    a0, v_op(zero)            ; opcode
        mv    a1, s0                    ; rd
        mv    a2, s1                    ; rs1
        call  enc_r                     ; emit
        j     dl_ret                    ; done

; ---- directive handlers (jumped to from do_line) -------------------------------------
d_sect:                                 ; .text .data .far .cluster
        ld    t0, v_fn(zero)            ; section index
        sd    t0, v_cs(zero)            ; current section
        li    t1, SREC                  ; record size
        mul   t1, t0, t1                ; offset of its record
        li    s11, sects                ; records
        add   s11, s11, t1              ; s11 = its record
d_nop:                                  ; .global .globl: nothing to do
        j     dl_ret                    ; done

d_ascii:                                ; .ascii .asciz .string
        ld    a0, v_rest(zero)          ; the operand text
        ld    a1, v_fn(zero)            ; add a NUL?
        call  emit_string               ; emit
        j     dl_ret                    ; done

d_data:                                 ; .byte .half .word .dword
        ld    a0, v_rest(zero)          ; operand text
        call  split_ops                 ; a0 = count
        mv    s0, a0                    ; s0 = values left
        li    s1, OPS                   ; s1 = next operand pointer
dd_loop:                                ; loop: one value
        beqz  s0, dl_ret                ; all done
        ld    a0, 0(s1)                 ; the operand
        call  eval                      ; value
        ld    a1, v_fn(zero)            ; width
        call  emit_le                   ; emit little endian
        addi  s1, s1, 8                 ; next operand
        addi  s0, s0, -1                ; one fewer
        j     dd_loop                   ; continue

d_space:                                ; .space size [, fill]
        ld    a0, v_rest(zero)          ; operand text
        call  split_ops                 ; a0 = count
        mv    s0, a0                    ; s0 = count
        li    s1, 0                     ; s1 = size
        li    s2, 0                     ; s2 = undefined?
        li    s3, 0                     ; s3 = fill byte
        beqz  s0, ds_chk                ; no operands: size 0
        ld    a0, OPS(zero)             ; size expression
        call  eval                      ; value
        mv    s1, a0                    ; size
        mv    s2, a1                    ; undefined flag
        li    t0, 2                     ; a fill value too?
        bltu  s0, t0, ds_chk            ; no
        ld    a0, OPS+8(zero)           ; fill expression
        call  eval                      ; value
        mv    s3, a0                    ; fill
ds_chk:                                 ; validate the size
        bnez  s2, ds_bad                ; size not known
        bltz  s1, ds_bad                ; negative
ds_loop:                                ; loop: one fill byte
        beqz  s1, dl_ret                ; done
        mv    a0, s3                    ; fill byte
        call  emit_byte                 ; emit
        addi  s1, s1, -1                ; one fewer
        j     ds_loop                   ; continue
ds_bad:                                 ; error: bad size
        li    a0, m_space               ; bad size
        j     fail                      ; report

d_align:                                ; .align power-of-two
        ld    a0, v_rest(zero)          ; operand text
        call  eval                      ; value
        bnez  a1, da_bad                ; not known
        blez  a0, da_bad                ; not positive
        addi  s0, a0, -1                ; s0 = mask
        and   t0, a0, s0                ; power of two?
        bnez  t0, da_bad                ; no
da_loop:                                ; loop: one padding byte
        ld    t0, S_LOC(s11)            ; location
        and   t0, t0, s0                ; misaligned bits
        beqz  t0, dl_ret                ; aligned
        li    a0, 0                     ; pad with zero
        call  emit_byte                 ; emit
        j     da_loop                   ; continue
da_bad:                                 ; error: bad alignment
        li    a0, m_align               ; bad alignment
        j     fail                      ; report

d_org:                                  ; .org address
        ld    t0, v_lreg(zero)          ; in paged code?
        bgez  t0, do_paged              ; an error
        ld    a0, v_rest(zero)          ; operand text
        call  eval                      ; value
        mv    s0, a0                    ; s0 = target
        bnez  a1, do_bad                ; not known
        ld    t0, S_LOC(s11)            ; location
        blt   s0, t0, do_bad            ; backwards
do_loop:                                ; loop: one padding byte
        ld    t0, S_LOC(s11)            ; location
        bge   t0, s0, dl_ret            ; reached
        li    a0, 0                     ; pad with zero
        call  emit_byte                 ; emit
        j     do_loop                   ; continue
do_bad:                                 ; error: backwards
        li    a0, m_org                 ; cannot go back
        j     fail                      ; report
do_paged:                               ; error: .org in paged code
        li    a0, m_orgp                ; (sasm refuses it in .text)
        j     fail                      ; report

d_equ:                                  ; .equ name, value
        ld    a0, v_rest(zero)          ; operand text
        call  split_ops                 ; a0 = count
        li    t0, 2                     ; exactly two
        bne   a0, t0, de_bad            ; otherwise an error
        ld    a0, OPS+8(zero)           ; value expression
        call  eval                      ; value
        mv    s0, a0                    ; s0 = value
        beqz  a1, de_set                ; known
        li    t0, 1                     ; pass 1?
        bne   tp, t0, de_set            ; pass 2 already reported it
        li    a0, m_later               ; forward reference
        ld    a1, OPS(zero)             ; name
        j     fail_s                    ; report
de_set:                                 ; define the constant
        ld    a0, OPS(zero)             ; name (any text, as in sasm)
        call  strhash                   ; a1 = length, a2 = hash
        mv    a3, s0                    ; value
        li    a4, -1                    ; no section
        call  sym_define                ; define it
        j     dl_ret                    ; done
de_bad:                                 ; error: wrong operand count
        li    a0, m_equ                 ; usage
        j     fail                      ; report

; ---- text helpers ----------------------------------------------------------------------
; is_include(a0 = raw line) -> a0 = 1 if it is an `.include` line (sasm reads the file there)
is_include:                             ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  skipws                    ; first non-blank
        li    t0, s_include             ; ".include"
        li    t1, 8                     ; 8 characters
ii_cmp:                                 ; loop: compare with ".include"
        lbu   t2, 0(a0)                 ; line character
        lbu   t3, 0(t0)                 ; expected character
        bne   t2, t3, ii_no             ; differs: not an include
        addi  a0, a0, 1                 ; next
        addi  t0, t0, 1                 ; next
        addi  t1, t1, -1                ; one fewer
        bnez  t1, ii_cmp                ; all 8
        lbu   t2, 0(a0)                 ; the character after ".include"
        lbu   t2, CCLASS(t2)            ; its class
        andi  a0, t2, C_SP              ; white space: an include
        j     ii_ret                    ; (a0 = C_SP or 0)
ii_no:                                  ; not an include
        li    a0, 0                     ; ...
ii_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; get_mnem(a0 = text) -> a0 = the text after the mnemonic, a1 = its length, a2 = hash
; Copies the mnemonic (up to a blank or a tab) lower-cased into MBUF; sasm
; keeps 63 characters of it.
get_mnem:                               ; routine entry (leaf)
        li    t0, MBUF                  ; t0 = lower-cased copy
        li    a1, 0                     ; a1 = characters kept
        li    a2, 0                     ; a2 = hash
gm_loop:                                ; loop: copy one mnemonic character
        lbu   t4, 0(a0)                 ; next character
        beqz  t4, gm_end                ; end of line
        li    t5, ' '                   ; blank ends the mnemonic
        beq   t4, t5, gm_end            ; ...
        li    t5, 9                     ; and so does a tab
        beq   t4, t5, gm_end            ; ...
        addi  a0, a0, 1                 ; consumed
        li    t5, 63                    ; sasm keeps 63 characters
        bgeu  a1, t5, gm_loop           ; drop the rest
        addi  t5, t4, -'A'              ; upper case?
        sltiu t5, t5, 26                ; t5 = 1 if A..Z
        slli  t5, t5, 5                 ; 32 if so
        add   t4, t4, t5                ; lower-case it
        add   t5, t0, a1                ; destination
        sb    t4, 0(t5)                 ; keep it
        addi  a1, a1, 1                 ; one more
        slli  t5, a2, 5                 ; hash * 32
        add   a2, a2, t5                ; hash * 33
        add   a2, a2, t4                ; + character
        j     gm_loop                   ; continue
gm_end:                                 ; mnemonic copied
        add   t5, t0, a1                ; end of the copy
        sb    zero, 0(t5)               ; terminate it
        ret                             ; done

; skipws(a0) -> a0 = first non-blank character at or after a0
skipws:                                 ; routine entry (leaf)
        lbu   t0, 0(a0)                 ; character
        lbu   t0, CCLASS(t0)            ; class
        andi  t0, t0, C_SP              ; blank?
        beqz  t0, sw_ret                ; no
        addi  a0, a0, 1                 ; skip it
        j     skipws                    ; continue
sw_ret:                                 ; found
        ret                             ; done

; trim(a0) -> a0: skip leading blanks, cut trailing ones (uses t0..t2 only)
trim:                                   ; routine entry (leaf)
        lbu   t0, 0(a0)                 ; character
        lbu   t0, CCLASS(t0)            ; class
        andi  t0, t0, C_SP              ; blank?
        beqz  t0, tr_end                ; no: start found
        addi  a0, a0, 1                 ; skip it
        j     trim                      ; continue
tr_end:                                 ; start found
        mv    t2, a0                    ; t2 = scan for the end
tr_find:                                ; loop: find the end
        lbu   t0, 0(t2)                 ; character
        beqz  t0, tr_back               ; end of string
        addi  t2, t2, 1                 ; next
        j     tr_find                   ; continue
tr_back:                                ; loop: drop trailing blanks
        beq   t2, a0, tr_cut            ; empty string
        lbu   t0, -1(t2)                ; last character
        lbu   t1, CCLASS(t0)            ; class
        andi  t1, t1, C_SP              ; blank?
        beqz  t1, tr_cut                ; no
        addi  t2, t2, -1                ; drop it
        j     tr_back                   ; continue
tr_cut:                                 ; terminate
        sb    zero, 0(t2)               ; new end
        ret                             ; done

; strip_comment(a0): cut the line at ; # or // outside quotes
strip_comment:                          ; routine entry (leaf)
        li    t1, 0                     ; t1 = open quote character, 0 if none
scm_loop:                               ; loop: one character
        lbu   t0, 0(a0)                 ; character
        beqz  t0, scm_ret               ; end of line
        beqz  t1, scm_out               ; outside quotes
        li    t2, '\\'                  ; escape?
        bne   t0, t2, scm_q1            ; no
        lbu   t2, 1(a0)                 ; escaped character
        beqz  t2, scm_q1                ; a trailing backslash is just a character
        addi  a0, a0, 2                 ; skip both
        j     scm_loop                  ; continue
scm_q1:                                 ; inside quotes, not an escape
        bne   t0, t1, scm_next          ; not the closing quote
        li    t1, 0                     ; quote closed
        j     scm_next                  ; continue
scm_out:                                ; outside quotes
        li    t2, '"'                   ; opening a string?
        beq   t0, t2, scm_open          ; yes
        li    t2, '\''                  ; opening a character?
        beq   t0, t2, scm_open          ; yes
        li    t2, ';'                   ; comment?
        beq   t0, t2, scm_cut           ; yes
        li    t2, '#'                   ; comment?
        beq   t0, t2, scm_cut           ; yes
        li    t2, '/'                   ; maybe //
        bne   t0, t2, scm_next          ; no
        lbu   t3, 1(a0)                 ; next character
        beq   t3, t2, scm_cut           ; // comment
        j     scm_next                  ; just a slash
scm_open:                               ; a quote opens
        mv    t1, t0                    ; inside this quote
scm_next:                               ; advance
        addi  a0, a0, 1                 ; next character
        j     scm_loop                  ; continue
scm_cut:                                ; a comment starts here
        sb    zero, 0(a0)               ; cut here
scm_ret:                                ; done
        ret                             ; done

; split_ops(a0 = text) -> a0 = count; operand pointers at OPS, also v_nops
; Splits on commas outside parentheses and quotes, trimming each operand.
; An unterminated quote drops the last operand, exactly as sasm does.
split_ops:                              ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  trim                      ; trim the whole text
        li    a2, 0                     ; a2 = count
        lbu   t0, 0(a0)                 ; empty?
        beqz  t0, so_ret                ; no operands
        mv    a3, a0                    ; a3 = operand start
        mv    a4, a0                    ; a4 = cursor
        li    a5, 0                     ; a5 = parenthesis depth
        li    a6, 0                     ; a6 = open quote, 0 if none
so_loop:                                ; loop: one character
        lbu   a7, 0(a4)                 ; character
        beqz  a6, so_noq                ; outside quotes
        li    t0, '\\'                  ; escape?
        bne   a7, t0, so_q2             ; no
        lbu   t1, 1(a4)                 ; escaped character
        beqz  t1, so_q2                 ; none
        addi  a4, a4, 2                 ; skip both
        j     so_loop                   ; continue
so_q2:                                  ; inside quotes, not an escape
        bne   a7, a6, so_q3             ; not the closing quote
        li    a6, 0                     ; closed
so_q3:                                  ; still inside quotes?
        beqz  a7, so_ret                ; end inside a quote: stop (operand dropped)
        addi  a4, a4, 1                 ; next
        j     so_loop                   ; continue
so_noq:                                 ; outside quotes
        li    t0, '"'                   ; string?
        beq   a7, t0, so_open           ; yes
        li    t0, '\''                  ; character?
        beq   a7, t0, so_open           ; yes
        li    t0, '('                   ; deeper?
        bne   a7, t0, so_np1            ; no
        addi  a5, a5, 1                 ; one level in
so_np1:                                 ; not an opening parenthesis
        li    t0, ')'                   ; shallower?
        bne   a7, t0, so_np2            ; no
        addi  a5, a5, -1                ; one level out
so_np2:                                 ; not a closing parenthesis
        beqz  a7, so_split              ; end of text ends an operand
        li    t0, ','                   ; comma?
        bne   a7, t0, so_next           ; no
        bnez  a5, so_next               ; inside parentheses
so_split:                               ; end of an operand
        sb    zero, 0(a4)               ; terminate the operand
        li    t0, MAXOPS                ; room for it?
        bgeu  a2, t0, so_many           ; no
        mv    a0, a3                    ; the operand
        call  trim                      ; trimmed (keeps a2..a7)
        slli  t0, a2, 3                 ; slot offset
        sd    a0, OPS(t0)               ; store the pointer
        addi  a2, a2, 1                 ; one more
        beqz  a7, so_ret                ; that was the end
        addi  a4, a4, 1                 ; past the comma
        mv    a3, a4                    ; next operand starts here
        j     so_loop                   ; continue
so_open:                                ; a quote opens
        mv    a6, a7                    ; inside this quote
so_next:                                ; advance
        addi  a4, a4, 1                 ; next character
        j     so_loop                   ; continue
so_ret:                                 ; all operands found
        sd    a2, v_nops(zero)          ; remember the count
        mv    a0, a2                    ; return it
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
so_many:                                ; error: more than 8 operands
        li    a0, m_many                ; too many operands
        j     fail                      ; report

; scan_sym(a0 = start, a1 = max length) -> a0 = end, a1 = length, a2 = hash
scan_sym:                               ; routine entry (leaf)
        mv    t0, a0                    ; t0 = start
        li    a2, 0                     ; hash
ss_loop:                                ; loop: one symbol character
        sub   t1, a0, t0                ; length so far
        bgeu  t1, a1, ss_end            ; at the limit
        lbu   t2, 0(a0)                 ; character
        lbu   t3, CCLASS(t2)            ; class
        andi  t3, t3, C_SC              ; symbol character?
        beqz  t3, ss_end                ; no
        slli  t3, a2, 5                 ; hash * 32
        add   a2, a2, t3                ; hash * 33
        add   a2, a2, t2                ; + character
        addi  a0, a0, 1                 ; next
        j     ss_loop                   ; continue
ss_end:                                 ; end of the name
        sub   a1, a0, t0                ; length
        ret                             ; done

; strhash(a0 = NUL-terminated string) -> a0 unchanged, a1 = length, a2 = hash
strhash:                                ; routine entry (leaf)
        mv    t0, a0                    ; cursor
        li    a2, 0                     ; hash
sh_loop:                                ; loop: one character
        lbu   t1, 0(t0)                 ; character
        beqz  t1, sh_end                ; end
        slli  t2, a2, 5                 ; hash * 32
        add   a2, a2, t2                ; hash * 33
        add   a2, a2, t1                ; + character
        addi  t0, t0, 1                 ; next
        j     sh_loop                   ; continue
sh_end:                                 ; end of the string
        sub   a1, t0, a0                ; length
        ret                             ; done

; strlen(a0) -> a1 = length (a0 unchanged)
strlen:                                 ; routine entry (leaf)
        mv    t0, a0                    ; cursor
sl_loop:                                ; loop: one character
        lbu   t1, 0(t0)                 ; character
        beqz  t1, sl_end                ; end
        addi  t0, t0, 1                 ; next
        j     sl_loop                   ; continue
sl_end:                                 ; end of the string
        sub   a1, t0, a0                ; length
        ret                             ; done

; ---- symbol and keyword records --------------------------------------------------------
; find(a0 = name, a1 = length, a2 = hash, a3 = heads, a4 = mask) -> a0 = record or 0
find:                                   ; routine entry (leaf)
        and   t0, a2, a4                ; bucket
        slli  t0, t0, 1                 ; u16 heads
        add   t0, a3, t0                ; head address
        lhu   t1, 0(t0)                 ; first record
fd_rec:                                 ; loop: one record of the chain
        beqz  t1, fd_none               ; end of chain
        lbu   t2, R_LEN(t1)             ; its length
        bne   t2, a1, fd_next           ; differs
        li    t3, 0                     ; compare the names
fd_cmp:                                 ; loop: compare one character
        beq   t3, a1, fd_hit            ; all equal
        add   t4, t1, t3                ; record character
        lbu   t4, R_NAME(t4)            ; ...
        add   t5, a0, t3                ; wanted character
        lbu   t5, 0(t5)                 ; ...
        bne   t4, t5, fd_next           ; differs
        addi  t3, t3, 1                 ; next
        j     fd_cmp                    ; continue
fd_next:                                ; not this record
        lhu   t1, R_NEXT(t1)            ; next record
        j     fd_rec                    ; continue
fd_hit:                                 ; names equal
        mv    a0, t1                    ; found
        ret                             ; done
fd_none:                                ; end of the chain
        li    a0, 0                     ; not found
        ret                             ; done

; insert(a0 = name, a1 = length, a2 = hash, a3 = heads, a4 = mask,
;        a5 = value, a6 = section/class) -> a0 = new record
insert:                                 ; routine entry (leaf)
        ld    t0, v_heap(zero)          ; t0 = new record
        addi  t1, a1, R_NAME + 7        ; size with the name
        srli  t1, t1, 3                 ; rounded up
        slli  t1, t1, 3                 ; to 8 bytes
        add   t2, t0, t1                ; new heap top
        ld    t3, v_hend(zero)          ; heap limit
        bltu  t3, t2, in_full           ; no room
        sd    t2, v_heap(zero)          ; claim it
        sd    a5, R_VAL(t0)             ; value
        sb    a1, R_LEN(t0)             ; name length
        sb    a6, R_SECT(t0)            ; section or class
        li    t3, -1                    ; no region
        sh    t3, R_REG(t0)             ; ...
        sb    zero, R_FL(t0)            ; no flags
        sb    zero, R_GEN(t0)           ; not defined by any pass 1 yet
        li    t3, 0                     ; copy the name
in_copy:                                ; loop: copy one name character
        beq   t3, a1, in_link           ; done
        add   t4, a0, t3                ; source character
        lbu   t4, 0(t4)                 ; ...
        add   t5, t0, t3                ; destination
        sb    t4, R_NAME(t5)            ; ...
        addi  t3, t3, 1                 ; next
        j     in_copy                   ; continue
in_link:                                ; link it into its chain
        and   t3, a2, a4                ; bucket
        slli  t3, t3, 1                 ; u16 heads
        add   t3, a3, t3                ; head address
        lhu   t4, 0(t3)                 ; old first record
        sh    t4, R_NEXT(t0)            ; follows the new one
        sh    t0, 0(t3)                 ; new first record
        mv    a0, t0                    ; return it
        ret                             ; done
in_full:                                ; error: heap exhausted
        li    a0, m_full                ; heap exhausted
        j     fail                      ; report

; sym_define(a0 = name, a1 = length, a2 = hash, a3 = value, a4 = section or -1)
; Pass 1 only: pass 2 finds the same values again. A record that exists but
; was not defined in this pass 1 (a .text label the pre-scan entered, or a
; symbol of an earlier pass 1) is defined again.
sym_define:                             ; routine entry
        li    t0, 2                     ; pass 2?
        beq   tp, t0, sd_ret            ; nothing to do
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; and the arguments
        sd    a1, 16(sp)                ; ...
        sd    a2, 24(sp)                ; ...
        sd    a3, 32(sp)                ; ...
        sd    a4, 40(sp)                ; ...
        li    a3, SYMHASH               ; symbol heads
        li    a4, SYMMASK               ; mask
        call  find                      ; already there?
        beqz  a0, sd_new                ; no
        lbu   t0, R_GEN(a0)             ; defined in this pass 1?
        ld    t1, v_gen(zero)           ; ...
        beq   t0, t1, sd_redef          ; yes: redefinition
        ld    t0, 32(sp)                ; (re)define it: value
        sd    t0, R_VAL(a0)             ; ...
        ld    t0, 40(sp)                ; section
        sb    t0, R_SECT(a0)            ; ...
        sb    t1, R_GEN(a0)             ; in this pass 1
        j     sd_done                   ; done
sd_new:                                 ; a new symbol
        ld    a1, 16(sp)                ; length
        li    t0, 255                   ; record length field limit
        bltu  t0, a1, sd_long           ; too long
        ld    a0, 8(sp)                 ; name
        ld    a2, 24(sp)                ; hash
        li    a3, SYMHASH               ; symbol heads
        li    a4, SYMMASK               ; mask
        ld    a5, 32(sp)                ; value
        ld    a6, 40(sp)                ; section
        call  insert                    ; add it
        ld    t1, v_gen(zero)           ; defined in this pass 1
        sb    t1, R_GEN(a0)             ; ...
sd_done:                                ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 48                ; pop
sd_ret:                                 ; done
        ret                             ; done
sd_redef:                               ; error: defined twice
        li    a0, m_redef               ; redefined
        ld    a1, 8(sp)                 ; name
        ld    a2, 16(sp)                ; length
        j     fail_n                    ; report
sd_long:                                ; error: name too long
        li    a0, m_nlong               ; too long
        j     fail                      ; report

; ---- expressions ---------------------------------------------------------------------------
; eval(a0 = text) -> a0 = value, a1 = 1 if an undefined symbol was used
; Grammar and precedence as in sasm, lowest first: | ^ & (<< >>) (+ -)
; (* / %) unary (- + ~), then ( ), 'c', numbers, symbols and `.`.
eval:                                   ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    s10, a0                   ; s10 = cursor
        sd    zero, v_undef(zero)       ; nothing undefined yet
        li    t0, -1                    ; no section yet
        sd    t0, v_esect(zero)         ; ...
        call  e_or                      ; parse
        mv    a2, a0                    ; keep the value
        call  ws10                      ; trailing blanks
        lbu   t0, 0(s10)                ; anything left?
        bnez  t0, ev_junk               ; yes: error
        mv    a0, a2                    ; value
        ld    a1, v_undef(zero)         ; undefined flag
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
ev_junk:                                ; error: text after the expression
        li    a0, m_junk                ; junk after the expression
        mv    a1, s10                   ; the junk
        j     fail_s                    ; report

; ws10(): skip blanks at the cursor (uses t0 only)
ws10:                                   ; routine entry (leaf)
        lbu   t0, 0(s10)                ; character
        lbu   t0, CCLASS(t0)            ; class
        andi  t0, t0, C_SP              ; blank?
        beqz  t0, w10_ret               ; no
        addi  s10, s10, 1               ; skip it
        j     ws10                      ; continue
w10_ret:                                ; found
        ret                             ; done

e_or:                                   ; the lowest precedence: a | b | ...
        li    a0, 0                     ; level 0
; e_bin(a0 = level) -> a0 = value: operands of the next level (e_unary
; after level 5) joined by this level's operators, left to right:
; 0 |, 1 ^, 2 &, 3 << >> (arithmetic, amount & 63), 4 + -, 5 * / % (signed, as C)
e_bin:                                  ; routine entry
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        mv    s1, a0                    ; s1 = level
        call  ez_opnd                   ; left operand
        mv    s0, a0                    ; s0 = value
ez_loop:                                ; loop: another operator of this level?
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; the character
        li    t2, 0                     ; t2 = index in ez_ops
ez_find:                                ; loop: look it up
        lbu   t1, ez_ops(t2)            ; an operator
        beqz  t1, ez_ret                ; none: done
        bne   t1, t0, ez_fn             ; not this one
        lbu   t3, ez_lvl(t2)            ; of this level?
        beq   t3, s1, ez_hit            ; yes
ez_fn:                                  ; next operator
        addi  t2, t2, 1                 ; ...
        j     ez_find                   ; continue
ez_hit:                                 ; found
        li    t3, 3                     ; a shift is a doubled character
        bne   s1, t3, ez_one            ; ...
        lbu   t3, 1(s10)                ; << or >>?
        bne   t3, t0, ez_ret            ; no: done
        addi  s10, s10, 1               ; consume one more
ez_one:                                 ; consume it
        addi  s10, s10, 1               ; ...
        sd    t2, 24(sp)                ; keep the operator
        mv    a0, s1                    ; right operand
        call  ez_opnd                   ; ...
        ld    t2, 24(sp)                ; the operator
        slli  t2, t2, 2                 ; its code
        lwu   t1, ez_jt(t2)             ; ...
        jr    t1                        ; ...
ez_or:                                  ; |
        or    s0, s0, a0                ; ...
        j     ez_loop                   ; continue
ez_xor:                                 ; ^
        xor   s0, s0, a0                ; ...
        j     ez_loop                   ; continue
ez_and:                                 ; &
        and   s0, s0, a0                ; ...
        j     ez_loop                   ; continue
ez_shl:                                 ; <<
        andi  a0, a0, 63                ; modulo 64
        sll   s0, s0, a0                ; ...
        j     ez_loop                   ; continue
ez_shr:                                 ; >>
        andi  a0, a0, 63                ; modulo 64
        sra   s0, s0, a0                ; arithmetic
        j     ez_loop                   ; continue
ez_add:                                 ; +
        add   s0, s0, a0                ; ...
        j     ez_loop                   ; continue
ez_sub:                                 ; -
        sub   s0, s0, a0                ; ...
        j     ez_loop                   ; continue
ez_mul:                                 ; *
        mul   s0, s0, a0                ; ...
        j     ez_loop                   ; continue
ez_div:                                 ; /
        beqz  a0, ez_zero               ; by zero
        div   s0, s0, a0                ; quotient
        j     ez_loop                   ; continue
ez_rem:                                 ; %
        beqz  a0, ez_zero               ; by zero
        rem   s0, s0, a0                ; remainder
        j     ez_loop                   ; continue
ez_zero:                                ; division by zero
        ld    t0, v_undef(zero)         ; an undefined symbol reads as 0:
        li    s0, 0                     ; the result is 0
        bnez  t0, ez_loop               ; and that is not an error
        li    a0, m_div0                ; a real division by zero
        j     fail                      ; report
ez_ret:                                 ; no more operators of this level
        mv    a0, s0                    ; result
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 32                ; pop
        ret                             ; done
ez_opnd:                                ; an operand of level a0 (keeps ra: a tail call)
        addi  a0, a0, 1                 ; the next level
        li    t0, 6                     ; past the last one:
        bltu  a0, t0, e_bin             ; ...
        j     e_unary                   ; a unary expression

e_unary:                                ; -a, +a, ~a, or a primary
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; first character
        li    t1, '-'                   ; negate?
        beq   t0, t1, eu_neg            ; yes
        li    t1, '+'                   ; plus?
        beq   t0, t1, eu_pos            ; yes
        li    t1, '~'                   ; complement?
        beq   t0, t1, eu_not            ; yes
        call  e_primary                 ; a primary
        j     eu_ret                    ; done
eu_neg:                                 ; -
        addi  s10, s10, 1               ; consume it
        call  e_unary                   ; operand
        neg   a0, a0                    ; negate
        j     eu_ret                    ; done
eu_pos:                                 ; +
        addi  s10, s10, 1               ; consume it
        call  e_unary                   ; operand
        j     eu_ret                    ; unchanged
eu_not:                                 ; ~
        addi  s10, s10, 1               ; consume it
        call  e_unary                   ; operand
        li    t0, -1                    ; all ones
        xor   a0, a0, t0                ; complement
eu_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

e_primary:                              ; ( expr ), 'c', number, symbol, .
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; first character
        li    t1, '('                   ; parenthesis?
        beq   t0, t1, ep_paren          ; yes
        li    t1, '\''                  ; character literal?
        beq   t0, t1, ep_char           ; yes
        lbu   t1, CCLASS(t0)            ; class
        andi  t2, t1, C_DG              ; digit?
        bnez  t2, ep_num                ; a number
        andi  t2, t1, C_SS              ; symbol start?
        bnez  t2, ep_sym                ; a symbol
        li    a0, m_bad                 ; nothing else can start an expression
        mv    a1, s10                   ; the text
        j     fail_s                    ; report
ep_paren:                               ; ( expression )
        addi  s10, s10, 1               ; consume (
        call  e_or                      ; inner expression
        mv    s0, a0                    ; keep it
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; closing?
        li    t1, ')'                   ; ...
        bne   t0, t1, ep_noparen        ; missing
        addi  s10, s10, 1               ; consume )
        mv    a0, s0                    ; value
        j     ep_ret                    ; done
ep_noparen:                             ; error: missing )
        li    a0, m_paren               ; expected )
        j     fail                      ; report
ep_char:                                ; character literal
        lbu   a0, 1(s10)                ; the character
        addi  s10, s10, 2               ; consume ' and it
        beqz  a0, ep_badc               ; nothing there
        li    t1, '\\'                  ; escape?
        bne   a0, t1, ep_cq             ; no
        lb    a0, 0(s10)                ; escaped character (a signed char, as in C)
        addi  s10, s10, 1               ; consume it
        beqz  a0, ep_badc               ; nothing there
        li    t1, 'n'                   ; \n
        bne   a0, t1, ep_c1             ; no
        li    a0, 10                    ; newline
ep_c1:                                  ; not \n
        li    t1, 't'                   ; \t
        bne   a0, t1, ep_c2             ; no
        li    a0, 9                     ; tab
ep_c2:                                  ; not \t
        li    t1, '0'                   ; \0
        bne   a0, t1, ep_c3             ; no
        li    a0, 0                     ; NUL
ep_c3:                                  ; not \0
        li    t1, 'r'                   ; \r
        bne   a0, t1, ep_cq             ; no
        li    a0, 13                    ; carriage return
ep_cq:                                  ; the closing quote must follow
        lbu   t0, 0(s10)                ; closing quote?
        li    t1, '\''                  ; ...
        bne   t0, t1, ep_badc           ; missing
        addi  s10, s10, 1               ; consume it
        j     ep_ret                    ; value in a0
ep_badc:                                ; error: bad character literal
        li    a0, m_chr                 ; bad character literal
        j     fail                      ; report
ep_num:                                 ; a number: decimal, 0x hex, 0b binary or 0 octal
        li    a0, 0                     ; a0 = value
        lbu   t1, 1(s10)                ; second character
        ori   t2, t1, 0x20              ; lower-cased
        li    t3, '0'                   ; a leading 0?
        bne   t0, t3, ep_dec            ; no: decimal
        li    t3, 'b'                   ; 0b?
        beq   t2, t3, ep_bin            ; binary
        li    t3, 'x'                   ; 0x?
        bne   t2, t3, ep_oct            ; no: octal
        lbu   t4, 2(s10)                ; a hex digit must follow
        lbu   t4, CCLASS(t4)            ; class
        andi  t4, t4, C_HX              ; hex digit?
        beqz  t4, ep_oct                ; no: just "0" (then junk)
        addi  s10, s10, 2               ; consume 0x
ep_hex:                                 ; loop: one hex digit
        lbu   t0, 0(s10)                ; digit?
        lbu   t1, CCLASS(t0)            ; class
        andi  t1, t1, C_HX              ; hex digit?
        beqz  t1, ep_ret                ; no: done
        li    t1, '9'                   ; letter or digit?
        bgeu  t1, t0, ep_hdig           ; digit
        ori   t0, t0, 0x20              ; lower-case letter
        addi  t0, t0, 10 - 'a'          ; a..f = 10..15
        j     ep_hadd                   ; add it
ep_hdig:                                ; 0..9
        addi  t0, t0, -'0'              ; 0..9
ep_hadd:                                ; accumulate
        slli  a0, a0, 4                 ; shift in
        add   a0, a0, t0                ; the digit
        addi  s10, s10, 1               ; next
        j     ep_hex                    ; continue
ep_bin:                                 ; binary
        addi  s10, s10, 2               ; consume 0b
ep_bloop:                               ; loop: one binary digit
        lbu   t0, 0(s10)                ; digit?
        addi  t0, t0, -'0'              ; value
        li    t1, 2                     ; binary digits are 0 and 1
        bgeu  t0, t1, ep_ret            ; not one: done
        slli  a0, a0, 1                 ; shift in
        add   a0, a0, t0                ; the digit
        addi  s10, s10, 1               ; next
        j     ep_bloop                  ; continue
ep_oct:                                 ; octal (a leading 0)
        lbu   t0, 0(s10)                ; digit?
        addi  t0, t0, -'0'              ; value
        li    t1, 8                     ; octal digits are 0..7
        bgeu  t0, t1, ep_ret            ; not one: done
        slli  a0, a0, 3                 ; shift in
        add   a0, a0, t0                ; the digit
        addi  s10, s10, 1               ; next
        j     ep_oct                    ; continue
ep_dec:                                 ; decimal
        li    t2, 10                    ; base
ep_dloop:                               ; loop: one decimal digit
        lbu   t0, 0(s10)                ; digit?
        addi  t0, t0, -'0'              ; value
        bgeu  t0, t2, ep_ret            ; not one: done
        mul   a0, a0, t2                ; shift in
        add   a0, a0, t0                ; the digit
        addi  s10, s10, 1               ; next
        j     ep_dloop                  ; continue
ep_sym:                                 ; a symbol or .
        mv    a0, s10                   ; scan the name
        li    a1, 255                   ; sasm reads at most 255 characters
        call  scan_sym                  ; a0 = end, a1 = length, a2 = hash
        mv    s0, a0                    ; s0 = end
        li    t0, 1                     ; "." alone?
        bne   a1, t0, ep_look           ; no
        lbu   t0, 0(s10)                ; the character
        li    t1, '.'                   ; dot?
        bne   t0, t1, ep_look           ; no
        mv    s10, s0                   ; consume it
        ld    t0, v_cs(zero)            ; current section
        sd    t0, v_esect(zero)         ; is the expression's section
        ld    a0, S_LOC(s11)            ; value = location
        j     ep_ret                    ; done
ep_look:                                ; look the symbol up
        mv    a0, s10                   ; name
        li    a3, SYMHASH               ; symbol heads
        li    a4, SYMMASK               ; mask
        call  find                      ; a0 = record or 0
        beqz  a0, ep_undef              ; not defined (yet)
        lbu   t0, R_GEN(a0)             ; defined in this pass 1 (or the last one)?
        ld    t1, v_gen(zero)           ; ...
        bne   t0, t1, ep_undef          ; not yet
        lbu   t0, R_SECT(a0)            ; its section
        li    t1, 255                   ; none?
        beq   t0, t1, ep_val            ; a constant
        sd    t0, v_esect(zero)         ; a label: remember its section
ep_val:                                 ; its value
        ld    a0, R_VAL(a0)             ; value
        mv    s10, s0                   ; consume the name
        j     ep_ret                    ; done
ep_undef:                               ; not (yet) defined
        li    t0, 1                     ; mark undefined
        sd    t0, v_undef(zero)         ; ...
        li    t0, 2                     ; pass 2?
        beq   tp, t0, ep_err            ; then it is an error
        mv    s10, s0                   ; consume the name
        li    a0, 0                     ; reads as 0
        j     ep_ret                    ; done
ep_err:                                 ; error: undefined in pass 2
        li    a0, m_undef               ; undefined symbol
        mv    a1, s10                   ; name
        sub   a2, s0, s10               ; its length
        j     fail_n                    ; report
ep_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

; ---- operands ------------------------------------------------------------------------
; dec_tail(a0 = digits) -> a0 = value (capped at 1000), a1 = 1 if the string ends there
dec_tail:                               ; routine entry (leaf)
        li    t0, 0                     ; value
        li    t3, 10                    ; base
dt_loop:                                ; loop: one digit
        lbu   t1, 0(a0)                 ; character
        addi  t2, t1, -'0'              ; digit value
        bgeu  t2, t3, dt_end            ; not a digit
        mul   t0, t0, t3                ; shift in
        add   t0, t0, t2                ; the digit
        li    t2, 1000                  ; cap (anything this big is out of range)
        bltu  t0, t2, dt_ok             ; below the cap
        mv    t0, t2                    ; capped
dt_ok:                                  ; next digit
        addi  a0, a0, 1                 ; next
        j     dt_loop                   ; continue
dt_end:                                 ; end of the digits
        seqz  a1, t1                    ; whole string consumed?
        mv    a0, t0                    ; value
        ret                             ; done

; parse_xreg(a0 = text) -> a0 = register number or -1
parse_xreg:                             ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        mv    s0, a0                    ; s0 = text
        lbu   t0, 0(s0)                 ; first character
        li    t1, 'x'                   ; xN?
        bne   t0, t1, px_name           ; no
        lbu   t0, 1(s0)                 ; second character
        lbu   t0, CCLASS(t0)            ; class
        andi  t0, t0, C_DG              ; digit?
        beqz  t0, px_name               ; no
        addi  a0, s0, 1                 ; the number
        call  dec_tail                  ; a0 = value, a1 = whole?
        beqz  a1, px_name               ; trailing junk
        li    t0, 32                    ; x0..x31
        bltu  a0, t0, px_ret            ; valid
px_name:                                ; try the ABI names
        mv    a0, s0                    ; ABI name?
        call  strhash                   ; a1 = length, a2 = hash
        li    a3, KWHASH                ; keywords
        li    a4, KWMASK                ; ...
        call  find                      ; a0 = record or 0
        beqz  a0, px_none               ; not a keyword
        lbu   t0, R_SECT(a0)            ; class
        li    t1, K_REG                 ; register?
        bne   t0, t1, px_none           ; no
        lbu   a0, R_VAL(a0)             ; register number
        j     px_ret                    ; done
px_none:                                ; not a register
        li    a0, -1                    ; not a register
px_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

; xreg(a0 = text) -> a0 = register number (error if none)
xreg:                                   ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the text, for the message
        call  parse_xreg                ; parse
        bltz  a0, xr_bad                ; not a register
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done
xr_bad:                                 ; error: not a register
        li    a0, m_xreg                ; expected a register
        ld    a1, 8(sp)                 ; got this
        j     fail_s                    ; report

; creg(a0 = text) -> a0 = capability register number c0..c15
creg:                                   ; routine entry
        lbu   t0, 0(a0)                 ; first character
        li    t1, 'c'                   ; c prefix?
        bne   t0, t1, cr_bad            ; no
        addi  a2, a0, 1                 ; the number
        li    a3, m_creg                ; message
        j     numbered                  ; parse it
cr_bad:                                 ; error: no c prefix
        mv    a1, a0                    ; got this
        li    a0, m_creg                ; expected a capability register
        j     fail_s                    ; report

; tagreg(a0 = text) -> a0 = transfer tag number tg0..tg15
tagreg:                                 ; routine entry
        lbu   t0, 0(a0)                 ; first character
        li    t1, 't'                   ; t?
        bne   t0, t1, tg_bad            ; no
        lbu   t0, 1(a0)                 ; second character
        li    t1, 'g'                   ; g?
        bne   t0, t1, tg_bad            ; no
        addi  a2, a0, 2                 ; the number
        li    a3, m_tag                 ; message
        j     numbered                  ; parse it
tg_bad:                                 ; error: no tg prefix
        mv    a1, a0                    ; got this
        li    a0, m_tag                 ; expected a tag
        j     fail_s                    ; report

; numbered(a0 = text, a2 = digits, a3 = message) -> a0 = 0..15 (error otherwise)
numbered:                               ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; text
        sd    a3, 16(sp)                ; message
        lbu   t0, 0(a2)                 ; a digit must follow the prefix
        lbu   t0, CCLASS(t0)            ; class
        andi  t0, t0, C_DG              ; digit?
        beqz  t0, nb_bad                ; no
        mv    a0, a2                    ; the digits
        call  dec_tail                  ; a0 = value, a1 = whole?
        beqz  a1, nb_bad                ; junk after the digits
        li    t0, 16                    ; 0..15
        bgeu  a0, t0, nb_bad            ; out of range
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done
nb_bad:                                 ; error: bad number
        ld    a0, 16(sp)                ; message
        ld    a1, 8(sp)                 ; got this
        j     fail_s                    ; report

; csrnum(a0 = text) -> a0 = CSR number (a name or an expression 0..0xffff)
csrnum:                                 ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        mv    s0, a0                    ; s0 = text
        call  strhash                   ; a1 = length, a2 = hash
        li    a3, KWHASH                ; keywords
        li    a4, KWMASK                ; ...
        call  find                      ; a0 = record or 0
        beqz  a0, cn_expr               ; not a keyword
        lbu   t0, R_SECT(a0)            ; class
        li    t1, K_CSR                 ; CSR name?
        bne   t0, t1, cn_expr           ; no
        lbu   a0, R_VAL(a0)             ; its number
        j     cn_ret                    ; done
cn_expr:                                ; not a CSR name: an expression
        mv    a0, s0                    ; an expression
        call  eval                      ; value
        bltz  a0, cn_bad                ; negative
        li    t0, 0xffff                ; at most 0xffff
        bltu  t0, a0, cn_bad            ; too big
cn_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done
cn_bad:                                 ; error: out of range
        li    a0, m_csr                 ; out of range
        j     fail                      ; report

; memop(a0 = text "imm(reg)" or "(reg)") -> a0 = offset, a1 = base register
memop:                                  ; routine entry
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s2
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        mv    s0, a0                    ; s0 = text
        call  strlen                    ; a1 = length
        beqz  a1, mo_bad                ; empty
        add   t0, s0, a1                ; end
        addi  t0, t0, -1                ; last character
        lbu   t1, 0(t0)                 ; ...
        li    t2, ')'                   ; must close a parenthesis
        bne   t1, t2, mo_bad            ; does not
        mv    s2, t0                    ; s2 = the closing parenthesis
        li    t3, 0                     ; depth
        li    t4, '('                   ; opening
mo_scan:                                ; loop: find the matching (
        bltu  t0, s0, mo_bad            ; ran off the start: unbalanced
        lbu   t1, 0(t0)                 ; character
        bne   t1, t2, mo_s1             ; not )
        addi  t3, t3, 1                 ; deeper
mo_s1:                                  ; not )
        bne   t1, t4, mo_s2             ; not (
        addi  t3, t3, -1                ; shallower
        beqz  t3, mo_open               ; the matching one
mo_s2:                                  ; keep scanning left
        addi  t0, t0, -1                ; move left
        j     mo_scan                   ; continue
mo_open:                                ; found the (
        mv    s1, t0                    ; s1 = the opening parenthesis
        sb    zero, 0(s2)               ; cut the closing one
        addi  a0, s1, 1                 ; the register text
        call  trim                      ; trimmed
        call  xreg                      ; register number
        mv    s2, a0                    ; s2 = base register
        sb    zero, 0(s1)               ; cut at the opening parenthesis
        mv    a0, s0                    ; the offset text
        call  trim                      ; trimmed
        lbu   t0, 0(a0)                 ; empty?
        beqz  t0, mo_zero               ; offset 0
        call  eval                      ; value
        j     mo_ret                    ; done
mo_zero:                                ; empty offset
        li    a0, 0                     ; no offset
mo_ret:                                 ; done
        mv    a1, s2                    ; base register
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        addi  sp, sp, 32                ; pop
        ret                             ; done
mo_bad:                                 ; error: not offset(register)
        li    a0, m_mem                 ; expected offset(register)
        mv    a1, s0                    ; got this
        j     fail_s                    ; report

; check_imm(a0 = value, a1 = range kind): pass 2 only
;   0 signed 16, 1 unsigned 16, 2 shift 0..63, 3 lui -32768..65535,
;   4 capability slot 0..63, 5 overlay index 0..7
check_imm:                              ; routine entry (leaf)
        li    t0, 2                     ; pass 2?
        bne   tp, t0, ci_ok             ; no checks in pass 1
        slli  t0, a1, 4                 ; 16 bytes per range entry
        ld    t1, ranges(t0)            ; lowest allowed
        blt   a0, t1, ci_bad            ; below
        ld    t1, ranges+8(t0)          ; highest allowed
        blt   t1, a0, ci_bad            ; above
ci_ok:                                  ; in range
        ret                             ; fits
ci_bad:                                 ; error: out of range
        slli  t0, a1, 3                 ; message index
        ld    a0, rmsgs(t0)             ; the message
        j     fail                      ; report

; tagmask(a0 = operand pointer array, a1 = count) -> a0 = mask
tagmask:                                ; routine entry
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s2
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        mv    s0, a0                    ; s0 = operand pointers
        mv    s1, a1                    ; s1 = count
        beqz  s1, tm_one                ; no operands
        ld    t0, 0(s0)                 ; first operand
        lbu   t1, 0(t0)                 ; starts with "tg"?
        li    t2, 't'                   ; ...
        bne   t1, t2, tm_one            ; no: a mask
        lbu   t1, 1(t0)                 ; ...
        li    t2, 'g'                   ; ...
        bne   t1, t2, tm_one            ; no: a mask
        li    s2, 0                     ; s2 = mask
tm_list:                                ; loop: one tag
        ld    a0, 0(s0)                 ; a tag
        call  tagreg                    ; its number
        li    t0, 1                     ; one bit
        sll   t0, t0, a0                ; for that tag
        or    s2, s2, t0                ; collect
        addi  s0, s0, 8                 ; next operand
        addi  s1, s1, -1                ; one fewer
        bnez  s1, tm_list               ; all of them
        j     tm_ret                    ; done
tm_one:                                 ; a single mask expression
        li    t0, 1                     ; a mask is one operand
        bne   s1, t0, tm_bad            ; anything else is an error
        ld    a0, 0(s0)                 ; the mask expression
        call  eval                      ; value
        mv    s2, a0                    ; s2 = mask
        li    a1, 1                     ; unsigned 16 bits
        call  check_imm                 ; pass 2 range check
tm_ret:                                 ; done
        mv    a0, s2                    ; mask
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        addi  sp, sp, 32                ; pop
        ret                             ; done
tm_bad:                                 ; error: neither tags nor one mask
        li    a0, m_tags                ; expected tags or a mask
        j     fail                      ; report

; pcrel(a0 = target text, a1 = bits) -> a0 = word offset from this instruction
pcrel:                                  ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        mv    s0, a1                    ; s0 = field width
        call  eval                      ; a0 = target, a1 = undefined?
        li    t0, 1                     ; pass 1?
        beq   tp, t0, pc_zero           ; offsets only matter in pass 2
        bnez  a1, pc_zero               ; (undefined was reported)
        ld    t0, v_esect(zero)         ; section of the target
        bltz  t0, pc_same               ; a plain number
        ld    t1, v_cs(zero)            ; current section
        bne   t0, t1, pc_sect           ; another section
pc_same:                                ; same section (or a number)
        ld    t1, S_LOC(s11)            ; this instruction's address
        sub   a0, a0, t1                ; byte distance
        andi  t0, a0, 3                 ; word aligned?
        bnez  t0, pc_align              ; no
        srai  a0, a0, 2                 ; word distance
        addi  t0, s0, -1                ; bits - 1
        li    t1, 1                     ; ...
        sll   t1, t1, t0                ; t1 = limit
        bge   a0, t1, pc_range          ; too far forward
        neg   t1, t1                    ; -limit
        blt   a0, t1, pc_range          ; too far back
        j     pc_ret                    ; fits
pc_zero:                                ; pass 1 or unknown target
        li    a0, 0                     ; placeholder
pc_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done
pc_sect:                                ; error: target in another section
        li    a0, m_sect                ; another section
        j     fail                      ; report
pc_align:                               ; error: misaligned target
        li    a0, m_balign              ; misaligned target
        j     fail                      ; report
pc_range:                               ; error: target too far
        li    a0, m_range               ; too far
        j     fail                      ; report

; ---- emission --------------------------------------------------------------------------
; emit_byte(a0 = byte) at the current location of the current section
emit_byte:                              ; routine entry (leaf)
        ld    t0, S_LOC(s11)            ; location
        ld    t1, S_LIMIT(s11)          ; address space size
        li    t2, 2                     ; pass 2?
        bltu  t0, t1, eb_in             ; inside the address space
        beq   tp, t2, eb_ovf            ; past the end: an error in pass 2
        addi  t0, t0, 1                 ; pass 1 only counts it (a later pass 1
        sd    t0, S_LOC(s11)            ; may place the code elsewhere)
        ret                             ; done
eb_in:                                  ; inside
        beq   tp, t2, eb_p2             ; pass 2: store the byte
        ld    t1, S_LO(s11)             ; pass 1: lowest address so far
        bgeu  t0, t1, eb_p1             ; not lower
        sd    t0, S_LO(s11)             ; new lowest
eb_p1:                                  ; pass 1: advance and track the size
        addi  t0, t0, 1                 ; advance
        sd    t0, S_LOC(s11)            ; ...
        ld    t1, S_SIZE(s11)           ; highest so far
        bgeu  t1, t0, eb_ret            ; not higher
        sd    t0, S_SIZE(s11)           ; new highest
eb_ret:                                 ; done
        ret                             ; done
eb_p2:                                  ; pass 2: store into the window
        ld    t1, S_WBASE(s11)          ; window start address
eb_win:                                 ; loop: until the window holds the location
        sub   t2, t0, t1                ; position in the window
        li    t3, WINSZ                 ; window size
        bltu  t2, t3, eb_put            ; inside
        ld    t4, S_WBUF(s11)           ; past it: flush the window
        ld    t5, S_FADJ(s11)           ; arena offset of address 0
        add   t5, t5, t1                ; arena offset of the window
        tput  tg0, t4, c0, t5, t3       ; write it (later stores into it wait)
        li    t5, 0                     ; clear it (a gap, such as the rest of
eb_clr:                                 ; a code unit, is zeros)
        add   t2, t4, t5                ; 8 bytes of it
        sd    zero, 0(t2)               ; cleared
        addi  t5, t5, 8                 ; next
        bltu  t5, t3, eb_clr            ; the whole window
        add   t1, t1, t3                ; next window
        sd    t1, S_WBASE(s11)          ; ...
        j     eb_win                    ; does it hold the location?
eb_put:                                 ; store the byte
        ld    t4, S_WBUF(s11)           ; window buffer
        add   t4, t4, t2                ; byte address
        sb    a0, 0(t4)                 ; store
        addi  t0, t0, 1                 ; advance
        sd    t0, S_LOC(s11)            ; ...
        ret                             ; done
eb_ovf:                                 ; error: past the end of the address space
        li    a0, m_ovf                 ; overflow
        j     fail                      ; report

; emit_le(a0 = value, a1 = byte count): little endian
emit_le:                                ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        mv    s0, a0                    ; s0 = value
        mv    s1, a1                    ; s1 = bytes left
el_loop:                                ; loop: one byte
        beqz  s1, el_ret                ; done
        andi  a0, s0, 255               ; low byte
        call  emit_byte                 ; emit
        srli  s0, s0, 8                 ; next byte
        addi  s1, s1, -1                ; one fewer
        j     el_loop                   ; continue
el_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 24                ; pop
        ret                             ; done

; emit_insn(a0 = instruction word)
emit_insn:                              ; routine entry
        ld    t0, S_LOC(s11)            ; location
        andi  t0, t0, 3                 ; word aligned?
        bnez  t0, ei_bad                ; no
        li    a1, 4                     ; four bytes
        j     emit_le                   ; emit
ei_bad:                                 ; error: misaligned instruction
        li    a0, m_ialign              ; misaligned instruction
        j     fail                      ; report

; enc_i(a0 = op, a1 = rd, a2 = rs1, a3 = imm): op | rd | rs1 | imm16
enc_i:                                  ; routine entry
        slli  a0, a0, 26                ; opcode: bits 26..31
        slli  a1, a1, 21                ; rd: bits 21..25
        or    a0, a0, a1                ; merge
        slli  a2, a2, 16                ; rs1: bits 16..20
        or    a0, a0, a2                ; merge
        li    t0, 0xffff                ; 16-bit immediate
        and   a3, a3, t0                ; ...
        or    a0, a0, a3                ; merge
        j     emit_insn                 ; emit

; enc_r(a0 = op, a1 = rd, a2 = rs1, a3 = rs2, a4 = funct): register format
enc_r:                                  ; routine entry
        slli  a0, a0, 26                ; opcode: bits 26..31
        slli  a1, a1, 21                ; rd: bits 21..25
        or    a0, a0, a1                ; merge
        slli  a2, a2, 16                ; rs1: bits 16..20
        or    a0, a0, a2                ; merge
        slli  a3, a3, 11                ; rs2: bits 11..15
        or    a0, a0, a3                ; merge
        andi  a4, a4, 0x7ff             ; function: bits 0..10
        or    a0, a0, a4                ; merge
        j     emit_insn                 ; emit

; do_li(a0 = rd, a1 = expression, a2 = 1 for la)
; Size: la always 2; li 1 if it fits 16 bits signed, 2 if 32 bits signed,
; else (or if not yet known in pass 1) 6. Pass 2 replays the pass 1 size.
do_li:                                  ; routine entry
        addi  sp, sp, -40               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s3
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        sd    s3, 32(sp)                ; ...
        mv    s0, a0                    ; s0 = rd
        mv    s2, a2                    ; s2 = la?
        mv    a0, a1                    ; the expression
        call  eval                      ; a0 = value, a1 = undefined?
        mv    s1, a0                    ; s1 = value
        ld    t0, v_lii(zero)           ; li index
        li    t1, LIMAX                 ; table size
        bgeu  t0, t1, li_full           ; full
        srli  t2, t0, 2                 ; byte holding the entry
        andi  t3, t0, 3                 ; entry within the byte
        slli  t3, t3, 1                 ; bit position
        addi  t4, t0, 1                 ; next index
        sd    t4, v_lii(zero)           ; ...
        li    t4, 2                     ; pass 2?
        beq   tp, t4, li_p2             ; yes: replay
        li    s3, 1                     ; la: 2 instructions (code 1)
        bnez  s2, li_store              ; ...
        li    s3, 2                     ; unknown: 6 instructions (code 2)
        bnez  a1, li_store              ; ...
        li    s3, 0                     ; 16-bit signed: 1 instruction (code 0)
        slli  t4, s1, 48                ; sign-extend the low 16 bits
        srai  t4, t4, 48                ; ...
        beq   t4, s1, li_store          ; same value: fits
        li    s3, 1                     ; 32-bit signed: 2 instructions (code 1)
        slli  t4, s1, 32                ; sign-extend the low 32 bits
        srai  t4, t4, 32                ; ...
        beq   t4, s1, li_store          ; same value: fits
        li    s3, 2                     ; otherwise 6 instructions (code 2)
li_store:                               ; pass 1: record the size code
        lbu   t4, LITAB(t2)             ; the byte
        bnez  t3, li_merge              ; not its first entry
        li    t4, 0                     ; first entry: start clean
li_merge:                               ; merge it into the byte
        sll   t5, s3, t3                ; code into position
        or    t4, t4, t5                ; merge
        sb    t4, LITAB(t2)             ; store
        j     li_gen                    ; emit
li_p2:                                  ; pass 2: replay the size code
        lbu   t4, LITAB(t2)             ; the byte
        srl   t4, t4, t3                ; the entry
        andi  s3, t4, 3                 ; s3 = size code
        beqz  s2, li_gen                ; li: no range rule
        bltz  s1, li_la                 ; la: negative address
        li    t4, 0x7fffffff            ; largest address
        bltu  t4, s1, li_la             ; too big
li_gen:                                 ; emit by size
        beqz  s3, li_one                ; 1 instruction
        mv    a0, s0                    ; rd
        mv    a1, s1                    ; 2 instructions: lui, ori of v
        li    t0, 1                     ; ...
        beq   s3, t0, li_two            ; ...
        srai  a1, s1, 32                ; 6: lui, ori of the high 32 bits,
        call  emit_luo                  ; ...
        srai  a0, s1, 16                ; then slli 16, ori (v >> 16) & 0xffff,
        call  li_sh                     ; ...
        mv    a0, s1                    ; then slli 16, ori v & 0xffff
        call  li_sh                     ; ...
        j     li_ret                    ; done
li_two:                                 ; lui rd, (v >> 16) & 0xffff; ori rd, rd, v & 0xffff
        call  emit_luo                  ; ...
        j     li_ret                    ; done
li_one:                                 ; 1 instruction: addi
        li    a0, OP_ADDI               ; addi rd, zero, v
        mv    a1, s0                    ; rd
        li    a2, 0                     ; rs1
        mv    a3, s1                    ; immediate (masked)
        call  enc_i                     ; emit
li_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        addi  sp, sp, 40                ; pop
        ret                             ; done
li_sh:                                  ; slli s0, s0, 16; ori s0, s0, a0 & 0xffff
        addi  sp, sp, -16               ; frame (a0 is kept on it)
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the immediate
        li    a0, OP_SLLI               ; slli rd, rd, 16
        mv    a1, s0                    ; ...
        mv    a2, s0                    ; ...
        li    a3, 16                    ; ...
        call  enc_i                     ; ...
        li    a0, OP_ORI                ; ori rd, rd, imm
        mv    a1, s0                    ; ...
        mv    a2, s0                    ; ...
        ld    a3, 8(sp)                 ; (masked)
        call  enc_i                     ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done
li_full:                                ; error: table full
        li    a0, m_limax               ; too many li/la
        j     fail                      ; report
li_la:                                  ; error: la address out of range
        li    a0, m_la                  ; la out of range
        j     fail                      ; report

; emit_string(a0 = text containing "...", a1 = 1 to add a NUL)
emit_string:                            ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        mv    s1, a1                    ; s1 = add a NUL?
estr_find:                              ; loop: find the opening quote
        lbu   t0, 0(a0)                 ; character
        beqz  t0, estr_none             ; no opening quote
        li    t1, '"'                   ; quote?
        beq   t0, t1, estr_open         ; found
        addi  a0, a0, 1                 ; next
        j     estr_find                 ; continue
estr_open:                              ; found it
        addi  s0, a0, 1                 ; s0 = first character inside
estr_loop:                              ; loop: one string character
        lbu   a0, 0(s0)                 ; character
        beqz  a0, estr_unterm           ; no closing quote
        li    t1, '"'                   ; closing quote?
        beq   a0, t1, estr_done         ; yes
        li    t1, '\\'                  ; escape?
        bne   a0, t1, estr_emit         ; no
        addi  s0, s0, 1                 ; the escaped character
        lbu   a0, 0(s0)                 ; ...
        beqz  a0, estr_unterm           ; nothing after the backslash
        li    t1, 'n'                   ; \n
        bne   a0, t1, es_e1             ; no
        li    a0, 10                    ; newline
        j     estr_emit                 ; emit
es_e1:                                  ; not \n
        li    t1, 't'                   ; \t
        bne   a0, t1, es_e2             ; no
        li    a0, 9                     ; tab
        j     estr_emit                 ; emit
es_e2:                                  ; not \t
        li    t1, 'r'                   ; \r
        bne   a0, t1, es_e3             ; no
        li    a0, 13                    ; carriage return
        j     estr_emit                 ; emit
es_e3:                                  ; not \r
        li    t1, '0'                   ; \0
        bne   a0, t1, es_e4             ; no
        li    a0, 0                     ; NUL
        j     estr_emit                 ; emit
es_e4:                                  ; not \0
        li    t1, 'x'                   ; \x hex digits
        bne   a0, t1, estr_emit         ; no: the character itself
        li    a0, 0                     ; value
es_hex:                                 ; loop: one \x hex digit
        lbu   t0, 1(s0)                 ; next character
        lbu   t1, CCLASS(t0)            ; class
        andi  t1, t1, C_HX              ; hex digit?
        beqz  t1, estr_emit             ; no: done (s0 on the last one used)
        li    t1, '9'                   ; letter or digit?
        bgeu  t1, t0, es_hd             ; digit
        ori   t0, t0, 0x20              ; lower case
        addi  t0, t0, 10 - 'a'          ; 10..15
        j     es_ha                     ; add
es_hd:                                  ; 0..9
        addi  t0, t0, -'0'              ; 0..9
es_ha:                                  ; accumulate
        slli  a0, a0, 4                 ; shift in
        add   a0, a0, t0                ; the digit
        addi  s0, s0, 1                 ; consumed
        j     es_hex                    ; continue
estr_emit:                              ; emit the byte in a0
        andi  a0, a0, 255               ; one byte
        call  emit_byte                 ; emit
        addi  s0, s0, 1                 ; next
        j     estr_loop                 ; continue
estr_done:                              ; closing quote reached
        beqz  s1, estr_ret              ; no terminator wanted
        li    a0, 0                     ; NUL
        call  emit_byte                 ; emit
estr_ret:                               ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 24                ; pop
        ret                             ; done
estr_none:                              ; error: no string
        li    a0, m_str                 ; expected a string
        j     fail                      ; report
estr_unterm:                            ; error: no closing quote
        li    a0, m_unterm              ; unterminated
        j     fail                      ; report

; ---- paged code and far data: the pre-scan ------------------------------------------------
; asm/sasm.c ("paged code and far data", prescan, layout, paged_transfer,
; paged_branch, emit_flink, emit_farcall, emit_stub, emit_cache) is the
; specification: what follows does the same, in the same order.

; prescan(): sasm's prescan, in up to four passes over the source
;   A  .text labels (entered as symbols with FL_TL), .resident, .near, the
;      program's first instruction, the lines that conflict with the modes;
;      then the defaults (on for a StrataOS program) and the errors
;   B  functions (FL_FUNC: call / jal ra targets) and labels whose address
;      is taken (FL_TAKEN)
;   C  regions: one from each line with a function's label (and the first
;      .text line); each .text label's region (R_REG)
;   D  what joins regions (fall-through, jumps and branches to labels that
;      are not functions), what pins them (taken labels, .pinned); then the
;      groups, in the region table
prescan:                                ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        li    tp, 0                     ; (not an assembly pass)
        li    a0, pa_line               ; A
        call  scan_src                  ; ...
        ld    t0, v_org(zero)           ; the defaults: on at a text origin other than 0
        snez  t0, t0                    ; ...
        ld    t1, v_paged(zero)         ; paged code: given?
        bgez  t1, ps_d1                 ; yes (.resident)
        sd    t0, v_paged(zero)         ; no: the default
ps_d1:                                  ; far data
        ld    t1, v_far(zero)           ; given?
        bgez  t1, ps_d2                 ; yes (.near)
        sd    t0, v_far(zero)           ; no: the default
ps_d2:                                  ; the errors of paged code
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, ps_e3                 ; no
        ld    t1, v_own15(zero)         ; c15 is the kernel's
        li    a0, m_c15                 ; ...
        bnez  t1, ps_err                ; ...
        ld    t1, v_owncode(zero)       ; the program pages its own code
        li    a0, m_owncode             ; ...
        bnez  t1, ps_err                ; ...
ps_e3:                                  ; of far data
        ld    t0, v_far(zero)           ; far data?
        beqz  t0, ps_e4                 ; no
        ld    t1, v_owncache(zero)      ; the program has its own cache
        li    a0, m_owncache            ; ...
        bnez  t1, ps_err                ; ...
ps_e4:                                  ; of either: the entry must be `j`
        ld    t0, v_paged(zero)         ; paged code
        ld    t1, v_far(zero)           ; or far data?
        or    t0, t0, t1                ; ...
        beqz  t0, ps_ret                ; neither: nothing more to find
        ld    t1, v_first(zero)         ; the first instruction
        beqz  t1, ps_e5                 ; (none)
        ld    t2, v_firstj(zero)        ; is it `j`?
        li    a0, m_entry               ; ...
        beqz  t2, ps_err                ; no
ps_e5:                                  ; paged code: functions, regions, groups
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, ps_ret                ; no
        li    a0, pb_line               ; B
        call  scan_src                  ; ...
        li    a0, pc_line               ; C
        call  scan_src                  ; ...
        ld    t0, v_regctr(zero)        ; the regions
        addi  t0, t0, 1                 ; ...
        sd    t0, v_nreg(zero)          ; ...
        slli  a1, t0, 4                 ; a1 = their table's size (RGSZ each)
        ld    a0, v_heap(zero)          ; a0 = the table, from the heap
        sd    a0, v_regs(zero)          ; ...
        add   t1, a0, a1                ; its end
        ld    t2, v_hend(zero)          ; heap limit
        bltu  t2, t1, ps_full           ; no room
        sd    t1, v_heap(zero)          ; claimed
        call  zero_mem                  ; cleared
        li    t0, -1                    ; no .text line yet
        sd    t0, v_lastreg(zero)       ; ...
        li    t0, 1                     ; ...
        sd    t0, v_lastterm(zero)      ; ...
        li    a0, pd_line               ; D
        call  scan_src                  ; ...
        ld    t0, v_regs(zero)          ; t0 = region record
        ld    t1, v_nreg(zero)          ; t1 = regions
        beqz  t1, ps_ret                ; (none)
        li    t2, 1                     ; the entry's region is pinned
        sb    t2, RG_PIN(t0)            ; ...
        li    t2, 0                     ; t2 = region
        li    t3, 0                     ; t3 = its group (the group's first region)
ps_grp:                                 ; loop: one region
        bgeu  t2, t1, ps_ret            ; all done
        beqz  t2, ps_g1                 ; the first starts a group
        lbu   t4, RG_JOIN - RGSZ(t0)    ; joined to the region before?
        bnez  t4, ps_g2                 ; yes: same group
ps_g1:                                  ; a new group
        mv    t3, t2                    ; starts here
ps_g2:                                  ; the region's group is known
        sh    t3, RG_GRP(t0)            ; ...
        lbu   t4, RG_PIN(t0)            ; a pinned region
        beqz  t4, ps_g3                 ; ...
        slli  t5, t3, 4                 ; pins its group
        ld    t6, v_regs(zero)          ; ...
        add   t5, t5, t6                ; ...
        li    t4, 1                     ; ...
        sb    t4, RG_GPIN(t5)           ; ...
ps_g3:                                  ; next region
        addi  t0, t0, RGSZ              ; next record
        addi  t2, t2, 1                 ; its number
        j     ps_grp                    ; continue
ps_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done
ps_err:                                 ; error about line t1: message in a0
        sd    t1, v_line(zero)          ; that line
        j     fail                      ; report
ps_full:                                ; error: no room for the region table
        li    a0, m_full                ; heap exhausted
        j     fail                      ; report

; scan_src(a0 = handler): one pre-scan pass. Each line that is not an
; .include is parsed (ps_parse) and given to the handler, with v_psect the
; section it starts in and v_ltext = 1 if it is .text code (in .text, not
; a section directive).
scan_src:                               ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        mv    s0, a0                    ; s0 = handler
        call  rewind                    ; from the first line
        sd    zero, v_psect(zero)       ; in .text
        li    t0, -1                    ; no region yet
        sd    t0, v_regctr(zero)        ; ...
sc_loop:                                ; loop: one line
        call  read_line                 ; next line into LINEBUF
        beqz  a0, sc_done               ; end of the source
        li    a0, LINEBUF               ; an .include line?
        call  is_include                ; ...
        bnez  a0, sc_loop               ; skipped
        li    a0, LINEBUF               ; the line
        call  strip_comment             ; cut ; # // comments
        li    a0, LINEBUF               ; the line
        call  trim                      ; drop surrounding white space
        call  ps_parse                  ; labels and mnemonic
        ld    t0, v_psect(zero)         ; in .text?
        seqz  t0, t0                    ; ...
        ld    t1, v_mfmt(zero)          ; a section directive is not code
        li    t2, D_SECT                ; ...
        bne   t1, t2, sc_lt             ; ...
        li    t0, 0                     ; ...
sc_lt:                                  ; t0 = .text code?
        sd    t0, v_ltext(zero)         ; ...
        jalr  ra, s0, 0                 ; the handler
        ld    t1, v_mfmt(zero)          ; a section directive?
        li    t2, D_SECT                ; ...
        bne   t1, t2, sc_loop           ; no
        ld    t0, v_mfn(zero)           ; the next line starts in that section
        sd    t0, v_psect(zero)         ; ...
        j     sc_loop                   ; continue
sc_done:                                ; pass done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

; ps_parse(a0 = a line, comment stripped and trimmed): what sasm's
; parse_line finds, without changing the line
;   LABS, v_nlabs  its labels (name, length, hash; the first 8)
;   v_mk           0 nothing after them, 1 a mnemonic (in MBUF), 2 `name = expr`
;   v_mrec, v_mfmt, v_mop, v_mfn   the mnemonic's keyword record (0 if it is
;                  not one), format (255 if none), opcode and function
;   v_mrest        the text after the mnemonic, or after the `=`
ps_parse:                               ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        mv    s0, a0                    ; s0 = cursor
        li    s1, 0                     ; s1 = labels kept
pp_lab:                                 ; loop: one leading label
        lbu   t0, 0(s0)                 ; next character
        lbu   t0, CCLASS(t0)            ; its class
        andi  t0, t0, C_SS              ; can it start a symbol?
        beqz  t0, pp_end                ; no: no label here
        mv    a0, s0                    ; scan the name
        li    a1, -1                    ; of any length
        call  scan_sym                  ; a0 = end, a1 = length, a2 = hash
        lbu   t0, 0(a0)                 ; character after it
        li    t1, ':'                   ; a label?
        bne   t0, t1, pp_end            ; no
        li    t1, MAXLABS               ; room for it?
        bgeu  s1, t1, pp_skip           ; no (sasm keeps 8)
        li    t1, 24                    ; its entry
        mul   t1, s1, t1                ; ...
        sd    s0, LABS(t1)              ; name
        sd    a1, LABS+8(t1)            ; length
        sd    a2, LABS+16(t1)           ; hash
        addi  s1, s1, 1                 ; one more
pp_skip:                                ; after the colon
        addi  a0, a0, 1                 ; ...
        call  skipws                    ; skip blanks
        mv    s0, a0                    ; continue there
        j     pp_lab                    ; several labels may share a line
pp_end:                                 ; no (more) labels
        sd    s1, v_nlabs(zero)         ; how many
        sd    s0, v_mrest(zero)         ; nothing after them yet
        sd    zero, v_mk(zero)          ; ...
        sd    zero, v_mrec(zero)        ; ...
        li    t0, 255                   ; no format
        sd    t0, v_mfmt(zero)          ; ...
        lbu   t0, 0(s0)                 ; anything left?
        beqz  t0, pp_ret                ; no
        lbu   t1, CCLASS(t0)            ; a name?
        andi  t1, t1, C_SS              ; ...
        beqz  t1, pp_mn                 ; no: cannot be `name = expr`
        mv    a0, s0                    ; scan it
        li    a1, -1                    ; any length
        call  scan_sym                  ; a0 = end
        call  skipws                    ; blanks after the name
        lbu   t0, 0(a0)                 ; next character
        li    t1, '='                   ; assignment?
        bne   t0, t1, pp_mn             ; no
        lbu   t2, 1(a0)                 ; "==" is not one
        beq   t2, t1, pp_mn             ; ...
        addi  a0, a0, 1                 ; the expression
        sd    a0, v_mrest(zero)         ; ...
        li    t0, 2                     ; `name = expr`
        sd    t0, v_mk(zero)            ; ...
        j     pp_ret                    ; done
pp_mn:                                  ; a mnemonic
        li    t0, 1                     ; ...
        sd    t0, v_mk(zero)            ; ...
        mv    a0, s0                    ; copy it into MBUF
        call  get_mnem                  ; a0 = rest, a1 = length, a2 = hash
        sd    a0, v_mrest(zero)         ; the operands
        li    a0, MBUF                  ; look it up
        li    a3, KWHASH                ; among the keywords
        li    a4, KWMASK                ; ...
        call  find                      ; a0 = record or 0
        beqz  a0, pp_ret                ; not a keyword
        lbu   t0, R_SECT(a0)            ; an instruction or directive?
        li    t1, K_OP                  ; ...
        bne   t0, t1, pp_ret            ; no (a register or CSR name)
        sd    a0, v_mrec(zero)          ; the record
        lbu   t0, R_VAL(a0)             ; format
        sd    t0, v_mfmt(zero)          ; ...
        lbu   t0, R_VAL+2(a0)           ; opcode
        sd    t0, v_mop(zero)           ; ...
        lbu   t0, R_VAL+3(a0)           ; function
        sd    t0, v_mfn(zero)           ; ...
pp_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 24                ; pop
        ret                             ; done

; lab_get(a0 = index) -> a0 = the line's label: name, a1 = length, a2 = hash
lab_get:                                ; routine entry (leaf)
        li    t0, 24                    ; its entry in LABS
        mul   t0, a0, t0                ; ...
        ld    a0, LABS(t0)              ; name
        ld    a1, LABS+8(t0)            ; length
        ld    a2, LABS+16(t0)           ; hash
        ret                             ; done

; lab_rec(a0 = index) -> a0 = the symbol record of the line's label, 0 if none
lab_rec:                                ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  lab_get                   ; the label
        li    a3, SYMHASH               ; among the symbols
        li    a4, SYMMASK               ; ...
        call  find                      ; a0 = record or 0
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; lookup_tl(a0 = NUL-terminated name) -> a0 = its record if it is a .text label, else 0
lookup_tl:                              ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  strhash                   ; a1 = length, a2 = hash
        li    a3, SYMHASH               ; among the symbols
        li    a4, SYMMASK               ; ...
        call  find                      ; a0 = record or 0
        beqz  a0, lt_ret                ; none
        lbu   t0, R_FL(a0)              ; a .text label?
        andi  t0, t0, FL_TL             ; ...
        bnez  t0, lt_ret                ; yes
        li    a0, 0                     ; no
lt_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; tl_group(a0 = .text label record) -> a0 = its group (the group's first
; region, -1 if it has no region), a1 = the group's pinned flag
tl_group:                               ; routine entry (leaf)
        lhu   t0, R_REG(a0)             ; its region
        li    t1, 0xffff                ; none?
        beq   t0, t1, tg_none           ; ...
        ld    t1, v_regs(zero)          ; the region table
        slli  t0, t0, 4                 ; the region's record
        add   t0, t0, t1                ; ...
        lhu   a0, RG_GRP(t0)            ; its group
        slli  t0, a0, 4                 ; the group's record
        add   t0, t0, t1                ; ...
        lbu   a1, RG_GPIN(t0)           ; pinned?
        ret                             ; done
tg_none:                                ; a label on a section directive line
        li    a0, -1                    ; no group
        li    a1, 1                     ; (treated as resident)
        ret                             ; done

; reg_rec(a0 = region) -> a0 = its record
reg_rec:                                ; routine entry (leaf)
        slli  a0, a0, 4                 ; RGSZ bytes each
        ld    t0, v_regs(zero)          ; the table
        add   a0, a0, t0                ; ...
        ret                             ; done

; reg_step() -> a0 = the region of the current .text line: a new one if
; there is none yet or a label on the line is a function's
reg_step:                               ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        ld    t0, v_regctr(zero)        ; the first region?
        bltz  t0, rs_new                ; yes
        li    s0, 0                     ; s0 = label index
rs_lab:                                 ; loop: one label of the line
        ld    t0, v_nlabs(zero)         ; all seen?
        bgeu  s0, t0, rs_same           ; yes: the same region
        mv    a0, s0                    ; its record
        call  lab_rec                   ; ...
        beqz  a0, rs_next               ; none
        lbu   t0, R_FL(a0)              ; a function?
        andi  t0, t0, FL_FUNC           ; ...
        bnez  t0, rs_new                ; yes: a new region
rs_next:                                ; next label
        addi  s0, s0, 1                 ; ...
        j     rs_lab                    ; continue
rs_new:                                 ; a new region starts here
        ld    t0, v_regctr(zero)        ; ...
        addi  t0, t0, 1                 ; ...
        sd    t0, v_regctr(zero)        ; ...
rs_same:                                ; the region is known
        ld    a0, v_regctr(zero)        ; ...
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

; join(a0, a1 = regions): the regions from the lower up to the higher one
; join their next: one group
join:                                   ; routine entry (leaf)
        bltu  a0, a1, jn_ord            ; in order?
        mv    t0, a0                    ; no: swap
        mv    a0, a1                    ; ...
        mv    a1, t0                    ; ...
jn_ord:                                 ; a0 < a1
        ld    t1, v_regs(zero)          ; the table
jn_loop:                                ; loop: one region
        bgeu  a0, a1, jn_ret            ; all done
        slli  t0, a0, 4                 ; its record
        add   t0, t0, t1                ; ...
        li    t2, 1                     ; joined to the next
        sb    t2, RG_JOIN(t0)           ; ...
        addi  a0, a0, 1                 ; next
        j     jn_loop                   ; continue
jn_ret:                                 ; done
        ret                             ; done

; streq(a0, a1 = strings) -> a0 = 1 if they are equal
streq:                                  ; routine entry (leaf)
        lbu   t0, 0(a0)                 ; character
        lbu   t1, 0(a1)                 ; ...
        bne   t0, t1, se_no             ; differ
        beqz  t0, se_yes                ; both ended
        addi  a0, a0, 1                 ; next
        addi  a1, a1, 1                 ; ...
        j     streq                     ; continue
se_yes:                                 ; equal
        li    a0, 1                     ; ...
        ret                             ; done
se_no:                                  ; not equal
        li    a0, 0                     ; ...
        ret                             ; done

; note_line(a0 = address of a line variable): the current line, if it holds none yet
note_line:                              ; routine entry (leaf)
        ld    t0, 0(a0)                 ; already one?
        bnez  t0, nl_ret                ; yes: keep the first
        ld    t0, v_line(zero)          ; this line
        sd    t0, 0(a0)                 ; ...
nl_ret:                                 ; done
        ret                             ; done

; set_func(a0 = name): if it is a .text label, it is a function's
set_func:                               ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        call  lookup_tl                 ; the label
        beqz  a0, sf_ret                ; not one
        lbu   t0, R_FL(a0)              ; a function
        ori   t0, t0, FL_FUNC           ; ...
        sb    t0, R_FL(a0)              ; ...
sf_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; mark_taken(a0 = expression): every .text label it names has its address
; taken. Quoted strings and characters are skipped; a run of symbol
; characters is a name if it starts as one (so 0x1f is not).
mark_taken:                             ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        mv    s0, a0                    ; s0 = cursor
mt_loop:                                ; loop: one character or run
        lbu   t0, 0(s0)                 ; character
        beqz  t0, mt_ret                ; end
        li    t1, '"'                   ; a string?
        beq   t0, t1, mt_q              ; ...
        li    t1, '\''                  ; a character?
        beq   t0, t1, mt_q              ; ...
        lbu   t1, CCLASS(t0)            ; its class
        andi  t2, t1, C_SC              ; a symbol character?
        beqz  t2, mt_next               ; no
        andi  t2, t1, C_SS              ; does the run start a name?
        beqz  t2, mt_run                ; no: skip it
        mv    a0, s0                    ; the name
        li    a1, -1                    ; all of it
        call  scan_sym                  ; a0 = end, a1 = length, a2 = hash
        mv    s1, a0                    ; s1 = end
        mv    a0, s0                    ; look it up
        li    a3, SYMHASH               ; among the symbols
        li    a4, SYMMASK               ; ...
        call  find                      ; a0 = record or 0
        mv    s0, s1                    ; past the name
        beqz  a0, mt_loop               ; not a symbol
        lbu   t0, R_FL(a0)              ; a .text label?
        andi  t1, t0, FL_TL             ; ...
        beqz  t1, mt_loop               ; no
        ori   t0, t0, FL_TAKEN          ; its address is taken
        sb    t0, R_FL(a0)              ; ...
        j     mt_loop                   ; continue
mt_run:                                 ; loop: skip a run (a number)
        addi  s0, s0, 1                 ; next
        lbu   t0, 0(s0)                 ; character
        lbu   t1, CCLASS(t0)            ; a symbol character?
        andi  t1, t1, C_SC              ; ...
        bnez  t1, mt_run                ; yes: still the run
        j     mt_loop                   ; continue
mt_q:                                   ; a quote: skip to the closing one
        mv    t2, t0                    ; t2 = the quote
        addi  s0, s0, 1                 ; inside
mt_ql:                                  ; loop: one quoted character
        lbu   t0, 0(s0)                 ; character
        beqz  t0, mt_loop               ; unterminated: the end
        beq   t0, t2, mt_next           ; the closing quote
        li    t1, '\\'                  ; an escape?
        bne   t0, t1, mt_qn             ; no
        lbu   t1, 1(s0)                 ; the escaped character
        beqz  t1, mt_qn                 ; none
        addi  s0, s0, 1                 ; skip the backslash
mt_qn:                                  ; next quoted character
        addi  s0, s0, 1                 ; ...
        j     mt_ql                     ; continue
mt_next:                                ; one character on
        addi  s0, s0, 1                 ; ...
        j     mt_loop                   ; continue
mt_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 24                ; pop
        ret                             ; done

; pa_line(): pre-scan A, for one line
pa_line:                                ; routine entry
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s2
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        ld    t0, v_psect(zero)         ; in .text?
        bnez  t0, pa_mn                 ; no: its labels are not code
        li    s0, 0                     ; s0 = label index
pa_lab:                                 ; loop: one label: enter it
        ld    t0, v_nlabs(zero)         ; all done?
        bgeu  s0, t0, pa_mn             ; yes
        mv    a0, s0                    ; the label
        call  lab_get                   ; a0 = name, a1 = length, a2 = hash
        li    t0, 255                   ; record length field limit
        bltu  t0, a1, pa_long           ; too long
        li    a3, SYMHASH               ; already entered?
        li    a4, SYMMASK               ; ...
        call  find                      ; ...
        bnez  a0, pa_next               ; yes (a redefinition: pass 1 says so)
        mv    a0, s0                    ; the label again
        call  lab_get                   ; ...
        li    a3, SYMHASH               ; into the symbols
        li    a4, SYMMASK               ; ...
        li    a5, 0                     ; no value yet
        li    a6, 255                   ; no section yet
        call  insert                    ; a0 = record
        li    t0, FL_TL                 ; a .text label
        sb    t0, R_FL(a0)              ; ...
pa_next:                                ; next label
        addi  s0, s0, 1                 ; ...
        j     pa_lab                    ; continue
pa_mn:                                  ; the mnemonic
        ld    t0, v_mk(zero)            ; a mnemonic?
        li    t1, 1                     ; ...
        bne   t0, t1, pa_ops            ; no
        ld    t0, v_mfmt(zero)          ; t0 = format
        li    t1, D_RES                 ; .resident
        bne   t0, t1, pa_m1             ; ...
        sd    zero, v_paged(zero)       ; no paged code
pa_m1:                                  ; .near?
        li    t1, D_NEAR                ; ...
        bne   t0, t1, pa_m2             ; ...
        sd    zero, v_far(zero)         ; no far data
pa_m2:                                  ; the program's first instruction?
        ld    t1, v_first(zero)         ; already found
        bnez  t1, pa_ops                ; ...
        ld    t1, v_psect(zero)         ; in .text
        bnez  t1, pa_ops                ; ...
        lbu   t1, MBUF(zero)            ; not a directive
        li    t2, '.'                   ; ...
        beq   t1, t2, pa_ops            ; ...
        ld    t1, v_line(zero)          ; this line
        sd    t1, v_first(zero)         ; ...
        li    t1, P_J                   ; is it `j`?
        bne   t0, t1, pa_ops            ; ...
        ld    t1, v_mfn(zero)           ; (not call)
        bnez  t1, pa_ops                ; ...
        li    t1, 1                     ; yes
        sd    t1, v_firstj(zero)        ; ...
pa_ops:                                 ; the operands
        ld    a0, v_mrest(zero)         ; split them (as sasm does, every line)
        call  split_ops                 ; a0 = count
        mv    s2, a0                    ; s2 = count
        li    s0, 0                     ; s0 = operand index
pa_c15:                                 ; loop: an operand c15?
        bgeu  s0, s2, pa_own            ; all seen
        slli  t0, s0, 3                 ; the operand
        ld    a0, OPS(t0)               ; ...
        li    a1, s_c15                 ; c15?
        call  streq                     ; ...
        beqz  a0, pa_c15n               ; no
        li    a0, v_own15               ; yes: note the line
        call  note_line                 ; ...
pa_c15n:                                ; next operand
        addi  s0, s0, 1                 ; ...
        j     pa_c15                    ; continue
pa_own:                                 ; code paging and cache instructions
        ld    s1, v_mfmt(zero)          ; s1 = format
        li    t0, F_XCALL               ; xcall
        beq   s1, t0, pa_code           ; ...
        li    t0, F_XRET                ; xret
        beq   s1, t0, pa_code           ; ...
        li    t0, F_XMAP                ; xmap
        beq   s1, t0, pa_code           ; ...
        li    t0, F_XUNMAP              ; xunmap
        beq   s1, t0, pa_code           ; ...
        li    t0, F_LINST               ; linst
        beq   s1, t0, pa_cache          ; ...
        li    t0, F_RRK                 ; ltag (F_RRK, opcode 0x3B)
        bne   s1, t0, pa_csrw           ; ...
        ld    t0, v_mop(zero)           ; ...
        li    t1, 0x3B                  ; ...
        beq   t0, t1, pa_cache          ; ...
        j     pa_ret                    ; (mv, seqz, tany)
pa_csrw:                                ; csrw xslot / ttag / tdata / tgeom, rs
        li    t0, F_CSRW                ; csrw?
        bne   s1, t0, pa_ret            ; no
        li    t0, 2                     ; two operands?
        bne   s2, t0, pa_ret            ; no
        ld    a0, OPS(zero)             ; xslot?
        li    a1, s_xslot               ; ...
        call  streq                     ; ...
        bnez  a0, pa_code               ; ...
        ld    a0, OPS(zero)             ; ttag?
        li    a1, s_ttag                ; ...
        call  streq                     ; ...
        bnez  a0, pa_cache              ; ...
        ld    a0, OPS(zero)             ; tdata?
        li    a1, s_tdata               ; ...
        call  streq                     ; ...
        bnez  a0, pa_cache              ; ...
        ld    a0, OPS(zero)             ; tgeom?
        li    a1, s_tgeom               ; ...
        call  streq                     ; ...
        beqz  a0, pa_ret                ; ...
pa_cache:                               ; the program manages a data cache
        li    a0, v_owncache            ; note the line
        call  note_line                 ; ...
        j     pa_ret                    ; done
pa_code:                                ; the program pages its own code
        li    a0, v_owncode             ; note the line
        call  note_line                 ; ...
pa_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        addi  sp, sp, 32                ; pop
        ret                             ; done
pa_long:                                ; error: label name too long
        li    a0, m_nlong               ; too long
        j     fail                      ; report

; pb_line(): pre-scan B, for one line
pb_line:                                ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        ld    t0, v_mk(zero)            ; anything?
        beqz  t0, pb_ret                ; no
        li    t1, 2                     ; `name = expr`?
        bne   t0, t1, pb_op             ; no
        ld    a0, v_mrest(zero)         ; its expression
        call  mark_taken                ; takes addresses
        j     pb_ret                    ; done
pb_op:                                  ; a mnemonic
        ld    a0, v_mrest(zero)         ; its operands
        call  split_ops                 ; a0 = count
        mv    s0, a0                    ; s0 = count
        ld    s1, v_mfmt(zero)          ; s1 = format
        li    t0, P_J                   ; j or call?
        bne   s1, t0, pb_jal            ; no
        ld    t0, v_mfn(zero)           ; j: a target, not an address
        beqz  t0, pb_ret                ; ...
        li    t0, 1                     ; call with one operand
        bne   s0, t0, pb_all            ; (otherwise its operands are expressions)
        ld    a0, OPS(zero)             ; calls a function
        call  set_func                  ; ...
        j     pb_ret                    ; done
pb_jal:                                 ; jal rd, target?
        li    t0, F_JAL                 ; ...
        bne   s1, t0, pb_br             ; no
        li    t0, 2                     ; two operands
        bne   s0, t0, pb_all            ; (otherwise expressions)
        ld    a0, OPS(zero)             ; rd a register
        call  parse_xreg                ; ...
        bltz  a0, pb_all                ; (otherwise expressions)
        li    t0, 1                     ; jal ra: a call
        bne   a0, t0, pb_ret            ; (any other: a target)
        ld    a0, OPS+8(zero)           ; calls a function
        call  set_func                  ; ...
        j     pb_ret                    ; done
pb_br:                                  ; a branch: its target is not an address
        li    t0, F_B                   ; ...
        beq   s1, t0, pb_ret            ; ...
        li    t0, P_BZ                  ; ...
        beq   s1, t0, pb_ret            ; ...
        li    t0, P_B2                  ; ...
        beq   s1, t0, pb_ret            ; ...
        li    t0, D_EQU                 ; .equ name, value
        bne   s1, t0, pb_dir            ; no
        li    t0, 2                     ; two operands
        bne   s0, t0, pb_ret            ; ...
        ld    a0, OPS+8(zero)           ; the value takes addresses
        call  mark_taken                ; ...
        j     pb_ret                    ; done
pb_dir:                                 ; other directives name no code
        lbu   t0, MBUF(zero)            ; a directive?
        li    t1, '.'                   ; ...
        bne   t0, t1, pb_all            ; no
        li    t0, D_DATA                ; except .byte .half .word .dword
        bne   s1, t0, pb_ret            ; ...
pb_all:                                 ; every operand takes addresses
        li    s1, 0                     ; s1 = operand index
pb_loop:                                ; loop: one operand
        bgeu  s1, s0, pb_ret            ; all done
        slli  t0, s1, 3                 ; the operand
        ld    a0, OPS(t0)               ; ...
        call  mark_taken                ; ...
        addi  s1, s1, 1                 ; next
        j     pb_loop                   ; continue
pb_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 24                ; pop
        ret                             ; done

; pc_line(): pre-scan C, for one line
pc_line:                                ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        ld    t0, v_ltext(zero)         ; .text code?
        beqz  t0, pcl_ret                ; no
        call  reg_step                  ; a0 = its region
        mv    s1, a0                    ; s1 = region
        li    s0, 0                     ; s0 = label index
pcl_lab:                                ; loop: one label: in this region
        ld    t0, v_nlabs(zero)         ; all done?
        bgeu  s0, t0, pcl_ret            ; yes
        mv    a0, s0                    ; its record
        call  lab_rec                   ; ...
        beqz  a0, pcl_next               ; none
        sh    s1, R_REG(a0)             ; its region
pcl_next:                               ; next label
        addi  s0, s0, 1                 ; ...
        j     pcl_lab                    ; continue
pcl_ret:                                ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 24                ; pop
        ret                             ; done

; pd_line(): pre-scan D, for one line
pd_line:                                ; routine entry
        addi  sp, sp, -40               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s3
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        sd    s3, 32(sp)                ; ...
        ld    t0, v_ltext(zero)         ; .text code?
        beqz  t0, pd_ret                ; no
        call  reg_step                  ; a0 = its region
        mv    s0, a0                    ; s0 = region
        li    s1, 0                     ; s1 = label index
pd_lab:                                 ; loop: a taken label pins the region
        ld    t0, v_nlabs(zero)         ; all done?
        bgeu  s1, t0, pd_fall           ; yes
        mv    a0, s1                    ; its record
        call  lab_rec                   ; ...
        beqz  a0, pd_ln                 ; none
        lbu   t0, R_FL(a0)              ; address taken?
        andi  t0, t0, FL_TAKEN          ; ...
        beqz  t0, pd_ln                 ; no
        mv    a0, s0                    ; pinned
        call  reg_rec                   ; ...
        li    t0, 1                     ; ...
        sb    t0, RG_PIN(a0)            ; ...
pd_ln:                                  ; next label
        addi  s1, s1, 1                 ; ...
        j     pd_lab                    ; continue
pd_fall:                                ; a new region: fallen into?
        ld    t1, v_lastreg(zero)       ; the last line's region
        beq   t1, s0, pd_kind           ; the same
        bltz  t1, pd_new                ; (none)
        ld    t2, v_lastterm(zero)      ; its last instruction ended it?
        bnez  t2, pd_new                ; yes
        mv    a0, t1                    ; no: it falls through
        mv    a1, s0                    ; into this one
        call  join                      ; ...
pd_new:                                 ; this region
        sd    s0, v_lastreg(zero)       ; ...
        sd    zero, v_lastterm(zero)    ; ...
pd_kind:                                ; what the line is
        ld    t0, v_mk(zero)            ; a mnemonic?
        li    t1, 1                     ; ...
        bne   t0, t1, pd_ret            ; no: neither code nor an end
        ld    s1, v_mfmt(zero)          ; s1 = format
        li    t0, D_EQU                 ; .equ .set
        beq   s1, t0, pd_ret            ; ...
        li    t0, D_NOP                 ; .global .globl
        beq   s1, t0, pd_ret            ; ...
        li    t0, D_RES                 ; .resident
        beq   s1, t0, pd_ret            ; ...
        li    t0, D_NEAR                ; .near
        beq   s1, t0, pd_ret            ; ...
        li    t0, D_PIN                 ; .pinned
        bne   s1, t0, pd_ins            ; ...
        mv    a0, s0                    ; pins the region
        call  reg_rec                   ; ...
        li    t0, 1                     ; ...
        sb    t0, RG_PIN(a0)            ; ...
        j     pd_ret                    ; done
pd_ins:                                 ; an instruction (or another directive)
        ld    a0, v_mrest(zero)         ; its operands
        call  split_ops                 ; a0 = count
        mv    s2, a0                    ; s2 = count
        li    s3, 0                     ; s3 = its target, 0 if none
        sd    zero, v_lastterm(zero)    ; does not end the region (yet)
        li    t0, F_B                   ; a branch?
        beq   s1, t0, pd_br             ; ...
        li    t0, P_BZ                  ; ...
        beq   s1, t0, pd_br             ; ...
        li    t0, P_B2                  ; ...
        bne   s1, t0, pd_j              ; no
pd_br:                                  ; a branch: its last operand
        li    t0, 2                     ; (with two operands at least)
        bltu  s2, t0, pd_tgt            ; ...
        addi  t0, s2, -1                ; ...
        slli  t0, t0, 3                 ; ...
        ld    s3, OPS(t0)               ; is its target
        j     pd_tgt                    ; ...
pd_j:                                   ; j target / call
        li    t0, P_J                   ; ...
        bne   s1, t0, pd_halt           ; no
        ld    t0, v_mfn(zero)           ; call: ends the region
        bnez  t0, pd_term               ; (a call that ends it does not return)
        li    t0, 1                     ; j with one operand
        bne   s2, t0, pd_tgt            ; ...
        ld    s3, OPS(zero)             ; its target
        j     pd_term                   ; and the end
pd_halt:                                ; halt ends it
        li    t0, F_SYS                 ; ...
        bne   s1, t0, pd_jal            ; ...
        ld    t0, v_mop(zero)           ; (the system group,
        li    t1, 0x3A                  ; function 0)
        bne   t0, t1, pd_tgt            ; ...
        ld    t0, v_mfn(zero)           ; ...
        bnez  t0, pd_tgt                ; ...
        j     pd_term                   ; ...
pd_jal:                                 ; jal rd, target
        li    t0, F_JAL                 ; ...
        bne   s1, t0, pd_ret2           ; ...
        li    t0, 2                     ; two operands
        bne   s2, t0, pd_tgt            ; ...
        ld    a0, OPS(zero)             ; rd a register
        call  parse_xreg                ; ...
        bltz  a0, pd_tgt                ; ...
        li    t0, 1                     ; jal ra: a call, ends it
        beq   a0, t0, pd_term           ; ...
        ld    s3, OPS+8(zero)           ; otherwise a target
        bnez  a0, pd_tgt                ; that only jal zero ends on
        j     pd_term                   ; ...
pd_ret2:                                ; ret, jr, xret end it
        li    t0, P_RET                 ; ...
        beq   s1, t0, pd_term           ; ...
        li    t0, P_JR                  ; ...
        beq   s1, t0, pd_term           ; ...
        li    t0, F_XRET                ; ...
        beq   s1, t0, pd_term           ; ...
        li    t0, P_JALR                ; and jalr zero|ra, rs, imm
        bne   s1, t0, pd_tgt            ; ...
        li    t0, 3                     ; ...
        bne   s2, t0, pd_tgt            ; ...
        ld    a0, OPS(zero)             ; (or rd not a register)
        call  parse_xreg                ; ...
        li    t0, 2                     ; ...
        bge   a0, t0, pd_tgt            ; ...
pd_term:                                ; the line ends the region
        li    t0, 1                     ; ...
        sd    t0, v_lastterm(zero)      ; ...
pd_tgt:                                 ; a target in another region joins it
        beqz  s3, pd_ret                ; no target
        mv    a0, s3                    ; a .text label?
        call  lookup_tl                 ; ...
        beqz  a0, pd_ret                ; no
        lhu   t0, R_REG(a0)             ; its region
        li    t1, 0xffff                ; none
        beq   t0, t1, pd_ret            ; ...
        beq   t0, s0, pd_ret            ; this one
        lbu   t1, R_FL(a0)              ; a function: a (conditional) tail call,
        andi  t1, t1, FL_FUNC           ; which becomes a far one
        bnez  t1, pd_ret                ; ...
        mv    a0, s0                    ; otherwise both regions, and those
        mv    a1, t0                    ; between, are one group
        call  join                      ; ...
pd_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        addi  sp, sp, 40                ; pop
        ret                             ; done

; ---- paged code and far data: the passes --------------------------------------------------
; map_line(s0 = the line, comment stripped and trimmed): with paged code, a
; .text line goes where its group is: the group's place in .text (pinned) or
; in the units (paged; before the first layout every group is in .text, at
; 0, as in sasm). dl_ret moves the section back.
map_line:                               ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        mv    a0, s0                    ; labels and mnemonic
        call  ps_parse                  ; ...
        ld    t0, v_mfmt(zero)          ; a section directive is not code
        li    t1, D_SECT                ; ...
        beq   t0, t1, ml_ret            ; ...
        call  reg_step                  ; a0 = the line's region
        sd    a0, v_lreg(zero)          ; ...
        ld    t1, v_regs(zero)          ; its record
        slli  t0, a0, 4                 ; ...
        add   t0, t0, t1                ; ...
        lhu   t2, RG_GRP(t0)            ; its group
        sd    t2, v_lgrp(zero)          ; ...
        slli  t3, t2, 4                 ; the group's record
        add   t3, t3, t1                ; ...
        sd    t3, v_lgrec(zero)         ; ...
        lbu   t4, RG_GPIN(t3)           ; pinned?
        seqz  t5, t4                    ; paged code if not
        sd    t5, v_lpaged(zero)        ; ...
        li    t6, 0                     ; t6 = the section: .text
        ld    a1, v_laid(zero)          ; until the first layout
        beqz  a1, ml_sect               ; ...
        bnez  t4, ml_sect               ; and for pinned groups
        li    t6, S_UNITS               ; the units for paged ones
ml_sect:                                ; switch to it
        sd    t6, v_cs(zero)            ; ...
        li    a1, SREC                  ; its record
        mul   a1, t6, a1                ; ...
        li    s11, sects                ; ...
        add   s11, s11, a1              ; ...
        ld    a2, S_LOC(s11)            ; its own location, kept
        sd    a2, v_uloc(zero)          ; ...
        lwu   a2, RG_LOC(t3)            ; and the group's
        sd    a2, S_LOC(s11)            ; ...
ml_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; layout_groups() -> a0 = 1 if a group or the end of the pinned code moved.
; sasm's layout: pinned groups in source order from the text origin, the
; stub after them (v_pend); paged groups packed into units in source order
; from offset UNIT (next fit); a group larger than a unit stays resident.
layout_groups:                          ; routine entry (leaf)
        ld    a5, v_regs(zero)          ; a5 = the table
        ld    a6, v_nreg(zero)          ; a6 = regions
        li    a7, 0                     ; a7 = moved?
        li    t0, 0                     ; t0 = region
lg_size:                                ; loop: each group's size
        bgeu  t0, a6, lg_pins           ; all done
        slli  t1, t0, 4                 ; its record
        add   t1, t1, a5                ; ...
        lhu   t2, RG_GRP(t1)            ; a group's first region?
        bne   t2, t0, lg_sn             ; no
        lwu   t3, RG_BASE(t1)           ; size = where it ended - where it began
        lwu   t4, RG_LOC(t1)            ; ...
        sub   t4, t4, t3                ; ...
        sw    t4, RG_LOC(t1)            ; (kept in RG_LOC)
        lbu   t5, RG_GPIN(t1)           ; pinned already?
        bnez  t5, lg_sn                 ; yes
        li    t6, UNIT                  ; larger than a unit?
        bgeu  t6, t4, lg_sn             ; no
        li    t5, 2                     ; yes: stays resident
        sb    t5, RG_GPIN(t1)           ; ...
lg_sn:                                  ; next region
        addi  t0, t0, 1                 ; ...
        j     lg_size                   ; continue
lg_pins:                                ; pinned groups from the text origin
        ld    a0, v_org(zero)           ; a0 = where the next one goes
        li    t0, 0                     ; t0 = region
lg_p:                                   ; loop: one region
        bgeu  t0, a6, lg_pend           ; all done
        slli  t1, t0, 4                 ; its record
        add   t1, t1, a5                ; ...
        lhu   t2, RG_GRP(t1)            ; a group's first region?
        bne   t2, t0, lg_pn             ; no
        lbu   t5, RG_GPIN(t1)           ; pinned?
        beqz  t5, lg_pn                 ; no
        lwu   t3, RG_BASE(t1)           ; moved?
        beq   t3, a0, lg_p1             ; no
        li    a7, 1                     ; yes
lg_p1:                                  ; place it
        sw    a0, RG_BASE(t1)           ; ...
        lwu   t4, RG_LOC(t1)            ; its size
        sw    a0, RG_LOC(t1)            ; the next pass starts it there
        add   a0, a0, t4                ; the next one after it
lg_pn:                                  ; next region
        addi  t0, t0, 1                 ; ...
        j     lg_p                      ; continue
lg_pend:                                ; the end of the pinned code
        ld    t3, v_pend(zero)          ; moved?
        beq   t3, a0, lg_pe1            ; no
        li    a7, 1                     ; yes
lg_pe1:                                 ; (the stub goes there)
        sd    a0, v_pend(zero)          ; ...
        li    a1, UNIT                  ; a1 = the current unit's offset
        li    a2, 0                     ; a2 = bytes used in it
        li    t0, 0                     ; t0 = region
lg_u:                                   ; loop: one region
        bgeu  t0, a6, lg_done           ; all done
        slli  t1, t0, 4                 ; its record
        add   t1, t1, a5                ; ...
        lhu   t2, RG_GRP(t1)            ; a group's first region?
        bne   t2, t0, lg_un             ; no
        lbu   t5, RG_GPIN(t1)           ; paged?
        bnez  t5, lg_un                 ; no
        lwu   t4, RG_LOC(t1)            ; its size
        add   t5, a2, t4                ; fits the unit?
        li    t6, UNIT                  ; ...
        bgeu  t6, t5, lg_fit            ; yes
        add   a1, a1, t6                ; no: the next unit
        li    a2, 0                     ; empty
lg_fit:                                 ; place it
        add   t5, a1, a2                ; its offset
        lwu   t3, RG_BASE(t1)           ; moved?
        beq   t3, t5, lg_u1             ; no
        li    a7, 1                     ; yes
lg_u1:                                  ; ...
        sw    t5, RG_BASE(t1)           ; ...
        add   a2, a2, t4                ; used
        sw    t5, RG_LOC(t1)            ; the next pass starts it there
lg_un:                                  ; next region
        addi  t0, t0, 1                 ; ...
        j     lg_u                      ; continue
lg_done:                                ; all placed
        li    t0, 1                     ; groups are in their sections now
        sd    t0, v_laid(zero)          ; ...
        mv    a0, a7                    ; moved?
        ret                             ; done

; ptransfer(a0 = rd: 0 or 1, a1 = target, a2 = 1 for a jump) -> a0 = 1 if
; the call or jump was rewritten (sasm's paged_transfer):
;   to a paged function                  lui t6, ori t6, xcall rd, c15, t6
;   from paged code to pinned code       (call: a far link in ra) ori t6, jalr zero, t6
; A jump to a label that is not a function, or into the same group, and a
; transfer between pinned groups stay as written.
ptransfer:                              ; routine entry
        addi  sp, sp, -40               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s3
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        sd    s3, 32(sp)                ; ...
        mv    s0, a0                    ; s0 = rd
        mv    s1, a1                    ; s1 = target
        mv    s3, a2                    ; s3 = a jump?
        li    a0, 0                     ; (as written)
        ld    t0, v_lreg(zero)          ; .text code with paging?
        bltz  t0, pt_ret                ; no
        mv    a0, s1                    ; a .text label?
        call  lookup_tl                 ; ...
        beqz  a0, pt_ret                ; no
        mv    s2, a0                    ; s2 = its record
        call  tl_group                  ; a0 = its group, a1 = pinned there?
        beqz  s3, pt_any                ; a call: whatever the target
        lbu   t0, R_FL(s2)              ; a jump to a label that is not a function
        andi  t0, t0, FL_FUNC           ; ...
        beqz  t0, pt_no                 ; is a branch
        ld    t0, v_lgrp(zero)          ; and so is a jump into the same group
        beq   a0, t0, pt_no             ; ...
pt_any:                                 ; where the target is
        mv    s2, a1                    ; s2 = pinned there?
        ld    t0, v_lpaged(zero)        ; from pinned code to pinned code:
        bnez  t0, pt_go                 ; as written
        bnez  s2, pt_no                 ; ...
pt_go:                                  ; rewrite it
        mv    a0, s1                    ; the target's address
        call  eval                      ; ...
        mv    s1, a0                    ; s1 = it
        bnez  s2, pt_pin                ; to pinned code
        mv    a0, s0                    ; to a paged function: a far call
        mv    a1, s1                    ; ...
        call  farcall                   ; ...
        j     pt_yes                    ; done
pt_pin:                                 ; from paged code to pinned code
        beqz  s0, pt_j                  ; a call:
        ld    a0, S_LOC(s11)            ; ra = a far link to the instruction after
        addi  a0, a0, 4 * 9             ; (7 for the link, ori, jalr)
        call  flink                     ; ...
pt_j:                                   ; then the jump
        mv    a0, s1                    ; ori t6, zero, target; jalr zero, t6, 0
        call  pin_jump                  ; ...
pt_yes:                                 ; rewritten
        li    a0, 1                     ; ...
        j     pt_ret                    ; ...
pt_no:                                  ; as written
        li    a0, 0                     ; ...
pt_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        addi  sp, sp, 40                ; pop
        ret                             ; done

; pbranch(a0 = opcode, a1, a2 = registers, a3 = target) -> a0 = 1 if the
; branch was rewritten (sasm's paged_branch): one to a function in another
; group, from or to paged code, becomes the opposite branch over a jump
; there, four words either way:
;   b!cond a1, a2, +4; lui t6; ori t6; xcall zero, c15, t6     (to paged code)
;   b!cond a1, a2, +4; ori t6; jalr zero, t6, 0; nop           (to pinned code)
pbranch:                                ; routine entry
        addi  sp, sp, -48               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0..s4
        sd    s1, 16(sp)                ; ...
        sd    s2, 24(sp)                ; ...
        sd    s3, 32(sp)                ; ...
        sd    s4, 40(sp)                ; ...
        mv    s0, a0                    ; s0 = opcode
        mv    s1, a1                    ; s1, s2 = registers
        mv    s2, a2                    ; ...
        mv    s3, a3                    ; s3 = target
        li    a0, 0                     ; (as written)
        ld    t0, v_lreg(zero)          ; .text code with paging?
        bltz  t0, pbr_ret               ; no
        mv    a0, s3                    ; a .text label?
        call  lookup_tl                 ; ...
        beqz  a0, pbr_ret               ; no
        lbu   t0, R_FL(a0)              ; a function's?
        andi  t0, t0, FL_FUNC           ; ...
        beqz  t0, pbr_no                ; no: an ordinary branch
        call  tl_group                  ; a0 = its group, a1 = pinned
        ld    t0, v_lgrp(zero)          ; in this group?
        beq   a0, t0, pbr_no            ; yes: an ordinary branch
        mv    s4, a1                    ; s4 = pinned there?
        ld    t0, v_lpaged(zero)        ; between pinned groups:
        bnez  t0, pbr_go                ; an ordinary branch
        bnez  s4, pbr_no                ; ...
pbr_go:                                 ; rewrite it
        xori  a0, s0, 1                 ; the opposite condition (beq/bne,
        mv    a1, s1                    ; blt/bge, bltu/bgeu are pairs)
        mv    a2, s2                    ; ...
        li    a3, 4                     ; over the jump
        call  enc_i                     ; ...
        mv    a0, s3                    ; the target's address
        call  eval                      ; ...
        mv    a1, a0                    ; ...
        bnez  s4, pbr_pin               ; to pinned code
        li    a0, 0                     ; to paged code: a far jump
        call  farcall                   ; ...
        j     pbr_yes                   ; done
pbr_pin:                                ; to pinned code
        mv    a0, a1                    ; ori t6, zero, target; jalr zero, t6, 0
        call  pin_jump                  ; ...
        li    a0, W_NOP                 ; nop: four words either way
        call  emit_insn                 ; ...
pbr_yes:                                ; rewritten
        li    a0, 1                     ; ...
        j     pbr_ret                   ; ...
pbr_no:                                 ; as written
        li    a0, 0                     ; ...
pbr_ret:                                ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        ld    s4, 40(sp)                ; ...
        addi  sp, sp, 48                ; pop
        ret                             ; done

; farcall(a0 = rd: ra for a call, zero for a jump, a1 = image offset):
;   lui t6, ori t6, xcall rd, c15, t6
farcall:                                ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        mv    s0, a0                    ; s0 = rd
        li    a0, RT6                   ; t6 = the offset
        call  emit_luo                  ; ...
        slli  a0, s0, 21                ; xcall rd, c15, t6
        li    t0, W_XC6                 ; ...
        or    a0, a0, t0                ; ...
        call  emit_insn                 ; ...
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

; pin_jump(a0 = I-LS address): ori t6, zero, address; jalr zero, t6, 0
pin_jump:                               ; routine entry
        addi  sp, sp, -8                ; frame
        sd    ra, 0(sp)                 ; save the return address
        li    t0, 0xffff                ; ori t6, zero, address
        and   a0, a0, t0                ; ...
        li    t0, W_ORI6                ; ...
        or    a0, a0, t0                ; ...
        call  emit_insn                 ; ...
        li    a0, W_JR6                 ; jalr zero, t6, 0
        call  emit_insn                 ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 8                 ; pop
        ret                             ; done

; emit_luo(a0 = rd, a1 = value): lui rd, value >> 16; ori rd, rd, value & 0xffff
emit_luo:                               ; routine entry
        addi  sp, sp, -24               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; rd
        sd    a1, 16(sp)                ; value
        mv    a1, a0                    ; lui rd, value >> 16
        li    a0, OP_LUI                ; ...
        li    a2, 0                     ; ...
        ld    a3, 16(sp)                ; ...
        srli  a3, a3, 16                ; (masked)
        call  enc_i                     ; ...
        li    a0, OP_ORI                ; ori rd, rd, value & 0xffff
        ld    a1, 8(sp)                 ; ...
        mv    a2, a1                    ; ...
        ld    a3, 16(sp)                ; (masked)
        call  enc_i                     ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 24                ; pop
        ret                             ; done

; flink(a0 = image offset of the return point): ra = its far link, what
; xret resolves to come back there: cbase ra, c15; t6 = offset;
; add ra, ra, t6; t6 = 1 << 63; or ra, ra, t6
flink:                                  ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a0, 8(sp)                 ; the offset
        li    a0, W_CBASE               ; cbase ra, c15 (the image)
        call  emit_insn                 ; ...
        li    a0, RT6                   ; t6 = the offset
        ld    a1, 8(sp)                 ; ...
        call  emit_luo                  ; ...
        li    a0, W_ADDRA               ; add ra, ra, t6
        call  emit_insn                 ; ...
        li    a0, W_T6ONE               ; addi t6, zero, 1
        call  emit_insn                 ; ...
        li    a0, W_T6SH                ; slli t6, t6, 63
        call  emit_insn                 ; ...
        li    a0, W_ORRA                ; or ra, ra, t6
        call  emit_insn                 ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; emit_stub(): __pinit, at the current location of .text: what the entry's
; `j L` now goes through. It sets xslot (paged code) and ttag, tdata, tgeom
; (far data), then goes on to L: a far jump if L is paged, else a jal;
; three words for the jump either way.
emit_stub:                              ; routine entry
        addi  sp, sp, -32               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0, s1
        sd    s1, 16(sp)                ; ...
        li    a0, s_pinit               ; __pinit = here
        call  strhash                   ; a1 = length, a2 = hash
        ld    a3, S_LOC(s11)            ; ...
        li    a4, 0                     ; in .text
        call  sym_define                ; ...
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, est_far               ; no
        li    a0, W_XSL1                ; addi t0, zero, ULG
        call  emit_insn                 ; ...
        li    a0, W_CSRW0 | CSR_XSLOT   ; csrw xslot, t0
        call  emit_insn                 ; ...
est_far:                                ; far data?
        ld    t0, v_far(zero)           ; ...
        beqz  t0, est_jump              ; no
        li    a0, s_fctags              ; ttag = __fc_tags
        call  eval                      ; ...
        li    a1, CSR_TTAG              ; ...
        call  stub_csr                  ; ...
        li    a0, s_fclines             ; tdata = __fc_lines
        call  eval                      ; ...
        li    a1, CSR_TDATA             ; ...
        call  stub_csr                  ; ...
        li    a0, GEOM                  ; tgeom: the cache's shape, FA
        li    a1, CSR_TGEOM             ; ...
        call  stub_csr                  ; ...
est_jump:                               ; and on to the entry's target
        ld    s1, S_LOC(s11)            ; s1 = the end of the stub
        addi  s1, s1, 12                ; (three words for the jump)
        li    s0, 0                     ; s0 = the target (0 if there is none)
        ld    t0, v_entry(zero)         ; is there one?
        beqz  t0, est_jal               ; no
        li    a0, ENTBUF                ; its address
        call  eval                      ; ...
        mv    s0, a0                    ; ...
        ld    t0, v_esect(zero)         ; its section
        sd    t0, 24(sp)                ; ...
        ld    t0, v_paged(zero)         ; paged code?
        beqz  t0, est_chk               ; no
        li    a0, ENTBUF                ; a .text label
        call  lookup_tl                 ; ...
        beqz  a0, est_chk               ; no
        call  tl_group                  ; a1 = pinned?
        bnez  a1, est_chk               ; yes
        li    a0, 0                     ; paged: a far jump
        mv    a1, s0                    ; ...
        call  farcall                   ; ...
        j     est_pad                   ; done
est_chk:                                ; a jal: the target must be in .text
        li    t0, 2                     ; (checked in pass 2)
        bne   tp, t0, est_jal           ; ...
        ld    t0, 24(sp)                ; ...
        bnez  t0, est_bad               ; not .text (a constant, or data)
est_jal:                                ; jal zero, target
        ld    t0, S_LOC(s11)            ; word offset
        sub   t0, s0, t0                ; ...
        srai  t0, t0, 2                 ; ...
        li    t1, 0x1fffff              ; 21 bits of it
        and   a0, t0, t1                ; ...
        li    t1, OP_JAL << 26          ; jal zero
        or    a0, a0, t1                ; ...
        call  emit_insn                 ; ...
est_pad:                                ; loop: nops up to three words
        ld    t0, S_LOC(s11)            ; ...
        bgeu  t0, s1, est_ret           ; there
        li    a0, W_NOP                 ; nop
        call  emit_insn                 ; ...
        j     est_pad                   ; continue
est_ret:                                ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        addi  sp, sp, 32                ; pop
        ret                             ; done
est_bad:                                ; error: the entry jumps to no code
        li    a0, m_ent2                ; not code
        j     fail_noline               ; report

; stub_csr(a0 = value, a1 = CSR): lui t0, ori t0, csrw CSR, t0
stub_csr:                               ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    a1, 8(sp)                 ; the CSR
        mv    a1, a0                    ; t0 = the value
        li    a0, RT0                   ; ...
        call  emit_luo                  ; ...
        ld    a0, 8(sp)                 ; csrw CSR, t0
        li    t0, W_CSRW0               ; ...
        or    a0, a0, t0                ; ...
        call  emit_insn                 ; ...
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; done

; emit_cache(): the far data cache at the current location of .data,
; 64-byte aligned: __fc_lines (CLINES bytes), then __fc_tags (CTAGS bytes)
emit_cache:                             ; routine entry
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
ec_al:                                  ; loop: align to 64
        ld    t0, S_LOC(s11)            ; ...
        andi  t0, t0, 63                ; ...
        beqz  t0, ec_lines              ; aligned
        li    a0, 0                     ; a zero byte
        call  emit_byte                 ; ...
        j     ec_al                     ; continue
ec_lines:                               ; the lines
        li    a0, s_fclines             ; __fc_lines = here
        call  strhash                   ; ...
        ld    a3, S_LOC(s11)            ; ...
        li    a4, 1                     ; in .data
        call  sym_define                ; ...
        li    s0, CLINES                ; s0 = bytes left
ec_z1:                                  ; loop: one zero byte
        beqz  s0, ec_tags               ; all done
        li    a0, 0                     ; ...
        call  emit_byte                 ; ...
        addi  s0, s0, -1                ; ...
        j     ec_z1                     ; continue
ec_tags:                                ; the tags
        li    a0, s_fctags              ; __fc_tags = here
        call  strhash                   ; ...
        ld    a3, S_LOC(s11)            ; ...
        li    a4, 1                     ; in .data
        call  sym_define                ; ...
        li    s0, CTAGS                 ; s0 = bytes left
ec_z2:                                  ; loop: one zero byte
        beqz  s0, ec_ret                ; all done
        li    a0, 0                     ; ...
        call  emit_byte                 ; ...
        addi  s0, s0, -1                ; ...
        j     ec_z2                     ; continue
ec_ret:                                 ; done
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

; ---- image layout and output ------------------------------------------------------------------
; layout(): after pass 1, place each non-empty section in the image and
; prepare its output window. The units come first, their base forced to 24
; (the file offset of their first byte): an offset in them is one in the file.
layout:                                 ; routine entry (leaf)
        li    t0, 8                     ; t0 = file offset: after "STX2" and the count
        li    t1, 0                     ; t1 = sections in the image
        li    t4, 0                     ; t4 = position in sorder
lo_loop:                                ; loop: one section record
        lbu   t2, sorder(t4)            ; the section
        li    t3, SREC                  ; its record
        mul   t2, t2, t3                ; ...
        li    t3, sects                 ; ...
        add   t2, t2, t3                ; t2 = the record
        ld    t3, S_WBUF(t2)            ; t3 = its window
        ld    t5, S_SIZE(t2)            ; size
        beqz  t5, lo_next               ; empty: not in the image
        addi  t1, t1, 1                 ; one more section
        ld    t6, S_LO(t2)              ; lowest address
        srli  t6, t6, 3                 ; rounded down
        slli  t6, t6, 3                 ; to 8: the base
        ld    a0, S_KIND(t2)            ; the units?
        li    a1, SK_UNITS              ; ...
        bne   a0, a1, lo_base           ; no
        li    t6, 24                    ; yes: from file offset 24 (zeros up to the first unit)
lo_base:                                ; the base is known
        sd    t6, S_BASE(t2)            ; remember
        sd    t0, S_HDR(t2)             ; its header goes here
        ld    a0, v_outbase(zero)       ; image offset in the arena
        add   a0, a0, t0                ; header position
        addi  a0, a0, 16                ; bytes follow the header
        sub   a0, a0, t6                ; arena offset of address 0
        sd    a0, S_FADJ(t2)            ; ...
        sd    t6, S_WBASE(t2)           ; first window starts at the base
        li    a1, 0                     ; clear the window (covers padding below lo)
lo_clr:                                 ; loop: clear 8 window bytes
        add   a2, t3, a1                ; address
        sd    zero, 0(a2)               ; clear 8 bytes
        addi  a1, a1, 8                 ; next
        li    a2, WINSZ                 ; window size
        bltu  a1, a2, lo_clr            ; whole window
        addi  t5, t5, 7                 ; end rounded up
        srli  t5, t5, 3                 ; to 8
        slli  t5, t5, 3                 ; ...
        sub   t5, t5, t6                ; padded section length
        addi  t0, t0, 16                ; header
        add   t0, t0, t5                ; and bytes
lo_next:                                ; next section
        addi  t4, t4, 1                 ; next in sorder
        li    t2, NSECT                 ; all five?
        bltu  t4, t2, lo_loop           ; not yet
        sd    t0, v_total(zero)         ; image length
        sd    t1, v_count(zero)         ; section count
        ld    t2, v_outmax(zero)        ; limit
        bltu  t2, t0, lo_big            ; too large
        ret                             ; done
lo_big:                                 ; error: image too large
        li    a0, m_outbig              ; output too large
        sd    zero, v_line(zero)        ; not about a line
        j     fail                      ; report

; finish(): after pass 2, flush the last windows and write the headers
finish:                                 ; routine entry (leaf)
        li    t2, sects                 ; t2 = section record
        li    t4, NSECT                 ; t4 = records left
        li    t6, HDRBUF                ; t6 = header staging buffer
fi_loop:                                ; loop: one section record
        ld    t5, S_SIZE(t2)            ; size
        beqz  t5, fi_next               ; not in the image
        addi  t5, t5, 7                 ; end rounded up
        srli  t5, t5, 3                 ; to 8
        slli  t5, t5, 3                 ; ...
        ld    t1, S_WBASE(t2)           ; last window start
        ld    t3, S_WBUF(t2)            ; its buffer
        ld    a0, S_SIZE(t2)            ; zero the padding after the end
fi_pad:                                 ; loop: clear one padding byte
        bgeu  a0, t5, fi_flush          ; up to the rounded end
        sub   a1, a0, t1                ; position in the window
        add   a1, t3, a1                ; address
        sb    zero, 0(a1)               ; clear
        addi  a0, a0, 1                 ; next
        j     fi_pad                    ; continue
fi_flush:                               ; write the last window and the header
        sub   a1, t5, t1                ; bytes in the last window
        ld    a2, S_FADJ(t2)            ; arena offset of address 0
        add   a2, a2, t1                ; of the window
        tput  tg0, t3, c0, a2, a1       ; write it
        ld    a0, S_KIND(t2)            ; header: kind
        sw    a0, 0(t6)                 ; (waits until the previous header is out)
        ld    a0, S_BASE(t2)            ; base
        sw    a0, 4(t6)                 ; ...
        sub   a0, t5, a0                ; padded length
        sw    a0, 8(t6)                 ; ...
        sw    zero, 12(t6)              ; reserved
        ld    a2, v_outbase(zero)       ; image offset
        ld    a0, S_HDR(t2)             ; header position
        add   a2, a2, a0                ; arena offset
        li    a1, 16                    ; 16 bytes
        tput  tg0, t6, c0, a2, a1       ; write the header
fi_next:                                ; next section
        addi  t2, t2, SREC              ; next record
        addi  t4, t4, -1                ; one fewer
        bnez  t4, fi_loop               ; all five
        li    a0, 0x32585453            ; "STX2" as a little-endian word
        sw    a0, 0(t6)                 ; magic (waits for the last header)
        ld    a0, v_count(zero)         ; section count
        sw    a0, 4(t6)                 ; ...
        ld    a2, v_outbase(zero)       ; start of the image
        li    a1, 8                     ; 8 bytes
        tput  tg0, t6, c0, a2, a1       ; write
        ret                             ; done

; copy_out(): bare metal: image -> console, through the D-LS
copy_out:                               ; routine entry (leaf)
        li    t0, 0                     ; t0 = image offset
        ld    t1, v_total(zero)         ; t1 = image length
        ld    t2, v_outbase(zero)       ; t2 = image base in system memory
        li    t3, INBUF                 ; t3 = bounce buffer
co_loop:                                ; loop: one buffer
        bgeu  t0, t1, co_ret            ; all sent
        sub   t4, t1, t0                ; bytes left
        li    t5, INSZ                  ; at most a buffer
        bltu  t4, t5, co_n              ; fewer left
        mv    t4, t5                    ; a full buffer
co_n:                                   ; size decided
        add   t5, t2, t0                ; source offset
        tget  tg1, t3, c0, t5, t4       ; system memory -> D-LS
        tput  tg2, t3, c2, zero, t4     ; D-LS -> console (in order after the tget)
        add   t0, t0, t4                ; advance
        j     co_loop                   ; continue
co_ret:                                 ; done
        ret                             ; done

; ---- messages ----------------------------------------------------------------------------
; print_buf(a0 = address, a1 = length)
print_buf:                              ; routine entry (leaf)
        tput  tg15, a0, c2, zero, a1    ; to the console
        ret                             ; done

; print_z(a0 = NUL-terminated string)
print_z:                                ; routine entry (leaf)
        mv    t0, a0                    ; cursor
pz_len:                                 ; loop: measure
        lbu   t1, 0(t0)                 ; character
        beqz  t1, pz_out                ; end
        addi  t0, t0, 1                 ; next
        j     pz_len                    ; continue
pz_out:                                 ; measured
        sub   a1, t0, a0                ; length
        j     print_buf                 ; print

; print_dec(a0 = unsigned value)
print_dec:                              ; routine entry (leaf)
        li    t0, NUMBUF + 24           ; write cursor (right to left)
        li    t1, 10                    ; base
pd_loop:                                ; loop: one digit
        remu  t2, a0, t1                ; lowest digit
        divu  a0, a0, t1                ; drop it
        addi  t2, t2, '0'               ; character
        addi  t0, t0, -1                ; move left
        sb    t2, 0(t0)                 ; store
        bnez  a0, pd_loop               ; more digits
        mv    a0, t0                    ; first digit
        li    t1, NUMBUF + 24           ; end
        sub   a1, t1, t0                ; length
        j     print_buf                 ; print

; fail(a0 = message): print "line N: message" and stop
; fail_s(a0 = message, a1 = NUL-terminated detail)
; fail_n(a0 = message, a1 = detail, a2 = its length)
fail_noline:                            ; error exit about the program, not a line
        sd    zero, v_line(zero)        ; (prints "as: message")
fail:                                   ; error exit, no detail
        li    a1, 0                     ; no detail
        li    a2, 0                     ; ...
        j     fail_n                    ; print
fail_s:                                 ; error exit, NUL-terminated detail
        li    a2, -1                    ; detail is NUL-terminated
fail_n:                                 ; error exit, detail with a length
        mv    s0, a0                    ; s0 = message
        mv    s1, a1                    ; s1 = detail
        mv    s2, a2                    ; s2 = detail length
        ld    t0, v_line(zero)          ; about a line?
        beqz  t0, fl_noline             ; no
        li    a0, m_line                ; "line "
        call  print_z                   ; print
        ld    a0, v_line(zero)          ; the number
        call  print_dec                 ; print
        li    a0, m_colon               ; ": "
        call  print_z                   ; print
        j     fl_msg                    ; then the message
fl_noline:                              ; not about a line
        li    a0, m_as                  ; "as: "
        call  print_z                   ; print
fl_msg:                                 ; the message
        mv    a0, s0                    ; message
        call  print_z                   ; print
        beqz  s1, fl_nl                 ; no detail
        li    a0, m_sp                  ; a blank
        call  print_z                   ; print
        mv    a0, s1                    ; detail
        bltz  s2, fl_z                  ; NUL-terminated
        mv    a1, s2                    ; length
        call  print_buf                 ; print
        j     fl_nl                     ; end the line
fl_z:                                   ; NUL-terminated detail
        call  print_z                   ; print
fl_nl:                                  ; end the message
        li    a0, m_nl                  ; newline
        call  print_z                   ; print
        ld    t0, v_mode(zero)          ; which mode?
        li    a0, 1                     ; bare metal: exit code 1
        beqz  t0, fl_halt               ; ...
        li    a0, 0                     ; StrataOS: no output
fl_halt:                                ; stop
        halt                            ; stop (after the console drains)
