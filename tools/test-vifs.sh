#!/bin/sh
# The Forth editor, lang/forth/vi.fs (`forth vi.fs FILE`), on the emulator.
# The session of tools/test-vi.sh, the assembly vi's test, with the same keys:
# inserting, moving, deleting lines, yanking and putting, undo and redo, .,
# searching, :w to a new name, :q!, counts and operators, a file bigger than
# the whole D-LS (seq 15000: 77 KiB) and the 333 KiB shell source, :set nu,
# :syntax off, :e. The files it wrote are shown with cat (and wc, grep), and
# that output, with vi's screens taken out, is compared with
# tools/test-vifs.out, and also with tools/test-vi.out (the names of the
# commands aside): the two editors must have written the same files. Then the
# raw screens are searched for the highlighting of an .s and an .fs file (SGR
# colours on the right words, a Forth ( comment carried to the next line), and
# a second boot interrupts vi.fs (Ctrl-C, the console's break) in normal mode:
# it must carry on. A third session starts the editor from the Forth prompt
# (include vi.fs, then vi FILE).
#
#   tools/test-vifs.sh build/bootrom.stx build/disk.img     (-u: update the .out)
#
# The emulator runs the interpreter with the virtual timer (-j -T virtual),
# so the session is deterministic. No terminal answers the size question, so
# the screen is 80 x 24.
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
VI="forth vi.fs"
{
  # a new file: insert, move, delete lines, yank and put, undo, search; :w to
  # a new name, then :q! (the file itself is never written)
  printf '%s f1\n' "$VI"
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
  printf '%s w1\n' "$VI"
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
  printf '%s n1\n' "$VI"
  printf '3ddj2yyGp'                  # 4 .. 12, then 5 6
  printf 'ggJr9'                      # 4 5 -> 495
  printf '3j2xkP'                     # 8 out, put after 7: 87
  printf 'x...uu%sjdd.' "$CR"         # 495 -> 5; 6 and 87 go
  printf ':wq\n'
  printf 'cat n1\n'
  # arrows, insert-mode arrows, o O I A, %%, X s S, :N
  printf '%s p1\n' "$VI"
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
  printf 'seq 15000 > big\n'
  printf '%s big\n' "$VI"
  printf '5000GddGoend%s' "$E"
  printf 'gg/9999\nx'
  printf '3000G2000ddGpu'             # 2000 lines out (put back at the end, undone)
  printf '%s%s%s%s' "$CF" "$CB" "$CD" "$CU"
  printf ':wq\n'
  printf 'wc < big; grep end < big; grep 9999 < big; grep 5000 < big; grep 4999 < big\n'
  # the shell's source (333 KiB): to the end, a search back, nothing changed
  printf '%s /src/sh.s\n' "$VI"
  printf 'G?main:\n%s:q\n' "$CG"
  # options, :e, Ctrl-C in normal mode, ZZ
  printf '%s n1\n' "$VI"
  printf ':set nu\n:syntax off\n:set nonu\n:syntax on\n'
  printf '%sddZZ' "$CC"
  printf '%s n1\n' "$VI"
  printf 'x:e w1\n:e! w1\nx:x\n'
  printf 'cat n1; cat w1\n'
  # highlighting: assembly, Forth, a ( comment over two lines
  printf '%s /src/hello.s\n45G:q\n' "$VI"
  printf '%s /forth/gfx.fs\n:q\n' "$VI"
  printf '%s m.fs\n' "$VI"
  printf 'i( open\nstill ) : w ;%s:wq\n' "$E"
  printf 'rm f2 w1 n1 p1 big m.fs\n'
  printf 'echo bye\n%s' "$CD"
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 8000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>"$tmp/err.out"
if [ -n "${VIFS_KEEP:-}" ]; then cp "$tmp/raw.out" "$tmp/err.out" "$tmp/in.txt" "$VIFS_KEEP"; fi
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
fail() { printf '%-14s FAIL  %s\n' vi.fs "$1"; exit 1; }
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$here/tools/test-vifs.out"; echo "tools/test-vifs.out updated"; exit 0; fi
if ! cmp -s "$tmp/out.txt" "$here/tools/test-vifs.out"; then
  diff "$here/tools/test-vifs.out" "$tmp/out.txt" | head -40; fail "the files vi.fs wrote differ"
fi
# the same files as the assembly vi wrote (its test's expected output)
sed 's/^strata\$ forth vi\.fs /strata$ vi /' "$tmp/out.txt" >"$tmp/as-vi.txt"
if ! cmp -s "$tmp/as-vi.txt" "$here/tools/test-vi.out"; then
  diff "$here/tools/test-vi.out" "$tmp/as-vi.txt" | head -40; fail "not the files the assembly vi writes"
fi
# highlighting: the SGR colour before each word (site/hl.css's colours as the terminal's)
grep -q 'all cores halted' "$tmp/raw.out" || fail "the session did not end"
for want in '[90m; =====' '[34m.data' '[97m_start' '[31mcsrr' '[37ms0' '[91mcoreid' \
            '[96maddi' '[95mbeqz' '[93mctake' '[93mc3' '[32m1' '[35m"Hello from Strata core "' \
            '[31m:' '[97mentry' '[90m( i -- addr )' '[34mcreate' '[33mtget' '[95mdo' \
            '[32m$1000' '[35m.( gfx.fs needs bare metal)' '[90mstill )' '[31m:' ; do
  grep -qF "$E$want" "$tmp/raw.out" || fail "no highlighting: ESC$want"
done
grep -q 'Type :q and Enter to exit vi' "$tmp/raw.out" || fail "Ctrl-C (the key) did not reach vi.fs"
# Ctrl-C (the console's break, -b, while vi.fs moves the cursor up and down):
# the tty echoes ^C and has proc SIGNAL Forth, which catches interrupts while
# vi.fs runs: it goes on with the keys after it and writes its file.
printf '%s cc1\nikept%s' "$VI" "$E" >"$tmp/in2.txt"
i=0; while [ $i -lt 800 ]; do printf 'jk' >>"$tmp/in2.txt"; i=$((i + 1)); done
printf ':wq\ncat cc1\n%s' "$CD" >>"$tmp/in2.txt"
cp "$2" "$tmp/d2.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -b ${VIFS_BREAK:-25000000} -m 8000000000 -d "$tmp/d2.img" -i "$tmp/in2.txt" "$1" >"$tmp/raw2.out" 2>/dev/null
python3 - "$tmp/raw2.out" <<'PY' || fail "vi.fs did not survive Ctrl-C (or it came outside vi.fs)"
import sys
r = open(sys.argv[1], "rb").read()
vi, ask, cc, end = r.find(b"vi.fs cc1"), r.find(b"\x1b[999;999H"), r.find(b"^C"), r.rfind(b"\x1b[H\x1b[2J")
sys.exit(0 if 0 <= vi < ask < cc < end < r.rfind(b"\nkept\n") else 1)
PY
# from the Forth prompt: include vi.fs, then vi FILE (twice), and the prompt is back
printf 'forth\ninclude vi.fs\nvi r1\nirepl%s:wq\nvi r1\nA one%s:wq\n.( back) cr\nbye\ncat r1\n%s' "$E" "$E" "$CD" >"$tmp/in3.txt"
cp "$2" "$tmp/d3.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 8000000000 -d "$tmp/d3.img" -i "$tmp/in3.txt" "$1" >"$tmp/raw3.out" 2>/dev/null
python3 - "$tmp/raw3.out" <<'PY' || fail "vi FILE at the Forth prompt"
import re, sys
r = open(sys.argv[1], "rb").read().decode("latin-1")
r = re.sub(r"\x1b\[999;999H.*?\x1b\[H\x1b\[2J", "", r, flags=re.S)
sys.exit(0 if "back" in r and "\nrepl one\n" in r else 1)
PY
printf '%-14s OK    the files of the assembly vi'"'"'s session, a 77 KiB file, highlighting, Ctrl-C, from the prompt\n' vi.fs
