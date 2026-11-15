#!/bin/sh
# test-plat.sh: plat, the city-building game, on the real kernel, headless.
#
#   tools/test-plat.sh bootrom.stx disk.img
#
# Sessions on the emulator (12 cores, no window), with scripted input:
# 1. `ws plat demo N` for each demo (tools/plat-assets.py: DEMOS): the window
#    server starts with plat in a full-size tile, and plat plays the demo's
#    keys one tic a frame whatever the clock says, then stands still and
#    says how long it took, what the treasury holds, the date, the census
#    and a checksum of the map. Alt+Shift+H halts the machine with that picture
#    on the screen. Checked: the report, and the picture itself: the
#    window's 1252 x 740 pixels must have the expected checksum.
#      demo 1  a road drawn with the keyboard's pen round a block and west
#              across the river (a bridge), a power line along the block
#              and across both its roads, cells bulldozed, a cell asked
#              about, the view zoomed in, moved and zoomed out
#      demo 2  the fastest speed for two years, then the pause
#      demo 3  a road grid larger than the treasury: it stops at 0 and
#              says so
#      demo 4  at 32 pixels a cell: a power line west over the river
#      demo 5  a town: a coal plant, a road, a power line across it, homes,
#              shops and offices, industry, and a zone with neither power
#              nor a road (its mark); two years at the fastest speed: it
#              grows, and the census says how much
#      demo 6  the town in a file: built, a year, saved (the demo says the
#              map's checksum), bulldozed and taxed differently, the saved
#              town loaded again: the map must be the one that was saved
#      demo 7  the fuller city: rail across a road, police and fire
#              stations, a park, a solar plant beside the zones; two
#              years; the budget (less for the police and the fire
#              service); the pollution map over the town
#      demo 8  demo 5's town, and the Plat Ledger on its year
#      demo 9  demo 5's town, and its history (residents, treasury)
#    (An adviser's portrait and words are in the bar in most of them.)
#    (A demo's land comes from a fixed seed, so it is always the same land.)
# 2. `ws plat` on a machine with the sound device (-A: what it plays goes
#    to a WAV file) and a pointer (-P): a road dragged with the left button,
#    the map dragged with the right one and scrolled with the wheel, the
#    power line's button, a line dragged, the fastest speed's button; q ends
#    the program, which saves the town and says what the treasury holds; the
#    window server then opens a terminal, where a command leaves a file;
#    Alt+Shift+Q, and the shell shows the file and the saved town's
#    attributes. Checked: the file, that something was paid for, the
#    attributes, and that the WAV holds sound.
# A checksum changes with the art, the land, the demo or the drawing: when
# one of those is changed on purpose, look at $BUILD/test-plat/frameN.ppm
# and put the numbers the test prints into PLAT_CRC below.
# (Alt+Shift+W: ws ignores the keyboard for a second; the space after the
# start dismisses the key help. See tools/test-ws.sh.)
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
# demo:frame checksum:map checksum:funds:seconds it is given
PLAT_CRC="1:b82894d8:fe18a8eb:19072:6 2:b1aac2a8:84ce65ce:20000:6 3:76a06f9d:52a65110:0:40 4:39915aa9:66999b66:19770:6 5:5d98837e:ea29c68a:17576:12 6:f0ab5e1e:68551d85:16652:10 7:34dadb25:92a2abb7:9077:14 8:81d79295:ea29c68a:17576:12 9:e6e6574a:ea29c68a:17576:12"
T=$BUILD/test-plat
mkdir -p $T
W='\033[27;3;87~'                       # Alt+Shift+W
AQ='\033[27;3;81~' AH='\033[27;3;72~'   # Alt+Shift+Q, Alt+Shift+H
fail() { echo "test-plat: FAILED: $1"; tail -20 $T/$2.txt; exit 1; }

