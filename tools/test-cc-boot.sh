#!/bin/sh
# The C compiler's bootstrap inside StrataOS (lang/cc/DESIGN.md, section 6).
# cc0, the bootstrap compiler in assembly, compiles cc.c; the result (cc1)
# compiles cc.c again (c2), and that one once more (c3). c2 and c3 must be
# the same files: the compiler reproduces itself. They must also be the cc
# of the disk, which the Makefile makes with cc.c built for the host
# (build/strata-cc): the cross compiler and the native one agree byte for
# byte. The files are compared with lang/cc/examples/cmp.c, compiled by cc.
#
#   tools/test-cc-boot.sh build/bootrom.stx build/disk.img     (-u: update the .out)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
  printf 'cc0 -p -h 0 -o cc1 /src/cc.c; echo status $?\n'
  printf 'cc1 -p -h 0 -o c2 /src/cc.c; echo status $?\n'
  printf 'c2 -p -h 0 -o c3 /src/cc.c; echo status $?\n'
  printf 'cc -o cmp /src/cmp.c\n'
  printf 'cmp c2 c3\n'
  printf 'cmp c2.u c3.u\n'
  printf 'cmp c2 /bin/cc\n'
  printf 'cmp c2.u /bin/cc.u\n'
  printf 'halt\n'
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>/dev/null
awk 'f || /^strata\$ /{f=1; print}' "$tmp/raw.out" | cat -v >"$tmp/out.txt"
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$here/tools/test-cc-boot.out"; echo "tools/test-cc-boot.out updated"; exit 0; fi
if cmp -s "$tmp/out.txt" "$here/tools/test-cc-boot.out"; then
  printf '%-14s OK    cc0 compiles cc.c, which then reproduces itself and the cross-built cc\n' cc-boot; exit 0
fi
printf '%-14s FAIL\n' cc-boot; diff "$here/tools/test-cc-boot.out" "$tmp/out.txt" | head -40; exit 1
