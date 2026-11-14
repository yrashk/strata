#!/usr/bin/env python3
"""wdoom-assets.py: the data file of os/progs/wdoom.s, from Freedoom's art.

    tools/wdoom-assets.py FREEDOOM_CHECKOUT [OUTDIR]     (OUTDIR: os/progs/wdoom)

Reads a small subset of a Freedoom source checkout (https://github.com/
freedoom/freedoom, BSD 3-clause: see os/progs/wdoom/LICENSE-freedoom and
ATTRIBUTION.md): wall patches, flats, sprites, status bar graphics, the
palette and a few sounds, and writes

    OUTDIR/wdoom.dat    what the game loads
    OUTDIR/dat.s        the layout of that file as assembler constants

The level, the lookup tables (sine, floor distances, light levels) and the
colour map are made here too. Only the Python standard library is used.

wdoom.dat = a resident block (R_SIZE bytes, loaded into the game's D-LS:
tables, directories, the level) and a far block (F_SIZE bytes, loaded into
the top of the game's arena: pixels and samples). Everything is 8-bit
palette indices; index 255 is "transparent" in sprites.
  textures  column-major, 128 bytes per column, 64 or 128 columns
  sprites   column-major, each column padded to a multiple of 8 bytes
  flats     64 x 64, row-major
  the bar   ten 32 x 32 pieces, row-major (one per 32-column slab)
  palettes  256 x XRGB8888 each: normal, three reds (pain), gold (pickup)
  sounds    signed 8-bit mono, 11025 Hz
"""
import math
import os
import struct
import sys
import wave
import zlib

VW, VH = 320, 168                       # the 3-D view (the bar is 32 rows under it)
HALF = VH // 2
PROJ = 160                              # pixels per unit at distance 1 (90 degree view)
NANG = 2048                             # angle units in a circle
NLIGHT = 16                             # light levels in the colour map
SND_RATE = 11025
SND_MAX = 4400                          # samples kept of a sound (0.4 s)
TRANSP = 255


