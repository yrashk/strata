#!/bin/sh
# vi-shots.sh: pictures of vi in the window server's terminal, headless.
#
#   tools/vi-shots.sh [bootrom.stx disk.img]      -> build/vi-shots/asm.png, forth.png
#   tools/vi-shots.sh -f [bootrom.stx disk.img]   -> build/vi-shots/fs-asm.png, fs-forth.png
#                                                    (the same, with the Forth port: forth vi.fs)
#
# Boots StrataOS on the emulator (12 cores, no window) with scripted keys, as
# tools/test-ws.sh does: `ws` from the shell, then in its first terminal vi
# on a file, a few keys, and Alt+Shift+H, which halts the machine with the
# desktop on the screen; -F keeps the last frame (PPM), which is written out
# as a PNG (python3, no other modules). In the script, Alt+Shift+W
# (ESC [ 27 ; 3 ; 87 ~, spec 1.4) makes ws ignore the keyboard for a second
# (time for vi to start and draw); the space after the first ones dismisses
# the key help. Alt+Shift+H is ESC [ 27 ; 3 ; 72 ~.
set -e
VI=vi; P=; WAIT=
if [ "${1:-}" = "-f" ]; then VI="forth vi.fs"; P=fs-; WAIT='\033W\033W\033W'; shift; fi
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/disk.img}
T=$BUILD/vi-shots
mkdir -p $T
W='\033[27;3;87~'                       # Alt+Shift+W
shot() {                                # shot NAME KEYS: the frame after KEYS typed in a terminal
  printf "ws\n$W$W$W${W} $2$W$W$W\033[27;3;72~" > $T/$1.keys
  cp "$DISK" $T/disk.img
  $BUILD/strata-emu -c 12 -g none -m 60000000000 -F $T/$1.ppm -d $T/disk.img -i $T/$1.keys "$ROM" > $T/$1.out 2>&1 || {
    echo "vi-shots: the emulator failed ($1)"; tail -5 $T/$1.out; exit 1; }
  python3 - $T/$1.ppm $T/$1.png <<'PY'
import struct, sys, zlib
b = open(sys.argv[1], "rb").read()
p = b.split(b"\n", 3)                   # P6, "W H", 255, pixels
w, h = map(int, p[1].split())
rows = b"".join(b"\0" + p[3][y * w * 3:(y + 1) * w * 3] for y in range(h))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
PY
  rm -f $T/disk.img $T/$1.ppm
  echo "vi-shots: $T/$1.png"
}
# assembly: line numbers, then a new line being typed (insert mode)
shot ${P}asm "$VI /src/demo/hello.s\n$W$WAIT:set nu\n30Go        addi  t1, t1, 8           ; a new line, typed"
# Forth: the Mandelbrot demo, its inner loop (locals, control words, a ( comment)
shot ${P}forth "$VI gfx.fs\n${W}${WAIT}40G"
