#!/usr/bin/env python3
"""kira-assets.py: the data file of os/progs/kira.s, from its art.

    tools/kira-assets.py [ARTDIR [OUTDIR [PREVIEW.png]]]

ARTDIR is os/progs/kira/art (the PNG files that tools/kira-art.py draws,
specified in SPEC.md there), OUTDIR is os/progs/kira. Writes

    OUTDIR/kira.dat     what the game loads
    OUTDIR/dat.s        the layout of that file as assembler constants

The palette is made here from the colours the art uses; the sounds are
synthesised here; the world, the songs, the lookup tables and the demos
are defined here. Only the Python standard library is used.

kira.dat = a resident block (R_SIZE bytes, loaded into the game's D-LS:
tables, directories, the world) and a far block (F_SIZE bytes, loaded into
the top of the game's arena: pixels and samples). Pixels are 8-bit palette
indices; index 255 is "transparent" in sprites.
  sprites   column-major, each column padded to a multiple of 8 bytes
  tiles     16 x 16, row-major (the world seen from above)
  textures  64 x 64, column-major (walls seen through Kira's eyes)
  flats     32 x 32, row-major (floors and the ceiling)
  the bar   ten 32 x 32 pieces, row-major (one per 32-column slab)
  pictures  320 x 168 in ten slabs of 32 columns, each slab run-length
            coded row-major as (count, value) pairs; a colouring page's
            values are region numbers (0: the outline)
  sounds    signed 8-bit mono, 11025 Hz
"""
import math
import os
import random
import struct
import sys
import zlib

VW, VH = 320, 168                       # the view (the bar is 32 rows under it)
HALF = VH // 2
PROJ = 160                              # pixels per cell at distance 1
NANG = 2048                             # angle units in a circle
NLIGHT = 4                              # light levels in the colour map
SHADE = 0.08                            # how much darker each level is
SND_RATE = 11025
TRANSP = 255
MAPW, MAPH = 64, 20                     # the world's array (40 x 20 of it are used)
WORLDW, WORLDH = 40, 20
PIC_MAX = 2040                          # bytes of a picture's slab at most, coded

FRIENDS = ['cat', 'dog', 'bunny', 'duck', 'pony', 'bird', 'frog']
WALLS = ['stone', 'window', 'banner', 'shelf', 'hedge', 'roses']      # map codes 1..6
FLOORS = ['castle', 'carpet', 'grass', 'path', 'water']               # floor kinds 0..4
DECOR = ['tree', 'bush', 'fountain', 'bed', 'table', 'throne', 'chest', 'picnic']
PLANTS = ['tulip', 'daisy', 'sunflower', 'rose']
PAINTS = [(230, 40, 50), (250, 140, 30), (255, 225, 50), (70, 190, 80), (110, 200, 250),
          (50, 90, 220), (150, 80, 200), (255, 150, 200), (150, 95, 50), (255, 255, 255)]
PICTURES = ['menu', 'garden', 'music', 'paint_1', 'paint_2', 'paint_3']

# ---- songs: notes 0..7 = C D E F G A B C', -1 a rest; all traditional tunes --
SONGS = [
    [0, 0, 4, 4, 5, 5, 4, -1, 3, 3, 2, 2, 1, 1, 0, -1,                   # Twinkle, twinkle, little star
     4, 4, 3, 3, 2, 2, 1, -1, 4, 4, 3, 3, 2, 2, 1, -1,
     0, 0, 4, 4, 5, 5, 4, -1, 3, 3, 2, 2, 1, 1, 0],
    [2, 1, 0, 1, 2, 2, 2, -1, 1, 1, 1, -1, 2, 4, 4, -1,                  # Mary had a little lamb
     2, 1, 0, 1, 2, 2, 2, 2, 1, 1, 2, 1, 0],
    [0, 1, 2, 0, 0, 1, 2, 0, 2, 3, 4, -1, 2, 3, 4, -1,                   # Frere Jacques
     4, 5, 4, 3, 2, 0, 4, 5, 4, 3, 2, 0, 0, 4, 0, -1, 0, 4, 0],
    [2, 2, 3, 4, 4, 3, 2, 1, 0, 0, 1, 2, 2, 1, 1, -1,                    # Ode to Joy
     2, 2, 3, 4, 4, 3, 2, 1, 0, 0, 1, 2, 1, 0, 0],
]
SONG_TICS = 12                          # tics from a note to the next
FANFARE = [(0, 0), (4, 2), (4, 4), (4, 7), (8, 4), (4, 7), (0, 2), (10, 0), (0, 4), (0, 7)]

