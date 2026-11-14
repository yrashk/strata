#!/bin/sh
# The HTTP server under StrataOS (os/progs/httpd.s), in two parts:
#
#  1. One machine, deterministic (-j -T virtual): `httpd &`, then scripted
#     requests over loopback with `echo REQUEST | nc 127.0.0.1 80`: the index
#     page, a tag listing (and its facets), a file by tag path, a %XX escape
#     and a query, a HEAD, a 404, a 301 (a tag without its slash), a 405, a
#     400, /~ps, a 300 KB file (its size against `cat FILE | wc` and the
#     host's copy), / without index.html (the listing of every file), two
#     requests as browsers send them (CR LF, a 3 KB Cookie header: files on
#     the test disk, $(BUILD)/http-test/disk.img, since the console turns CR
#     into LF), and the first of them again from a client that keeps the
#     connection open for 3 s: its log line must come before "two seconds later" (answered at the
#     blank line, not at the client's close), and its response must reach nc
#     although it arrives before nc's own input ends (net keeps the data of a
#     socket that was only shut down, in LAST-ACK, readable). Responses go to
#     files and are shown with cat/grep, so httpd's log lines and the
#     responses never interleave. The console from the first prompt on is
#     compared with tools/test-http.out; `tools/test-http.sh -u ...`
#     regenerates that file.
#  2. Two machines over a host UDP "cable" (JIT, real time): 10.0.0.2 opens
#     a connection to httpd on 10.0.0.1 that sends its request only after 3
#     seconds, then a second one that asks at once. The second must be
#     answered first (httpd reads several connections at a time): the order
#     of 10.0.0.1's log lines shows it.
#
#   tools/test-http.sh [-u] build/bootrom.stx build/http-test/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
update=0
if [ "${1:-}" = "-u" ]; then update=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ok=0

# ---- 1: one machine, loopback ----------------------------------------------------------------
cat >"$tmp/in1.txt" <<'EOF'
ifconfig
httpd & sleep 1
echo GET / HTTP/1.0 | nc 127.0.0.1 80 > r1
grep HTTP/ < r1
grep Content < r1
grep "<h1>" < r1
echo GET /www/ HTTP/1.1 | nc 127.0.0.1 80 > r2
cat r2
echo GET /src/ HTTP/1.0 | nc 127.0.0.1 80 > r3
grep facets < r3
echo GET /www/style.css HTTP/1.0 | nc 127.0.0.1 80 > r4
grep Content < r4
wc < r4
cat /www/style.css | wc
echo GET /www/index%2Ehtml?x=1 HTTP/1.1 | nc 127.0.0.1 80 > r5
grep HTTP/ < r5
echo HEAD /src/sh.s HTTP/1.1 | nc 127.0.0.1 80 > r6
cat r6
echo GET /www/nosuch.html HTTP/1.0 | nc 127.0.0.1 80 > r7
cat r7
echo GET /bin HTTP/1.0 | nc 127.0.0.1 80 > r8
cat r8
echo POST /www/ HTTP/1.0 | nc 127.0.0.1 80 > r9
grep HTTP/ < r9
grep Allow: < r9
echo garbage | nc 127.0.0.1 80 > r10
grep HTTP/ < r10
nc 127.0.0.1 80 < /test/browser.req > r14
grep HTTP/ < r14
grep Content-Length < r14
nc 127.0.0.1 80 < /test/cookie.req > r15
grep HTTP/ < r15
grep Content-Length < r15
sh -c "cat /test/browser.req; sleep 3" | nc 127.0.0.1 80 > r13 & sleep 2; echo two seconds later
wait %2
grep HTTP/ < r13
echo GET /~ps HTTP/1.0 | nc 127.0.0.1 80 > r11
grep "<h2>" < r11
echo GET /src/sh.s HTTP/1.0 | nc 127.0.0.1 80 | wc
cat /src/sh.s | wc
rm /www/index.html
echo GET / HTTP/1.0 | nc 127.0.0.1 80 > r12
grep title < r12
rm r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 r14 r15
kill %1
wait
EOF
cp "$2" "$tmp/d1.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -N peer -m 4000000000 -d "$tmp/d1.img" -i "$tmp/in1.txt" "$1" \
  >"$tmp/raw1.out" 2>/dev/null
