\ cat.fs: copy files (or standard input) to standard output (the Forth port of os/progs/cat.s)
\   forth cat.fs motd about    forth cat.fs < note    forth cat.fs motd > copy
\ A file is copied 4032 bytes at a time; standard input a line at a time (lines of
\ up to 4000 bytes, each ended by a newline). A missing file: "cat: no such file:
\ NAME" and exit code 1, after the others are copied.
[defined] sys.fs 0= [if] include /sys.fs [then]

4000 constant /line
create ln /line allot                           \ a line of standard input
: copy ( id -- ) begin dup inb read dup 0> while inb swap type repeat drop close ;
: cat-file ( a u -- )
  2dup 0 open  dup 0< if drop s" cat: no such file: " complain exit then  nip nip copy ;
: cat-stdin ( -- ) begin ln /line in-line dup 0< 0= while ln swap type cr repeat drop ;
: cat-main ( a u -- )
  dup 0= if 2drop cat-stdin exit then
  begin arg dup while cat-file repeat 2drop 2drop ;
' cat-main main: cat
