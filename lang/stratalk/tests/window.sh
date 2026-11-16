#!/bin/sh
# lang/stratalk/tests/window.sh: a Window opened from Stratalk in a terminal
# of the window server, where standard input and output are pipes: the
# REPL must go on after it (it once lost its standard input to the window's
# endpoint and ended, closing the window). In ws's terminal:
#   cat in.txt | stratalk - > out.txt
# with in.txt opening a window, then evaluating more; ws stops (Alt+Shift+Q),
# and the console shows out.txt. A Window in register 4, pipe's, which Db
# reads through (made to take it: standard error, a pipe here, keeps it
# otherwise): a Db written and read while the window is open (the register
# is put back for each message). Also `stratalk -` on the console with no window server: Window
# open: is an error, and the REPL goes on.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
b="$here/${BUILD:-build}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
W='\033[27;3;87~'                       # Alt+Shift+W: ws waits a second
AQ='\033[27;3;81~'                      # Alt+Shift+Q: ws stops
A1='\033[27;3;49~'                      # Alt+1: the first tile (the terminal) has the keys
{
  printf "ws\n$W$W$W${W} stratalk > out.txt\n$W$W$W$W"
  printf "(Window open: 'a') class\r$W$W$W${A1}$W$W"
  printf "3 + 4\r$W$W"
  printf "(Window open: 'b') close; class\r$W$W$W${A1}$W$W"
  printf "10 factorial\r$W$W"
  printf "Smalltalk quit\r$W$W$W"
  for l in "Window class compile: 'freeRegister [ ^4 ]'. #four" "Smalltalk at: #W put: (Window open: 'd')" "Smalltalk at: #D put: (Db tree: 'mine/wt')" \
      "D at: 'k' put: 'v1'" "D at: 'k'" \
      "| o | o := OrderedCollection new. D keysAndValuesDo: [:k :v | o add: k -> v]. o" "W close" "D at: 'k'"; do
    printf 'echo "%s" >> db.st\n' "$l"
  done
  printf "$W"
  printf "stratalk - < db.st > db.txt\n$W$W$W$W$W${A1}$W$W"
  printf "${AQ}"
  printf 'cat out.txt\n'
  printf 'cat db.txt\n'
  printf 'echo "Window open: %sc%s" | stratalk -; echo status $?\n' "'" "'"
  printf 'halt\n'
} > "$tmp/in.txt"
cp "$b/disk.img" "$tmp/d.img"
"$b/strata-emu" -c 12 -g none -m 60000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$b/bootrom.stx" > "$tmp/raw.out" 2>&1
fail() { echo "stratalk-window: FAILED: $1"; tail -25 "$tmp/raw.out"; exit 1; }
grep -q 'all cores halted' "$tmp/raw.out" || fail "the machine did not halt"
grep -q '^ws: stopped' "$tmp/raw.out" || fail "ws did not stop"
python3 - "$tmp/raw.out" <<'PY' || fail "what the REPL printed is not what it should be"
import sys
raw = open(sys.argv[1], 'rb').read().decode('latin1').replace('\r', '')
a = raw.index('strata$ cat out.txt\n') + len('strata$ cat out.txt\n')
out = raw[a:raw.index('strata$', a)]
results = [l.split('st> ')[-1] for l in out.split('\n')]
ok = all(w in results for w in ('Window', '7', '3628800')) and results.count('Window') == 2
if not ok:
    print('out.txt:\n' + out); sys.exit(1)
a = raw.index('strata$ cat db.txt\n') + len('strata$ cat db.txt\n')
db = raw[a:raw.index('strata$', a)]
d = [l for l in db.split('\n') if l]
if len(d) != 8 or d[3:6] != ["'v1'", "'v1'", "OrderedCollection ('k'->'v1')"] or d[7] != "'v1'":
    print('db.txt:\n' + db); sys.exit(1)
b = raw.index("| stratalk -; echo status $?\n")
rest = raw[b:]
if 'Error: no server named ws' not in rest or 'status 0' not in rest:
    print(rest[:400]); sys.exit(1)
PY
echo "stratalk-window: ok    a Window from a ws terminal; the REPL goes on"
