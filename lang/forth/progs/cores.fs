\ cores.fs: what every core is doing (the Forth port of os/progs/cores.s)
\   forth cores.fs
\   core 0: system
\   core 1: running 3, 1 runnable, 4 processes, server; 120 switches, 40 KiB moved, 41 slots free
[defined] sys.fs 0= [if] include /sys.fs [then]

31 constant op-cores                            \ proc's CORES: a 32-byte record per core
16 constant max-cores
32 constant /record
: core#     ( r -- n )   c@ ;
: running   ( r -- pid ) 1+ c@ ;                \ the process it runs, 0 none
: runnable  ( r -- n )   2 + c@ ;
: procs     ( r -- n )   3 + c@ ;
: flags     ( r -- n )   4 + c@ ;               \ 1 exclusive, 2 server, 4 solo
: slots     ( r -- n )   5 + c@ ;               \ free slots of its capability save table
: switches  ( r -- n )   8 + l@ ;
: kib-moved ( r -- n )   12 + l@ ;

create tab  max-cores /record * allot
: record ( i -- r ) /record * tab + ;
: ask ( -- n )                                  \ the records, into tab: how many
  0 0 0 op-cores proc  dup 0< if drop s" cores: cannot ask the process server" fail then
  max-cores min  tab over /record * msg> ;

: state.   ( r -- ) running ?dup if ." : running " .u else ." : idle" then ;
: load.    ( r -- ) ." , " dup runnable .u ."  runnable, " procs .u ."  processes" ;
: roles.   ( r -- )
  flags  dup 1 and s" , exclusive" ?type  dup 2 and s" , server" ?type  4 and s" , solo" ?type ;
: traffic. ( r -- )
  ." ; " dup switches .u ."  switches, " dup kib-moved .u ."  KiB moved, " slots .u ."  slots free" ;
: core. ( r -- )
  ." core " dup core# .u
  dup core# 0= if drop ." : system" cr exit then
  dup state.  dup load.  dup roles.  traffic. cr ;

: cores-main ( a u -- ) 2drop  ask 0 ?do i record core. loop ;
' cores-main main: cores
