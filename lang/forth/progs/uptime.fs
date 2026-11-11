\ uptime.fs: how long the machine has run, and how busy it was (the Forth port of os/progs/uptime.s)
\   forth uptime.fs
\   up 12.345 s, 7 processes, 1200 context switches (3400 KiB moved), 5 kernel code units paged in
\ The time is TICKS (microseconds since power-on); the rest is proc's INFO (64 bytes:
\ u64 cores, free heap, memory, processes, kernel units loaded, switches, KiB moved).
[defined] sys.fs 0= [if] include /sys.fs [then]

create info 64 allot
: info@ ( -- ) 0 0 0 16 proc 0< if s" uptime: cannot ask the process server" +e e! 1 stop then  info 64 msg> ;
: uptime-main ( a u -- )
  2drop ticks info@
  ." up " 1000 / 1000 /mod .u '.' emit  <# # # # #> type
  ."  s, " info 24 + @ .u ."  processes, " info 40 + @ .u ."  context switches ("
  info 48 + @ .u ."  KiB moved), " info 32 + @ .u ."  kernel code units paged in" cr ;
' uptime-main main: uptime
