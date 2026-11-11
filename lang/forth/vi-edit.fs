\ =============================================================================
\ vi-edit.fs: vi.fs, part 2: undo, inserting, changing, files, : commands, normal mode
\ =============================================================================
\ Included by vi.fs (which describes the editor); not a program of its own.

\ ==== overlay 5: the undo history and the register =========================================================
overlay
: fl-put ( far u -- size )                      \ a line record {u64 length, bytes} from tbuf (bytes at +8)
  dup tbuf ! 15 + -8 and >r tbuf swap r@ far-write htag twait r> ;
: fl-get ( far -- u size )                      \ and back: its length (the bytes at tbuf + 8), its size
  tbuf over 8 far-read htag twait  tbuf @ dup 7 + -8 and
  dup if >r tbuf 8 + rot 8 + r@ far-read htag twait r> else rot drop then 8 + ;
: fmove ( dst src u -- )                        \ far memory moved down, through tbuf
  begin dup while  dup 1000 min >r  tbuf 2 pick r@ far-read htag twait  tbuf 3 pick r@ far-write htag twait
    rot r@ + rot r@ + rot r> - repeat drop 2drop ;
: u-room ( bytes -- f )                         \ room after u-w (and a trailer)? The oldest records go
  begin dup u-w @ + 8 + usz > while
    u-rec @ 0= if drop false exit then
    hdrb f-u 8 far-read htag twait  hdrb @
    dup negate u-rec +!  dup negate u-w +!  u-saved @ over - dup 0< if drop -1 then u-saved !
    f-u dup 2 pick + u-w @ fmove drop
  repeat drop true ;
: u-line ( n -- )                               \ its text into the record being written
  u-ok @ 0= if drop exit then  tbuf 8 + lget dup >r 15 + -8 and u-room
  if f-u u-w @ + r> fl-put u-w +! else rdrop 0 u-ok ! then ;
: chg-begin ( first n -- )                      \ a change replaces those lines (0: it adds): the old ones
  2dup chg-n ! chg-a !  u-end @ dup u-rec ! dup u-top ! 48 + u-w ! \ go into a new record (redo is gone)
  u-saved @ u-end @ > if -1 u-saved ! then  1 u-ok !  cy @ chg-y !  cx @ chg-x !
  0 u-room u-ok !  bounds ?do i u-line loop ;
: chg-end ( n -- )                              \ it made n lines from chg-a: they go in; the record is done
  1 chg !  dup hdrb 24 + !  chg-a @ tuck + swap ?do i u-line loop
  u-ok @ 0= if 0 u-end ! 0 u-top ! -1 u-saved ! m" undo: the change was too big; history cleared" exit then
  u-w @ 8 + dup u-rec @ -  dup hdrb !  chg-a @ hdrb 8 + !  chg-n @ hdrb 16 + !  chg-y @ hdrb 32 + !
  chg-x @ hdrb 40 + !  hdrb f-u u-rec @ + 48 far-write htag twait
  hdrb ! hdrb f-u u-w @ + 8 far-write htag twait  dup u-end ! u-top ! ;
: u-apply ( rec redo? -- )                      \ a record's lines back as they were (undo) or as it made them
  swap f-u + hdrb over 48 far-read htag twait 48 +  hdrb 8 + @ hdrb 24 + @ hdrb 16 + @
  { redo far first del add }
  redo if del add to del to add  del 0 ?do far fl-get nip far + to far loop then
  del 0 ?do first ldel loop
  add 0 ?do far fl-get far + to far  first i + tbuf 8 + rot lins drop loop
  fixempty drop  hdrb 32 + @ cy !  hdrb 40 + @ cx !  1 dall ! ;
: c-u ( -- )                                    \ undo, count times
  cnt1 @ 0 ?do u-end @ 0= if m" Already at oldest change" unloop exit then
    hdrb f-u u-end @ + 8 - 8 far-read htag twait  u-end @ hdrb @ - dup u-end ! 0 u-apply loop ;
