\ grep.fs: the lines of standard input that contain a pattern (the Forth port of os/progs/grep.s)
\   forth grep.fs TEXT < file  seq 50 | forth grep.fs 3
\ The pattern is the whole argument text (spaces included). Lines of up to 255 bytes,
\ as grep.s reads them (the rest of a longer line is not searched, nor printed).
[defined] sys.fs 0= [if] include /sys.fs [then]

255 constant /line
create ln /line 1+ allot
create pat /line 1+ allot  variable #pat
: at? ( a -- f )                                \ does the pattern start at a? (its first byte first)
  dup c@ pat c@ = if #pat @ pat #pat @ str= else drop false then ;
: has? ( a u -- f )                             \ does the line contain the pattern?
  #pat @ 0= if 2drop true exit then
  #pat @ - 1+ dup 1 < if 2drop false exit then  ( a positions )
  0 ?do dup i + at? if drop true unloop exit then loop drop false ;
: grep-main ( a u -- )
  /line min dup #pat ! pat swap move
  begin ln /line in-line dup 0< 0= while  ln over has? if ln swap type cr else drop then  repeat drop ;
' grep-main main: grep
