\ tag.fs: give a file tags, take them away, or replace them (the Forth port of os/progs/tag.s)
\   forth tag.fs FILE TAG...       FILE now carries each TAG (a new tag is created)
\   forth untag.fs FILE TAG...     FILE no longer carries them
\   forth retag.fs FILE [TAG...]   FILE carries exactly these TAGs (none: no tags)
\ One program, three names, as tag.s: the pack has this file as tag.fs, untag.fs and
\ retag.fs, and it looks at the name it was started by. At the Forth prompt (include
\ tag.fs) the words are tag, untag and retag. Errors (exit code 1): "tag: no such
\ file: FILE", "tag: cannot tag FILE with TAG".
[defined] sys.fs 0= [if] include /sys.fs [then]

variable mode                                   \ 0 tag, 1 untag, 2 retag
2variable file  2variable tags                  \ the arguments (the tags as written)
create tbuf 520 allot  variable #tbuf           \ the tags' names, each followed by a zero
: tbuf-end ( -- a ) tbuf #tbuf @ + ;
: +name ( a u -- ) tbuf-end swap dup #tbuf +! move  0 tbuf-end c!  1 #tbuf +! ;
: tag-use ( -- ) s" usage: tag FILE TAG... / untag FILE TAG... / retag FILE [TAG...]" usage ;
: tag-arg ( a u -- rest u' word u2 ) arg dup 0= if tag-use then ;
: no-tags? ( a u -- f ) arg nip nip nip 0= ;
: request ( -- op ) mode @ 1 = if op-untag else op-tag then ;
: tag-fail ( err -- )
  -4 = if s" tag: no such file: " +e file 2@ +e
  else s" tag: cannot tag " +e file 2@ +e s"  with " +e tags 2@ +e then  e! 1 status ! ;
: tag-main ( a u -- )                           \ all the tags in one request: the file moves once, into the
  0 #tbuf !  tag-arg file 2!                    \ directory of its tags and these (untag: without these;
  mode @ 2 = if s" /" +name                     \ retag: of exactly these: a first name "/" empties the set)
  else 2dup no-tags? if tag-use then then
  bl skip 2dup tags 2!
  begin arg dup while +name repeat 2drop 2drop
  file 2@ tbuf #tbuf @ request fs-2path  dup 0< if tag-fail else drop then ;
: by-name ( a u -- )                            \ the mode from the name started by
  last/ 2dup s" untag.fs" str= if 2drop 1 mode ! exit then
  s" retag.fs" str= if 2 mode ! else 0 mode ! then ;
cmdline nip [if] cmdline arg 2drop arg by-name 2drop [then]
: with-mode ( n "args" -- ) mode !  0 parse bl skip ['] tag-main run  0 mode ! ;
: untag ( "args" -- ) 1 with-mode ;
: retag ( "args" -- ) 2 with-mode ;
' tag-main main: tag
