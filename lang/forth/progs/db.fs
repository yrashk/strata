\ db.fs: the store for programs (the Forth port of `db get / put / del / scan`, os/progs/db.s)
\   forth db.fs get NS/TREE KEY          the value
\   forth db.fs put NS/TREE KEY VALUE    put it (the namespace and the tree are made if new)
\   forth db.fs del NS/TREE KEY          delete it
\   forth db.fs scan NS/TREE             every record, in key order: "KEY" = "VALUE"
\ The words are the file server's DBGET, DBSCAN and DBBATCH for one tree at a time, as
\ os/lib/kv.s has them in assembly; a program that keeps data in the store includes this file.
\ A negative answer: -1 a bad request or a namespace not the program's to name (fs), -4 nothing
\ there. "db: refused ..." (exit code 1); usage: exit code 2.
[defined] sys.fs 0= [if] include /sys.fs [then]

64 constant op-dbget  65 constant op-dbscan  66 constant op-dbbatch

\ A request in kvq: u8 the namespace's name length, u8 the tree's, u16 the key's, u32 0;
\ from byte 8 the two names, then the key or a batch item.
create kvq 1600 allot
variable kv-n                                   \ its bytes up to the names' end
: names-end ( -- a ) kvq kv-n @ + ;
: kv-len! ( u a -- ) 2dup c! swap 8 rshift swap 1+ c! ; \ a u16
: key-len! ( u -- ) kvq 2 + kv-len! ;
: kv-pad ( at -- at' ) begin dup 7 and while 0 over c! 1+ repeat ; \ zeros up to a cell
: kv+ ( a u at -- at' ) 2dup + >r swap move r> kv-pad ; \ bytes into the request, padded
: names-ok? ( nl tl -- f ) 1 29 within swap 1 33 within and ;
: kv-open ( a u -- f )                          \ "NAMESPACE/TREE" is the tree at work; false: no such text
  2dup '/' scan  2dup - 1-                      ( a u nl tl )
  2dup names-ok? 0= if 2drop 2drop false exit then
  rot drop  kvq 8 erase  over kvq c!  dup kvq 1+ c!  >r ( a nl ) \ the namespace's name,
  2dup kvq 8 + swap move  tuck + 1+  over kvq 8 + +  r@ move \ the tree's after it
  r> + 8 + kv-n !  true ;
: kv-send ( handle u mode op -- r ) 2>r kvq over >msg 2r> fs ; \ the request's first u bytes
: kv-ask ( key u mode op -- r )                 \ a request of the names and a key
  2>r  dup key-len!  tuck names-end kv+ drop  kv-n @ +  0 swap 2r> kv-send ;
: kv-get ( key u buf -- n|err )                 \ the value -> buf (1024 bytes): its length; -4 no such key
  >r 0 op-dbget kv-ask  dup 0> if r@ over msg> then rdrop ;
\ DBSCAN's records: u16 key length, u16 value length, u32 0, the key, the value, each padded to a cell
: kv-scan ( key u mode buf -- n|err )           \ the records from the key on (mode 0) or after it (1), as
  >r op-dbscan kv-ask  dup 0> if r@ /msg msg> then rdrop ; \ many as fit -> buf (4032 bytes): how many
\ A batch item: u8 what (1 put, 2 delete), u8 0, u16 key length, u16 value length, u16 0;
\ the key, the value, each padded to a cell. It follows the names, padded to a cell.
: kv-item ( key u val u2 what -- err )          \ a batch of one item
  0 key-len!  names-end kv-pad >r               ( R: the item )
  r@ 8 erase  r@ c!  dup r@ 4 + kv-len!  2swap  dup r@ 2 + kv-len!
  r> 8 + kv+ kv+  kvq -  1 swap 0 op-dbbatch kv-send ;
: kv-put ( key u val u2 -- err ) 1 kv-item ;    \ 0: it is on the disk
: kv-del ( key u -- err ) 0 0 2 kv-item ;       \ 0 (also when it was not there)

inb constant kvb                                \ a value, or a part of a scan (db reads no standard input)
create lastk 488 allot  variable lastk#         \ scan: the last key shown
variable after                                  \ scan: from lastk on (0) or after it (1)
: db-use ( -- ) s" usage: db get NS/TREE KEY | put NS/TREE KEY VALUE | del NS/TREE KEY | scan NS/TREE" usage ;
: db-refused ( -- ) s" db: refused (no such record, a private namespace, or too long)" fail ;
: quoted ( a u -- ) '"' emit type '"' emit ;
: key-len ( rec -- u ) @ $ffff and ;
: val-len ( rec -- u ) @ 16 rshift $ffff and ;
: rec-key ( rec -- a u ) dup 8 + swap key-len ;
: rec-val ( rec -- a u ) dup rec-key + aligned swap val-len ;
: remember ( a u -- ) dup lastk# ! lastk swap move ;
: record. ( rec -- rec' )                       \ "KEY" = "VALUE": the next record
  dup rec-key 2dup remember quoted ."  = "
  rec-val 2dup quoted cr + aligned ;
: db-scan ( -- )                                \ part by part, each from the last key of the one before
  0 lastk# !  0 after !
  begin lastk lastk# @ after @ kvb kv-scan dup 0> while
    1 after !  kvb swap 0 ?do record. loop drop
  repeat drop ;

2variable verb
: verb? ( a u -- f ) verb 2@ str= ;
: db-arg ( a u -- rest u' word u2 ) arg dup 0= if db-use then ;
: db-get ( key u -- ) kvb kv-get dup 0< if db-refused then  kvb swap type cr ;
: db-del ( key u -- ) kv-del if db-refused then ;
: db-put ( rest u key u2 -- ) 2swap db-arg 2swap 2drop  kv-put if db-refused then ;
: db-main ( a u -- )
  db-arg verb 2!  db-arg kv-open 0= if db-use then
  s" scan" verb? if 2drop db-scan exit then
  db-arg
  s" get" verb? if db-get 2drop exit then
  s" del" verb? if db-del 2drop exit then
  s" put" verb? 0= if db-use then  db-put ;
' db-main main: db
