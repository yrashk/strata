#!/bin/sh
# test-wdoom.sh: wdoom, the first-person shooter, on the real kernel, headless.
#
#   tools/test-wdoom.sh bootrom.stx disk.img
#
# Two sessions on the emulator (12 cores, no window), with scripted keys:
# 1. `ws wdoom demo` from the shell: the window server starts with wdoom in
#    a full-size tile, and wdoom plays its recorded demo (through the first
#    door, a zombie shot, a second one in view), one tic a frame whatever
#    the clock says, then stands still and reports its frame rate.
#    Alt+Shift+H halts the machine with that picture on the screen. Checked:
#    the report, and the picture itself: the 960 x 600 pixels of the game
#    (320 x 200 at three times) must have the expected checksum.
# 2. `ws wdoom` on a machine with the sound device (-A: what it plays goes
#    to a WAV file): Space fires the pistol, q ends the game; the window
#    server then opens a terminal, where a command leaves a file;
#    Alt+Shift+Q, and the shell shows the file. Checked: the platform
#    table's tenth entry, the file, and that the WAV holds the shot.
# The checksum changes with the level, the demo, the art or the renderer:
# when one of those is changed on purpose, look at $BUILD/test-wdoom/frame.ppm
# and put the number the test prints into WDOOM_CRC below.
# (Alt+Shift+W: ws ignores the keyboard for a second; the space after the
# start dismisses the key help. See tools/test-ws.sh.)
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
WDOOM_CRC=f26ff1e3
T=$BUILD/test-wdoom
mkdir -p $T
W='\033[27;3;87~'                       # Alt+Shift+W
AQ='\033[27;3;81~' AH='\033[27;3;72~'   # Alt+Shift+Q, Alt+Shift+H
fail() { echo "test-wdoom: FAILED: $1"; tail -20 $T/$2.txt; exit 1; }

# ---- 1. the demo and its last frame
cp "$DISK" $T/disk.img
printf "ws wdoom demo\n$W$W$W$W$W$W $W${AH}" > $T/keys1
$BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/frame.ppm -d $T/disk.img -i $T/keys1 "$ROM" > $T/out1.txt 2>&1 || {
  echo "test-wdoom: FAILED: the emulator exited with an error"; tail -5 $T/out1.txt; exit 1; }
grep -q '^wdoom: demo: [0-9]* frames in ' $T/out1.txt || fail "the demo did not play to its end" out1
grep -q 'all cores halted' $T/out1.txt || fail "the window server did not halt the machine" out1
if grep -q 'fault\|panic' $T/out1.txt; then fail "a fault was reported" out1; fi
[ -s $T/frame.ppm ] || fail "no frame was presented" out1
python3 - $T/frame.ppm $WDOOM_CRC <<'PY' || fail "the demo's last frame is not the expected picture" out1
import sys, zlib
b = open(sys.argv[1], 'rb').read()
p = b.split(b'\n', 3)                      # P6, "W H", 255, pixels
w, h = map(int, p[1].split())
px = p[3]
gw, gh = 960, 600                          # the game: 320 x 200, three times
x0, y0 = 160, 116                          # centred in the full-size tile's client area
crc = zlib.crc32(b''.join(px[((y0 + y) * w + x0) * 3:((y0 + y) * w + x0 + gw) * 3] for y in range(gh)))
print("frame %dx%d: game picture crc %08x (expected %s)" % (w, h, crc, sys.argv[2]))
sys.exit(0 if (w, h) == (1280, 800) and "%08x" % crc == sys.argv[2] else 1)
PY

# ---- 2. sound, q, and the window server after it
cp "$DISK" $T/disk.img
printf "ws wdoom\n$W$W$W$W $W $W${W}q$W$W${W}echo wdoom-q-ok > wdmark\n$W${AQ}cat wdmark\n" > $T/keys2
$BUILD/strata-emu -c 12 -g none -m 40000000000 -A $T/sound.wav -d $T/disk.img -i $T/keys2 "$ROM" > $T/out2.txt 2>&1 || {
  echo "test-wdoom: FAILED: the emulator exited with an error (sound)"; tail -5 $T/out2.txt; exit 1; }
grep -q '^platform: 12 cores, 10 entries' $T/out2.txt || fail "the platform table has no sound device" out2
grep -q '^  sound    0 space 4 base 0x0000000000004300' $T/out2.txt || fail "the boot ROM did not list the sound device" out2
grep -q '^wdoom-q-ok' $T/out2.txt || fail "q did not end wdoom (no terminal took the command after it)" out2
grep -q '^ws: stopped' $T/out2.txt || fail "ws did not quit to the shell" out2
if grep -q 'fault\|panic' $T/out2.txt; then fail "a fault was reported" out2; fi
python3 - $T/sound.wav <<'PY' || fail "the sound device did not play the pistol shot" out2
import sys, wave, struct
w = wave.open(sys.argv[1])
d = w.readframes(w.getnframes())
s = struct.unpack('<%dh' % (len(d) // 2), d)
loud = sum(1 for v in s if abs(v) > 1000)
print("sound: %d Hz, %d samples, %d of them loud" % (w.getframerate(), len(s), loud))
sys.exit(0 if w.getframerate() == 11025 and w.getnchannels() == 1 and loud > 1000 else 1)
PY
echo "test-wdoom: ok"
