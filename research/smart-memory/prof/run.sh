#!/bin/sh
# Runs the examples and the scripted StrataOS session on the profiling
# simulator (prof/build.sh) and leaves each run's console output with the
# profiler's "PROF" lines in research/smart-memory/build/runs/NAME.out.
# Needs `make all examples os` first. Each run's console output without
# the PROF lines is compared with the plain simulator's (examples only:
# the profiler must not change the machine).
#
#   research/smart-memory/prof/run.sh [examples|boot|all]
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$here"
p=research/smart-memory/build
what=${1:-all}
mkdir -p $p/runs
if [ "$what" != boot ]; then
  for e in hello mandel pipeline swcache overlay parsum stream_sum race gfx; do
    build/strata-rtl -g none -T virtual build/examples/$e.stx > $p/runs/$e.ref 2> /dev/null
    $p/strata-rtl-prof -g none -T virtual build/examples/$e.stx > $p/runs/$e.out 2> $p/runs/$e.err
    rc=$?
    if grep -v '^PROF' $p/runs/$e.out | cmp -s - $p/runs/$e.ref; then same=same; else same=DIFFERENT; fi
    echo "$e: exit $rc, output $same as build/strata-rtl"
  done
fi
if [ "$what" != examples ]; then
  cp build/disk.img $p/runs/disk-run.img
  $p/strata-rtl-prof -g none -T virtual -d $p/runs/disk-run.img -i os/demo.txt build/bootrom.stx \
    > $p/runs/boot.out 2> $p/runs/boot.err
  echo "boot: exit $?"
  rm -f $p/runs/disk-run.img
fi
