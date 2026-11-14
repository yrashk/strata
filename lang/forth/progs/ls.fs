\ ls.fs: the files of a tag path (the Forth port of os/progs/ls.s)
\   forth ls.fs                the current tag path's files: name (padded to 26 columns), size
\   forth ls.fs /TAG/TAG...    the files carrying every one of the tags ("-TAG": not carrying it)
\   forth ls.fs /TAG.../NAME   that one file, if it carries the tags
\   forth ls.fs -t [PATH]      the same, with each file's tags after its size
\ fs QUERY answers the files part by part (records: u16 bytes, u16 name length, u32 tags,
\ u64 size, the name) and, in each reply's mode word, the facets: the other tags the files
\ carry (those with ids below 64), listed after the files as "TAG/".
\ "(no files)" when there are none; "ls: no such tag or file: PATH" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

2variable path  variable ls-t  variable facets  variable cursor  variable #files
create tagb 4032 allot                          \ a file's tags, or every tag (for the facets)
create aname 264 allot                          \ "/NAME": a file wherever the current path is
create hdr 64 allot                             \ a reply's header (the cursor, the data's bytes, the facets)
: tags. ( a u -- )                              \ a file's tags, each after a space
  dup 1+ >r aname 1+ swap move '/' aname c!  aname r> tagb tags-of
  0 max tagb swap 0 ?do space dup rec-name type rec-next loop drop ;
: facets. ( -- )                                \ the facets: "TAG/"
  facets @ 0= if exit then
  0 0 tagb tags-of 0 max tagb swap 0 ?do
    dup rec-id dup 64 < if facets @ swap rshift 1 and if dup rec-name type ." /" cr then else drop then
    rec-next loop drop ;
: file. ( rec -- )                              \ a file's line
  dup rec-name dup >r type 26 r> - 1 max spaces
  ls-t @ if dup 8 + @ 7 u.r space dup rec-name tags. else dup 8 + @ .u then cr drop ;
: ls-fail ( -- )
  s" ls: no such tag or file: " +e  path 2@ dup 0= if
    2drop 0 0 0 20 fs dup 0> if inb over msg> inb swap +e else drop then  \ the current path (CWD)
  else +e then e! 1 stop ;
: ls-main ( a u -- )
  0 ls-t !  0 0 path 2!
  begin arg dup while 2dup s" -t" str= if 2drop -1 ls-t ! else path 2! then repeat 2drop 2drop
  0 cursor !  0 facets !  0 #files !
  begin
    path 2@ >msg  cursor @ path 2@ nip 0 40 fs  dup 0< if drop ls-fail then
    hdr 0 64 5 tget 32 twait  hdr 8 + @ cursor !  hdr 24 + @ facets @ or facets !
    inb hdr 16 + @ 4032 min msg>  dup #files +!
    inb dup @ 4 * 15 + -8 and +                 \ (the path's own tags come first)
    swap 0 ?do dup file. rec-next loop drop
  cursor @ 0= until
  #files @ 0= if ." (no files)" cr exit then
  facets. ;
' ls-main main: ls
