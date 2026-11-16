#!/usr/bin/env python3
"""Splits the assembled Stralog into the program and its code units, and
checks the units.

  python3 mkimg.py stralog.stx stralog.map PROGRAM UNITS

PROGRAM is the image without its far section (the I-LS and D-LS sections:
what the kernel loads, at most 128 KiB); UNITS is the far section's bytes
from arena offset 0, which the program reads into its arena at start-up.

Every unit is a label u_NAME, on a 4 KiB boundary, and a label u_NAME_end
no more than 4 KiB after it; no jump or branch between the two may leave
the unit (a unit runs in whatever slot it was paged into).
"""
import struct, sys

stx, mapf, prog, units = sys.argv[1:5]
img = open(stx, 'rb').read()
assert img[:4] == b'STX2'
n, = struct.unpack_from('<I', img, 4)
off, keep, far = 8, [], None
for _ in range(n):
    kind, base, size, r = struct.unpack_from('<IIII', img, off)
    body = img[off + 16:off + 16 + size]
    if kind == 3:
        far = (base, body)
    else:
        keep.append((kind, base, size, r, body))
    off += 16 + size

sym = {}
for line in open(mapf):
    p = line.split()
    if len(p) == 4 and p[0] == 'sym':
        sym[p[3]] = int(p[2], 16)

bad = 0
base, body = far
if base != 0:
    print(f'{stx}: the far section starts at {base:#x}, not 0'); bad += 1
data = bytes(base) + body
nunits = 0
for name, a in sorted(sym.items(), key=lambda kv: kv[1]):
    if not name.startswith('u_') or name.endswith('_end'):
        continue
    e = sym.get(name + '_end')
    if e is None:
        print(f'{stx}: {name} has no {name}_end'); bad += 1; continue
    nunits += 1
    if a % 4096:
        print(f'{stx}: {name} at {a:#x} is not on a 4 KiB boundary'); bad += 1
    if e - a > 4096:
        print(f'{stx}: {name} is {e - a} bytes, more than 4 KiB'); bad += 1
    for i in range(a, min(e, len(data)), 4):
        w, = struct.unpack_from('<I', data, i)
        op = w >> 26
        if op == 0x28:
            d = (w & 0x1FFFFF) - (1 << 21 if w & 0x100000 else 0)
        elif 0x20 <= op <= 0x25:
            d = (w & 0xFFFF) - (1 << 16 if w & 0x8000 else 0)
        else:
            continue
        t = i + 4 * d
        if a >> 12 != t >> 12:
            near = max((k for k, v in sym.items() if v <= i and not k.startswith('u_')),
                       key=lambda k: sym[k], default='?')
            print(f'{stx}: {name}: jump at {i:#x} (after {near}) leaves its unit (target {t:#x})'); bad += 1

out = bytearray(b'STX2' + struct.pack('<I', len(keep)))
for kind, b, size, r, body in keep:
    out += struct.pack('<IIII', kind, b, size, r) + body
if len(out) > 128 * 1024:
    print(f'{prog}: {len(out)} bytes, more than 128 KiB'); bad += 1
if bad:
    sys.exit(1)
open(prog, 'wb').write(out)
open(units, 'wb').write(data)
print(f'{prog}: {len(out)} bytes; {units}: {len(data)} bytes, {nunits} code units')
