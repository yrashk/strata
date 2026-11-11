\ =============================================================================
\ net.fs: TCP for Strata Forth under StrataOS
\ =============================================================================
\
\ Sockets through the network server (os/servers/net.s, doc/strataos.md
\ 2.10). A disk file, like tools.fs: each word below is loaded on demand the
\ first time the interpreter meets it (and forgotten again after it ran);
\ `require net` loads them for good, as a program that uses them inside its
\ definitions must. UDP, ping, addresses and sock-peer are in udp.fs. Bare
\ metal has no network: there these words do not exist.
\
\ Everything goes through one kernel word, the platform's message call:
\
\   (msg) ( handle len mode op reg -- result )
\
\ It writes a request header (op, handle, length, mode) into the process's
\ message buffer, lends the buffer to the server behind endpoint register
\ reg (1 proc, 2 fs, 3 tty, 4 pipe, 6 the network server) and sleeps until
\ the server gives it back with the result. Request and reply
\ data sit in the buffer from byte 64 on, and Forth moves them itself with
\ transfers through c5 (`5 tput`, `5 tget`): on Strata memory is explicit
\ I/O, and so is the message buffer.
\
\ A socket is the server's id for it (a small number). Results below zero
\ are errors: -1 refused, reset or not ours, -4 no network server, -6 no
\ free socket (the server has 4, TCP and UDP together), -7 port in use, -8
\ no answer. An address is IPv4 in a cell: a.b.c.d = a<<24 | b<<16 | c<<8 | d.

inline-limit @  4 inline-limit !                \ code space is scarce under StrataOS: even small
                                                \ primitives are called, not copied (until the end)

\ ---- the message buffer ------------------------------------------------------------
1024 constant /mbuf                             \ data moved per message here (a message holds 4032)
create mbuf /mbuf 8 + allot                     \ staging: transfers want 8-aligned D-LS
: mbuf> ( u -- ) mbuf 64 rot aligned 5 tput ;   \ the first u bytes of mbuf -> the request data
: >msg ( a u -- )                               \ u bytes (at most 1 KiB), then a zero, as request data
  /mbuf min  >r  mbuf r@ move  0 mbuf r@ + c!  r> 1+ mbuf> ;
: msg@ ( off u -- mbuf )                        \ u bytes of the reply data from offset off, into mbuf
  >r 64 + mbuf swap r> aligned 5 tget mbuf ;    \ (loads from mbuf wait for the transfer)
: msg> ( a u -- ) tuck 0 swap msg@ swap rot move ; \ the first u bytes of the reply data -> a
: msg-read ( a u handle reg -- n )              \ READ through register reg: at most 1 KiB, into a
  >r swap /mbuf min 0 1 r> (msg)  dup 0> if 2dup msg> then nip ;

\ ---- strings -------------------------------------------------------------------------
: split ( a u c -- rest u2 first u1 )           \ cut a u at the first c: what follows it, what precedes it
  >r 2dup begin dup while over c@ r@ <> while 1 /string repeat then r> drop
  2swap drop 2 pick over -  2swap dup if 1 /string then 2swap ;

\ ---- the network server -------------------------------------------------------------
\ Register 6. A process has no register to spare for its endpoint, so (msg)
\ asks proc for it (LOOKUP "net") before every request and drops it after:
\ a proc round trip per request, and proc stays reachable through register 1.
\ If none runs, one is started the way os/lib/sys.s does it: `net` (its
\ address comes from the link: 10.0.2.15 under -N nat, else 10.0.0.1), its
\ output on the console.
variable net-ready                              \ the network server was found
create net-spawn                                \ SPAWN's data: ncores, handles 0..2, the command line
  0 , -1 , $300000000 , $300000000 ,            \ (one thread; no input; output and errors: tty 0)
  char " parse net" s, align                    \ (not S": its buffer may hold the caller's string)
: net? ( -- f ) 0 0 0 50 6 (msg) 0< 0= ;        \ is there a network server? (a STAT: -4 if not)
: start-net ( -- ) net-spawn 35 >msg  0 3 0 5 1 (msg) drop ; \ have proc start one
: net-init ( -- )                               \ find the network server; start one if none runs
  net-ready @ if exit then
  cores 1 > abort" net: one thread only (start Forth without -n)"
  net? 0= if  start-net  40 0 do 50 ms net? if leave then loop  then
  net? 0= abort" net: no network server"  true net-ready ! ;
: net ( handle len mode op -- result ) net-init 6 (msg) ; \ a request to the network server

\ ---- TCP: a connection is a socket that READ, WRITE and CLOSE work on ------------------
: tcp-listen ( port -- sock|err ) 0 0 54 net ;   \ a listening socket
: tcp-accept ( lsock -- sock|err ) 0 0 55 net ;  \ the next connection to it (waits for one)
: tcp-connect ( ip port -- sock|err ) 0 53 net ; \ a connection, once established
: sock-read ( addr u sock -- n )                \ what has arrived (waits): at most u bytes and 1 KiB;
  net-init 6 msg-read ;                         \ 0 once the peer has closed, < 0 on an error
: sock-write ( addr u sock -- n )               \ all u bytes (n = u), or an error
  over >r >r  begin dup while                   ( a u ) ( R: u sock )
    2dup /mbuf min tuck >msg  r@ swap 0 2 net   ( a u n: the server takes at least a byte )
    dup 0< if nip nip 2r> 2drop exit then  /string
  repeat 2drop r> drop r> ;
: sock-close ( sock -- ) 0 0 4 net drop ;       \ the buffered data goes, then FIN; the socket is gone
: sock-shutdown ( sock -- ) 0 1 4 net drop ;    \ no more sending (FIN); reading goes on
inline-limit !                                  \ inlining as it was
create net.fs                                   \ REQUIRE looks for this name: the file is loaded
