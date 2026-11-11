\ units.fs: a program larger than its code space, in overlays (the Forth port of os/progs/units.s)
\   forth units.fs
\ units.s has 24 functions, each in its own 1 KiB code unit that the kernel pages in
\ (xcall, xmiss) into a code cache of 16 slots. Here each function is a code overlay
\ of its own (overlay.fs), brought in by the program when it is called: one
\ overlay region, so every call of another function swaps code, and a function
\ that called another is brought back when the call returns (OVCALL). A chain
\ is seven calls deep; the sum over 24 chains is checked against the same
\ computation by resident code, and the number of overlays brought in is shown
\ (units.s: the kernel's count of units loaded).
[defined] sys.fs 0= [if] include /sys.fs [then]
[defined] overlay.fs 0= [if] include /overlay.fs [then]
inline-limit @  4 inline-limit !

create mult 3 , 15 , 27 , 39 , 51 , 63 , 75 , 87 , 99 , 14 , 26 , 38 ,  \ each function's multiplier
            50 , 62 , 74 , 86 , 98 , 13 , 25 , 37 , 49 , 61 , 73 , 85 ,
create addc 1 , 504 , 7 , 510 , 13 , 516 , 19 , 522 , 25 , 528 , 31 , 534 , \ constant
            37 , 540 , 43 , 546 , 49 , 552 , 55 , 558 , 61 , 564 , 67 , 570 ,
create nxt  5 , 12 , 19 , 2 , 9 , 16 , 23 , 6 , 13 , 20 , 3 , 10 ,         \ the one it calls
            17 , 0 , 7 , 14 , 21 , 4 , 11 , 18 , 1 , 8 , 15 , 22 ,
create uxt 24 cells allot                       \ their overlay xts
: call-unit ( x d k -- r ) cells uxt + @ ovcall ; \ (OVCALL: the caller's overlay comes back after)
: ref ( k x d -- r )                            \ the same computation, resident
  >r over cells mult + @ * over cells addc + @ +
  r> ?dup if 1- >r swap cells nxt + @ over $ffff and r> recurse + else nip then ;

24 128 overlays
\ f(x, d) = x * multiplier + constant, plus the next function's f(that & $ffff, d - 1) when d > 0
overlay : u0  swap  3 * 1   + swap ?dup if 1- over $ffff and swap  5 call-unit + then ;
overlay : u1  swap 15 * 504 + swap ?dup if 1- over $ffff and swap 12 call-unit + then ;
overlay : u2  swap 27 * 7   + swap ?dup if 1- over $ffff and swap 19 call-unit + then ;
overlay : u3  swap 39 * 510 + swap ?dup if 1- over $ffff and swap  2 call-unit + then ;
overlay : u4  swap 51 * 13  + swap ?dup if 1- over $ffff and swap  9 call-unit + then ;
overlay : u5  swap 63 * 516 + swap ?dup if 1- over $ffff and swap 16 call-unit + then ;
overlay : u6  swap 75 * 19  + swap ?dup if 1- over $ffff and swap 23 call-unit + then ;
overlay : u7  swap 87 * 522 + swap ?dup if 1- over $ffff and swap  6 call-unit + then ;
overlay : u8  swap 99 * 25  + swap ?dup if 1- over $ffff and swap 13 call-unit + then ;
overlay : u9  swap 14 * 528 + swap ?dup if 1- over $ffff and swap 20 call-unit + then ;
overlay : u10 swap 26 * 31  + swap ?dup if 1- over $ffff and swap  3 call-unit + then ;
overlay : u11 swap 38 * 534 + swap ?dup if 1- over $ffff and swap 10 call-unit + then ;
overlay : u12 swap 50 * 37  + swap ?dup if 1- over $ffff and swap 17 call-unit + then ;
overlay : u13 swap 62 * 540 + swap ?dup if 1- over $ffff and swap  0 call-unit + then ;
overlay : u14 swap 74 * 43  + swap ?dup if 1- over $ffff and swap  7 call-unit + then ;
overlay : u15 swap 86 * 546 + swap ?dup if 1- over $ffff and swap 14 call-unit + then ;
overlay : u16 swap 98 * 49  + swap ?dup if 1- over $ffff and swap 21 call-unit + then ;
overlay : u17 swap 13 * 552 + swap ?dup if 1- over $ffff and swap  4 call-unit + then ;
overlay : u18 swap 25 * 55  + swap ?dup if 1- over $ffff and swap 11 call-unit + then ;
overlay : u19 swap 37 * 558 + swap ?dup if 1- over $ffff and swap 18 call-unit + then ;
overlay : u20 swap 49 * 61  + swap ?dup if 1- over $ffff and swap  1 call-unit + then ;
overlay : u21 swap 61 * 564 + swap ?dup if 1- over $ffff and swap  8 call-unit + then ;
overlay : u22 swap 73 * 67  + swap ?dup if 1- over $ffff and swap 15 call-unit + then ;
overlay : u23 swap 85 * 570 + swap ?dup if 1- over $ffff and swap 22 call-unit + then ;
resident
: uxt! ( xt0 .. xt23 -- ) 0 23 do uxt i cells + ! -1 +loop ;
' u0  ' u1  ' u2  ' u3  ' u4  ' u5  ' u6  ' u7  ' u8  ' u9  ' u10 ' u11
' u12 ' u13 ' u14 ' u15 ' u16 ' u17 ' u18 ' u19 ' u20 ' u21 ' u22 ' u23  uxt!
: units-main ( a u -- )
  2drop ." units: 24 functions in 24 code overlays, chains 7 calls deep" cr
  ovl-loads @  0 0 24 0 do  swap i 1+ 6 i call-unit +  swap i i 1+ 6 ref +  loop ( loads paged resident )
  ." paged sum   = " over .u cr  ." resident sum= " dup .u cr
  = if ." check: ok" else ." check: MISMATCH" then cr
  ." [" ovl-loads @ swap - .u ."  overlays brought in]" cr ;
inline-limit !
' units-main main: units
