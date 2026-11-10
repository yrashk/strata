\ =============================================================================
\ udp.fs: UDP and ping for Strata Forth under StrataOS
\ =============================================================================
\
\ The datagram half of the network words, on top of net.fs (which it loads):
\ loaded on demand like net.fs, or for good with `require udp`. A UDP socket
\ is a server socket id like a TCP one (sock-close closes it); datagrams
\ carry at most 1008 bytes here (the server takes 1472).

require net
inline-limit @  4 inline-limit !                \ code space is scarce: primitives are called

: udp-open ( port -- sock|err ) 0 0 56 net ;     \ a UDP socket on port (0: any)
: udp-send ( addr u ip port sock -- n )         \ one datagram: the payload bytes sent
  >r  mbuf 8 + !  mbuf !  /mbuf 16 - min        \ data: u64 address, u64 port, the payload
  tuck mbuf 16 + swap move  dup 16 + mbuf>  r> swap 16 + 0 57 net ;
: udp-recv ( addr u sock -- n ip port )         \ the next datagram (waits for one) and its sender
  swap /mbuf 16 - min 0 58 net  dup 0< if nip 0 0 exit then
  0 over 16 + msg@ >r  r@ 16 + rot 2 pick move  r@ @ r> 8 + @ ;
: ping ( ip -- us|err ) 56 0 52 net ;            \ an echo request: the round trip, -8 no answer in 1 s
inline-limit !                                  \ inlining as it was
create udp.fs                                   \ REQUIRE looks for this name: the file is loaded
