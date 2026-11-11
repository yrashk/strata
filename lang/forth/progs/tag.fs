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
2variable file  2variable given  variable #old
create tagb 64 32 * allot                       \ retag: the file's tags before
: tag-use ( -- ) s" usage: tag FILE TAG... / untag FILE TAG... / retag FILE [TAG...]" usage ;
: no-file ( -- ) s" tag: no such file: " +e file 2@ +e e! 1 stop ;
: old-tag ( i -- a u ) 32 * tagb + 16 zlen ;
: among? ( a u -- f )                           \ is the tag one of those given?
  2>r given 2@ begin arg dup while 2r@ str= if 2drop 2r> 2drop true exit then repeat
  2drop 2drop 2r> 2drop false ;
: tag-main ( a u -- )
  arg dup 0= if tag-use then file 2!  2dup given 2!
  mode @ 2 = if file 2@ tagb tags-of dup 0< if drop no-file then #old !
  else 2dup arg nip nip nip 0= if tag-use then then
  begin arg dup while                           ( rest u tag u2 )
    file 2@ 2over mode @ 1 = if 13 else 12 then fs-2path dup 0< if
      -4 = if no-file then  s" tag: cannot tag " +e file 2@ +e s"  with " +e 2dup +e e! 1 status !
    else drop then 2drop
  repeat 2drop 2drop
  mode @ 2 = if #old @ 0 ?do i old-tag among? 0= if file 2@ i old-tag 13 fs-2path drop then loop then ;
: by-name ( a u -- )                            \ the mode from the name started by
  last/ 2dup s" untag.fs" str= if 2drop 1 mode ! exit then
  s" retag.fs" str= if 2 mode ! else 0 mode ! then ;
32 kvar cell+ @ [if] 32 kvar 2@ swap arg 2drop arg by-name 2drop [then]
: untag ( "args" -- ) 1 mode ! 0 parse bl skip ['] tag-main run 0 mode ! ;
: retag ( "args" -- ) 2 mode ! 0 parse bl skip ['] tag-main run 0 mode ! ;
' tag-main main: tag
