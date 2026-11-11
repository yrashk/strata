\ free.fs: how much memory is left (the Forth port of os/progs/free.s)
\   forth free.fs
\   total:  786432 KiB  (768 MiB)
\   free:   524288 KiB  (512 MiB)
\   processes: 7
\ From proc's INFO (64 bytes: u64 cores, free heap, memory, processes, ...).
[defined] sys.fs 0= [if] include /sys.fs [then]

create info 64 allot
: amount ( bytes -- ) dup 10 rshift 8 u.r ."  KiB  (" 20 rshift .u ."  MiB)" cr ;
: free-main ( a u -- )
  2drop 0 0 0 16 proc 0< if s" free: cannot ask the process server" +e e! 1 stop then  info 64 msg>
  ." total: " info 16 + @ amount  ." free:  " info 8 + @ amount  ." processes: " info 24 + @ .u cr ;
' free-main main: free