# ---- 1. the demos and their last frames
for d in $PLAT_CRC; do
  n=${d%%:*}; r=${d#*:}
  crc=${r%%:*}; r=${r#*:}
  map=${r%%:*}; r=${r#*:}
  funds=${r%%:*}; secs=${r#*:}
  cp "$DISK" $T/disk.img
  WW=""; i=0; while [ $i -lt $secs ]; do WW="$WW$W"; i=$((i + 1)); done
  printf "ws plat demo $n\n$W$W$W$W $W$WW${AH}" > $T/keys
  $BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/frame$n.ppm -d $T/disk.img -i $T/keys "$ROM" > $T/out$n.txt 2>&1 || {
    echo "test-plat: FAILED: the emulator exited with an error (demo $n)"; tail -5 $T/out$n.txt; exit 1; }
  grep -q '^plat: demo: [0-9]* frames in ' $T/out$n.txt || fail "demo $n did not play to its end" out$n
  grep -q 'all cores halted' $T/out$n.txt || fail "the window server did not halt the machine" out$n
  if grep -q 'fault\|panic' $T/out$n.txt; then fail "a fault was reported" out$n; fi
  grep "^plat: demo:" $T/out$n.txt
  grep -q "^plat: demo: .*; funds $funds; .*; map $map\$" $T/out$n.txt ||
    fail "demo $n did not end with funds $funds and map $map" out$n
  if [ $n = 6 ]; then                   # the saved town came back as it was saved
    grep -q "^plat: saved: map $map\$" $T/out$n.txt || fail "demo 6 did not load the town it saved" out$n
  fi
  [ -s $T/frame$n.ppm ] || fail "no frame was presented" out$n
  python3 - $T/frame$n.ppm $crc $n <<'PY' || fail "the last frame of demo $n is not the expected picture" out$n
import sys, zlib
b = open(sys.argv[1], 'rb').read()
p = b.split(b'\n', 3)                      # P6, "W H", 255, pixels
w, h = map(int, p[1].split())
px = p[3]
gw, gh = 1252, 740                         # the window's client area in a full-size tile
x0, y0 = 14, 46                            # ... and where it is on the screen
crc = zlib.crc32(b''.join(px[((y0 + y) * w + x0) * 3:((y0 + y) * w + x0 + gw) * 3] for y in range(gh)))
print("demo %s: frame %dx%d: window crc %08x (expected %s)" % (sys.argv[3], w, h, crc, sys.argv[2]))
sys.exit(0 if (w, h) == (1280, 800) and "%08x" % crc == sys.argv[2] else 1)
PY
done

# ---- 2. the pointer, sound, q, and the window server after it
cp "$DISK" $T/disk.img
START="ws plat\n$W$W$W$W $W"
printf "$START$W$W$W$W$W${W}q$W$W${W}echo plat-q-ok > pmark\n$W${AQ}cat pmark\nattr /ws/plat.sav\n" > $T/keys
N=$(printf "$START" | wc -c | tr -d ' ')
N1=$((N + 10)) N2=$((N + 20)) N3=$((N + 30)) N4=$((N + 40))   # (one Alt+Shift+W later, two, ...)
cat > $T/ptr <<EOF
k$N move 302 302
k$N down left
k$N move 382 302
k$N move 462 302
k$N up left
k$N1 move 700 400
k$N1 down right
k$N1 move 604 400
k$N1 up right
k$N1 wheel 1
k$N2 move 28 92
k$N2 down left
k$N2 up left
k$N3 move 302 494
k$N3 down left
k$N3 move 302 590
k$N3 up left
k$N4 move 87 769
k$N4 down left
k$N4 up left
EOF
$BUILD/strata-emu -c 12 -g none -m 40000000000 -A $T/sound.wav -P $T/ptr -d $T/disk.img -i $T/keys "$ROM" > $T/outp.txt 2>&1 || {
  echo "test-plat: FAILED: the emulator exited with an error (pointer, sound)"; tail -5 $T/outp.txt; exit 1; }
grep -q '^plat-q-ok' $T/outp.txt || fail "q did not end plat (no terminal took the command after it)" outp
grep -q '^ws: stopped' $T/outp.txt || fail "ws did not quit to the shell" outp
if grep -q 'fault\|panic' $T/outp.txt; then fail "a fault was reported" outp; fi
grep "^plat: funds" $T/outp.txt || fail "plat did not say what the treasury holds" outp
f=$(sed -n 's/^plat: funds \([0-9]*\);.*/\1/p' $T/outp.txt)
[ "$f" -lt 20000 ] || fail "nothing was built with the pointer (funds $f)" outp
grep -q "^funds = $f\$" $T/outp.txt && grep -q "^year = 1900\$" $T/outp.txt && grep -q "^population = 0\$" $T/outp.txt ||
  fail "the saved town's attributes are not its funds, year and population" outp
python3 - $T/sound.wav <<'PY' || fail "the sound device played nothing" outp
import sys, wave, struct
w = wave.open(sys.argv[1])
d = w.readframes(w.getnframes())
s = struct.unpack('<%dh' % (len(d) // 2), d)
loud = sum(1 for v in s if abs(v) > 1000)
print("sound: %d Hz, %d samples, %d of them loud" % (w.getframerate(), len(s), loud))
sys.exit(0 if w.getframerate() == 11025 and w.getnchannels() == 1 and loud > 200 else 1)
PY
echo "test-plat: ok"
