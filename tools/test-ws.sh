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
# Alt+Enter, with a command that leaves a file; focus changes (Alt+Right,
# Alt+Left, Alt+1); Alt+Shift+Q back to the shell, which shows the files;
# then `ws` again and Alt+Shift+H (halt with the desktop on the screen).
# Checks the console markers and the last frame (-F): the status strip, a
# focused tile's amber edge, terminal text.
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
E='\033'                                # Esc
{
  printf "ws\n$W$W$W${W} echo ws-term-ok > wsmark\n"
  printf "${W}vi wsvi\n$W${W}ihello${E}yy${E}p:wq\n$W"
  printf "${AP}wm\n$W$W${AP}wclock\n$W$W${AP}echo ws-pal-ok > palmark\n$W$W"
  printf "${A2}${W}q$W$W${AE}$W${W}echo ws-alt-ok > altmark\n$W"
  printf "${AR}$W${AL}$W${A1}$W${AQ}cat wsmark\ncat palmark\ncat altmark\ncat wsvi\n"
  printf "ws\n$W$W$W${W} cores\n$W$W${AH}"
} > $T/keys
$BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/frame.ppm -d $T/disk.img -i $T/keys "$ROM" > $T/out.txt 2>&1 || {
  echo "test-ws: FAILED: the emulator exited with an error"; tail -5 $T/out.txt; exit 1; }
fail() { echo "test-ws: FAILED: $1"; tail -20 $T/out.txt; exit 1; }
grep -q '^ws: stopped' $T/out.txt || fail "ws did not quit to the shell"
grep -q '^ws-term-ok' $T/out.txt || fail "the command typed into the terminal did not run"
grep -q '^ws-pal-ok' $T/out.txt || fail "the command typed into the palette (Alt+P) did not run"
grep -q '^ws-alt-ok' $T/out.txt || fail "the terminal from Alt+Enter did not run its command"
[ "$(grep -c '^hello$' $T/out.txt)" = 2 ] || fail "vi did not get Esc y y, Esc p (did ws take Esc p as Alt+P?)"
grep -q 'all cores halted' $T/out.txt || fail "the second ws did not halt the machine"
if grep -q 'fault\|panic' $T/out.txt; then fail "a fault was reported"; fi
[ -s $T/frame.ppm ] || fail "no frame was presented"
python3 - $T/frame.ppm <<'PY' || fail "the last frame is not the desktop"
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
amber = count(bytes((0xFF, 0xB3, 0x47)), 28, h)      # the focused tile's edge and tag
text = count(bytes((0xCF, 0xE8, 0xFF)), 28, h)       # terminal text
strip = count(bytes((0xCF, 0xE8, 0xFF)), 0, 28)      # the figures in the status strip
print("frame %dx%d: amber %d, text %d, strip %d" % (w, h, amber, text, strip))
sys.exit(0 if amber > 1500 and text > 2000 and strip > 100 else 1)
PY
echo "test-ws: ok"
