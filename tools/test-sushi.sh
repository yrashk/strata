#!/bin/sh
# test-sushi.sh: sushi, SushiBelt, on the real kernel, headless.
#
#   tools/test-sushi.sh bootrom.stx disk.img
#
# Sessions on the emulator (12 cores, no window), with scripted input:
# 1. `ws sushi demo N` for each demo (tools/sushi-assets.py: DEMOS): the
#    window server starts with sushi in a full-size tile, and sushi plays the
#    demo's keys and clicks one tic a frame whatever the clock says (or, where
#    the demo says so, a run of tics without drawing them), then stands still
#    and says how long it took. Alt+Shift+H halts the machine with that
#    picture on the screen. Checked: the report, and the picture itself: the
#    960 x 600 pixels of the game (320 x 200 at three times) must have the
#    expected checksum.
#      demo 1  the title
#      demo 2  how to play: a card over the room
#      demo 3  ... its second page: the three cooks, what each is fast at
#      demo 4  the evening begins: the first customers come in and sit down
#      demo 5  orders given to the cooks with 1 2 3: the cooks make them
#              (the piece in hand beside each cook), the first plate rides
#              the belt; the bubbles show which cook has their order
#      demo 6  ... with the mouse: a bubble, then a cook in the kitchen; a
#              bubble, then a cook's queue in the bar; customers served, paid
#      demo 7  one order given twice (the second time chosen with an arrow);
#              the first plate is swept off the belt by a click as it leaves
#              the cook (a cloud of dust)
#      demo 8  one order given six times: the plates nobody takes ride on,
#              tire and go stale (flies) through the first rush; Z sweeps
#              the oldest off
#      demo 9  nobody is served: the first customer waits too long and goes,
#              cross (steam), as the first rush brings a crowd
#      demo a  a whole evening with every order given to every cook at once:
#              the bar closes at 22:00 and the results are shown
#      demo b  I: the card of how you earn, I again: the owner's card, with
#              his times and his queue (the evening waits behind it)
#      demo c  a click on a cook's face in the bar opens their card, a key
#              closes it; a click on the money opens how you earn
#      demo d  a customer pays: the price and the tip rise over them, and
#              the bar counts the pieces served in a row
#      demo e  18:00, the first rush: the card of the busy hours opens over
#              the evening (the sign by the door, sets, VIPs)
#      demo f  the rush once the card is closed: RUSH by the door, the
#              banner on the floor, the clock on red, every seat taken
#      demo g  later in it: a set (two pieces) in a bubble and a cook's
#              queue, VIPs' stars, plates stacked beside those who ate
#      demo h  the restaurant's file is used: a whole evening as in demo a,
#              then the shop: the tea station and the eel bought from the
#              till, the inside-out roll chosen (what it does is shown)
#    (A demo's random numbers start from a fixed seed, so its customers and
#    their orders are always the same.)
#    In section 3 these run after demo h on its disk, in the same session
#    (ws quit with Alt+Shift+Q, then started again), so the file it wrote
#    is there:
#      demo i  the title: day 2, the till, N for a new bar
#      demo j  day 2: straight into the evening (no pages of how to play);
#              eel on the menu, on a gold plate
# 2. `ws sushi` on a machine with the sound device (-A: what it plays goes
#    to a WAV file) and a pointer (-P): a click on the title shows how to
#    play, two more turn its page and start the evening, 1 gives the first
#    order to a cook, q ends the program; the
#    window server then opens a terminal, where a command leaves a file;
#    Alt+Shift+Q, and the shell shows the file. Checked: the file, and that
#    the WAV holds the sounds (the door bell, the cook's knife).
# A checksum changes with the art, the rules, the demo or the drawing: when
# one of those is changed on purpose, look at $BUILD/test-sushi/frameN.ppm
# and put the number the test prints into SUSHI_CRC below.
# (Alt+Shift+W: ws ignores the keyboard for a second; the space after the
# start dismisses the key help. See tools/test-ws.sh.)
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
SUSHI_CRC="1:c4ad2efb:6 2:6a9ad6a4:6 3:b3bd9d3e:6 4:729a8d4e:6 5:3f72ea15:8 6:bef84dff:12 7:2a672591:6 8:4f2adf89:6 9:bdeb65f7:6 a:0cc49cf8:6 b:ebd402a7:8 c:1b842428:8 d:0d6d0441:8 e:d933f36a:6 f:89fd7df0:6 g:66f50181:6 h:97a324d9:8"
SUSHI_CRC2="i:77333980 j:c17606ce"
T=$(mktemp -d "${TMPDIR:-/tmp}/test-sushi.XXXXXX")
OUT=$BUILD/test-sushi
mkdir -p $OUT
trap 'rm -rf "$T"' EXIT
W='\033[27;3;87~'                       # Alt+Shift+W
AQ='\033[27;3;81~' AH='\033[27;3;72~'   # Alt+Shift+Q, Alt+Shift+H
fail() { echo "test-sushi: FAILED: $1"; tail -20 $OUT/$2.txt; exit 1; }

