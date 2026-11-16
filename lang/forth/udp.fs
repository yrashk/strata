\ =============================================================================
\ udp.fs: UDP, ping, IPv4 addresses for Strata Forth under StrataOS
\ =============================================================================
\
\ The rest of the network words, on top of net.fs (which it loads): loaded
\ on demand like net.fs, or for good with `require udp`. They are not in
\ net.fs so that a program that needs only TCP (httpd.fs) has more code
\ space. A UDP socket is a server socket id like a TCP one (sock-close
\ closes it); datagrams carry at most 1008 bytes here (the server takes 1472).

require net
inline-limit @  4 inline-limit !                \ code space is scarce: primitives are called

52 constant op-ping   56 constant op-udp        \ the network server's requests (os/spec/net.toml)
57 constant op-sendto 58 constant op-recvfrom

\ ---- UDP: datagrams ------------------------------------------------------------------
\ SENDTO's data and RECVFROM's reply: u64 address, u64 port, the payload.
16 constant /udp-head
/mbuf /udp-head - constant /payload
: udp-open ( port -- sock|err ) 0 0 op-udp net ; \ a UDP socket on port (0: any)
: udp-send ( addr u ip port sock -- n )         \ one datagram: the payload bytes sent
  >r  mbuf 8 + !  mbuf !
  /payload min  tuck mbuf /udp-head + swap move ( n )
  /udp-head + dup mbuf>  r> swap 0 op-sendto net ;
: datagram ( n -- buf ) 0 swap /udp-head + msg@ ; \ the reply's first n payload bytes, into mbuf
: udp-recv ( addr u sock -- n ip port )         \ the next datagram (waits for one) and its sender
  swap /payload min 0 op-recvfrom net  dup 0< if nip 0 0 exit then
  tuck datagram  ( n addr buf )  dup /udp-head + rot 3 pick move  dup @ swap 8 + @ ;

\ ---- ICMP ---------------------------------------------------------------------------
: ping ( ip -- us|err ) 56 0 op-ping net ;       \ an echo request: the round trip, -8 no answer in 1 s

\ ---- TCP: the other end of a connection ----------------------------------------------
\ STAT's data: 64 bytes, then a 32-byte record per socket in use.
: sock-record ( i -- r ) 32 * 64 + 32 msg@ ;
: sock-id   ( r -- id )   c@ ;
: peer-port ( r -- port ) 6 + w@ ;
: peer-ip   ( r -- ip )   8 + l@ ;
: sock-peer ( sock -- ip port )                 \ the other end (0 0: not a socket of ours)
  0 0 0 op-net-stat net 0 max  0 ?do
    i sock-record  2dup sock-id = if nip dup peer-ip swap peer-port unloop exit then drop
  loop drop 0 0 ;

\ ---- addresses ----------------------------------------------------------------------
: ip>str ( ip -- addr u )                       \ "a.b.c.d" (in the pictured-number buffer)
  base @ >r decimal  <#  3 0 do dup 255 and #s drop [char] . hold 8 rshift loop
  255 and #s #>  r> base ! ;
: .ip ( ip -- ) ip>str type space ;             \ print it
: ip-byte ( a u -- n|-1 )                       \ one part of an address: 0..255, else -1
  dup 0= if 2drop -1 exit then  number? if dup 0 256 within if exit then drop then -1 ;
: str>ip ( addr u -- ip|-1 )                    \ "a.b.c.d" -> the address, -1 if it is not one
  0 -rot  4 0 do                                ( ip a u )
    [char] . split ip-byte  dup 0< if 2drop 2drop -1 unloop exit then
    >r rot 8 lshift r> or -rot                  \ the byte, into ip from the right
  loop  nip if drop -1 then ;
inline-limit !                                  \ inlining as it was
create udp.fs                                   \ REQUIRE looks for this name: the file is loaded
