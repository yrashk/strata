#!/bin/sh
# TCP/IP under StrataOS (os/servers/net.s, the network interface of
# common/net.h, common/netnat.h), in three parts:
#
#  1. One machine, deterministic (-j -T virtual), with the built-in test
#     peer on the link and its names only (-N peer,nodns): ifconfig (which
#     starts the network server), ping over the server's own loopback and to
#     the peer, TCP through tcpecho (a line and a 300 KB file, compared with
#     the file itself), UDP to the peer's echo port and between two programs,
#     a refused connection, netstat, a new address; DNS: host (an address, a
#     CNAME, two addresses, no such name), ping and nc by name, the second
#     resolver when the first does not answer (192.0.2.1: the peer drops
#     TEST-NET-1), no resolver answering, localhost. The console from the
#     first prompt on is compared with tools/test-net.out (round-trip times
#     and job pids normalised); `tools/test-net.sh -u ...` regenerates it.
#  2. Two machines over a host UDP "cable" (-N udp:...), at full speed (JIT,
#     real time): 10.0.0.1 runs tcpecho and receivers, 10.0.0.2 pings it, sends
#     a line through tcpecho, a file each way over TCP and a datagram over UDP.
#     The checks look for each of those in the two consoles.
#  3. The user-mode NAT (-N nat), offline: tools/net-echo.py runs a TCP and a
#     UDP echo server on 127.0.0.1, which the guest reaches as 10.0.2.2: a
#     line and a 300 KB file through TCP (compared), a datagram, a refused
#     connection (RST), ping to the gateway; and inbound, -N nat,fwd=PORT:80
#     with tcpecho on port 80 in the guest: three host connections in a row
#     to 127.0.0.1:PORT must each get their line back. Needs python3 (else
#     skipped).
#
#   tools/test-net.sh [-u] build/bootrom.stx build/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
update=0
if [ "${1:-}" = "-u" ]; then update=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ok=0

# ---- 1: one machine and the test peer ---------------------------------------------------
cat >"$tmp/in1.txt" <<'EOF'
ifconfig
ping -c 3 127.0.0.1
ping -c 2 -s 1000 10.0.0.2
ping -c 1 10.0.0.1
tcpecho 7 2 &
echo hello strata | nc 10.0.0.1 7
cat sh.s | nc 127.0.0.1 7 | wc
cat sh.s | wc
netstat
echo hello peer | nc -u 10.0.0.2 7
nc -u -l 5003 &
echo dgram one | nc -u 127.0.0.1 5003
wait
nc 10.0.0.1 9 < motd
ifconfig 10.0.0.5
ping -c 1 10.0.0.5
host peer.test
host two.test
ping -c 2 peer.test
echo hello by name | nc -u peer.test 7
host nosuch.test
ping -c 1 nosuch.test
ifconfig dns 192.0.2.1 10.0.0.53
host www.peer.test
ifconfig dns 192.0.2.1 192.0.2.2
host gone.test
host localhost
EOF
cp "$2" "$tmp/d1.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -N peer,nodns -m 4000000000 -d "$tmp/d1.img" -i "$tmp/in1.txt" "$1" \
  >"$tmp/raw1.out" 2>/dev/null
sed -n '/^strata\$ /,$p' "$tmp/raw1.out" |
  sed -E 's/time=[0-9]+\.[0-9]+ ms/time=T ms/; s/^\[([0-9]+)\] [0-9]+$/[\1] PID/' >"$tmp/one.out"
if [ $update -eq 1 ]; then
  cp "$tmp/one.out" "$here/tools/test-net.out"
  echo "test-net: tools/test-net.out updated"
fi
if cmp -s "$tmp/one.out" "$here/tools/test-net.out"; then
  printf '%-14s OK    ping, TCP, UDP on one machine and the test peer\n' net-one
else
  printf '%-14s FAIL\n' net-one; diff "$here/tools/test-net.out" "$tmp/one.out" | head -20; ok=1
fi

# ---- 2: two machines over UDP ---------------------------------------------------------------
pa=$((20000 + $$ % 20000)); pb=$((pa + 1))
cat >"$tmp/inA.txt" <<'EOF'
net 10.0.0.1 &
tcpecho 7 1 &
nc -l 5001
nc -u -l 5003
cat about | nc 10.0.0.2 5002
EOF
cat >"$tmp/inB.txt" <<'EOF'
net 10.0.0.2 &
sleep 2
ping -c 3 10.0.0.1
echo hello over tcp | nc 10.0.0.1 7
cat motd | nc 10.0.0.1 5001
sleep 1
echo hello over udp | nc -u 10.0.0.1 5003
nc -l 5002
netstat
EOF
cp "$2" "$tmp/dA.img"; cp "$2" "$tmp/dB.img"
# (a watchdog: neither machine may hang the test)
perl -e 'alarm 300; exec @ARGV' "$b/strata-emu" -c "$n" -g none -N "udp:$pa:127.0.0.1:$pb" -d "$tmp/dA.img" \
  -i "$tmp/inA.txt" "$1" >"$tmp/A.out" 2>&1 &
