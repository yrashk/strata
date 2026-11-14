#!/bin/sh
# test-kira.sh: kira, Princess Kira's games, on the real kernel, headless.
#
#   tools/test-kira.sh bootrom.stx disk.img
#
# Sessions on the emulator (12 cores, no window), with scripted input:
# 1. `ws kira demo N` for each demo (tools/kira-assets.py: DEMOS): the window
#    server starts with kira in a full-size tile, and kira plays the demo's
#    keys and clicks one tic a frame whatever the clock says, then stands
#    still and says how long it took. Alt+Shift+H halts the machine with
#    that picture on the screen. Checked: the report, and the picture
#    itself: the 960 x 600 pixels of the game (320 x 200 at three times)
#    must have the expected checksum.
#      demo 1  Friends from above: a click on the duck's cell: Kira walks
#              there and the duck is found; three steps with the arrow keys
#      demo 2  the hand is moved to FRIENDS with the arrows and pressed;
#              all friends found; a step onto the picnic blanket: the party;
#              a key: a new game in a new world
#      demo 3  Friends through Kira's eyes: quarter turns (a turning key that
#              repeats during a turn does nothing) and steps
#      demo 4  ... and the party seen so
#      demo 5  Garden: a daisy is sown and watered into bloom (a butterfly
#              comes); the garden is left (and written to its file) and
#              come back to
#      demo 6  Paint: two regions are filled, the next page, one more
#      demo 7  Music: a bar struck by a click, one by a key, a friend's
#              voice, a song
#      demo 8  sixty games of Friends one after another, each in a new world
#              (all friends found, a step onto the blanket, a key)
#    (A demo's random numbers start from a fixed seed, so its worlds, its
#    butterflies and its song are always the same ones.)
# 2. `ws kira` on a machine with the sound device (-A: what it plays goes
#    to a WAV file) and a pointer (-P): a click on MUSIC, clicks on two of
#    the xylophone's bars, q ends the program; the window server then opens
#    a terminal, where a command leaves a file; Alt+Shift+Q, and the shell
#    shows the file. Checked: the file, and that the WAV holds the notes.
# A checksum changes with the art, the world, the demo or the drawing: when
# one of those is changed on purpose, look at $BUILD/test-kira/frameN.ppm
# and put the number the test prints into KIRA_CRC below.
# (Alt+Shift+W: ws ignores the keyboard for a second; the space after the
# start dismisses the key help. See tools/test-ws.sh.)
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
KIRA_CRC="1:10875dd2:6 2:b28d0fb6:4 3:a4a6212e:6 4:e8e347e2:6 5:e654c81a:4 6:8ac2eeac:4 7:453116f1:4 8:bb71d3b4:40"
T=$BUILD/test-kira
mkdir -p $T
W='\033[27;3;87~'                       # Alt+Shift+W
AQ='\033[27;3;81~' AH='\033[27;3;72~'   # Alt+Shift+Q, Alt+Shift+H
fail() { echo "test-kira: FAILED: $1"; tail -20 $T/$2.txt; exit 1; }

# ---- 1. the demos and their last frames (the machines run at the same time,
#         each with its own disk; then each is checked)
for d in $KIRA_CRC; do                  # demo:checksum:seconds it is given
  n=${d%%:*}
  cp "$DISK" $T/disk$n.img
  WW=""; i=0; while [ $i -lt ${d##*:} ]; do WW="$WW$W"; i=$((i + 1)); done
  printf "ws kira demo $n\n$W$W$W$W $W$WW${AH}" > $T/keys$n
  { $BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/frame$n.ppm -d $T/disk$n.img -i $T/keys$n "$ROM" > $T/out$n.txt 2>&1
    echo $? > $T/rc$n; } &
done
wait
for d in $KIRA_CRC; do
  n=${d%%:*}
  crc=${d#*:}; crc=${crc%%:*}
  [ "$(cat $T/rc$n)" = 0 ] || {
    echo "test-kira: FAILED: the emulator exited with an error (demo $n)"; tail -5 $T/out$n.txt; exit 1; }
  grep -q '^kira: demo: [0-9]* frames in ' $T/out$n.txt || fail "demo $n did not play to its end" out$n
  grep -q 'all cores halted' $T/out$n.txt || fail "the window server did not halt the machine" out$n
  if grep -q 'fault\|panic' $T/out$n.txt; then fail "a fault was reported" out$n; fi
  [ -s $T/frame$n.ppm ] || fail "no frame was presented" out$n
  python3 - $T/frame$n.ppm $crc $n <<'PY' || fail "the last frame of demo $n is not the expected picture" out$n
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
START="ws kira\n$W$W$W$W $W"
printf "$START$W$W$W${W}q$W$W${W}echo kira-q-ok > kmark\n$W${AQ}cat kmark\n" > $T/keys
N=$(printf "$START" | wc -c | tr -d ' ')
N1=$((N + 10)) N2=$((N + 20))           # (one Alt+Shift+W later, and two)
printf "k$N move 874 524\nk$N down 0\nk$N up 0\nk$N1 move 280 416\nk$N1 down 0\nk$N1 up 0\nk$N2 move 688 416\nk$N2 down 0\nk$N2 up 0\n" > $T/ptr   # MUSIC; the first bar; the fifth
$BUILD/strata-emu -c 12 -g none -m 40000000000 -A $T/sound.wav -P $T/ptr -d $T/disk.img -i $T/keys "$ROM" > $T/outp.txt 2>&1 || {
  echo "test-kira: FAILED: the emulator exited with an error (pointer, sound)"; tail -5 $T/outp.txt; exit 1; }
grep -q '^kira-q-ok' $T/outp.txt || fail "q did not end kira (no terminal took the command after it)" outp
grep -q '^ws: stopped' $T/outp.txt || fail "ws did not quit to the shell" outp
if grep -q 'fault\|panic' $T/outp.txt; then fail "a fault was reported" outp; fi
python3 - $T/sound.wav <<'PY' || fail "the sound device did not play the xylophone's notes" outp
import sys, wave, struct
w = wave.open(sys.argv[1])
d = w.readframes(w.getnframes())
s = struct.unpack('<%dh' % (len(d) // 2), d)
loud = sum(1 for v in s if abs(v) > 1000)
print("sound: %d Hz, %d samples, %d of them loud" % (w.getframerate(), len(s), loud))
sys.exit(0 if w.getframerate() == 11025 and w.getnchannels() == 1 and loud > 1000 else 1)
PY
echo "test-kira: ok"
