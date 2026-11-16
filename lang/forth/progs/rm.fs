\ rm.fs: delete files (the Forth port of os/progs/rm.s)
\   forth rm.fs NAME...        each named file (fs UNLINK)
\ A name that is no file: "rm: no such file: X" and exit code 1; the others still go.
[defined] sys.fs 0= [if] include /sys.fs [then]

11 constant op-unlink
: rm-file ( a u -- ) 2dup 0 op-unlink fs-path 0< if s" rm: no such file: " complain else 2drop then ;
: rm-main ( a u -- )
  dup 0= if s" usage: rm NAME..." usage then
  begin arg dup while rm-file repeat 2drop 2drop ;
' rm-main main: rm
