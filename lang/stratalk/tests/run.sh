#!/bin/sh
# lang/stratalk/tests/run.sh [-h] [NAME...]: the test vectors of
# lang/stratalk/tests: each NAME.st is typed into `stratalk -`, one
# expression a line, and what it prints must be NAME.out.
#   -h   on the host's reference interpreter (lang/stratalk/host) instead of
#        StrataOS on the emulator (vm.st and os.st are the VM's alone)
#   -j   with the JIT on (stratalk -j -): what gets hot runs as native code
#   TESTS=DIR  the vectors are DIR/NAME.st and DIR/NAME.out (doc.sh)
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
b="$here/${BUILD:-build}"
t="${TESTS:-$here/lang/stratalk/tests}"
host=0
jit=
if [ "${1:-}" = "-h" ]; then host=1; shift; fi
if [ "${1:-}" = "-j" ]; then jit='-j '; shift; fi
names=${*:-"arith blocks exceptions collections gc compiler ui browse vm os"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
if [ $host = 1 ]; then
  for n in $names; do
    case $n in vm|os) continue ;; esac
    python3 "$here/lang/stratalk/host/stratalk.py" run "$b/stratalk/stratalk.image" - < "$t/$n.st" > "$tmp/$n.out" 2>&1
    if cmp -s "$t/$n.out" "$tmp/$n.out"; then echo "stratalk-host $n ok"
    else echo "stratalk-host $n FAIL"; diff "$t/$n.out" "$tmp/$n.out" | head -20; fails=1; fi
  done
  exit $fails
fi
# StrataOS: one session; each file is typed in after `stratalk -`, then ^D
for n in $names; do
  printf 'stratalk %s-\n' "$jit" >> "$tmp/in.txt"
  cat "$t/$n.st" >> "$tmp/in.txt"
  printf '\004echo ==end %s==\n' "$n" >> "$tmp/in.txt"
done
printf 'halt\n' >> "$tmp/in.txt"
cp "$b/disk.img" "$tmp/d.img"
"$b/strata-emu" -c "${NCORES:-8}" -j -T virtual -g none -m 40000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$b/bootrom.stx" > "$tmp/raw.out" 2>&1
for n in $names; do
  # what the VM printed: after the echo of the last line typed, up to the marker
  python3 - "$tmp/raw.out" "$t/$n.st" "$n" > "$tmp/$n.out" <<'PY'
import sys
raw = open(sys.argv[1], 'rb').read().decode('latin1').replace('\r', '')
src = open(sys.argv[2]).read().splitlines()
name = sys.argv[3]
end = raw.index('==end %s==' % name)
import re
start = [m.end() for m in re.finditer(r'strata\$ stratalk (-j )?-\n', raw[:end])][-1]
lines = raw[start:end].split('\n')
# the console echoes each typed line; what is left is the output
out = []
i = 0
for l in lines:
    if i < len(src) and l == src[i]:
        i += 1; continue
    if l.startswith('strata$ echo') or l.startswith('==end') or l == '': continue
    out.append(l)
print('\n'.join(out))
PY
  if cmp -s "$t/$n.out" "$tmp/$n.out"; then echo "stratalk $jit$n ok"
  else echo "stratalk $jit$n FAIL"; diff "$t/$n.out" "$tmp/$n.out" | head -20; fails=1; fi
done
grep -q 'all cores halted' "$tmp/raw.out" || { echo "stratalk: the machine did not halt"; tail -5 "$tmp/raw.out"; fails=1; }
exit $fails
