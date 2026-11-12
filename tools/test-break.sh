#!/bin/sh
# Ctrl-C on the emulator and on the Verilated RTL: boots StrataOS, starts
# `spin` (which never ends), presses Ctrl-C partway in (-b), then runs another
# program to show the shell survived and the cores were recovered. The
# console output of both must be the same and must show the interrupt.
#
#   tools/test-break.sh build/bootrom.stx build/disk.img
#
# The tty server waits on the console's break port; Ctrl-C completes that
# read, the tty asks proc to SIGNAL the foreground process (spin: the shell
# gave it the console), and proc has the kernel DESTROY it. The shell's WAIT
# returns "killed", and it takes the console back.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'spin\n-n 2 hello\nhalt\n' >"$tmp/in.txt"
cp "$2" "$tmp/d1.img"; cp "$2" "$tmp/d2.img"
# -b counts emulator steps but RTL cycles: both land while spin runs
"$b/strata-emu" -c "$n" -T virtual -g none -b 4000000 -m 400000000 -d "$tmp/d1.img" -i "$tmp/in.txt" "$1" >"$tmp/e.out" 2>/dev/null
"$b/strata-rtl" -T virtual -g none -b 30000000 -m 200000000 -d "$tmp/d2.img" -i "$tmp/in.txt" "$1" >"$tmp/r.out" 2>/dev/null
# spin's progress dots depend on timing: drop them before comparing (its last
# one may also reach the console just after the ^C echo, before the prompt)
sed -i.bak -E -e 's/^\.*\^C$/^C/' -e 's/^\.+(\[[0-9]+\] )/\1/' "$tmp/e.out" "$tmp/r.out"
if cmp -s "$tmp/e.out" "$tmp/r.out" && grep -q '^\^C$' "$tmp/r.out" &&
   grep -q 'Hello from Strata core 1 of 2' "$tmp/r.out" && grep -q 'all cores halted' "$tmp/r.out"; then
  printf '%-14s OK    spin stopped by Ctrl-C, the shell carried on\n' ctrl-c; exit 0
fi
printf '%-14s FAIL\n' ctrl-c; diff "$tmp/e.out" "$tmp/r.out" | head; exit 1
