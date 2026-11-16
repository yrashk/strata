\ free.fs: how much memory is left (the Forth port of os/progs/free.s)
\   forth free.fs
\   total:  786432 KiB  (768 MiB)
\   free:   524288 KiB  (512 MiB)
\   processes: 7
[defined] sys.fs 0= [if] include /sys.fs [then]

create info 64 allot                            \ proc's INFO: u64 cores, free heap, memory, processes, ...
: heap-free ( -- u ) info 8 + @ ;
: memory    ( -- u ) info 16 + @ ;
: processes ( -- n ) info 24 + @ ;
: amount ( bytes -- ) dup 10 rshift 8 u.r ."  KiB  (" 20 rshift .u ."  MiB)" cr ;
: free-main ( a u -- )
  2drop  0 0 0 op-info proc 0< if s" free: cannot ask the process server" fail then  info 64 msg>
  ." total: " memory amount  ." free:  " heap-free amount  ." processes: " processes .u cr ;
' free-main main: free
