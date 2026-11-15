#!/usr/bin/env python3
"""plat-assets.py: the data file of os/progs/plat.s, from its art.

    tools/plat-assets.py [ARTDIR [OUTDIR]]

ARTDIR is os/progs/plat/art (the PNG files that tools/plat-art.py draws,
specified in SPEC.md there), OUTDIR is os/progs/plat. Writes

    OUTDIR/plat.dat     what the game loads
    OUTDIR/dat.s        the layout of that file as assembler constants

The palette is made here from the colours the art uses; the sounds are
synthesised here; the lookup tables and the demos are defined here. Only
the Python standard library is used.

plat.dat = a resident block (R_SIZE bytes, loaded into the game's D-LS:
the palette, tables, directories, the demos) and a far block (F_SIZE
bytes, loaded into the top of the game's arena: pixels and samples).
Pixels are 8-bit palette indices; index 255 is "transparent" in sprites.
  cells     16 x 16, row-major, 256 bytes each: everything on the map,
            the zones and the plant cut into their cells
  sprites   row-major, each row padded to a multiple of 8 bytes
  sounds    signed 8-bit mono, 11025 Hz
"""
import importlib.util
import math
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('kira_assets', os.path.join(HERE, 'kira-assets.py'))
_kira = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_kira)
read_png, synth, sweep, bell, pad8 = _kira.read_png, _kira.synth, _kira.sweep, _kira.bell, _kira.pad8

SND_RATE = 11025
TRANSP = 255
WATER_RAMP = {'245868', '2c7180', '398b95', '63aeb1', 'b1d8ce'}   # the art's water colours
CELL = 16

# ---- what a cell is (its kind: the program's K_* constants) ------------------------
KINDS = ['GROUND', 'DIRT', 'RUBBLE', 'WOODS', 'WATER', 'ROAD', 'BRIDGE', 'LINE', 'LROAD',
         'LWATER', 'ZONE', 'PLANT', 'RAIL', 'RBRIDGE', 'RROAD', 'LRAIL', 'POLICE', 'FIREST',
         'PARK', 'BURN']
ZONES = ['res', 'com', 'ind']
ZONE_PICS = ['empty', 'site'] + ['%d_%s' % (n, v) for n in range(1, 5) for v in 'ab']

SPRITES = ['button', 'button_down',
           'tool_bulldoze', 'tool_road', 'tool_line', 'tool_res', 'tool_com', 'tool_ind',
           'tool_coal', 'tool_query',
           'speed_pause', 'speed_slow', 'speed_normal', 'speed_fast',
           'icon_funds', 'icon_date', 'icon_pop', 'nopower', 'noroad', 'logo', 'app',
           'tool_zoom_in', 'tool_zoom_out',
           'tool_rail', 'tool_police', 'tool_fire', 'tool_park', 'tool_solar', 'tool_budget',
           'tool_map', 'jam', 'adv_clerk', 'adv_engineer', 'adv_shopkeeper', 'adv_resident',
           'paper_head']

