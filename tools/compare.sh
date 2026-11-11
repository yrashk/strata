#!/bin/sh
# Runs each .stx image on the C emulator and on the Verilated RTL, then
# compares what must agree:
#   * console output, minus lines starting with '@' (timing-dependent by convention)
#   * per-core halt/fault lines, minus the RTL-only cycle and stall counts
#   * per-core instruction traces (pc, instruction word, in order)
#
# Both run with the virtual timer (-T virtual: NOW counts machine rounds or
# clock cycles, not host time, so a program's timer-driven control flow does
# not depend on how fast the host is) and without a window (-g none).
#
# Programs must avoid timing-visible behaviour for this to hold: the cycle
# and stalls CSRs, tpoll, CCR.PTRAP, any-sender ctake/cpoll where several
# nodes may give to one core at once, and unserialised output from several
# cores to one device (see emu/emu.c).
#
#   tools/compare.sh build/examples/*.stx
#
# EMU_ARGS: extra emulator flags matching the RTL build (e.g. -X 8 for NXMAP=8).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
ncores=${NCORES:-8}
emu="$here/${BUILD:-build}/strata-emu -j -c $ncores ${EMU_ARGS:-} -T virtual -g none -r 640x480"
rtl="$here/${BUILD:-build}/strata-rtl -T virtual -g none -r 640x480"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

for img in "$@"; do
  name=$(basename "$img" .stx)
  [ -f "$img" ] || { printf '%-14s FAIL  (no image)\n' "$name"; fail=1; continue; }
  $emu -t "$tmp/emu.trace" "$img" >"$tmp/emu.out" 2>"$tmp/emu.err" </dev/null; ec=$?
  $rtl -t "$tmp/rtl.trace" "$img" >"$tmp/rtl.out" 2>"$tmp/rtl.err" </dev/null; rc=$?
  ok=1
  [ $ec -eq $rc ] || { echo "  exit status: emu=$ec rtl=$rc"; ok=0; }
  if grep -qE '^(timeout|deadlock)' "$tmp/emu.err" "$tmp/rtl.err"; then
    grep -hE '^(timeout|deadlock)' "$tmp/emu.err" "$tmp/rtl.err" | sed 's/^/  /'; ok=0
  fi
  grep -v '^@' "$tmp/emu.out" >"$tmp/emu.o"; grep -v '^@' "$tmp/rtl.out" >"$tmp/rtl.o"
  cmp -s "$tmp/emu.o" "$tmp/rtl.o" || { echo "  console output differs:"; diff "$tmp/emu.o" "$tmp/rtl.o" | head -10; ok=0; }
  grep '^core' "$tmp/emu.err" | sort >"$tmp/emu.h"
  grep '^core' "$tmp/rtl.err" | sed -e 's/ cycles=[0-9]*//' -e 's/ stalls=[0-9]*//' | sort >"$tmp/rtl.h"
  cmp -s "$tmp/emu.h" "$tmp/rtl.h" || { echo "  halt state differs:"; diff "$tmp/emu.h" "$tmp/rtl.h"; ok=0; }
  c=0
  while [ $c -lt "$ncores" ]; do
    grep "^$c " "$tmp/emu.trace" >"$tmp/e.$c"; grep "^$c " "$tmp/rtl.trace" >"$tmp/r.$c"
    cmp -s "$tmp/e.$c" "$tmp/r.$c" || { echo "  core $c trace differs (first difference):"; diff "$tmp/e.$c" "$tmp/r.$c" | head -4; ok=0; }
    c=$((c + 1))
  done
  ninsn=$(wc -l <"$tmp/emu.trace" | tr -d ' ')
  cycles=$(sed -n 's/^total cycles: //p' "$tmp/rtl.err")
  if [ $ok -eq 1 ]; then
    printf '%-14s OK    %8s instructions  %9s RTL cycles\n' "$name" "$ninsn" "$cycles"
  else
    printf '%-14s FAIL\n' "$name"; fail=1
  fi
done
exit $fail
