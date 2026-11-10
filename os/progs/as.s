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
; How it works
;   * Two passes over the source, like sasm. Pass 1 defines the symbols and
;     measures each section; pass 2 encodes. The size of every `li` is
;     decided in pass 1 (1, 2 or 6 instructions) and replayed in pass 2.
;   * Loads and stores reach only the data Local Store (D-LS), so all tables
;     live there: symbols, keywords, the line buffer. The source stays in
;     system memory and is streamed through a 1 KiB D-LS window, once per
;     pass, with `tget`.
;   * Emission within a section only moves forward (`.org` cannot go back),
;     so after pass 1 the place of every section in the output file is
;     known. Pass 2 writes each section through its own 256-byte D-LS window
;     straight to its final place, flushing a full window with `tput`.
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
;   0x2000 source window   0x2400 line buffer   0x2800 output windows
;   0x2C00 li sizes        0x3000 symbol hash heads
;   0x3800..0xA000 record heap (keywords, then symbols)
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
ILS_BYTES = 65536                       ; instruction Local Store size
DLS_BYTES = 65536                       ; data Local Store size
T2_BYTES = 262144                       ; cluster store size
T3_BYTES = 67108864                     ; system memory size (64 MiB)
SK_ILS   = 1                            ; STX section kinds: instruction LS
SK_DLS   = 2                            ; data LS
SK_T3    = 3                            ; system memory
SK_T2    = 4                            ; cluster store

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
F_LINST  = 25                           ; rs (linst, jr)
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
ANY      = 255                          ; operand count not checked up front
K_OP     = 1                            ; keyword class: instruction or directive
K_REG    = 2                            ; keyword class: integer register name
K_CSR    = 3                            ; keyword class: CSR name

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
INBUF    = 0x2000                       ; source window (also input gathering and output copying)
INSZ     = 1024                         ; its size
LINEBUF  = 0x2400                       ; current line, NUL-terminated
LINEMAX  = 1000                         ; longest line accepted
WINBUF   = 0x2800                       ; four section output windows
WINSZ    = 256                          ; bytes per window
LITAB    = 0x2C00                       ; li sizes, 2 bits each
LIMAX    = 4096                         ; li/la limit
SYMHASH  = 0x3000                       ; 1024 symbol chain heads (u16)
SYMMASK  = 1023                         ; symbol hash mask
HEAP     = 0x3800                       ; record heap start
HEAPEND  = 0xA000                       ; record heap end (StrataOS data limit)

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

; ---- symbol / keyword record (in the heap, 8-byte aligned) -----------------------
R_VAL    = 0                            ; value (8 bytes)
R_NEXT   = 8                            ; next record in the chain (u16, 0 = end)
R_LEN    = 10                           ; name length (u8)
R_SECT   = 11                           ; section, 255 = none (keywords: class)
R_NAME   = 12                           ; name bytes follow

; =============================================================================
        .data                           ; D-LS image: tables and variables
; =============================================================================
        .align 8                        ; variables are 64-bit words
v_mode:   .dword 0                      ; 1 = under StrataOS, 0 = bare metal
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
v_total:  .dword 0                      ; image length
v_count:  .dword 0                      ; number of sections in the image

sects:                                  ; section records: .text .data .far .cluster
        .dword 0, 0, 0, ILS_BYTES, SK_ILS, 0, 0, 0 ; .text: loc, lo, size, limit, kind, window
        .dword 0, 0                     ; header offset, base
        .dword 0, 0, 0, DLS_BYTES, SK_DLS, 0, 0, 0 ; .data
        .dword 0, 0                     ; header offset, base
        .dword 0, 0, 0, T3_BYTES, SK_T3, 0, 0, 0 ; .far
        .dword 0, 0                     ; header offset, base
        .dword 0, 0, 0, T2_BYTES, SK_T2, 0, 0, 0 ; .cluster
        .dword 0, 0                     ; header offset, base

jtab:                                   ; handler for each format, by format number
        .word h_r, h_i, h_iu, h_sh, h_lui, h_ld, h_b, h_jal ; F_R .. F_JAL
        .word h_xf, h_twait, h_tpoll, h_amo, h_cdcs, h_cdcsrx, h_rdcs, h_cpoll ; F_XF .. F_CPOLL
        .word h_csrx, h_ctake, h_cd, h_csslot, h_cdslot, h_csrr, h_csrw, h_sys ; F_CSRX .. F_SYS
        .word h_rrk, h_linst, h_xmap, h_xunmap, h_xcall, h_r0, h_li, h_j ; F_RRK .. P_J
        .word h_ret, h_tfence, h_bz, h_b2, d_sect, d_nop, d_ascii, d_data ; P_RET .. D_DATA
        .word d_space, d_align, d_org, d_equ, h_xret, h_csend, h_mkep ; D_SPACE .. F_MKEP

