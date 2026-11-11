#!/bin/sh
# The editor (vi) on the emulator. Boots StrataOS with a scripted console
# (keys as the terminal sends them) and drives vi through files: inserting,
# moving, deleting lines, yanking and putting, undo and redo, ., searching,
# :w to a new name, :q!, counts and operators, a file bigger than the D-LS
# (seq 10000: 48 KiB) and the 333 KiB shell source, :set nu, :syntax off,
# :e. The files it wrote are shown with cat (and wc, grep), and that output,
# with vi's screens taken out, is compared with tools/test-vi.out. Then the
# raw screens are searched for the highlighting of an .s and an .fs file
# (SGR colours on the right words, a Forth ( comment carried to the next
# line), and a second boot interrupts vi (Ctrl-C, the console's break) in
# normal mode: it must carry on.
#
#   tools/test-vi.sh build/bootrom.stx build/disk.img     (-u: update the .out)
#
# The emulator runs the interpreter with the virtual timer (-j -T virtual),
# so the session is deterministic. No terminal answers vi's size question,
# so the screen is 80 x 24.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
E=$(printf '\033')
UP="$E[A"; DN="$E[B"; RT="$E[C"; LT="$E[D"
CR=$(printf '\022'); CD=$(printf '\004'); CU=$(printf '\025'); CF=$(printf '\006')
CB=$(printf '\002'); CC=$(printf '\003'); CG=$(printf '\007')
{
  # a new file: insert, move, delete lines, yank and put, undo, search; :w to
  # a new name, then :q! (the file itself is never written)
  printf 'vi f1\n'
  printf 'ione\ntwo\nthree\nfour\nfive%s' "$E"
  printf 'ggjdd'                      # two goes
  printf 'Gyykp'                      # five again after four ...
  printf 'u'                          # ... and gone again
  printf '/thr\nx'                    # three -> hree (the search goes round)
  printf 'ggOzero%s' "$E"             # a line above the first
  printf '?four\nyyggP'               # four put above zero
  printf 'uu%s' "$CR"                 # undo twice, redo once: zero stays, four not
  printf ':w f2\n:q!\n'
  printf 'cat f1; cat f2\n'
  # words and operators, D, C, ., counts
  printf 'vi w1\n'
  printf 'ialpha beta gamma\ndelta epsilon zeta\neta theta%s' "$E"
  printf 'ggwdw'                      # alpha gamma
  printf 'jwcwEPS%s' "$E"             # delta epsilon EPS
  printf '$xj0D'                      # ... EP; line 3 empty
  printf 'iiota%s' "$E"
  printf 'ggeaX%s' "$E"               # alphaX gamma
  printf 'jbbC-%s' "$E"               # alphaX -
  printf 'GA;%sk.k.' "$E"             # ; at the end of every line, by .
  printf ':wq\n'
  printf 'cat w1\n'
  printf 'seq 12 > n1\n'
  printf 'vi n1\n'
  printf '3ddj2yyGp'                  # 4 .. 12, then 5 6
  printf 'ggJr9'                      # 4 5 -> 495
  printf '3j2xkP'                     # 8 out, put after 7: 87
  printf 'x...uu%sjdd.' "$CR"         # 495 -> 5; 6 and 87 go
  printf ':wq\n'
  printf 'cat n1\n'
  # arrows, insert-mode arrows, o O I A, %%, X s S, :N
  printf 'vi p1\n'
  printf 'ifoo(bar[1], baz{2})%s' "$E"
  printf '0%%x'                       # the ) matching (
  printf 'Oabove%sobelow%s' "$E" "$E"
  printf 'Ibeg %sAend%s' "$E" "$E"
  printf '%s%s%sXsQ%s' "$UP" "$DN" "$RT" "$E"
  printf ':1\nSnew first%s' "$E"
  printf 'ixy%sz%s' "$LT" "$E"
  printf ':wq\n'
  printf 'cat p1\n'
  # a file bigger than the D-LS: lines deleted, added, put; scrolling
  printf 'seq 10000 > big\n'
  printf 'vi big\n'
  printf '5000GddGoend%s' "$E"
  printf 'gg/9999\nx'
  printf '3000G2000ddGpu'             # 2000 lines out (put back at the end, undone)
  printf '%s%s%s%s' "$CF" "$CB" "$CD" "$CU"
  printf ':wq\n'
  printf 'wc < big; grep end < big; grep 9999 < big; grep 5000 < big; grep 4999 < big\n'
  # the shell's source (333 KiB): to the end, a search back, nothing changed
  printf 'vi /src/sh.s\n'
  printf 'G?main:\n%s:q\n' "$CG"
  # options, :e, Ctrl-C in normal mode, ZZ
  printf 'vi n1\n'
  printf ':set nu\n:syntax off\n:set nonu\n:syntax on\n'
  printf '%sddZZ' "$CC"
  printf 'vi n1\n'
  printf 'x:e w1\n:e! w1\nx:x\n'
  printf 'cat n1; cat w1\n'
  # highlighting: assembly, Forth, a ( comment over two lines
  printf 'vi /src/hello.s\n45G:q\n'
  printf 'vi gfx.fs\n:q\n'
  printf 'vi m.fs\n'
  printf 'i( open\nstill ) : w ;%s:wq\n' "$E"
  printf 'rm f2 w1 n1 p1 big m.fs\n'
  printf 'echo bye\n%s' "$CD"
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>/dev/null
# vi's screens (from its size question to the clear at its end) taken out;
# from the first prompt on; control bytes visible
python3 - "$tmp/raw.out" "$tmp/out.txt" <<'PY'
import re, sys
raw = open(sys.argv[1], "rb").read().decode("latin-1")
txt = re.sub(r"\x1b\[999;999H.*?\x1b\[H\x1b\[2J", "", raw, flags=re.S)
txt = txt[txt.find("strata$ "):]
txt = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", lambda m: "^" + chr(ord(m.group()) ^ 64), txt)
open(sys.argv[2], "w", encoding="latin-1").write(txt)
PY
fail() { printf '%-14s FAIL  %s\n' vi "$1"; exit 1; }
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$here/tools/test-vi.out"; echo "tools/test-vi.out updated"; exit 0; fi
if ! cmp -s "$tmp/out.txt" "$here/tools/test-vi.out"; then
  diff "$here/tools/test-vi.out" "$tmp/out.txt" | head -40; fail "the files vi wrote differ"
fi
# highlighting: the SGR colour before each word (site/hl.css's colours as the terminal's)
grep -q 'all cores halted' "$tmp/raw.out" || fail "the session did not end"
for want in '[90m; =====' '[34m.data' '[97m_start' '[31mcsrr' '[37ms0' '[91mcoreid' \
            '[96maddi' '[95mbeqz' '[93mctake' '[93mc3' '[32m1' '[35m"Hello from Strata core "' \
            '[31m:' '[97mentry' '[90m( i -- addr )' '[34mcreate' '[33mtget' '[95mdo' \
            '[32m$1000' '[35m.( gfx.fs needs bare metal)' '[90mstill )' '[31m:' ; do
  grep -qF "$E$want" "$tmp/raw.out" || fail "no highlighting: ESC$want"
done
grep -q 'Type :q and Enter to exit vi' "$tmp/raw.out" || fail "Ctrl-C (the key) did not reach vi"
# Ctrl-C (the console's break, -b, while vi moves the cursor up and down):
# the tty echoes ^C and has proc SIGNAL vi, which catches interrupts: it
# goes on with the keys after it and writes its file. (Whether vi also sees
# it as the key Ctrl-C depends on whether it was waiting for a key then.)
printf 'vi cc1\nikept%s' "$E" >"$tmp/in2.txt"
i=0; while [ $i -lt 800 ]; do printf 'jk' >>"$tmp/in2.txt"; i=$((i + 1)); done
printf ':wq\ncat cc1\n%s' "$CD" >>"$tmp/in2.txt"
cp "$2" "$tmp/d2.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -b ${VI_BREAK:-25000000} -m 4000000000 -d "$tmp/d2.img" -i "$tmp/in2.txt" "$1" >"$tmp/raw2.out" 2>/dev/null
python3 - "$tmp/raw2.out" <<'PY' || fail "vi did not survive Ctrl-C (or it came outside vi)"
import sys
r = open(sys.argv[1], "rb").read()
vi, cc, end = r.find(b"vi cc1"), r.find(b"^C"), r.rfind(b"\x1b[H\x1b[2J")
sys.exit(0 if 0 <= vi < cc < end < r.rfind(b"\nkept\n") else 1)
PY
printf '%-14s OK    editing, undo, search, :w, a 48 KiB file, highlighting (asm, Forth), Ctrl-C\n' vi