# ---- the demos (`kira demo N`): (tics to wait, key), one tic a frame -----------
# Keys: U D L R the arrows, other characters themselves. tools/test-kira.sh
# compares the last frame of each.
DEMOS = {
    1: "9 1,10 @40:28,200 .,5 R,10 R,10 D,40 .",  # Friends from above: a click on the duck's cell; three steps
    2: "5 L,3 L,3 L,3 L,3 L,3 L,3 L,3 U,3 U,3 U,5  ,10 !,30 R,80 .,5 .,20 .",   # the hand presses FRIENDS; the party; a new world
    3: "9 1,5  ,20 R,4 R,4 R,35 R,35 U,20 U,20 L,40 .",   # through her eyes: turns and steps
    4: "9 1,5  ,10 !,30 U,60 .",                  # ... and the party seen so
    5: "9 2,5 2,5 @88:100,10 5,5 @88:100,20 @88:100,30 @136:146,250 .,5 m,10 2,60 .",   # Garden: a daisy sown and watered into bloom; left and come back to
    6: "9 3,5 1,5 @100:60,5 4,5 @200:120,5 n,5 7,5 @160:80,30 .",    # Paint: two regions, the next page, one more
    7: "9 4,5 @40:100,10 3,10 @30:30,10 p,200 .",                     # Music: a bar by a click, one by a key, a friend, a song
    8: "9 1,1 {60,2 !,3 R,80 .,2 .,1 },20 .",   # sixty games, each in a new world
}
KEYS = {'U': 1, 'D': 2, 'L': 3, 'R': 4, '!': 0xfd, '}': 0xfc}


def read_png(path):
    """-> (w, h, rows of (r, g, b, a))"""
    b = open(path, 'rb').read()
    assert b[:8] == b'\x89PNG\r\n\x1a\n', path
    p = 8
    idat = b''
    pal = trns = None
    while p < len(b):
        n, t = struct.unpack('>I4s', b[p:p + 8])
        d = b[p + 8:p + 8 + n]
        p += 12 + n
        if t == b'IHDR':
            w, h, depth, ct, _, _, il = struct.unpack('>IIBBBBB', d)
            assert il == 0 and depth == 8, path
        elif t == b'PLTE':
            pal = [tuple(d[i:i + 3]) for i in range(0, len(d), 3)]
        elif t == b'tRNS':
            trns = d
        elif t == b'IDAT':
            idat += d
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    stride = w * ch
    out = []
    prev = bytearray(stride)
    q = 0
    for _ in range(h):
        f = raw[q]
        line = bytearray(raw[q + 1:q + 1 + stride])
        q += 1 + stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            up = prev[i]
            c = prev[i - ch] if i >= ch else 0
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
            px = list(line[x * ch:(x + 1) * ch])
            if ct == 3:
                r, g, bl = pal[px[0]]
                a = trns[px[0]] if trns and px[0] < len(trns) else 255
            elif ct == 0:
                r = g = bl = px[0]
                a = 255
            elif ct == 2:
                r, g, bl = px
                a = 255
            elif ct == 4:
                r = g = bl = px[0]
                a = px[1]
            else:
                r, g, bl, a = px
            row.append((r, g, bl, a))
        out.append(row)
    return w, h, out


def write_png(path, w, h, rows):
    raw = b''.join(b'\0' + bytes(c for px in row for c in px[:3]) for row in rows)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def pad8(b):
    return b + bytes(-len(b) % 8)


# ---- sounds ---------------------------------------------------------------------
def synth(seconds, fn):
    """fn(t, i) -> -1..1; -> signed 8-bit samples, a whole number of words"""
    n = int(seconds * SND_RATE) & ~7
    out = bytearray()
    for i in range(n):
        t = i / SND_RATE
        v = fn(t, i) * min(1.0, i / 40.0) * min(1.0, (n - i) / 200.0)
        out.append(int(max(-1.0, min(1.0, v)) * 110) & 255)
    return bytes(out)


def sweep(t, dur, f0, f1):
    """phase (in cycles) at t of a tone that glides from f0 to f1 over dur"""
    return f0 * t + (f1 - f0) * t * t / (2 * dur)


