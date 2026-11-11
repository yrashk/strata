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

\ ---- UDP: datagrams ------------------------------------------------------------------
: udp-open ( port -- sock|err ) 0 0 56 net ;     \ a UDP socket on port (0: any)
: udp-send ( addr u ip port sock -- n )         \ one datagram: the payload bytes sent
  >r  mbuf 8 + !  mbuf !  /mbuf 16 - min        \ data: u64 address, u64 port, the payload
  tuck mbuf 16 + swap move  dup 16 + mbuf>  r> swap 16 + 0 57 net ;
: udp-recv ( addr u sock -- n ip port )         \ the next datagram (waits for one) and its sender
  swap /mbuf 16 - min 0 58 net  dup 0< if nip 0 0 exit then
  0 over 16 + msg@ >r  r@ 16 + rot 2 pick move  r@ @ r> 8 + @ ;

\ ---- ICMP ---------------------------------------------------------------------------
: ping ( ip -- us|err ) 56 0 52 net ;            \ an echo request: the round trip, -8 no answer in 1 s

\ ---- TCP: the other end of a connection ----------------------------------------------
: sock-peer ( sock -- ip port )                 \ the other end (0 0: not a socket of ours)
  0 0 0 50 net 0 max                            \ STAT: sockets in use; data: 64 bytes, 32 per socket
  0 ?do  64 i 32 * + 32 msg@                    ( sock record: u8 id .. u16 port at 6, u32 ip at 8 )
    2dup c@ = if nip dup 8 + l@ swap 6 + w@ unloop exit then drop
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
    >r rot 8 lshift r> or -rot
  loop  nip if drop -1 then ;
inline-limit !                                  \ inlining as it was
create udp.fs                                   \ REQUIRE looks for this name: the file is loaded
