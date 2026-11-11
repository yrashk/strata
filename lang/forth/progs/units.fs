\ units.fs: a program larger than its code cache (the Forth port of os/progs/units.s)
\   forth units.fs
\ units.s has 24 functions, each in its own 1 KiB code unit that the kernel pages in
\ (xcall, xmiss) into a code cache of 16 slots. Here, too: every Forth word is in a
\ code unit that StrataOS pages (lang/forth/README.md, "Code paging"), and each of
\ the 24 functions is a little over 1 KiB (its code, then dead code after EXIT),
\ so it has a unit of its own, and they are three times the cache. A chain is
\ seven calls deep, so a function's unit is often evicted while the function
\ waits for its call to return, and comes back when it does (the far link). The
\ sum over 24 chains is checked against the same computation by one recursive
\ word, and the number of units the dispatcher paged in is shown (UNIT-STATS).
[defined] sys.fs 0= [if] include /sys.fs [then]

create mult 3 , 15 , 27 , 39 , 51 , 63 , 75 , 87 , 99 , 14 , 26 , 38 ,  \ each function's multiplier
            50 , 62 , 74 , 86 , 98 , 13 , 25 , 37 , 49 , 61 , 73 , 85 ,
create addc 1 , 504 , 7 , 510 , 13 , 516 , 19 , 522 , 25 , 528 , 31 , 534 , \ constant
            37 , 540 , 43 , 546 , 49 , 552 , 55 , 558 , 61 , 564 , 67 , 570 ,
create nxt  5 , 12 , 19 , 2 , 9 , 16 , 23 , 6 , 13 , 20 , 3 , 10 ,         \ the one it calls
            17 , 0 , 7 , 14 , 21 , 4 , 11 , 18 , 1 , 8 , 15 , 22 ,
create uxt 24 cells allot                       \ their xts
: call-unit ( x d k -- r ) cells uxt + @ execute ;
: ref ( k x d -- r )                            \ the same computation, in one word
  >r over cells mult + @ * over cells addc + @ +
  r> ?dup if 1- >r swap cells nxt + @ over $ffff and r> recurse + else nip then ;
: pad ( -- ) 270 0 do 0 insn, loop ; immediate  \ 1 KiB of code that never runs (nops)

\ f(x, d) = x * multiplier + constant, plus the next function's f(that & $ffff, d - 1) when d > 0
: u0  swap  3 * 1   + swap ?dup if 1- over $ffff and swap  5 call-unit + then exit pad ;
: u1  swap 15 * 504 + swap ?dup if 1- over $ffff and swap 12 call-unit + then exit pad ;
: u2  swap 27 * 7   + swap ?dup if 1- over $ffff and swap 19 call-unit + then exit pad ;
: u3  swap 39 * 510 + swap ?dup if 1- over $ffff and swap  2 call-unit + then exit pad ;
: u4  swap 51 * 13  + swap ?dup if 1- over $ffff and swap  9 call-unit + then exit pad ;
: u5  swap 63 * 516 + swap ?dup if 1- over $ffff and swap 16 call-unit + then exit pad ;
: u6  swap 75 * 19  + swap ?dup if 1- over $ffff and swap 23 call-unit + then exit pad ;
: u7  swap 87 * 522 + swap ?dup if 1- over $ffff and swap  6 call-unit + then exit pad ;
: u8  swap 99 * 25  + swap ?dup if 1- over $ffff and swap 13 call-unit + then exit pad ;
: u9  swap 14 * 528 + swap ?dup if 1- over $ffff and swap 20 call-unit + then exit pad ;
: u10 swap 26 * 31  + swap ?dup if 1- over $ffff and swap  3 call-unit + then exit pad ;
: u11 swap 38 * 534 + swap ?dup if 1- over $ffff and swap 10 call-unit + then exit pad ;
: u12 swap 50 * 37  + swap ?dup if 1- over $ffff and swap 17 call-unit + then exit pad ;
: u13 swap 62 * 540 + swap ?dup if 1- over $ffff and swap  0 call-unit + then exit pad ;
: u14 swap 74 * 43  + swap ?dup if 1- over $ffff and swap  7 call-unit + then exit pad ;
: u15 swap 86 * 546 + swap ?dup if 1- over $ffff and swap 14 call-unit + then exit pad ;
: u16 swap 98 * 49  + swap ?dup if 1- over $ffff and swap 21 call-unit + then exit pad ;
: u17 swap 13 * 552 + swap ?dup if 1- over $ffff and swap  4 call-unit + then exit pad ;
: u18 swap 25 * 55  + swap ?dup if 1- over $ffff and swap 11 call-unit + then exit pad ;
: u19 swap 37 * 558 + swap ?dup if 1- over $ffff and swap 18 call-unit + then exit pad ;
: u20 swap 49 * 61  + swap ?dup if 1- over $ffff and swap  1 call-unit + then exit pad ;
: u21 swap 61 * 564 + swap ?dup if 1- over $ffff and swap  8 call-unit + then exit pad ;
: u22 swap 73 * 67  + swap ?dup if 1- over $ffff and swap 15 call-unit + then exit pad ;
: u23 swap 85 * 570 + swap ?dup if 1- over $ffff and swap 22 call-unit + then exit pad ;
: uxt! ( xt0 .. xt23 -- ) 0 23 do uxt i cells + ! -1 +loop ;
' u0  ' u1  ' u2  ' u3  ' u4  ' u5  ' u6  ' u7  ' u8  ' u9  ' u10 ' u11
' u12 ' u13 ' u14 ' u15 ' u16 ' u17 ' u18 ' u19 ' u20 ' u21 ' u22 ' u23  uxt!
: units-main ( a u -- )
  2drop ." units: 24 functions of 1 KiB, chains 7 calls deep" cr
  unit-stats drop  0 0 24 0 do  swap i 1+ 6 i call-unit +  swap i i 1+ 6 ref +  loop ( misses paged resident )
  ." paged sum   = " over .u cr  ." resident sum= " dup .u cr
  = if ." check: ok" else ." check: MISMATCH" then cr
  ." [" unit-stats drop swap - .u ."  code units paged in]" cr ;
' units-main main: units