def tone(ph, harmonics):
    return sum(a * math.sin(2 * math.pi * k * ph) for k, a in harmonics)


def bell(t, dur):
    return math.sin(math.pi * min(1.0, t / dur)) ** 0.7 if t < dur else 0.0


def make_sounds():
    rnd = random.Random(7)
    noise = [rnd.uniform(-1, 1) for _ in range(SND_RATE)]
    snd = []
    scale = [523.25, 587.33, 659.25, 698.46, 783.99, 880.00, 987.77, 1046.50]
    for i, f in enumerate(scale):       # the xylophone: a struck bar
        snd.append(('NOTE%d' % i, synth(0.45, lambda t, _, f=f: (
            math.sin(2 * math.pi * f * t) * math.exp(-7 * t) +
            0.35 * math.sin(2 * math.pi * 4 * f * t) * math.exp(-28 * t) +
            0.15 * math.sin(2 * math.pi * 10 * f * t) * math.exp(-60 * t)) * 0.8)))
    saw = [(k, 1.0 / k) for k in range(1, 7)]
    nasal = [(1, 0.5), (2, 1.0), (3, 0.8), (4, 0.3), (5, 0.4), (6, 0.2)]

    def meow(t, _):
        d = 0.5
        f = 620 + 330 * math.sin(math.pi * min(1, t / d) ** 0.6) - 150 * (t / d) ** 2
        meow.ph += f / SND_RATE
        return tone(meow.ph, nasal) * 0.33 * bell(t, d)
    meow.ph = 0.0

    def woof(t, i):
        v = 0.0
        for t0 in (0.0, 0.2):
            u = t - t0
            if 0 <= u < 0.13:
                v += (tone(sweep(u, 0.13, 330, 170), saw) * 0.45 + noise[i % SND_RATE] * 0.25) * bell(u, 0.13)
        return v

    def squeak(t, _):
        v = 0.0
        for t0 in (0.0, 0.16):
            u = t - t0
            if 0 <= u < 0.12:
                v += math.sin(2 * math.pi * sweep(u, 0.12, 900, 1700)) * 0.7 * bell(u, 0.12)
        return v

    def quack(t, _):
        v = 0.0
        for t0 in (0.0, 0.2):
            u = t - t0
            if 0 <= u < 0.15:
                v += tone(sweep(u, 0.15, 520, 400), nasal) * 0.33 * bell(u, 0.15) * \
                    (0.7 + 0.3 * math.sin(2 * math.pi * 45 * u))
        return v

    def neigh(t, _):
        d = 0.6
        f = (1250 - 800 * (t / d)) * (1 + 0.10 * math.sin(2 * math.pi * 13 * t))
        neigh.ph += f / SND_RATE
        return tone(neigh.ph, saw) * 0.4 * bell(t, d)
    neigh.ph = 0.0

    def tweet(t, _):
        v = 0.0
        for t0 in (0.0, 0.11, 0.22):
            u = t - t0
            if 0 <= u < 0.08:
                v += math.sin(2 * math.pi * sweep(u, 0.08, 2400, 3600)) * 0.6 * bell(u, 0.08)
        return v

    def ribbit(t, _):
        v = 0.0
        for t0, d, f0, f1 in ((0.0, 0.13, 190, 210), (0.17, 0.22, 200, 300)):
            u = t - t0
            if 0 <= u < d:
                v += tone(sweep(u, d, f0, f1), saw) * 0.5 * bell(u, d) * (0.5 + 0.5 * math.sin(2 * math.pi * 32 * u))
        return v
    snd += [('CAT', synth(0.5, meow)), ('DOG', synth(0.36, woof)), ('BUNNY', synth(0.3, squeak)),
            ('DUCK', synth(0.36, quack)), ('PONY', synth(0.6, neigh)), ('BIRD', synth(0.32, tweet)),
            ('FROG', synth(0.4, ribbit))]
    snd.append(('POP', synth(0.08, lambda t, _: math.sin(2 * math.pi * sweep(t, 0.08, 900, 350)) * 0.7)))
    snd.append(('PLANT', synth(0.16, lambda t, _: math.sin(2 * math.pi * sweep(t, 0.16, 300, 700)) * 0.7 * bell(t, 0.16))))
    snd.append(('STEP', synth(0.05, lambda t, i: (noise[(i * 3) % SND_RATE] * 0.12 +
                                                  math.sin(2 * math.pi * 150 * t) * 0.2) * math.exp(-60 * t))))

    def water(t, i):
        k = int(t / 0.045)
        f = 500 + 900 * ((k * 7919) % 13) / 13.0
        u = t - k * 0.045
        return math.sin(2 * math.pi * sweep(u, 0.045, f, f * 1.5)) * 0.45 * bell(u, 0.045) * bell(t, 0.45) + \
            noise[i % SND_RATE] * 0.06 * bell(t, 0.45)
    snd.append(('WATER', synth(0.45, water)))

    def chime(t, _):
        v = 0.0
        for k, f in enumerate((1046.5, 1318.5, 1568.0, 2093.0)):
            u = t - k * 0.07
            if u >= 0:
                v += math.sin(2 * math.pi * f * u) * math.exp(-9 * u) * 0.3
        return v
    snd.append(('CHIME', synth(0.6, chime)))
    snd.append(('BLOOM', synth(0.4, lambda t, _: sum(
        math.sin(2 * math.pi * f * t) * math.exp(-8 * max(0, t - d)) * (t >= d) * 0.3
        for d, f in ((0, 784.0), (0.1, 1046.5), (0.2, 1318.5))))))
    return snd


