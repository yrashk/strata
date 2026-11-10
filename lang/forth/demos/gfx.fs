\ =============================================================================
\ demos/gfx.fs: a parallel Mandelbrot set, drawn into the framebuffer
\ =============================================================================
\ Run (bare metal; a small screen keeps the emulator quick):
\   build/strata-emu -c 8 -r 320x200 -i lang/forth/demos/gfx.fs build/forth.stx
\   ... -g none -F frame.ppm  writes the picture to a file instead of a window
\
\ The framebuffer is ordinary system memory: core 0 holds it as capability
\ c9. It is cut into one band of rows per worker (CSPLIT) and each band is
\ given away. A worker renders a row into its D-LS and TPUTs it into its
\ band; nobody else can write there. The bands come back in order, are
\ joined, and core 0 writes PRESENT through the device capability c3.

23 kvar @ [if] .( gfx.fs needs bare metal) cr abort [then]

\ ---- the screen's geometry, from the platform table (device space $1000)
create ptab 256 allot
ptab $1000 256 3 tget  3 tag twait      \ the table, through c3 with tag tg3
: entry ( i -- addr ) 32 * ptab 32 + + ;
: fb-info ( -- info )                   \ the PT_FB entry's info word
  ptab 8 + w@ 0 do i entry w@ 5 = if i entry 8 + @ unloop exit then loop 0 ;
fb-info constant info
info $ffff and constant width
info 16 rshift $ffff and constant height
info 32 rshift $ffff and constant stride
.( framebuffer ) width . .( x ) height . .( stride ) stride . cr

\ ---- the picture: fixed point with 16 fraction bits
16 constant fb                          \ fraction bits
1 fb lshift constant one                \ 1.0
48 constant maxit                       \ iteration limit
: f* ( a b -- a*b ) * fb arshift ;      \ fixed-point multiply
-2 one * one 2/ - constant x0           \ left edge: -2.5
-1 one * one 4 / - constant y0          \ top edge: -1.25
7 one * 2/ width / constant dx          \ 3.5 wide
5 one * 2/ height / constant dy         \ 2.5 high
: iters ( cx cy -- n )                  \ escape time of one point
  { cx cy }  0 0
  maxit 0 do
    over dup f*  over dup f*            ( zx zy zx2 zy2 )
    2dup + 4 one * > if 2drop 2drop i unloop exit then
    - cx +  -rot f* 2* cy +             ( zx' zy' )
  loop 2drop maxit ;
: color ( n -- xrgb )                   \ a palette: black inside, bands outside
  dup maxit = if drop 0 exit then
  dup 9 * 255 and 16 lshift  over 5 * 255 and 8 lshift or  swap 17 * 255 and or ;
create rowbuf 1280 4 * allot            \ one row of pixels (up to 1280 wide)
: row ( y -- )                          \ render row y into rowbuf
  dy * y0 +  width 0 do  i dx * x0 +  over iters color  rowbuf i 4 * + l!  loop drop ;

\ ---- the jobs
height workers + 1- workers / constant rows  \ rows per band
rows stride * constant band              \ bytes per band
: job ( k -- )                           \ worker k draws rows [(k-1)*rows, k*rows)
  9 0 take                               \ our band: its offset 0 is our first row
  1- rows *  rows 0 do
    dup i + dup height < if row  rowbuf  i stride *  width 4 *  9 tput else drop then
  loop drop
  9 0 give ;                             \ give the band back (after our transfers)
: deal ( -- )                            \ start the jobs, then hand out the bands
  cores 1 ?do  i 1 ['] job i spawn  loop
  cores 1 ?do  9 band 11 csplit  9 i give  11 9 cmov  loop ;
: collect ( -- )                         \ bands back in order, joined
  11 1 take  cores 2 ?do  7 i take  11 7 cjoin  loop
  11 9 cjoin  11 9 cmov
  cores 1 ?do  i await  loop ;
create present-word 0 ,
: present ( -- ) present-word $4000 8 3 tput ; \ PRESENT: show the framebuffer
: draw ( -- ) deal collect present ;
width 1280 > [if] .( wider than 1280: use -r WxH) cr abort [then]
.( drawing with ) workers . .( workers, ) rows . .( rows each ... ) ' draw timeit cr
9 .cap
