#!/bin/sh
# Strata Forth as a StrataOS 0.1 program: boots StrataOS on the emulator with
# scripted console input (12 cores, interpreter, virtual timer: deterministic)
# from the test disk (build/forth-test/disk.img: the standard disk plus
# tests/*.fs, and tests/http/* tagged httptest) and checks four things:
#   1. tests/test.fs through `-n 6 forth < test.fs` gives tests/test.out, the
#      output of the bare-metal Forth (first line and the lines marked as
#      platform-specific aside);
#   2. tests/ostest.fs and a few command lines (files, tools on demand,
#      `forth FILE`, `forth -e`, pipes, `include` after a `cd`) give tests/os.out;
#   3. preemption: `forth preempt.fs` compiles and runs code while `spin`
#      shares its core; its output is right, and `ps`, a little later, shows
#      that both were switched (forth at least 5 times);
#   4. the network words (tests/nettest.fs) and httpd.fs over loopback give
#      tests/net.out.
#   BUILD=build lang/forth/tests/run-os.sh        (UPDATE=1 rewrites tests/os.out and tests/net.out)
set -u
BUILD=${BUILD:-build}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$BUILD/forth-test
DISK=$OUT/disk.img
[ -f "$DISK" ] || { echo "test-forth: $DISK is missing (make test-forth builds it)"; exit 1; }
# boot NAME: run the session in $OUT/NAME.in, console to $OUT/NAME.con
boot() {
  cp "$DISK" "$OUT/disk-run.img"
  "$BUILD/strata-emu" -c 12 -T virtual -g none -j -m 3000000000 -d "$OUT/disk-run.img" \
    -i "$OUT/$1.in" "$BUILD/bootrom.stx" > "$OUT/$1.con" 2> "$OUT/$1.err" ||
    { echo "test-forth: StrataOS session $1 failed"; tail -5 "$OUT/$1.err"; exit 1; }
}
# the banner's free-space figures change with every edit of core.fs: mask them
mask() { sed -e 's/[0-9][0-9]* code bytes free, [0-9][0-9]* data bytes free/N code bytes free, N data bytes free/' \
             -e 's/[0-9][0-9]* CODE BYTES FREE, [0-9][0-9]* DATA BYTES FREE/N CODE BYTES FREE, N DATA BYTES FREE/'; }
ok=1

# ---- 1. the common regression test, on 6 threads
printf -- '-n 6 forth < test.fs\nhalt\n' > "$OUT/os1.in"
boot os1
sed -n '/^Strata Forth/,/^bye /p' "$OUT/os1.con" | sed -e '1d' -e '/^23 kvar @ /d' -e 's/^bye .*/bye /' > "$OUT/os1.out"
sed -e '1d' -e '/^23 kvar @ /d' "$HERE/test.out" > "$OUT/os1.exp"
[ -s "$OUT/os1.exp" ] && [ -n "$(tail -c 1 "$OUT/os1.exp")" ] && echo >> "$OUT/os1.exp"
if cmp -s "$OUT/os1.out" "$OUT/os1.exp"; then
  echo "test-forth: StrataOS (forth -n 6 < test.fs) matches tests/test.out ($(wc -l < "$OUT/os1.out" | tr -d ' ') lines)"
else
  echo "test-forth: StrataOS output of test.fs differs from tests/test.out:"; diff "$OUT/os1.exp" "$OUT/os1.out" | head -20; ok=0
fi

# ---- 2. files, tools, command lines, pipes
{
  printf 'forth < ostest.fs\n'
  printf 'forth inc2.fs from-inc2 cr\n'
  printf 'forth -e 6 7 * . cr .( done)\n'
  printf 'echo "2 3 + ." | forth | upper\n'
  printf 'echo ": sq dup * ; 12 sq . see sq" | forth | grep mul | wc\n'
  printf 'forth nofile.fs\n'
  printf 'forth incerr.fs\n'
  # the current tag path: relative names (and nested includes) resolve under it
  printf 'cd /test; forth -e include inc1.fs cr .fcache\n'
  printf 'cd /demo; forth inc2.fs; cd /\n'
  printf 'halt\n'
} > "$OUT/os2.in"
boot os2
sed -n '/^strata\$ forth < ostest.fs/,$p' "$OUT/os2.con" | mask > "$OUT/os2.out"
if [ "${UPDATE:-0}" = 1 ]; then cp "$OUT/os2.out" "$HERE/os.out"; echo "test-forth: os.out updated"; fi
if cmp -s "$OUT/os2.out" "$HERE/os.out"; then
  echo "test-forth: StrataOS files, tools on demand, command lines and pipes match tests/os.out ($(wc -l < "$HERE/os.out" | tr -d ' ') lines)"
