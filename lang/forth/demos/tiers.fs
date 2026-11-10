\ =============================================================================
\ demos/tiers.fs: memory tiers, capabilities and code installation, by hand
\ =============================================================================
\ Run:  build/strata-emu -c 8 -i lang/forth/demos/tiers.fs build/forth.stx
\ (or feed it to `make forth`); under StrataOS:  -n 2 forth tiers.fs
\ heap-cap is the far heap's capability register (c8 bare metal, c6 StrataOS),
\ tmp-cap a spare one (c11 / c7).

cr .( ---- 1. the capability registers this core holds ----) cr
.caps

cr .( ---- 2. carve 4 KiB off the top of the heap into tmp-cap ----) cr
heap-cap dup clen 4096 - tmp-cap csplit
heap-cap .cap tmp-cap .cap

cr .( ---- 3. transfers: D-LS -> far -> D-LS, tagged with the register's number ----) cr
create a 512 allot   create b 512 allot
: init ( -- ) 64 0 do i i * a i cells + ! loop ;  init
a 0 512 tmp-cap tput     \ issue: returns at once, the hardware stalls reuse of a
b 0 512 tmp-cap tget     \ ... and the far data comes back into b
tmp-cap tag twait        \ wait for both (loads from b would wait anyway)
.( b[63] = ) b 63 cells + ? cr

cr .( ---- 4. what costs what: D-LS, far memory through the software cache ----) cr
: dls-sum ( -- n ) 0 64 0 do a i cells + @ + loop ;
: far-sum ( -- n ) 0 4096 0 do i far@ + 8 +loop ;
.( D-LS loop:            ) ' dls-sum timeit cr
finval fcache-reset
.( far loop, cold cache: ) ' far-sum timeit cr .fcache
.( far loop, warm cache: ) ' far-sum timeit cr .fcache

cr .( ---- 5. capabilities are enforced ----) cr
: too-far ( -- ) a 4096 8 tmp-cap tget ; \ the piece is 4096 bytes: offset 4096 is outside
' too-far catch .( throw code ) . cr
.( the fault: ) 9 kvar @ . .( = bounds ) cr

cr .( ---- 6. join it back: the heap is whole again ----) cr
heap-cap tmp-cap cjoin  heap-cap .cap  tmp-cap .cap

cr .( ---- 7. code is installed through far memory too ----) cr
true jit-trace
: cube ( n -- n^3 ) dup dup * * ;
false jit-trace
3 cube . cr
see cube
.jit

cr .( ---- 8. ownership moves: lend a piece to core 1, which reads it and gives it back ----) cr
: peek ( -- x ) tmp-cap 0 take  b 72 8 tmp-cap tget  b @  tmp-cap 0 give ;   \ cell 9: 81
0 ' peek 1 spawn                              \ the job first: it waits in TAKE
heap-cap dup clen 4096 - tmp-cap csplit  tmp-cap 1 give   \ the piece again, given to core 1
tmp-cap cvalid .( core 0 still holds the piece? ) . cr
tmp-cap 1 take  tmp-cap cvalid .( and now it is back: ) . cr
heap-cap tmp-cap cjoin                        \ (the scratch register must be free for AWAIT)
1 await .( core 1 read ) . cr
