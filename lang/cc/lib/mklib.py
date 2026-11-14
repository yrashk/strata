# mklib.py OUT LIBC.stx LIBC.map LIBC.s HEADER...: pack cc.lib, the one file cc
# needs beside itself and its code units.
#
#   0   "CCLIB1\0\0"
#   8   directory: 32-byte entries { name[24], u32 offset, u32 size }, ended by
#       an entry whose name is empty; offsets are from the start of the file
#   ... the members, each 8-byte aligned:
#       libc.text   the library's code (I-LS from 0x8000)
#       libc.data   its data (D-LS from 0)
#       libc.sym    its exported names: 24-byte records { name[20], u32 address }
#                   for every `.global NAME` of libc.s, addresses from sasm's map
#       NAME.h      the headers
#       asm.tab     the instructions of asm("...") (mkasm.py)
#       NAME.c      library functions as C source (lib/src): cc reads one from
#                   the file when a program needs it. What comes before them
#                   is what cc keeps in its arena, in 32 KiB.
#       cc.units    the compiler's own code units (the T3 section of the image
#                   sasm made of cc.s); always the last member: cc copies it to
#                   the bottom of its arena at start-up and pages its code from
#                   there. With `--cc FULL.stx PROG` the image is split: PROG gets
#                   the Local Store sections, cc.lib this member (an image holds
#                   at most 128 KiB, and the compiler is larger).
import struct, sys, os, re
ccfull = ccprog = None
if sys.argv[1] == "--cc":
    ccfull, ccprog = sys.argv[2:4]; del sys.argv[1:4]
out, stx, mp, src = sys.argv[1:5]
img = open(stx, "rb").read()
assert img[:4] == b"STX2"
sect = {}
off = 8
for _ in range(struct.unpack_from("<I", img, 4)[0]):
    kind, base, size, _r = struct.unpack_from("<IIII", img, off)
    sect[kind] = (base, img[off + 16:off + 16 + size]); off += 16 + size
assert sect[1][0] == 0x8000 and sect[2][0] == 0, "libc must start at I-LS 0x8000 and D-LS 0"
addr = {}
for line in open(mp):
    f = line.split()
    if len(f) == 4 and f[0] == "sym": addr[f[3]] = int(f[2], 16)
sym = b""
for name in re.findall(r"^\s*\.global\s+(\w+)", open(src).read(), re.M):
    assert len(name) < 20, name
    sym += name.encode().ljust(20, b"\0") + struct.pack("<I", addr[name])
members = [("libc.text", sect[1][1]), ("libc.data", sect[2][1]), ("libc.sym", sym)]
for h in sorted(sys.argv[5:], key=lambda f: f.endswith(".c")):
    members.append((os.path.basename(h), open(h, "rb").read()))
if ccfull:
    full = open(ccfull, "rb").read()
    assert full[:4] == b"STX2"
    keep, o = [], 8
    for _ in range(struct.unpack_from("<I", full, 4)[0]):
        kind, base, size, _r = struct.unpack_from("<IIII", full, o)
        if kind == 3:
            assert base == 0, "the compiler's units must start at arena offset 0"
            members.append(("cc.units", full[o + 16:o + 16 + size]))
        else:
            keep.append(full[o:o + 16 + size])
        o += 16 + size
    open(ccprog, "wb").write(b"STX2" + struct.pack("<I", len(keep)) + b"".join(keep))
pos = 8 + 32 * (len(members) + 1)
dirb, body = b"", b""
insrc = False
for name, data in members:
    assert len(name) < 24, name
    if name.endswith(".c") and not insrc:
        insrc = True
        assert pos <= 0x8000, "cc.lib: the library and the headers must fit 32 KiB"
    dirb += name.encode().ljust(24, b"\0") + struct.pack("<II", pos, len(data))
    data += b"\0" * (-len(data) % 8)
    body += data; pos += len(data)
open(out, "wb").write(b"CCLIB1\0\0" + dirb + b"\0" * 32 + body)
