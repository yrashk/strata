\ rm.fs: delete files (the Forth port of os/progs/rm.s)
\   forth rm.fs NAME...        each named file (fs UNLINK)
\ A name that is no file: "rm: no such file: X" and exit code 1; the others still go.
[defined] sys.fs 0= [if] include /sys.fs [then]

: rm-main ( a u -- )
  dup 0= if s" usage: rm NAME..." usage then
  begin arg dup while
    2dup 0 11 fs-path 0< if s" rm: no such file: " +e 2dup +e e! 1 status ! then 2drop
  repeat 2drop 2drop ;
' rm-main main: rm
