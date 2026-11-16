#!/bin/sh
# Stralog under StrataOS: boots the standard disk with a scripted console
# that runs a session (lang/stralog/tests/NAME.txt) and compares the console
# from the first `stralog` on with NAME.out.
#
#   lang/stralog/tests/run.sh [-u] NAME build/bootrom.stx build/disk.img
#
# -u writes NAME.out instead. The emulator interprets with the virtual timer
# (-j -T virtual): the session is deterministic.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
name=$1
t="$here/lang/stralog/tests"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$3" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$tmp/d.img" -i "$t/$name.txt" "$2" >"$tmp/raw.out" 2>/dev/null
awk 'f || /^strata\$ .*stralog/{f=1; print}' "$tmp/raw.out" | cat -v >"$tmp/out.txt"
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$t/$name.out"; echo "lang/stralog/tests/$name.out updated"; exit 0; fi
if cmp -s "$tmp/out.txt" "$t/$name.out"; then
  printf '%-14s OK    Stralog: %s\n' "stralog-$name" "$name"; exit 0
fi
printf '%-14s FAIL\n' "stralog-$name"; diff "$t/$name.out" "$tmp/out.txt" | head -40; exit 1
