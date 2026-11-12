\ ps.fs: list the processes (the Forth port of os/progs/ps.s)
\   forth ps.fs
\     PID  PPID STATE    CORE  CPUS  SWITCHES   KIB  NAME
\       1     0 blocked     1     0        12     0  proc (server)
\ proc's PS: a 32-byte record per process (u8 pid, state, core, parent, flags,
\ cores; u32 switches, u32 KiB moved at 8 and 12; the name at 16). States: 1
\ running, 2 ready, 3 blocked, 4 zombie. Flags: 1 exclusive, 2 server.
[defined] sys.fs 0= [if] include /sys.fs [then]

create tab 64 32 * allot
: state ( n -- a u ) dup 5 u< 0= if drop 0 then 8 * s" ?       running ready   blocked zombie  " drop + 8 ;
: ps-main ( a u -- )
  2drop 0 0 0 9 proc dup 0< if drop s" ps: cannot ask the process server" +e e! 1 stop then
  64 min  tab over 32 * 4032 min msg>
  ."   PID  PPID STATE    CORE  CPUS  SWITCHES   KIB  NAME" cr
  0 ?do tab i 32 * +
    dup c@ 5 u.r  dup 3 + c@ 6 u.r space  dup 1+ c@ state type  dup 2 + c@ 5 u.r  dup 5 + c@ 6 u.r
    dup 8 + l@ 10 u.r  dup 12 + l@ 6 u.r  2 spaces  dup 16 + 16 zlen type
    dup 4 + c@ 1 and if ."  (excl)" then  4 + c@ 2 and if ."  (server)" then cr
  loop ;
' ps-main main: ps