# ---- the demos (`plat demo N`): (tics to wait, key), one tic a frame ---------------
# Keys: U D L R the arrows, _ Space, ^ Enter, {N what follows up to } N times,
# other characters themselves. tools/test-plat.sh checks what each ends with.
DEMOS = {
    # a road drawn with the pen (Enter), round a block and across the river
    # (a bridge), a power line along it and over the water and a road, woods
    # bulldozed, a cell asked about, the view zoomed and scrolled
    1: "5 r,5 ^,{12,2 R,},{6,2 D,},{12,2 L,},{6,2 U,},2 ^,"
       "5 D,3 D,3 D,3 l,3 ^,{14,2 R,},2 ^,"
       "5 b,3 ^,{4,2 D,},2 ^,"
       "5 r,3 U,3 U,3 U,3 U,3 U,3 U,3 U,3 ^,{40,1 L,},2 ^,"
       "5 i,3 _,10 z,10 R,10 x,10 x,10 x,10 .",
    # time: the fastest speed for a year and a half, then a pause
    2: "5 =,3 =,{30,30 .,},5 0,10 .",
    # what money stops: a long road with too little left for it
    3: "5 r,3 ^,{8,1 D,{126,1 R,},1 D,{126,1 L,},},2 ^,10 .",
    # at 32 pixels a cell: a power line west over the river
    4: "5 z,5 l,3 ^,{30,2 L,},2 ^,10 .",
    # a town: a coal plant, a road, a power line to the zones and across the
    # road, homes, shops and offices, industry; then two years at the
    # fastest speed
    5: "5 p,3 _,{4,1 L,},{4,1 D,},3 r,3 ^,{40,1 R,},3 ^,"
       "{33,1 L,},{3,1 U,},3 l,3 ^,{3,1 R,},{5,1 D,},3 ^,"
       "{2,1 R,},{4,1 U,},3 1,3 _,{3,1 R,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 2,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 3,{15,1 L,},{4,1 D,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 1,{3,1 R,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "{10,1 U,},3 _,"
       "5 =,3 =,{28,30 .,},5 0,10 .",
    # the town in a file: a plant, a road, zones, a year; saved; bulldozed
    # and taxed differently; the saved town back (the map must be the one
    # that was saved)
    6: "5 p,3 _,{4,1 R,},3 r,3 ^,{12,1 R,},3 ^,"
       "{13,1 L,},1 U,3 l,3 ^,{8,1 R,},3 ^,{2,1 R,},1 U,3 1,3 _,"
       "5 =,3 =,{12,30 .,},5 0,5 s,"
       "5 b,3 ^,{6,1 L,},3 ^,5 ],5 ],10 o,10 .",
    # the fuller city: a coal plant, a road, a line, homes, a police
    # station, shops, a fire station, industry, a park, rail across the
    # road, a solar plant; two years; the budget (less for the police and
    # the fire service); the pollution map over the town
    7: "5 p,3 _,{4,1 L,},{4,1 D,},3 r,3 ^,{40,1 R,},3 ^,"
       "{33,1 L,},{3,1 U,},3 l,3 ^,{3,1 R,},{5,1 D,},3 ^,"
       "{2,1 R,},{4,1 U,},3 1,3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 4,{3,1 R,},3 _,3 2,{3,1 R,},3 _,3 5,{3,1 R,},3 _,"
       "{15,1 L,},{4,1 D,},3 3,3 _,{3,1 R,},3 _,3 6,{2,1 R,},3 _,1 R,3 _,"
       "3 1,{3,1 R,},3 _,"
       "{9,1 R,},{10,1 U,},3 t,3 ^,{16,1 D,},3 ^,"
       "{6,1 R,},{14,1 U,},3 e,3 _,"
       "5 =,3 =,{24,30 .,},"
       "5 g,3 D,3 L,3 D,3 L,3 ^,5 m,3 m,3 m,5 0,10 .",
    # demo 5's town, and the Plat Ledger at the end
    8: "5 p,3 _,{4,1 L,},{4,1 D,},3 r,3 ^,{40,1 R,},3 ^,"
       "{33,1 L,},{3,1 U,},3 l,3 ^,{3,1 R,},{5,1 D,},3 ^,"
       "{2,1 R,},{4,1 U,},3 1,3 _,{3,1 R,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 2,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 3,{15,1 L,},{4,1 D,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 1,{3,1 R,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "{10,1 U,},3 _,"
       "5 =,3 =,{28,30 .,},5 0,5 j",
    # demo 5's town, and its history at the end
    9: "5 p,3 _,{4,1 L,},{4,1 D,},3 r,3 ^,{40,1 R,},3 ^,"
       "{33,1 L,},{3,1 U,},3 l,3 ^,{3,1 R,},{5,1 D,},3 ^,"
       "{2,1 R,},{4,1 U,},3 1,3 _,{3,1 R,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 2,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 3,{15,1 L,},{4,1 D,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "3 1,{3,1 R,},3 _,{3,1 R,},3 _,{3,1 R,},3 _,"
       "{10,1 U,},3 _,"
       "5 =,3 =,{28,30 .,},5 0,5 h",
}
KEYS = {'U': 1, 'D': 2, 'L': 3, 'R': 4, '_': 32, '^': 13, '}': 0xfc}


