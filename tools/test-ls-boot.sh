#!/bin/sh
# StrataOS on a machine whose Local Stores are smaller than 64 KiB: the boot
# ROM refuses an OS image that does not fit them, and the kernel refuses a
# machine its layout does not fit; either one says so and every core halts
# (none waits for core 0 for good).
#
#   tools/test-ls-boot.sh build/bootrom.stx build/disk.img
#
# EMU_ARGS: the emulator's -L for the machine the RTL in $BUILD was built as;
# the two must print the same console output. RTL=none runs the emulator
# alone (a size no RTL here was built with).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$2" "$tmp/d1.img"
cp "$2" "$tmp/d2.img"
"$b/strata-emu" -j -c "$n" ${EMU_ARGS:-} -T virtual -g none -m 100000000 -d "$tmp/d1.img" -i /dev/null "$1" >"$tmp/e.out" 2>"$tmp/e.err"
ok=1
grep -q "does not fit this machine's Local Stores\|needs Local Stores of 64 KiB" "$tmp/e.out" || { echo "  no refusal:"; tail -3 "$tmp/e.out" | sed 's/^/    /'; ok=0; }
grep -q 'deadlock\|timeout\|fault' "$tmp/e.err" && { echo "  the emulator did not halt every core:"; tail -2 "$tmp/e.err" | sed 's/^/    /'; ok=0; }
grep -q '^core 0: halt a0=1' "$tmp/e.err" || { echo "  core 0 did not halt with 1"; ok=0; }
if [ "${RTL:-}" != none ]; then
  "$b/strata-rtl" -T virtual -g none -m 100000000 -d "$tmp/d2.img" -i /dev/null "$1" >"$tmp/r.out" 2>"$tmp/r.err"
  cmp -s "$tmp/e.out" "$tmp/r.out" || { echo "  console output differs:"; diff "$tmp/e.out" "$tmp/r.out" | head; ok=0; }
  grep -q 'timeout' "$tmp/r.err" && { echo "  the RTL did not halt every core"; ok=0; }
fi
msg=$(grep -m1 "does not fit this machine\|needs Local Stores of 64 KiB" "$tmp/e.out" || true)
if [ $ok -eq 1 ]; then printf '%-14s OK    %s %s\n' "ls-boot" "${EMU_ARGS:-}" "($msg)"; exit 0; fi
printf '%-14s FAIL  %s\n' "ls-boot" "${EMU_ARGS:-}"; exit 1
