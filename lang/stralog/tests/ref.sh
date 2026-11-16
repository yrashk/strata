#!/bin/sh
# The examples of the website's Stralog reference (doc/manual/web/stralog-ref.txt)
# under StrataOS: genstralog.py --session makes them one session and what
# Stralog must print for it; this runs the session as run.sh runs one and
# compares.
#
#   lang/stralog/tests/ref.sh build/bootrom.stx build/disk.img
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 "$here/doc/manual/gen/genstralog.py" --session "$tmp" || exit 1
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$tmp/d.img" -i "$tmp/ref.txt" "$1" >"$tmp/raw.out" 2>/dev/null
awk 'f || /^strata\$ .*stralog/{f=1; print}' "$tmp/raw.out" | cat -v >"$tmp/out.txt"
if cmp -s "$tmp/out.txt" "$tmp/ref.out"; then
  printf '%-14s OK    Stralog: the reference examples\n' "stralog-ref"; exit 0
fi
printf '%-14s FAIL\n' "stralog-ref"; diff "$tmp/ref.out" "$tmp/out.txt" | head -40; exit 1
