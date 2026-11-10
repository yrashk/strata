#!/bin/sh
# The scripted StrataOS session on the emulator with its JIT and the real-time
# timer (-J -T real): coarse core interleaving (thousands of steps per core
# turn) and preemption at host-time ticks give event orders the lock-step,
# virtual-time runs of compare-boot.sh never see. Runs the demo a few times
# and checks that each run ends with halt, without a fault, and with the
# programs' results present.
#
#   tools/test-boot-jit.sh build/bootrom.stx build/disk.img os/demo.txt
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="${BUILD:-build}"; case "$b" in /*) ;; *) b="$here/$b" ;; esac
n=${NCORES:-8}
runs=${RUNS:-3}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
i=1
while [ $i -le "$runs" ]; do
  cp "$2" "$tmp/d.img"
  "$b/strata-emu" -c "$n" -J -T real -g none -m 4000000000 -d "$tmp/d.img" -i "$3" "$1" >"$tmp/out" 2>&1
  rc=$?   # 0 only if every core halted (a pending device read at halt is a deadlock: 1)
  if [ $rc -ne 0 ] || ! grep -q 'StrataOS: all cores halted' "$tmp/out" || grep -q 'kernel fault\|cannot start\|\[fault' "$tmp/out" ||
     ! grep -q 'Hello from Strata core 1 of 2' "$tmp/out" || ! grep -q 'check: ok' "$tmp/out"; then
    printf '%-14s FAIL  (run %s)\n' boot-jit $i; tail -15 "$tmp/out" | sed 's/^/    /'; exit 1
  fi
  i=$((i + 1))
done
printf '%-14s OK    %s demo runs with the JIT and the real-time timer\n' boot-jit "$runs"
