\ tags.fs: list the tags (the Forth port of os/progs/tags.s)
\   forth tags.fs              every tag: its name (padded to 18 columns), the files carrying it
\   forth tags.fs FILE...      each file's tags: "FILE: tag tag ..."
\ "(no tags)" when there are none; "tags: no such file: FILE" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

create tagb 64 32 * allot
: tag-name ( i -- a u ) 32 * tagb + 16 zlen ;
: every-tag ( -- )
  0 0 tagb tags-of dup 0> 0= if drop ." (no tags)" cr exit then
  0 ?do i tag-name dup >r type 18 r> - spaces  i 32 * tagb + 16 + @ .u cr loop ;
: tags-main ( a u -- )
  dup 0= if 2drop every-tag exit then
  begin arg dup while
    2dup tagb tags-of dup 0< if drop s" tags: no such file: " +e 2dup +e e! 1 status !
    else >r 2dup type ':' emit r> 0 ?do space i tag-name type loop cr then 2drop
  repeat 2drop 2drop ;
' tags-main main: tags
