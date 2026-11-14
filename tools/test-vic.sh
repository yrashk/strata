#!/bin/sh
# vi's C highlighting on the emulator. Boots StrataOS with a scripted console
# and runs vi on C files: one typed in (every kind of token: a preprocessor
# line (one with blanks around the #), a #include <name>, comments of both kinds, one over two lines,
# keywords, types, strings and characters with escapes, numbers), the same
# file after an edit that ends a comment (the rows below change colour),
# cc.c entered in the middle of its first comment (the state comes from
# lines above the screen), a file whose comment runs over 100 lines (seen
# from inside, after an edit far above that ends it, and scrolling back up
# into it), a comment typed in insert mode while the screen scrolls,
# :syntax off, and a .h file.
#
#   tools/test-vic.sh build/bootrom.stx build/disk.img     (-u: update the .out)
#
# Each vi session's output (from its size question to the clear at its end)
# is played into an 80 x 24 grid, as a terminal would, and the last frame
# is written out with the colour of each run of non-blank cells ({90}: SGR
# 90, {}: the default) and compared with tools/test-vic.out. The output is
# also checked for colours that change nothing: an SGR that sets the colour
# in effect, or one followed by another before any non-blank byte (the
# reset at the end of a row aside).
#
# The emulator runs the interpreter with the virtual timer (-j -T virtual),
# so the session is deterministic; no terminal answers vi's size question,
# so the screen is 80 x 24.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
E=$(printf '\033'); CB=$(printf '\002')
{
  # every kind of token, typed in
  printf 'vi t.c\n'
  printf 'i#include <stdio.h>\n'
  printf '#define N 0x1Fu /* a\n'
  printf '   comment */ int x;\n'
  printf '// a line comment: "not a string"\n'
  printf 'static const char *s = "a\\tb\\x41\\101\\"q" "/* no */";\n'
  printf 'int main(void) {\n'
  printf "\tunsigned long n = 1.5e+3 + .5 + 'c' + '\\\\n' + 0x1p-2;\n"
  printf '\tif (n) return sizeof(size_t); else goto out;\n'
  printf '\t/* open\n'
  printf '\tstill */ for (;;) break; /**/ /*/ x */ L"w";\n'
  printf '  #  pragma once\n'
  printf "\tchar c = '\"'; _Bool b; FILE *f; uint8_t u = 017;\n"
  printf 'out:\treturn 0;\n}%s:wq\n' "$E"
  # the comment's opener goes: the row below it is code again
  printf 'vi t.c\n9G^2x:q!\n'
  # cc.c, from line 9: inside its first comment (lines 1..25)
  printf 'vi /src/cc.c\nG20G:q\n'
  # a comment over 100 lines: inside it; after its opener goes; from below
  printf "echo '/*' > f.c; seq 100 >> f.c; echo '*/ int' >> f.c; seq 100 >> f.c\n"
  printf 'vi f.c\n50G:q\n'
  printf 'vi f.c\n50GggdduG50Gggdd50G:q!\n'
  printf 'vi f.c\n180G%s%s%s%s:q\n' "$CB" "$CB" "$CB" "$CB"
  # a comment typed in insert mode while the screen scrolls
  printf 'vi g.c\ni/* a\n'
  i=0; while [ $i -lt 30 ]; do printf 'line %d\n' $i; i=$((i + 1)); done
  printf 'int%s:wq\n' "$E"
  # :syntax off; a .h file
  printf 'vi t.c\n:syntax off\n:q\n'
  printf 'vi t.h\ni#ifndef T_H\ntypedef unsigned long size_t; /* x */\n#endif%s:wq\n' "$E"
  printf 'rm t.c f.c g.c t.h\n'
  printf 'echo bye\n\004'
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>/dev/null
fail() { printf '%-14s FAIL  %s\n' vic "$1"; exit 1; }
grep -q 'all cores halted' "$tmp/raw.out" || fail "the session did not end"
python3 - "$tmp/raw.out" "$tmp/out.txt" <<'PY' || fail "vi's output is wrong (above)"
import re, sys
raw = open(sys.argv[1], "rb").read().decode("latin-1")
sessions = re.findall(r"\x1b\[999;999H(.*?)\x1b\[H\x1b\[2J", raw, flags=re.S)
ROWS, COLS = 24, 80
out, bad = [], []
for k, s in enumerate(sessions):
    grid = [[(" ", 39)] * COLS for _ in range(ROWS)]
    r = c = 0
    fg = 39
    pending = None                       # an SGR not yet followed by a non-blank byte
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "\x1b":
            m = re.match(r"\x1b\[(\??)([0-9;]*)([A-Za-z])", s[i:])
            if not m:
                bad.append(f"session {k + 1}: a lone ESC at {i}")
                break
            priv, args, cmd = m.groups()
            i += m.end()
            if priv:
                continue
            ps = [int(x) if x else 0 for x in args.split(";")] if args else []
            if cmd == "H":
                r = min((ps[0] if ps else 1), ROWS) - 1
                c = min((ps[1] if len(ps) > 1 else 1), COLS) - 1
            elif cmd == "K":
                for x in range(c, COLS):
                    grid[r][x] = (" ", 39)
            elif cmd == "J":
                grid = [[(" ", 39)] * COLS for _ in range(ROWS)]
            elif cmd == "m":
                v = ps[0] if ps else 0
                new = 39 if v == 0 else v
                if v != 0:
                    if pending is not None:
                        bad.append(f"session {k + 1}: SGR {pending} then SGR {v} with nothing between")
                    if new == fg:
                        bad.append(f"session {k + 1}: SGR {v} sets the colour in effect")
                    pending = v
                elif pending is not None and pending != 1:
                    bad.append(f"session {k + 1}: SGR {pending} then a reset with nothing between")
                fg = new if v != 1 else fg
                if v == 0:
                    pending = None
            continue
        if ch in "\r\n":
            i += 1
            continue
        if c < COLS:
            grid[r][c] = (ch, fg)
        c += 1
        if ch != " ":
            pending = None
        i += 1
    out.append(f"---- session {k + 1}")
    for row in grid:
        line, cur = "", 39
        for ch, col in row:
            if ch != " " and col != cur:
                line += "{}" if col == 39 else "{%d}" % col
                cur = col
            line += ch
        out.append(line.rstrip())
open(sys.argv[2], "w", encoding="latin-1").write("\n".join(out) + "\n")
for b in bad[:10]:
    print("vic:", b)
if len(sessions) != 9:
    print(f"vic: {len(sessions)} vi sessions, not 9")
    sys.exit(1)
sys.exit(1 if bad else 0)
PY
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$here/tools/test-vic.out"; echo "tools/test-vic.out updated"; exit 0; fi
if ! cmp -s "$tmp/out.txt" "$here/tools/test-vic.out"; then
  diff "$here/tools/test-vic.out" "$tmp/out.txt" | head -40; fail "the frames differ"
fi
printf '%-14s OK    C colours: tokens, comments over lines and screens, edits, :syntax off, .h\n' vic