; Keyword table: name, then class, format, operand count, opcode, function.
; Copied into the keyword hash at start-up. An empty name ends it.
kwtab:                                  ; keyword table (copied into the keyword hash at start-up)
        .asciz "add"                    ; rd = rs1 + rs2
        .byte K_OP, F_R, 3, 0x00, 0     ; ALU, function 0
        .asciz "sub"                    ; rd = rs1 - rs2
        .byte K_OP, F_R, 3, 0x00, 1     ; ALU, function 1
        .asciz "and"                    ; bitwise and
        .byte K_OP, F_R, 3, 0x00, 2     ; ALU, function 2
        .asciz "or"                     ; bitwise or
        .byte K_OP, F_R, 3, 0x00, 3     ; ALU, function 3
        .asciz "xor"                    ; bitwise exclusive or
        .byte K_OP, F_R, 3, 0x00, 4     ; ALU, function 4
        .asciz "sll"                    ; shift left
        .byte K_OP, F_R, 3, 0x00, 5     ; ALU, function 5
        .asciz "srl"                    ; shift right logical
        .byte K_OP, F_R, 3, 0x00, 6     ; ALU, function 6
        .asciz "sra"                    ; shift right arithmetic
        .byte K_OP, F_R, 3, 0x00, 7     ; ALU, function 7
        .asciz "slt"                    ; set if less than
        .byte K_OP, F_R, 3, 0x00, 8     ; ALU, function 8
        .asciz "sltu"                   ; set if less than, unsigned
        .byte K_OP, F_R, 3, 0x00, 9     ; ALU, function 9
        .asciz "mul"                    ; multiply
        .byte K_OP, F_R, 3, 0x00, 10    ; ALU, function 10
        .asciz "mulhu"                  ; multiply, high half unsigned
        .byte K_OP, F_R, 3, 0x00, 11    ; ALU, function 11
        .asciz "divu"                   ; divide unsigned
        .byte K_OP, F_R, 3, 0x00, 12    ; ALU, function 12
        .asciz "remu"                   ; remainder unsigned
        .byte K_OP, F_R, 3, 0x00, 13    ; ALU, function 13
        .asciz "div"                    ; divide
        .byte K_OP, F_R, 3, 0x00, 14    ; ALU, function 14
        .asciz "rem"                    ; remainder
        .byte K_OP, F_R, 3, 0x00, 15    ; ALU, function 15
        .asciz "addi"                   ; add immediate
        .byte K_OP, F_I, 3, 0x01, 0     ; opcode 0x01
        .asciz "slti"                   ; set if less than immediate
        .byte K_OP, F_I, 3, 0x08, 0     ; opcode 0x08
        .asciz "sltiu"                  ; unsigned form
        .byte K_OP, F_I, 3, 0x09, 0     ; opcode 0x09
        .asciz "jalr"                   ; jump and link register
        .byte K_OP, F_I, 3, 0x29, 0     ; opcode 0x29
        .asciz "andi"                   ; and immediate (zero-extended)
        .byte K_OP, F_IU, 3, 0x02, 0    ; opcode 0x02
        .asciz "ori"                    ; or immediate
        .byte K_OP, F_IU, 3, 0x03, 0    ; opcode 0x03
        .asciz "xori"                   ; xor immediate
        .byte K_OP, F_IU, 3, 0x04, 0    ; opcode 0x04
        .asciz "slli"                   ; shift left immediate
        .byte K_OP, F_SH, 3, 0x05, 0    ; opcode 0x05
        .asciz "srli"                   ; shift right logical immediate
        .byte K_OP, F_SH, 3, 0x06, 0    ; opcode 0x06
        .asciz "srai"                   ; shift right arithmetic immediate
        .byte K_OP, F_SH, 3, 0x07, 0    ; opcode 0x07
        .asciz "lui"                    ; load upper immediate
        .byte K_OP, F_LUI, 2, 0x0A, 0   ; opcode 0x0A
        .asciz "ld"                     ; load 64 bits
        .byte K_OP, F_LD, 2, 0x10, 0    ; opcode 0x10
        .asciz "lw"                     ; load 32 bits, signed
        .byte K_OP, F_LD, 2, 0x11, 0    ; opcode 0x11
        .asciz "lwu"                    ; load 32 bits, unsigned
        .byte K_OP, F_LD, 2, 0x12, 0    ; opcode 0x12
        .asciz "lh"                     ; load 16 bits, signed
        .byte K_OP, F_LD, 2, 0x13, 0    ; opcode 0x13
        .asciz "lhu"                    ; load 16 bits, unsigned
        .byte K_OP, F_LD, 2, 0x14, 0    ; opcode 0x14
        .asciz "lb"                     ; load 8 bits, signed
        .byte K_OP, F_LD, 2, 0x15, 0    ; opcode 0x15
        .asciz "lbu"                    ; load 8 bits, unsigned
        .byte K_OP, F_LD, 2, 0x16, 0    ; opcode 0x16
        .asciz "sd"                     ; store 64 bits
        .byte K_OP, F_LD, 2, 0x18, 0    ; opcode 0x18
        .asciz "sw"                     ; store 32 bits
        .byte K_OP, F_LD, 2, 0x19, 0    ; opcode 0x19
        .asciz "sh"                     ; store 16 bits
        .byte K_OP, F_LD, 2, 0x1A, 0    ; opcode 0x1A
        .asciz "sb"                     ; store 8 bits
        .byte K_OP, F_LD, 2, 0x1B, 0    ; opcode 0x1B
        .asciz "beq"                    ; branch if equal
        .byte K_OP, F_B, 3, 0x20, 0     ; opcode 0x20
        .asciz "bne"                    ; branch if not equal
        .byte K_OP, F_B, 3, 0x21, 0     ; opcode 0x21
        .asciz "blt"                    ; branch if less than
        .byte K_OP, F_B, 3, 0x22, 0     ; opcode 0x22
        .asciz "bge"                    ; branch if greater or equal
        .byte K_OP, F_B, 3, 0x23, 0     ; opcode 0x23
        .asciz "bltu"                   ; unsigned less than
        .byte K_OP, F_B, 3, 0x24, 0     ; opcode 0x24
        .asciz "bgeu"                   ; unsigned greater or equal
        .byte K_OP, F_B, 3, 0x25, 0     ; opcode 0x25
        .asciz "jal"                    ; jump and link
        .byte K_OP, F_JAL, 2, 0x28, 0   ; opcode 0x28
        .asciz "tget"                   ; transfer far -> D-LS
        .byte K_OP, F_XF, 5, 0x30, 0    ; transfer group, get
        .asciz "tput"                   ; transfer D-LS -> far
        .byte K_OP, F_XF, 5, 0x30, 1    ; transfer group, put
        .asciz "tgetx"                  ; transfer far -> I-LS
        .byte K_OP, F_XF, 5, 0x30, 2    ; transfer group, get code
        .asciz "twait"                  ; wait for tags
        .byte K_OP, F_TWAIT, ANY, 0x31, 0 ; opcode 0x31
        .asciz "tpoll"                  ; poll tags
        .byte K_OP, F_TPOLL, ANY, 0x32, 0 ; opcode 0x32
        .asciz "tamo.add"               ; far atomic add
        .byte K_OP, F_AMO, 4, 0x33, 0   ; atomic group, add
        .asciz "tamo.swap"              ; far atomic swap
        .byte K_OP, F_AMO, 4, 0x33, 1   ; atomic group, swap
        .asciz "tamo.cas"               ; far compare and swap
        .byte K_OP, F_AMO, 4, 0x33, 2   ; atomic group, cas
        .asciz "tamo.and"               ; far atomic and
        .byte K_OP, F_AMO, 4, 0x33, 3   ; atomic group, and
        .asciz "tamo.or"                ; far atomic or
        .byte K_OP, F_AMO, 4, 0x33, 4   ; atomic group, or
        .asciz "cmov"                   ; move a capability
        .byte K_OP, F_CDCS, 2, 0x34, 0  ; capability group, mov
        .asciz "cjoin"                  ; join two capabilities
        .byte K_OP, F_CDCS, 2, 0x34, 2  ; capability group, join
        .asciz "cshare"                 ; read-only copyable share
        .byte K_OP, F_CDCS, 2, 0x34, 3  ; capability group, share
        .asciz "catomic"                ; atomic-only capability
        .byte K_OP, F_CDCS, 2, 0x34, 4  ; capability group, atom
        .asciz "csplit"                 ; split a capability
        .byte K_OP, F_CDCSRX, 3, 0x34, 1 ; capability group, split
        .asciz "crestrict"              ; drop permissions
        .byte K_OP, F_CDCSRX, 3, 0x34, 5 ; capability group, restrict
        .asciz "cbase"                  ; capability base
        .byte K_OP, F_RDCS, 2, 0x34, 6  ; capability group, base
        .asciz "clen"                   ; capability length
        .byte K_OP, F_RDCS, 2, 0x34, 7  ; capability group, len
        .asciz "cperms"                 ; capability permissions
        .byte K_OP, F_RDCS, 2, 0x34, 8  ; capability group, perms
        .asciz "cvalid"                 ; capability validity
        .byte K_OP, F_RDCS, 2, 0x34, 14 ; capability group, valid
        .asciz "cpoll"                  ; inbox senders
        .byte K_OP, F_CPOLL, 1, 0x34, 15 ; capability group, poll
        .asciz "cgive"                  ; give a capability to a node
        .byte K_OP, F_CSRX, 2, 0x34, 9  ; capability group, give
        .asciz "ctake"                  ; take a capability from the inbox
        .byte K_OP, F_CTAKE, ANY, 0x34, 10 ; capability group, take
        .asciz "cclear"                 ; clear a capability register
        .byte K_OP, F_CD, 1, 0x34, 11   ; capability group, clear
        .asciz "csave"                  ; capability -> table slot
        .byte K_OP, F_CSSLOT, 2, 0x34, 12 ; capability group, save
        .asciz "crestore"               ; table slot -> capability
        .byte K_OP, F_CDSLOT, 2, 0x34, 13 ; capability group, restore
        .asciz "cdom"                   ; make a revocation domain
        .byte K_OP, F_CDCS, 2, 0x35, 0  ; second capability group, dom
        .asciz "crevoke"                ; revoke a domain's capabilities
        .byte K_OP, F_CDCS, 2, 0x35, 1  ; second capability group, revoke
        .asciz "cundom"                 ; dissolve a domain
        .byte K_OP, F_CDCS, 2, 0x35, 2  ; second capability group, undom
        .asciz "csend"                  ; send a capability to an endpoint
        .byte K_OP, F_CSEND, 2, 0x35, 3 ; second capability group, send
        .asciz "crecv"                  ; receive a capability from an endpoint
        .byte K_OP, F_CDCS, 2, 0x35, 4  ; second capability group, recv
        .asciz "cmkep"                  ; make an endpoint capability
        .byte K_OP, F_MKEP, 2, 0x35, 5  ; second capability group, mkep
        .asciz "tany"                   ; wait for any of tags or the inbox
        .byte K_OP, F_RRK, 2, 0x36, 0   ; opcode 0x36
        .asciz "csrr"                   ; read a CSR
        .byte K_OP, F_CSRR, 2, 0x38, 0  ; opcode 0x38
        .asciz "csrw"                   ; write a CSR
        .byte K_OP, F_CSRW, 2, 0x39, 0  ; opcode 0x39
        .asciz "halt"                   ; stop the core
        .byte K_OP, F_SYS, 0, 0x3A, 0   ; system group, halt
        .asciz "eret"                   ; return from a trap
        .byte K_OP, F_SYS, 0, 0x3A, 1   ; system group, eret
        .asciz "svc"                    ; ask the supervisor for a service
        .byte K_OP, F_SYS, 0, 0x3A, 2   ; system group, svc
        .asciz "ltag"                   ; software cache lookup
        .byte K_OP, F_RRK, 2, 0x3B, 0   ; opcode 0x3B
        .asciz "linst"                  ; software cache install
        .byte K_OP, F_LINST, 1, 0x3C, 0 ; opcode 0x3C
        .asciz "xmap"                   ; map an overlay
        .byte K_OP, F_XMAP, 4, 0x3D, 0  ; opcode 0x3D
        .asciz "xunmap"                 ; unmap an overlay
        .byte K_OP, F_XUNMAP, 1, 0x3D, 0 ; opcode 0x3D, unmap bit
        .asciz "xcall"                  ; call through an overlay
        .byte K_OP, F_XCALL, 3, 0x3E, 0 ; opcode 0x3E
        .asciz "xret"                   ; return through a far link
        .byte K_OP, F_XRET, 1, 0x3E, 16 ; opcode 0x3E, return bit
        .asciz "nop"                    ; pseudo: addi zero, zero, 0
        .byte K_OP, F_SYS, 0, 0x01, 0   ; as an operand-less addi
        .asciz "mv"                     ; pseudo: addi rd, rs, 0
        .byte K_OP, F_RRK, 2, 0x01, 0   ; addi, immediate 0
        .asciz "seqz"                   ; pseudo: sltiu rd, rs, 1
        .byte K_OP, F_RRK, 2, 0x09, 1   ; sltiu, immediate 1
        .asciz "snez"                   ; pseudo: sltu rd, zero, rs
        .byte K_OP, P_R0, 2, 0x00, 9    ; ALU sltu
        .asciz "neg"                    ; pseudo: sub rd, zero, rs
        .byte K_OP, P_R0, 2, 0x00, 1    ; ALU sub
        .asciz "li"                     ; pseudo: load immediate
        .byte K_OP, P_LI, 2, 0, 0       ; sized in pass 1
        .asciz "la"                     ; pseudo: load address
        .byte K_OP, P_LI, 2, 0, 1       ; always 2 instructions
        .asciz "j"                      ; pseudo: jal zero, target
        .byte K_OP, P_J, 1, 0x28, 0     ; rd = 0
        .asciz "call"                   ; pseudo: jal ra, target
        .byte K_OP, P_J, 1, 0x28, 1     ; rd = 1
        .asciz "ret"                    ; pseudo: jalr zero, ra, 0
        .byte K_OP, P_RET, 0, 0x29, 0   ; fixed encoding
        .asciz "jr"                     ; pseudo: jalr zero, rs, 0
        .byte K_OP, F_LINST, 1, 0x29, 0 ; like linst with opcode jalr
        .asciz "tfence"                 ; pseudo: twait 0xffff
        .byte K_OP, P_TFENCE, 0, 0x31, 0 ; fixed encoding
        .asciz "beqz"                   ; pseudo: beq rs, zero
        .byte K_OP, P_BZ, 2, 0x20, 0    ; not swapped
        .asciz "bnez"                   ; pseudo: bne rs, zero
        .byte K_OP, P_BZ, 2, 0x21, 0    ; not swapped
        .asciz "bltz"                   ; pseudo: blt rs, zero
        .byte K_OP, P_BZ, 2, 0x22, 0    ; not swapped
        .asciz "bgez"                   ; pseudo: bge rs, zero
        .byte K_OP, P_BZ, 2, 0x23, 0    ; not swapped
        .asciz "bgtz"                   ; pseudo: blt zero, rs
        .byte K_OP, P_BZ, 2, 0x22, 1    ; swapped
        .asciz "blez"                   ; pseudo: bge zero, rs
        .byte K_OP, P_BZ, 2, 0x23, 1    ; swapped
        .asciz "bgt"                    ; pseudo: blt rs2, rs1
        .byte K_OP, P_B2, 3, 0x22, 0    ; swapped blt
        .asciz "ble"                    ; pseudo: bge rs2, rs1
        .byte K_OP, P_B2, 3, 0x23, 0    ; swapped bge
        .asciz "bgtu"                   ; pseudo: bltu rs2, rs1
        .byte K_OP, P_B2, 3, 0x24, 0    ; swapped bltu
        .asciz "bleu"                   ; pseudo: bgeu rs2, rs1
        .byte K_OP, P_B2, 3, 0x25, 0    ; swapped bgeu
        .asciz ".text"                  ; directive: instruction LS section
        .byte K_OP, D_SECT, ANY, 0, 0   ; section 0
        .asciz ".data"                  ; directive: data LS section
        .byte K_OP, D_SECT, ANY, 0, 1   ; section 1
        .asciz ".far"                   ; directive: system memory section
        .byte K_OP, D_SECT, ANY, 0, 2   ; section 2
        .asciz ".cluster"               ; directive: cluster store section
        .byte K_OP, D_SECT, ANY, 0, 3   ; section 3
        .asciz ".global"                ; directive: ignored
        .byte K_OP, D_NOP, ANY, 0, 0    ; nothing to do
        .asciz ".globl"                 ; directive: ignored
        .byte K_OP, D_NOP, ANY, 0, 0    ; nothing to do
        .asciz ".ascii"                 ; directive: string bytes
        .byte K_OP, D_ASCII, ANY, 0, 0  ; no terminator
        .asciz ".asciz"                 ; directive: string bytes and a NUL
        .byte K_OP, D_ASCII, ANY, 0, 1  ; with terminator
        .asciz ".string"                ; directive: same as .asciz
        .byte K_OP, D_ASCII, ANY, 0, 1  ; with terminator
        .asciz ".byte"                  ; directive: 1-byte values
        .byte K_OP, D_DATA, ANY, 0, 1   ; width 1
        .asciz ".half"                  ; directive: 2-byte values
        .byte K_OP, D_DATA, ANY, 0, 2   ; width 2
        .asciz ".word"                  ; directive: 4-byte values
        .byte K_OP, D_DATA, ANY, 0, 4   ; width 4
        .asciz ".dword"                 ; directive: 8-byte values
        .byte K_OP, D_DATA, ANY, 0, 8   ; width 8
        .asciz ".space"                 ; directive: fill bytes
        .byte K_OP, D_SPACE, ANY, 0, 0  ; size [, fill]
        .asciz ".zero"                  ; directive: same as .space
        .byte K_OP, D_SPACE, ANY, 0, 0  ; size [, fill]
        .asciz ".align"                 ; directive: pad to a power of two
        .byte K_OP, D_ALIGN, ANY, 0, 0  ; alignment
        .asciz ".org"                   ; directive: pad up to an address
        .byte K_OP, D_ORG, ANY, 0, 0    ; address
        .asciz ".equ"                   ; directive: define a constant
        .byte K_OP, D_EQU, ANY, 0, 0    ; name, value
        .asciz ".set"                   ; directive: same as .equ
        .byte K_OP, D_EQU, ANY, 0, 0    ; name, value
        .asciz "zero"                   ; register x0
        .byte K_REG, 0, 0, 0, 0         ; number 0
        .asciz "ra"                     ; register x1
        .byte K_REG, 1, 0, 0, 0         ; number 1
        .asciz "sp"                     ; register x2
        .byte K_REG, 2, 0, 0, 0         ; number 2
        .asciz "gp"                     ; register x3
        .byte K_REG, 3, 0, 0, 0         ; number 3
        .asciz "tp"                     ; register x4
        .byte K_REG, 4, 0, 0, 0         ; number 4
        .asciz "t0"                     ; register x5
        .byte K_REG, 5, 0, 0, 0         ; number 5
        .asciz "t1"                     ; register x6
        .byte K_REG, 6, 0, 0, 0         ; number 6
        .asciz "t2"                     ; register x7
        .byte K_REG, 7, 0, 0, 0         ; number 7
        .asciz "s0"                     ; register x8
        .byte K_REG, 8, 0, 0, 0         ; number 8
        .asciz "fp"                     ; register x8, other name
        .byte K_REG, 8, 0, 0, 0         ; number 8
        .asciz "s1"                     ; register x9
        .byte K_REG, 9, 0, 0, 0         ; number 9
        .asciz "a0"                     ; register x10
        .byte K_REG, 10, 0, 0, 0        ; number 10
        .asciz "a1"                     ; register x11
        .byte K_REG, 11, 0, 0, 0        ; number 11
        .asciz "a2"                     ; register x12
        .byte K_REG, 12, 0, 0, 0        ; number 12
        .asciz "a3"                     ; register x13
        .byte K_REG, 13, 0, 0, 0        ; number 13
        .asciz "a4"                     ; register x14
        .byte K_REG, 14, 0, 0, 0        ; number 14
        .asciz "a5"                     ; register x15
        .byte K_REG, 15, 0, 0, 0        ; number 15
        .asciz "a6"                     ; register x16
        .byte K_REG, 16, 0, 0, 0        ; number 16
        .asciz "a7"                     ; register x17
        .byte K_REG, 17, 0, 0, 0        ; number 17
        .asciz "s2"                     ; register x18
        .byte K_REG, 18, 0, 0, 0        ; number 18
        .asciz "s3"                     ; register x19
        .byte K_REG, 19, 0, 0, 0        ; number 19
        .asciz "s4"                     ; register x20
        .byte K_REG, 20, 0, 0, 0        ; number 20
        .asciz "s5"                     ; register x21
        .byte K_REG, 21, 0, 0, 0        ; number 21
        .asciz "s6"                     ; register x22
        .byte K_REG, 22, 0, 0, 0        ; number 22
        .asciz "s7"                     ; register x23
        .byte K_REG, 23, 0, 0, 0        ; number 23
        .asciz "s8"                     ; register x24
        .byte K_REG, 24, 0, 0, 0        ; number 24
        .asciz "s9"                     ; register x25
        .byte K_REG, 25, 0, 0, 0        ; number 25
        .asciz "s10"                    ; register x26
        .byte K_REG, 26, 0, 0, 0        ; number 26
        .asciz "s11"                    ; register x27
        .byte K_REG, 27, 0, 0, 0        ; number 27
        .asciz "t3"                     ; register x28
        .byte K_REG, 28, 0, 0, 0        ; number 28
        .asciz "t4"                     ; register x29
        .byte K_REG, 29, 0, 0, 0        ; number 29
        .asciz "t5"                     ; register x30
        .byte K_REG, 30, 0, 0, 0        ; number 30
        .asciz "t6"                     ; register x31
        .byte K_REG, 31, 0, 0, 0        ; number 31
        .asciz "cycle"                  ; CSR 0
        .byte K_CSR, 0, 0, 0, 0         ; number 0
        .asciz "instret"                ; CSR 1
        .byte K_CSR, 1, 0, 0, 0         ; number 1
        .asciz "cause"                  ; CSR 2
        .byte K_CSR, 2, 0, 0, 0         ; number 2
        .asciz "epc"                    ; CSR 3
        .byte K_CSR, 3, 0, 0, 0         ; number 3
        .asciz "tval"                   ; CSR 4
        .byte K_CSR, 4, 0, 0, 0         ; number 4
        .asciz "tvec"                   ; CSR 5
        .byte K_CSR, 5, 0, 0, 0         ; number 5
        .asciz "ccr"                    ; CSR 6
        .byte K_CSR, 6, 0, 0, 0         ; number 6
        .asciz "coreid"                 ; CSR 7
        .byte K_CSR, 7, 0, 0, 0         ; number 7
        .asciz "ttag"                   ; CSR 8
        .byte K_CSR, 8, 0, 0, 0         ; number 8
        .asciz "tdata"                  ; CSR 9
        .byte K_CSR, 9, 0, 0, 0         ; number 9
        .asciz "tgeom"                  ; CSR 10
        .byte K_CSR, 10, 0, 0, 0        ; number 10
        .asciz "ncores"                 ; CSR 11
        .byte K_CSR, 11, 0, 0, 0        ; number 11
        .asciz "scratch"                ; CSR 12
        .byte K_CSR, 12, 0, 0, 0        ; number 12
        .asciz "stalls"                 ; CSR 13
        .byte K_CSR, 13, 0, 0, 0        ; number 13
        .asciz "takefrom"               ; CSR 14
        .byte K_CSR, 14, 0, 0, 0        ; number 14
        .asciz "corebase"               ; CSR 15
        .byte K_CSR, 15, 0, 0, 0        ; number 15
        .asciz "corecount"              ; CSR 16
        .byte K_CSR, 16, 0, 0, 0        ; number 16
        .asciz "reserved17"             ; CSR 17
        .byte K_CSR, 17, 0, 0, 0        ; number 17
        .asciz "status"                 ; CSR 18
        .byte K_CSR, 18, 0, 0, 0        ; number 18
        .asciz "ucause"                 ; CSR 19
        .byte K_CSR, 19, 0, 0, 0        ; number 19
        .asciz "uepc"                   ; CSR 20
        .byte K_CSR, 20, 0, 0, 0        ; number 20
        .asciz "utval"                  ; CSR 21
        .byte K_CSR, 21, 0, 0, 0        ; number 21
        .asciz "utvec"                  ; CSR 22
        .byte K_CSR, 22, 0, 0, 0        ; number 22
        .asciz "sscratch"               ; CSR 23
        .byte K_CSR, 23, 0, 0, 0        ; number 23
        .asciz "ipend"                  ; CSR 24
        .byte K_CSR, 24, 0, 0, 0        ; number 24
        .asciz "xslot"                  ; CSR 25
        .byte K_CSR, 25, 0, 0, 0        ; number 25
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
        sd    zero, v_org(zero)         ; text origin 0
        li    t0, IN_BARE               ; input offset in system memory
        sd    t0, v_inbase(zero)        ; remember
        li    t0, OUT_BARE              ; output offset
        sd    t0, v_outbase(zero)       ; remember
        li    t0, OUTMAX_BARE           ; output limit
        sd    t0, v_outmax(zero)        ; remember
        call  read_console              ; console input -> system memory
