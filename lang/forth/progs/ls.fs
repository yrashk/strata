\ ls.fs: the files of a tag path (the Forth port of os/progs/ls.s)
\   forth ls.fs                the current tag path's files: name (padded to 26 columns), size
\   forth ls.fs /TAG/TAG...    the files carrying every one of the tags ("-TAG": not carrying it)
\   forth ls.fs /TAG.../NAME   that one file, if it carries the tags
\   forth ls.fs -t [PATH]      the same, with each file's tags after its size
\ fs QUERY answers the files part by part and, with each part, the facets: the other
\ tags the files carry (those with ids below 64), listed after the files as "TAG/".
\ "(no files)" when there are none; "ls: no such tag or file: PATH" (exit code 1).
[defined] sys.fs 0= [if] include /sys.fs [then]

40 constant op-query  20 constant op-cwd
2variable path  variable ls-t  variable facets  variable cursor  variable #files

\ A part of QUERY's answer: in the message buffer's first 64 bytes, the cursor of the next
\ part (0: none) at 8, the data's bytes at 16, the facets (a bit per tag id) at 24; the
\ data: u64 n and the path's own n tag ids (u32), padded to a cell, then a record per file
\ (sys.fs: a file's u32 is how many tags it has; their ids follow its name, u32 each).
create hdr 64 allot
: next-cursor ( -- u ) hdr 8 + @ ;
: data-bytes ( -- u ) hdr 16 + @ ;
: part-facets ( -- mask ) hdr 24 + @ ;
: first-file ( data -- rec ) dup @ 4 * cell+ aligned + ;
: tag-ids ( rec -- a n ) dup rec-name + aligned  swap rec-id ;

create tagb /msg allot                          \ a file's tags, or every tag (for the facets)
variable #tagb  variable tagb?                  \ -t: every tag is in tagb (read once): how many
: all-tags ( -- ) tagb? @ 0= if 0 0 tagb tags-of 0 max #tagb !  -1 tagb? ! then ;
: id>name ( id -- a u )                         \ a tag's name (0 0: not among those read)
  all-tags  tagb #tagb @ 0 ?do
    2dup rec-id = if nip rec-name unloop exit then  rec-next
  loop 2drop 0 0 ;
: tag. ( a u -- ) dup if space type else 2drop then ;
: ids. ( rec -- ) tag-ids 0 ?do dup i 4 * + l@ id>name tag. loop drop ;
: names. ( recs n -- ) 0 ?do space dup rec-name type rec-next loop drop ;
: one. ( rec -- )                               \ no ids: a file in no directory, or the one file the path
  rec-name path 2@ last/ str= 0= if exit then   \ names: then the path gives its tags
  0 tagb? !  path 2@ tagb tags-of 0 max  tagb swap names. ;
: tags. ( rec -- ) dup rec-id if ids. else one. then ;
: file. ( rec -- )                              \ a file's line
  dup rec-name 26 type-pad
  ls-t @ if dup rec-num 7 u.r space dup tags. else dup rec-num .u then cr drop ;
: facet? ( id -- f ) dup 64 < if facets @ swap rshift 1 and else drop false then ;
: facets. ( -- )                                \ the facets: "TAG/"
  facets @ 0= if exit then
  0 0 tagb tags-of 0 max  tagb swap 0 ?do
    dup rec-id facet? if dup rec-name type ." /" cr then  rec-next
  loop drop ;

: +cwd ( -- )                                   \ the current tag path, to the error message
  0 0 0 op-cwd fs  dup 0> if inb over msg> inb swap +e else drop then ;
: ls-fail ( -- )
  s" ls: no such tag or file: " +e  path 2@ dup if +e else 2drop +cwd then  e! 1 stop ;
: query ( -- n )                                \ the next part: its files, into inb
  path 2@ >msg  cursor @ path 2@ nip 0 op-query fs  dup 0< if drop ls-fail then
  hdr 0 64 msg@  next-cursor cursor !  part-facets facets @ or facets !
  inb data-bytes /msg min msg> ;
: files. ( n -- )                               \ (a record with no name: a deeper directory's file)
  dup #files +!  inb first-file swap 0 ?do
    dup rec-name nip if dup file. else -1 #files +! then  rec-next
  loop drop ;
: ls-args ( a u -- )                            \ [-t] [PATH]
  0 ls-t !  0 0 path 2!
  begin arg dup while 2dup s" -t" str= if 2drop -1 ls-t ! else path 2! then repeat 2drop 2drop ;
: ls-main ( a u -- )
  ls-args  0 cursor !  0 facets !  0 #files !
  begin query files. cursor @ 0= until
  #files @ 0=  facets @ 0= and if ." (no files)" cr exit then
  facets. ;
' ls-main main: ls