: c-redo ( -- )                                 \ redo, count times
  cnt1 @ 0 ?do u-end @ u-top @ = if m" Already at newest change" unloop exit then
    u-end @ 1 u-apply  hdrb @ u-end +! loop ;
: y-lines ( first n -- )                        \ those lines are the register
  dup y-cnt ! 1 y-kind !  0 -rot bounds ?do
    i tbuf 8 + lget  2dup 15 + + ysz > if 2drop 0 y-cnt ! m" too much for the register (48 KiB)" unloop exit then
    f-y 2 pick + swap fl-put +
  loop drop ;
: y-chars ( a u -- ) tuck tbuf 8 + swap move  f-y swap fl-put drop  0 y-kind ! 1 y-cnt ! ;

\ ==== overlay 6: insert mode ================================================================================
overlay
: ir-load ( -- ) cy @ lbuf lget lblen !  1 lblive !  cy @ mark-row ; \ the cursor's line into lbuf
: ir-commit ( -- )                              \ lbuf back; the change ends with the cursor's line
  cy @ lbuf lblen @ lput drop  0 lblive !  cy @ mark-row  cy @ chg-a @ - 1+ chg-end ;
: ir-ch ( c -- )                                \ a byte typed
  lblen @ lmax < 0= if drop exit then
  lbuf cx @ + dup 1+ lblen @ cx @ - move  lbuf cx @ + c!  1 cx +!  1 lblen +!  cy @ mark-row ;
: ir-dl ( -- ) lbuf cx @ + dup 1+ swap lblen @ cx @ - 1- move  -1 lblen +!  cy @ mark-row ;
: ir-nl ( -- )                                  \ Enter: the line up to the cursor stays, the rest is a new one
  cy @ lbuf cx @ lput drop  cy @ 1+ lbuf cx @ + lblen @ cx @ - lins drop
  lbuf cx @ + lbuf lblen @ cx @ - dup lblen ! move  cy @ mark-from  1 cy +!  0 cx ! ;
: ir-mv ( k -- )                                \ an arrow: the change ends; another begins where the cursor is
  ir-commit  case $101 of -1 cy +! endof $102 of 1 cy +! endof $104 of -1 cx +! endof
    $103 of 1 cx +! endof $105 of 0 cx ! endof $106 of bigcol cx ! endof endcase
  fix-cursor  cy @ 1 chg-begin  ir-load ;
: ir-end ( -- ) ir-commit  0 ins !  1 setw !  cx @ if -1 cx +! then ;
: ins-run ( -- )                                \ insert mode on the cursor's line, in a change begun before
  1 ins !  ir-load
  begin 1 setw !  refresh  getkey
    dup 27 = over 3 = or if drop ir-end exit then
    dup $10a = if k-pend ! ir-end exit then
    dup 10 = over 13 = or if drop ir-nl else
    dup 127 = over 8 = or if drop cx @ if -1 cx +! ir-dl then else
    dup $107 = if drop cx @ lblen @ < if ir-dl then else
    dup $106 > if drop else  dup $100 > if ir-mv else
    dup 9 <> over 32 < and if drop else ir-ch then then then then then then
  again ;
: c-ins ( -- ) cy @ 1 chg-begin ins-run ;
: c-open ( n -- ) dup 0 chg-begin  dup lbuf 0 lins drop  dup cy !  0 cx !  mark-from  ins-run ;

\ ==== overlay 7: changing =================================================================================
overlay
: op-chars ( from to op -- )                    \ the cursor line's bytes [from, to): into the register,
  { x0 x1 op }  x0 cx !  cy @ lbuf lget lblen !  lbuf x0 + x1 x0 - y-chars \ and (d c) out of the line
  op 'y' = if exit then
  cy @ 1 chg-begin  lbuf x1 + lbuf x0 + lblen @ x1 - move  lblen @ x1 - x0 + lblen !
  cy @ lbuf lblen @ lput drop  cy @ mark-row
  op 'c' = if ins-run else 1 chg-end then ;
