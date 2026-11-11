\ =============================================================================
\ vi-text.fs: vi.fs, part 1: data, the text, keys, highlighting, drawing
\ =============================================================================
\ Included by vi.fs (which describes the editor); not a program of its own.

\ ==== overlay 1: the data, the keyword tables, the messages =======================================
\ Everything that is only data is here: the stubs of variables are code, and
\ compiled code never runs them (it uses their addresses), so they need not
\ take resident code space.
overlay
2048 constant chsz                              \ bytes per chunk of text
1000 constant lmax                              \ the longest line
$40000000 constant bigcol                       \ "the end of the line" for j and k after $
$1400 constant f-y   $c000 constant ysz         \ the far heap: keyword tables at 0, messages at $1000,
$d400 constant f-u   $18000 constant usz        \ the register, the undo history,
$25400 constant f-t                             \ and the text (chunks) from here
heap-cap tag constant htag                      \ the heap's transfers' tag mask
38 kvar constant hdl                            \ standard handles 0..2: server register, then the ids
variable cols  variable rows  variable trows variable tcols  variable numw
variable nl    variable cy    variable cx    variable want   variable setw  variable dcur
variable top   variable lcol  variable ins   variable syn    variable synon
variable dirty variable dall  variable clear variable con    variable quit
variable cnt   variable cnt1  variable chg   variable rep
variable nch   variable nfree variable cidx  variable cdirty variable nchmax
variable f-c   variable f-b   variable f-o   variable f-len  variable lc-n
variable lblive variable lblen
variable u-end variable u-top variable u-rec variable u-w    variable u-ok  variable u-saved
variable chg-a variable chg-n variable chg-y variable chg-x
variable y-kind variable y-cnt
variable kb-pos variable kb-len variable k-pend
variable rq-pos variable rq-len variable dotn variable rec-len variable dot-len
variable msgl  variable patl  variable sdir  variable fnl    variable hs-n  variable hs-s
variable mv-y  variable mv-x  variable mv-w  variable p-y    variable p-x
variable x-bang variable x-arg variable x-argl
create ctab 200 8 * allot                       \ the chunks in order: u16 store number, u16 bytes, u32 lines
create fstk 200 allot                           \ store numbers that are free (a stack)
create cbuf chsz 16 + allot                     \ the chunk in the D-LS
create lbuf lmax 8 + allot                      \ a line being edited
create tbuf lmax 16 + allot                     \ a line to or from far memory: u64 length, the bytes; file
tbuf constant cls                               \   data; and (while drawing) the class of each byte
create cmdbuf 344 allot                         \ the : line; while drawing, keyword entries
create kbuf 64 allot                            \ input bytes read
create recbuf 128 allot                         \ the keys of the command (16 bits each, 64 at most)
create dotbuf 128 allot                         \ the keys of the last change
create patbuf 128 allot  create fname 128 allot  create msgbuf 128 allot
create rowst 64 allot                           \ Forth: the ( state at the start of each text row
create hdrb 48 allot                            \ an undo record's header
create ctype 256 allot                          \ byte types: 1 letter or _, 2 digit, 4 ".", 8 "$",
: ct! ( type from to -- ) 1+ swap ?do dup ctype i + c! loop drop ; \ 16 blank, 32 capital, 64 "_"
ctype 256 erase  1 'a' 'z' ct!  33 'A' 'Z' ct!  2 '0' '9' ct!  65 '_' '_' ct!
4 '.' '.' ct!  8 '$' '$' ct!  16 bl bl ct!  16 9 9 ct!
create sgrtab                                   \ the site's colours (site/hl.css) as SGR codes, by class
  39 c, 90 c, 97 c, 92 c, 96 c, 94 c, 95 c, 33 c, 93 c, 31 c, 91 c, 36 c, 34 c, 37 c, 93 c, 91 c,
  32 c, 35 c, 31 c, 97 c, 95 c, 34 c, 33 c, 93 c,
create tildes 0 c, 5 c, 0 c, 7 c, 6 c, 8 c, 9 c, 5 c, 6 c, \ ESC [ n ~: the key - $100
create kmap 'k' c, 'j' c, 'l' c, 'h' c, '0' c, '$' c, 'x' c, 2 c, 6 c, $1c c, \ $101.. in normal mode
create brk '(' c, ')' c, '[' c, ']' c, '{' c, '}' c, \ what % matches
far-size f-t - chsz / 200 min nchmax !          \ the chunks the heap has room for
: size-upd ( -- ) rows @ 1- trows !  cols @ numw @ - tcols !  1 dall ! ;
: set-size ( rows cols -- )                     \ the terminal's size, from its report
  dup 20 < 2 pick 3 < or if 2drop exit then  250 min cols !  62 min rows !  1 clear !  size-upd ;
: lbu, ( rd rs imm -- ) $16 rri, ;             \ (more of the assembler, for the code words below:
: andi, ( rd rs imm -- ) $02 rri, ;            \   a byte load, and, or with an immediate)
: ori, ( rd rs imm -- ) $03 rri, ;
: or, ( rd rs1 rs2 -- ) 3 rrr, ;
: sub, ( rd rs1 rs2 -- ) 1 rrr, ;
: blt, ( ra rb off -- ) $22 rri, ;
13 constant %a3  14 constant %a4  15 constant %a5
variable kw-pos  variable kw-b                 \ making a keyword table: its end, the last first byte done
: kw-begin ( -- ) 0 kw-pos !  $20 kw-b !  cbuf 2048 erase ;
: kw-fill ( b -- ) begin kw-b @ over < while 1 kw-b +!  kw-pos @ cbuf kw-b @ $21 - 2* + w! repeat drop ;
: kw ( class "words..." -- )                    \ the rest of the line: words of that class, in the table's order
  >r begin parse-name dup while
    over c@ kw-fill  cbuf 192 + kw-pos @ +  2dup c!  r@ over 1+ c!  2 + swap dup 2 + kw-pos +! move
  repeat 2drop rdrop ;
: kw-end ( n -- )                               \ done: into far memory as table n (1 assembly, 2 Forth): an
  $80 kw-fill  kw-pos @ 192 + 2048 > abort" vi-syntax.fs: a table too big" \ index of 96 halfwords by
  cbuf swap 1- 2048 * 2048 far-write htag twait ; \ first byte, then {u8 length, u8 class, bytes}
include /vi-syntax.fs
\ Messages: m" text" in a definition keeps the text in far memory (not in data
\ space, which is scarce) and compiles its address and length; m+" appends.
variable m-pos  $1000 m-pos !                   \ where the next message's text goes
: m-far ( x -- ) dup $ff and msgl !  8 rshift msgbuf swap msgl @ aligned far-read htag twait ;
: m-far+ ( x -- ) dup $ff and >r 8 rshift hdrb swap r@ aligned far-read htag twait
  r> 120 msgl @ - min 0 max  hdrb msgbuf msgl @ + 2 pick move  msgl +! ;
: m-text ( "text" -- x ) '"' parse dup >r cbuf swap move  cbuf m-pos @ r@ aligned far-write htag twait
  m-pos @ 8 lshift r@ or  r> aligned m-pos +!  m-pos @ $1400 > abort" vi: messages too long" ;
: m" ( "text" -- ) m-text postpone literal postpone m-far ; immediate   \ the message is the text
: m+" ( "text" -- ) m-text postpone literal postpone m-far+ ; immediate \ ... appended to the message

\ ---- resident: finding lines of the text, output, the screen's bookkeeping ----------------------
resident
: ct ( c -- type ) ctype + c@ ;
: ce ( i -- a ) 8 * ctab + ;                    \ chunk i's entry
: cb@ ( i -- u ) ce 2 + w@ ;                    \ its bytes
: cl@ ( i -- u ) ce 4 + l@ ;                    \ its lines
: ch-io ( i buf put? -- )                       \ chunk i between its store and buf (whole words)
  >r over ce w@ chsz * f-t + rot cb@ aligned  r> if far-write else far-read then  htag twait ;
: ch-flush ( -- ) cdirty @ if 0 cdirty ! cidx @ cbuf 1 ch-io then ;
: ch-load ( i -- ) dup cidx @ = if drop exit then  ch-flush dup cidx ! cbuf 0 ch-io ;
\ The byte loops of finding a line are code words (assembled with core.fs's
\ assembler, as its control structures are): 4 instructions a byte.
: nlpos ( a -- a' )                             \ the newline at or after a
  [ %t1 %zero 10 addi,  mark  %t0 %s1 0 lbu,  chere %t0 %t1 0 beq,  %s1 %s1 1 addi,
    ahead, rot resolve  mark resolve ] ;
: lskip ( a k -- a' )                           \ past k newlines from a
  [ %t2 %s0 0 ld,  %s0 %s0 8 addi,  %t1 %zero 10 addi,
    mark  chere %s1 %zero 0 beq,  mark  %t0 %t2 0 lbu,  %t2 %t2 1 addi,  chere %t0 %t1 0 bne,  swap resolve
    %s1 %s1 -1 addi,  ahead, rot resolve  mark resolve  %s1 %t2 0 addi, ] ;
: lwalk ( n -- n skip )                         \ its chunk, from the first: f-c, f-b; into cbuf
  0 f-c ! 0 f-b !
  begin f-c @ nch @ 1- < if dup f-c @ cl@ f-b @ + < 0= else false then
  while f-c @ cl@ f-b +!  1 f-c +! repeat
  dup f-b @ -  f-c @ ch-load ;
: lfind ( n -- a u )                            \ line n (below nl): its text in cbuf. After the line
  dup lc-n @ = if drop f-o @ cbuf + f-len @ exit then \ found last, in its chunk, the scan goes on
  lc-n @ dup 0< 0= 2 pick rot > and             \   from there (drawing row after row is quick)
  if f-c @ cl@ f-b @ + over > else false then
  if f-c @ ch-load dup lc-n @ - f-o @ cbuf + else lwalk cbuf then  swap lskip
  dup cbuf - f-o !  dup nlpos over - dup f-len !  rot lc-n ! ;
: lget ( n buf -- u ) swap lfind >r swap r@ move r> ; \ line n's text copied there
: skip-bl ( a u i -- i' )                       \ the first non-blank at or after i (a code word)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %s0 %s0 16 addi,  %a1 %zero ctype ori,
    mark  chere %s1 %t1 0 bge,  %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,
    %a0 %a0 16 andi,  chere %a0 %zero 0 beq,  %s1 %s1 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve ] ;
: fnb ( n -- x ) lfind 0 skip-bl ;              \ line n's first non-blank
: esc[ ( -- ) 27 emit '[' emit ;
: o-n ( n -- ) 0 .r ;
: o-goto ( row col -- ) esc[ swap 1+ o-n ';' emit 1+ o-n 'H' emit ;
: o-sgr ( n -- ) esc[ o-n 'm' emit ;
: o-el ( -- ) esc[ 'K' emit ;
: mark-row ( n -- ) top @ - dup 0< over trows @ < 0= or if drop exit then 1 swap lshift dirty @ or dirty ! ;
: mark-from ( n -- ) top @ - 0 max dup 63 > if drop exit then -1 swap lshift dirty @ or dirty ! ;
: cur-text ( -- a u ) lblive @ if lbuf lblen @ else cy @ lfind then ;
: is-mod ( -- f ) u-end @ u-saved @ <> ins @ or ;
: mo-line ( n -- ) nl @ 1- min 0 max mv-y ! ;  \ a motion's line: n, within the text

\ ==== overlay 2: keys and messages ================================================================
overlay
: m-add ( a u -- ) 120 msgl @ - min 0 max  tuck msgbuf msgl @ + swap move  msgl +! ;
: msg ( a u -- ) 0 msgl ! m-add ;
: rd ( mode -- n )                              \ READ standard input into kbuf (mode 1: do not wait):
  hdl 24 + @ 64 rot 1 hdl @ (msg)               \   bytes, 0 the end, -2 interrupted, -3 none yet
  dup 0> if kbuf 64 2 pick aligned 5 tget then ;
: rd-byte ( -- c|-1|-2 )                        \ the next byte; -1 the end, -2 interrupted
  kb-pos @ kb-len @ = if flush 0 rd dup 0> 0= if 0 kb-len ! -2 = 1- exit then kb-len ! 0 kb-pos ! then
  kbuf kb-pos @ + c@ 1 kb-pos +! ;
: csi ( -- k|0 )                              \ the rest of ESC [ ...: a key, $10b (a size report), 0 (none)
  0 0 begin rd-byte  dup 0< if drop 2drop 0 exit then
    dup '0' - 10 u< if '0' - swap 10 * + false else
    dup ';' = if drop nip 0 false else dup $40 < if drop false else true then then then
  until
  dup 'R' = if drop set-size $10b exit then
  dup '~' = if drop nip dup 9 u< if tildes + c@ dup if $100 + then else drop 0 then exit then
  nip nip  s" ABCDHF" 0 ?do 2dup i + c@ = if 2drop $101 i + unloop exit then loop 2drop 0 ;
: rd-wait ( polls -- f )                        \ a byte waiting (asked up to polls times more, 2 ms apart)?
  begin kb-pos @ kb-len @ < if drop true exit then
    flush 1 rd dup 0> if kb-len ! 0 kb-pos ! drop true exit then
    -3 <> over 0= or if drop false exit then  1- 2 ms
  again ;
: esc-key ( -- k|0 )                              \ an Esc: an escape sequence if a "[" follows within 30 ms
  15 rd-wait 0= if 27 exit then  rd-byte '[' <> if -1 kb-pos +! 27 exit then  csi ;
: rd-key ( -- k )                               \ a key: a byte, $101.. sequences, $10a the end
  begin rd-byte
    dup -2 = if drop 3 exit then  dup 0< if drop $10a exit then  dup 27 <> if exit then
    drop esc-key ?dup
  until ;
: dot-key ( -- k )                            \ the next key of the last change (again, for a count)
  rq-pos @ rq-len @ < 0= if -1 dotn +! 0 rq-pos ! then  dotbuf rq-pos @ 2* + w@  1 rq-pos +! ;
: getkey ( -- k )                               \ the next key (those of . first), recorded for .
  k-pend @ ?dup if 0 k-pend ! else rq-pos @ rq-len @ < dotn @ or if dot-key else rd-key then then
  rec-len @ 64 < if dup recbuf rec-len @ 2* + w! 1 rec-len +! then ;

\ ==== overlay 3: deleting lines, splitting chunks =================================================
overlay
: ln-touch ( n -- ) -1 lc-n !  hs-n @ < if 0 hs-n ! 0 hs-s ! then ; \ (again: something at line n changes)
: ch-new ( i -- f )                             \ an empty chunk at index i (those from i move up)
  nfree @ 0= if drop false exit then  -1 nfree +!
  dup ce dup 8 + nch @ 3 pick - 8 * move  fstk nfree @ + c@ over ce !  1 nch +!
  cidx @ swap < 0= if 1 cidx +! then  true ;
: ch-del ( i -- )                               \ chunk i leaves the table; its store is free
  dup ce w@ fstk nfree @ + c!  1 nfree +!  -1 nch +!
  dup ce dup 8 + swap nch @ 3 pick - 8 * move
  cidx @ 2dup > if 2drop exit then  = if -1 cidx ! 0 cdirty ! else -1 cidx +! then ;
: ch-merge ( -- )                               \ f-c's chunk takes in the next if small and both fit
  f-c @ dup 1+ nch @ < 0= if drop exit then
  dup cb@ dup chsz 4 / < 0= if 2drop exit then
  over 1+ cb@ 2dup + chsz > if 2drop drop exit then  ( c b0 b1 )
  rot >r  over aligned cbuf +  r@ 1+ ce w@ chsz * f-t +  2 pick aligned far-read htag twait
  over aligned cbuf + 2 pick cbuf + 2 pick move \ (read at a whole word, moved down to the end)
  + r@ ce 2 + w!  r@ 1+ cl@ r@ cl@ + r@ ce 4 + l!  1 cdirty !  r> 1+ ch-del ;
: ldel ( n -- )                                 \ line n goes
  dup ln-touch dup >r lfind  f-c @ ce >r        ( a u ) ( R: n entry )
  1+ r@ 2 + w@ over - r@ 2 + w!  r@ 4 + l@ 1- dup r@ 4 + l!  1 cdirty !  -1 nl +!  -1 lc-n !  rdrop
  0= if 2drop rdrop f-c @ ch-del exit then      \ (its chunk is empty: it goes)
  over + swap  f-c @ cb@ f-o @ -  move  ch-merge \ the bytes after it come down
  f-o @ f-c @ cb@ < if                          \ the line after starts where it did (dd after dd
    f-o @ cbuf + dup nlpos swap - f-len !  r@ lc-n ! then rdrop ; \ is quick)
: ch-split ( c off -- f )                       \ the bytes from off on become chunk c+1 (c in cbuf)
  over 1+ ch-new 0= if 2drop false exit then
  0 over 0 ?do cbuf i + c@ 10 = - loop          ( c off k: the lines before off )
  2 pick cl@ over - 3 pick 1+ ce 4 + l!  2 pick ce 4 + l!
  over cb@ over - 2 pick 1+ ce 2 + w!  over ce 2 + w!
  dup cbuf 1 ch-io  cbuf over cb@ + cbuf 2 pick 1+ cb@ move \ (no second buffer: cbuf is written,
  dup 1+ cbuf 1 ch-io  cbuf 0 ch-io  0 cdirty !  true ; \   shifted, written and read again)
\ ==== overlay 4: highlighting assembly (site/hl.js's rules) =======================================
overlay
: paint ( from to class -- ) >r over - 0 max swap cls + swap r> fill ;
: lower ( c -- c' ) dup ct 32 and or ;
: kw-range ( i -- e0 e1 )                       \ the entries of first byte $21 + i, read into cmdbuf
  2* syn @ 1- 2048 * + dup -8 and tuck - swap hdrb swap 16 far-read htag twait \ (the index in far memory)
  hdrb + dup w@ swap 2 + w@ over - >r  syn @ 1- 2048 * 192 + +  dup 7 and tuck -
  cmdbuf swap r@ 3 pick + aligned far-read htag twait  cmdbuf + r> over + ;
: kw-scan ( a u e0 e1 -- class|0 )               \ the entry for the word among e0..e1 (a code word:
  [ %t0 %s0 0 ld,  %t1 %s0 8 ld,  %t2 %s0 16 ld,  %s0 %s0 24 addi,  %a1 %zero ctype ori, \ the word's
    mark  chere %t0 %s1 0 bge,                  \ bytes in lower case against an entry's)
    %a0 %t0 0 lbu,  chere %a0 %t1 0 bne,
    %a3 %t1 0 addi,  %a4 %t2 0 addi,  %a5 %t0 2 addi,
    mark  chere %a3 %zero 0 beq,
    %a0 %a4 0 lbu,  %a2 %a0 %a1 add,  %a2 %a2 0 lbu,  %a2 %a2 32 andi,  %a0 %a0 %a2 or,
    %a2 %a5 0 lbu,  chere %a0 %a2 0 bne,
    %a4 %a4 1 addi,  %a5 %a5 1 addi,  %a3 %a3 -1 addi,  ahead, 3 roll resolve
    mark resolve  swap mark resolve             \ (the next entry)
    %a0 %t0 0 lbu,  %t0 %t0 %a0 add,  %t0 %t0 2 addi,  ahead, 3 roll resolve
    mark resolve  %s1 %t0 1 lbu,  ahead,  swap mark resolve  %s1 %zero 0 addi,  mark resolve ] ;
: kw-find ( a u -- class|0 )                    \ the word's class in the keyword table (case folded)
  dup 0= if nip exit then  over c@ lower $21 - dup 94 u< 0= if drop 2drop 0 exit then  kw-range kw-scan ;
: scan-id ( a u i -- i' )                       \ past the identifier at i ([A-Za-z_.$][A-Za-z0-9_.$]*)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %s0 %s0 16 addi,  %a1 %zero ctype ori,   \ (a code word)
    chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 13 andi,
    chere %a0 %zero 0 beq,
    mark  %s1 %s1 1 addi,  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 15 andi,
    chere %a0 %zero 0 bne,  rot resolve  mark resolve  mark resolve  mark resolve ] ;
: bfind ( a u i c -- i'|-1 )                    \ the first byte c at or after i (a code word)
  [ %a2 %s1 0 addi,  %s1 %s0 0 ld,  %t1 %s0 8 ld,  %t2 %s0 16 ld,  %s0 %s0 24 addi,
    mark  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  chere %a0 %a2 0 beq,
    %s1 %s1 1 addi,  ahead, 3 roll resolve
    swap mark resolve  %s1 %zero -1 addi,  mark resolve ] ;
: com? ( a u i -- f )                           \ an assembly comment starts there (; # //)? (a code word)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %s0 %s0 16 addi,  %a0 %t2 %s1 add,  %a2 %a0 0 lbu,
    %a1 %zero ';' addi,  chere %a2 %a1 0 beq,  %a1 %zero '#' addi,  chere %a2 %a1 0 beq,
    %a1 %zero '/' addi,  chere %a2 %a1 0 bne,  %s1 %s1 1 addi,  chere %s1 %t1 0 bge,
    %a2 %a0 1 lbu,  chere %a2 %a1 0 bne,
    4 roll mark resolve  3 roll mark resolve  %s1 %zero -1 addi,  ahead,
    3 roll mark resolve  2 roll mark resolve  swap mark resolve  %s1 %zero 0 addi,  mark resolve ] ;
: caps? ( a i j -- f )                          \ [A-Z][A-Z0-9_]*[A-Z0-9], two bytes at least (a code word)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %s0 %s0 16 addi,  %a1 %zero ctype ori,
    %a0 %s1 %t1 sub,  %a2 %zero 2 addi,  chere %a0 %a2 0 blt,
    %a0 %t2 %t1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 32 andi,  chere %a0 %zero 0 beq,
    %a0 %t2 %s1 add,  %a0 %a0 -1 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 34 andi,  chere %a0 %zero 0 beq,
    %t1 %t1 1 addi,  mark  chere %t1 %s1 0 bge,
    %a0 %t2 %t1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 98 andi,  chere %a0 %zero 0 beq,
    %t1 %t1 1 addi,  ahead, 3 roll resolve
    swap mark resolve  %s1 %zero -1 addi,  ahead,
    4 roll mark resolve  3 roll mark resolve  2 roll mark resolve  swap mark resolve
    %s1 %zero 0 addi,  mark resolve ] ;
: str-end ( a u i -- j )                       \ past the string at i (to its closing quote; \ escapes)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %s0 %s0 16 addi,  %s1 %s1 1 addi,  %a1 %zero '"' addi,  %a2 %zero '\' addi,
    mark  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %s1 %s1 1 addi,  chere %a0 %a1 0 beq,  chere %a0 %a2 0 bne,  3 pick resolve
    %s1 %s1 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve
    chere %t1 %s1 0 bge,  %s1 %t1 0 addi,  mark resolve ] ;   \ (not past the end)
: num-end ( a u i -- j )                       \ past the number at i (digits and letters)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %s0 %s0 16 addi,  %a1 %zero ctype ori,
    mark  %s1 %s1 1 addi,  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 3 andi,
    chere %a0 %zero 0 bne,  rot resolve  mark resolve ] ;
: chr-end ( a u i -- j )                        \ past the character at i: 'x' or '\x'
  1+ 2dup > if 2 pick over + c@ '\' = if 1+ then 1+ then
  2dup > if 2 pick over + c@ ''' = if 1+ then then  min nip ;
: 3dup ( a b c -- a b c a b c ) 2 pick 2 pick 2 pick ;
: hl-tok ( a u i csr? -- j )                    \ the operand token at i, painted; j: past it
  >r 2 pick over + c@
  dup ct 2 and if drop rdrop dup >r num-end r> over 16 paint exit then
  dup ct 13 and if drop 3dup scan-id rot drop   \ ( a i j ) a register? a CSR (after csrr csrw)? CAPITALS?
    2 pick 2 pick + over 3 pick - kw-find
    dup 13 = over 14 = or over 15 = r> and or 0= if drop 3dup caps? 3 and then
    >r rot drop tuck r> paint exit then
  dup '"' = if drop rdrop dup >r str-end r> over 17 paint exit then
  ''' = if rdrop dup >r chr-end r> over 17 paint exit then
  rdrop nip nip 1+ ;
: hl-ops ( a u i csr? -- )                      \ assembly operands from i
  { a u i csr }
  begin i u < while
    a u i com? if i u 1 paint exit then
    a u i csr hl-tok to i
  repeat ;
: hl-asm ( a u -- )                             \ the classes of an assembly line
  0 0 { a u i w }  0 u 0 paint
  begin a u i skip-bl dup to i to w  i u < 0= if exit then
    a u i com? if i u 1 paint exit then
    a u i scan-id dup w = if drop a u i 0 hl-ops exit then  to i
    i u < if a i + c@ ':' = else false then
  while w i 2 paint  i 1+ to i repeat           \ labels (another may follow)
  a u i skip-bl dup u < if                      \ NAME = (not ==): a constant
    a over + c@ '=' = over 1+ u < if a over + 1+ c@ '=' <> else true then and
    if 1+ to i  w i 1- 3 paint  a u i 0 hl-ops exit then then drop
  a w + c@ '.' = if 12 else                     \ a directive, a mnemonic, or an operand
    a w + i w - kw-find dup 4 - 8 u< 0= if drop a u w 0 hl-ops exit then then
  w i 2 pick paint
  9 = i w - 4 = and a w + c@ 'c' = and  a u i 3 roll hl-ops ; \ csrr / csrw: CSR names follow

\ ==== overlay 5: highlighting Forth (the helpers again: they run for every word) ==================
overlay
: paint ( from to class -- ) >r over - 0 max swap cls + swap r> fill ;
: lower ( c -- c' ) dup ct 32 and or ;
: kw-range ( i -- e0 e1 )                       \ the entries of first byte $21 + i, read into cmdbuf
  2* syn @ 1- 2048 * + dup -8 and tuck - swap hdrb swap 16 far-read htag twait \ (the index in far memory)
  hdrb + dup w@ swap 2 + w@ over - >r  syn @ 1- 2048 * 192 + +  dup 7 and tuck -
  cmdbuf swap r@ 3 pick + aligned far-read htag twait  cmdbuf + r> over + ;
: kw-scan ( a u e0 e1 -- class|0 )               \ the entry for the word among e0..e1 (a code word:
  [ %t0 %s0 0 ld,  %t1 %s0 8 ld,  %t2 %s0 16 ld,  %s0 %s0 24 addi,  %a1 %zero ctype ori, \ the word's
    mark  chere %t0 %s1 0 bge,                  \ bytes in lower case against an entry's)
    %a0 %t0 0 lbu,  chere %a0 %t1 0 bne,
    %a3 %t1 0 addi,  %a4 %t2 0 addi,  %a5 %t0 2 addi,
    mark  chere %a3 %zero 0 beq,
    %a0 %a4 0 lbu,  %a2 %a0 %a1 add,  %a2 %a2 0 lbu,  %a2 %a2 32 andi,  %a0 %a0 %a2 or,
    %a2 %a5 0 lbu,  chere %a0 %a2 0 bne,
    %a4 %a4 1 addi,  %a5 %a5 1 addi,  %a3 %a3 -1 addi,  ahead, 3 roll resolve
    mark resolve  swap mark resolve             \ (the next entry)
    %a0 %t0 0 lbu,  %t0 %t0 %a0 add,  %t0 %t0 2 addi,  ahead, 3 roll resolve
    mark resolve  %s1 %t0 1 lbu,  ahead,  swap mark resolve  %s1 %zero 0 addi,  mark resolve ] ;
: kw-find ( a u -- class|0 )                    \ the word's class in the keyword table (case folded)
  dup 0= if nip exit then  over c@ lower $21 - dup 94 u< 0= if drop 2drop 0 exit then  kw-range kw-scan ;
: scan-id ( a u i -- i' )                       \ past the identifier at i ([A-Za-z_.$][A-Za-z0-9_.$]*)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %s0 %s0 16 addi,  %a1 %zero ctype ori,   \ (a code word)
    chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 13 andi,
    chere %a0 %zero 0 beq,
    mark  %s1 %s1 1 addi,  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 15 andi,
    chere %a0 %zero 0 bne,  rot resolve  mark resolve  mark resolve  mark resolve ] ;
: bfind ( a u i c -- i'|-1 )                    \ the first byte c at or after i (a code word)
  [ %a2 %s1 0 addi,  %s1 %s0 0 ld,  %t1 %s0 8 ld,  %t2 %s0 16 ld,  %s0 %s0 24 addi,
    mark  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  chere %a0 %a2 0 beq,
    %s1 %s1 1 addi,  ahead, 3 roll resolve
    swap mark resolve  %s1 %zero -1 addi,  mark resolve ] ;
: 3dup ( a b c -- a b c a b c ) 2 pick 2 pick 2 pick ;
: word-at ( a u i -- w j )                      \ the next word: w its start (past blanks), j its end (a code word)
  [ %t1 %s0 0 ld,  %t2 %s0 8 ld,  %a1 %zero ctype ori,
    mark  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 16 andi,  chere %a0 %zero 0 beq,
    %s1 %s1 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve
    %s1 %s0 8 sd,
    mark  chere %s1 %t1 0 bge,
    %a0 %t2 %s1 add,  %a0 %a0 0 lbu,  %a0 %a0 %a1 add,  %a0 %a0 0 lbu,  %a0 %a0 16 andi,  chere %a0 %zero 0 bne,
    %s1 %s1 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve
    %s0 %s0 8 addi, ] ;
: f-digit ( c base -- f ) swap lower dup '0' - dup 10 u< if nip else drop 'a' - 10 + dup 10 < if drop 99 then then > ;
: f-digits ( a u base dot? -- f )               \ digits of base (one at least), then a "." if dot?
  2>r 0 -rot
  begin dup while over c@ 2r@ drop f-digit while rot 1+ -rot 1 /string repeat
    1 = swap c@ '.' = and 2r> nip and swap 0<> and exit
  then 2drop 2r> 2drop 0<> ;
: fnum ( a u -- f )                             \ a Forth number: -?($-?hex | #-?dec | %-?bin | dec.? | 'c')
  over c@ '-' = if 1 /string then  dup 0= if nip exit then
  over c@ ''' = if 3 = swap 2 + c@ ''' = and exit then
  over c@ case '$' of 16 endof '#' of 10 endof '%' of 2 endof 0 swap endcase
  ?dup if >r 1 /string  over c@ '-' = over 0<> and if 1 /string then  r> false else 10 true then
  f-digits ;
variable hf-want                                \ what the word before asked for: 1 a name, 2 a character, 3 locals
: hf-close ( a u w from -- a u i' open? )       \ a ( comment from w; its ) searched from `from`
  >r 2 pick 2 pick r> ')' bfind
  dup 0< if drop over 1 paint dup true exit then  1+ tuck 1 paint false ;
: hf-str ( a u w j c -- a u i' )                \ a string from w: up to c, searched from past j
  >r 1+ >r 2 pick 2 pick r> r> bfind
  dup 0< if drop over else 1+ then tuck 17 paint ;
: hf-wanted ( a u w j -- a u j )                \ the word the one before asked for
  hf-want @ 3 = if 2dup swap - 1 = 4 pick 3 pick + c@ '}' = and if 0 hf-want ! then 23
    else hf-want @ 1 = if 19 else 17 then 0 hf-want ! then
  >r tuck r> paint ;
: hf-one ( a u w j -- a u i' open? )            \ one word [w, j) of a Forth line, painted
  hf-want @ if hf-wanted false exit then
  3 pick 2 pick + c@  2 pick 2 pick swap -      ( a u w j c len )
  over '\' = over 1 = and if 2drop drop over 1 paint dup false exit then
  over '(' = over 1 = and if 2drop hf-close exit then
  dup 2 < 0= 6 pick 4 pick + 1- c@ '"' = and if 2drop '"' hf-str false exit then
  2 = swap '.' = and 4 pick 2 pick + 1- c@ '(' = and if ')' hf-str false exit then
  3 pick 2 pick + 2 pick 2 pick swap - 2dup kw-find ?dup if
    nip nip dup 6 rshift hf-want ! $3f and >r tuck r> paint false exit then
  fnum if tuck 16 paint else nip then false ;
: hl-forth ( a u open? -- open? )               \ the classes of a Forth line; is a ( comment open after it?
  0 hf-want !  >r 0 over 0 paint  0 r> if 0 hf-close if 2drop drop true exit then then
  begin 3dup word-at  2dup = if 2drop 2drop drop false exit then  rot drop  hf-one
    if 2drop drop true exit then
  again ;
: hl-on ( -- syn ) synon @ if syn @ else 0 then ; \ the highlighting in effect (0 none, 1 asm, 2 Forth)
: fstate-top ( -- s )                           \ Forth: the ( state at the start of the top line
  hl-on 2 <> if 0 exit then                     \   (from the line it was known for, or the first)
  hs-n @ top @ > if 0 hs-n ! 0 hs-s ! then
  hs-s @ hs-n @ begin dup top @ < while dup lfind 3 pick hl-forth rot drop swap 1+ repeat
  hs-n ! dup hs-s ! ;


\ ==== overlay 6: inserting and replacing lines; reading a file ====================================
overlay
: ln-touch ( n -- ) -1 lc-n !  hs-n @ < if 0 hs-n ! 0 hs-s ! then ; \ something at line n changes
: room? ( -- f ) nfree @ 2 < if m" buffer full" false else true then ;
: fits? ( c u -- f ) swap cb@ + 1+ chsz > 0= ;
: lins ( n a u -- f )                           \ a new line before line n (nl: after the last)
  room? 0= if drop 2drop false exit then
  0 0 { n a u c off }  n ln-touch
  nch @ 0= if 0 ch-new drop 0 cidx ! 0 cdirty ! else
    n nl @ < if n lfind 2drop f-c @ to c  f-o @ to off  \ where the line is; at a chunk's start:
      off 0= c 0<> and if c 1- to c  c ch-load  c cb@ to off then \ the end of the one before
    else nch @ 1- to c  c ch-load  c cb@ to off then then
  c u fits? 0= if                               \ no room: split there, or a new chunk
    off if off c cb@ < if c off ch-split 0= if false exit then then
      c u fits? 0= if c 1+ to c  0 to off  ch-flush c ch-new 0= if false exit then  c cidx ! then
    else ch-flush c ch-new 0= if false exit then  c cidx ! then then
  cbuf off + dup u 1+ +  c cb@ off - move  a cbuf off + u move  10 cbuf off + u + c!
  c ce 2 + dup w@ u + 1+ swap w!  c ce 4 + dup l@ 1+ swap l!  1 cdirty !  1 nl +!
  c f-c !  off f-o !  u f-len !  n lc-n !      \ found: the new line (inserting one after another is quick)
  off 0= if n else c cb@ off u + 1+ = if n c cl@ 1- - else 0 c 0 ?do i cl@ + loop then then f-b !  true ;
: lput ( n a u -- f )                           \ line n's text replaced (in its chunk if it fits)
  2 pick ln-touch  2 pick lfind nip { n a u old }
  f-c @ cb@ u + old - chsz > if room? 0= if false exit then  n ldel  n a u lins exit then
  cbuf f-o @ + old +  dup u old - +  f-c @ cb@ f-o @ - old -  move
  a cbuf f-o @ + u move  f-c @ ce 2 + dup w@ u + old - swap w!
  u f-len !  n lc-n !  1 cdirty !  true ;
: fixempty ( -- f ) nl @ if false else 0 lbuf 0 lins drop true then ; \ there is always a line
: fs-read ( id u -- n ) 0 1 2 (msg) dup 0> if tbuf 64 2 pick aligned 5 tget then ; \ into tbuf
: dl-add ( -- f ) nl @ lbuf lblen @ lins  0 lblen ! ; \ lbuf -> a new last line
: nl-in ( a u -- k )                            \ the bytes before the first newline (all u if none: a code word)
  [ %t2 %s0 0 ld,  %s0 %s0 8 addi,  %t1 %zero 10 addi,  %a0 %zero 0 addi,
    mark  chere %a0 %s1 0 bge,  %a2 %t2 %a0 add,  %a2 %a2 0 lbu,  chere %a2 %t1 0 beq,
    %a0 %a0 1 addi,  ahead, 3 roll resolve  mark resolve  mark resolve  %s1 %a0 0 addi, ] ;
: dl-file ( id -- cut? )                        \ the file's lines into the text (lmax bytes make a line)
  false { id cut }
  begin cut 0= if id 1008 fs-read else 0 then dup 0> while
    tbuf swap begin dup cut 0= and while        ( a u: what is left of this piece )
      2dup nl-in lmax lblen @ - min             \ up to a newline, as much as the line takes
      >r over lbuf lblen @ + r@ move  r@ lblen +!  r> /string
      lblen @ lmax = if dl-add 0= to cut else   \ (a full line ends there, as in vi.s)
        dup if over c@ 10 = if 1 /string dl-add 0= to cut then then then
    repeat 2drop
  repeat drop
  lblen @ cut 0= and if dl-add 0= to cut then  cut ;

\ ==== overlay 7: drawing ==========================================================================
overlay
: hl-on ( -- syn ) synon @ if syn @ else 0 then ; \ (again: called for every row)
: hl-line ( a u state -- state' ) syn @ 2 = if hl-forth else drop hl-asm 0 then ;
: dcol ( a i -- col ) 0 swap 0 ?do over i + c@ 9 = if 7 or then 1+ loop nip ; \ byte i's column
: emit-row ( a u color? -- )                    \ the columns shown, tabs as spaces, others as ?
  0 0 { a u color col shown }
  u 0 ?do
    a i + c@ 1  over 9 = if 2drop bl col 7 or 1+ col - then  ( c n )
    over $20 - $5f u< 0= if nip '?' swap then
    begin dup while
      col lcol @ tcols @ + < 0= if 2drop unloop shown if 0 o-sgr then exit then
      col lcol @ < 0= if color if cls i + c@ dup shown <> if dup to shown sgrtab + c@ o-sgr else drop then then
        over emit then
      col 1+ to col  1-
    repeat 2drop
  loop shown if 0 o-sgr then ;
: draw-row ( r -- )                             \ text row r: its line (or ~ past the end), highlighted
  dup 0 o-goto  dup top @ +
  dup nl @ < 0= if 2drop 94 o-sgr '~' emit 0 o-sgr o-el exit then
  numw @ if 33 o-sgr dup 1+ 5 u.r 0 o-sgr space then
  dup cy @ = lblive @ and if drop lbuf lblen @ else lfind then  ( r a u )
  hl-on if 2dup 4 pick rowst + c@ hl-line       \ the next row starts in another ( state: drawn too
    3 pick 1+ rowst + dup c@ 2 pick <> if c! 2 pick 1+ 1 swap lshift dirty @ or dirty ! else 2drop then
    true else false then  emit-row drop o-el ;
: draw-status ( -- )                            \ the message, or the mode, the file, [+], line,column
  rows @ 1- 0 o-goto
  msgl @ if msgbuf msgl @ cols @ 1- min type o-el exit then
  ins @ if esc[ ." 1m-- INSERT --" esc[ ." 0m  " then
  fnl @ if fname fnl @ 40 min type else ." [No Name]" then
  is-mod if ."  [+]" then  o-el
  rows @ 1- cols @ 18 - o-goto  cy @ 1+ o-n ',' emit  cx @ 1+ o-n  o-el ;
: fix-cursor ( -- )                             \ the cursor within the text (normal mode: on a byte)
  cy @ nl @ 1- min 0 max cy !
  cur-text nip ins @ 0= over 0<> and if 1- then  cx @ min 0 max cx ! ;
: view ( -- )                                   \ the screen follows the cursor; dcur, want
  top @ cy @ trows @ { t y r }
  y t < if y r + t < if y r 2/ - 0 max else y then top ! 1 dall ! else
    y t r + < 0= if y t r + r + < 0= if y r 2/ - 0 max else y r - 1+ then top ! 1 dall ! then then
  cur-text drop cx @ dcol  dup dcur !  setw @ if dup want ! then
  dup lcol @ < over lcol @ tcols @ + < 0= or if tcols @ 2/ - 0 max lcol ! 1 dall ! else drop then ;
: refresh ( -- )                                \ the screen up to date: rows marked, status, cursor
  fix-cursor view  esc[ ." ?25l"
  clear @ if 0 clear ! esc[ ." 2J" then
  dall @ if 0 dall ! -1 dirty ! fstate-top rowst c! then
  trows @ 0 ?do dirty @ i rshift 1 and if i draw-row then loop
  0 dirty !  draw-status
  cy @ top @ -  dcur @ lcol @ - numw @ +  o-goto  esc[ ." ?25h"  0 setw ! ;

