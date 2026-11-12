#!/bin/sh
# Isolation of the Local Store between processes: what one process leaves in
# its core's D-LS (above its data extent, below its stack, in a scratch range:
# the parts a context switch does not save) must never be visible to the next
# process on that core. tools/dlsgap.s fills those parts with a pattern and
# sleeps, over and over, pinned to core 6; a second copy pinned to the same
# core scans its own gaps for the pattern at its first load and after each of
# 8 switches back from the filler. Runs on the emulator with the virtual timer;
# RTL=1 runs it on the Verilated RTL as well.
#
#   tools/test-isolate.sh build/bootrom.stx build/isol-test/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf -- '-c 6 dlsgap fill &\n-c 6 dlsgap scan 8\nps\nkill %%1\nwait\nhalt\n' >"$tmp/in.txt"
check() { # $1 = which machine, $2 = its output
  # the scanner's verdict, and the filler's switches (ps: pid ppid state core cpus switches KiB name)
  ok=$(grep -c '^dlsgap: 9 looks, clean$' "$2")
  sw=$(awk '$4 == 6 && $8 == "dlsgap" && $6 >= 8 { k++ } END { print k + 0 }' "$2")
  if [ "$ok" = 1 ] && [ "$sw" -ge 1 ]; then
    printf '%-14s OK    nothing of the filler in the scanner'"'"'s D-LS gaps, 8 switches (%s)\n' isolate "$1"
    return 0
  fi
  printf '%-14s FAIL  (%s)\n' isolate "$1"
  grep -A12 'dlsgap scan' "$2" | head -16 | sed 's/^/    /'
  return 1
}
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -T virtual -g none -m 1000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/out" 2>/dev/null
check emulator "$tmp/out" || exit 1
if [ "${RTL:-0}" = 1 ]; then
  cp "$2" "$tmp/r.img"
  "$b/strata-rtl" -T virtual -g none -m 4000000000 -d "$tmp/r.img" -i "$tmp/in.txt" "$1" >"$tmp/rout" 2>/dev/null
  check RTL "$tmp/rout" || exit 1
fi
exit 0