: op-lines ( op first last -- )                 \ those lines: into the register, and (d) out of the text,
  over - 1+ { op first n }  first n y-lines  first cy ! \ or (c) an empty line in insert mode instead
  op 'y' = if exit then
  first n chg-begin  n 0 ?do first ldel loop  first mark-from
  op 'c' = if first lbuf 0 lins drop  0 cx !  ins-run exit then
  fixempty negate chg-end  first nl @ 1- min dup cy ! fnb cx ! ;
: op-lcnt ( op -- ) cy @ dup cnt1 @ + 1- nl @ 1- min op-lines ; \ dd cc yy: count lines from the cursor's
: c-x ( -- ) cur-text nip ?dup if cx @ dup cnt1 @ + rot min 'd' op-chars then ;
: c-bs ( -- ) cx @ ?dup if dup cnt1 @ - 0 max swap 'd' op-chars then ;
: c-DC ( op -- ) cur-text nip cx @ swap rot op-chars ; \ D C: to the end of the line
: c-s ( -- ) cur-text nip cx @ dup cnt1 @ + rot min 'c' op-chars ;
: c-r ( -- )                                    \ r: count bytes replaced by the next key
  getkey dup 9 <> over $20 - $5f u< 0= and if drop exit then
  cur-text nip cx @ cnt1 @ + < if drop exit then
  cy @ 1 chg-begin  cy @ lbuf lget lblen !  lbuf cx @ + cnt1 @ rot fill
  cx @ cnt1 @ + 1- cx !  cy @ lbuf lblen @ lput drop  1 chg-end  cy @ mark-row ;

\ ==== overlay 8: joining, putting ==========================================================================
overlay
: c-J ( -- )                                    \ J: lines joined, the leading blanks gone, a space between
  cnt1 @ 1- 1 max  nl @ cy @ - 1- min  dup 0> 0= if drop exit then
  cy @ over 1+ chg-begin  cy @ lbuf lget lblen !
  0 ?do
    cy @ 1+ tbuf 8 + lget  tbuf 8 + over 0 skip-bl   ( u s )
    lblen @ dup cx ! if 2dup > if lbuf lblen @ + 1- c@ ct 16 and 0=  tbuf 8 + 2 pick + c@ ')' <> and
      if bl lbuf lblen @ + c!  1 lblen +! then then then
    tuck -  lblen @ over + lmax > if drop lmax lblen @ - then
    swap tbuf 8 + +  lbuf lblen @ +  rot dup lblen +! move
    cy @ 1+ ldel
  loop
  cy @ lbuf lblen @ lput drop  1 chg-end  cy @ mark-from ;
: put-lines ( after? -- )                       \ the register's lines below (above) the cursor's, count times
  cy @ + 0 true { line off ok }  line 0 chg-begin  line cy !  line mark-from
  cnt1 @ 0 ?do  f-y to off
    y-cnt @ 0 ?do ok if off fl-get off + to off  line tbuf 8 + rot lins dup to ok if line 1+ to line then then loop
  loop  line cy @ - chg-end  cy @ fnb cx ! ;
: put-at ( u at -- )                            \ the register's bytes into lbuf there, count times
  { u at }  cnt1 @ 0 ?do lblen @ u + lmax > if leave then
    lbuf at + dup u + lblen @ at - move  tbuf 8 + lbuf at + u move  u lblen +!  at u + to at loop
  at 1- 0 max cx !  cy @ lbuf lblen @ lput drop  1 chg-end  cy @ mark-row ;
: put ( after? -- )                             \ p P
  y-cnt @ 0= if drop exit then  y-kind @ if put-lines exit then
  cy @ 1 chg-begin  f-y fl-get drop  cy @ lbuf lget dup lblen !
  if swap cx @ + else nip cx @ then put-at ;

