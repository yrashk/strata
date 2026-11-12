\ upper.fs: standard input to standard output in capital letters (the Forth port of os/progs/upper.s)
\   forth upper.fs < about     cat motd | forth upper.fs
\ Lines of up to 255 bytes (the rest of a longer line is dropped), as upper.s reads them.
[defined] sys.fs 0= [if] include /sys.fs [then]

create ln 256 allot
: caps ( a u -- ) bounds ?do i c@ 'a' - 26 u< if i c@ 32 - i c! then loop ;
: upper-main ( a u -- ) 2drop begin ln 255 in-line dup 0< 0= while ln over caps ln swap type cr repeat drop ;
' upper-main main: upper
