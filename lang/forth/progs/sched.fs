\ sched.fs: show or set the preemption time slice (the Forth port of os/progs/sched.s)
\   forth sched.fs             the slice, and the switches and KiB moved per second since the last
\   forth sched.fs 500us       set it (100us .. 100ms): microseconds (no suffix), or us / ms
\   forth sched.fs 5ms
[defined] sys.fs 0= [if] include /sys.fs [then]

30 constant op-sched                            \ SCHED: handle 0 reads it, 1 sets it (length = the slice)
create info 24 allot                            \ what it reads: u64 slice, switches/s, KiB/s
: slice       ( -- us ) info @ ;
: switch-rate ( -- n )  info 8 + @ ;
: move-rate   ( -- n )  info 16 + @ ;
: sched-use ( -- ) s" usage: sched [N | Nus | Nms]  (100us .. 100ms)" usage ;
: show ( -- )
  0 0 0 op-sched proc if 1 stop then  info 24 msg>
  ." time slice: " slice .u ."  us; " switch-rate .u ."  switches/s, " move-rate .u
  ."  KiB/s moved by switches" cr ;
: in-us ( n a u -- us )                         \ the suffix: none or us (microseconds), ms
  dup 0= if 2drop exit then
  2dup s" ms" str= if 2drop 1000 * exit then
  s" us" str= 0= if sched-use then ;
: slice-arg ( a u -- us ) 2dup digits dup 0= if sched-use then  2swap rot /string in-us ;
: sched-main ( a u -- )
  dup 0= if 2drop show exit then
  slice-arg  1 swap 0 op-sched proc if sched-use then ;
' sched-main main: sched
