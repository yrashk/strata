\ =============================================================================
\ core.fs: the rest of Strata Forth, written in Forth
\ =============================================================================
\
\ The kernel (forth.s) gives us the interpreter, the native-code compiler,
\ about 150 primitives and a handful of code-generation words:
\
\   insn,   ( u -- )        compile one machine instruction
\   mark    ( -- dest )     the current code address, as a branch target
\   if,     ( -- orig )     compile "pop; branch forward if zero"
\   ahead,  ( -- orig )     compile "jump forward"
\   resolve ( orig dest -- ) aim the branch at orig to dest
\   prologue, epilogue,     save / restore the return address
\   slit, dotq, ( addr u -- ) compile "push this string" / "print this string"
\   (local) local?          declare / look up locals
\   xexec   ( a0 a1 a2 insn -- a0' )  run one instruction built at run time
\
\ Everything else is built here: control structures (using a small
\ assembler written below), defining words, strings, number formatting,
\ .s and the Strata words for memory tiers, capabilities and cores. This file
\ is embedded in the image's far section and compiled at start-up, a line
\ per transfer. The tools (words, dump, .caps, .jit, .fcache: tools.fs; the
\ disassembler and see: see.fs) follow it on bare metal; under StrataOS,
\ where code space is 32 KiB, they are files loaded on demand (os/os.fs).

\ ---- kernel variables and constants ----------------------------------------------
0 kvar constant state                   \ STATE: nonzero while compiling
1 kvar constant base                    \ BASE: the number base
2 kvar constant >in                     \ >IN: parse position in the input buffer
7 kvar constant source-id-var           \ 0 console, -1 a string, 1 far text
8 constant cell                         \ bytes per cell
-8 constant -cell                       \ minus that
-1 constant true                        \ the canonical true flag
0 constant false                        \ and false
32 constant bl                          \ a space
$9800 constant dict-limit               \ data space ends where the data stack starts

: source-id ( -- n ) source-id-var @ ;  \ where the input comes from
: decimal ( -- ) 10 base ! ;            \ numbers in decimal
: hex ( -- ) 16 base ! ;                \ numbers in hex
: cr ( -- ) 10 emit ;                   \ a newline
: space ( -- ) bl emit ;                \ a space
: char+ ( a -- a+1 ) 1+ ;               \ next character
: aligned ( a -- a' ) 7 + -8 and ;      \ round up to a cell boundary
: ['] ( "name" -- ) ' postpone literal ; immediate \ compile an xt as a literal
: char ( "c" -- c ) parse-name drop c@ ; \ the first character of the next word
: [char] ( "c" -- ) char postpone literal ; immediate \ ... compiled
: abort ( -- ) -1 throw ;               \ back to the interpreter, silently
: variable ( "name" -- ) create 0 , ;           \ a cell
: 2variable ( "name" -- ) create 0 , 0 , ;      \ two cells

\ ---- control structures ------------------------------------------------------------
\ Every one of them is a few compiled instructions, assembled here.
: if ( -- orig ) if, ; immediate        \ pop, branch ahead if zero
: ahead ( -- orig ) ahead, ; immediate  \ branch ahead always
: then ( orig -- ) mark resolve ; immediate \ the branch lands here
: else ( orig -- orig2 ) ahead, swap mark resolve ; immediate \ jump over the else part
: begin ( -- dest ) mark ; immediate    \ a loop starts here
: until ( dest -- ) if, swap resolve ; immediate \ loop back while zero
: again ( dest -- ) ahead, swap resolve ; immediate \ loop back always
: while ( dest -- orig dest ) if, swap ; immediate \ leave the loop when zero
: repeat ( orig dest -- ) ahead, swap resolve mark resolve ; immediate \ back, and the exit lands here

\ ---- a small assembler (just what the compiler words below need) -------------------
0 constant %zero   1 constant %ra   2 constant %sp      \ register numbers
5 constant %t0     6 constant %t1   7 constant %t2      \ scratch
8 constant %s0     9 constant %s1                       \ data stack pointer, top of stack
18 constant %s2    19 constant %s3  20 constant %s4     \ loop index, loop limit, locals frame
10 constant %a0    11 constant %a1  12 constant %a2     \ xexec operands

: rri, ( rd rs imm op -- )              \ an I-type instruction
  26 lshift >r  $ffff and  swap 16 lshift or  swap 21 lshift or  r> or insn, ;
: rrr, ( rd rs1 rs2 funct -- )          \ an ALU register-register instruction
  >r  11 lshift  swap 16 lshift or  swap 21 lshift or  r> or insn, ;
: addi, ( rd rs imm -- ) $01 rri, ;     \ rd = rs + imm
: ld,   ( rd rs imm -- ) $10 rri, ;     \ rd = [rs + imm]
: sd,   ( rv rs imm -- ) $18 rri, ;     \ [rs + imm] = rv
: beq,  ( ra rb off -- ) $20 rri, ;     \ branch if equal (offset set by resolve)
: bne,  ( ra rb off -- ) $21 rri, ;     \ branch if not equal
: bge,  ( ra rb off -- ) $23 rri, ;     \ branch if ra >= rb (signed)
: add,  ( rd rs1 rs2 -- ) 0 rrr, ;      \ rd = rs1 + rs2
: sub,  ( rd rs1 rs2 -- ) 1 rrr, ;      \ rd = rs1 - rs2
: and,  ( rd rs1 rs2 -- ) 2 rrr, ;      \ rd = rs1 & rs2
: xor,  ( rd rs1 rs2 -- ) 4 rrr, ;      \ rd = rs1 ^ rs2
: pop,  ( -- ) %s1 %s0 0 ld,  %s0 %s0 8 addi, ; \ drop the top of stack
: push, ( -- ) %s0 %s0 -8 addi,  %s1 %s0 0 sd, ; \ make room for a new top

\ ---- counted loops: DO ... LOOP keeps the index in s2 and the limit in s3 -----------
create leave-stack 32 cells allot       \ forward branches of LEAVE, per loop
variable leaves                         \ top of that stack
leave-stack leaves !                    \ empty
: >leave ( orig -- ) leaves @ !  cell leaves +! ; \ remember a LEAVE branch
: resolve-leaves ( mark -- )            \ aim every LEAVE of this loop here
  begin leaves @ over <> while  -cell leaves +!  leaves @ @ mark resolve  repeat drop ;
: do-setup, ( -- )                      \ save the outer loop's registers, load ours
  %sp %sp -16 addi,  %s2 %sp 0 sd,  %s3 %sp 8 sd,
  %s3 %s0 0 ld,  %s2 %s1 0 addi,  %s1 %s0 8 ld,  %s0 %s0 16 addi, ;
: unloop, ( -- ) %s2 %sp 0 ld,  %s3 %sp 8 ld,  %sp %sp 16 addi, ; \ restore the outer loop's
: do ( -- mark dest ) do-setup,  leaves @  mark ; immediate
: ?do ( -- mark dest )                  \ like DO, but skip the loop if index = limit
  do-setup,  leaves @  chere %s2 %s3 0 beq, >leave  mark ; immediate
: loop ( mark dest -- )                 \ index + 1; back while it differs from the limit
  %s2 %s2 1 addi,  chere %s2 %s3 0 bne,  swap resolve  resolve-leaves unloop, ; immediate
: +loop ( mark dest -- )                \ index + n; leave when it crosses limit-1 | limit
  %t0 %s2 %s3 sub,  %s2 %s2 %s1 add,  %t1 %s2 %s3 sub,  %t1 %t1 %t0 xor,
  %t2 %t0 %s1 xor,  %t1 %t1 %t2 and,  pop,
  chere %t1 %zero 0 bge,  swap resolve  resolve-leaves unloop, ; immediate
: leave ( -- ) ahead, >leave ; immediate \ jump to the end of the loop

\ ---- more stack and arithmetic words -------------------------------------------------
: 2@ ( addr -- x1 x2 ) dup cell+ @ swap @ ;     \ two cells
: 2! ( x1 x2 addr -- ) swap over ! cell+ ! ;    \ ...
: ? ( addr -- ) @ . ;                           \ print a variable
: within ( x lo hi -- f ) over - >r - r> u< ;   \ lo <= x < hi
: */ ( a b c -- a*b/c ) >r * r> / ;             \ (64-bit intermediate)
: */mod ( a b c -- rem quot ) >r * r> /mod ;    \ ...
: u/mod ( u1 u2 -- rem quot ) 2dup umod -rot u/ ; \ unsigned
: roll ( xu .. x0 u -- xu-1 .. x0 xu )          \ rotate u+1 items
  ?dup if swap >r 1- recurse r> swap then ;
: bounds ( a u -- a+u a ) over + swap ;         \ for DO over a buffer
: erase ( a u -- ) 0 fill ;                     \ zero bytes
: blank ( a u -- ) bl fill ;                    \ spaces
: cmove ( src dst u -- ) move ;                 \ (MOVE is overlap-safe)
: cmove> ( src dst u -- ) move ;                \ ...
: count ( c-addr -- a u ) dup 1+ swap c@ ;      \ a counted string
: /string ( a u n -- a+n u-n ) rot over + -rot - ; \ drop n characters
: unused ( -- n ) dict-limit here - ;           \ data space left
: buffer: ( u "name" -- ) create allot ;        \ a named buffer
: >body ( xt -- addr ) xt>name dup 10 + c@ + 11 + aligned ; \ data field of a CREATEd word
: defer ( "name" -- ) create ['] abort , does> @ execute ; \ a changeable word
: defer! ( xt deferred-xt -- ) >body ! ;       \ change it
: defer@ ( deferred-xt -- xt ) >body @ ;        \ what it does now
: is ( xt "name" -- )                           \ change a deferred word
  state @ if postpone ['] postpone defer! else ' defer! then ; immediate
: action-of ( "name" -- xt )                    \ what a deferred word does
  state @ if postpone ['] postpone defer@ else ' defer@ then ; immediate

\ ---- CASE -----------------------------------------------------------------------------
: case ( -- 0 ) 0 ; immediate                   \ count of OFs
: of ( n -- n+1 orig )                          \ compare, drop, run the part on a match
  1+ >r postpone over postpone = postpone if postpone drop r> ; immediate
: endof ( orig n -- orig2 n ) >r postpone else r> ; immediate \ jump to ENDCASE
: endcase ( orig.. n -- )                        \ drop the selector; every ENDOF lands here
  postpone drop 0 ?do postpone then loop ; immediate

\ ---- strings ----------------------------------------------------------------------------
: s, ( addr u -- ) here over allot swap move ;  \ copy a string into data space
: >data ( addr u -- addr' u ) here over 2>r s, align 2r> ; \ a copy of the string in data space
: (sliteral) ( addr u -- ) >data slit, ;        \ compile: the copy's address and length, pushed
: sliteral ( addr u -- ) (sliteral) ; immediate \ ... (code cannot be read as data)
create sbuf 256 allot                           \ interpreted S" strings go here
: >sbuf ( addr u -- addr' u ) 255 min >r sbuf r@ move sbuf r> ; \ ...
: s" ( "ccc<quote>" -- addr u )                 \ a string literal
  [char] " parse state @ if (sliteral) else >sbuf then ; immediate
: ." ( "ccc<quote>" -- )                        \ print a string
  [char] " parse state @ if >data dotq, else type then ; immediate
: .( ( "ccc<paren>" -- ) [char] ) parse type ; immediate \ print now
: (abort") ( addr u -- ) 3 kvar tuck cell+ ! !  -2 throw ; \ ABORT" with a message
: abort" ( flag "ccc<quote>" -- )               \ abort with a message if flag
  postpone if postpone s" postpone (abort") postpone then ; immediate
: compare ( a1 u1 a2 u2 -- n )                  \ -1, 0, 1 like strcmp
  rot 2dup 2>r min 0 ?do
    over i + c@ over i + c@ - ?dup if
      nip nip 0< 2* 1+ unloop 2r> 2drop exit then
  loop 2drop 2r> swap - dup if 0< 2* 1+ then ;
: str= ( a1 u1 a2 u2 -- f ) compare 0= ;        \ equal strings?
: -trailing ( a u -- a u' )                     \ drop trailing spaces
  begin dup while 2dup + 1- c@ bl = while 1- repeat then ;
: spaces ( n -- ) begin dup 0> while space 1- repeat drop ; \ n spaces

\ ---- number formatting (single cells) ---------------------------------------------------
create holdbuf 80 allot                         \ digits are built right to left
variable hld                                    \ the next free place
: <# ( -- ) holdbuf 80 + hld ! ;                \ start
: hold ( c -- ) -1 hld +!  hld @ c! ;           \ add a character in front
: holds ( a u -- ) begin dup while 1- 2dup + c@ hold repeat 2drop ; \ a string in front
: digit ( n -- c ) dup 10 < if [char] 0 else [char] a 10 - then + ; \ 0..9 a..z
: # ( u -- u' ) base @ 2dup umod digit hold u/ ; \ one digit
: #s ( u -- 0 ) begin # dup 0= until ;          \ all digits
: #> ( u -- addr len ) drop hld @ holdbuf 80 + over - ; \ the result
: sign ( n -- ) 0< if [char] - hold then ;      \ a minus if negative
: u.r ( u width -- ) >r <# #s #> r> over - spaces type ; \ right-aligned unsigned
: .r ( n width -- ) >r dup abs <# #s swap sign #> r> over - spaces type ; \ right-aligned
: h. ( u -- ) base @ >r hex ." $" <# #s #> type space r> base ! ; \ hex, whatever BASE is
: .s ( -- )                                     \ show the stack, deepest first
  ." <" depth 0 .r ." > " depth 0 ?do depth i - 1- pick . loop ;

\ ---- conditional compilation (within one line or one evaluated string) -----------------
: [else] ( -- )                                 \ skip to the matching [then]
  1 begin parse-name dup while
    2dup s" [if]" str= if 2drop 1+ else
    2dup s" [else]" str= if 2drop 1- dup if 1+ then else
    s" [then]" str= if 1- then then then
    dup 0= if drop exit then
  repeat 2drop drop ; immediate
: [if] ( flag -- ) 0= if postpone [else] then ; immediate \ skip unless flag
: [then] ( -- ) ; immediate                     \ nothing to do
: [defined] ( "name" -- f ) parse-name find-name 0<> ; immediate

\ ---- locals and quotations --------------------------------------------------------------
\ { a b c -- comment }  takes three values off the stack into locals a b c
\ (c from the top). Locals live in a frame on the return stack, addressed
\ from s4; reading one compiles "push; ld s1, 8i(s4)", TO compiles a store.
: { ( "names --  }" -- )
  0 begin
    parse-name
    2dup s" }" str= if 2drop true else
    2dup s" --" str= if 2drop [char] } parse 2drop true else
    (local) 1+ false then then
  until
  >r  %sp %sp r@ 1+ cells negate addi,          \ the frame: n locals and the old s4
  %s4 %sp r@ cells sd,  %s4 %sp 0 addi,         \ save s4, point it at the frame
  0 r> 1- do  %s1 %s4 i cells sd,  pop,  -1 +loop ; immediate \ take the values, top last
: to ( x "name" -- )                            \ store into a VALUE or a local
  parse-name 2dup local? if nip nip  %s1 %s4 rot cells sd,  pop,  exit then
  2dup find-name ?dup 0= if type -13 throw then nip nip
  dup 10 + c@ + 11 + aligned                    \ its data field
  state @ if postpone literal postpone ! else ! then ; immediate
: [: ( -- orig old-xt quot-xt )                 \ start a quotation inside a definition
  ahead,  19 kvar @  mark dup 19 kvar !  prologue, ; immediate
: ;] ( orig old-xt quot-xt -- )                 \ end it: its xt becomes a literal
  epilogue,  swap 19 kvar !  swap mark resolve  postpone literal ; immediate

\ ---- the dictionary ------------------------------------------------------------------------
\ Header layout (forth.s): +0 link, +2 hash link, +4 xt, +6 code size (u16),
\ +8 flags, +9 fold kind, +10 name length (u8), +11 the name.
: name>string ( nt -- addr u ) dup 11 + swap 10 + c@ ; \ the name
: name>xt ( nt -- xt ) 4 + w@ ;                 \ the code address
: name>size ( nt -- u ) 6 + w@ ;                \ code bytes (inline body for primitives)
: name>flags ( nt -- f ) 8 + c@ ;               \ flags
: name>link ( nt -- nt' ) w@ ;                  \ the next older word
: immediate? ( nt -- f ) name>flags 1 and 0<> ; \ ...
: timeit ( xt -- )                              \ run it and show what it cost
  cycles >r instret >r execute instret r> - cycles r> -
  ." [" . ." cycles, " . ." instructions]" ;

\ ---- memory tiers, capabilities, transfers ------------------------------------------------
\ A Strata instruction names its capability register and transfer tag in
\ immediate fields. These words assemble the exact instruction and run it
\ with XEXEC (a trampoline in the I-LS, installed by tput + tgetx and cached).
\ A transfer through capability register cN uses tag tgN.
: xfer ( c# sub -- insn )                        \ tget/tput/tgetx tgN, a0, cN, a1, a2
  23 lshift $30 26 lshift or  over 19 lshift or  swap 10 lshift or
  %a0 14 lshift or  %a1 5 lshift or  %a2 or ;
: tget ( dls off len c# -- ) 0 xfer xexec drop ; \ far -> D-LS, returns at once
: tput ( dls off len c# -- ) 1 xfer xexec drop ; \ D-LS -> far, returns at once
: tag ( c# -- mask ) 1 swap lshift ;             \ the tag mask of cN's transfers
: twait ( mask -- ) >r 0 0 0 r> $ffff and $31 26 lshift or xexec drop ; \ wait for them
: tpoll ( mask -- busy ) >r 0 0 0 r> $ffff and $32 26 lshift or %a0 21 lshift or xexec ;
: tany ( mask -- ready )                         \ wait for any (bit 16: a capability arrived)
  0 0 $36 26 lshift %a0 21 lshift or %a0 16 lshift or xexec ;
: capop ( rd rs1 rs2 fn -- insn )                \ a capability instruction
  swap 11 lshift or  swap 16 lshift or  swap 21 lshift or  $34 26 lshift or ;
: cap1 ( a2 insn -- a0 ) >r 0 0 rot r> xexec ;  \ run it with a2 set
: csplit ( cs off cd -- ) rot %a2 1 capop cap1 drop ; \ cs keeps [0,off), cd gets the rest
: cjoin ( cd cs -- ) 0 2 capop 0 swap cap1 drop ; \ cd absorbs the adjacent cs
: cmov ( cs cd -- ) swap 0 0 capop 0 swap cap1 drop ; \ move (copy if duplicable)
: cshare ( cs cd -- ) swap 0 3 capop 0 swap cap1 drop ; \ a duplicable read-only share
: catomic ( cs cd -- ) swap 0 4 capop 0 swap cap1 drop ; \ an atomics-only, duplicable cap
: crestrict ( c# perms -- ) swap dup %a2 5 capop cap1 drop ; \ keep only these permissions
: cbase ( c# -- base ) %a0 swap 0 6 capop 0 swap cap1 ; \ where it starts
: clen ( c# -- len ) %a0 swap 0 7 capop 0 swap cap1 ;   \ how long
: cperms ( c# -- space<<8|perms ) %a0 swap 0 8 capop 0 swap cap1 ; \ what it is
: cvalid ( c# -- f ) %a0 swap 0 14 capop 0 swap cap1 0<> ; \ does it hold anything?
: cclear ( c# -- ) 0 0 11 capop 0 swap cap1 drop ; \ drop it
: give ( c# core -- ) ?threads >r 0 swap %a2 9 capop r> swap cap1 drop ; \ cgive to another core
: take ( c# core -- ) ?threads (reclaim) >r 0 %a2 26 capop r> swap cap1 drop ; \ ctake from that core
: tamo ( addr operand c# fn -- old )             \ a far atomic on capability c#
  swap 7 lshift or  %a0 21 lshift or  %a1 16 lshift or  %a2 11 lshift or  $33 26 lshift or
  >r 0 -rot r> xexec ;
: atomic@ ( addr c# -- x ) 0 swap 0 tamo ;       \ read (an add of 0)
: atomic+! ( n addr c# -- ) rot swap 0 tamo drop ; \ add
: atomic! ( x addr c# -- ) rot swap 1 tamo drop ; \ swap in
: csr@ ( csr# -- x ) >r 0 0 0 r> $38 26 lshift or %a0 21 lshift or xexec ; \ read any CSR
21 kvar @ constant heap-cap                      \ the capability behind far@ / far! (c8 bare metal, c6 StrataOS)
11 23 kvar @ 4 * - constant tmp-cap              \ a capability register free for programs (c11; c7 under StrataOS)
: far-size ( -- u ) heap-cap clen ;              \ bytes of far heap
: far-read ( dls far u -- ) heap-cap tget ;      \ bulk: heap -> D-LS (8-aligned)
: far-write ( dls far u -- ) heap-cap tput ;     \ bulk: D-LS -> heap
: fcache-reset ( -- ) 5 kvar 3 cells erase ;     \ zero the far cache's counters (.fcache shows them)

\ ---- the JIT, made visible ----------------------------------------------------------------
: jit-trace ( flag -- ) 24 kvar ! ;              \ report every code install
36 kvar constant inline-limit                    \ primitives of up to this many code bytes are copied inline (16)

\ ---- cores ------------------------------------------------------------------------------
\ spawn ( x1..xn n xt core -- )  run xt on a worker core with n arguments
\ await ( core -- y1..ym )       its final data stack (top 8 cells)
\ A worker gets the image (code + a snapshot of data space) by being lent
\ capability c0 (StrataOS: a parcel cut from it), and the job through the
\ board; see forth.s.
: workers ( -- n ) cores 1- ;                    \ cores other than 0
: run-on ( xt core -- results ) 0 -rot dup >r spawn r> await ; \ run, wait
: par ( xt -- )                                  \ run xt ( core -- ) on every worker, wait for all
  cores 1 ?do i 1 2 pick i spawn loop drop
  cores 1 ?do i await loop ;

: : ( "name" -- ) leave-stack leaves ! : ;     \ a fresh LEAVE stack for every definition
: :noname ( -- xt ) leave-stack leaves ! :noname ;
