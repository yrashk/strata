#!/bin/sh
# The C compiler inside StrataOS: boots the standard disk with a scripted
# console that compiles the C programs of lang/cc/examples with `cc`
# (hi.c, calc.c, asm.c, sort.c, math.c and vla.c, on the disk under /src)
# and runs the results, also in the paged code model (-p), vla.c also with
# the bootstrap compiler (cc0),
# and compares the console output with tools/test-cc.out.
#
#   tools/test-cc.sh build/bootrom.stx build/disk.img     (-u: update the .out)
#
# The emulator runs the interpreter with the virtual timer (-j -T virtual),
# so the session is deterministic. The output is compared from the first
# prompt on.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
  printf 'cc /src/hi.c\n'
  printf 'hi\n'
  printf 'hi there\n'
  printf 'cc -o calc2 /src/calc.c && echo compiled\n'
  printf 'calc2 1 + 2 * (3 - 4) - -5\n'
  printf 'echo 6 * 7 | calc2\n'
  printf 'calc2 10 / (5 - 5); echo status $?\n'
  printf 'calc2 (1 + 2\n'
  printf "echo 'int main(void) { return x; }' > bad.c\n"
  printf 'cc bad.c; echo status $?\n'
  printf 'cc nosuch.c; echo status $?\n'
  printf 'cc -p -o calc3 /src/calc.c && calc3 (7 - 1) * 7\n'
  printf 'cc /src/asm.c && asm\n'
  printf 'cc -p -o asm2 /src/asm.c && asm2\n'
  printf 'cc -o csort /src/sort.c && csort\n'
  printf 'csort pear apple fig\n'
  printf 'cc -p -o csort2 /src/sort.c && csort2 b c a\n'
  printf 'cc -o cmath /src/math.c && cmath\n'
  printf 'cc /src/vla.c && vla\n'
  printf 'cc -p -o vla2 /src/vla.c && vla2\n'
  printf 'cc0 -o vla0 /src/vla.c && vla0\n'
  printf 'rm hi calc2 calc3 bad.c asm asm2 csort csort2 cmath vla vla2 vla0\n'
  printf 'halt\n'
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 2000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>/dev/null
awk 'f || /^strata\$ /{f=1; print}' "$tmp/raw.out" | cat -v >"$tmp/out.txt"
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$here/tools/test-cc.out"; echo "tools/test-cc.out updated"; exit 0; fi
if cmp -s "$tmp/out.txt" "$here/tools/test-cc.out"; then
  printf '%-14s OK    cc compiles and runs its examples inside StrataOS\n' cc; exit 0
fi
printf '%-14s FAIL\n' cc; diff "$here/tools/test-cc.out" "$tmp/out.txt" | head -40; exit 1
