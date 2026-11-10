#!/bin/sh
# The WebAssembly build of the emulator (make wasm: the module the play
# page runs) against the native interpreter, under node: runs every example
# image, the window-server demo for a while and the Forth regression input
# three times: natively interpreted (strata-emu -j), in WebAssembly
# interpreted (-j) and with the WebAssembly JIT (-J, translating at once and
# with the default hot threshold), and requires
#   * the same console output, minus lines starting with '@' (timing)
#   * the same exit status and the same halt/fault line per core; for the
#     interpreter also the same instret and the same order (the JIT's
#     quanta make instret of spinning cores timing-dependent)
#   * for images that draw, the same last presented frame (-F)
# All runs use the virtual timer and no window. Then the JIT fuzzer
# (emu/jit/fuzz.py) runs random programs on the WebAssembly build, JIT
# against interpreter.
#
#   tools/test-wasm.sh [image.stx ...]      (default: build/examples/*.stx)
#   FUZZ=n: fuzz programs (default 60; 0: none)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
ncores=${NCORES:-8}
if ! command -v node >/dev/null 2>&1; then echo "test-wasm: node not found; skipped"; exit 0; fi
[ -f "$b/web/strata-emu.js" ] || { echo "test-wasm: $b/web/strata-emu.js missing (make wasm)"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/wemu" <<WRAP
#!/bin/sh
exec node "$here/tools/wasm-run.js" "$b/web/strata-emu.js" "\$@"
WRAP
chmod +x "$tmp/wemu"
opts="-T virtual -g none -r 640x480"
fail=0
[ $# -gt 0 ] || set -- "$b"/examples/*.stx

# one WHAT EMU ARGS...: a run; leaves WHAT.out .o .err .h .f .ppm .rc
one() {
  w=$1; shift
  "$@" >"$tmp/$w.out" 2>"$tmp/$w.err0" </dev/null; echo $? >"$tmp/$w.rc"
  grep -v '^no frame was presented' "$tmp/$w.err0" >"$tmp/$w.err" # (it names the -F file)
  grep -v '^@' "$tmp/$w.out" >"$tmp/$w.o"
  grep '^core' "$tmp/$w.err" >"$tmp/$w.f"
  sed 's/ instret=[0-9]*//' "$tmp/$w.f" | sort >"$tmp/$w.h"
}
# same A B EXACT: compares two runs
same() {
  ok=1
  [ "$(cat "$tmp/$1.rc")" = "$(cat "$tmp/$2.rc")" ] || { echo "  $2: exit status $(cat "$tmp/$2.rc"), native $(cat "$tmp/$1.rc")"; ok=0; }
  cmp -s "$tmp/$1.o" "$tmp/$2.o" || { echo "  $2: console output differs:"; diff "$tmp/$1.o" "$tmp/$2.o" | head -10; ok=0; }
  cmp -s "$tmp/$1.h" "$tmp/$2.h" || { echo "  $2: halt state differs:"; diff "$tmp/$1.h" "$tmp/$2.h" | head -10; ok=0; }
  if [ "$3" = exact ]; then
    cmp -s "$tmp/$1.err" "$tmp/$2.err" || { echo "  $2: messages (instret, order) differ:"; diff "$tmp/$1.err" "$tmp/$2.err" | head -10; ok=0; }
    cmp -s "$tmp/$1.out" "$tmp/$2.out" || { echo "  $2: timing lines differ"; ok=0; }
  fi
  if [ -s "$tmp/$1.ppm" ] || [ -s "$tmp/$2.ppm" ]; then
    cmp -s "$tmp/$1.ppm" "$tmp/$2.ppm" || { echo "  $2: the presented frames differ"; ok=0; }
  fi
  return $((1 - ok))
}
# run NAME ARGS...
run() {
  name=$1; shift
  rm -f "$tmp"/*.ppm
  one n "$b/strata-emu" -c "$ncores" $opts -j -F "$tmp/n.ppm" "$@"
  one wi "$tmp/wemu" -c "$ncores" $opts -j -F "$tmp/wi.ppm" "$@"
  STRATA_JIT_HOT=1 one wj "$tmp/wemu" -c "$ncores" $opts -J -F "$tmp/wj.ppm" "$@"
  STRATA_JIT_HOT=0 one wk "$tmp/wemu" -c "$ncores" $opts -J -F "$tmp/wk.ppm" "$@"
  one wh "$tmp/wemu" -c "$ncores" $opts -J -F "$tmp/wh.ppm" "$@"
  bad=0
  same n wi exact || bad=1
  same n wj loose || bad=1
  same n wk loose || bad=1
  same n wh loose || bad=1
  frame=""; [ -s "$tmp/n.ppm" ] && frame="  same frame"
  if [ $bad -eq 0 ]; then printf '%-14s OK   interp = native; jit (eager, no tail calls, hot) agree%s\n' "$name" "$frame"
  else printf '%-14s FAIL\n' "$name"; fail=1; fi
}

for img in "$@"; do
  [ -f "$img" ] || { printf '%-14s FAIL  (no image)\n' "$(basename "$img" .stx)"; fail=1; continue; }
  run "$(basename "$img" .stx)" "$img"
done
if [ -f "$b/forth.stx" ]; then
  run forth-test -m 400000000 -i "$here/lang/forth/tests/test.fs" "$b/forth.stx"
  run forth-gfx -i "$here/lang/forth/demos/gfx.fs" "$b/forth.stx"
fi
if [ -f "$b/ws/wsdemo.stx" ]; then # 1 core, a device read always in flight: 3 s of machine time
  ncores=1 run wsdemo -m 60000000 "$b/ws/wsdemo.stx"
fi

# the play page's network: StrataOS with -N peer, the guest's DNS answered by
# site/play/net.js (DNS over HTTPS, here with a fetch that answers from canned
# JSON: no network needed): a CNAME chain from the page, the peer's own names
if [ -f "$b/disk.img" ] && [ -f "$b/bootrom.stx" ]; then
  printf 'host example.com\nhost www.peer.test\nping -c 1 peer.test\n' >"$tmp/dns.in"
  cp "$b/disk.img" "$tmp/dns.img"
  STRATA_DOH_STUB='{"Status":0,"Answer":[{"name":"example.com.","type":5,"TTL":60,"data":"edge.example.net."},{"name":"edge.example.net.","type":1,"TTL":60,"data":"93.184.216.34"}]}' \
    "$tmp/wemu" -c 8 -J -g none -N peer -m 2000000000 -d "$tmp/dns.img" -i "$tmp/dns.in" "$b/bootrom.stx" >"$tmp/dns.out" 2>&1
  if grep -q '^example.com is an alias for edge.example.net$' "$tmp/dns.out" &&
     grep -q '^edge.example.net has address 93.184.216.34$' "$tmp/dns.out" &&
     grep -q '^peer.test has address 10.0.0.2$' "$tmp/dns.out" && grep -q '^--- peer.test: 1 sent, 1 received' "$tmp/dns.out"; then
    printf '%-14s OK   StrataOS host/ping through the page'"'"'s DNS over HTTPS (stubbed) and the peer\n' web-dns
  else
    printf '%-14s FAIL\n' web-dns; tail -15 "$tmp/dns.out"; fail=1
  fi
fi

# the play page's relay mode: the guest's packets over a WebSocket to
# tools/netrelay (the simulators' NAT), offline: a ping to the gateway and a
# line through a TCP echo server on 127.0.0.1 (tools/net-echo.py), which the
# guest reaches as 10.0.2.2
if [ -x "$b/netrelay" ] && command -v python3 >/dev/null 2>&1 &&
   node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null; then
  rp=$((40000 + $$ % 10000)); ep=$((rp + 1))
  "$b/netrelay" -p "$rp" 2>"$tmp/relay.err" &
  pidR=$!
  python3 "$here/tools/net-echo.py" serve "$ep" "$((ep + 1))" &
  pidE=$!
  sleep 1
  printf 'ping -c 1 10.0.2.2\necho through the relay | nc 10.0.2.2 %s\n' "$ep" >"$tmp/relay.in"
  cp "$b/disk.img" "$tmp/relay.img"
  STRATA_RELAY="ws://127.0.0.1:$rp/" "$tmp/wemu" -c 8 -J -g none -N web,nat -m 2000000000 -d "$tmp/relay.img" \
    -i "$tmp/relay.in" "$b/bootrom.stx" >"$tmp/relay.out" 2>&1
  kill $pidR $pidE 2>/dev/null; wait $pidR $pidE 2>/dev/null
  if grep -q '^--- 10.0.2.2: 1 sent, 1 received' "$tmp/relay.out" && grep -q '^through the relay$' "$tmp/relay.out" &&
     grep -q '^net: 10.0.2.15' "$tmp/relay.out"; then
    printf '%-14s OK   StrataOS through a WebSocket to tools/netrelay: ping, TCP\n' web-relay
  else
    printf '%-14s FAIL\n' web-relay; tail -15 "$tmp/relay.out"; fail=1
  fi
else
  printf '%-14s SKIP (needs build/netrelay, python3, node with WebSocket)\n' web-relay
fi

n=${FUZZ:-60}
if [ "$n" -gt 0 ] && command -v python3 >/dev/null 2>&1; then
  STRATA_JIT_HOT=1 python3 "$here/emu/jit/fuzz.py" -n "$n" --emu "$tmp/wemu" --sasm "$b/sasm" | tail -1 || fail=1
  python3 "$here/emu/jit/fuzz.py" -n "$n" -s 1000 --emu "$tmp/wemu" --sasm "$b/sasm" | tail -1 || fail=1
fi
exit $fail
