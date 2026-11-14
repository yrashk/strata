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
2variable file
create tbuf 520 allot  variable #tbuf           \ the tags' names, a zero byte between them
: tag-use ( -- ) s" usage: tag FILE TAG... / untag FILE TAG... / retag FILE [TAG...]" usage ;
: +t ( a u -- ) tbuf #tbuf @ + swap dup #tbuf +! move ;
: tag-main ( a u -- )                           \ all the tags in one request: the file moves once, into the
  0 #tbuf !  arg dup 0= if tag-use then file 2!  \ directory of its tags and these (untag: without these;
  mode @ 2 = if s" /" +t 0 tbuf 1+ c! 1 #tbuf +!  \ retag: of exactly these: a first name "/" empties the set)
  else 2dup arg nip nip nip 0= if tag-use then then
  bl skip 2dup 2>r                              ( rest u ) ( R: the tags as written )
  begin arg dup while +t  0 tbuf #tbuf @ + c!  1 #tbuf +! repeat 2drop 2drop
  file 2@ tbuf #tbuf @ mode @ 1 = if 13 else 12 then fs-2path dup 0< if
    -4 = if s" tag: no such file: " +e file 2@ +e else
      s" tag: cannot tag " +e file 2@ +e s"  with " +e 2r@ +e then e! 1 status !
  else drop then 2r> 2drop ;
: by-name ( a u -- )                            \ the mode from the name started by
  last/ 2dup s" untag.fs" str= if 2drop 1 mode ! exit then
  s" retag.fs" str= if 2 mode ! else 0 mode ! then ;
32 kvar cell+ @ [if] 32 kvar 2@ swap arg 2drop arg by-name 2drop [then]
: untag ( "args" -- ) 1 mode ! 0 parse bl skip ['] tag-main run 0 mode ! ;
: retag ( "args" -- ) 2 mode ! 0 parse bl skip ['] tag-main run 0 mode ! ;
' tag-main main: tag
