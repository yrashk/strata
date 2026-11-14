#!/bin/sh
# test-ws.sh: the window server on the real kernel, headless.
#
#   tools/test-ws.sh bootrom.stx disk.img
#
# Boots StrataOS on the emulator (12 cores, no window) with scripted keys:
# `ws` from the shell; in its first terminal a command that leaves a file
# (keys -> ws -> term -> the shell's pipe), then vi, where Esc followed at
# once by y and by p (the bytes together, as a script sends them) must
# reach vi as Esc and the key, not as ws's Alt+P; wmandel and wclock
# through the palette, and a command typed into it (a terminal runs it: a
# file); Alt+2 and wmandel ended with its own `q` key; a terminal from
# Alt+Enter, with a command that leaves a file; Alt+F (that terminal full
# screen: a command typed into it leaves a file), Alt+1 (the full screen
# moves to the first terminal: a file again) and Alt+F back; Alt+Z (that
# terminal the only tile: a file) and Alt+Z back; focus changes
# (Alt+Right, Alt+Left, Alt+1); Alt+Shift+Q back to the shell, which shows
# the files; then `ws` again: a second terminal, Alt+F and Alt+F again,
# Alt+Z and Alt+Z again, Alt+Z and Alt+F and Alt+F again, and Alt+Shift+H
# (halt with the desktop on the screen).
# Checks the console markers and the last frame (-F): the status strip, a
# focused tile's amber edge, terminal text, and that after full screen, a
# single tile and back the two tiles' edges are exactly where the tiling
# puts them.
# Two more runs (at the same time) halt with a window alone: two terminals,
# the first one, after `seq 60` scrolled it, full screen (Alt+F) or the only
# tile (Alt+Z). The last frame in full screen: no tile edge and no strip,
# the sign in the top right corner, and terminal text in the screen's first
# and last 16 rows and first 8 columns, where no tile reaches: the terminal
# drew itself at the screen's size. As the only tile: the strip, one amber
# edge around the whole tile area and no other tile's, and text down to the
# rows only a tile of that height has.
# Alt+key is ESC [ 27 ; 3 ; code ~, Alt+arrow ESC [ 1 ; 3 X (spec 1.4).
# Alt+Shift+W makes ws ignore the keyboard for a second: time for programs
# to start and draw (it works while the key help is shown). The space after
# each start dismisses the help (shown when the splash ends; the key is not
# passed on).
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
T=$BUILD/test-ws
mkdir -p $T
cp "$DISK" $T/disk.img
W='\033[27;3;87~'                       # Alt+Shift+W
AP='\033[27;3;112~' AE='\033[27;3;13~'  # Alt+P, Alt+Enter
A1='\033[27;3;49~' A2='\033[27;3;50~'   # Alt+1, Alt+2
AR='\033[1;3C' AL='\033[1;3D'           # Alt+Right, Alt+Left
AQ='\033[27;3;81~' AH='\033[27;3;72~'   # Alt+Shift+Q, Alt+Shift+H
AF='\033[27;3;102~' AZ='\033[27;3;122~' # Alt+F, Alt+Z
E='\033'                                # Esc
{
  printf "ws\n$W$W$W${W} echo ws-term-ok > wsmark\n"
  printf "${W}vi wsvi\n$W${W}ihello${E}yy${E}p:wq\n$W"
  printf "${AP}wm\n$W$W${AP}wclock\n$W$W${AP}echo ws-pal-ok > palmark\n$W$W"
  printf "${A2}${W}q$W$W${AE}$W${W}echo ws-alt-ok > altmark\n$W"
  printf "${AF}${W}echo ws-full-ok > fullmark\n$W${A1}${W}echo ws-move-ok > movemark\n$W${AF}$W"
  printf "${AZ}${W}echo ws-single-ok > singlemark\n$W${AZ}$W"
  printf "${AR}$W${AL}$W${A1}$W${AQ}cat wsmark\ncat palmark\ncat altmark\ncat wsvi\n"
  printf "cat fullmark\ncat movemark\ncat singlemark\n"
  printf "ws\n$W$W$W${W} cores\n$W$W${AE}$W$W${AF}$W${AF}$W${AZ}$W${AZ}$W${AZ}$W${AF}$W${AF}$W$W${AH}"
} > $T/keys
printf "ws\n$W$W$W${W} seq 60\n$W${AE}$W$W${A1}$W${AF}$W${AH}" > $T/keys-full
printf "ws\n$W$W$W${W} seq 60\n$W${AE}$W$W${A1}$W${AZ}$W${AH}" > $T/keys-one
$BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/frame.ppm -d $T/disk.img -i $T/keys "$ROM" > $T/out.txt 2>&1 || {
  echo "test-ws: FAILED: the emulator exited with an error"; tail -5 $T/out.txt; exit 1; }
