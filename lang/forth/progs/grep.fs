\ grep.fs: the lines of standard input that contain a pattern (the Forth port of os/progs/grep.s)
\   forth grep.fs TEXT < file  seq 50 | forth grep.fs 3
\ The pattern is the whole argument text (spaces included). Lines of up to 255 bytes,
\ as grep.s reads them (the rest of a longer line is not searched, nor printed).
[defined] sys.fs 0= [if] include /sys.fs [then]

create ln 256 allot
create pat 256 allot  variable #pat
: has? ( a u -- f )                             \ does the line contain the pattern?
  #pat @ 0= if 2drop true exit then
  #pat @ - 1+ dup 1 < if 2drop false exit then  ( a positions )
  0 ?do  dup i + c@ pat c@ = if dup i + #pat @ pat #pat @ str= if drop true unloop exit then then
  loop drop false ;
: grep-main ( a u -- )
  255 min dup #pat ! pat swap move
  begin ln 255 in-line dup 0< 0= while  ln over has? if ln swap type cr else drop then repeat drop ;
' grep-main main: grep
