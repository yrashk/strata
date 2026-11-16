\ wc.fs: count the lines, words and bytes of standard input (the Forth port of os/progs/wc.s)
\   forth wc.fs < motd         seq 1000 | forth wc.fs
\ Prints "LINES WORDS BYTES". A word is a run of bytes other than spaces and tabs.
\ Lines are read as wc.s reads them (up to 255 bytes each: the rest is not counted).
[defined] sys.fs 0= [if] include /sys.fs [then]

255 constant /line
create ln /line 1+ allot
variable #l  variable #w  variable #b
: blank? ( c -- f ) dup bl = swap 9 = or ;      \ a space or a tab
: words+ ( a u -- )                             \ count the words of a line
  false -rot bounds ?do                         ( in-a-word? )
    i c@ blank? if drop false else 0= if 1 #w +! then true then
  loop drop ;
: wc-main ( a u -- )
  2drop 0 #l ! 0 #w ! 0 #b !
  begin ln /line in-line dup 0< 0= while  1 #l +!  dup 1+ #b +!  ln swap words+  repeat drop
  #l @ .u space #w @ .u space #b @ .u cr ;
' wc-main main: wc