st_go:                                  ; both modes: assemble
        li    a0, 1                     ; pass 1: symbols and sizes
        call  run_pass                  ; over the whole source
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
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
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
it_kw:                                  ; loop: one keyword table entry
        lbu   t0, 0(s0)                 ; first character of the name
        beqz  t0, it_done               ; empty name: end of table
        mv    a0, s0                    ; the name
        call  strhash                   ; a1 = length, a2 = hash
        add   t0, s0, a1                ; t0 = the NUL after the name
        lbu   a6, 1(t0)                 ; a6 = class
        lbu   a5, 2(t0)                 ; a5 = format (or number)
        lbu   t1, 3(t0)                 ; operand count
        slli  t1, t1, 8                 ; into bits 8..15
        or    a5, a5, t1                ; merge
        lbu   t1, 4(t0)                 ; opcode
        slli  t1, t1, 16                ; into bits 16..23
        or    a5, a5, t1                ; merge
        lbu   t1, 5(t0)                 ; function
        slli  t1, t1, 24                ; into bits 24..31
        or    a5, a5, t1                ; merge: a5 = record value
        addi  s0, t0, 6                 ; s0 = next entry
        li    a3, KWHASH                ; keyword heads
        li    a4, KWMASK                ; their mask
        call  insert                    ; add the record
        j     it_kw                     ; next entry
