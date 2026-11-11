\ paging.fs: a program bigger than the code cache, run while another program
\ shares the core (tests/run-os.sh, part 5). Twelve words of a little over
\ 1 KiB each (dead code after EXIT) have a code unit each, about twice the
\ code cache; they call one another in chains ten deep, so a caller's unit is
\ evicted while it waits for the call to return, and paged back in when it
\ does (xret through the far link). Some of them sleep in a resident word
\ (MS: an svc, so the core goes to the other program, and comes back with a
\ return address into a slot on the stack), one loops long enough to be
\ preempted (its pc in a slot). The result is checked against the same
\ computation by one recursive word.
: pad ( -- ) 270 0 do 0 insn, loop ; immediate  \ 1 KiB of code that never runs
create xts 12 cells allot                       \ the words' xts
: nxt ( x d k -- r ) cells xts + @ execute ;
: spin ( -- ) 30000 0 do loop ;                 \ (a while: a slice or two)
: p0  swap  3 * 0  + swap ?dup if 1- over $fff and swap  5 nxt + then spin exit pad ;
: p1  swap  4 * 1  + swap ?dup if 1- over $fff and swap  6 nxt + then exit pad ;
: p2  swap  5 * 2  + swap ?dup if 1- over $fff and swap  7 nxt + then exit pad ;
: p3  swap  6 * 3  + swap ?dup if 1- over $fff and swap  8 nxt + then 1 ms exit pad ;
: p4  swap  7 * 4  + swap ?dup if 1- over $fff and swap  9 nxt + then exit pad ;
: p5  swap  8 * 5  + swap ?dup if 1- over $fff and swap 10 nxt + then exit pad ;
: p6  swap  9 * 6  + swap ?dup if 1- over $fff and swap 11 nxt + then exit pad ;
: p7  swap 10 * 7  + swap ?dup if 1- 1 ms over $fff and swap  0 nxt + then exit pad ;
: p8  swap 11 * 8  + swap ?dup if 1- over $fff and swap  1 nxt + then exit pad ;
: p9  swap 12 * 9  + swap ?dup if 1- over $fff and swap  2 nxt + then exit pad ;
: p10 swap 13 * 10 + swap ?dup if 1- over $fff and swap  3 nxt + then exit pad ;
: p11 swap 14 * 11 + swap ?dup if 1- over $fff and swap  4 nxt + then 1 ms exit pad ;
' p0 xts !  ' p1 xts 8 + !  ' p2 xts 16 + !  ' p3 xts 24 + !  ' p4 xts 32 + !  ' p5 xts 40 + !
' p6 xts 48 + !  ' p7 xts 56 + !  ' p8 xts 64 + !  ' p9 xts 72 + !  ' p10 xts 80 + !  ' p11 xts 88 + !
: ref ( k x d -- r )                            \ the same, in one word
  >r over 3 + * over + r> ?dup if 1- >r swap 5 + 12 mod over $fff and r> recurse + else nip then ;
: run ( -- paged resident )
  0 0 12 0 do  swap i 100 + 9 i nxt +  swap i i 100 + 9 ref +  loop ;
: test ( -- )
  unit-stats drop >r  run  unit-stats drop r> - >r
  ." paged " over . ." resident " dup . = if ." equal" else ." DIFFERENT" then cr
  r> 100 > if ." the units were paged in again and again" else ." too few misses" then cr ;
test bye
