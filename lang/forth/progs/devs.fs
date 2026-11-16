\ devs.fs: the machine's platform table (the Forth port of os/progs/devs.s)
\   forth devs.fs
\   memory   0 space 3 base 0x0000000000000000 size 805306368 info 0
\ Asks the device manager (dev: (msg)'s register 6, looked up by the name in KVAR
\ 41, which is "net" otherwise) for DEVS.
[defined] sys.fs 0= [if] include /sys.fs [then]

23 constant op-devs                             \ DEVS: a 32-byte entry per device
16 constant max-devs
32 constant /entry
: kind#     ( e -- n ) w@ ;                     \ 1 memory, 2 console, 3 platform, 4 block, 5 fb,
: index     ( e -- n ) 2 + w@ ;                 \ 6 timer, 7 pointer, 8 net, 9 sound, 10 pagemap
: addr-space ( e -- n ) 4 + w@ ;
: info      ( e -- u ) 8 + @ ;
: base-addr ( e -- a ) 16 + @ ;
: size      ( e -- u ) 24 + @ ;

create tab  max-devs /entry * allot
: entry ( i -- e ) /entry * tab + ;
41 kvar constant server-name                    \ the server (msg)'s register 6 looks up
: dev-devs ( -- n )                             \ DEVS, from "dev" for once
  server-name @  $766564 server-name !  0 0 0 op-devs 6 (msg)  swap server-name ! ;
: ask ( -- n )                                  \ the entries, into tab: how many
  dev-devs dup 0< if drop s" devs: no device manager" fail then
  max-devs min  tab over /entry * msg> ;

: kind ( n -- a u )                             \ its name, 9 columns
  dup 11 u< 0= if drop 0 then
  9 * s" ?        memory   console  platform block    fb       timer    pointer  net      sound    pagemap  " drop + 9 ;
: entry. ( e -- )
  dup kind# kind type  dup index .u  ."  space " dup addr-space .u  ."  base 0x" dup base-addr 16 hex.
  ."  size " dup size .u  ."  info " info .u cr ;
: devs-main ( a u -- ) 2drop  ask 0 ?do i entry entry. loop ;
' devs-main main: devs