it_done:                                ; table copied
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; restore
        addi  sp, sp, 16                ; pop
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
        li    t1, 4                     ; t1 = sections left
        li    t2, -1                    ; t2 = "nothing emitted yet"
rp_reset:                               ; loop: reset one section record
        sd    zero, S_LOC(t0)           ; location 0
        sd    t2, S_LO(t0)              ; no lowest address yet
        addi  t0, t0, SREC              ; next record
        addi  t1, t1, -1                ; one fewer
        bnez  t1, rp_reset              ; all four
        ld    t0, v_org(zero)           ; text origin
        sd    t0, sects+S_LOC(zero)     ; .text starts there
        sd    zero, v_cs(zero)          ; start in .text
        li    s11, sects                ; s11 = its record
        sd    zero, v_lii(zero)         ; first li
        sd    zero, v_line(zero)        ; no line read yet
        sd    zero, v_pos(zero)         ; at the start of the source
        li    t0, -1                    ; no window contents yet: a huge window
        srli  t0, t0, 1                 ; offset puts every position "before" it
        sd    t0, v_chunk(zero)         ; and forces a fetch
rp_loop:                                ; loop: one source line
        call  read_line                 ; next line into LINEBUF
        beqz  a0, rp_done               ; end of the source
        call  do_line                   ; assemble it
        j     rp_loop                   ; continue