def read_png(path):
    """-> (w, h, rows of (r, g, b, a), grAb offsets or None)"""
    b = open(path, 'rb').read()
    assert b[:8] == b'\x89PNG\r\n\x1a\n', path
    p = 8
    idat = b''
    pal = trns = grab = None
    while p < len(b):
        n, t = struct.unpack('>I4s', b[p:p + 8])
        d = b[p + 8:p + 8 + n]
        p += 12 + n
        if t == b'IHDR':
            w, h, depth, ct, _, _, il = struct.unpack('>IIBBBBB', d)
            assert il == 0 and depth <= 8, path
        elif t == b'PLTE':
            pal = [tuple(d[i:i + 3]) for i in range(0, len(d), 3)]
        elif t == b'tRNS':
            trns = d
        elif t == b'grAb':
            grab = struct.unpack('>ii', d)
        elif t == b'IDAT':
            idat += d
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = max(1, ch * depth // 8)
    stride = (w * ch * depth + 7) // 8
    out = []
    prev = bytearray(stride)
    q = 0
    for _ in range(h):
        f = raw[q]
        line = bytearray(raw[q + 1:q + 1 + stride])
        q += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + up) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + up) >> 1)) & 255
            elif f == 4:
                pp = a + up - c
                pa, pb, pc = abs(pp - a), abs(pp - up), abs(pp - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else up if pb <= pc else c)) & 255
        prev = line
        row = []
        for x in range(w):
            if depth < 8:
                px = [(line[x * depth // 8] >> (8 - depth - (x * depth) % 8)) & ((1 << depth) - 1)]
            else:
                px = list(line[x * ch:(x + 1) * ch])
            if ct == 3:
                r, g, bl = pal[px[0]]
                a = trns[px[0]] if trns and px[0] < len(trns) else 255
            elif ct == 0:
                r = g = bl = px[0] * 255 // ((1 << depth) - 1)
                a = 255
            elif ct == 2:
                r, g, bl = px
                a = 0 if trns and len(trns) >= 6 and (r, g, bl) == (trns[1], trns[3], trns[5]) else 255
            elif ct == 4:
                r = g = bl = px[0]
                a = px[1]
            else:
                r, g, bl, a = px
            row.append((r, g, bl, a))
        out.append(row)
    return w, h, out, grab


def write_png(path, w, h, rows):
    raw = b''.join(b'\0' + bytes(c for px in row for c in px[:3]) for row in rows)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


class Pal:
    def __init__(self, path):
        d = open(path, 'rb').read()
        assert len(d) == 768, path
        self.rgb = [tuple(d[i:i + 3]) for i in range(0, 768, 3)]
        self.cache = {}

    def nearest(self, r, g, b, skip=TRANSP):
        k = (r, g, b)
        v = self.cache.get(k)
        if v is None:
            best = 1 << 30
            for i, (pr, pg, pb) in enumerate(self.rgb):
                if i == skip:
                    continue
                d = 2 * (pr - r) ** 2 + 4 * (pg - g) ** 2 + 3 * (pb - b) ** 2
                if d < best:
                    best, v = d, i
            self.cache[k] = v
        return v

    def image(self, rows):
        """rows of RGBA -> rows of indices (TRANSP where alpha < 128)"""
        return [[TRANSP if a < 128 else self.nearest(r, g, b) for r, g, b, a in row] for row in rows]

    def xrgb(self, tint=None, amount=0.0):
        out = bytearray()
        for r, g, b in self.rgb:
            if tint:
                r = int(r + (tint[0] - r) * amount)
                g = int(g + (tint[1] - g) * amount)
                b = int(b + (tint[2] - b) * amount)
            out += bytes((b, g, r, 0))
        return bytes(out)

    def colormap(self):
        out = bytearray()
        for lv in range(NLIGHT):
            f = 1.0 - lv / (NLIGHT + 5.0)
            out += bytes(self.nearest(int(r * f), int(g * f), int(b * f)) for r, g, b in self.rgb)
        return bytes(out)


def pad8(b):
    return b + bytes(-len(b) % 8)


# ---- what is taken ------------------------------------------------------------
# wall textures: (name, base patch, overlays (patch, x, y), first column, columns);
# map code = index + 1. A 64-column texture repeats twice across a cell.
TEXTURES = [
    ('CONC', 'aqconc16', [], 0, 128), ('PANEL1', 'aqpanl01', [], 0, 128), ('PANEL2', 'aqpanl02', [], 0, 128),
    ('METAL', 'aqmetl13', [], 0, 64), ('STEEL', 'aqconc13', [], 0, 64), ('HAZARD', 'aqconc14', [], 0, 64),
    ('BRICK', 'brick1', [], 0, 128), ('BROWN', 'brick', [], 0, 128), ('ROCK', 'arock2', [], 0, 128),
    ('RIVET', 'aqpipe10', [], 0, 64), ('CRATE', 'rw13_1', [], 0, 128),
    ('SW_OFF', 'aqconc16', [('sw1s0', 48, 56), ('exit1', 48, 30)], 32, 64),
    ('SW_ON', 'aqconc16', [('sw1s1', 48, 56), ('exit1', 48, 30)], 32, 64),
    ('DOOR', 'door9_1', [], 0, 128), ('DOORKEY', 'aqdoor02', [], 0, 128),
]
FLATS = [('FLOOR', 'aqf050'), ('CEIL', 'ceil5_1')]
MONSTERS = [                            # name, sprite, walk, attack, pain, death frames
    ('Z', 'poss', 'abcd', 'ef', 'g', 'hijkl'),
    ('I', 'troo', 'abcd', 'efg', 'h', 'ijklm'),
    ('D', 'sarg', 'abcd', 'efg', 'h', 'ijklmn'),
]
SPRITES = [                             # name, directory, file
    ('CLIP', 'sprites', 'clipa0'), ('STIM', 'sprites', 'stima0'), ('MEDI', 'sprites', 'media0'),
    ('KEY', 'sprites', 'bkeya0'), ('BALL0', 'sprites', 'bal1a0'), ('BALL1', 'sprites', 'bal1b0'),
    ('BOOM', 'sprites', 'bal1c0'),
    ('GUN0', 'sprites', 'pisga0'), ('GUN1', 'sprites', 'pisgb0'), ('GUN2', 'sprites', 'pisgc0'),
    ('FLASH', 'sprites', 'pisfa0'),
] + [('NUM%d' % i, 'graphics', 'sttnum%d' % i) for i in range(10)] + [
    ('PCT', 'graphics', 'sttprcnt'),
] + [('FACE%d' % i, 'graphics', 'stfst%d0' % i) for i in range(5)] + [
    ('FACEX', 'graphics', 'stfdead0'), ('KEYICON', 'graphics', 'stkeys0'),
]
MESSAGES = [                            # drawn here with Freedoom's small font
    ('M_CLIP', 'PICKED UP A CLIP.'), ('M_STIM', 'PICKED UP A STIMPACK.'),
    ('M_MEDI', 'PICKED UP A MEDIKIT.'), ('M_KEY', 'PICKED UP A BLUE KEYCARD.'),
    ('M_NEED', 'YOU NEED A BLUE KEY TO OPEN THIS DOOR.'),
    ('M_DEAD', 'YOU DIED. PRESS SPACE TO TRY AGAIN.'),
    ('M_WIN', 'LEVEL COMPLETE! PRESS SPACE TO PLAY AGAIN.'), ('M_KILLS', 'KILLS'),
    ('M_START', 'WASD OR ARROWS MOVE, SPACE FIRES, E OPENS.'),
]
SOUNDS = [
    ('PISTOL', 'dspistol'), ('DOOROPEN', 'dsdoropn'), ('DOORSHUT', 'dsdorcls'),
    ('SIGHT', 'dsposit1'), ('MPAIN', 'dspopain'), ('ZDIE', 'dspodth1'), ('IDIE', 'dsbgdth1'),
    ('DDIE', 'dssgtdth'), ('HURT', 'dsplpain'), ('ITEM', 'dsitemup'), ('FIRE', 'dsfirsht'),
    ('BITE', 'dssgtatk'), ('SWITCH', 'dsswtchn'), ('NOWAY', 'dsnoway'), ('DEATH', 'dspldeth'),
    ('BOOM', 'dsfirxpl'),
]

# ---- the level ------------------------------------------------------------------
# 1..9, A, B: a wall with texture 1..11; '=' a door, '%' the door that needs the
# blue key, '!' the exit switch. On the floor: P the player (facing east), z a
# zombie, i an imp, d a demon, c a clip, s a stimpack, m a medikit, k the key.
LEVEL = [
    "11111111111111111111111111111111",
    "1.....1....c.4........7.......s7",
    "1.P...1......4..z.....7..i.....7",
    "1.....=......=........=......i.7",
    "1.....1..z...4....z...7........7",
    "1..c..1......4........7..B..B..7",
    "1111111......44422444477.......7",
    "5.....5..22......1....7..B..B.k7",
    "5..s..5..22..z...1.c..7........7",
    "5.....5..........1....77777=7777",
    "5.....=......i...1....8.....8..8",
    "5.z...5..........=....8..d..8.m8",
    "5.....5..22......1....8.....8..8",
    "555=555..22......1....8..88.8..8",
    "6.....6111111%1111....8.....8..8",
    "6..m..69.......9.1..c.8.....=..8",
    "6.....69.......9.1....8888888888",
    "6.c...=....d...9.1....A...i....A",
    "6.....69.......9.1....A..AA....A",
    "6666669..9.9...9.1....=..AA..i.A",
    "1....99........9.11=11A........A",
    "1.s..9...i..i..9.3....AAAAAAAAAA",
    "1....9.........9.3..z.3111111111",
    "1....9999...9999.3....3........1",
    "1.......=.c.9....3..s.3........1",
    "1.......9...9....33333311111...1",
    "1.......99=99................1.1",
    "1........3.3.................1.1",
    "1........3.33333333333333333.1.1",
    "1........3.....z.....c....z..1.1",
    "1........3333333333333333333!1.1",
    "11111111111111111111111111111111",
]
MAPW = 32

# ---- the demo (`wdoom demo`) ---------------------------------------------------
# What the player does, tic by tic: (tics, keys), keys from f forward, b back,
# l step left, r step right, < turn left, > turn right, ! fire, e open. The
# game runs it one tic a frame, whatever the clock says, and stops at its end,
# so the last frame is the same on every run (tools/test-wdoom.sh).
DEMO = [
    (14, 'fr'), (26, 'f'), (1, 'e'), (22, ''), (20, 'f'), (7, '>'), (9, ''), (1, '!'), (15, ''), (1, '!'), (15, ''), (1, '!'), (15, ''), (1, '!'), (15, ''), (4, '>'), (56, ''), (1, '!'), (1, ''),
]
DEMO_KEYS = {'f': 1, 'b': 2, 'l': 4, 'r': 8, '<': 16, '>': 32, '!': 64, 'e': 128}
KINDS = {'z': 1, 'i': 2, 'd': 3, 'c': 4, 's': 5, 'm': 6, 'k': 7}
MAXTHINGS = 48
MAXDOORS = 24
C_DOOR = 0x80                           # a door cell: 0x80 | its number


def build(src, outdir, preview=None):
    pal = Pal(os.path.join(src, 'lumps/playpal/playpal-base.lmp'))
    far = bytearray()
    eq = []                             # (name, value, comment)

    def put(data):
        assert len(far) % 8 == 0
        off = len(far)
        far.extend(pad8(bytes(data)))
        return off

    def load(directory, name):
        w, h, rows, grab = read_png(os.path.join(src, directory, name + '.png'))
        return w, h, pal.image(rows), grab

    # sprite offsets: buildcfg.txt's [sprites] section, else the PNG's grAb, else centred
    offsets = {}
    sect = ''
    for line in open(os.path.join(src, 'buildcfg.txt'), encoding='latin-1'):
        line = line.split(';')[0].split()
        if line and line[0].startswith('['):
            sect = line[0]
        elif sect == '[sprites]' and len(line) >= 3 and line[2].lstrip('-').isdigit():
            offsets[line[0].lower()] = (int(line[1]), int(line[2]))

    # ---- textures
    texdir = bytearray()
    for i, (name, base, overlays, cx, cw) in enumerate(TEXTURES):
        w, h, img, _ = load('patches', base)
        assert h == 128 and w == 128, base
        for oname, ox, oy in overlays:
            ow, oh, oimg, _ = load('patches', oname)
            for y in range(oh):
                for x in range(ow):
                    if oimg[y][x] != TRANSP:
                        img[oy + y][ox + x] = oimg[y][x]
        cols = bytearray()
        for x in range(cx, cx + cw):
            cols += bytes(pal.nearest(*pal.rgb[0]) if img[y][x] == TRANSP else img[y][x] for y in range(128))
        texdir += struct.pack('<IHH', put(cols), cw - 1, 0)
        eq.append(('TX_' + name, i + 1, 'map code of %s' % base))
    ntex = len(TEXTURES)

    # ---- sprites
    sprdir = bytearray()
    sprnames = []
    sprimgs = []

    def add_sprite(name, w, h, img, ox, oy):
        cs = (h + 7) & ~7
        cols = bytearray()
        for x in range(w):
            cols += bytes(img[y][x] for y in range(h)) + bytes([TRANSP] * (cs - h))
        sprdir.extend(struct.pack('<IHHhhHH', put(cols), w, h, ox, oy, cs, 0))
        if name:
            eq.append(('SP_' + name, len(sprnames), ''))
        sprnames.append(name)
        sprimgs.append((w, h, img))
        assert h <= 128, name

    def add_file(name, directory, fname):
        w, h, img, grab = load(directory, fname)
        ox, oy = offsets.get(fname) or grab or ((w // 2, h - 4) if directory == 'sprites' else (0, 0))
        add_sprite(name, w, h, img, ox, oy)

    for name, spr, walk, atk, pain, die in MONSTERS:
        eq.append(('SP_%s' % name, len(sprnames), '%s: %d walk, %d attack, pain, %d death frames' % (spr, len(walk), len(atk), len(die))))
        eq.append(('N%s_ATK' % name, len(atk), ''))
        eq.append(('N%s_DIE' % name, len(die), ''))
        for f in walk + atk + pain:
            add_file(None, 'sprites', spr + f + '1')
        for f in die:
            add_file(None, 'sprites', spr + f + '0')
    for name, directory, fname in SPRITES:
        add_file(name, directory, fname)
    glyphs = {}
    for name, text in MESSAGES:
        cells = []
        for c in text:
            if c == ' ':
                cells.append((4, 0, []))
                continue
            if c not in glyphs:
                glyphs[c] = load('graphics', 'stcfn%03d' % ord(c))[:3]
            cells.append(glyphs[c])
        h = max(c[1] for c in cells)
        w = sum(c[0] for c in cells)
        img = [[TRANSP] * w for _ in range(h)]
        x0 = 0
        for cw, chh, cimg in cells:
            for y in range(chh):
                for x in range(cw):
                    img[h - chh + y][x0 + x] = cimg[y][x]
            x0 += cw
        add_sprite(name, w, h, img, 0, 0)
    nspr = len(sprnames)

    # ---- flats, the bar, palettes
    for name, fname in FLATS:
        w, h, img, _ = load('flats', fname)
        assert (w, h) == (64, 64)
        eq.append(('F_' + name, put(bytes(c for row in img for c in row)), 'far offset of flat %s' % fname))
    w, h, bar, _ = load('graphics', 'stbar')
    assert (w, h) == (320, 32)
    aw, ah, arms, _ = load('graphics', 'starms')
    for y in range(ah):
        for x in range(aw):
            if arms[y][x] != TRANSP:
                bar[y][104 + x] = arms[y][x]
    eq.append(('F_BAR', len(far), 'far offset of the status bar: ten 32 x 32 pieces'))
    for s in range(10):
        put(bytes(bar[y][x] for y in range(32) for x in range(s * 32, s * 32 + 32)))
    eq.append(('F_PALS', len(far), 'far offset of the palettes (1024 bytes each)'))
    put(pal.xrgb())
    for k in (2, 4, 6):
        put(pal.xrgb((255, 0, 0), k / 9.0))
    put(pal.xrgb((215, 186, 69), 0.25))
    eq.append(('PAL_RED', 1, 'the first of three red palettes'))
    eq.append(('PAL_GOLD', 4, 'the pickup flash'))

    # ---- sounds
    snddir = bytearray()
    for i, (name, fname) in enumerate(SOUNDS):
        wv = wave.open(os.path.join(src, 'sounds', fname + '.wav'))
        assert wv.getsampwidth() == 1 and wv.getnchannels() == 1, fname
        d = wv.readframes(wv.getnframes())
        step = wv.getframerate() // SND_RATE
        assert step in (1, 2), fname
        s = [sum(d[j:j + step]) // step - 128 for j in range(0, len(d) - step + 1, step)][:SND_MAX]
        fade = min(len(s), 600) if len(s) == SND_MAX else 0
        for j in range(fade):
            s[len(s) - 1 - j] = s[len(s) - 1 - j] * j // fade
        while len(s) % 8:
            s.append(0)
        snddir += struct.pack('<II', put(bytes(v & 255 for v in s)), len(s))
        eq.append(('SN_' + name, i, fname))
    nsnd = len(SOUNDS)

    # ---- the level
    assert len(LEVEL) == 32 and all(len(r) == MAPW for r in LEVEL)
    cells = bytearray(MAPW * 32)
    things = []
    doors = []
    start = None
    for y, row in enumerate(LEVEL):
        for x, c in enumerate(row):
            v = 0
            if c in '123456789AB':
                v = int(c, 16)
            elif c in '=%':
                horiz = LEVEL[y][x - 1] not in '.' and LEVEL[y][x + 1] not in '.'
                # horiz: walls to the west and east, so the door is crossed going north-south
                v = C_DOOR | len(doors)
                doors.append((y * MAPW + x, (dict(TEXTURES_IDX)['DOORKEY'] if c == '%' else dict(TEXTURES_IDX)['DOOR']),
                              (1 if horiz else 0) | (2 if c == '%' else 0)))
            elif c == '!':
                v = dict(TEXTURES_IDX)['SW_OFF']
            elif c == 'P':
                start = (x, y)
            elif c in KINDS:
                things.append((x, y, KINDS[c]))
            else:
                assert c == '.', c
            cells[y * MAPW + x] = v
    assert start and len(things) <= MAXTHINGS - 12 and len(doors) <= MAXDOORS
    lvl = bytearray(cells)
    lvl += struct.pack('<QQQ', start[0], start[1], len(things))
    for x, y, k in things:
        lvl += bytes((x, y, k, 0))
    lvl += bytes(4 * (MAXTHINGS - len(things)))
    lvl += struct.pack('<Q', len(doors))
    for cell, tex, flags in doors:
        lvl += struct.pack('<HBB', cell, tex, flags)
    lvl += bytes(4 * (MAXDOORS - len(doors)))

    demo = bytearray()
    for tics, keys in DEMO:
        mask = sum(DEMO_KEYS[k] for k in keys)
        while tics > 0:
            demo += bytes((min(tics, 255), mask))
            tics -= 255

    # ---- tables
    sin = b''.join(struct.pack('<I', min(65536, int(round(math.sin(i * math.pi / 2 / (NANG // 4)) * 65536))))
                   for i in range(NANG // 4 + 1))
    rowd = []
    rowl = bytearray()
    for k in range(HALF):
        d = (PROJ / 2) / (k + 0.5)
        rowd.append(struct.pack('<I', min(int(d * 65536), 0x7fffffff)))
        rowl.append(min(NLIGHT - 1, int(d * 1.6)))
    parts = [('R_SIN', pad8(sin), 'sine of a quarter circle: %d + 1 entries, 16.16' % (NANG // 4)),
             ('R_ROWD', pad8(b''.join(rowd)), 'distance of floor row k below the horizon, 16.16'),
             ('R_ROWL', pad8(bytes(rowl)), 'its light level'),
             ('R_CMAP', pal.colormap(), 'the colour map: %d levels of 256' % NLIGHT),
             ('R_PAL', pal.xrgb(), 'the palette in use (XRGB8888)'),
             ('R_TEX', pad8(bytes(texdir)), 'textures: u32 far offset, u16 column mask, u16 0'),
             ('R_SPR', pad8(bytes(sprdir)), 'sprites: u32 far offset, u16 w, h, s16 ox, oy, u16 column bytes, u16 0'),
             ('R_SND', pad8(bytes(snddir)), 'sounds: u32 far offset, u32 samples'),
             ('R_MAP', bytes(lvl[:MAPW * 32]), 'the level: 32 x 32 cells'),
             ('R_START', bytes(lvl[MAPW * 32:MAPW * 32 + 16]), 'the player: cell x, y'),
             ('R_NTHING', bytes(lvl[MAPW * 32 + 16:MAPW * 32 + 24]), 'things in the level'),
             ('R_THINGS', bytes(lvl[MAPW * 32 + 24:MAPW * 32 + 24 + 4 * MAXTHINGS]), 'x, y, kind, 0 each'),
             ('R_NDOOR', bytes(lvl[MAPW * 32 + 24 + 4 * MAXTHINGS:MAPW * 32 + 32 + 4 * MAXTHINGS]), 'doors'),
             ('R_DOORS', bytes(lvl[MAPW * 32 + 32 + 4 * MAXTHINGS:]), 'u16 cell, u8 texture, u8 flags (1: crossed north-south, 2: needs the key)'),
             ('R_DEMO', pad8(demo + b'\0\0'), 'the demo: u8 tics, u8 keys (bits: fwd, back, left, right, turn left, turn right, fire, open); 0 ends it')]
    res = bytearray()
    lines = ['; dat.s: the layout of wdoom.dat. Written by tools/wdoom-assets.py: do not edit.',
             ';',
             '; The art and sounds in wdoom.dat come from Freedoom (BSD 3-clause): see',
             '; LICENSE-freedoom and ATTRIBUTION.md in this directory.', '']

    def equ(name, value, comment):
        lines.append(('%-9s = %-28s' % (name, value)).ljust(40) + '; ' + (comment or '...'))
    for name, data, comment in parts:
        assert len(res) % 8 == 0 and len(data) % 8 == 0, name
        equ(name, len(res), comment)
        res += data
    equ('R_SIZE', len(res), 'bytes of the resident block (the head of the file)')
    equ('F_SIZE', len(far), 'bytes of the far block (the rest of it)')
    equ('NTEX', ntex, 'textures')
    equ('NSPR', nspr, 'sprites')
    equ('NSND', nsnd, 'sounds')
    equ('NLIGHT', NLIGHT, 'light levels')
    equ('MAXTHINGS', MAXTHINGS, 'things at most (those of the level and those made in play)')
    equ('MAXDOORS', MAXDOORS, 'doors at most')
    equ('SND_RATE', SND_RATE, 'samples per second')
    for name, value, comment in eq:
        equ(name, value, comment)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'wdoom.dat'), 'wb').write(bytes(res) + bytes(far))
    open(os.path.join(outdir, 'dat.s'), 'w').write('\n'.join(lines) + '\n')
    print('wdoom.dat: resident %d + far %d = %d bytes; %d textures, %d sprites, %d sounds, %d things, %d doors' %
          (len(res), len(far), len(res) + len(far), ntex, nspr, nsnd, len(things), len(doors)))
    if preview:                         # the sprites as a picture, to look at
        W = 640
        x = y = rowh = 0
        canvas = [[(255, 0, 255)] * W for _ in range(900)]
        for w, h, img in sprimgs:
            if x + w > W:
                x, y, rowh = 0, y + rowh + 2, 0
            for yy in range(h):
                for xx in range(w):
                    if img[yy][xx] != TRANSP:
                        canvas[y + yy][x + xx] = pal.rgb[img[yy][xx]]
            x += w + 2
            rowh = max(rowh, h)
        write_png(preview, W, y + rowh + 2, canvas[:y + rowh + 2])


TEXTURES_IDX = [(t[0], i + 1) for i, t in enumerate(TEXTURES)]

if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    here = os.path.dirname(os.path.abspath(__file__))
    build(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, '..', 'os', 'progs', 'wdoom'),
          sys.argv[3] if len(sys.argv) > 3 else None)
