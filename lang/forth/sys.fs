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
\ Under StrataOS a Forth program has about 8 KiB of code space; this file
\ takes some 2.9 KiB of it and 9.2 KiB of the 16 KiB of data space (the
\ buffers of a message and of standard input). The byte loops are code
\ words (core.fs's assembler). It is compiled at every start, after the
\ platform has read the standard handles, so their servers and ids are
\ compiled in as literals. It must not use S" outside definitions: when
\ the pack's head interprets it, sbuf holds the name of the port wanted.

inline-limit @  4 inline-limit !                \ code space: primitives are called, not copied

\ ---- byte loops: code words ----------------------------------------------------------------
: scan ( a u c -- i )                           \ the index of the first byte c, or u (4 instructions a byte)
  [ %t1 %s1 0 addi,  pop,  %t2 %s1 0 addi,  %s1 %zero 0 addi,  %a0 %s0 0 ld,  %s0 %s0 8 addi,
    mark  chere %s1 %t2 0 beq,  %a1 %a0 %s1 add,  %a1 %a1 0 $16 rri,  chere %a1 %t1 0 beq,
    %s1 %s1 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve ] ;
: skip ( a u c -- a' u' )                       \ past the bytes c at the start
  [ %t1 %s1 0 addi,  pop,  %a0 %s0 0 ld,
    mark  chere %s1 %zero 0 beq,  %a1 %a0 0 $16 rri,  chere %a1 %t1 0 bne,  %a0 %a0 1 addi,  %s1 %s1 -1 addi,
    ahead, 3 roll resolve  mark resolve  mark resolve  %a0 %s0 0 sd, ] ;
: digits ( a u -- n k )                         \ the leading decimal digits: their value, how many
  [ %t2 %s1 0 addi,  %a0 %s0 0 ld,  %t0 %zero 0 addi,  %s1 %zero 0 addi,  %t1 %zero 10 addi,
    mark  chere %s1 %t2 0 beq,  %a1 %a0 %s1 add,  %a1 %a1 0 $16 rri,  %a1 %a1 -48 addi,  chere %a1 %t1 0 $25 rri,
    %t0 %t0 %t1 10 rrr,  %t0 %t0 %a1 add,  %s1 %s1 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve
    %t0 %s0 0 sd, ] ;
: atoi ( a u -- n ) digits drop ;               \ the leading number (0 if none)
: num ( a u -- n|-1 ) tuck digits rot over = swap 0<> and 0= if drop -1 then ; \ all digits, else -1
: .u ( u -- ) 0 u.r ;                           \ unsigned decimal
: zlen ( a max -- a u ) over swap 0 scan ;      \ a zero-padded name
: last/ ( a u -- a' u' )                        \ a path's last component (the file's name)
  dup >r begin dup while 2dup + 1- c@ '/' <> while 1- repeat then r> swap /string ;