rp_done:                                ; end of the source
        ld    ra, 0(sp)                 ; restore
        addi  sp, sp, 16                ; pop
        ret                             ; pass done

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
        li    a0, LINEBUF               ; the raw line
        call  skipws                    ; first non-blank
        li    t0, s_include             ; ".include"
        li    t1, 8                     ; 8 characters
dl_inc:                                 ; loop: compare with ".include"
        lbu   t2, 0(a0)                 ; line character
        lbu   t3, 0(t0)                 ; expected character
        bne   t2, t3, dl_noinc          ; differs: not an include
        addi  a0, a0, 1                 ; next
        addi  t0, t0, 1                 ; next
        addi  t1, t1, -1                ; one fewer
        bnez  t1, dl_inc                ; all 8
        lbu   t2, 0(a0)                 ; the character after ".include"
        lbu   t2, CCLASS(t2)            ; its class
        andi  t2, t2, C_SP              ; white space?
        bnez  t2, dl_ret                ; an include line: skipped (supply the file as input)
dl_noinc:                               ; an ordinary line
        li    a0, LINEBUF               ; the line
        call  strip_comment             ; cut ; # // comments
        li    a0, LINEBUF               ; the line
        call  trim                      ; drop surrounding white space
        mv    s0, a0                    ; s0 = cursor
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
        li    t0, MBUF                  ; t0 = lower-cased copy
        mv    t1, s0                    ; t1 = source cursor
        li    t2, 0                     ; t2 = characters kept
        li    t3, 0                     ; t3 = hash
dm_loop:                                ; loop: copy one mnemonic character
        lbu   t4, 0(t1)                 ; next character
        beqz  t4, dm_end                ; end of line
        li    t5, ' '                   ; blank ends the mnemonic
        beq   t4, t5, dm_end            ; ...
        li    t5, 9                     ; and so does a tab
        beq   t4, t5, dm_end            ; ...
        addi  t1, t1, 1                 ; consumed
        li    t5, 63                    ; sasm keeps 63 characters
        bgeu  t2, t5, dm_loop           ; drop the rest
        addi  t5, t4, -'A'              ; upper case?
        sltiu t5, t5, 26                ; t5 = 1 if A..Z
        slli  t5, t5, 5                 ; 32 if so
        add   t4, t4, t5                ; lower-case it
        add   t5, t0, t2                ; destination
        sb    t4, 0(t5)                 ; keep it
        addi  t2, t2, 1                 ; one more
        slli  t5, t3, 5                 ; hash * 32
        add   t3, t3, t5                ; hash * 33
        add   t3, t3, t4                ; + character
        j     dm_loop                   ; continue
