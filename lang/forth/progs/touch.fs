\ touch.fs: create empty files (the Forth port of os/progs/touch.s)
\   forth touch.fs FILE...     each FILE, empty, unless its path names one already
\ A path that names a file (STAT) is left alone; anything else is opened for
\ appending and closed. "touch: cannot create FILE" (exit code 1) otherwise.
[defined] sys.fs 0= [if] include /sys.fs [then]

: make-empty ( a u -- )
  2dup 2 open dup 0< if drop s" touch: cannot create " complain else close 2drop then ;
: touch-file ( a u -- ) 2dup stat 0< if make-empty else 2drop then ;
: touch-main ( a u -- )
  dup 0= if s" usage: touch FILE..." usage then
  begin arg dup while touch-file repeat 2drop 2drop ;
' touch-main main: touch