\ ==== overlay 9: files ======================================================================================
overlay
: buf-reset ( -- )                              \ no text, every chunk free, no history, the cursor home
  nchmax @ dup nfree !  0 ?do nchmax @ 1- i - fstk i + c! loop
  -1 cidx ! -1 lc-n !  0 cdirty ! 0 nch ! 0 nl ! 0 cy ! 0 cx ! 0 top ! 0 lcol ! 0 hs-n ! 0 hs-s !
  0 u-end ! 0 u-top ! 0 u-saved !  1 dall ! 1 setw ! ;
: >msg ( a u -- ) tuck tbuf swap move  0 tbuf 2 pick + c!  tbuf 64 rot 1+ aligned 5 tput ; \ request data
: fs-open ( a u mode -- id|err ) >r tuck >msg 0 swap r> 3 2 (msg) ;
: fs-close ( id -- ) 0 0 4 2 (msg) drop ;
: fs-write ( id u -- f ) tbuf 64 2 pick aligned 5 tput  tuck 0 2 2 (msg) = ; \ from tbuf
: m-chr ( c -- ) msgl @ 120 < if msgbuf msgl @ + c! 1 msgl +! else drop then ;
: m-name ( -- ) 0 msgl ! '"' m-chr fname fnl @ m-add '"' m-chr ; \ the message: "NAME"
: m-dec ( n -- ) <# #s #> m-add ;
: buf-bytes ( -- u ) 0 nch @ 0 ?do i cb@ + loop ; \ the text's bytes as a file
: m-size ( -- ) bl m-chr nl @ m-dec m+"  lines," bl m-chr buf-bytes m-dec m+"  bytes" ;
: zlen ( a max -- a u ) over swap 0 ?do dup c@ 0= if leave then 1+ loop over - ;
: syn-detect ( -- )                             \ highlighting by the name (.s .fs), else by the tags (src forth)
  1 dall !  0 syn !
  fnl @ 3 < 0= if fname fnl @ + 3 - 3 s" .fs" str= if 2 syn ! exit then then
  fnl @ 2 < 0= if fname fnl @ + 2 - 2 s" .s" str= if 1 syn ! exit then then
  fnl @ 0= if exit then
  fname fnl @ >msg  0 fnl @ 0 14 2 (msg) 31 min  dup 0> 0= if drop exit then \ TAGS
  tbuf 64 2 pick 32 * 5 tget
  0 ?do tbuf i 32 * + 16 zlen 2dup s" forth" str= if 2drop 2 syn ! unloop exit then
    s" src" str= if 1 syn ! unloop exit then loop ;
: do-load ( a u -- )                            \ the buffer is that file (one that does not exist: empty)
  dup fnl ! fname swap move  buf-reset  0 lblen !
  fnl @ if fname fnl @ 0 fs-open dup 0< if drop m-name m+"  [New File]" else
      dup dl-file swap fs-close  m-name m-size  if m-name m+"  is cut short: the buffer is full" then
    then then
  fixempty drop  syn-detect ;
: dw-lines ( id -- f )                          \ every line and its newline, a message at a time
  0 { id k }
  nl @ 0 ?do i lfind  k over + 1+ 1008 > if id k fs-write 0= if 2drop false unloop exit then 0 to k then
    tuck tbuf k + swap move  k + dup tbuf + 10 swap c!  1+ to k loop
  k if id k fs-write else true then ;
: do-write ( a u -- f )                         \ the text into that file
  buf-bytes $20000 > if 2drop m" too big to write: the file server takes 128 KiB at most" false exit then
  2dup 1 fs-open dup 0< if drop m" cannot write: " m-add false exit then
  dup dw-lines swap fs-close 0= if m" cannot write: " m-add false exit then
  0 msgl ! '"' m-chr m-add '"' m-chr m-size m+"  written" true ;