dm_end:                                 ; mnemonic copied
        add   t5, t0, t2                ; end of the copy
        sb    zero, 0(t5)               ; terminate it
        sd    t1, v_rest(zero)          ; the operands follow
        mv    a0, t0                    ; look the mnemonic up
        mv    a1, t2                    ; length
        mv    a2, t3                    ; hash
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
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        ld    s1, 16(sp)                ; ...
        ld    s2, 24(sp)                ; ...
        ld    s3, 32(sp)                ; ...
        ld    s4, 40(sp)                ; ...
        addi  sp, sp, 48                ; pop
        ret                             ; line done

; ---- instruction handlers (jumped to from do_line) ----------------------------------
h_r:                                    ; rd, rs1, rs2
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; rs1
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        ld    a0, OPS+16(zero)          ; rs2
        call  xreg                      ; number
        mv    a3, a0                    ; a3 = rs2
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode with rd = s0, rs1 = s1

h_i:                                    ; rd, rs1, signed imm16
        li    s3, 0                     ; range: signed 16 bits
        j     h_imm                     ; common part
h_iu:                                   ; rd, rs1, unsigned imm16
        li    s3, 1                     ; range: unsigned 16 bits
        j     h_imm                     ; common part
h_sh:                                   ; rd, rs1, shift amount
        li    s3, 2                     ; range: 0..63
h_imm:                                  ; common part of the immediate forms
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; rs1
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        ld    a0, OPS+16(zero)          ; immediate
        call  eval                      ; value
        mv    s2, a0                    ; s2 = immediate
        mv    a1, s3                    ; which range
        call  check_imm                 ; pass 2 range check
        mv    a3, s2                    ; immediate
        j     h_enc_i01                 ; encode with rd = s0, rs1 = s1

h_lui:                                  ; rd, imm16 (either reading)
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; immediate
        call  eval                      ; value
        mv    s2, a0                    ; s2 = immediate
        li    a1, 3                     ; range -32768..65535
        call  check_imm                 ; pass 2 range check
        li    s1, 0                     ; rs1 = 0
        mv    a3, s2                    ; immediate
        j     h_enc_i01                 ; encode

h_ld:                                   ; reg, offset(base)
        ld    a0, OPS+8(zero)           ; memory operand
        call  memop                     ; a0 = offset, a1 = base
        mv    s2, a0                    ; s2 = offset
        mv    s1, a1                    ; s1 = base register
        li    a1, 0                     ; signed 16 bits
        call  check_imm                 ; pass 2 range check
        ld    a0, OPS(zero)             ; data register
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = it
        mv    a3, s2                    ; offset
        j     h_enc_i01                 ; encode

h_b:                                    ; rs1, rs2, target
        ld    a0, OPS(zero)             ; first register
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = it
        ld    a0, OPS+8(zero)           ; second register
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = it
        ld    a0, OPS+16(zero)          ; target
h_bt:                                   ; common part of the branches: target in a0
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
        ld    a0, OPS+8(zero)           ; target
        j     h_jt                      ; common part
h_j:                                    ; j / call: rd from the table
        ld    s0, v_fn(zero)            ; rd = 0 or 1
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

h_amo:                                  ; rd, cap, addr, value
        ld    a0, OPS+8(zero)           ; capability
        call  creg                      ; number
        slli  s4, a0, 7                 ; s4 = cap << 7
        ld    t0, v_fn(zero)            ; atomic operation
        or    s4, s4, t0                ; s4 = function field
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+16(zero)          ; address register
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        ld    a0, OPS+24(zero)          ; value register
        call  xreg                      ; number
        mv    a3, a0                    ; a3 = rs2
        mv    a4, s4                    ; function
        j     h_enc_r01                 ; encode

h_cdcs:                                 ; cd, cs
        ld    a0, OPS(zero)             ; cd
        call  creg                      ; number
        mv    s0, a0                    ; s0 = cd
        ld    a0, OPS+8(zero)           ; cs
        call  creg                      ; number
        mv    s1, a0                    ; s1 = cs
        li    a3, 0                     ; no rs2
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_cdcsrx:                               ; cd, cs, rs
        ld    a0, OPS(zero)             ; cd
        call  creg                      ; number
        mv    s0, a0                    ; s0 = cd
        ld    a0, OPS+8(zero)           ; cs
        call  creg                      ; number
        mv    s1, a0                    ; s1 = cs
        ld    a0, OPS+16(zero)          ; rs
        call  xreg                      ; number
        mv    a3, a0                    ; rs2 field
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_rdcs:                                 ; rd, cs
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; cs
        call  creg                      ; number
        mv    s1, a0                    ; s1 = cs
        li    a3, 0                     ; no rs2
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_cpoll:                                ; rd
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        li    s1, 0                     ; no rs1
        li    a3, 0                     ; no rs2
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_csrx:                                 ; cs, rs (cgive)
        ld    a0, OPS(zero)             ; cs
        call  creg                      ; number
        mv    s1, a0                    ; s1 = cs (rs1 field)
        ld    a0, OPS+8(zero)           ; rs
        call  xreg                      ; number
        mv    a3, a0                    ; rs2 field
        li    s0, 0                     ; no rd
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

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
h_cd:                                   ; cd (cclear, ctake)
        ld    a0, OPS(zero)             ; cd
        call  creg                      ; number
        mv    s0, a0                    ; s0 = cd
        li    s1, 0                     ; no rs1
        li    a3, 0                     ; no rs2
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_csslot:                               ; cs, slot
        li    s3, 0                     ; capability goes in rs1
        j     h_slot                    ; common part
h_cdslot:                               ; cd, slot
        li    s3, 1                     ; capability goes in rd
h_slot:                                 ; common part of csave/crestore
        ld    a0, OPS(zero)             ; capability register
        call  creg                      ; number
        mv    s2, a0                    ; s2 = it
        ld    a0, OPS+8(zero)           ; slot
        call  eval                      ; value
        mv    s4, a0                    ; s4 = slot
        li    a1, 4                     ; range 0..63
        call  check_imm                 ; pass 2 range check
        andi  a4, s4, 63                ; slot bits
        slli  a4, a4, 5                 ; into place
        ld    t0, v_fn(zero)            ; function
        or    a4, a4, t0                ; function field
        li    s0, 0                     ; rd
        li    s1, 0                     ; rs1
        li    a3, 0                     ; rs2
        beqz  s3, h_slot_s              ; csave: capability in rs1
        mv    s0, s2                    ; crestore: capability in rd
        j     h_enc_r01                 ; encode
h_slot_s:                               ; csave
        mv    s1, s2                    ; capability in rs1
        j     h_enc_r01                 ; encode

h_csrr:                                 ; rd, csr
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; csr
        call  csrnum                    ; number
        mv    a3, a0                    ; immediate
        li    s1, 0                     ; no rs1
        j     h_enc_i01                 ; encode

h_csrw:                                 ; csr, rs
        ld    a0, OPS+8(zero)           ; rs
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        ld    a0, OPS(zero)             ; csr
        call  csrnum                    ; number
        mv    a3, a0                    ; immediate
        li    s0, 0                     ; no rd
        j     h_enc_i01                 ; encode

