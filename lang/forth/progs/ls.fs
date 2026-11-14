\ ls.fs: the files of a tag path (the Forth port of os/progs/ls.s)
\   forth ls.fs                the current tag path's files: name (padded to 26 columns), size
\   forth ls.fs /TAG/TAG...    the files carrying every one of the tags ("-TAG": not carrying it)
\   forth ls.fs /TAG.../NAME   that one file, if it carries the tags
\   forth ls.fs -t [PATH]      the same, with each file's tags after its size
\ fs QUERY answers the files in parts, with a cursor: the ids of the path's own tags, then
\ per file { u16 record bytes, u16 name length, u32 tags, u64 size, the name ... }. The mode
\ word of DIR's reply has the facets: the other tags the files carry, listed after them
\ as "TAG/".
\ "(no files)" when there are none; "ls: no such tag or file: PATH" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

2variable path  variable ls-t  variable facets
create tagb 64 32 * allot                       \ a file's tags, or every tag (for the facets)
create aname 32 allot                           \ "/NAME": a file wherever the current path is
create hdr 64 allot                             \ DIR's reply header (the facets in its mode word)
variable cur                                    \ the cursor of the listing
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
: list ( cursor -- n|err )                      \ the next part of the listing -> inb; cur = the cursor after it
  >r path 2@ tuck >msg r> swap 0 40 fs  dup 0< if exit then
  hdr 0 64 5 tget 32 twait  hdr 8 + @ cur !  inb hdr 16 + @ 4032 min msg> ;
: file. ( a -- )                                \ one record: the name (padded to 26 columns), the size
  dup >r 16 + r@ 2 + w@  2dup type  26 over - 1 max spaces
  ls-t @ if r@ 8 + @ 7 u.r space tags. else 2drop r@ 8 + @ .u then cr  r> drop ;
: part ( n -- )                                 \ the n files of the part in inb
  inb @ 4 * 7 + -8 and 8 + inb +  swap 0 ?do dup file. dup w@ + loop drop ;
: ls-main ( a u -- )
  0 ls-t !  0 0 path 2!
  begin arg dup while 2dup s" -t" str= if 2drop -1 ls-t ! else path 2! then repeat 2drop 2drop
  path 2@ 0 10 fs-path dup 0< if drop ls-fail then        \ DIR: is there such a path, and its facets
  0= if ." (no files)" cr exit then
  hdr 0 64 5 tget 32 twait  hdr 24 + @ facets !
  0 list dup 0< if drop exit then
  begin part cur @ while cur @ list dup 0< if drop exit then repeat
  facets. ;
' ls-main main: ls
