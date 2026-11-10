\ Strata Forth under StrataOS: the network words, over loopback (no link needed).
\ Fed to `forth < nettest.fs` by tests/run-os.sh; expected output: tests/net.out.
\ ---- at the prompt each word loads net.fs (or udp.fs) for one command
s" 10.0.0.1" str>ip h.  s" 1.2.3" str>ip .  s" 1.2.3.256" str>ip .  s" 1.2.3.4.5" str>ip .
$7f000001 .ip  $0a000102 ip>str type
$7f000001 ping 0> .
[defined] tcp-listen .  [defined] net.fs .
\ ---- for good: TCP within one process (a connection is established before it is accepted)
require udp  [defined] tcp-listen .  [defined] udp-open .  [defined] net.fs .
variable lsn  variable cli  variable srv  create buf 64 allot
7000 tcp-listen dup lsn ! 0> .  7000 tcp-listen .
$7f000001 7000 tcp-connect dup cli ! 0> .
lsn @ tcp-accept dup srv ! 0> .
s" hello, strata" cli @ sock-write .
buf 64 srv @ sock-read buf swap type
srv @ sock-peer 49151 > . .ip
s" and back" srv @ sock-write .  srv @ sock-close
buf 64 cli @ sock-read buf swap type  buf 64 cli @ sock-read .
cli @ sock-close  lsn @ sock-close
$7f000001 7001 tcp-connect .
\ ---- UDP
0 udp-open dup cli ! 0> .  7001 udp-open dup srv ! 0> .
s" a datagram" $7f000001 7001 cli @ udp-send .
buf 64 srv @ udp-recv 49151 > . .ip buf swap type
cli @ sock-close  srv @ sock-close
bye
