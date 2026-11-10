#!/bin/sh
# Runs the Forth regression test (tests/test.fs) on the emulator and on the
# RTL simulator and compares both console outputs with tests/test.out.
#   BUILD=build NCORES=8 lang/forth/tests/run.sh [image]
# With UPDATE=1 it rewrites tests/test.out from the emulator's output.
set -e
BUILD=${BUILD:-build}
NCORES=${NCORES:-8}
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${1:-$BUILD/forth.stx}
OUT=$BUILD/forth-test
mkdir -p "$OUT"
# the banner's free-space figures change with every edit of core.fs: mask them
norm() { sed '1s/[0-9][0-9]* code bytes free, [0-9][0-9]* data bytes free/N code bytes free, N data bytes free/' "$1" > "$1.n" && mv "$1.n" "$1"; }
"$BUILD/strata-emu" -c "$NCORES" -T virtual -g none -m 400000000 -i "$HERE/test.fs" "$IMG" \
  > "$OUT/emu.out" 2> "$OUT/emu.err" || { echo "test-forth: emulator failed"; cat "$OUT/emu.err"; exit 1; }
norm "$OUT/emu.out"
if [ "$UPDATE" = 1 ]; then cp "$OUT/emu.out" "$HERE/test.out"; echo "test-forth: test.out updated"; fi
"$BUILD/strata-rtl" -T virtual -g none -i "$HERE/test.fs" "$IMG" \
  > "$OUT/rtl.out" 2> "$OUT/rtl.err" || { echo "test-forth: RTL failed"; cat "$OUT/rtl.err"; exit 1; }
norm "$OUT/rtl.out"
ok=1
cmp -s "$OUT/emu.out" "$HERE/test.out" || { echo "test-forth: emulator output differs from test.out:"; diff "$HERE/test.out" "$OUT/emu.out" | head -20; ok=0; }
cmp -s "$OUT/rtl.out" "$HERE/test.out" || { echo "test-forth: RTL output differs from test.out:"; diff "$HERE/test.out" "$OUT/rtl.out" | head -20; ok=0; }
[ $ok = 1 ] || exit 1
echo "test-forth: emulator and RTL ($NCORES cores) match tests/test.out ($(wc -l < "$HERE/test.out" | tr -d ' ') lines)"
