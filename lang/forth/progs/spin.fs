\ spin.fs: burn CPU on purpose, printing a character now and then (the Forth port of os/progs/spin.s)
\   forth spin.fs              a dot every 200000 loop iterations, forever (Ctrl-C ends it)
\   forth spin.fs 20 a         twenty a's, then a newline and exit code 0
\ A DO loop with nothing in it is two instructions an iteration, as spin.s's loop.
[defined] sys.fs 0= [if] include /sys.fs [then]

: spin-main ( a u -- )
  arg atoi >r  arg if c@ else drop '.' then nip nip  r>      ( c n )
  begin 200000 0 do loop  over emit flush  dup if 1- dup 0= if 2drop cr exit then then again ;
' spin-main main: spin