else
  echo "test-forth: StrataOS output differs from tests/os.out:"; diff "$HERE/os.out" "$OUT/os2.out" | head -20; ok=0
fi

# ---- 3. preemption: forth and spin on core 6
printf -- '-c 6 spin 60 a > sa &\n-c 6 forth preempt.fs > fo &\nspin 4 x\nps\nwait\ncat fo\nhalt\n' > "$OUT/os3.in"
boot os3
# ps: pid ppid state core cpus switches KiB name: both on core 6, both switched
sw=$(awk '$4 == 6 && ($8 == "spin" || $8 == "forth") && $6 >= 1 { n++ } END { print n + 0 }' "$OUT/os3.con")
fsw=$(awk '$4 == 6 && $8 == "forth" { print $6 }' "$OUT/os3.con")
[ "${fsw:-0}" -ge 5 ] || sw=0
res=$(sed -n '/^strata\$ cat fo/,/^strata\$ halt/p' "$OUT/os3.con" | sed -e '1d' -e '$d' | tr '\n' '|')
want='299850000 |heap ok 144 |'
if [ "$sw" = 2 ] && [ "$res" = "$want" ]; then
  echo "test-forth: preemption OK (forth compiled and ran 150 words sharing core 6 with spin; $fsw switches when ps looked)"
else
  echo "test-forth: preemption FAILED (switched processes on core 6: $sw, output: $res)"; tail -15 "$OUT/os3.con"; ok=0
fi
# ---- 4. the network words and httpd.fs, over loopback (127.0.0.1: no link needed)
# tests/nettest.fs uses the words at the prompt (on demand) and for good, TCP
# and UDP within one process; then httpd.fs answers 11 requests sent with nc
# for the files of tests/http/ (tagged httptest): two files, a listing with
# and without a trailing /, HEAD, 404, 405, 400, a binary's type, the type
# of / (its home page, /www/forth.html), and /~ps twice (what the machine is
# doing: lines without numbers, which change with the OS);
# its log is shown last. HTTP's CRs are dropped before the comparison, and
# the size of /~ps in the log is masked.
{
  printf 'forth < nettest.fs\n'
  printf -- '-n 2 forth -e 80 tcp-listen\n'
  printf 'forth httpd.fs 8000 11 > hlog &\n'
  printf 'echo "GET /httptest/note.txt HTTP/1.0" | nc 127.0.0.1 8000\n'
  printf 'echo "GET /httptest/page.html HTTP/1.0" | nc 127.0.0.1 8000\n'
  printf 'echo "GET /httptest HTTP/1.0" | nc 127.0.0.1 8000\n'
  printf 'echo "HEAD /httptest/ HTTP/1.0" | nc 127.0.0.1 8000\n'
  printf 'echo "GET /httptest/nosuch HTTP/1.0" | nc 127.0.0.1 8000\n'
  printf 'echo "DELETE /httptest/note.txt HTTP/1.0" | nc 127.0.0.1 8000\n'
  printf 'echo "nonsense" | nc 127.0.0.1 8000\n'
  printf 'echo "GET /httptest/blob.bin HTTP/1.0" | nc 127.0.0.1 8000 | grep Type\n'
  printf 'echo "HEAD / HTTP/1.0" | nc 127.0.0.1 8000 | grep Type\n'
  printf 'echo "GET /~ps HTTP/1.0" | nc 127.0.0.1 8000 | grep doing\n'
  printf 'echo "GET /~ps HTTP/1.0" | nc 127.0.0.1 8000 | grep Processes\n'
  printf 'wait\ncat hlog\nhalt\n'
} > "$OUT/os4.in"
boot os4
sed -n '/^strata\$ forth < nettest.fs/,$p' "$OUT/os4.con" | mask | tr -d '\r' | sed 's|^GET /~ps 200 [0-9]* $|GET /~ps 200 N |' > "$OUT/os4.out"
if [ "${UPDATE:-0}" = 1 ]; then cp "$OUT/os4.out" "$HERE/net.out"; echo "test-forth: net.out updated"; fi
if cmp -s "$OUT/os4.out" "$HERE/net.out"; then
  echo "test-forth: StrataOS network words and httpd.fs (loopback) match tests/net.out ($(wc -l < "$HERE/net.out" | tr -d ' ') lines)"
else
  echo "test-forth: StrataOS network output differs from tests/net.out:"; diff "$HERE/net.out" "$OUT/os4.out" | head -20; ok=0
fi
[ $ok = 1 ] || exit 1
