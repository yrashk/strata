\ tags.fs: list the tags (the Forth port of os/progs/tags.s)
\   forth tags.fs              every tag: its name (padded to 18 columns), the files carrying it
\   forth tags.fs FILE...      each file's tags: "FILE: tag tag ..."
\ "(no tags)" when there are none; "tags: no such file: FILE" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

create tagb /msg allot
: every-tag ( -- )
  0 0 tagb tags-of dup 0> 0= if drop ." (no tags)" cr exit then
  tagb swap 0 ?do dup rec-name 18 type-pad  dup rec-num .u cr  rec-next loop drop ;
: names. ( n -- ) tagb swap 0 ?do space dup rec-name type rec-next loop drop ;
: file-tags ( a u -- )
  2dup tagb tags-of dup 0< if drop s" tags: no such file: " complain exit then
  -rot type ':' emit  names. cr ;
: tags-main ( a u -- )
  dup 0= if 2drop every-tag exit then
  begin arg dup while file-tags repeat 2drop 2drop ;
' tags-main main: tags
