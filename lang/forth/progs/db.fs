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

create kvq 1600 allot                           \ a request: the names' lengths, the names, a key or an item
variable kv-n                                   \ its bytes up to the names' end
: kv-len! ( u a -- ) 2dup c! swap 8 rshift swap 1+ c! ; \ a u16
: kv+ ( a u at -- at' )                         \ bytes into the request, padded with zeros to a cell
  2dup + >r swap move r>  begin dup 7 and while 0 over c! 1+ repeat ;
: kv-open ( a u -- f )                          \ "NAMESPACE/TREE" is the tree at work; false: no such text
  2dup '/' scan  2dup - 1-                      ( a u nl tl )
  over 1 33 within 0=  over 1 29 within 0= or if 2drop 2drop false exit then
  kvq 8 erase  over kvq c!  dup kvq 1+ c!  2>r drop  ( a ) ( R: nl tl )
  dup kvq 8 + 2r@ drop move                     \ the namespace's name,
  2r@ drop + 1+  kvq 8 + 2r@ drop +  r@ move    \ the tree's after it
  2r> + 8 + kv-n !  true ;
: kv-ask ( key u mode op -- r )                 \ a request of the names and a key
  2>r  dup kvq 2 + kv-len!  tuck kvq kv-n @ + kv+ drop
  kv-n @ +  kvq over >msg  0 swap 2r> fs ;
: kv-get ( key u buf -- n|err )                 \ the value -> buf (1024 bytes): its length; -4 no such key
  >r 0 64 kv-ask dup 0> if r@ over msg> then rdrop ;
: kv-scan ( key u mode buf -- n|err )           \ the records from the key on (mode 0) or after it (1), as
  >r 65 kv-ask dup 0> if r@ 4032 msg> then rdrop ; \ many as fit -> buf (4032 bytes): how many. A record:
                                                \ u16 key length, u16 value length, u32 0, the key, the
                                                \ value, each padded to a cell
: kv-item ( key u val u2 what -- err )          \ a batch of one item: 1 put, 2 delete
  0 kvq 2 + kv-len!
  kvq kv-n @ + begin dup 7 and while 0 over c! 1+ repeat >r ( key u val u2 what ) ( R: item )
  r@ 8 erase  r@ c!  dup r@ 4 + kv-len!  2swap  dup r@ 2 + kv-len!
  r> 8 + kv+ kv+  kvq -  kvq over >msg  1 swap 0 66 fs ;
: kv-put ( key u val u2 -- err ) 1 kv-item ;    \ 0: it is on the disk
: kv-del ( key u -- err ) 0 0 2 kv-item ;       \ 0 (also when it was not there)

create kvb 4032 allot                           \ a value, or a part of a scan
create lastk 488 allot  variable lastk#         \ scan: the last key shown
: db-use ( -- ) s" usage: db get NS/TREE KEY | put NS/TREE KEY VALUE | del NS/TREE KEY | scan NS/TREE" usage ;
: db-refused ( -- ) s" db: refused (no such record, a private namespace, or too long)" +e e! 1 stop ;
: quoted ( a u -- ) '"' emit type '"' emit ;
: db-scan ( -- )                                \ part by part, each from the last key of the one before
  0 lastk# !  0 >r                              ( R: mode )
  begin lastk lastk# @ r@ kvb kv-scan dup 0> while
    rdrop 1 >r  kvb swap 0 ?do                  ( record )
      dup 8 + over @ $ffff and                  ( record key u )
      2dup lastk swap move  dup lastk# !  2dup quoted ."  = "
      + aligned  over @ 16 rshift $ffff and     ( record value u )
      2dup quoted cr  + aligned nip
    loop drop
  repeat drop rdrop ;
: db-main ( a u -- )
  arg dup 0= if db-use then 2>r                 ( rest u ) ( R: the verb )
  arg dup 0= if db-use then  kv-open 0= if db-use then
  2r@ s" scan" str= if 2r> 2drop 2drop db-scan exit then
  arg dup 0= if db-use then                     ( rest u key u2 )
  2r@ s" get" str= if 2r> 2drop  kvb kv-get dup 0< if db-refused then  kvb swap type cr 2drop exit then
  2r@ s" del" str= if 2r> 2drop  kv-del if db-refused then  2drop exit then
  2r> s" put" str= 0= if db-use then
  2swap arg dup 0= if db-use then  2>r 2drop 2r>  kv-put if db-refused then ;
' db-main main: db
