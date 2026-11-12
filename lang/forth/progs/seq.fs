\ seq.fs: the numbers 1 to N, one per line (the Forth port of os/progs/seq.s)
\   forth seq.fs 20            forth seq.fs 100 | grep 7 | wc
[defined] sys.fs 0= [if] include /sys.fs [then]

: seq-main ( a u -- ) atoi 1+ 1 ?do i .u cr loop ;
' seq-main main: seq
