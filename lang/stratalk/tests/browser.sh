#!/bin/sh
# lang/stratalk/tests/browser.sh: the class browser in a window of ws, driven
# by keys. The arrows held through the whole class list, both ways, and
# through a class's selectors: keys typed quickly come several to an event,
# and an escape sequence cut between two events once ended the browser.
# Then the typeahead: "seqx" (no match), Backspace ("seq": the class
# SequenceableCollection), Esc (the filter cleared, the class still
# selected, the list whole); in the selectors "zzz", Ctrl-U, "do:" (the
# selector do:); Esc in the classes, with no filter, closes the browser.
# The REPL that opened it prints what was selected.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
b="$here/${BUILD:-build}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
W='\033[27;3;87~'                       # Alt+Shift+W: ws waits a second
AQ='\033[27;3;81~'                      # Alt+Shift+Q: ws stops
D='\033[B' U='\033[A'
keys() {                                # keys KEY N: N times, a wait after every 20
  i=0
  while [ $i -lt $2 ]; do printf "$1"; i=$((i + 1)); [ $((i % 20)) = 0 ] && printf "$W"; done
  printf "$W$W"
}
typed() {                               # typed TEXT: a key at a time
  t=$1
  while [ -n "$t" ]; do printf '%s' "${t%"${t#?}"}"; printf "$W"; t=${t#?}; done
}
{
  printf "ws\n$W$W$W${W} stratalk > out.txt\n$W$W$W$W"
  printf '[:b | Array with: b classList selected with: b classList filter with: b classList items size = Smalltalk allClasses size with: b selectorList selected] value: ClassBrowser open\r'
  printf "$W$W$W$W$W"
  keys "$D" 150; keys "$U" 150
  printf "\t$W"; keys "$D" 60; keys "$U" 60
  printf "\t\t$W"
  typed seqx; printf "\177$W\033$W$W"
  printf "\t$W"; typed zzz; printf "\025$W"; typed 'do:'
  printf "\t\t$W\033$W$W$W"
  printf "Smalltalk quit\r$W$W$W${AQ}"
  printf 'cat out.txt\n'
  printf 'halt\n'
} > "$tmp/in.txt"
cp "$b/disk.img" "$tmp/d.img"
"$b/strata-emu" -c 12 -g none -m 120000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$b/bootrom.stx" > "$tmp/raw.out" 2>&1
fail() { echo "stratalk-browser: FAILED: $1"; tail -25 "$tmp/raw.out"; exit 1; }
grep -q 'all cores halted' "$tmp/raw.out" || fail "the machine did not halt"
grep -q '^ws: stopped' "$tmp/raw.out" || fail "ws did not stop"
python3 - "$tmp/raw.out" <<'PY' || fail "what the REPL printed is not what it should be"
import sys
raw = open(sys.argv[1], 'rb').read().decode('latin1').replace('\r', '')
a = raw.index('strata$ cat out.txt\n') + len('strata$ cat out.txt\n')
out = raw[a:raw.index('strata$', a)]
if "#('SequenceableCollection' '' true 'do:')" not in out:
    print('out.txt:\n' + out); sys.exit(1)
PY
echo "stratalk-browser: ok    the arrows through the lists; the typeahead"
