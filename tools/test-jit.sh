#!/bin/sh
# The JIT against the interpreter: runs every example image, and the Forth
# regression input, on the emulator twice, with the JIT (-J) and
# interpreting only (-j), and requires:
#   * the same console output, minus lines starting with '@' (timing)
#   * the same exit status and the same halt/fault line per core (a0 and
#     the cause; instret is reported when it differs, but spin loops make
#     it timing-dependent, so it is not compared)
#   * for images that draw, the same last presented frame (-F)
# Both runs use the virtual timer and no window. With the JIT a core runs
# thousands of instructions per turn instead of one, so this only holds
# for programs whose results do not depend on timing (see emu/emu.c).
#
#   tools/test-jit.sh [image.stx ...]      (default: build/examples/*.stx)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
ncores=${NCORES:-8}
emu="$b/strata-emu -c $ncores -T virtual -g none -r 640x480"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
[ $# -gt 0 ] || set -- "$b"/examples/*.stx

# run NAME ARGS...: both modes, then compare
run() {
  name=$1
  shift
  $emu -j -F "$tmp/i.ppm" "$@" >"$tmp/i.out" 2>"$tmp/i.err" </dev/null; ic=$?
  $emu -J -F "$tmp/j.ppm" "$@" >"$tmp/j.out" 2>"$tmp/j.err" </dev/null; jc=$?
  ok=1
  [ $ic -eq $jc ] || { echo "  exit status: interpreter=$ic jit=$jc"; ok=0; }
  grep -v '^@' "$tmp/i.out" >"$tmp/i.o"; grep -v '^@' "$tmp/j.out" >"$tmp/j.o"
  cmp -s "$tmp/i.o" "$tmp/j.o" || { echo "  console output differs:"; diff "$tmp/i.o" "$tmp/j.o" | head -10; ok=0; }
  grep '^core' "$tmp/i.err" | sed 's/ instret=[0-9]*//' | sort >"$tmp/i.h"
  grep '^core' "$tmp/j.err" | sed 's/ instret=[0-9]*//' | sort >"$tmp/j.h"
  cmp -s "$tmp/i.h" "$tmp/j.h" || { echo "  halt state differs:"; diff "$tmp/i.h" "$tmp/j.h"; ok=0; }
  if grep -qE '^(timeout|deadlock)' "$tmp/i.err" "$tmp/j.err"; then
    grep -hE '^(timeout|deadlock)' "$tmp/i.err" "$tmp/j.err" | sed 's/^/  /'; ok=0
  fi
  frame=""
  if [ -s "$tmp/i.ppm" ] || [ -s "$tmp/j.ppm" ]; then
    if cmp -s "$tmp/i.ppm" "$tmp/j.ppm"; then frame="  same frame"
    else echo "  the presented frames differ"; ok=0; fi
  fi
  same=""
  grep '^core' "$tmp/i.err" | sort >"$tmp/i.f"; grep '^core' "$tmp/j.err" | sort >"$tmp/j.f"
  cmp -s "$tmp/i.f" "$tmp/j.f" || same="  (instret differs: timing-dependent)"
  rm -f "$tmp/i.ppm" "$tmp/j.ppm"
  if [ $ok -eq 1 ]; then printf '%-14s OK%s%s\n' "$name" "$frame" "$same"
  else printf '%-14s FAIL\n' "$name"; fail=1; fi
}

for img in "$@"; do
  [ -f "$img" ] || { printf '%-14s FAIL  (no image)\n' "$(basename "$img" .stx)"; fail=1; continue; }
  run "$(basename "$img" .stx)" "$img"
done

# the Forth regression input (lang/forth/tests/test.fs), when Forth is built
if [ -f "$b/forth.stx" ]; then
  run forth-test -m 400000000 -i "$here/lang/forth/tests/test.fs" "$b/forth.stx"
fi
exit $fail