h_sys:                                  ; no operands: imm = function (halt, eret, nop)
        li    s0, 0                     ; rd
        li    s1, 0                     ; rs1
        ld    a3, v_fn(zero)            ; immediate
        j     h_enc_i01                 ; encode

h_ret:                                  ; ret = jalr zero, ra, 0
        li    s0, 0                     ; rd = zero
        li    s1, 1                     ; rs1 = ra
        li    a3, 0                     ; offset 0
        j     h_enc_i01                 ; encode

h_tfence:                               ; tfence = twait 0xffff
        li    s0, 0                     ; rd
        li    s1, 0                     ; rs1
        li    a3, 0xffff                ; every tag
        j     h_enc_i01                 ; encode

h_rrk:                                  ; rd, rs: immediate = function (ltag, mv, seqz)
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; rs
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        ld    a3, v_fn(zero)            ; immediate
        j     h_enc_i01                 ; encode

h_linst:                                ; rs (linst, jr)
        ld    a0, OPS(zero)             ; rs
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        li    s0, 0                     ; no rd
        li    a3, 0                     ; no immediate
        j     h_enc_i01                 ; encode

h_r0:                                   ; rd, rs with rs1 = zero (snez, neg)
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+8(zero)           ; rs
        call  xreg                      ; number
        mv    a3, a0                    ; rs2
        li    s1, 0                     ; rs1 = zero
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_xmap:                                 ; idx, rs1, cap, rs2
        ld    a0, OPS(zero)             ; index
        call  eval                      ; value
        mv    s4, a0                    ; s4 = index
        li    a1, 5                     ; range 0..15
        call  check_imm                 ; pass 2 range check
        andi  s0, s4, 15                ; rd field = index
        ld    a0, OPS+8(zero)           ; rs1
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        ld    a0, OPS+24(zero)          ; rs2
        call  xreg                      ; number
        mv    s2, a0                    ; s2 = rs2
        ld    a0, OPS+16(zero)          ; capability
        call  creg                      ; number
        mv    a4, a0                    ; function field = capability
        mv    a3, s2                    ; rs2
        j     h_enc_r01                 ; encode

h_xunmap:                               ; idx
        ld    a0, OPS(zero)             ; index
        call  eval                      ; value
        mv    s4, a0                    ; s4 = index
        li    a1, 5                     ; range 0..15
        call  check_imm                 ; pass 2 range check
        andi  s0, s4, 15                ; rd field = index
        li    s1, 0                     ; no rs1
        li    a3, 0                     ; no rs2
        li    a4, 16                    ; unmap bit
        j     h_enc_r01                 ; encode

h_xcall:                                ; rd, cap, rs
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        mv    s0, a0                    ; s0 = rd
        ld    a0, OPS+16(zero)          ; rs
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        ld    a0, OPS+8(zero)           ; capability
        call  creg                      ; number
        mv    a4, a0                    ; function field = capability
        li    a3, 0                     ; no rs2
        j     h_enc_r01                 ; encode

h_xret:                                 ; rs: return through the far link in rs
        ld    a0, OPS(zero)             ; rs
        call  xreg                      ; number
        mv    s1, a0                    ; s1 = rs1
        li    s0, 0                     ; no rd
        li    a3, 0                     ; no rs2
        ld    a4, v_fn(zero)            ; function: the return bit
        j     h_enc_r01                 ; encode

h_csend:                                ; cs, ce: cs goes in rs1, ce in rd
        ld    a0, OPS(zero)             ; cs
        call  creg                      ; number
        mv    s1, a0                    ; s1 = cs
        ld    a0, OPS+8(zero)           ; ce
        call  creg                      ; number
        mv    s0, a0                    ; s0 = ce
        li    a3, 0                     ; no rs2
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_mkep:                                 ; cd, rs: the node number goes in rs2
        ld    a0, OPS(zero)             ; cd
        call  creg                      ; number
        mv    s0, a0                    ; s0 = cd
        ld    a0, OPS+8(zero)           ; rs
        call  xreg                      ; number
        mv    a3, a0                    ; rs2 field
        li    s1, 0                     ; no rs1
        ld    a4, v_fn(zero)            ; function
        j     h_enc_r01                 ; encode

h_li:                                   ; rd, value (fn = 1 for la)
        ld    a0, OPS(zero)             ; rd
        call  xreg                      ; number
        ld    a1, OPS+8(zero)           ; expression
        ld    a2, v_fn(zero)            ; la?
        call  do_li                     ; emit 1, 2 or 6 instructions
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
        li    t3, HEAPEND               ; heap limit
        bltu  t3, t2, in_full           ; no room
        sd    t2, v_heap(zero)          ; claim it
        sd    a5, R_VAL(t0)             ; value
        sb    a1, R_LEN(t0)             ; name length
        sb    a6, R_SECT(t0)            ; section or class
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
; Pass 1 only: pass 2 finds the same values again.
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
        bnez  a0, sd_redef              ; yes: redefinition
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

e_or:                                   ; a | b | ...
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        call  e_xor                     ; left operand
        mv    s0, a0                    ; s0 = value
eo_loop:                                ; loop: another | operand?
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; operator?
        li    t1, '|'                   ; or
        bne   t0, t1, e_ret             ; no: done
        addi  s10, s10, 1               ; consume it
        call  e_xor                     ; right operand
        or    s0, s0, a0                ; combine
        j     eo_loop                   ; continue

e_xor:                                  ; a ^ b ^ ...
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        call  e_and                     ; left operand
        mv    s0, a0                    ; s0 = value
ex_loop:                                ; loop: another ^ operand?
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; operator?
        li    t1, '^'                   ; xor
        bne   t0, t1, e_ret             ; no: done
        addi  s10, s10, 1               ; consume it
        call  e_and                     ; right operand
        xor   s0, s0, a0                ; combine
        j     ex_loop                   ; continue

e_and:                                  ; a & b & ...
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        call  e_shift                   ; left operand
        mv    s0, a0                    ; s0 = value
ea_loop:                                ; loop: another & operand?
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; operator?
        li    t1, '&'                   ; and
        bne   t0, t1, e_ret             ; no: done
        addi  s10, s10, 1               ; consume it
        call  e_shift                   ; right operand
        and   s0, s0, a0                ; combine
        j     ea_loop                   ; continue

e_ret:                                  ; shared epilogue of the binary levels
        mv    a0, s0                    ; result
        ld    ra, 0(sp)                 ; restore
        ld    s0, 8(sp)                 ; ...
        addi  sp, sp, 16                ; pop
        ret                             ; done

e_shift:                                ; a << b, a >> b (arithmetic), amount & 63
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        call  e_add                     ; left operand
        mv    s0, a0                    ; s0 = value
es_loop:                                ; loop: another shift?
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; first character
        lbu   t1, 1(s10)                ; second character
        bne   t0, t1, e_ret             ; << and >> repeat a character
        li    t1, '<'                   ; left shift?
        beq   t0, t1, es_left           ; yes
        li    t1, '>'                   ; right shift?
        bne   t0, t1, e_ret             ; no: done
        addi  s10, s10, 2               ; consume >>
        call  e_add                     ; amount
        andi  a0, a0, 63                ; modulo 64
        sra   s0, s0, a0                ; arithmetic shift
        j     es_loop                   ; continue
