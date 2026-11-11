\ df.fs: how full the disk is (the Forth port of os/progs/df.s)
\   forth df.fs                disk: T blocks, U used, F free, N files
\ From the file server's STATFS: total blocks, used blocks, files.
[defined] sys.fs 0= [if] include /sys.fs [then]

create st 24 allot
: df-main ( a u -- )
  2drop 0 0 0 32 fs 0> 0= if s" df: cannot ask the file server" +e e! 1 stop then  st 24 msg>
  ." disk: " st @ .u ."  blocks, " st 8 + @ .u ."  used, " st @ st 8 + @ - .u ."  free, "
  st 16 + @ .u ."  files" cr ;
' df-main main: df