sed -n '/^strata\$ /,$p' "$tmp/raw1.out" | sed -E 's/^\[([0-9]+)\] [0-9]+$/[\1] PID/' >"$tmp/one.out"
if [ $update -eq 1 ]; then
  cp "$tmp/one.out" "$here/tools/test-http.out"
  echo "test-http: tools/test-http.out updated"
fi
one=0
cmp -s "$tmp/one.out" "$here/tools/test-http.out" || {
  diff "$here/tools/test-http.out" "$tmp/one.out" | head -20; one=1
}
# the large file: its Content-Length and the body bytes logged are the host's size
size=$(wc -c <"$b/src/sh.s" | tr -d ' ')
grep -q "^Content-Length: $size" "$tmp/one.out" || { echo "  HEAD: no Content-Length $size"; one=1; }
grep -q "^GET /src/sh.s 200 $size\$" "$tmp/one.out" || { echo "  GET: not $size bytes sent"; one=1; }
if [ $one -eq 0 ]; then
  printf '%-14s OK    httpd over loopback: index, listings, files, HEAD, 301/400/404/405, 300 KB\n' http-one
else
  printf '%-14s FAIL\n' http-one; ok=1
fi

# ---- 2: two machines, two connections at once -------------------------------------------------
pa=$((20000 + $$ % 20000)); pb=$((pa + 1))
cat >"$tmp/inA.txt" <<'EOF'
net 10.0.0.1 &
httpd
EOF
cat >"$tmp/inB.txt" <<'EOF'
net 10.0.0.2 &
sleep 2
sh -c "sleep 3; echo GET /doc/motd HTTP/1.0" | nc 10.0.0.1 80 > slow &
sleep 1
echo GET /doc/about HTTP/1.0 | nc 10.0.0.1 80
wait %2
grep Content-Length < slow
halt
EOF
cp "$2" "$tmp/dA.img"; cp "$2" "$tmp/dB.img"
# A serves until B is done; (a watchdog: neither machine may hang the test)
perl -e 'alarm 120; exec @ARGV' "$b/strata-emu" -c "$n" -g none -N "udp:$pa:127.0.0.1:$pb" -d "$tmp/dA.img" \
  -i "$tmp/inA.txt" "$1" >"$tmp/A.out" 2>&1 &
pidA=$!
perl -e 'alarm 120; exec @ARGV' "$b/strata-emu" -c "$n" -g none -N "udp:$pb:127.0.0.1:$pa" -d "$tmp/dB.img" \
  -i "$tmp/inB.txt" "$1" >"$tmp/B.out" 2>&1
eb=$?
kill $pidA 2>/dev/null; wait $pidA 2>/dev/null
two=0
check() { # check FILE PATTERN what
  if ! grep -q -- "$2" "$1"; then echo "  missing in $(basename "$1" .out): $3"; two=1; fi
}
check "$tmp/A.out" '^httpd: listening on port 80' "httpd started"
check "$tmp/B.out" "$(head -1 "$here/os/files/about")" "the file served while another connection waited"
check "$tmp/B.out" "^Content-Length: $(wc -c <"$here/os/files/motd" | tr -d ' ')" "the slow request's answer"
check "$tmp/B.out" 'all cores halted' "B halted"
order=$(grep -E '^GET /doc/(about|motd) 200' "$tmp/A.out" | cut -d' ' -f2 | tr '\n' ' ')
[ "$order" = "/doc/about /doc/motd " ] || { echo "  log order on A: '$order' (the quick request first)"; two=1; }
[ $eb -eq 0 ] || { echo "  exit status of B: $eb"; two=1; }
if [ $two -eq 0 ]; then
  printf '%-14s OK    two machines: a quick request answered while a slow one waits\n' http-two
else
  printf '%-14s FAIL\n' http-two; ok=1
  echo "---- A"; tail -15 "$tmp/A.out"; echo "---- B"; tail -25 "$tmp/B.out"
fi
exit $ok
