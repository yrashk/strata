\ cp.fs: copy a file (the Forth port of os/progs/cp.s)
\   forth cp.fs SRC DST        DST gets SRC's bytes; a tag path gives it those tags
\   forth cp.fs -t SRC DST     the same, and DST also gets SRC's tags
\ DST must be another path ("cp: same file: SRC DST"); a name is unique in its directory only.
\ Errors: "cp: no such file: SRC", "cp: cannot write DST" (exit code 1); usage:
\ exit code 2.
[defined] sys.fs 0= [if] include /sys.fs [then]

2variable src  2variable dst  variable cp-t
: cp-use ( -- ) s" usage: cp [-t] SRC DST" usage ;
: cp-arg ( a u -- rest u' word u2 ) arg dup 0= if cp-use then ; \ one more, or usage
: cp-args ( a u -- )                            \ [-t] SRC DST
  0 cp-t !  cp-arg  2dup s" -t" str= if 2drop -1 cp-t ! cp-arg then  src 2!
  cp-arg dst 2!  arg nip if cp-use then 2drop ;

: cp-fail ( a u a2 u2 -- ) +e +e e! 1 stop ;    \ "message" "name", exit code 1
: same-file ( -- ) s" cp: same file: " +e src 2@ +e s"  " +e dst 2@ +e e! 1 stop ;
: open-src ( -- id ) src 2@ 0 open dup 0< if drop src 2@ s" cp: no such file: " cp-fail then ;
: open-dst ( -- id ) dst 2@ 1 open dup 0< if drop dst 2@ s" cp: cannot write " cp-fail then ;
: copy ( from to -- from to )                   \ every byte (WRITE sends all of a part, or stops)
  >r begin dup inb read dup 0> while inb swap 2 r@ write repeat drop r> ;

\ -t: DST goes into the directory of its tags and SRC's, in one TAG request
create tagb /msg allot                          \ SRC's tags
create tbuf 1024 allot  variable #tbuf          \ their names, each followed by a zero (the first KiB)
: tbuf-end ( -- a ) tbuf #tbuf @ + ;
: +tag ( a u -- )                               \ a name and its zero, if there is room
  dup #tbuf @ + 1000 < 0= if 2drop exit then
  tbuf-end swap  dup 1+ #tbuf +!  move  0 tbuf-end 1- c! ;
: cp-tags ( -- )
  0 #tbuf !  src 2@ tagb tags-of 0 max  tagb swap 0 ?do dup rec-name +tag rec-next loop drop
  #tbuf @ if dst 2@ tbuf #tbuf @ op-tag fs-2path drop then ;

: cp-main ( a u -- )
  cp-args  src 2@ dst 2@ str= if same-file then
  src 2@ stat 0< if src 2@ s" cp: no such file: " cp-fail then
  open-src open-dst copy close close
  cp-t @ if cp-tags then ;
' cp-main main: cp