fail() { echo "test-ws: FAILED: $1"; tail -20 $T/out.txt; exit 1; }
grep -q '^ws: stopped' $T/out.txt || fail "ws did not quit to the shell"
grep -q '^ws-term-ok' $T/out.txt || fail "the command typed into the terminal did not run"
grep -q '^ws-pal-ok' $T/out.txt || fail "the command typed into the palette (Alt+P) did not run"
grep -q '^ws-alt-ok' $T/out.txt || fail "the terminal from Alt+Enter did not run its command"
grep -q '^ws-full-ok' $T/out.txt || fail "the full-screen terminal (Alt+F) did not run its command"
grep -q '^ws-move-ok' $T/out.txt || fail "the terminal the full screen moved to (Alt+1) did not run its command"
grep -q '^ws-single-ok' $T/out.txt || fail "the single tile's terminal (Alt+Z) did not run its command"
[ "$(grep -c '^hello$' $T/out.txt)" = 2 ] || fail "vi did not get Esc y y, Esc p (did ws take Esc p as Alt+P?)"
grep -q 'all cores halted' $T/out.txt || fail "the second ws did not halt the machine"
if grep -q 'fault\|panic' $T/out.txt; then fail "a fault was reported"; fi
[ -s $T/frame.ppm ] || fail "no frame was presented"
python3 - $T/frame.ppm <<'PY' || fail "the last frame is not the desktop with its two tiles in place"
import sys
b = open(sys.argv[1], 'rb').read()
p = b.split(b'\n', 3)                      # P6, "W H", 255, pixels
w, h = map(int, p[1].split())
px = p[3]
def count(rgb, y0, y1):
    n = 0
    for y in range(y0, y1):
        row = px[y * w * 3:(y + 1) * w * 3]
        n += sum(1 for i in range(0, len(row), 3) if row[i:i + 3] == rgb)
    return n
def at(x, y):
    return px[(y * w + x) * 3:(y * w + x) * 3 + 3]
amber, teal, pale = bytes((0xFF, 0xB3, 0x47)), bytes((0x1F, 0x6F, 0x8B)), bytes((0xCF, 0xE8, 0xFF))
edge = count(amber, 28, h)                 # the focused tile's edge and tag
text = count(pale, 28, h)                  # terminal text
strip = count(pale, 0, 28)                 # the figures in the status strip
low = count(pale, h - 13, h)               # (no tile's text reaches the last rows)
# two tiles (os/ws/layout.s): 6 pixels around and between, below the 28-pixel strip
aw = w - 12
w0 = (aw - 6) >> 2 << 1
x1, w1, y = 6 + w0 + 6, aw - w0 - 6, 34 + (h - 40) // 2
edges = (at(6, y), at(6 + w0 - 1, y), at(x1, y), at(x1 + w1 - 1, y))
print("frame %dx%d: amber %d, text %d, strip %d, low %d, edges %s" % (w, h, edge, text, strip, low,
      " ".join(e.hex() for e in edges)))