: arg ( a u -- rest u' word u2 )                \ the next word (separated by spaces); u2 = 0: none
  bl skip 2dup bl scan >r over r@ 2swap r> /string 2swap ;

\ ---- messages: request and reply data are the message buffer's bytes from 64 ---------------
38 kvar constant hdl                            \ standard handles 0..2: server register (3 cells), id (3 cells)
create iob 4096 allot                           \ request data on their way (8-aligned for the transfers)
: >msg ( a u -- )                               \ the request's data, and a zero after them (if there is room)
  4032 min >r iob r@ move  0 iob r@ + c!  iob 64 r> 1+ 4032 min aligned 5 tput ;
: msg> ( buf u -- ) >r 64 r> aligned 5 tget 32 twait ; \ the reply's data -> buf (8-aligned)
: fs ( handle len mode op -- r ) 2 (msg) ;      \ a request to fs
: proc ( handle len mode op -- r ) 1 (msg) ;    \ to proc
: fs-path ( a u mode op -- r ) 2>r tuck >msg 0 swap 2r> fs ; \ an fs request about a path
: open ( a u mode -- id|err ) 3 fs-path ;       \ mode 0 read, 1 write, 2 append; -4 no such file
: close ( id -- ) 0 0 4 fs drop ;
: read ( id buf -- n ) swap 4032 0 1 fs dup 0> if 2dup msg> then nip ; \ the next 4032 bytes at most; 0: the end
: stat ( a u -- size|err ) 0 27 fs-path ;       \ a file's size, or -4
: fs-2path ( a u a2 u2 op -- r )                \ about two paths ("a u", a zero, "a2 u2"): TAG, UNTAG
  >r 2swap 1000 min dup >r iob swap move  0 iob r@ + c! \ (a file, a tag), RENAME (a file, its new path)
  1000 min iob r@ + 1+ swap dup r> + 1+ >r move  iob r@ >msg  0 r> 0 r> fs ;
\ fs answers tags (TAGS2) and files (QUERY) as records of their own lengths: a first cell of
\ u16 record bytes, u16 name length, u32 id (a tag's) or tags (a file's); a second cell (the
\ files carrying a tag; a file's size); the name, padded to a cell.
: rec-next ( rec -- rec' ) dup @ $ffff and + ;
: rec-name ( rec -- a u ) dup 16 + swap @ 16 rshift $ffff and ;
: rec-id ( rec -- u ) @ 32 rshift ;
: tags-of ( a u buf -- n|err )                  \ TAGS2: a file's tags (u = 0: every tag) -> a buffer of
  >r 0 41 fs-path dup 0> if r@ 4032 msg> then rdrop ; \ 4032 bytes: n records (one message's worth)
: write ( a u reg id -- )                       \ all of a u, to a handle: its server, the server's id
  2>r begin dup while  2dup >msg  dup 4032 min  r@ swap 0 2 2r@ drop (msg)     ( a u n )
    dup 0> 0= if drop 2drop 2r> 2drop exit then  /string repeat 2drop 2r> 2drop ;

\ ---- standard error, the exit code, the command line ----------------------------------------
: >err ( a u -- ) flush [ hdl 16 + @ ] literal [ hdl 40 + @ ] literal write ; \ (standard output first)
create eb 256 allot  variable #eb               \ a message being made
: +e ( a u -- ) 250 #eb @ - min tuck eb #eb @ + swap move #eb +! ; \ append to it
: e! ( -- ) 10 eb #eb @ + c!  eb #eb @ 1+ >err  0 #eb ! ; \ end it with a newline and send it
variable status                                 \ the exit code
: stop ( code -- ) status ! -999 throw ;        \ end the program now
: usage ( a u -- ) +e e! 2 stop ;               \ "usage: ..." and exit code 2
: run ( a u xt -- )                             \ run a program's main on its arguments
  0 status !  catch ?dup if dup -999 <> if throw then drop 2drop then ;
: main: ( xt "name" -- )                        \ NAME runs xt on the rest of its line; from the
  create dup ,                                  \ command line (forth NAME.fs ARGS), at once on ARGS
  32 kvar cell+ @ if 32 kvar 2@ swap arg 2drop arg 2drop bl skip rot run  status @ 30 kvar ! bye then
  drop does> @ >r 0 parse bl skip r> run ;

\ ---- standard input, by lines --------------------------------------------------------------
create inb 4032 allot                           \ what was read and not yet used
variable in-pos  variable in-len  variable in-eof
hdl @ 0= in-eof !                               \ (standard input closed: at its end already)
: in-fill ( -- f )                              \ more standard input into inb; false at its end
  in-eof @ if false exit then  0 in-pos !
  [ hdl 24 + @ ] literal 4032 0 1 [ hdl @ ] literal (msg)
  dup 0> if dup in-len ! inb swap msg> true exit then  drop true in-eof ! false ;
: in-take ( buf max n -- buf max n' f )            \ inb's bytes up to a newline (f true) or its end (false)
  [ %t0 %zero in-pos $03 rri,  %a0 %t0 0 ld,  %a1 %zero in-len $03 rri,  %a1 %a1 0 ld, \ -> buf + n, while
    %a2 %zero inb $03 rri,  %t2 %s0 0 ld,  13 %s0 8 ld,  %t1 %zero 10 addi,  15 %zero 0 addi, \ n < max
    mark  chere %a0 %a1 0 beq,  14 %a2 %a0 add,  14 14 0 $16 rri,  %a0 %a0 1 addi,  chere 14 %t1 0 beq,
    chere %s1 %t2 0 $25 rri,  21 13 %s1 add,  14 21 0 $1B rri,  %s1 %s1 1 addi,  ahead,
    4 pick resolve  3 pick resolve  mark resolve  15 %zero -1 addi,  nip mark resolve
    %a0 %t0 0 sd,  push,  %s1 15 0 addi, ] ;
: in-line ( buf max -- u|-1 )                   \ the next line without its newline, cut to max bytes
  in-pos @ in-len @ = if in-fill 0= if 2drop -1 exit then then  0 \ (the rest of a longer one is dropped);
  begin in-take if nip nip exit then  in-fill 0= until nip nip ; \ -1: the end

inline-limit !
: sys.fs ;                                      \ (require sys: loaded)
