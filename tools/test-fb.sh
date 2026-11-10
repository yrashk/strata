#!/bin/sh
# The framebuffer on the emulator and on the Verilated RTL: runs an example
# that draws (gfx) on both without a window (-g none), has each write the
# last presented frame as a PPM (-F), and compares the two frames byte for
# byte. The timer runs in real time here: the picture does not depend on it,
# and the VSYNC waits then cost milliseconds instead of simulated cycles.
#
#   tools/test-fb.sh build/examples/gfx.stx
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$b/strata-emu" -j -c "${NCORES:-8}" -g none -F "$tmp/e.ppm" "$1" >"$tmp/e.out" 2>"$tmp/e.err" </dev/null; ec=$?
"$b/strata-rtl" -g none -F "$tmp/r.ppm" "$1" >"$tmp/r.out" 2>"$tmp/r.err" </dev/null; rc=$?
if [ $ec -eq 0 ] && [ $rc -eq 0 ] && [ -s "$tmp/e.ppm" ] && cmp -s "$tmp/e.ppm" "$tmp/r.ppm"; then
  printf '%-14s OK    %s: the same %s-byte frame on both\n' framebuffer "$(basename "$1" .stx)" \
    "$(wc -c <"$tmp/e.ppm" | tr -d ' ')"
  exit 0
fi
printf '%-14s FAIL  (exit emu=%s rtl=%s)\n' framebuffer $ec $rc
[ -s "$tmp/e.ppm" ] || echo "  the emulator wrote no frame"
[ -s "$tmp/r.ppm" ] || echo "  the RTL wrote no frame"
cmp "$tmp/e.ppm" "$tmp/r.ppm" 2>&1 | head -2 | sed 's/^/  /'
exit 1
