\ =============================================================================
\ demos/multicore.fs: a parallel sum over far memory, by moving ownership
\ =============================================================================
\ Run:  build/strata-emu -c 8 -i lang/forth/demos/multicore.fs build/forth.stx
\ or, under StrataOS, with threads:  -n 4 forth multicore.fs
\
\ Core 0 fills an array in the far heap (through FAR!, i.e. its software
\ cache), writes the cache back, then cuts the heap capability into one
\ slice per worker with CSPLIT and GIVEs each worker its slice. A worker
\ TAKEs the slice as its own heap capability, so FAR@ on that core reads the
\ slice through the worker's own cache; it sums it, gives the slice back and
\ returns the sum. Core 0 TAKEs the slices back, last one first, and CJOINs
\ them: the heap is whole again. No memory is ever shared: it changes hands.
\ (heap-cap is c8 on bare metal and c6 under StrataOS; tmp-cap, the one
\ spare capability register a StrataOS process has, is c11 or c7.)

cores 1 = [if] .( multicore.fs needs worker cores: under StrataOS start it as  -n 4 forth multicore.fs) cr abort [then]
23 kvar @ [if] require tools [then]             \ .cap is used inside a definition below

far-size workers / cell / 4096 min constant n   \ cells per worker (at most what the heap has)
n cells constant slice                          \ bytes per worker

: fill ( -- ) workers n * 0 do  i  i cells far!  loop ;  \ a[i] = i
: job ( k -- sum )                      \ runs on worker k
  drop  heap-cap 0 take                 \ our slice becomes our heap
  0  n 0 do  i cells far@ +  loop       \ sum it through our own far cache
  heap-cap 0 give ;                     \ hand it back (before the doorbell)
: deal ( -- )                           \ start the jobs, then give each its slice
  cores 1 ?do  i 1 ['] job i spawn  loop
  cores 1 ?do  heap-cap slice tmp-cap csplit  heap-cap i give  tmp-cap heap-cap cmov  loop ;
: collect ( -- total )                  \ slices back, the last one first, each joined
  1 cores 1- do  tmp-cap i take  tmp-cap heap-cap cjoin  tmp-cap heap-cap cmov  -1 +loop
  0  cores 1 ?do  i await +  loop ;     \ to what we hold: the heap is whole; then the sums
: expected ( -- n ) workers n * dup 1- * 2/ ;

.( filling ) workers n * . .( cells of far memory ... ) fill fflush finval .( done) cr
heap-cap .cap
: go ( -- )
  ." dealing " workers . ." slices of " slice . ." bytes; the heap is now " deal heap-cap .cap
  collect ." sum = " . ." expected " expected . cr ;
' go timeit cr
.( heap after: ) heap-cap .cap
