# check-units.py IMAGE: the compiler's code units obey the rules of cc.s.
# Every jump and branch in the `.far` section must stay inside its own 4 KiB
# unit: a unit runs in whatever slot it was paged into, so a pc-relative jump
# into another unit lands in whatever that slot holds.
import struct, sys
img = open(sys.argv[1], "rb").read()
assert img[:4] == b"STX2"
off, bad = 8, 0
for _ in range(struct.unpack_from("<I", img, 4)[0]):
    kind, base, size, _r = struct.unpack_from("<IIII", img, off)
    body = img[off + 16:off + 16 + size]; off += 16 + size
    if kind != 3: continue
    for i in range(0, size, 4):
        w, = struct.unpack_from("<I", body, i)
        op = w >> 26
        if op == 0x28: d = (w & 0x1FFFFF) - (1 << 21 if w & 0x100000 else 0)
        elif 0x20 <= op <= 0x25: d = (w & 0xFFFF) - (1 << 16 if w & 0x8000 else 0)
        else: continue
        a = base + i; t = a + 4 * d
        if a >> 12 != t >> 12:
            print("%s: jump at far 0x%x leaves its unit (target 0x%x)" % (sys.argv[1], a, t)); bad += 1
    print("%s: %d code units, %d bytes" % (sys.argv[1], (size + 4095) // 4096, size))
sys.exit(1 if bad else 0)
