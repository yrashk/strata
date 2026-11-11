\ touch.fs: create empty files (the Forth port of os/progs/touch.s)
\   forth touch.fs FILE...     each FILE, empty, unless its path names one already
\ A path that names a file (STAT) is left alone; anything else is opened for
\ appending and closed. "touch: cannot create FILE" (exit code 1) otherwise.
[defined] sys.fs 0= [if] include /sys.fs [then]

: touch-main ( a u -- )
  dup 0= if s" usage: touch FILE..." usage then
  begin arg dup while
    2dup stat 0< if 2dup 2 open dup 0< if drop s" touch: cannot create " +e 2dup +e e! 1 status ! else close then then
    2drop
  repeat 2drop 2drop ;
' touch-main main: touch