def make_sounds():
    rnd = random.Random(11)
    noise = [rnd.uniform(-1, 1) for _ in range(SND_RATE)]
    snd = []
    snd.append(('CLICK', synth(0.05, lambda t, _: math.sin(2 * math.pi * sweep(t, 0.05, 1400, 900)) * 0.6 *
                              math.exp(-40 * t))))

    def build(t, i):                    # a road laid: a short gritty thump
        return (noise[(i * 5) % SND_RATE] * 0.35 * math.exp(-30 * t) +
                math.sin(2 * math.pi * sweep(t, 0.12, 180, 90)) * 0.5 * math.exp(-18 * t))
    snd.append(('BUILD', synth(0.12, build)))

    def wire(t, _):                     # a power line strung: a soft twang
        return (math.sin(2 * math.pi * 330 * t) * 0.5 + math.sin(2 * math.pi * 495 * t) * 0.25) * \
            math.exp(-12 * t) * (1 + 0.2 * math.sin(2 * math.pi * 7 * t))
    snd.append(('WIRE', synth(0.25, wire)))

    def doze(t, i):                     # the bulldozer: engine rumble and rubble
        eng = math.sin(2 * math.pi * 55 * t) * 0.4 + math.sin(2 * math.pi * 110 * t) * 0.2
        grit = noise[(i * 7) % SND_RATE] * 0.25 * (0.5 + 0.5 * math.sin(2 * math.pi * 23 * t))
        return (eng + grit) * bell(t, 0.3)
    snd.append(('DOZE', synth(0.3, doze)))
    snd.append(('NOPE', synth(0.22, lambda t, _: (math.sin(2 * math.pi * 140 * t) +
                                                  0.5 * math.sin(2 * math.pi * 280 * t)) * 0.35 *
                              bell(t, 0.22))))

    def coin(t, _):                     # a new month: two bright pings
        v = 0.0
        for t0, f in ((0.0, 1318.5), (0.08, 1760.0)):
            u = t - t0
            if u >= 0:
                v += math.sin(2 * math.pi * f * u) * math.exp(-14 * u) * 0.35
        return v
    snd.append(('COIN', synth(0.35, coin)))
    return snd


def blob_table():
    """raw 8-neighbour mask (N 1, NE 2, E 4, SE 8, S 16, SW 32, W 64, NW 128)
    -> index of the water cell (SPEC.md: the 47 cleared masks in order)"""
    def clear(m):
        for d, a, b in ((2, 1, 4), (8, 4, 16), (32, 16, 64), (128, 64, 1)):
            if not (m & a and m & b):
                m &= ~d
        return m
    masks = sorted({clear(m) for m in range(256)})
    assert len(masks) == 47
    return bytes(masks.index(clear(m)) for m in range(256)), masks


