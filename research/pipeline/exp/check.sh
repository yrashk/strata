#!/bin/sh
# Builds the RTL simulator with research/pipeline/exp/par_overlay.py's core
# (research/pipeline/build/exp/strata-rtl-par) and checks that it runs every
# example and the scripted StrataOS session cycle for cycle like
# build/strata-rtl: the same console output and the same instruction trace
# (its checksum, for the session). Needs `make all examples os` first.
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$here"
out=research/pipeline/build/exp
mkdir -p $out
python3 research/pipeline/exp/par_overlay.py rtl/strata_core.sv $out/strata_core_par.sv
rtl="rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv rtl/strata_mul.sv
     rtl/strata_ram.sv rtl/strata_uart.sv rtl/strata_tu.sv rtl/strata_bus.sv
     rtl/strata_mem.sv rtl/strata_dev.sv $out/strata_core_par.sv rtl/strata_top.sv"
sdlc=$(pkg-config --cflags sdl2 2>/dev/null || echo -DNO_SDL)
sdll=$(pkg-config --libs sdl2 2>/dev/null || true)
# shellcheck disable=SC2086
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-DECLFILENAME \
  -DSIMULATION -GNCORES=8 -GNXMAP=16 -GDLS_KIB=64 -GILS_KIB=64 --top-module strata_top \
  -Mdir $out/obj_dir -o strata-rtl-par \
  -CFLAGS "-O2 -std=c++17 -DNCORES=8 -DNXMAP=16 -DDLS_KIB=64 -DILS_KIB=64 $sdlc" \
  -LDFLAGS "$sdll" $rtl sim/main.cpp > $out/build.log 2>&1 || { tail -30 $out/build.log; exit 1; }
cp $out/obj_dir/strata-rtl-par $out/strata-rtl-par
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
for e in hello mandel pipeline swcache overlay parsum stream_sum race faults clock; do
  [ -f build/examples/$e.stx ] || continue
  build/strata-rtl -g none -T virtual -t $t/a.tr build/examples/$e.stx > $t/a.out 2>&1 || true
  $out/strata-rtl-par -g none -T virtual -t $t/b.tr build/examples/$e.stx > $t/b.out 2>&1 || true
  if cmp -s $t/a.out $t/b.out && cmp -s $t/a.tr $t/b.tr; then echo "$e: same"; else echo "$e: DIFFERENT"; fi
done
for b in build/strata-rtl $out/strata-rtl-par; do
  cp build/disk.img $t/disk.img
  mkfifo $t/tr
  md5 -q $t/tr > $t/sum &
  $b -g none -T virtual -d $t/disk.img -i os/demo.txt -t $t/tr build/bootrom.stx > $t/os.out 2>&1
  wait
  echo "$b: session trace $(cat $t/sum), console $(md5 -q $t/os.out)"
  rm -f $t/tr
done
