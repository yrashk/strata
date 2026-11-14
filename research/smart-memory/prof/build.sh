#!/bin/sh
# Builds the RTL simulator with the cycle profiler (ls_prof.sv) bound into
# every core: research/smart-memory/build/strata-rtl-prof. The same machine
# as `make` builds (build/strata-rtl); rtl/ and sim/ are used as they are.
#
#   research/smart-memory/prof/build.sh [NCORES [DLS_KIB [ILS_KIB [STREAM [LS_1P]]]]]
#
# STREAM = 1: the cores' stream fetch (the binary is strata-rtl-prof-stream);
# LS_1P = 1: one single-port memory for both stores (...-1p).
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$here"
n=${1:-8}
dk=${2:-64}
ik=${3:-$dk}
out=research/smart-memory/build
sfx=
st=${4:-0}
[ "$dk$ik" = 6464 ] || sfx="-l$dk-$ik"
[ "$st" = 0 ] || sfx="$sfx-stream"
sp=${5:-0}
[ "$sp" = 0 ] || sfx="$sfx-1p"
sdlc=$(pkg-config --cflags sdl2 2>/dev/null || echo -DNO_SDL)
sdll=$(pkg-config --libs sdl2 2>/dev/null || true)
rtl="rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv rtl/strata_mul.sv
     rtl/strata_ram.sv rtl/strata_ram1.sv rtl/strata_uart.sv rtl/strata_tu.sv rtl/strata_bus.sv
     rtl/strata_mem.sv rtl/strata_dev.sv rtl/strata_core.sv rtl/strata_top.sv"
mkdir -p $out
# shellcheck disable=SC2086
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-DECLFILENAME \
  -DSIMULATION -GNCORES=$n -GNXMAP=16 -GDLS_KIB=$dk -GILS_KIB=$ik -GSTREAM=$st -GLS_1P=$sp --top-module strata_top \
  -Mdir $out/obj_dir$sfx -o strata-rtl-prof \
  -CFLAGS "-O2 -std=c++17 -DNCORES=$n -DNXMAP=16 -DDLS_KIB=$dk -DILS_KIB=$ik $sdlc" \
  -LDFLAGS "$sdll" $rtl research/smart-memory/prof/ls_prof.sv sim/main.cpp > $out/build$sfx.log 2>&1 \
  || { grep -B2 -A12 '%Error\|%Warning' $out/build$sfx.log | head -80; exit 1; }
cp $out/obj_dir$sfx/strata-rtl-prof $out/strata-rtl-prof$sfx
echo "$out/strata-rtl-prof$sfx"
