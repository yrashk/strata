#!/bin/sh
# The RTL simulator built for the browser (make wasm-rtl: Verilator's C++
# compiled to WebAssembly, the module the play page runs as "Machine: RTL
# simulator") against the native simulator (build/strata-rtl), under node:
# both run the same images with the virtual timer and no window, and must
# print the same console output and the same per-core halt and fault lines
# with the same cycle counts (stdout and stderr, byte for byte), and for the
# image that draws, the same last presented frame (-F).
#
#   tools/test-wasm-rtl.sh [name ...]      (default: a few quick examples and gfx)
#
# The two must have the same number of cores (WEB_RTL_CORES = NCORES).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
if ! command -v node >/dev/null 2>&1; then echo "test-wasm-rtl: node not found; skipped"; exit 0; fi
[ -f "$b/web/strata-rtl.js" ] || { echo "test-wasm-rtl: $b/web/strata-rtl.js missing (make wasm-rtl)"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
[ $# -gt 0 ] || set -- hello faults pipeline race clock mandel gfx
for e in "$@"; do
  img="$b/examples/$e.stx"
  opts="-T virtual -g none -r 320x200"
  node "$here/tools/wasm-run.js" "$b/web/strata-rtl.js" $opts -F "$tmp/w.ppm" "$img" >"$tmp/w.out" 2>"$tmp/w.err0"; wrc=$?
  "$b/strata-rtl" $opts -F "$tmp/n.ppm" "$img" >"$tmp/n.out" 2>"$tmp/n.err0" </dev/null; nrc=$?
  # (the "no frame was presented" note names the -F file)
  grep -v '^no frame was presented' "$tmp/w.err0" >"$tmp/w.err"
  grep -v '^no frame was presented' "$tmp/n.err0" >"$tmp/n.err"
  ok=1
  [ "$wrc" = "$nrc" ] || { echo "  $e: exit status: wasm=$wrc native=$nrc"; ok=0; }
  cmp -s "$tmp/w.out" "$tmp/n.out" || { echo "  $e: console output differs:"; diff "$tmp/w.out" "$tmp/n.out" | head -5; ok=0; }
  cmp -s "$tmp/w.err" "$tmp/n.err" || { echo "  $e: halt/fault lines differ:"; diff "$tmp/w.err" "$tmp/n.err" | head -5; ok=0; }
  frame=""
  if [ -f "$tmp/n.ppm" ] || [ -f "$tmp/w.ppm" ]; then
    cmp -s "$tmp/w.ppm" "$tmp/n.ppm" && frame=", same frame" || { echo "  $e: frames differ"; ok=0; }
  fi
  rm -f "$tmp/w.ppm" "$tmp/n.ppm"
  if [ $ok = 1 ]; then
    printf '%-14s OK   wasm RTL = native RTL (%s cycles%s)\n' "$e" "$(sed -n 's/^total cycles: //p' "$tmp/w.err")" "$frame"
  else
    printf '%-14s FAIL\n' "$e"; fail=1
  fi
done
exit $fail