\ ==== overlay 10: the : line and searching ===============================================================
overlay
: readline ( c -- u|-1 )                        \ a line typed on the status row (in cmdbuf); -1: abandoned
  0 { p n }
  begin rows @ 1- 0 o-goto  p emit cmdbuf n type o-el
    begin getkey
      dup 10 = over 13 = or if drop n exit then
      dup 27 = over 3 = or over $10a = or if drop -1 exit then
      dup 127 = over 8 = or if drop n 0= if -1 exit then n 1- to n true else
      dup $20 - $5f u< n 120 < and if dup emit cmdbuf n + c! n 1+ to n else drop then false then
    until
  again ;
: x-name ( -- a u ) x-argl @ if x-arg @ x-argl @ else fname fnl @ then ; \ the file a : command names
: ex-w ( -- f )                                 \ :w [NAME]
  x-name dup 0= if 2drop m" No file name" false exit then
  do-write 0= if false exit then
  fnl @ 0= if x-arg @ fname x-argl @ dup fnl ! move syn-detect u-end @ u-saved ! true exit then
  x-argl @ 0= if u-end @ u-saved ! then true ;
: nowrite ( -- ) m" No write since last change (add ! to override)" ;
: ex-x ( -- ) is-mod if ex-w 0= if exit then then 1 quit ! ; \ :x ZZ
: pack ( a u -- n ) dup 8 > if 2drop -1 exit then  0 swap 0 ?do over i + c@ i 3 lshift lshift or loop nip ;
: ex-set ( -- )                                 \ :set nu / number / nonu / nonumber (packed, as below)
  x-arg @ x-argl @ pack case $756e of 6 endof $7265626d756e of 6 endof $756e6f6e of 0 endof
    $7265626d756e6f6e of 0 endof  drop m" Unknown option: " x-arg @ x-argl @ m-add exit endcase
  numw ! size-upd ;
: ex-syn ( -- )                                 \ :syntax on / off
  x-arg @ x-argl @ pack case $6e6f of 1 endof $66666f of 0 endof drop m" Unknown option: " exit endcase
  synon ! 1 dall ! ;
: ex-do ( n -- f )                              \ the command, its letters packed in a number (w = $77 ...)
  case
    $77 of ex-w drop endof                                              \ w
    $71 of x-bang @ is-mod 0= or if 1 quit ! else nowrite then endof    \ q
    $7177 of ex-w if 1 quit ! then endof                                \ wq
    $78 of ex-x endof                                                   \ x
    $65 of x-bang @ is-mod 0= or if x-name do-load else nowrite then endof \ e
    $746573 of ex-set endof  $6573 of ex-set endof                      \ set se
    $7861746e7973 of ex-syn endof  $6e7973 of ex-syn endof              \ syntax syn
    drop false exit
  endcase true ;
: ex-run ( a u -- )                             \ a command [!] [argument]
  0 0 { a u k j }
  begin k u < if a k + c@ ct 1 and else false then while k 1+ to k repeat
  k to j  0 x-bang !  j u < if a j + c@ '!' = if 1 x-bang !  j 1+ to j then then
  a u j skip-bl dup a + x-arg !  u swap - x-argl !
  a k pack ex-do 0= if m" Not an editor command: " a u m-add then ;
: c-colon ( -- )                                \ a : line: a line number, or a command
  ':' readline dup 0> 0= if drop exit then  cmdbuf swap 2dup 0 skip-bl /string
  2dup number? if nip nip 1- mo-line mv-y @ dup cy ! fnb cx ! exit then  ex-run ;

\ ==== overlay: searching =============================================================================
overlay
: sfind ( a u from dir -- i|-1 )                \ where the text searched for starts: the first at or
  { a u from dir }  u patl @ -                  \   after (the last at or before) from
  dir 0< if from over min else from 0 max then to from
  begin from 0< 0= from 2 pick > 0= and while
    a from + patl @ patbuf patl @ compare 0= if drop from exit then  from dir + to from
  repeat drop -1 ;
