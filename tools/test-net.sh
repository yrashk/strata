#!/bin/sh
# TCP/IP under StrataOS (os/servers/net.s, the network interface of
# common/net.h), in two parts:
#
#  1. One machine, deterministic (-j -T virtual), with the built-in test
#     peer on the link (-N peer): ifconfig (which starts the network server),
#     ping over the server's own loopback and to the peer, TCP through tcpecho
#     (a line and a 300 KB file, compared with the file itself), UDP to the
#     peer's echo port and between two programs, a refused connection,
#     netstat, a new address. The console from the first prompt on is
#     compared with tools/test-net.out (round-trip times and job pids
#     normalised); `tools/test-net.sh -u ...` regenerates that file.
#  2. Two machines over a host UDP "cable" (-N udp:...), at full speed (JIT,
#     real time): 10.0.0.1 runs tcpecho and receivers, 10.0.0.2 pings it, sends
#     a line through tcpecho, a file each way over TCP and a datagram over UDP.
#     The checks look for each of those in the two consoles.
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
EOF
cp "$2" "$tmp/d1.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -N peer -m 4000000000 -d "$tmp/d1.img" -i "$tmp/in1.txt" "$1" \
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
exit $ok
