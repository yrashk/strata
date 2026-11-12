\ ls.fs: the files of a tag path (the Forth port of os/progs/ls.s)
\   forth ls.fs                the current tag path's files: name (padded to 26 columns), size
\   forth ls.fs /TAG/TAG...    the files carrying every one of the tags ("-TAG": not carrying it)
\   forth ls.fs /TAG.../NAME   that one file, if it carries the tags
\   forth ls.fs -t [PATH]      the same, with each file's tags after its size
\ fs DIR answers the files (32-byte records: name[24], u64 size) and, in its reply's
\ mode word, the facets: the other tags the files carry, listed after them as "TAG/".
\ "(no files)" when there are none; "ls: no such tag or file: PATH" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

2variable path  variable ls-t  variable facets
create tagb 64 32 * allot                       \ a file's tags, or every tag (for the facets)
create aname 32 allot                           \ "/NAME": a file wherever the current path is
create hdr 64 allot                             \ DIR's reply header (the facets in its mode word)
: rec ( i -- a ) 32 * inb + ;
: tags. ( a u -- )                              \ a file's tags, each after a space
  dup 1+ >r aname 1+ swap move '/' aname c!  aname r> tagb tags-of
  0 max 0 ?do space i 32 * tagb + 16 zlen type loop ;
: facets. ( -- )                                \ the facets: "TAG/"
  facets @ 0= if exit then
  0 0 tagb tags-of 0 max 0 ?do
    facets @ i 32 * tagb + 24 + @ rshift 1 and if i 32 * tagb + 16 zlen type ." /" cr then
  loop ;
: ls-fail ( -- )
  s" ls: no such tag or file: " +e  path 2@ dup 0= if
    2drop 0 0 0 20 fs dup 0> if inb over msg> inb swap +e else drop then  \ the current path (CWD)
  else +e then e! 1 stop ;
: ls-main ( a u -- )
  0 ls-t !  0 0 path 2!
  begin arg dup while 2dup s" -t" str= if 2drop -1 ls-t ! else path 2! then repeat 2drop 2drop
  path 2@ 0 10 fs-path dup 0< if drop ls-fail then
  dup 0= if drop ." (no files)" cr exit then
  126 min  hdr 0 64 5 tget 32 twait  hdr 24 + @ facets !  inb over 32 * msg>
  0 ?do i rec 24 zlen dup >r type 26 r> - spaces
    ls-t @ if i rec 24 + @ 7 u.r space i rec 24 zlen tags. else i rec 24 + @ .u then cr
  loop facets. ;
' ls-main main: ls
