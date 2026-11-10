#!/bin/sh
# test-ws.sh: the window server on the real kernel, headless.
#
#   tools/test-ws.sh bootrom.stx disk.img
#
# Boots StrataOS on the emulator (12 cores, no window) with scripted keys:
# `ws` from the shell; in its first terminal a command that leaves a file
# (keys -> ws -> term -> the shell's pipe); wmandel and wclock through the
# palette; a second terminal (four tiles); focus changes; a window closed;
# Alt+Shift+Q back to the shell, which shows the file; then `ws` again and
# Alt+Shift+H (halt with the desktop on the screen). Checks the console
# markers and the last frame (-F): the status strip, a focused tile's amber
# edge, terminal text.
# In the script, ESC W makes ws ignore the keyboard for a second: time for
# programs to start and draw.
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
T=$BUILD/test-ws
mkdir -p $T
cp "$DISK" $T/disk.img
W='\033W'
printf "ws\n$W$W$W${W}echo ws-term-ok > wsmark\n$W\033pwm\n$W$W\033pwclock\n$W$W\033\n$W${W}ps\n$W\0332$W\033q$W$W\0331$W\033Qcat wsmark\nws\n$W$W$W${W}cores\n$W$W\033H" > $T/keys
$BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/frame.ppm -d $T/disk.img -i $T/keys "$ROM" > $T/out.txt 2>&1 || {
  echo "test-ws: FAILED: the emulator exited with an error"; tail -5 $T/out.txt; exit 1; }
fail() { echo "test-ws: FAILED: $1"; tail -20 $T/out.txt; exit 1; }
grep -q '^ws: stopped' $T/out.txt || fail "ws did not quit to the shell"
grep -q '^ws-term-ok' $T/out.txt || fail "the command typed into the terminal did not run"
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
