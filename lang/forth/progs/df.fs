\ df.fs: how full the disk is (the Forth port of os/progs/df.s)
\   forth df.fs                disk: T blocks, U used, F free, N files
[defined] sys.fs 0= [if] include /sys.fs [then]

32 constant op-statfs                           \ STATFS: u64 total blocks, used blocks, files
create st 24 allot
: total ( -- n ) st @ ;
: used  ( -- n ) st 8 + @ ;
: files ( -- n ) st 16 + @ ;
: df-main ( a u -- )
  2drop  0 0 0 op-statfs fs 0> 0= if s" df: cannot ask the file server" fail then  st 24 msg>
  ." disk: " total .u ."  blocks, " used .u ."  used, " total used - .u ."  free, " files .u ."  files" cr ;
' df-main main: df
