\ spin.fs: burn CPU on purpose, printing a character now and then (the Forth port of os/progs/spin.s)
\   forth spin.fs              a dot every 200000 loop iterations, forever (Ctrl-C ends it)
\   forth spin.fs 20 a         twenty a's, then a newline and exit code 0
\ A DO loop with nothing in it is two instructions an iteration, as spin.s's loop.
[defined] sys.fs 0= [if] include /sys.fs [then]

: burn ( -- ) 200000 0 do loop ;
: spin-args ( a u -- c n )                      \ the character (a dot), how many (0: forever)
  arg atoi -rot  arg if c@ else drop '.' then  nip nip swap ;
: countdown ( n -- n' f ) dup if 1- dup 0= else false then ; \ f: the last one (n = 0: never)
: spin-main ( a u -- ) spin-args  begin burn over emit flush countdown until  2drop cr ;
' spin-main main: spin
