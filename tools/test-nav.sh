#!/bin/sh
# nav, the file navigator, on the emulator.
#
#   tools/test-nav.sh bootrom.stx disk.img        the console session
#   tools/test-nav.sh -w bootrom.stx disk.img     a window session: the mouse
#
# The console session boots StrataOS with scripted keys (the interpreter and
# the virtual timer: deterministic) and drives nav: a file made deep in the
# tree (in /deep/er) and a snapshot first; then in nav (/doc and /etc): the
# panels as drawn, Down to motd and F5 (a copy into /etc), Tab and F8 on the
# copy answered n (nothing happens) and then y (deleted), Tab, Up and F2 (about
# filed in /etc too: the same file); Enter on etc/ (a subdirectory now: the
# facet) and Backspace back; F4 on about: vi, where a line is added and
# written (:wq); Esc 1 (F1: the help) and Esc; a search typed ("needl") that finds the file in
# /deep/er, Enter on it (the viewer: its text), h (hex), q, Esc; Home, Enter
# on the snapshot @before and F8 there (refused: read-only); F10. Then `ls
# -t` of /doc and /etc and `cat` of the snapshot's motd. Checked: what the
# screens and the command line said (escape sequences taken out) and what
# the shell printed afterwards.
#
# The window session runs nav in a `term` under `ws` (12 cores) and uses
# only the mouse (-P): a click on /etc's resolv in the right panel, a click
# on the key bar's 8 (Delete), then the key y; F10 and halt with the disk
# written back (-w): stdb must find /etc/rc and no resolv. That needs term's
# mouse reports and nav's handling of them.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
win=0
if [ "${1:-}" = "-w" ]; then win=1; shift; fi
tmp=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$tmp"' EXIT
fail() { echo "test-nav: FAILED: $1"; exit 1; }
cp "$2" "$tmp/d.img"
E=$(printf '\033')
UP="$E[A"; DN="$E[B"; HOME="$E[H"
F2="$E[12~"; F4="$E[14~"; F5="$E[15~"; F8="$E[19~"; F10="$E[21~"

if [ $win = 1 ]; then
  W="$E[27;3;87~"; AF="$E[27;3;102~"; AH="$E[27;3;72~"
  pre="ws
$W$W$W$W $AF${W}nav /doc /etc
$W$W$W"
  printf '%s' "$pre" > "$tmp/in.txt"
  k=$(wc -c < "$tmp/in.txt" | tr -d ' ')
  # after `y` (and a wait), F10 quits nav; then halt with the frame
  printf '%s' "$W${W}y$W$W$F10$W$W$AH" >> "$tmp/in.txt"
  # the right panel at 1280 x 800 in cells of 8 x 16: column 82 on; its rows:
  # 2 "..", 3 rc, 4 resolv. Then the bar (row 49): F8 is the 8th of ten
  # slots of 15 columns: x 860
  cat > "$tmp/ptr.txt" <<EOF
k$k move 700 72
k$k down left
k$k up left
k$k move 860 792
k$k down left
k$k up left
EOF
  "$b/strata-emu" -c 12 -g none -m 60000000000 -P "$tmp/ptr.txt" -d "$tmp/d.img" -w "$tmp/d.img" \
    -i "$tmp/in.txt" "$1" > "$tmp/raw.out" 2>&1 || fail "the emulator exited with an error"
  grep -q 'all cores halted' "$tmp/raw.out" || fail "the machine did not halt"
  if grep -q 'fault\|panic' "$tmp/raw.out"; then fail "a fault was reported"; fi
  "$b/stdb" ls "$tmp/d.img" > "$tmp/ls.txt" 2>&1 || fail "stdb could not read the disk written back"
  grep -q '^resolv ' "$tmp/ls.txt" && fail "resolv is still there: the clicks did not delete it"
  grep -q '^rc ' "$tmp/ls.txt" || fail "rc is gone too"
  echo "test-nav: ok    (window) a click on a file, a click on the bar's Delete, y: deleted"
  exit 0
