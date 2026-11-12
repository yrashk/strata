\ cores.fs: what every core is doing (the Forth port of os/progs/cores.s)
\   forth cores.fs
\   core 0: system
\   core 1: running 3, 1 runnable, 4 processes, server; 120 switches, 40 KiB moved, 41 slots free
\ proc's CORES: a 32-byte record per core (u8 core, pid running (0 none), runnable,
\ processes, flags (1 exclusive, 2 server, 4 solo), free slots of the core's
\ capability save table; u32 switches, u32 KiB moved at 8 and 12).
[defined] sys.fs 0= [if] include /sys.fs [then]

create tab 16 32 * allot
: flag. ( r bit a u -- r ) 2>r over 4 + c@ and if 2r> type else 2r> 2drop then ;
: cores-main ( a u -- )
  2drop 0 0 0 31 proc dup 0< if drop s" cores: cannot ask the process server" +e e! 1 stop then
  16 min  tab over 32 * msg>
  0 ?do tab i 32 * +  ." core " dup c@ dup .u
    0= if ." : system" else
      dup 1+ c@ ?dup if ." : running " .u else ." : idle" then
      ." , " dup 2 + c@ .u ."  runnable, " dup 3 + c@ .u ."  processes"
      1 s" , exclusive" flag.  2 s" , server" flag.  4 s" , solo" flag.
      ." ; " dup 8 + l@ .u ."  switches, " dup 12 + l@ .u ."  KiB moved, " dup 5 + c@ .u ."  slots free"
    then drop cr
  loop ;
' cores-main main: cores
