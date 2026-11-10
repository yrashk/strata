#!/bin/sh
# Wall time of the emulator interpreting (-j) and with the JIT (-J) on
# mandel, gfx and the Forth gfx demo. Both use the virtual timer and no
# window, so only emulation speed is measured (time spent waiting for
# VSYNC is skipped, not slept).
#
#   tools/bench-jit.sh            (make bench)
#   RES=1280x800 FORTH_RES=640x400 NCORES=8 tools/bench-jit.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
emu="$b/strata-emu -c ${NCORES:-8} -T virtual -g none"
res=${RES:-1280x800}
fres=${FORTH_RES:-640x400}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# secs REPS MODE ARGS...: the wall time of REPS runs, in seconds per run
secs() {
  reps=$1
  shift
  /usr/bin/time -p sh -c 'n=$1; shift; while [ $n -gt 0 ]; do "$@" || exit 1; n=$((n - 1)); done' \
    sh "$reps" $emu "$@" >/dev/null 2>"$tmp/err" </dev/null
  sed -n 's/^real //p' "$tmp/err" | awk -v r="$reps" '{ printf "%.3f", $1 / r }'
}
# instructions retired by all cores in one run
insns() { $emu "$@" 2>&1 >/dev/null </dev/null | sed -n 's/.*instret=\([0-9]*\).*/\1/p' | awk '{s += $1} END {print s}'; }

printf '%-22s %12s %10s %10s %8s\n' benchmark instructions interp jit speedup
# bench NAME REPS ARGS...
bench() {
  name=$1
  reps=$2
  shift 2
  ti=$(secs "$reps" -j "$@")
  tj=$(secs "$reps" -J "$@")
  n=$(insns -J "$@")
  printf '%-22s %12s %9ss %9ss %7sx\n' "$name" "$n" "$ti" "$tj" \
    "$(awk -v i="$ti" -v j="$tj" 'BEGIN { if (j > 0) printf "%.1f", i / j; else print "-" }')"
}
bench "mandel" 50 "$b/examples/mandel.stx"
bench "gfx ($res)" 5 -r "$res" "$b/examples/gfx.stx"
bench "forth gfx ($fres)" 1 -r "$fres" -i "$here/lang/forth/demos/gfx.fs" "$b/forth.stx"
