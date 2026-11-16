\ mv.fs: rename a file (the Forth port of os/progs/mv.s)
\   forth mv.fs SRC DST        SRC is now called DST (a file named DST is replaced)
\   forth mv.fs SRC /TAG/DST   ... and also carries TAG
\   forth mv.fs SRC /TAG/      DST ending in "/": the same name, with those tags
\ One fs RENAME: the file keeps its blocks and tags, and gains DST's path's tags.
\ Errors: "mv: no such file: SRC", "mv: cannot rename SRC to DST" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

15 constant op-rename
2variable src
create dbuf 512 allot  variable #d              \ DST
: dst ( -- a u ) dbuf #d @ ;
: >dst ( a u -- ) 255 min dup #d ! dbuf swap move ;
: +dst ( a u -- ) 255 min tuck dst + swap move #d +! ; \ more of it
: mv-use ( -- ) s" usage: mv SRC DST" usage ;
: mv-arg ( a u -- rest u' word u2 ) arg dup 0= if mv-use then ;
: mv-args ( a u -- )
  mv-arg src 2!
  mv-arg 2dup >dst  last-char '/' = if src 2@ last/ +dst then \ "/TAG/": SRC's name after it
  arg nip if mv-use then 2drop ;
: mv-fail ( err -- )
  -4 = if s" mv: no such file: " +e src 2@ +e e! 1 stop then
  s" mv: cannot rename " +e src 2@ +e s"  to " +e dst +e e! 1 stop ;
: mv-main ( a u -- ) mv-args  src 2@ dst op-rename fs-2path  dup 0< if mv-fail then drop ;
' mv-main main: mv
