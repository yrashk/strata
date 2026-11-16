#!/bin/sh
# lang/stratalk/tests/examples.sh [-h]: every example of lang/stratalk/examples
# that has a NAME.out is run as `stratalk /stratalk/examples/NAME.st` under
# StrataOS on the emulator (-h: on the host's reference interpreter), and
# what it prints must be NAME.out (memory.st has none: its figures are the
# machine's).
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
b="$here/${BUILD:-build}"
ex="$here/lang/stratalk/examples"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
names=$(cd "$ex" && ls *.out | sed 's/\.out$//')
if [ "${1:-}" = "-h" ]; then
  for n in $names; do
    python3 "$here/lang/stratalk/host/stratalk.py" run "$b/stratalk/stratalk.image" "$ex/$n.st" > "$tmp/$n.out" 2>&1
    if cmp -s "$ex/$n.out" "$tmp/$n.out"; then echo "stratalk-host example $n ok"
    else echo "stratalk-host example $n FAIL"; diff "$ex/$n.out" "$tmp/$n.out" | head -10; fails=1; fi
  done
  exit $fails
fi
for n in $names; do
  printf 'stratalk /stratalk/examples/%s.st\necho ==end %s==\n' "$n" "$n" >> "$tmp/in.txt"
done
printf 'halt\n' >> "$tmp/in.txt"
cp "$b/disk.img" "$tmp/d.img"
"$b/strata-emu" -c "${NCORES:-8}" -j -T virtual -g none -m 20000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$b/bootrom.stx" > "$tmp/raw.out" 2>&1
for n in $names; do
  python3 - "$tmp/raw.out" "$n" > "$tmp/$n.out" <<'PY'
import sys
raw = open(sys.argv[1], 'rb').read().decode('latin1').replace('\r', '')
n = sys.argv[2]
cmd = 'strata$ stratalk /stratalk/examples/%s.st\n' % n
a = raw.index(cmd) + len(cmd)
e = raw.index('strata$ echo ==end %s==' % n, a)
sys.stdout.write(raw[a:e])
PY
  if cmp -s "$ex/$n.out" "$tmp/$n.out"; then echo "stratalk example $n ok"
  else echo "stratalk example $n FAIL"; diff "$ex/$n.out" "$tmp/$n.out" | head -10; fails=1; fi
done
grep -q 'all cores halted' "$tmp/raw.out" || { echo "stratalk: the machine did not halt"; fails=1; }
exit $fails
