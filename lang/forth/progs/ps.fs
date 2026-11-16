\ ps.fs: list the processes (the Forth port of os/progs/ps.s)
\   forth ps.fs
\     PID  PPID STATE    CORE  CPUS  SWITCHES   KIB  NAME
\       1     0 blocked     1     0        12     0  proc (server)
[defined] sys.fs 0= [if] include /sys.fs [then]

9 constant op-ps                                \ proc's PS: a 32-byte record per process
64 constant max-procs
32 constant /record
: pid       ( r -- n ) c@ ;
: state#    ( r -- n ) 1+ c@ ;                  \ 1 running, 2 ready, 3 blocked, 4 zombie
: core      ( r -- n ) 2 + c@ ;
: parent    ( r -- n ) 3 + c@ ;
: flags     ( r -- n ) 4 + c@ ;                 \ 1 exclusive, 2 server
: threads   ( r -- n ) 5 + c@ ;
: switches  ( r -- n ) 8 + l@ ;
: kib-moved ( r -- n ) 12 + l@ ;
: name      ( r -- a u ) 16 + 16 zlen ;

create tab  max-procs /record * allot
: record ( i -- r ) /record * tab + ;
: ask ( -- n )                                  \ the records, into tab: how many
  0 0 0 op-ps proc  dup 0< if drop s" ps: cannot ask the process server" fail then
  max-procs min  tab over /record * /msg min msg> ;

: state-name ( r -- a u )
  state# dup 5 u< 0= if drop 0 then  8 * s" ?       running ready   blocked zombie  " drop + 8 ;
: process. ( r -- )
  dup pid 5 u.r  dup parent 6 u.r space  dup state-name type  dup core 5 u.r  dup threads 6 u.r
  dup switches 10 u.r  dup kib-moved 6 u.r  2 spaces  dup name type
  flags  dup 1 and s"  (excl)" ?type  2 and s"  (server)" ?type  cr ;
: ps-main ( a u -- )
  2drop ask  ."   PID  PPID STATE    CORE  CPUS  SWITCHES   KIB  NAME" cr
  0 ?do i record process. loop ;
' ps-main main: ps
