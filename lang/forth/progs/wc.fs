\ wc.fs: count the lines, words and bytes of standard input (the Forth port of os/progs/wc.s)
\   forth wc.fs < motd         seq 1000 | forth wc.fs
\ Prints "LINES WORDS BYTES". A word is a run of bytes other than spaces and tabs.
\ Lines are read as wc.s reads them (up to 255 bytes each: the rest is not counted).
[defined] sys.fs 0= [if] include /sys.fs [then]

create ln 256 allot
variable #l  variable #w  variable #b
: words+ ( a u -- )                             \ count the words of a line
  0 -rot bounds ?do  i c@ dup bl = swap 9 = or if drop 0 else 0= if 1 #w +! then -1 then  loop drop ;
: wc-main ( a u -- )
  2drop 0 #l ! 0 #w ! 0 #b !
  begin ln 255 in-line dup 0< 0= while  1 #l +!  dup 1+ #b +!  ln swap words+ repeat drop
  #l @ .u space #w @ .u space #b @ .u cr ;
' wc-main main: wc
