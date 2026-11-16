#!/bin/sh
# test-wdb.sh: wdb, the store's trees in a window, on the real kernel, headless.
#
#   tools/test-wdb.sh bootrom.stx disk.img
#
# Boots StrataOS on the emulator (12 cores, no window) with scripted keys,
# as test-ws.sh does: `ws`, then wdb through the palette (Alt+P), keys for
# wdb, and Alt+Shift+H, which halts with the desktop on the screen (-F
# writes that frame). Four sessions:
#   list    wdb as it opens: the list of trees
#   page    Enter on the list's first row (the catalog): its root page
#   back    the same and Backspace: the list again
#   quit    wdb ended with its own `q`: the tile is gone, nothing faults
# The frames are compared below the status strip: `list` and `back` must be
# the same picture, `page` another one, each with text in it; after `quit`
# there is no text left.
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
T=$BUILD/test-wdb
mkdir -p $T
W='\033[27;3;87~'                       # Alt+Shift+W: ws ignores the keyboard for a second
AP='\033[27;3;112~'                     # Alt+P: the palette
AH='\033[27;3;72~'                      # Alt+Shift+H: halt
fail() { echo "test-wdb: FAILED: $1"; tail -20 $T/$2.txt; exit 1; }
run() { # run NAME KEYS-FOR-WDB
  cp "$DISK" $T/disk.img
  printf "ws\n$W$W$W${W} ${AP}wdb\n$W$W$W$2$W$W${AH}" > $T/$1.keys
  $BUILD/strata-emu -c 12 -g none -m 40000000000 -F $T/$1.ppm -d $T/disk.img -i $T/$1.keys "$ROM" > $T/$1.txt 2>&1 ||
    fail "the emulator exited with an error ($1)" $1
  grep -q 'all cores halted' $T/$1.txt || fail "the machine did not halt ($1)" $1
  if grep -q 'fault\|panic\|wdb: ' $T/$1.txt; then fail "a fault or an error was reported ($1)" $1; fi
  [ -s $T/$1.ppm ] || fail "no frame was presented ($1)" $1
}
run list ''
run page '\n'
run back '\n\177'
run quit 'q'
python3 - $T <<'PY' || { echo "test-wdb: FAILED: the frames are not what the keys should give"; exit 1; }
import sys
def frame(name):
    b = open("%s/%s.ppm" % (sys.argv[1], name), 'rb').read()
    p = b.split(b'\n', 3)                  # P6, "W H", 255, pixels
    w, h = map(int, p[1].split())
    return w, p[3][44 * w * 3:]            # below the status strip and the tile's tag (figures that tick)
def lit(px):                               # pixels that are not of the commonest colour
    from collections import Counter
    c = Counter(px[i:i + 3] for i in range(0, len(px), 3))
    return len(px) // 3 - c.most_common(1)[0][1], len(c)
w, a = frame("list"); _, p = frame("page"); _, k = frame("back"); _, q = frame("quit")
la, lp, lq = lit(a), lit(p), lit(q)
diff = sum(1 for i in range(0, len(a), 3) if a[i:i + 3] != p[i:i + 3])
same = sum(1 for i in range(0, len(a), 3) if a[i:i + 3] != k[i:i + 3])
print("list: %d lit pixels; page: %d; they differ in %d; back differs from list in %d; after q: %d lit" % (la[0], lp[0], diff, same, lq[0]))
ok = la[0] > 3000 and lp[0] > 3000 and diff > 2000 and same == 0 and lq[0] < la[0] // 2
sys.exit(0 if ok else 1)
PY
echo "test-wdb: ok    the list of trees, a tree's root page, back to the list, quit"
