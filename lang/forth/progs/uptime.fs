\ uptime.fs: how long the machine has run, and how busy it was (the Forth port of os/progs/uptime.s)
\   forth uptime.fs
\   up 12.345 s, 7 processes, 1200 context switches (3400 KiB moved), 5 kernel code units paged in
\ The time is TICKS (microseconds since power-on); the rest is proc's INFO.
[defined] sys.fs 0= [if] include /sys.fs [then]

create info 64 allot                            \ INFO: u64 cores, free heap, memory, processes,
: processes ( -- n ) info 24 + @ ;              \ kernel units loaded, switches, KiB moved
: units-in  ( -- n ) info 32 + @ ;
: switches  ( -- n ) info 40 + @ ;
: kib-moved ( -- n ) info 48 + @ ;
: info@ ( -- ) 0 0 0 op-info proc 0< if s" uptime: cannot ask the process server" fail then  info 64 msg> ;
: seconds. ( us -- ) 1000 / 1000 /mod .u '.' emit  <# # # # #> type ; \ to the millisecond
: uptime-main ( a u -- )
  2drop ticks info@
  ." up " seconds. ."  s, " processes .u ."  processes, " switches .u ."  context switches ("
  kib-moved .u ."  KiB moved), " units-in .u ."  kernel code units paged in" cr ;
' uptime-main main: uptime