: search ( dir -- f )                           \ the next match from the cursor, round the end: mv-y mv-x
  patl @ 0= if drop m" No previous pattern" false exit then
  cy @ cx @ 2 pick + nl @ 1+ false { dir y x left wrapped }
  begin y lfind x dir sfind dup 0< while drop
    left 1- dup to left 0= if m" Pattern not found: " patbuf patl @ m-add false exit then
    y dir + to y  dir 0< if bigcol to x  y 0< if nl @ 1- to y  true to wrapped then
      else 0 to x  y nl @ < 0= if 0 to y  true to wrapped then then
  repeat  mv-x !  y mv-y !
  wrapped if dir 0< if m" search hit TOP, continuing at BOTTOM" else m" search hit BOTTOM, continuing at TOP" then
    then true ;
: c-find ( dir -- )                             \ / ?: the text, then the search
  dup 0> if '/' else '?' then readline dup 0< if 2drop exit then
  ?dup if dup patl ! cmdbuf patbuf rot move then
  dup sdir ! search if mv-y @ cy ! mv-x @ cx ! then ;

\ ==== overlay 11: motions ===============================================================================
overlay
: pos-get ( -- c len ) p-y @ lfind dup p-x @ > if over p-x @ + c@ else 10 then rot drop swap ;
: pos-cls ( -- k )                              \ 0 blank (a line's end too), 1 a word's byte, 2 other, 3 an empty line
  pos-get swap dup 10 = if drop 0= 3 and exit then nip ct dup 16 and if drop 0 exit then 3 and if 1 else 2 then ;
: pos-next ( -- f ) pos-get nip p-x @ > if 1 p-x +! true exit then \ one byte on (a line's end counts)
  p-y @ 1+ dup nl @ < if p-y ! 0 p-x ! true else drop false then ;
: pos-prev ( -- f ) p-x @ if -1 p-x +! true exit then \ one byte back
  p-y @ dup 0= if drop false exit then 1- dup p-y ! lfind nip p-x ! true ;
: wf-bl ( -- ) begin pos-cls if exit then pos-next 0= until ;
: w-fwd ( -- )                                  \ w
  pos-cls dup 0= if drop wf-bl exit then
  dup 3 = if drop pos-next if wf-bl then exit then
  >r begin pos-next 0= if rdrop exit then pos-cls r@ <> until rdrop  pos-cls if exit then wf-bl ;
: w-end ( -- )                                  \ e
  pos-next 0= if exit then
  begin pos-cls dup 0= swap 3 = or while pos-next 0= if exit then repeat
  pos-cls >r begin p-y @ p-x @ pos-next 0= if p-x ! p-y ! rdrop exit then
    pos-cls r@ = while 2drop repeat p-x ! p-y ! rdrop ;
: w-back ( -- )                                 \ b
  pos-prev 0= if exit then
  begin pos-cls 0= while pos-prev 0= if exit then repeat
  pos-cls dup 3 = if drop exit then >r
  begin p-x @ 0= if rdrop exit then p-y @ p-x @ pos-prev drop pos-cls r@ = while 2drop repeat
  p-x ! p-y ! rdrop ;
: brk? ( c -- i|-1 ) 6 0 ?do brk i + c@ over = if drop i unloop exit then loop drop -1 ;
: pair-go ( c m fwd? -- f )                     \ to the bracket matching c (m: the other one)
  0 { c m fwd d }
  begin pos-get drop dup c = if d 1+ to d then m = if d 1- to d d 0= if true exit then then
    fwd if pos-next else pos-prev then 0= until false ;
: m-pair ( -- f )                               \ %: the first bracket at or after the cursor, then its match
  begin pos-get p-x @ > 0= if drop false exit then brk? dup 0< while drop 1 p-x +! repeat
  dup brk + c@ over 1 xor brk + c@ rot 1 and 0= pair-go ;

\ ==== overlay: motions ===================================================================================
overlay
: xcol ( a u col -- i )                         \ the last byte that starts at or before col (0: none)
  0 0 { a u col c i }
  begin i 1+ u < while  c a i + c@ 9 = if 7 or then 1+  dup col > if drop i exit then  to c  i 1+ to i
  repeat i ;
: mo-h ( n -- 0 ) mv-x @ swap - 0 max mv-x ! 0 ;
: mo-l ( n -- 0 ) mv-x @ + cur-text nip min mv-x ! 0 ;
: mo-jk ( line -- 2 ) mo-line  1 mv-w !  mv-y @ lfind want @ xcol mv-x ! 2 ;
: mo-fl ( line -- 2 ) mo-line  mv-y @ fnb mv-x ! 2 ;
: mo-p ( kind -- kind ) p-y @ mv-y ! p-x @ mv-x ! ;
: motion ( k -- kind )                          \ -1 none (or it failed), 0 to a byte, 1 to a byte (inclusive),
  cy @ dup mv-y ! p-y !  cx @ dup mv-x ! p-x !  0 mv-w !  cnt1 @ swap \ 2 to a line: mv-y mv-x (mv-w: 1 j k, 2 $)
  case
    'h' of mo-h endof  8 of mo-h endof  127 of mo-h endof  'l' of mo-l endof  bl of mo-l endof
    'j' of mv-y @ + mo-jk endof  14 of mv-y @ + mo-jk endof
    'k' of mv-y @ swap - mo-jk endof  16 of mv-y @ swap - mo-jk endof
    10 of mv-y @ + mo-fl endof  13 of mv-y @ + mo-fl endof  '+' of mv-y @ + mo-fl endof
    '-' of mv-y @ swap - mo-fl endof
    '0' of drop 0 mv-x ! 0 endof
    '^' of drop mv-y @ fnb mv-x ! 0 endof
    '$' of drop cur-text nip 1- 0 max mv-x !  2 mv-w ! 1 endof
    'G' of drop cnt @ 1- dup 0< if drop nl @ 1- then mo-fl endof
    'g' of drop getkey 'g' = if cnt @ 1- 0 max mo-fl else -1 then endof
    'w' of 0 ?do w-fwd loop 0 mo-p endof
    'b' of 0 ?do w-back loop 0 mo-p endof
    'e' of 0 ?do w-end loop 1 mo-p endof
    '%' of drop m-pair if 1 mo-p else -1 then endof
    'n' of drop sdir @ search if 0 else -1 then endof
    'N' of drop sdir @ negate search if 0 else -1 then endof
    nip -1 swap
  endcase ;

\ ==== overlay 12: operators, scrolling ==================================================================
overlay
: kmapk ( k -- k' ) dup $100 < if exit then $101 - dup 10 u< if kmap + c@ else drop 0 then ;
: count? ( n k -- n k f ) dup '0' - 10 u< over '0' <> 3 pick 0<> or and ; \ a digit of a count?
: op-span ( op kind -- )                        \ d c y over a motion to a byte
  cur-text nip { op kind len }
  cx @ mv-x @  cy @ mv-y @ < if drop len else
    cy @ mv-y @ > if drop 0 swap else 2dup > if swap then kind if 1+ then then then
  len min op op-chars ;
: c-op ( op -- )                                \ d c y: doubled for lines, or a motion (a count may come first)
  0 begin getkey count? while '0' - swap 10 * + repeat
  swap ?dup if cnt1 @ * dup cnt1 ! cnt ! then  kmapk
  2dup = if drop op-lcnt exit then
  over 'c' = over 'w' = and if cur-text cx @ > if cx @ + c@ ct 16 and 0= if drop 'e' then else drop then then
  motion dup 0< if 2drop exit then
  dup 2 = if drop cy @ mv-y @ 2dup > if swap then op-lines exit then
  op-span ;
: scroll ( lines cur -- )                       \ the screen moves, the cursor cur lines (-1: to the top line,
  swap top @ + nl @ 1- min 0 max dup top !      \   -2: to the bottom one)
  over -1 = if nip else over -2 = if nip trows @ + 1- else drop cy @ + then then
  cy !  1 dall !  fix-cursor  cy @ fnb cx ! ;

\ ==== overlay 13: normal mode ===========================================================================
overlay
: ncmd ( -- )                                   \ one command: a count, a key, what it does
  0 begin getkey 0 msgl ! count? while '0' - swap 10 * + repeat
  swap dup cnt ! 1 max cnt1 !  1 setw !  kmapk
  case
    'i' of c-ins endof  'a' of cur-text nip if 1 cx +! then c-ins endof
    'I' of cy @ fnb cx ! c-ins endof  'A' of cur-text nip cx ! c-ins endof
    'o' of cy @ 1+ c-open endof  'O' of cy @ c-open endof
    'x' of c-x endof  'X' of c-bs endof  'D' of 'd' c-DC endof  'C' of 'c' c-DC endof  's' of c-s endof
    'S' of 'c' op-lcnt endof  'Y' of 'y' op-lcnt endof
    'd' of 'd' c-op endof  'c' of 'c' c-op endof  'y' of 'y' c-op endof
    'r' of c-r endof  'J' of c-J endof  'p' of 1 put endof  'P' of 0 put endof
    'u' of c-u endof  18 of c-redo endof
    '.' of dot-len @ ?dup if rq-len ! 0 rq-pos ! cnt1 @ 1- dotn ! 1 rep ! then endof
    ':' of c-colon endof  '/' of 1 c-find endof  '?' of -1 c-find endof
    4 of trows @ 2/ dup scroll endof  21 of trows @ 2/ negate dup scroll endof
    6 of trows @ 2 - -1 scroll endof  2 of trows @ 2 - negate -2 scroll endof
    12 of 1 clear ! 1 dall ! esc[ ." 999;999H" esc[ ." 6n" endof
    7 of m-name m-size endof
    'Z' of getkey 'Z' = if 0 x-bang ! 0 x-argl ! ex-x then endof
    3 of m" Type :q and Enter to exit vi" endof
    $1c of 1 quit ! endof
    dup motion dup 0< 0= if mv-y @ cy ! mv-x @ cx !
      mv-w @ ?dup if 0 setw ! 2 = if bigcol want ! then then then drop
  endcase ;

: vi-loop ( -- )                                \ show, then one command, until :q
  begin refresh
    rq-pos @ rq-len @ < dotn @ or 0= if 0 rep ! then
    0 rec-len !  0 chg !  ncmd
    chg @ rep @ 0= and if rec-len @ dup dot-len ! recbuf dotbuf rot 2* move then
  quit @ until ;
resident

\ ==== overlay 14: starting and leaving ===================================================================
overlay
: vi-main ( a u -- )                            \ edit that file (u = 0: an empty buffer)
  hdl @ 3 = dup con ! if 1 0 0 19 3 (msg) drop then \ the console in raw mode (a pipe is already)
  1 0 0 22 1 (msg) drop                         \ interrupts come as READs that return -2
  80 cols !  24 rows !  0 numw !  size-upd  1 synon !  1 clear !  0 quit !  0 msgl !  0 ins !  0 lblive !
  0 kb-pos !  0 kb-len !  0 k-pend !  0 rq-pos !  0 rq-len !  0 dotn !  0 dot-len !  0 y-cnt !  0 patl !
  1 sdir !  0 dirty !
  esc[ ." 999;999H" esc[ ." 6n" flush           \ the size: the answer comes while the file is read
  120 min do-load
  100 rd-wait if kbuf kb-pos @ + c@ 27 = if getkey dup $10b = if drop else k-pend ! then then then
  vi-loop
  esc[ ." H" esc[ ." 2J" flush
  con @ if 0 0 0 19 3 (msg) drop then  0 0 0 22 1 (msg) drop ;
: vi ( "name" -- ) parse-name vi-main ;         \ at the Forth prompt: vi FILE
: cmd-word ( a u -- rest u' word u2 )           \ the next word of the command line
  begin dup if over c@ bl = else false then while 1 /string repeat
  2dup begin dup if over c@ bl <> else false then while 1 /string repeat 2swap drop 2 pick over - ;
resident