# ---- 1. the demos and their last frames
for d in $SUSHI_CRC; do                 # demo:checksum:seconds it is given
  n=${d%%:*}
  crc=${d#*:}; crc=${crc%%:*}
  cp "$DISK" $T/disk.img
  WW=""; i=0; while [ $i -lt ${d##*:} ]; do WW="$WW$W"; i=$((i + 1)); done
  printf "ws sushi demo $n\n$W$W$W$W $W$WW${AH}" > $T/keys
  $BUILD/strata-emu -c 12 -g none -m 40000000000 -F $OUT/frame$n.ppm -d $T/disk.img -i $T/keys "$ROM" > $OUT/out$n.txt 2>&1 || {
    echo "test-sushi: FAILED: the emulator exited with an error (demo $n)"; tail -5 $OUT/out$n.txt; exit 1; }
  grep -q '^sushi: demo: [0-9]* frames in ' $OUT/out$n.txt || fail "demo $n did not play to its end" out$n
  grep -q 'all cores halted' $OUT/out$n.txt || fail "the window server did not halt the machine" out$n
  if grep -q 'fault\|panic' $OUT/out$n.txt; then fail "a fault was reported" out$n; fi
  [ -s $OUT/frame$n.ppm ] || fail "no frame was presented" out$n
  python3 - $OUT/frame$n.ppm $crc $n <<'PY' || fail "the last frame of demo $n is not the expected picture" out$n
import sys, zlib
b = open(sys.argv[1], 'rb').read()
p = b.split(b'\n', 3)                      # P6, "W H", 255, pixels
w, h = map(int, p[1].split())
px = p[3]
gw, gh = 960, 600                          # the game: 320 x 200, three times
x0, y0 = 160, 116                          # centred in the full-size tile's client area
crc = zlib.crc32(b''.join(px[((y0 + y) * w + x0) * 3:((y0 + y) * w + x0 + gw) * 3] for y in range(gh)))
print("demo %s: frame %dx%d: game picture crc %08x (expected %s)" % (sys.argv[3], w, h, crc, sys.argv[2]))
sys.exit(0 if (w, h) == (1280, 800) and "%08x" % crc == sys.argv[2] else 1)
PY
done

# ---- 2. the pointer, sound, q, and the window server after it
cp "$DISK" $T/disk.img
START="ws sushi\n$W$W$W$W $W"
printf "$START$W$W${W}1$W$W${W}q$W$W${W}echo sushi-q-ok > smark\n$W${AQ}cat smark\n" > $T/keys
N=$(printf "$START" | wc -c | tr -d ' ')
N1=$((N + 10)) N2=$((N + 20))           # (one Alt+Shift+W later, and two)
printf "k$N move 640 416\nk$N down 0\nk$N up 0\nk$N1 down 0\nk$N1 up 0\nk$N2 down 0\nk$N2 up 0\n" > $T/ptr   # the title, how to play's two pages: the evening
$BUILD/strata-emu -c 12 -g none -m 40000000000 -A $OUT/sound.wav -P $T/ptr -d $T/disk.img -i $T/keys "$ROM" > $OUT/outp.txt 2>&1 || {
  echo "test-sushi: FAILED: the emulator exited with an error (pointer, sound)"; tail -5 $OUT/outp.txt; exit 1; }
grep -q '^sushi-q-ok' $OUT/outp.txt || fail "q did not end sushi (no terminal took the command after it)" outp
grep -q '^ws: stopped' $OUT/outp.txt || fail "ws did not quit to the shell" outp
if grep -q 'fault\|panic' $OUT/outp.txt; then fail "a fault was reported" outp; fi
python3 - $OUT/sound.wav <<'PY' || fail "the sound device did not play the evening's sounds" outp
import sys, wave, struct
w = wave.open(sys.argv[1])
d = w.readframes(w.getnframes())
s = struct.unpack('<%dh' % (len(d) // 2), d)
loud = sum(1 for v in s if abs(v) > 1000)
print("sound: %d Hz, %d samples, %d of them loud" % (w.getframerate(), len(s), loud))
sys.exit(0 if w.getframerate() == 11025 and w.getnchannels() == 1 and loud > 1000 else 1)
PY

# ---- 3. the restaurant kept: demo h writes /ws/sushi.sav, demos i and j read it
for d in $SUSHI_CRC2; do
  n=${d%%:*} crc=${d#*:}
  cp "$DISK" $T/disk.img
  printf "ws sushi demo h\n$W$W$W$W $W$W$W$W$W$W${W}q$W$W$W${AQ}ws sushi demo $n\n$W$W$W$W $W$W$W$W$W$W$W$W${AH}" > $T/keys
  $BUILD/strata-emu -c 12 -g none -m 40000000000 -F $OUT/frame$n.ppm -d $T/disk.img -i $T/keys "$ROM" > $OUT/out$n.txt 2>&1 || {
    echo "test-sushi: FAILED: the emulator exited with an error (demo $n)"; tail -5 $OUT/out$n.txt; exit 1; }
  [ "$(grep -c '^sushi: demo: [0-9]* frames in ' $OUT/out$n.txt)" = 2 ] || fail "demo h, then demo $n, did not play to their ends" out$n
  grep -q '^ws: stopped' $OUT/out$n.txt || fail "ws did not quit between the demos" out$n
  if grep -q 'fault\|panic' $OUT/out$n.txt; then fail "a fault was reported" out$n; fi
  python3 - $OUT/frame$n.ppm $crc $n <<'PY' || fail "the last frame of demo $n is not the expected picture" out$n
import sys, zlib
b = open(sys.argv[1], 'rb').read()
p = b.split(b'\n', 3)
w, h = map(int, p[1].split())
px = p[3]
crc = zlib.crc32(b''.join(px[((116 + y) * w + 160) * 3:((116 + y) * w + 160 + 960) * 3] for y in range(600)))
print("demo %s (after h): frame %dx%d: game picture crc %08x (expected %s)" % (sys.argv[3], w, h, crc, sys.argv[2]))
sys.exit(0 if (w, h) == (1280, 800) and "%08x" % crc == sys.argv[2] else 1)
PY
done
echo "test-sushi: ok"
