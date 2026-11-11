\ sched.fs: show or set the preemption time slice (the Forth port of os/progs/sched.s)
\   forth sched.fs             the slice, and the switches and KiB moved per second since the last
\   forth sched.fs 500us       set it (100us .. 100ms): microseconds (no suffix), or us / ms
\   forth sched.fs 5ms
\ proc's SCHED: handle 0 reads (u64 slice, switches/s, KiB/s), 1 sets (length = the slice).
[defined] sys.fs 0= [if] include /sys.fs [then]

create info 24 allot
: sched-use ( -- ) s" usage: sched [N | Nus | Nms]  (100us .. 100ms)" usage ;
: sched-main ( a u -- )
  dup 0= if 2drop 0 0 0 30 proc if 1 stop then  info 24 msg>
    ." time slice: " info @ .u ."  us; " info 8 + @ .u ."  switches/s, " info 16 + @ .u
    ."  KiB/s moved by switches" cr exit then
  2dup digits dup 0= if sched-use then  >r -rot r> /string  ( n rest u )
  dup if 2dup s" ms" str= if rot 1000 * -rot else 2dup s" us" str= 0= if sched-use then then then 2drop
  1 swap 0 30 proc if sched-use then ;
' sched-main main: sched
