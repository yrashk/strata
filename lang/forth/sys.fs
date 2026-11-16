\ =============================================================================
\ sys.fs: what the Forth ports of os/progs share (StrataOS)
\ =============================================================================
\
\ The counterpart of os/lib/sys.s for lang/forth/progs/*.fs, the Forth ports
\ of StrataOS's programs (seq.fs, cat.fs, ls.fs, ...): the command line,
\ standard input by lines, standard error, messages to the file server and
\ to proc, numbers. (The ports are not files of their own but parts of one,
\ progs.pk: progs.fs, its head, explains.)
\
\ A port ends with  ' NAME-main main: NAME  : started as `forth NAME.fs ARGS`
\ it runs NAME-main ( args u -- ) on ARGS and ends the process with its exit
\ code (STATUS; STOP leaves at once); at the Forth prompt, after
\ `include NAME.fs`, the word NAME runs it on the rest of its line.
\
\ Under StrataOS a Forth program has 16 KiB of data space; this file takes
\ about 9.8 KiB of it (mostly the buffers of a message and of standard
\ input) and some 3.9 KiB of code. The byte loops are code words (core.fs's
\ assembler). It is compiled at every start, after the platform has read
\ the standard handles, so their servers and ids are compiled in as
\ literals. It must not use S" outside definitions: when the pack's head
\ interprets it, sbuf holds the name of the port wanted.

inline-limit @  4 inline-limit !                \ code space: primitives are called, not copied

\ ---- byte loops: code words ----------------------------------------------------------------
\ More of the assembler. Registers 13..15 are a3..a5, 21 is s5. A loop's
\ branches out of it are resolved after it, innermost first.
: lbu,  ( rd rs imm -- ) $16 rri, ;             \ rd = the byte at rs + imm
: sb,   ( rv rs imm -- ) $1B rri, ;             \ the byte at rs + imm = rv
: ori,  ( rd rs imm -- ) $03 rri, ;             \ rd = rs | imm (with %zero: a 16-bit address)
: bgeu, ( ra rb off -- ) $25 rri, ;             \ branch if ra >= rb (unsigned)
: mul,  ( rd rs1 rs2 -- ) 10 rrr, ;             \ rd = rs1 * rs2

: scan ( a u c -- i )                           \ the index of the first byte c, or u (4 instructions a byte)
  [ %t1 %s1 0 addi,  pop,  %t2 %s1 0 addi,  %s1 %zero 0 addi,  %a0 %s0 0 ld,  %s0 %s0 8 addi,
    mark  chere %s1 %t2 0 beq,                  \ at the end: i = u
    %a1 %a0 %s1 add,  %a1 %a1 0 lbu,  chere %a1 %t1 0 beq, \ found
    %s1 %s1 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve ] ;
: skip ( a u c -- a' u' )                       \ past the bytes c at the start
  [ %t1 %s1 0 addi,  pop,  %a0 %s0 0 ld,
    mark  chere %s1 %zero 0 beq,                \ none left
    %a1 %a0 0 lbu,  chere %a1 %t1 0 bne,        \ another byte
    %a0 %a0 1 addi,  %s1 %s1 -1 addi,
    ahead, 3 roll resolve  mark resolve  mark resolve  %a0 %s0 0 sd, ] ;
: digits ( a u -- n k )                         \ the leading decimal digits: their value, how many
  [ %t2 %s1 0 addi,  %a0 %s0 0 ld,  %t0 %zero 0 addi,  %s1 %zero 0 addi,  %t1 %zero 10 addi,
    mark  chere %s1 %t2 0 beq,                  \ at the end
    %a1 %a0 %s1 add,  %a1 %a1 0 lbu,  %a1 %a1 -48 addi,  chere %a1 %t1 0 bgeu, \ not a digit
    %t0 %t0 %t1 mul,  %t0 %t0 %a1 add,  %s1 %s1 1 addi,
    ahead, 3 roll resolve  mark resolve  mark resolve  %t0 %s0 0 sd, ] ;

\ ---- strings and numbers --------------------------------------------------------------------
: atoi ( a u -- n ) digits drop ;               \ the leading number (0 if none)
: num ( a u -- n|-1 )                           \ a u all digits: their value, else -1
  tuck digits ( u n k )  rot over =  swap 0<> and  0= if drop -1 then ;
: .u ( u -- ) 0 u.r ;                           \ unsigned decimal
: hex. ( u digits -- ) base @ >r hex  <# 0 ?do # loop #> type  r> base ! ; \ zero-padded hex
: ?type ( f a u -- ) rot if type else 2drop then ; \ the text, if f
: type-pad ( a u width -- ) over - 1 max -rot type spaces ; \ the text, then spaces to width (one at least)
: zlen ( a max -- a u ) over swap 0 scan ;      \ a zero-padded name
: last-char ( a u -- c ) + 1- c@ ;
: last/ ( a u -- a' u' )                        \ a path's last component (the file's name)
  dup >r  begin dup while 2dup last-char '/' <> while 1- repeat then  r> swap /string ;
: split-at ( a u i -- rest u' a i )             \ a u cut after its first i bytes
  >r 2dup r@ /string 2swap drop r> ;
: arg ( a u -- rest u' word u2 )                \ the next word (separated by spaces); u2 = 0: none
  bl skip  2dup bl scan split-at ;

\ ---- messages: request and reply data are the message buffer's bytes from 64 ---------------
\ (msg) ( handle len mode op reg -- r ) is one request (forth.s); its data
\ move with transfers through c5, the message buffer, from byte 64 on.
4032 constant /msg                              \ the data a message holds, at most
1 constant op-read    2 constant op-write       \ the file server's requests (os/spec/fs.toml)
3 constant op-open    4 constant op-close       \ that more than one port makes
12 constant op-tag    13 constant op-untag
27 constant op-stat   41 constant op-tags2
16 constant op-info                             \ proc's INFO (os/spec/proc.toml)
create iob 4096 allot                           \ request data on their way (8-aligned for the transfers)
: >msg ( a u -- )                               \ the request's data, and a zero after them (if there is room)
  /msg min >r  iob r@ move  0 iob r@ + c!  iob 64 r> 1+ /msg min aligned 5 tput ;
: msg@ ( buf off u -- ) 5 tget 32 twait ;       \ u bytes of the message buffer from off -> buf
: msg> ( buf u -- ) 64 swap aligned msg@ ;      \ the reply's data -> buf (8-aligned)
: fs ( handle len mode op -- r ) 2 (msg) ;      \ a request to fs
: proc ( handle len mode op -- r ) 1 (msg) ;    \ to proc
: fs-path ( a u mode op -- r ) 2>r tuck >msg 0 swap 2r> fs ; \ an fs request about a path
: open ( a u mode -- id|err ) op-open fs-path ; \ mode 0 read, 1 write, 2 append; -4 no such file
: close ( id -- ) 0 0 op-close fs drop ;
: read ( id buf -- n )                          \ the next 4032 bytes at most; 0: the end
  swap /msg 0 op-read fs  dup 0> if 2dup msg> then nip ;
: stat ( a u -- size|err ) 0 op-stat fs-path ;  \ a file's size, or -4
: name>iob ( a u off -- off' )                  \ a name (1000 bytes at most) into iob at off
  >r 1000 min tuck iob r@ + swap move r> + ;
: fs-2path ( a u a2 u2 op -- r )                \ about two paths ("a u", a zero, "a2 u2"): TAG, UNTAG
  >r 2swap 0 name>iob  0 over iob + c!  1+ name>iob \ (a file, a tag), RENAME (a file, its new path)
  iob over >msg  0 swap 0 r> fs ;
\ fs answers tags (TAGS2) and files (QUERY) as records of their own lengths: a first cell of
\ u16 record bytes, u16 name length, u32 id (a tag's) or tags (a file's); a second cell (the
\ files carrying a tag; a file's size); the name, padded to a cell.
: rec-next ( rec -- rec' ) dup @ $ffff and + ;
: rec-name ( rec -- a u ) dup 16 + swap @ 16 rshift $ffff and ;
: rec-id ( rec -- u ) @ 32 rshift ;             \ a tag's id; how many tags a file has
: rec-num ( rec -- u ) 8 + @ ;                  \ the files carrying a tag; a file's size
: tags-of ( a u buf -- n|err )                  \ TAGS2: a file's tags (u = 0: every tag) -> a buffer of
  -rot 0 op-tags2 fs-path  dup 0> if over /msg msg> then nip ; \ 4032 bytes: n records (one message's worth)
: write-part ( a u reg id -- n )                \ one WRITE of 4032 bytes at most: how many went
  2swap /msg min tuck >msg  rot >r 0 op-write r> (msg) ;
: write ( a u reg id -- )                       \ all of a u, to a handle: its server, the server's id
  2>r begin dup while 2dup 2r@ write-part dup 0> while /string repeat drop then  2drop 2r> 2drop ;

\ ---- standard error, the exit code, the command line ----------------------------------------
38 kvar constant hdl                            \ standard handles 0..2: server register (3 cells), id (3 cells)
: handle-reg ( n -- reg ) cells hdl + @ ;
: handle-id ( n -- id ) 3 + cells hdl + @ ;
: >err ( a u -- )                               \ (standard output first)
  flush [ 2 handle-reg ] literal [ 2 handle-id ] literal write ;
create eb 256 allot  variable #eb               \ a message being made
: eb-end ( -- a ) eb #eb @ + ;
: +e ( a u -- ) 250 #eb @ - min  tuck eb-end swap move  #eb +! ; \ append to it
: e! ( -- ) 10 eb-end c!  eb #eb @ 1+ >err  0 #eb ! ; \ end it with a newline and send it
variable status                                 \ the exit code
: stop ( code -- ) status ! -999 throw ;        \ end the program now
: usage ( a u -- ) +e e! 2 stop ;               \ "usage: ..." and exit code 2
: fail ( a u -- ) +e e! 1 stop ;                \ an error message and exit code 1
: complain ( name u a u2 -- ) +e +e e! 1 status ! ; \ "a: name", exit code 1, and go on
: run ( a u xt -- )                             \ run a program's main on its arguments
  0 status !  catch ?dup if dup -999 <> if throw then drop 2drop then ;
: cmdline ( -- a u ) 32 kvar 2@ swap ;          \ "forth NAME.fs ARGS"; u = 0 at the Forth prompt
: main: ( xt "name" -- )                        \ NAME runs xt on the rest of its line; from the
  create dup ,                                  \ command line (forth NAME.fs ARGS), at once on ARGS
  cmdline nip if
    cmdline arg 2drop arg 2drop bl skip  rot run  status @ 30 kvar ! bye
  then drop
  does> @  0 parse bl skip  rot run ;

\ ---- standard input, by lines --------------------------------------------------------------
create inb 4032 allot                           \ what was read and not yet used
variable in-pos  variable in-len  variable in-eof
0 handle-reg 0= in-eof !                        \ (standard input closed: at its end already)
: in-fill ( -- f )                              \ more standard input into inb; false at its end
  in-eof @ if false exit then  0 in-pos !
  [ 0 handle-id ] literal /msg 0 op-read [ 0 handle-reg ] literal (msg)
  dup 0> if dup in-len ! inb swap msg> true exit then  drop true in-eof ! false ;
: in-take ( buf max n -- buf max n' f )         \ inb's bytes up to a newline (f true) or its end (false)
  [ %t0 %zero in-pos ori,  %a0 %t0 0 ld,        \ a0 = in-pos, t0 its address
    %a1 %zero in-len ori,  %a1 %a1 0 ld,  %a2 %zero inb ori, \ a1 = in-len, a2 = inb
    %t2 %s0 0 ld,  13 %s0 8 ld,  %t1 %zero 10 addi,  15 %zero 0 addi, \ t2 = max, a3 = buf, a5 = f
    mark  chere %a0 %a1 0 beq,                  \ inb used up
    14 %a2 %a0 add,  14 14 0 lbu,  %a0 %a0 1 addi,  chere 14 %t1 0 beq, \ a newline
    chere %s1 %t2 0 bgeu,                       \ buf full: the byte is dropped
    21 13 %s1 add,  14 21 0 sb,  %s1 %s1 1 addi,  ahead,
    4 pick resolve  3 pick resolve              \ (both back to the loop)
    mark resolve  15 %zero -1 addi,  nip mark resolve \ newline: f true; used up: f false
    %a0 %t0 0 sd,  push,  %s1 15 0 addi, ] ;
: in-used? ( -- f ) in-pos @ in-len @ = ;
: in-line ( buf max -- u|-1 )                   \ the next line without its newline, cut to max bytes
  in-used? if in-fill 0= if 2drop -1 exit then then  0 \ (the rest of a longer one is dropped);
  begin in-take if nip nip exit then  in-fill 0= until nip nip ; \ -1: the end

inline-limit !
: sys.fs ;                                      \ (require sys: loaded)
