\ mv.fs: rename a file (the Forth port of os/progs/mv.s)
\   forth mv.fs SRC DST        SRC is now called DST (a file named DST is replaced)
\   forth mv.fs SRC /TAG/DST   ... and also carries TAG
\   forth mv.fs SRC /TAG/      DST ending in "/": the same name, with those tags
\ One fs RENAME: the file keeps its blocks and tags, and gains DST's path's tags.
\ Errors: "mv: no such file: SRC", "mv: cannot rename SRC to DST" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

2variable src  create dbuf 512 allot  variable #d
: mv-use ( -- ) s" usage: mv SRC DST" usage ;
: >dst ( a u -- ) 255 min dup #d ! dbuf swap move ; \ DST
: +dst ( a u -- ) 255 min tuck dbuf #d @ + swap move #d +! ; \ more of it
: mv-main ( a u -- )
  arg dup 0= if mv-use then src 2!  arg dup 0= if mv-use then
  2dup >dst + 1- c@ '/' = if src 2@ last/ +dst then \ "/TAG/": SRC's name after it
  arg nip if mv-use then 2drop
  src 2@ dbuf #d @ 15 fs-2path dup 0< 0= if drop exit then
  -4 = if s" mv: no such file: " +e src 2@ +e e! 1 stop then
  s" mv: cannot rename " +e src 2@ +e s"  to " +e dbuf #d @ +e e! 1 stop ;
' mv-main main: mv
