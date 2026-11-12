\ =============================================================================
\ see.fs: the disassembler and SEE
\ =============================================================================
\
\ Part of Strata Forth (see core.fs). On bare metal this file is embedded in
\ the image after core.fs and tools.fs. Under StrataOS it is a disk file:
\ `see`, `disasm` and `dis` are stubs (os/os.fs) that load it, run and forget
\ it again; `require see` loads it for good.

\ ---- the disassembler and SEE ------------------------------------------------------------
\ Code cannot be loaded as data on Strata: CODE@ reads it back from the far
\ mirror of the I-LS (a tget), which is also what the compiler does to inline.
: field ( u shift bits -- v ) >r rshift 1 r> lshift 1- and ; \ an instruction field
: sext ( u bits -- n ) 64 swap - tuck lshift swap arshift ; \ sign-extend
: (name) ( a u n -- ) \ print the n-th 5-character field of a name table
  5 * /string drop 5 -trailing type ;
: reg. ( r -- )
  s" zero ra   sp   gp   tp   t0   t1   t2   s0   s1   a0   a1   a2   a3   a4   a5   a6   a7   s2   s3   s4   s5   s6   s7   s8   s9   s10  s11  t3   t4   t5   t6   "
  rot (name) ;
: ., ( -- ) ." , " ;
: target. ( a -- ) dup h. xt>name ?dup if ." <" name>string type ." >" then ;
variable pc                                     \ the instruction being shown
: dis-alu ( insn -- )
  dup 0 4 field s" add  sub  and  or   xor  sll  srl  sra  slt  sltu mul  mulhu divu remu div  rem  "
  rot (name) space  dup 21 5 field reg. ., dup 16 5 field reg. ., 11 5 field reg. ;
: dis-imm ( insn op -- )
  1- s" addi andi ori  xori slli srli srai slti sltiu" rot (name) space
  dup 21 5 field reg. ., dup 16 5 field reg. ., 0 16 field 16 sext . ;
: dis-mem ( insn -- )                           \ loads and stores: rd, imm(rs1)
  space dup 21 5 field reg. ., dup 0 16 field 16 sext 0 .r ." (" 16 5 field reg. ." )" ;
: dis-ldst ( insn op -- )                      \ every load and store, from one table
  $10 - s" ld   lw   lwu  lh   lhu  lb   lbu  ?    sd   sw   sh   sb   " rot (name) dis-mem ;
: dis-branch ( insn op -- )
  $20 - s" beq  bne  blt  bge  bltu bgeu " rot (name) space
  dup 21 5 field reg. ., dup 16 5 field reg. ., 0 16 field 16 sext cells 2/ pc @ + target. ;
: dis-jal ( insn -- )
  dup 21 5 field case 0 of ." j    " endof 1 of ." call " endof ." jal  " dup reg. ., endcase
  0 21 field 21 sext cells 2/ pc @ + target. ;
: dis-jalr ( insn -- )                           \ through gp (paged code): a resident word
  dup $03ffffff and $10000 = if drop ." ret" exit then
  ." jalr " dup 21 5 field reg. ., dup 16 5 field dup reg. ., swap 0 16 field 16 sext
  swap 3 = if $10000 + target. else . then ;
: dis-xfer ( insn -- )
  dup 23 3 field s" tget tput tgetx" rot (name) ."  tg" dup 19 4 field 0 .r .,
  dup 14 5 field reg. ., ." c" dup 10 4 field 0 .r ., dup 5 5 field reg. ., 0 5 field reg. ;
: dis-x ( insn -- )                              \ the overlay map: xcall, xret, xmap, xunmap
  dup 26 6 field $3E = if
    dup 4 rshift 1 and if ." xret " 16 5 field reg. exit then
    ." xcall " dup 21 5 field reg. ., ." c" dup 0 4 field 0 .r ., 16 5 field reg. exit then
  dup 4 rshift 1 and if ." xunmap " 21 5 field . exit then
  ." xmap " dup 21 4 field 0 .r ., dup 16 5 field reg. ., ." c" dup 0 4 field 0 .r ., 11 5 field reg. ;
: dis-sys ( insn op -- )
  case
    $31 of ." twait " 0 16 field h. endof
    $33 of ." tamo " h. endof
    $34 of ." cap-op " h. endof
    $38 of ." csrr " dup 21 5 field reg. ., 0 16 field . endof
    $3A of ." sys " 0 16 field . endof
    ." .word " over h. nip
  endcase ;
: dis ( insn -- )                                \ one instruction
  dup 26 6 field case
    0 of dis-alu endof
    $0A of ." lui  " dup 21 5 field reg. ., 0 16 field 16 sext . endof
    $28 of dis-jal endof
    $29 of dis-jalr endof
    $30 of dis-xfer endof
    $3D of dis-x endof
    $3E of dis-x endof
    dup 1 $0A within if dup >r dis-imm r> else
    dup $20 $26 within if dup >r dis-branch r> else
    dup $10 $1C within if dup >r dis-ldst r> else
    tuck dis-sys then then then
  endcase ;
: disasm ( a u -- )                              \ disassemble u bytes of code at a
  base @ >r hex
  bounds ?do cr i pc !  i 6 u.r ." :  " i code@ dup 8 u.r space space dis 4 +loop cr
  r> base ! ;
: .flags ( nt -- )
  name>flags  dup 1 and if ." immediate " then  dup 2 and if ." inline " then
  dup 8 and if ." created " then  dup 16 and if ." constant " then  dup 32 and if ." value " then
  64 and if ." pages " then ;
: see ( "name" -- )                              \ show a word's machine code
  parse-name 2dup find-name ?dup 0= if type -13 throw then nip nip
  cr ." : " dup name>string type ."   ( xt " dup name>xt h. ." , " dup name>size . ." bytes) " dup .flags
  dup name>size ?dup if over name>xt swap disasm else
    ." kernel code, not described" cr then drop ;
create see.fs                                 \ REQUIRE looks for this name: the file is loaded
