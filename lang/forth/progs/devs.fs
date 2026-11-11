\ devs.fs: the machine's platform table (the Forth port of os/progs/devs.s)
\   forth devs.fs
\   memory   0 space 3 base 0x0000000000000000 size 805306368 info 0
\ Asks the device manager (dev: (msg)'s register 6, looked up by the name in KVAR
\ 41, which is "net" otherwise) for DEVS: 32-byte entries of u16 type, index, space,
\ node, u64 info, base, size. Types: 1 memory, 2 console, 3 platform, 4 block, 5 fb,
\ 6 timer, 7 pointer, 8 net.
[defined] sys.fs 0= [if] include /sys.fs [then]

create tab 16 32 * allot
: dev-devs ( -- n ) 41 kvar dup @ >r  $766564 swap !  0 0 0 23 6 (msg)  r> 41 kvar ! ; \ "dev", then "net" again
: kind ( type -- a u ) dup 9 u< 0= if drop 0 then 9 * s" ?        memory   console  platform block    fb       timer    pointer  net      " drop + 9 ;
: hex16 ( u -- ) base @ >r hex <# 16 0 do # loop #> type r> base ! ;
: devs-main ( a u -- )
  2drop dev-devs dup 0< if drop s" devs: no device manager" +e e! 1 stop then
  16 min  tab over 32 * msg>
  0 ?do tab i 32 * + >r
    r@ w@ kind type  r@ 2 + w@ .u ."  space " r@ 4 + w@ .u ."  base 0x" r@ 16 + @ hex16
    ."  size " r@ 24 + @ .u ."  info " r@ 8 + @ .u cr rdrop
  loop ;
' devs-main main: devs
