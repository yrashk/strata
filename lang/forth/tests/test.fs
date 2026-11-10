\ Strata Forth regression test. Fed on the console of both machines (bare
\ metal), and to `forth -n 6` under StrataOS (make test-forth; expected
\ output: tests/test.out). Lines that start with "23 kvar @" are for one
\ platform only and are left out of the StrataOS comparison.
\ Lines are echoed; each ends with " ok" or an error message.
\ ---- arithmetic and stack
1 2 + . 7 3 - . 6 7 * . 100 7 / . 100 7 mod . -7 2 / .
1 2 3 rot .s drop drop drop
5 dup . drop  1 2 swap . .  1 2 over . . .  1 2 nip .  1 2 tuck . . .
-5 abs . 3 9 min . 3 9 max . 5 negate . 0 invert . 1 10 lshift . -16 2 arshift .
3 4 = . 3 3 = . 2 3 < . -1 0 u< . 0 0= . 7 0<> .
$ff . %1010 . #99 . 'z' . -$10 .
\ ---- definitions, control flow, recursion
: sq ( n -- n*n ) dup * ;  12 sq .
: fact ( n -- n! ) dup 1 > if dup 1- recurse * then ;  20 fact .
: fib ( n -- f ) dup 2 < if exit then dup 1- recurse swap 2 - recurse + ;  20 fib .
: sum ( n -- s ) 0 swap 0 ?do i + loop ;  1000 sum .  0 sum .
: evens 10 0 do i . 3 +loop ;  evens
: down 0 5 do i . -1 +loop ;  down
: grid 3 0 do 3 0 do j 3 * i + . loop loop ;  grid
: find5 100 0 do i 5 = if i unloop exit then loop -1 ;  find5 .
: lv 10 0 do i 4 > if leave then i . loop ." left" ;  lv
: count-down ( n -- ) begin dup . 1- dup 0= until drop ;  5 count-down
: w ( n -- ) begin dup while dup . 2/ repeat drop ;  100 w
: kind ( n -- ) case 0 of ." zero" endof 1 of ." one" endof ." many" endcase space ;
0 kind 1 kind 7 kind
\ ---- data, defining words, strings
variable v  42 v !  v @ .  5 v +!  v ?
10 constant ten  ten ten * .
5 value five  five .  7 to five  five .
: counter create , does> dup @ 1+ dup rot ! ;  0 counter next-id
next-id . next-id . next-id .
create table 1 , 2 , 3 ,  table 2 cells + @ .
s" hello" type space  s" abc" s" abd" compare .  s" abc" s" abc" str= .
: greet ." Hello, " type ." !" ;  s" Strata" greet
42 <# #s #> type space  255 hex . decimal  -42 8 .r 42 8 u.r
defer action  ' sq is action  9 action .
\ ---- locals, quotations, catch / throw, errors
: diff { a b -- } a b - ;  10 3 diff .
: swap-sub { a b -- } b a - ;  10 3 swap-sub .
: twice ( xt -- ) dup execute execute ;  : bump [: 1+ ;] twice ;  40 bump .
: risky ( n -- ) 0= if 99 throw then ;  1 ' risky catch .  0 ' risky catch .
: safe-div ( a b -- q ) ['] / catch if 2drop 0 then ;  10 2 safe-div .
frobnicate
1 2 3 + + + +
: broken 1 2 frob ;
3 4 + .
\ ---- the compiler, made visible
$0508FFF8 dis
$A4010000 dis
: fold-test ( n -- n ) 5 + 3 and ;  1 fold-test .
' sq xt>name name>string type space ' + xt>name name>flags .
\ ---- capabilities, transfers, the far cache
heap-cap cvalid . 15 cvalid .  1 cperms $ff and h.
23 kvar @ 0= [if] 8 clen h. 9 cbase h. 0 cperms h. 1 cperms h. 12 cperms h. [then]
23 kvar @ [if] 0 clen h. 5 clen h. 0 cperms h. 1 cperms h. 3 cperms h. [then]
create buf 64 allot  buf 64 erase
123 buf !  456 buf cell+ !
buf 0 16 heap-cap tput  heap-cap tag twait  buf 16 erase  buf 0 16 heap-cap tget  heap-cap tag twait  buf @ . buf cell+ @ .
0 far@ .  777 64 far!  64 far@ .  fflush  buf 64 8 heap-cap tget heap-cap tag twait buf @ .
: fill-far 512 0 do i 3 * i far! 8 +loop ;  fill-far  256 far@ .
finval fcache-reset  : sum-far 0 512 0 do i far@ + 8 +loop ;  sum-far .  .fcache
fcache-reset : stride ( n -- ) 0 do i i far! 64 +loop ;  65536 stride  65472 far@ .  .fcache
far-size constant hsize  heap-cap 4096 tmp-cap csplit  tmp-cap clen hsize 4096 - = .  far-size .
heap-cap tmp-cap cjoin  far-size hsize = .  tmp-cap cvalid .
\ ---- cores
cores 5 > .
: square-on ( n -- n*n ) dup * ;  7 1 ' square-on 1 spawn  1 await .
' core# 5 run-on .
: sumsq ( lo hi -- s ) 0 -rot swap ?do i dup * + loop ;
0 1000 2 ' sumsq 1 spawn  1000 2000 2 ' sumsq 2 spawn  1 await 2 await + .
: oops 1 0 ?do frob loop ;
: under drop drop ;  ' under 3 run-on
3 await
' core# 9 run-on
: far-job ( -- x ) heap-cap 0 take  128 far@  heap-cap 0 give ;
0 ' far-job 4 spawn  fflush finval  heap-cap 4 give  heap-cap 4 take  4 await .
16 1 atomic@ h.
\ ---- the end
bye
