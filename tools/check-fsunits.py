#!/usr/bin/env python3
# check-fsunits.py IMAGE [SLOT]: the code units in an image's .far section obey
# the first rule of os/servers/fsunits.s: every pc-relative jump, branch and
# call stays inside its own unit (SLOT bytes, 2048 unless given). A unit runs
# in whatever slot of the code cache it was paged into, so a jump into
# another unit would land in whatever that slot holds. (A jump between the
# .text and .far sections does not assemble at all.) Prints the units' sizes.
import struct, sys
img = open(sys.argv[1], "rb").read()
slot = int(sys.argv[2]) if len(sys.argv) > 2 else 2048
assert img[:4] == b"STX2", "not an STX2 image"
off, bad, seen = 8, 0, 0
for _ in range(struct.unpack_from("<I", img, 4)[0]):
    kind, base, size, _r = struct.unpack_from("<IIII", img, off)
    body = img[off + 16:off + 16 + size]
    off += 16 + size
    if kind != 3: continue                 # the far section
    seen = 1
    for i in range(0, size - size % 4, 4):
        w, = struct.unpack_from("<I", body, i)
        op = w >> 26
        if op == 0x28: d = (w & 0x1FFFFF) - (1 << 21 if w & 0x100000 else 0)      # jal
        elif 0x20 <= op <= 0x25: d = (w & 0xFFFF) - (1 << 16 if w & 0x8000 else 0)  # branches
        else: continue
        a = base + i
        t = a + 4 * d
        if a // slot != t // slot:
            print("%s: the jump at far 0x%x leaves its unit (to 0x%x)" % (sys.argv[1], a, t))
            bad += 1
    used = []
    for u in range(0, size, slot):
        b = body[u:u + slot].rstrip(b"\0")
        used.append(len(b) + 3 & ~3)
    print("%s: %d code units of %d bytes: %s bytes used" % (sys.argv[1], len(used), slot, " ".join(map(str, used))))
if not seen: print("%s: no code units" % sys.argv[1])
sys.exit(1 if bad else 0)
