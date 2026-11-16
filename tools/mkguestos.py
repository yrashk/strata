#!/usr/bin/env python3
"""mkguestos.py: StrataOS as a guest image (doc/strataos.md, "StrataOS as a guest").

  mkguestos.py kernel.stx disk.img out.g

The guest loader (os/kunits/guest.s, u_gload) copies an image's I-LS and D-LS
sections into each guest core's Local Stores, its T3 sections into the guest's
writable memory (relative core 0 only), and jumps to the I-LS section's base.
So the guest image is the kernel itself: its code (from KTEXT, the entry), its
data (from KDATA), its code units (the .far section, at memory offset 0, where
the kernel makes its far share of them) and one more T3 section, the disk, at
memory offset RD_OFF: the guest's RAM disk (os/kernel.s, "Guest mode"). The
D-LS section goes last (see below).
"""
import struct
import sys

KTEXT = 0x4000                          # os/kernel.s: kernel code address in the I-LS
KDATA = 0xA000                          # ... kernel data address in the D-LS
RD_OFF = 0x100000                       # ... the RAM disk's offset in the guest's memory
GN_LOW = 0x400000                       # ... the guest's memory below its pool
SK_ILS, SK_DLS, SK_T3 = 1, 2, 3         # STX section kinds (asm/isa.h)


def sections(path):
    d = open(path, 'rb').read()
    if d[:4] != b'STX2':
        sys.exit(f'{path}: not an STX2 image')
    n, = struct.unpack_from('<I', d, 4)
    o, out = 8, []
    for _ in range(n):
        kind, base, size, _r = struct.unpack_from('<4I', d, o)
        out.append((kind, base, d[o + 16:o + 16 + size]))
        o += 16 + size
    return out


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.strip().split('\n\n')[1])
    kern, disk, out = sys.argv[1:]
    secs = []
    for kind, base, data in sections(kern):
        skip = {SK_ILS: KTEXT, SK_DLS: KDATA}.get(kind, 0)   # the stores below these are not the kernel's
        if base < skip:
            if any(data[:skip - base]):
                sys.exit(f'{kern}: section {kind} has bytes below {skip:#x}')
            data, base = data[skip - base:], skip
        secs.append((kind, base, data))
    if not any(k == SK_ILS and b == KTEXT for k, b, _ in secs):
        sys.exit(f'{kern}: no code at {KTEXT:#x}')
    far = sum(len(d) for k, _, d in secs if k == SK_T3)
    if far > RD_OFF:
        sys.exit(f'{kern}: the code units ({far} bytes) reach the RAM disk')
    img = open(disk, 'rb').read()
    if RD_OFF + len(img) > GN_LOW:
        sys.exit(f'{disk}: {len(img)} bytes do not fit the RAM disk ({GN_LOW - RD_OFF})')
    img += bytes(-len(img) % 8)
    secs.append((SK_T3, RD_OFF, img))
    # the D-LS last: the loader reads section headers and bounces T3 sections
    # through D-LS 0xC000, which is the kernel's data once that is loaded
    secs.sort(key=lambda s: s[0] == SK_DLS)
    with open(out, 'wb') as f:
        f.write(b'STX2' + struct.pack('<I', len(secs)))
        for kind, base, data in secs:
            f.write(struct.pack('<4I', kind, base, len(data), 0) + data)


if __name__ == '__main__':
    main()