es_left:                                ; <<
        addi  s10, s10, 2               ; consume <<
        call  e_add                     ; amount
        andi  a0, a0, 63                ; modulo 64
        sll   s0, s0, a0                ; shift
        j     es_loop                   ; continue

e_add:                                  ; a + b, a - b
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        call  e_mul                     ; left operand
        mv    s0, a0                    ; s0 = value
ead_loop:                               ; loop: another + or - operand?
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; operator?
        li    t1, '+'                   ; plus?
        beq   t0, t1, ead_plus          ; yes
        li    t1, '-'                   ; minus?
        bne   t0, t1, e_ret             ; no: done
        addi  s10, s10, 1               ; consume it
        call  e_mul                     ; right operand
        sub   s0, s0, a0                ; subtract
        j     ead_loop                  ; continue
ead_plus:                               ; +
        addi  s10, s10, 1               ; consume it
        call  e_mul                     ; right operand
        add   s0, s0, a0                ; add
        j     ead_loop                  ; continue

e_mul:                                  ; a * b, a / b, a % b (signed, as C)
        addi  sp, sp, -16               ; frame
        sd    ra, 0(sp)                 ; save the return address
        sd    s0, 8(sp)                 ; and s0
        call  e_unary                   ; left operand
        mv    s0, a0                    ; s0 = value
em_loop:                                ; loop: another * / % operand?
        call  ws10                      ; blanks
        lbu   t0, 0(s10)                ; operator?
        li    t1, '*'                   ; multiply?
        beq   t0, t1, em_mul            ; yes
        li    t1, '/'                   ; divide?
        beq   t0, t1, em_div            ; yes
        li    t1, '%'                   ; remainder?
        bne   t0, t1, e_ret             ; no: done
        addi  s10, s10, 1               ; consume it
        call  e_unary                   ; right operand
        beqz  a0, em_zero               ; by zero
        rem   s0, s0, a0                ; remainder
        j     em_loop                   ; continue
em_div:                                 ; /
        addi  s10, s10, 1               ; consume it
        call  e_unary                   ; right operand
        beqz  a0, em_zero               ; by zero
        div   s0, s0, a0                ; quotient
        j     em_loop                   ; continue
em_mul:                                 ; *
        addi  s10, s10, 1               ; consume it
        call  e_unary                   ; right operand
        mul   s0, s0, a0                ; product
        j     em_loop                   ; continue
em_zero:                                ; division by zero
        ld    t0, v_undef(zero)         ; an undefined symbol reads as 0:
        li    s0, 0                     ; the result is 0
        bnez  t0, em_loop               ; and that is not an error
        li    a0, m_div0                ; a real division by zero
        j     fail                      ; report

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
        bgeu  t0, t1, eb_ovf            ; past the end
        li    t2, 2                     ; pass 2?
        beq   tp, t2, eb_p2             ; yes: store the byte
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
        sub   t2, t0, t1                ; position in the window
        li    t3, WINSZ                 ; window size
        bltu  t2, t3, eb_put            ; inside
        ld    t4, S_WBUF(s11)           ; full: flush the window
        ld    t5, S_FADJ(s11)           ; arena offset of address 0
        add   t5, t5, t1                ; arena offset of the window
        tput  tg0, t4, c0, t5, t3       ; write it (later stores into it wait)
        add   t1, t1, t3                ; next window
        sd    t1, S_WBASE(s11)          ; ...
        sub   t2, t0, t1                ; position in it
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
        li    t0, 1                     ; 2 instructions?
        beq   s3, t0, li_two            ; yes
        srai  s2, s1, 32                ; s2 = high 32 bits
        li    a0, OP_LUI                ; lui rd, hi >> 16
        mv    a1, s0                    ; rd
        li    a2, 0                     ; rs1
        srai  a3, s2, 16                ; immediate
        call  enc_i                     ; emit
        li    a0, OP_ORI                ; ori rd, rd, hi & 0xffff
        mv    a1, s0                    ; rd
        mv    a2, s0                    ; rs1
        mv    a3, s2                    ; immediate (masked)
        call  enc_i                     ; emit
        li    a0, OP_SLLI               ; slli rd, rd, 16
        mv    a1, s0                    ; rd
        mv    a2, s0                    ; rs1
        li    a3, 16                    ; amount
        call  enc_i                     ; emit
        li    a0, OP_ORI                ; ori rd, rd, (v >> 16) & 0xffff
        mv    a1, s0                    ; rd
        mv    a2, s0                    ; rs1
        srai  a3, s1, 16                ; immediate (masked)
        call  enc_i                     ; emit
        li    a0, OP_SLLI               ; slli rd, rd, 16
        mv    a1, s0                    ; rd
        mv    a2, s0                    ; rs1
        li    a3, 16                    ; amount
        call  enc_i                     ; emit
        j     li_last                   ; and the low half
li_two:                                 ; 2 instructions: lui, ori
        li    a0, OP_LUI                ; lui rd, (v >> 16) & 0xffff
        mv    a1, s0                    ; rd
        li    a2, 0                     ; rs1
        srai  a3, s1, 16                ; immediate (masked)
        call  enc_i                     ; emit
li_last:                                ; final ori of the low half
        li    a0, OP_ORI                ; ori rd, rd, v & 0xffff
        mv    a1, s0                    ; rd
        mv    a2, s0                    ; rs1
        mv    a3, s1                    ; immediate (masked)
        call  enc_i                     ; emit
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

; ---- image layout and output ------------------------------------------------------------------
; layout(): after pass 1, place each non-empty section in the image and
; prepare its output window.
layout:                                 ; routine entry (leaf)
        li    t0, 8                     ; t0 = file offset: after "STX2" and the count
        li    t1, 0                     ; t1 = sections in the image
        li    t2, sects                 ; t2 = section record
        li    t3, WINBUF                ; t3 = its window
        li    t4, 4                     ; t4 = records left
lo_loop:                                ; loop: one section record
        ld    t5, S_SIZE(t2)            ; size
        beqz  t5, lo_next               ; empty: not in the image
        addi  t1, t1, 1                 ; one more section
        ld    t6, S_LO(t2)              ; lowest address
        srli  t6, t6, 3                 ; rounded down
        slli  t6, t6, 3                 ; to 8: the base
        sd    t6, S_BASE(t2)            ; remember
        sd    t0, S_HDR(t2)             ; its header goes here
        ld    a0, v_outbase(zero)       ; image offset in the arena
        add   a0, a0, t0                ; header position
        addi  a0, a0, 16                ; bytes follow the header
        sub   a0, a0, t6                ; arena offset of address 0
        sd    a0, S_FADJ(t2)            ; ...
        sd    t6, S_WBASE(t2)           ; first window starts at the base
        sd    t3, S_WBUF(t2)            ; window buffer
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
        addi  t2, t2, SREC              ; next record
        addi  t3, t3, WINSZ             ; next window
        addi  t4, t4, -1                ; one fewer
        bnez  t4, lo_loop               ; all four
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
        li    t4, 4                     ; t4 = records left
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
        bnez  t4, fi_loop               ; all four
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
