\ =============================================================================
\ httpd.fs: a web server in Strata Forth
\ =============================================================================
\
\   forth httpd.fs [PORT [COUNT]]      (StrataOS; port 8000, until Ctrl-C)
\
\ An HTTP/1.0 server for the tag file system, one connection at a time.
\ A URL path is a tag path (doc/strataos.md 2.4): /doc/motd is the file motd,
\ which carries the tag doc. A path of tags (/forth/demo) is a listing of
\ the files that carry them; a path ending in / is its index.html if there
\ is one, else that listing. / is this server's own page, /www/forth.html
\ (the assembly httpd's is index.html), else the listing of every file.
\
\ GET and HEAD; the answers carry Content-Type (by the extension, else text
\ or binary by the first bytes), Content-Length, and the status 200, 400 (not
\ a request), 404 (no such file or tag) or 405 (not GET or HEAD). One line
\ per request on standard output: method, path, status, body bytes.
\ It stops after COUNT requests if one is given (the tests use that).
\
\ Built on net.fs (sockets) and on messages to the file server, both through
\ the kernel's message call (msg): see net.fs. Limits: requests up to 1 KiB
\ (the headers are read and ignored), listings of 126 files at most (one
\ DIR message), no %-escapes in paths, no keep-alive.

require net
inline-limit @  4 inline-limit !                \ code space is scarce: call even small primitives

8000 value http-port                            \ where it listens: argument 1
0 value http-count                              \ requests to answer before stopping (0: no end): argument 2

\ ---- files: messages to the file server (endpoint register 2) --------------------------
: fs ( handle len mode op -- result ) 2 (msg) ;  \ a request to fs
: fs-size ( path u -- size|err ) tuck >msg 0 swap 0 27 fs ; \ STAT; -4 no such file
: fs-open ( path u -- id|err ) tuck >msg 0 swap 0 3 fs ; \ OPEN for reading
: fs-read ( addr u id -- n ) 2 msg-read ;        \ READ: at most 1 KiB, 0 at the end
: fs-close ( id -- ) 0 0 4 fs drop ;            \ CLOSE
create dir-buf 126 32 * allot                   \ a DIR answer: {name[24], u64 size} per file
: fs-dir ( path u -- n|err )                     \ DIR: the files a tag path names -> dir-buf
  tuck >msg 0 swap 0 10 fs  dup 0> if dir-buf 64 2 pick 32 * 5 tget then ;

\ ---- the connection: buffered output -------------------------------------------------
variable conn                                   \ the socket being answered
create obuf /mbuf allot  variable #obuf         \ what is not sent yet
: send-flush ( -- ) obuf #obuf @ conn @ sock-write drop  0 #obuf ! ;
: send ( a u -- )                               \ to the client (through obuf)
  begin dup while
    #obuf @ /mbuf = if send-flush then
    2dup /mbuf #obuf @ - min >r  obuf #obuf @ + r@ move  r@ #obuf +!  r> /string
  repeat 2drop ;
create crlf 13 c, 10 c,                         \ HTTP ends its lines so
: send-nl ( -- ) crlf 2 send ;                  \ end a line
: send-line ( a u -- ) send send-nl ;           \ a header line
: send-number ( u -- ) <# #s #> send ;          \ in decimal

\ ---- the request -----------------------------------------------------------------------
1024 constant /req
create req /req allot  variable #req            \ the request as it arrived
2variable method  2variable path  2variable version \ the parts of its first line
: req-tail ( i -- c ) #req @ swap - dup 0< if drop 0 else req + c@ then ; \ the i-th byte from the end
: headers-end? ( -- f )                         \ the last thing that arrived is an empty line
  1 req-tail 10 =  2 req-tail 10 =  2 req-tail 13 = 3 req-tail 10 = and  or and ;
: read-request ( -- )                           \ until the empty line, the client's end, or 1 KiB
  0 #req !  begin
    req #req @ +  /req #req @ -  conn @ sock-read  0 max  dup #req +!
    0=  headers-end? or  #req @ /req = or
  until ;
: -cr ( a u -- a u' ) dup if 2dup + 1- c@ 13 = if 1- then then ; \ drop a CR at the end
: parse-request ( -- )                          \ "METHOD PATH VERSION": the first line, in three
  req #req @ 10 split 2swap 2drop -cr
  bl split method 2!  bl split path 2!  version 2!
  path 2@ [char] ? split path 2! 2drop ;        \ the query string is ignored
: prefix? ( a u p pu -- f ) tuck 2>r min 2r> str= ; \ does a u start with p pu?
: bad-request? ( -- f )                         \ not a request at all
  path 2@ 0= if drop true exit then  c@ [char] / <>
  version 2@ dup if s" HTTP/" prefix? 0= or else 2drop then ;
: head? ( -- f ) method 2@ s" HEAD" str= ;      \ headers only?

\ ---- the answer: the status line and the headers ---------------------------------------
2variable status  variable #body                \ "200 OK" and the body's bytes, for the log line
: respond ( type u length a u -- )              \ the status a u, e.g. "404 Not Found"
  2dup status 2!  s" HTTP/1.0 " send send-line
  s" Server: Strata Forth httpd" send-line
  status 2@ s" 405" prefix? if s" Allow: GET, HEAD" send-line then
  dup #body !  s" Content-Length: " send send-number send-nl
  s" Content-Type: " send send-line  send-nl
  head? if 0 #body ! then ;
: error-page ( a u -- )                         \ a status, with its words as a text body
  2>r  s" text/plain" 2r@ nip 1+ 2r@ respond
  2r> head? if 2drop else send crlf 1+ 1 send then ;

\ ---- Content-Type by the file name's extension ------------------------------------------
: mime, ( "ext" "type" -- ) parse-name dup c, s,  parse-name dup c, s, ; \ an entry: two counted strings
create mime-types
  mime, html text/html   mime, htm text/html   mime, txt text/plain   mime, css text/css
  mime, js text/javascript   mime, json application/json   mime, svg image/svg+xml
  mime, png image/png   mime, jpg image/jpeg   mime, gif image/gif   mime, pdf application/pdf
  mime, fs text/plain   mime, s text/plain   mime, md text/plain   mime, c text/plain
  0 c, align
: mime-type ( ext u -- type u | 0 0 )           \ look an extension up
  2>r mime-types begin dup c@ while             ( entry )
    count 2dup + -rot 2r@ str= if count 2r> 2drop exit then  count +
  repeat drop 2r> 2drop 0 0 ;
: extension ( a u -- ext u )                    \ what follows the name's last '.' (empty: none)
  dup begin 1- dup 0< 0= while                  ( a u i )
    2 pick over + c@
    dup [char] . = if drop 1+ /string exit then
    [char] / = if drop + 0 exit then
  repeat drop + 0 ;
: text? ( a u -- f )                            \ no zero byte in it
  0 ?do dup i + c@ 0= if drop false unloop exit then loop drop true ;
: content-type ( name u a n -- type u )         \ by the name's extension, else by the first bytes a n
  2swap extension mime-type dup if 2swap 2drop exit then 2drop
  text? if s" text/plain" else s" application/octet-stream" then ;

\ ---- a file ------------------------------------------------------------------------------
\ The first KiB is read before the headers (they depend on it) into dir-buf,
\ which a file does not need; the rest goes straight from fs into obuf.
variable file  variable #file                   \ the file being sent and its size
: send-rest ( -- )                              \ the file from where it is, a KiB per message pair
  send-flush begin obuf /mbuf file @ fs-read dup 0> while #obuf ! send-flush repeat drop ;
: serve-file ( name u size -- )                 \ 200 and the file
  #file !  2dup fs-open dup file !  0< if 2drop s" 404 Not Found" error-page exit then
  dir-buf /mbuf file @ fs-read 0 max >r         ( name u ) ( R: bytes in dir-buf )
  dir-buf r@ content-type  #file @ s" 200 OK" respond
  head? 0= if dir-buf r@ send send-rest then  rdrop file @ fs-close ;

\ ---- generated pages: a listing ------------------------------------------------------------
\ A page's length goes into the headers, so it is made twice: once to count
\ the bytes, once to send them.
defer out ( a u -- )                            \ where a generated page goes
: tally ( a u -- ) nip #body +! ;               \ the counting pass
: out-nl ( -- ) crlf 2 out ;                    \ end a line
: serve-page ( xt -- )                          \ 200 and the HTML page xt makes, to OUT
  ['] tally is out  0 #body !  dup execute  s" text/html" #body @ s" 200 OK" respond
  head? if drop else ['] send is out execute then ;
: zcount ( a max -- a u )                       \ a name padded with zero bytes
  over swap 0 ?do dup c@ 0= if leave then 1+ loop over - ;
: out-dir ( -- )                                \ the listing's path, ending in '/'
  path 2@ out  path 2@ + 1- c@ [char] / <> if s" /" out then ;
variable #files                                 \ the files in dir-buf
: list-page ( -- )                              \ the listing, in HTML, to OUT
  s" <html><head><title>" out path 2@ out s" </title></head><body><h1>" out
  path 2@ out s" </h1><ul>" out out-nl
  #files @ 0 ?do  dir-buf i 32 * +  dup 24 zcount  ( record name u )
    s" <li><a href='" out out-dir 2dup out s" '>" out out s" </a> " out
    24 + @ <# #s #> out s" </li>" out out-nl
  loop  s" </ul></body></html>" out out-nl ;
: serve-listing ( n -- ) #files !  ['] list-page serve-page ; \ the n files in dir-buf

\ ---- the answer to a request --------------------------------------------------------------
create pbuf 256 allot                           \ room for PATH followed by index.html
: index-path ( -- a u )                         \ PATH followed by index.html
  path 2@ 240 min dup >r  pbuf swap move  s" index.html" pbuf r@ + swap move  pbuf r> 10 + ;
: serve-path ( -- )                             \ a file, an index, a listing, or 404
  path 2@ + 1- c@ [char] / = if                  \ the file it may name: "/" is this
    path 2@ nip 1 = if s" /www/forth.html" else index-path then \ server's own home page
  else path 2@ then
  2dup fs-size dup 0< if drop 2drop else serve-file exit then
  path 2@ s" /~ps" str= if                      \ what the machine is doing: httpd-ps.fs makes it,
    s" /httpd-ps.fs" s" ps-page" ['] (tool) catch \ loaded for the request and forgotten after
    if 2drop 2drop s" 500 Internal Server Error" error-page then exit then
  path 2@ s" /~/" str= if s" /" path 2! then     \ /~/: every file, as on the assembly httpd
  path 2@ fs-dir dup 0< if drop s" 404 Not Found" error-page exit then  serve-listing ;
: answer ( -- )                                 \ the request on conn
  0 #obuf !  0 #body !  read-request parse-request
  bad-request? if s" 400 Bad Request" error-page exit then
  method 2@ s" GET" str= head? or 0= if s" 405 Method Not Allowed" error-page exit then
  serve-path ;

\ ---- serving ------------------------------------------------------------------------------
: log ( -- )                                    \ method path status bytes, as the assembly httpd logs
  method 2@ type space path 2@ type space status 2@ drop 3 type space #body @ . cr flush ;
: serve ( sock -- )                             \ answer one connection, close it, log it
  conn !  answer send-flush  conn @ sock-close  log ;
: serve-all ( lsock -- )                        \ accept and answer, http-count times (0: forever)
  0 begin                                       ( lsock answered )
    over tcp-accept dup 0< if ." httpd: accept failed: " . cr 2drop exit then
    serve 1+  dup http-count =
  until 2drop ;
: httpd ( -- )                                  \ listen on http-port and serve
  http-port tcp-listen  dup 0< if ." httpd: cannot listen on port " http-port . . cr exit then
  ." httpd: serving the tag file system on port " http-port . cr flush
  dup serve-all sock-close ;

\ ---- the command line: `forth httpd.fs [PORT [COUNT]]` -----------------------------------
\ Forth gets it as "include httpd.fs PORT COUNT" (kvar 32: its address and
\ length) and interprets it; this file reads the words after its own name.
\ (They are interpreted too when the server is done: two numbers, pushed.)
: arg ( n -- a u )                              \ the n-th word after the file's name (empty: none)
  >r 32 kvar dup @ swap cell+ @  r> 1+ 0 ?do bl split 2drop loop  bl split 2swap 2drop ;
: number-arg ( default n -- x ) arg dup if number? if nip then else 2drop then ;
http-port 1 number-arg to http-port
http-count 2 number-arg to http-count
inline-limit !                                  \ inlining as it was
httpd