def build(art, outdir, preview=None):
    def png(name):
        return read_png(os.path.join(art, name + '.png'))

    # ---- what is drawn
    sprites = []                        # (name, anchored)
    for d in ('down', 'up', 'left', 'right'):
        sprites += [('kira_td_%s_%d' % (d, f), True) for f in (0, 1)]
    sprites += [('kira_face_%d' % f, False) for f in range(3)]
    sprites += [('kira_big_%d' % f, True) for f in range(3)]
    for a in FRIENDS:
        sprites += [(a + '_fp_0', True), (a + '_fp_1', True), (a + '_td_0', True), (a + '_td_1', True),
                    (a + '_icon', False), ('word_' + a, False)]
    for d in DECOR:
        sprites += [(d + '_fp', True), (d + '_td', True)]
    sprites += [(n, False) for n in ('heart_0', 'heart_1', 'star_0', 'star_1', 'note_0', 'note_1')]
    for c in 'abc':
        sprites += [('butterfly_%s_%d' % (c, f), False) for f in (0, 1)]
    sprites += [('cursor', False), ('select', False)]
    sprites += [('num_%d' % i, False) for i in range(1, 8)]
    sprites += [('word_picnic', False), ('word_hooray', False)]
    sprites += [('icon_' + n, False) for n in ('home', 'eyes', 'map', 'tulip', 'daisy', 'sunflower', 'rose',
                                               'can', 'next', 'song')]
    sprites += [('pot_%d' % i, False) for i in range(10)]
    for p in PLANTS:
        sprites += [('plant_%s_%d' % (p, s), True) for s in (1, 2, 3)]
    sprites += [('drop', False)]
    sprites += [('xylo_hit_%d' % i, False) for i in range(8)]
    tiles = ['wall_%s_td' % w for w in WALLS] + ['floor_%s_td' % f for f in FLOORS]
    textures = ['wall_%s_fp' % w for w in WALLS]
    flats = ['floor_%s_fp' % f for f in FLOORS] + ['ceil_castle_fp']

    # ---- the palette: every colour the art uses, then the ones the game needs
    images = {}
    colours = {}
    for name in [s for s, _ in sprites] + tiles + textures + flats + ['bar', 'menu', 'garden', 'music']:
        images[name] = png(name)
        for row in images[name][2]:
            for r, g, b, a in row:
                if a >= 128:
                    colours[(r, g, b)] = colours.get((r, g, b), 0) + 1
    extra = [(0, 0, 0), (255, 255, 255), (254, 254, 254), (165, 155, 185), (140, 200, 250), (200, 180, 230)] + PAINTS
    rgb = sorted(colours, key=lambda c: (-colours[c], c))
    for c in extra:
        if c not in colours:
            rgb.append(c)
    # ... and, while there is room, the darker shades of the colours that the world seen
    # through Kira's eyes is made of, so that a far wall is a shade of its own colour
    def shade(c, lv):
        f = 1.0 - lv * SHADE
        return tuple(int(v * f) for v in c)
    world = {}
    for name in textures + flats + [s for s, _ in sprites if s.endswith(('_fp', '_fp_0', '_fp_1'))]:
        for row in images[name][2]:
            for r, g, b, a in row:
                if a >= 128:
                    world[(r, g, b)] = world.get((r, g, b), 0) + 1
    for lv in range(1, NLIGHT):
        for c in sorted(world, key=lambda c: (-world[c], c)):
            d = shade(c, lv)
            if d not in rgb and len(rgb) < 255:
                rgb.append(d)
    assert len(rgb) <= 255, 'the art uses %d colours: 255 at most' % len(rgb)
    index = {c: i for i, c in enumerate(rgb)}
    ncol = len(rgb)
    rgb += [(0, 0, 0)] * (256 - len(rgb))

    def nearest(r, g, b):
        best, v = 1 << 30, 0
        for i in range(ncol):
            pr, pg, pb = rgb[i]
            d = 2 * (pr - r) ** 2 + 4 * (pg - g) ** 2 + 3 * (pb - b) ** 2
            if d < best:
                best, v = d, i
        return v

    def indices(name):
        w, h, rows = images[name]
        return w, h, [[index[(r, g, b)] if a >= 128 else TRANSP for r, g, b, a in row] for row in rows]

    far = bytearray()
    eq = []                             # (name, value, comment)

    def put(data):
        assert len(far) % 8 == 0
        off = len(far)
        far.extend(pad8(bytes(data)))
        return off

    # ---- sprites
    sprdir = bytearray()
    sprimgs = []
    spr = {}
    for name, anchored in sprites:
        w, h, img = indices(name)
        assert h <= 128, name
        cs = (h + 7) & ~7
        cols = bytearray()
        for x in range(w):
            cols += bytes(img[y][x] for y in range(h)) + bytes([TRANSP] * (cs - h))
        ox, oy = (w // 2, h) if anchored else (0, 0)
        spr[name] = len(sprimgs)
        sprdir += struct.pack('<IHHhhHH', put(cols), w, h, ox, oy, cs, 0)
        eq.append(('SP_' + name.upper(), len(sprimgs), ''))
        sprimgs.append((w, h, img))

    # ---- tiles, textures, flats, the bar
    f_tiles = len(far)
    for name in tiles:
        w, h, img = indices(name)
        assert (w, h) == (16, 16) and all(TRANSP not in r for r in img), name
        put(b''.join(bytes(r) for r in img))
    texdir = bytearray()
    for name in textures:
        w, h, img = indices(name)
        assert (w, h) == (64, 64) and all(TRANSP not in r for r in img), name
        texdir += struct.pack('<IHH', put(bytes(img[y][x] for x in range(64) for y in range(64))), 63, 0)
    f_flats = len(far)
    for name in flats:
        w, h, img = indices(name)
        assert (w, h) == (32, 32) and all(TRANSP not in r for r in img), name
        put(b''.join(bytes(r) for r in img))
    w, h, img = indices('bar')
    assert (w, h) == (320, 32)
    f_bar = len(far)
    for s in range(10):
        put(b''.join(bytes(img[y][s * 32:s * 32 + 32]) for y in range(32)))

    # ---- pictures
    def rle(img):
        d = bytearray()
        for s in range(10):
            flat = [img[y][x] for y in range(VH) for x in range(s * 32, s * 32 + 32)]
            out = bytearray()
            i = 0
            while i < len(flat):
                j = i
                while j < len(flat) and flat[j] == flat[i] and j - i < 255:
                    j += 1
                out += bytes((j - i, flat[i]))
                i = j
            assert len(out) <= PIC_MAX, 'a slab codes to %d bytes: %d at most' % (len(out), PIC_MAX)
            d += struct.pack('<IHH', put(out), len(out), 0)
        return d

    picdir = bytearray()
    nreg = []
    for name in PICTURES:
        if not name.startswith('paint'):
            w, h, img = indices(name)
            assert (w, h) == (VW, VH) and all(TRANSP not in r for r in img), name
        else:                           # a colouring page: the white regions, numbered
            w, h, rows = png(name)
            assert (w, h) == (VW, VH), name
            img = [[0 if r < 128 else -1 for r, g, b, a in row] for row in rows]
            n = 0
            for y0 in range(VH):
                for x0 in range(VW):
                    if img[y0][x0] != -1:
                        continue
                    n += 1
                    assert n <= 63, name + ': too many regions'
                    stack = [(x0, y0)]
                    img[y0][x0] = n
                    while stack:
                        x, y = stack.pop()
                        for xx, yy in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                            if 0 <= xx < VW and 0 <= yy < VH and img[yy][xx] == -1:
                                img[yy][xx] = n
                                stack.append((xx, yy))
            nreg.append(n)
        eq.append(('PIC_' + name.upper(), len(picdir) // 80, ''))
        picdir += rle(img)

    # ---- sounds
    snddir = bytearray()
    for i, (name, data) in enumerate(make_sounds()):
        snddir += struct.pack('<II', put(data), len(data))
        eq.append(('SN_' + name, i, ''))
    nsnd = len(snddir) // 8

    # ---- the world: made by the game (os/progs/kira/world.s); the things' sprites
    decor = b''.join(struct.pack('<HH', spr[d + '_fp'], spr[d + '_td']) for d in DECOR)
    friends = b''.join(struct.pack('<HHHHHHHH', spr[a + '_fp_0'], spr[a + '_td_0'], spr[a + '_icon'],
                                   spr['word_' + a], i + 8, 0, 0, 0) for i, a in enumerate(FRIENDS))

    # ---- songs and demos
    songs = bytearray()
    songdir = bytearray()
    for notes in SONGS:
        songdir += struct.pack('<H', 2 * len(SONGS) + len(songs))
        wait = 0
        for n in notes:
            if n < 0:
                wait += SONG_TICS
            else:
                songs += bytes((wait, n))
                wait = SONG_TICS
        songs += b'\xff\xff'
    fanfare = b''.join(bytes(p) for p in FANFARE) + b'\xff\xff'
    demos = bytearray()
    demodir = bytearray()
    for n in range(1, 9):
        demodir += struct.pack('<H', 16 + len(demos))
        for step in DEMOS.get(n, "1 .").split(','):
            t, k = step.split(' ', 1)
            if k.startswith('@'):       # a click
                x, y = k[1:].split(':')
                demos += bytes((int(t), 0xfe, int(x) // 2, int(y)))
            elif k.startswith('{'):     # what follows, up to }, so many times
                demos += bytes((int(t), 0xfb, int(k[1:]), 0))
            else:
                demos += bytes((int(t), KEYS.get(k, ord(k))))
        demos += b'\0\0'

    # ---- tables
    sin = b''.join(struct.pack('<I', min(65536, int(round(math.sin(i * math.pi / 2 / (NANG // 4)) * 65536))))
                   for i in range(NANG // 4 + 1))
    rowd = []
    rowl = bytearray()
    for k in range(HALF):
        d = (PROJ / 2) / (k + 0.5)
        rowd.append(struct.pack('<I', min(int(d * 65536), 0x7fffffff)))
        rowl.append(min(NLIGHT - 1, int(d * 0.45)))
    cmap = bytearray()
    for lv in range(NLIGHT):
        cmap += bytes(nearest(*shade(c, lv)) if i < ncol else i for i, c in enumerate(rgb))
    palb = b''.join(bytes((b, g, r, 0)) for r, g, b in rgb)
    parts = [('R_SIN', pad8(sin), 'sine of a quarter circle: %d + 1 entries, 16.16' % (NANG // 4)),
             ('R_ROWD', pad8(b''.join(rowd)), 'distance of floor row k below the horizon, 16.16'),
             ('R_ROWL', pad8(bytes(rowl)), 'its light level'),
             ('R_CMAP', bytes(cmap), 'the colour map: %d levels of 256' % NLIGHT),
             ('R_PAL', palb, 'the palette (XRGB8888)'),
             ('R_TEX', pad8(bytes(texdir)), 'wall textures: u32 far offset, u16 column mask, u16 0'),
             ('R_SPR', pad8(bytes(sprdir)), 'sprites: u32 far offset, u16 w, h, s16 ox, oy, u16 column bytes, u16 0'),
             ('R_SND', pad8(bytes(snddir)), 'sounds: u32 far offset, u32 samples'),
             ('R_PIC', bytes(picdir), 'pictures: ten slabs each: u32 far offset, u16 coded bytes, u16 0'),
             ('R_MAP', bytes(MAPW * MAPH), 'the world: %d x %d cells (%d x %d used): wall 1..6 in bits 0..3, '
              'floor kind in bits 4..6, bit 7: not walked on' % (MAPW, MAPH, WORLDW, WORLDH)),
             ('R_THINGS', bytes(8 * 41), 'things: u8 x, y, kind, which, u16 sprite (through her eyes), '
              'u16 sprite (from above); kind 0 ends them'),
             ('R_DECOR', pad8(decor), 'the things\' sprites: u16 through her eyes, u16 from above, each'),
             ('R_FRIEND', friends, 'friends: u16 sprite (eyes), sprite (above), icon, word, sound; 16 bytes'),
             ('R_PAINT', pad8(bytes(index[c] for c in PAINTS)), 'the ten paint colours'),
             ('R_NREG', pad8(bytes(nreg)), 'regions of each colouring page'),
             ('R_SONGS', pad8(bytes(songdir) + bytes(songs)), 'the songs: a u16 offset from here each, then '
              'u8 tics before the note, u8 note each; 255 ends one'),
             ('R_FANFARE', pad8(fanfare), 'the fanfare, likewise'),
             ('R_DEMO', pad8(bytes(demodir) + bytes(demos)), 'the demos: eight u16 offsets from here, then '
              'u8 tics, u8 key (1..4: up, down, left, right; 0xfe: a click, x / 2 and y follow; 0xfd: all found; 0xfb: a loop begins, its count and 0 follow; 0xfc: it ends) each; 0 ends one')]
    res = bytearray()
    lines = ['; dat.s: the layout of kira.dat. Written by tools/kira-assets.py: do not edit.', '']

    def equ(name, value, comment):
        lines.append(('%-9s = %-28s' % (name, value)).ljust(40) + '; ' + (comment or '...'))
    for name, data, comment in parts:
        assert len(res) % 8 == 0 and len(data) % 8 == 0, name
        equ(name, len(res), comment)
        res += data
    equ('R_SIZE', len(res), 'bytes of the resident block (the head of the file)')
    equ('F_SIZE', len(far), 'bytes of the far block (the rest of it)')
    equ('F_TILES', f_tiles, 'far offset of the tiles: walls 1..6, then floors 0..4; 256 bytes each')
    equ('F_FLATS', f_flats, 'far offset of the flats: floors 0..4, the ceiling; 1024 bytes each')
    equ('F_BAR', f_bar, 'far offset of the bar: ten 32 x 32 pieces')
    equ('NSPR', len(sprimgs), 'sprites')
    equ('NSND', nsnd, 'sounds')
    equ('NLIGHT', NLIGHT, 'light levels')
    equ('NFRIEND', len(FRIENDS), 'friends')
    equ('SND_RATE', SND_RATE, 'samples per second')
    equ('C_BLACK', index[(0, 0, 0)], 'palette indices: black')
    equ('C_WHITE', index[(255, 255, 255)], 'white')
    equ('C_PAPER', index[(254, 254, 254)], 'a colouring page not yet painted')
    equ('C_GREY', index[(165, 155, 185)], 'a friend not yet found')
    equ('C_SKY', index[(140, 200, 250)], 'the sky')
    equ('C_EDGE', index[(200, 180, 230)], 'the strip above and below the tiles')
    for name, value, comment in eq:
        equ(name, value, comment)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'kira.dat'), 'wb').write(bytes(res) + bytes(far))
    open(os.path.join(outdir, 'dat.s'), 'w').write('\n'.join(lines) + '\n')
    print('kira.dat: resident %d + far %d = %d bytes; %d colours, %d sprites, %d sounds, regions %s' %
          (len(res), len(far), len(res) + len(far), ncol, len(sprimgs), nsnd, nreg))
    if preview:                         # the sprites as a picture, to look at
        W = 640
        x = y = rowh = 0
        canvas = [[(120, 170, 120)] * W for _ in range(1200)]
        for w, h, img in sprimgs:
            if x + w > W:
                x, y, rowh = 0, y + rowh + 2, 0
            for yy in range(h):
                for xx in range(w):
                    if img[yy][xx] != TRANSP:
                        canvas[y + yy][x + xx] = rgb[img[yy][xx]]
            x += w + 2
            rowh = max(rowh, h)
        write_png(preview, W, y + rowh + 2, canvas[:y + rowh + 2])


if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    kira = os.path.join(here, '..', 'os', 'progs', 'kira')
    build(sys.argv[1] if len(sys.argv) > 1 else os.path.join(kira, 'art'),
          sys.argv[2] if len(sys.argv) > 2 else kira,
          sys.argv[3] if len(sys.argv) > 3 else None)