ok = edge > 1500 and text > 2000 and strip > 100 and low == 0
sys.exit(0 if ok and edges == (teal, teal, amber, amber) else 1)
PY
for m in full one; do
  cp "$DISK" $T/disk-$m.img
  $BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/$m.ppm -d $T/disk-$m.img -i $T/keys-$m "$ROM" > $T/out-$m.txt 2>&1 &
done
wait
for m in full one; do
  fail() { echo "test-ws: FAILED: $1"; tail -20 $T/out-$m.txt; exit 1; }
  grep -q 'all cores halted' $T/out-$m.txt || fail "ws with a window alone ($m) did not halt the machine"
  if grep -q 'fault\|panic' $T/out-$m.txt; then fail "a fault was reported ($m)"; fi
  [ -s $T/$m.ppm ] || fail "no frame was presented ($m)"
done
m=full
python3 - $T/full.ppm <<'PY' || fail "the last frame is not a full-screen terminal"
import sys
b = open(sys.argv[1], 'rb').read()
p = b.split(b'\n', 3)                      # P6, "W H", 255, pixels
w, h = map(int, p[1].split())
px = p[3]
def count(rgb, x0, y0, x1, y1):
    n = 0
    for y in range(y0, y1):
        row = px[(y * w + x0) * 3:(y * w + x1) * 3]
        n += sum(1 for i in range(0, len(row), 3) if row[i:i + 3] == rgb)
    return n
amber, teal, pale = bytes((0xFF, 0xB3, 0x47)), bytes((0x1F, 0x6F, 0x8B)), bytes((0xCF, 0xE8, 0xFF))
sign = count(amber, w - 200, 8, w, 30)     # the sign: top right
edge = count(amber, 0, 0, w, h) - sign + count(teal, 0, 0, w, h) # no tile's edge
top = count(pale, 0, 0, 8, 16)             # text in the first row and column,
bottom = count(pale, 0, h - 13, w, h)      #   and in the last row
text = count(pale, 0, 0, w, h)             # 50 rows of it
print("full screen %dx%d: sign %d, edges %d, text %d (top left %d, bottom %d)" % (w, h, sign, edge, text, top, bottom))
sys.exit(0 if sign > 300 and edge == 0 and top > 0 and bottom > 0 and text > 1500 else 1)
PY
m=one
python3 - $T/one.ppm <<'PY' || fail "the last frame is not a single tile under the strip"
import sys
b = open(sys.argv[1], 'rb').read()
p = b.split(b'\n', 3)                      # P6, "W H", 255, pixels
w, h = map(int, p[1].split())
px = p[3]
def count(rgb, x0, y0, x1, y1):
    n = 0
    for y in range(y0, y1):
        row = px[(y * w + x0) * 3:(y * w + x1) * 3]
        n += sum(1 for i in range(0, len(row), 3) if row[i:i + 3] == rgb)
    return n
def at(x, y):
    return px[(y * w + x) * 3:(y * w + x) * 3 + 3]
amber, teal, pale = bytes((0xFF, 0xB3, 0x47)), bytes((0x1F, 0x6F, 0x8B)), bytes((0xCF, 0xE8, 0xFF))
strip = count(pale, 0, 0, w, 28)           # the figures in the status strip
other = count(teal, 0, 34, w, h)           # no other tile's edge
y = 34 + (h - 40) // 2                     # the one tile: the whole area (os/ws/layout.s)
edges = (at(6, y), at(w - 7, y), at(w // 2, 34), at(w // 2, h - 7))
rows = (h - 40 - 20) // 16                 # its terminal's rows: text in the last of them,
last = count(pale, 0, 46 + (rows - 1) * 16, w, 46 + rows * 16)
low = count(pale, 0, h - 13, w, h)         #   and none below the tile
print("single tile %dx%d: strip %d, other edges %d, last row %d, below %d, edges %s" % (w, h, strip, other, last, low,
      " ".join(e.hex() for e in edges)))
sys.exit(0 if strip > 100 and other == 0 and last > 0 and low == 0 and edges == (amber,) * 4 else 1)
PY
echo "test-ws: ok"