pidA=$!
perl -e 'alarm 300; exec @ARGV' "$b/strata-emu" -c "$n" -g none -N "udp:$pb:127.0.0.1:$pa" -d "$tmp/dB.img" \
  -i "$tmp/inB.txt" "$1" >"$tmp/B.out" 2>&1 &
pidB=$!
wait $pidA; ea=$?
wait $pidB; eb=$?
two=0
check() { # check FILE PATTERN what
  if ! grep -q -- "$2" "$1"; then echo "  missing in $(basename "$1" .out): $3"; two=1; fi
}
check "$tmp/B.out" '^64 bytes from 10.0.0.1: seq=1 ' "ping replies"
check "$tmp/B.out" '^--- 10.0.0.1: 3 sent, [123] received' "ping summary"
check "$tmp/B.out" '^hello over tcp$' "the line echoed through tcpecho"
check "$tmp/A.out" 'Welcome to StrataOS' "the motd sent from B over TCP"
check "$tmp/A.out" '^from 10.0.0.2:[0-9]*: hello over udp' "the datagram from B"
check "$tmp/B.out" "$(head -1 "$here/os/files/about")" "the file sent from A over TCP"
check "$tmp/A.out" 'all cores halted' "A halted"
check "$tmp/B.out" 'all cores halted' "B halted"
[ $ea -eq 0 ] && [ $eb -eq 0 ] || { echo "  exit status: A $ea, B $eb"; two=1; }
if [ $two -eq 0 ]; then
  printf '%-14s OK    two machines over UDP: ping, TCP both ways, UDP\n' net-two
else
  printf '%-14s FAIL\n' net-two; ok=1
  echo "---- A"; tail -25 "$tmp/A.out"; echo "---- B"; tail -25 "$tmp/B.out"
fi

# ---- 3: the NAT, against host services on 127.0.0.1 ----------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  printf '%-14s SKIP  (needs python3)\n' net-nat
  exit $ok
fi
tp=$((30000 + $$ % 20000)); up=$((tp + 1)); cp_=$((tp + 2)); fp=$((tp + 3))
python3 "$here/tools/net-echo.py" serve "$tp" "$up" &
pidE=$!
{
  printf 'ping -c 2 10.0.2.2\n'
  printf 'echo hello nat | nc 10.0.2.2 %s\n' "$tp"
  printf 'cat sh.s | nc 10.0.2.2 %s | wc\n' "$tp"
  printf 'cat sh.s | wc\n'
  printf 'echo dgram nat | nc -u 10.0.2.2 %s\n' "$up"
  printf 'nc 10.0.2.2 %s < motd\n' "$cp_"
  printf 'tcpecho 80 3 &\n'
  printf 'wait\n'
  printf 'echo inbound done\n'
} >"$tmp/inN.txt"
cp "$2" "$tmp/dN.img"
perl -e 'alarm 300; exec @ARGV' "$b/strata-emu" -c "$n" -g none -N "nat,fwd=$fp:80" -d "$tmp/dN.img" \
  -i "$tmp/inN.txt" "$1" >"$tmp/N.out" 2>&1 &
pidN=$!
for i in 1 2 3; do
  python3 "$here/tools/net-echo.py" client "$fp" "hello inbound $i" 120 >>"$tmp/fwd.out" 2>&1
done
wait $pidN; en=$?
kill $pidE 2>/dev/null; wait $pidE 2>/dev/null
nat=0
nchk() { # nchk FILE PATTERN what
  if ! grep -q -- "$2" "$1"; then echo "  missing: $3"; nat=1; fi
}
nchk "$tmp/N.out" '^net: 10.0.2.15, link up' "the guest at 10.0.2.15"
nchk "$tmp/N.out" '^--- 10.0.2.2: 2 sent, 2 received' "pings to the gateway"
nchk "$tmp/N.out" '^hello nat$' "a line through the host's TCP echo"
big=$(grep -c '^6[0-9]* [0-9]* [0-9]*$' "$tmp/N.out")
same=$(grep '^[0-9]* [0-9]* [0-9]*$' "$tmp/N.out" | sort | uniq -c | awk '$1 >= 2' | wc -l | tr -d ' ')
[ "$same" -ge 1 ] || { echo "  missing: the 300 KB file through TCP, the same as the file ($big counts)"; nat=1; }
nchk "$tmp/N.out" "^from 10.0.2.2:$up: dgram nat" "a datagram through the host's UDP echo"
nchk "$tmp/N.out" '^nc: failed: -1' "a refused connection (RST)"
nchk "$tmp/N.out" '^inbound done' "the guest's tcpecho served its three connections"
for i in 1 2 3; do nchk "$tmp/fwd.out" "^hello inbound $i\$" "inbound connection $i through fwd=$fp:80"; done
[ $en -eq 0 ] || { echo "  exit status $en"; nat=1; }
if [ $nat -eq 0 ]; then
  printf '%-14s OK    NAT: TCP both ways, UDP, RST, ping, 3 inbound connections\n' net-nat
else
  printf '%-14s FAIL\n' net-nat; ok=1
  echo "---- guest"; tail -30 "$tmp/N.out"; echo "---- host"; cat "$tmp/fwd.out"
fi
exit $ok