fi

{
  printf 'echo found > /deep/er/needle.txt\n'
  printf 'snap before\n'
  printf 'nav /doc /etc\n'
  printf '%s' "$DN$DN$F5"; printf '\n'          # motd copied into /etc
  printf '%s' "	$DN${F8}n"                     # Tab; motd in /etc; F8, n: kept
  printf '%s' "${F8}y"                           # F8, y: deleted
  printf '%s' "	$UP${F2}y"                     # Tab; about; F2: also filed in /etc
  printf '\n'                                    # etc/ (a facet now, at the cursor): Enter
  printf '\177'                                  # Backspace: back to /doc
  printf '%s' "$DN$F4"                            # about (the cursor came back on etc/): F4, vi
  printf 'Oedited in vi\033:wq\n'                # a line above the first; written
  printf '\0331'; printf '\033'                  # Esc 1: F1, the help; Esc leaves it
  printf 'needl'; printf '\n'                    # the search; Enter: the viewer
  printf 'hq'; printf '\033'                     # hex, back, Esc: the search ends
  printf '%s' "${HOME}"; printf '\n'             # Home: "..", Enter: up to /
  printf '%s' "$E[F"; printf '\n'                # End: @before, Enter
  printf '%s' "$DN$DN$DN$DN"; printf '\n'        # doc/ in the snapshot (bin deep demo doc)
  printf '%s' "$DN${F8}"                         # F8 on about there: refused
  printf '%s' "$F10"
  printf 'ls -t /doc\nls -t /etc\ncat /@before/doc/motd | wc\ncat /doc/about | grep vi\nhalt\n'
} > "$tmp/in.txt"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 8000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" \
  > "$tmp/raw.out" 2>/dev/null || fail "the emulator exited with an error"
python3 - "$tmp/raw.out" <<'PY' || fail "what nav showed or did is not what the keys should give"
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('latin1')
text = re.sub(r'\x1b\[[0-9;?<]*[A-Za-z~]', ' ', raw)
text = re.sub(r' +', ' ', text)
want = [
    ('the panels', '/doc', ' about 120 '),
    ('the copy', 'Copy motd to /etc?', 'done: 1'),
    ('the delete question', 'Delete motd? y: everywhere n: no t: only take it out of etc', None),
    ('also file', 'Also file in /etc? y/n', None),
    ('the facet', ' etc/ SUB-DIR ', ' /doc/etc '),
    ('the search', 'Find: needl 1 found', ' needle.txt '),
    ('the viewer (text)', ' needle.txt 0/6 text', 'found'),
    ('the viewer (hex)', '00000000 66 6f 75 6e 64 0a', ' hex h: text q: back'),
    ('the snapshot', ' @before/ -SNAP- ', ' /@before/doc '),
    ('read-only', 'read-only: a snapshot', None),
    ('vi', ' 1,1 ', None),
    ('the help', 'Esc then a digit: that F-key', None),
]
bad = 0
for name, a, b in want:
    for s in (a, b):
        if s and s not in text:
            print("test-nav: missing (%s): %r" % (name, s)); bad = 1
# what the shell says afterwards: about in doc and etc; motd only in doc
sh = text[text.rfind('ls -t /doc'):]
for s in ('about 133 doc etc', 'motd 1648 doc', 'rc 14 etc', '1648', 'edited in vi'):
    if s not in sh:
        print("test-nav: the shell's listing lacks %r" % s); bad = 1
if 'motd 1648 etc' in sh or 'motd 1648 doc etc' in sh:
    print("test-nav: motd was not deleted from /etc"); bad = 1
if 'fault' in raw or 'panic' in raw:
    print("test-nav: a fault"); bad = 1
sys.exit(bad)
PY
echo "test-nav: ok    panels, copy, delete (n, y), also file, facets, vi (F4), help, search, viewer, hex, snapshot"