def build(art, outdir):
    def png(name):
        return read_png(os.path.join(art, name + '.png'))

    # ---- the cells, in the order the program's T_* constants give
    cells = []                          # (name, rows of rgba 16 x 16)
    kinds = bytearray()
    eq = []

    def add(const, kind, imgs, comment):
        eq.append((const, len(cells), comment))
        for name, rows in imgs:
            cells.append((name, rows))
            kinds.append(KINDS.index(kind))

    def single(name):
        w, h, rows = png(name)
        assert (w, h) == (CELL, CELL), name
        return (name, rows)

    def strip(name, n, horizontal=False):
        w, h, rows = png(name)
        out = []
        for i in range(n):
            x0, y0 = (i * CELL, 0) if horizontal else (0, i * CELL)
            out.append(('%s %d' % (name, i), [r[x0:x0 + CELL] for r in rows[y0:y0 + CELL]]))
        assert (w, h) == ((n * CELL, CELL) if horizontal else (CELL, n * CELL)), name
        return out

    def cut(name, n):                   # an n x n picture, row by row
        w, h, rows = png(name)
        assert (w, h) == (n * CELL, n * CELL), name
        return [('%s %d,%d' % (name, cx, cy), [r[cx * CELL:(cx + 1) * CELL] for r in rows[cy * CELL:(cy + 1) * CELL]])
                for cy in range(n) for cx in range(n)]

    blob, masks = blob_table()
    wm = [int(l) for l in open(os.path.join(art, 'water_masks.txt')).read().split()]
    assert wm == masks, 'water_masks.txt is not the 47 masks in order'
    add('T_GROUND', 'GROUND', [single('ground_%d' % i) for i in range(4)], 'plain ground: 4 variants')
    add('T_DIRT', 'DIRT', [single('dirt')], 'cleared earth')
    add('T_RUBBLE', 'RUBBLE', [single('rubble_%d' % i) for i in range(2)], 'rubble: 2 variants')
    add('T_WOODS', 'WOODS', [single('woods_%d' % i) for i in range(4)], 'woods: 4 variants')
    add('T_WATER', 'WATER', strip('water', 47), 'water: 47 joins (R_BLOB)')
    add('T_ROAD', 'ROAD', strip('road', 16), 'roads: + mask (N 1, E 2, S 4, W 8)')
    water = strip('water', 47)

    def over(name):                     # a picture's own pixels (not the water's) over each water cell
        out = []
        for way, (_, top) in enumerate(strip(name, 2, True)):
            for i, (_, under) in enumerate(water):
                out.append(('%s %d over water %d' % (name, way, i),
                            [[t if '%02x%02x%02x' % t[:3] not in WATER_RAMP else u for t, u in zip(tr, ur)]
                             for tr, ur in zip(top, under)]))
        return out
    add('T_BRIDGE', 'BRIDGE', over('bridge'), 'bridges: E-W, then N-S, each over the 47 water cells')
    add('T_LINE', 'LINE', strip('line', 16), 'power lines: + mask')
    add('T_LROAD', 'LROAD', strip('line_road', 2, True), 'a line N-S over an E-W road; E-W over N-S')
    add('T_LWATER', 'LWATER', over('line_water'), 'a line over water: E-W, then N-S, each over the 47')
    for k in ZONES:
        for p in ZONE_PICS:
            add('T_%s_%s' % (k.upper(), p.upper()), 'ZONE', cut('zone_%s_%s' % (k, p), 3),
                'a 3 x 3 zone: 9 cells, row by row')
    add('T_COAL', 'PLANT', cut('coal_0', 4) + cut('coal_1', 4), 'the coal plant: 2 frames of 16 cells')
    add('T_RAIL', 'RAIL', strip('rail', 16), 'rail: + mask (N 1, E 2, S 4, W 8)')
    add('T_RBRIDGE', 'RBRIDGE', over('rail_bridge'), 'rail bridges: E-W, then N-S, each over the 47 water cells')
    add('T_RROAD', 'RROAD', strip('rail_road', 2, True), 'a crossing: rail N-S over an E-W road; E-W over N-S')
    add('T_LRAIL', 'LRAIL', strip('line_rail', 2, True), 'a line N-S over an E-W track; E-W over N-S')
    add('T_TLIGHT', 'ROAD', strip('traffic_light', 16), 'roads with light traffic: + mask')
    add('T_THEAVY', 'ROAD', strip('traffic_heavy', 16), 'roads with heavy traffic: + mask')
    add('T_POLICE', 'POLICE', cut('police', 3), 'a police station: 9 cells')
    add('T_FIREST', 'FIREST', cut('fire', 3), 'a fire station: 9 cells')
    add('T_PARK', 'PARK', [single('park_0'), single('park_1')], 'small parks: 2 designs')
    add('T_SOLAR', 'PLANT', cut('solar_0', 4) + cut('solar_1', 4), 'the solar plant: 2 frames of 16 cells')
    add('T_BURN', 'BURN', [single('fire_%d' % i) for i in range(4)], 'a cell on fire: 4 frames')
    ncell = len(cells)
    assert ncell <= 1024

    sprimgs = []
    for name in SPRITES:
        w, h, rows = png(name)
        sprimgs.append((name, w, h, rows))

    # ---- the palette: every opaque colour used, in order of first use
    rgb = []
    index = {}

    def idx(px):
        if px[3] == 0:
            return TRANSP
        c = px[:3]
        if c not in index:
            index[c] = len(rgb)
            rgb.append(c)
        return index[c]
    for c in open(os.path.join(art, 'ui_colours.txt')).read().split('\n'):
        if c.strip():
            idx(tuple(bytes.fromhex(c.split()[1])) + (255,))
    extra = {'C_CURSOR': (255, 226, 77), 'C_PEN': (232, 74, 58), 'C_WHITE': (255, 255, 255)}
    for c in extra.values():
        idx(c + (255,))
    celldata = bytearray()
    for name, rows in cells:
        for r in rows:
            for px in r:
                assert px[3] == 255, name + ': a cell must be opaque'
                celldata.append(idx(px))
    far = bytearray(celldata)
    sprdir = bytearray()
    for name, w, h, rows in sprimgs:
        sprdir += struct.pack('<IHH', len(far), w, h)
        stride = (w + 7) & ~7
        for r in rows:
            far += bytes(idx(px) for px in r) + bytes([TRANSP] * (stride - w))
    ncol = len(rgb)
    assert ncol < 255, 'too many colours'
    while len(rgb) < 256:
        rgb.append((0, 0, 0))
    ui = {}
    for c in open(os.path.join(art, 'ui_colours.txt')).read().split('\n'):
        if c.strip():
            ui[c.split()[0]] = index[tuple(bytes.fromhex(c.split()[1]))]

    sounds = make_sounds()
    snddir = bytearray()
    for name, s in sounds:
        far = pad8(far)
        snddir += struct.pack('<II', len(far), len(s))
        far += s
    far = pad8(far)

    # ---- the demos
    demodir = bytearray()
    demos = bytearray()
    ndemo = 9
    for n in range(1, ndemo + 1):
        demodir += struct.pack('<H', 2 * ndemo + len(demos))
        for step in DEMOS.get(n, "1 .").split(','):
            t, k = step.split(' ', 1) if ' ' in step else (step, '')
            if k.startswith('{'):       # what follows, up to }, so many times
                demos += bytes((int(t), 0xfb, int(k[1:]), 0))
            elif t.startswith('{'):
                demos += bytes((1, 0xfb, int(t[1:]), 0))
            elif t == '}':
                demos += bytes((1, 0xfc))
            else:
                demos += bytes((int(t), KEYS.get(k, ord(k[0]) if k else ord('.'))))
        demos += b'\0\0'

    avg = bytearray()                   # each cell's mean colour, as the palette's nearest
    for name, rows in cells:
        m = [sum(px[c] for r in rows for px in r) / 256 for c in range(3)]
        avg.append(min(range(ncol), key=lambda i: sum((rgb[i][c] - m[c]) ** 2 for c in range(3))))
    palb = b''.join(bytes((b, g, r, 0)) for r, g, b in rgb)
    parts = [('R_PAL', palb, 'the palette (XRGB8888)'),
             ('R_KIND', pad8(bytes(kinds)), 'the kind of each cell picture (K_*)'),
             ('R_BLOB', blob, 'water: a cell\'s 8-neighbour mask -> its picture after T_WATER'),
             ('R_SPR', pad8(bytes(sprdir)), 'sprites: u32 far offset, u16 w, h (rows of (w + 7) & ~7 bytes)'),
             ('R_SND', pad8(bytes(snddir)), 'sounds: u32 far offset, u32 samples'),
             ('R_AVG', pad8(bytes(avg)), 'each cell picture\'s colour, the nearest to its mean (the minimap)'),
             ('R_DEMO', pad8(bytes(demodir) + bytes(demos)), 'the demos: nine u16 offsets from here, then '
              'u8 tics, u8 key (1..4: up, down, left, right; 0xfb: a loop begins, its count and 0 follow; '
              '0xfc: it ends) each; 0 ends one')]
    res = bytearray()
    lines = ['; dat.s: the layout of plat.dat. Written by tools/plat-assets.py: do not edit.', '']

    def equ(name, value, comment):
        lines.append(('%-9s = %-28s' % (name, value)).ljust(40) + '; ' + (comment or '...'))
    for name, data, comment in parts:
        assert len(res) % 8 == 0 and len(data) % 8 == 0, name
        equ(name, len(res), comment)
        res += data
    equ('R_SIZE', len(res), 'bytes of the resident block (the head of the file)')
    equ('F_SIZE', len(far), 'bytes of the far block (the rest of it)')
    equ('F_CELLS', 0, 'far offset of the cell pictures: 256 bytes each')
    equ('NCELL', ncell, 'cell pictures')
    equ('NBLOB', 47, 'water cells (a bridge\'s, a line\'s over the water: their way * NBLOB + this)')
    equ('NSND', len(sounds), 'sounds')
    equ('SND_RATE', SND_RATE, 'samples per second')
    for i, k in enumerate(KINDS):
        equ('K_' + k, i, 'a kind of cell' if i == 0 else None)
    for name, value, comment in eq:
        equ(name, value, comment)
    for i, name in enumerate(SPRITES):
        equ('SP_' + name.upper(), i, 'sprites' if i == 0 else None)
    for i, (name, _) in enumerate(sounds):
        equ('SN_' + name, i, 'sounds' if i == 0 else None)
    for name in ('panel', 'panel_light', 'panel_dark', 'text', 'text_dim', 'good', 'bad', 'res', 'com', 'ind'):
        equ('C_' + name.upper(), ui[name], 'palette indices: the panels and the text' if name == 'panel' else None)
    for name, c in extra.items():
        equ(name, index[c], None)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'plat.dat'), 'wb').write(bytes(res) + bytes(far))
    open(os.path.join(outdir, 'dat.s'), 'w').write('\n'.join(lines) + '\n')
    print('plat.dat: resident %d + far %d = %d bytes; %d colours, %d cells, %d sprites, %d sounds' %
          (len(res), len(far), len(res) + len(far), ncol, ncell, len(sprimgs), len(sounds)))


if __name__ == '__main__':
    plat = os.path.join(HERE, '..', 'os', 'progs', 'plat')
    build(sys.argv[1] if len(sys.argv) > 1 else os.path.join(plat, 'art'),
          sys.argv[2] if len(sys.argv) > 2 else plat)
