\ cp.fs: copy a file (the Forth port of os/progs/cp.s)
\   forth cp.fs SRC DST        DST gets SRC's bytes; a tag path gives it those tags
\   forth cp.fs -t SRC DST     the same, and DST also gets SRC's tags
\ DST must be another path ("cp: same file: SRC DST"); a name is unique in its directory only.
\ Errors: "cp: no such file: SRC", "cp: cannot write DST" (exit code 1); usage:
\ exit code 2.
[defined] sys.fs 0= [if] include /sys.fs [then]

2variable src  2variable dst  variable cp-t
create tagb 4032 allot                          \ SRC's tags (-t)
: cp-fail ( a u a2 u2 -- ) +e +e e! 1 stop ;    \ "message" "name", exit code 1
: cp-use ( -- ) s" usage: cp [-t] SRC DST" usage ;
: cp-tags ( -- )                                \ SRC's tags, given to DST
  src 2@ tagb tags-of 0 max tagb swap 0 ?do dup >r dst 2@ r@ rec-name 12 fs-2path drop r> rec-next loop drop ;
: cp-main ( a u -- )
  0 cp-t !  arg dup 0= if cp-use then
  2dup s" -t" str= if 2drop -1 cp-t ! arg dup 0= if cp-use then then  src 2!
  arg dup 0= if cp-use then  dst 2!  arg nip if cp-use then 2drop
  src 2@ dst 2@ str= if
    s" cp: same file: " +e src 2@ +e s"  " +e dst 2@ +e e! 1 stop then
  src 2@ stat dup 0< if drop src 2@ s" cp: no such file: " cp-fail then
  drop
  src 2@ 0 open dup 0< if drop src 2@ s" cp: no such file: " cp-fail then  >r
  dst 2@ 1 open dup 0< if drop dst 2@ s" cp: cannot write " cp-fail then  >r
  begin 2r@ drop inb read dup 0> while               ( n )
    dup inb swap 2 r@ write  drop                    \ (write sends all of it, or stops)
  repeat drop  r> close r> close
  cp-t @ if cp-tags then ;
' cp-main main: cp
