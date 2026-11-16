#!/bin/sh
# Far loads and stores (tgeom.FA) under StrataOS: tools/fardata.s writes
# 256 KiB of its arena through a 4 KiB data cache and reads it back; every
# miss is served by the dispatcher (os/kernel.s, xdmiss), which writes dirty
# victims back. Then `fardata bad` must end with a dmiss fault (a line
# outside the arena is not served), and two copies pinned to one core must
# both get their data right while they switch between misses. On the
# emulator with the virtual timer; RTL=1 runs it on the Verilated RTL too.
#
#   tools/test-far.sh build/bootrom.stx build/far-test/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'fardata\nfardata bad\n-c 6 fardata &\n-c 6 fardata\nwait\nhalt\n' >"$tmp/in.txt"
SUM='fardata: 32768 words, 2048 bytes, sum 0000000000000000000000b05b0cca682e4a80'
check() { # $1 = which machine, $2 = its output
  tr -d '\r' <"$2" >"$2.t"
  good=$(grep -a -c "^$SUM\$\|$SUM\$" "$2.t")
  bad=$(grep -a -c 'fault 15' "$2.t")
  if [ "$good" = 3 ] && [ "$bad" = 1 ]; then
    printf '%-14s OK    256 KiB through a 4 KiB far cache, three times (two on one core); a line outside the arena refused (%s)\n' far "$1"
    return 0
  fi
  printf '%-14s FAIL  (%s)\n' far "$1"
  grep -a 'fardata\|fault' "$2.t" | head -12 | sed 's/^/    /'
  return 1
}
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -T virtual -g none -m 4000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/out" 2>/dev/null
check emulator "$tmp/out" || exit 1
if [ "${RTL:-0}" = 1 ]; then
  cp "$2" "$tmp/r.img"
  "$b/strata-rtl" -T virtual -g none -m 8000000000 -d "$tmp/r.img" -i "$tmp/in.txt" "$1" >"$tmp/rout" 2>/dev/null
  check RTL "$tmp/rout" || exit 1
fi
exit 0
