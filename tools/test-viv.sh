#!/bin/sh
# vi's visual mode on the emulator. Boots StrataOS with a scripted console
# and edits copies of one five-line file with each kind of selection (v, V,
# Ctrl-V) and each operator: d (undone and redone as one step), y and p and
# P (characters over lines, lines, a block, also into the selection's place),
# c (and . after it), ~ u U r, > < (and .), J, the : line on '<,'> (:d, :y,
# :w FILE, :w alone refused), blockwise I and A (after $) and c, gv, o, the
# marks '<, . after V d and after a block's I, a selection made with the
# mouse (the reports a window's terminal sends, typed in) and the wheel.
# Then an assembly file's lines selected over their colours.
#
#   tools/test-viv.sh build/bootrom.stx build/disk.img     (-u: update the .out)
#   tools/test-viv.sh -f build/bootrom.stx build/disk.img  (the Forth port)
#
# With -f the sessions run the Forth port, lang/forth/vi.fs (`forth vi.fs
# FILE`), with the same keys, and are compared with the same
# tools/test-viv.out: the two editors must draw the same frames and write
# the same files.
#
# Each vi session's output (from its size question to the clear at its end)
# is played into an 80 x 24 grid, as a terminal would, and the grid is
# written out as it was at the end of each stretch of visual mode (the last
# frame whose status line says -- VISUAL ...) and at the end of the session:
# runs of reverse video (the selection) between << and >> (as the bytes
# 0xAB 0xBB), colours as {SGR} before non-blank cells ({}: the default).
# The files written are shown with cat after the sessions.
#
# The emulator runs the interpreter with the virtual timer (-j -T virtual),
# so the session is deterministic; no terminal answers vi's size question,
# so the screen is 80 x 24.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0; VI=vi; name=viv
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
if [ "${1:-}" = "-f" ]; then VI="forth vi.fs"; name=vivfs; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
E=$(printf '\033'); CV=$(printf '\026'); CR=$(printf '\022')
{
  # the file every session starts from
  printf '%s b\n' "$VI"
  printf 'ione two three\nfour five six\nseven eight nine\nten eleven twelve\nMixed Case_words here%s:wq\n' "$E"
  printf 'cp b c1; cp b c2; cp b c3; cp b c4; cp b c5; cp b c6; cp b c7; cp b c8\n'
  printf 'cp b c9; cp b c10; cp b c11; cp b c12; cp b c13\n'
  # v d over two lines; undone (one step: c1u is b), redone
  printf '%s c1\nwvjd:w\nu:w c1u\n%s:wq\n' "$VI" "$CR"
  # v y over two lines; p after the last byte, P before the first
  printf '%s c2\nwvjyG$pggP:wq\n' "$VI"
  # v c, then . on as many bytes
  printf '%s c3\nwvecTWO%sj0.:wq\n' "$VI" "$E"
  # U ~ r u
  printf '%s c4\nv$UG0v$~2Gvlr*ggwvu:wq\n' "$VI"
  # V d, p; V > and . (twice), V <; V J
  printf '%s c5\njVjdpggVj>.ggVj<GkVkJ:wq\n' "$VI"
  # Ctrl-V d (undone), I, A after $, c
  printf '%s c6\nl%sjjldugg%sjjI# %sgg%sjj$A;%sGk0%sjec[X]%s:wq\n' "$VI" "$CV" "$CV" "$E" "$CV" "$E" "$CV" "$E"
  # Ctrl-V y; p after the last byte (a new line, padded), P at the start
  printf '%s c7\n%sjlyG$pgg0P:wq\n' "$VI" "$CV"
  # the : line on '<,'>: d, w alone (refused), w FILE, y; :'<,'>d again
  printf "%s c8\njVj:d\nggVj:w\nggVj:w part\nggVj:y\nGp:'<,'>d\n:wq\n" "$VI"
  # p and P in the selection's place: characters into characters, into lines;
  # lines into lines
  printf '%s c9\nwyejwvep3GVpggyyGVP:wq\n' "$VI"
  # gv, the mark '<, o
  printf "%s c10\njvjl%sgggvdG'<xggwvllohd:wq\n" "$VI" "$E"
  # the mouse: a press on row 2 column 6, the release on row 3 column 3: a
  # selection; then the wheel up and x
  printf '%s c11\n%s[<0;6;2M%s[<0;3;3md%s[<64;1;1Mx:wq\n' "$VI" "$E" "$E" "$E"
  # frames: v over lines (the newlines selected), a block to the ends ($)
  printf '%s c12\nwvj%sgg%sjj$%s:q\n' "$VI" "$E" "$CV" "$E"
  # . after V d (one undo), after a block's I
  printf '%s c13\nVjd.u%sjI> %sG.:wq\n' "$VI" "$CV" "$E"
  # an assembly file's lines selected over their colours
  printf '%s /src/demo/hello.s\n45GVj%s:q\n' "$VI" "$E"
  printf 'cat c1 c1u; cat c2; cat c3; cat c4; cat c5; cat c6; cat c7; cat c8 part\n'
  printf 'cat c9; cat c10; cat c11; cat c13\n'
  printf 'rm b c1 c1u c2 c3 c4 c5 c6 c7 c8 part c9 c10 c11 c12 c13\n'
  printf 'echo bye\n\004'
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>/dev/null
fail() { printf '%-14s FAIL  %s\n' $name "$1"; exit 1; }
grep -q 'all cores halted' "$tmp/raw.out" || fail "the session did not end"
grep -q 'Use ! to write part of the buffer to its file' "$tmp/raw.out" || fail ":'<,'>w without a name was not refused"
python3 - "$tmp/raw.out" "$tmp/out.txt" <<'PY' || fail "vi's output is wrong (above)"
import re, sys
raw = open(sys.argv[1], "rb").read().decode("latin-1")
sessions = re.findall(r"\x1b\[999;999H(.*?)\x1b\[H\x1b\[2J", raw, flags=re.S)
ROWS, COLS = 24, 80
out = []
def show(grid):
    lines = []
    for row in grid:
        line, cur, rev = "", 39, False
        for ch, col, rv in row:
            if rv != rev:
                line += "\xab" if rv else "\xbb"
                rev = rv
            if ch != " " and col != cur:
                line += "{}" if col == 39 else "{%d}" % col
                cur = col
            line += ch
        if rev:
            line += "\xbb"
        lines.append(line.rstrip())
    return lines
for k, s in enumerate(sessions):
    grid = [[(" ", 39, False)] * COLS for _ in range(ROWS)]
    r = c = 0
    fg, rev = 39, False
    last, nvis = None, 0
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "\x1b":
            m = re.match(r"\x1b\[(\??)([0-9;]*)([A-Za-z])", s[i:])
            if not m:
                print(f"viv: session {k + 1}: a lone ESC at {i}")
                sys.exit(1)
            priv, args, cmd = m.groups()
            i += m.end()
            ps = [int(x) if x else 0 for x in args.split(";")] if args else []
            if priv:
                if cmd == "h" and ps == [25]:     # a frame is complete: in visual mode?
                    status = "".join(x[0] for x in grid[ROWS - 1])
                    if "-- VISUAL" in status:
                        last = [row[:] for row in grid]
                    elif last is not None:
                        nvis += 1
                        out.append(f"---- session {k + 1}, visual mode {nvis}")
                        out.extend(show(last))
                        last = None
                continue
            if cmd == "H":
                r = min((ps[0] if ps else 1), ROWS) - 1
                c = min((ps[1] if len(ps) > 1 else 1), COLS) - 1
            elif cmd == "K":
                for x in range(c, COLS):
                    grid[r][x] = (" ", 39, False)
            elif cmd == "J":
                grid = [[(" ", 39, False)] * COLS for _ in range(ROWS)]
            elif cmd == "m":
                for v in ps or [0]:
                    if v == 0:
                        fg, rev = 39, False
                    elif v == 7:
                        rev = True
                    elif v == 27:
                        rev = False
                    elif v != 1:
                        fg = v
            continue
        if ch in "\r\n":
            i += 1
            continue
        if c < COLS:
            grid[r][c] = (ch, fg, rev)
        c += 1
        i += 1
    if last is not None:
        nvis += 1
        out.append(f"---- session {k + 1}, visual mode {nvis}")
        out.extend(show(last))
    out.append(f"---- session {k + 1}")
    out.extend(show(grid))
# the files, as cat showed them (after the last session)
tail = raw[raw.rfind("\x1b[H\x1b[2J") + 7:]
tail = tail[tail.find("strata$ cat"):tail.find("strata$ rm")]
tail = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", lambda m: "^" + chr(ord(m.group()) ^ 64), tail.replace("\r", ""))
out.append("---- the files")
out.append(tail.rstrip("\n"))
open(sys.argv[2], "w", encoding="latin-1").write("\n".join(out) + "\n")
if len(sessions) != 15:
    print(f"viv: {len(sessions)} vi sessions, not 15")
    sys.exit(1)
PY
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$here/tools/test-viv.out"; echo "tools/test-viv.out updated"; exit 0; fi
if ! cmp -s "$tmp/out.txt" "$here/tools/test-viv.out"; then
  diff "$here/tools/test-viv.out" "$tmp/out.txt" | head -40; fail "the frames or the files differ"
fi
printf '%-14s OK    visual mode: v V Ctrl-V, the operators, :'"'"'<,'"'"'>, gv, marks, ., the mouse, frames\n' $name
