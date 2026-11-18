#!/usr/bin/env python3
"""sushi-assets.py: the data file of os/progs/sushi.s (SushiBelt), from its art.

    tools/sushi-assets.py [ARTDIR [OUTDIR]]

ARTDIR is os/progs/sushi/art (the PNG files that tools/sushi-art.py draws,
specified in SPEC.md there), OUTDIR is os/progs/sushi. Writes

    OUTDIR/sushi.dat    what the game loads
    OUTDIR/dat.s        the layout of that file as assembler constants

The palette is the art's own (palette.txt there, every colour it uses);
the sounds are synthesised here; the sushi, the cooks, the evening and the
demos are defined here. Only the Python standard library is used, and the
PNG reader and the synthesiser are kira-assets.py's.

sushi.dat = a resident block (R_SIZE bytes, loaded into the game's D-LS:
tables and directories) and a far block (F_SIZE bytes, loaded into the top
of the game's arena: pixels and samples). Pixels are 8-bit palette indices;
index 255 is "transparent" in sprites.
  sprites   column-major, each column padded to a multiple of 8 bytes
  the bar   ten 32 x 32 pieces, row-major (one per 32-column slab)
  pictures  320 x 168 in ten slabs of 32 columns, each slab run-length
            coded row-major as (count, value) pairs
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

VW, VH = 320, 168                       # the view (the bar is 32 rows under it)
SND_RATE = 11025
TRANSP = 255
PIC_MAX = 3064                          # bytes of a picture's slab at most, coded (draw.s: scratch)
PICTURES = ['title', 'room']
BELT = [(16, 71, 303, 82), (16, 141, 303, 152), (3, 84, 14, 139), (305, 84, 316, 139)]   # the surface the game animates

# ---- the sushi: (name, plate colour, how it is made, price in yen) ---------------
# How: 0 nigiri (slice, then press the rice), 1 a roll (the mat), 2 gunkan (the
# rice, then the nori round it: the mat's frames).
PLATES = ['green', 'blue', 'red', 'gold', 'black']
KINDS = [('salmon', 1, 0, 150), ('tuna', 2, 0, 200), ('tamago', 0, 0, 100), ('ebi', 1, 0, 150),
         ('kappa', 0, 1, 100), ('ikura', 2, 2, 200), ('unagi', 3, 0, 300), ('uramaki', 3, 1, 300)]
COOKS = ['cook0', 'cook1', 'cook2']
COOK_FRAMES = ['idle_0', 'idle_1', 'slice_0', 'slice_1', 'rice_0', 'rice_1', 'roll_0', 'roll_1',
               'place_0', 'place_1', 'cheer', 'oops']
# tics each cook takes for each way of making: the owner is quick with nigiri, the
# woman in the red headscarf with rolls, the young cook is even
COOK_TICS = [(105, 200, 190), (165, 110, 125), (140, 145, 150)]
COOK_NAMES = [('HIRO', 'THE OWNER'), ('AIKO', 'THE ROLL EXPERT'), ('TARO', 'THE NEW COOK')]
CTEXT = 24                              # bytes of a line of a cook's text (R_CTEXT)
CUSTS = ['office', 'granny', 'student', 'tourist', 'artist', 'builder', 'kid', 'chef_fan']
CUST_FRAMES = ['sit_0', 'sit_1', 'want', 'eat_0', 'eat_1', 'happy', 'angry']
SMALL = ['cursor', 'select_cook', 'select_seat', 'fly_0', 'fly_1', 'stink_0', 'stink_1',
         'steam_0', 'steam_1', 'heart_0', 'heart_1', 'poof_0', 'poof_1', 'poof_2', 'coin',
         'star_0', 'star_1', 'bell_0', 'bell_1', 'panel']
FONT_S = ' 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-x:!?.%/$'    # $: the yen mark
FONT_B = '0123456789+-x:$'

# ---- the demos (`sushi demo N`): (tics to wait, key), one tic a frame -------------
# Keys: U D L R the arrows, _ none (a wait), > the tics after it are not drawn
# (until the next >), other characters themselves; @X:Y a click there. tools/test-sushi.sh compares the last frame of each.
DEMOS = {
    1: "5 .",                                       # the title
    2: "3  ,5 .",                                   # how to play
    3: "3  ,2  ,5 .",                               # ... its second page: the cooks
    4: "3  ,2  ,2  ,400 _",                         # the evening starts: customers come in and sit
    5: "3  ,2  ,2  ,300 _,1 1,2 2,2 3,150 _",       # orders given by keys: the cooks make them, a plate rides
    6: "3  ,2  ,2  ,300 _,2 @208:24,2 @160:96,120 _,2 @240:24,2 @282:184,700 _",   # ... by clicks: a bubble, a cook, a cook's box
    7: "3  ,2  ,2  ,300 _,1 1,1 R,1 1,130 _,1 @76:146,4 _",     # one order given twice; a plate swept off by a click
    8: "3  ,2  ,2  ,300 _,1 1,1 R,1 1,1 R,1 1,1 >,2390 _,1 >,10 _,1 z,5 _",   # plates nobody takes go stale; Z sweeps one off
    9: "3  ,2  ,2  ,1 >,1460 _,1 >,10 _",           # left alone: the first customer waits too long and goes
    10: "3  ,2  ,2  ,1 >,1 {220,1 1,1 2,1 3,30 _,1 },1 >,200 _",   # a whole evening, every order given at once: the results
    11: "3  ,2  ,2  ,300 _,1 1,1 1,60 _,1 i,1 i,3 _",   # I: how you earn, then the owner's card with his queue
    12: "3  ,2  ,2  ,300 _,1 1,2 2,2 3,300 _,2 @92:184,30 _,2 .,2 @40:184,3 _",   # a click on a face: a card that holds the evening; one on the money
    13: "3  ,2  ,2  ,300 _,1 1,2 2,2 3,545 _",      # a customer pays: what for, rising over them
}
KEYS = {'U': 1, 'D': 2, 'L': 3, 'R': 4, '}': 0xfc, '~': 0xfa, '>': 0xf9, '_': 0}
NDEMO = 13


def make_sounds():
    rnd = random.Random(11)
    noise = [rnd.uniform(-1, 1) for _ in range(SND_RATE)]
    snd = []
    snd.append(('POP', synth(0.08, lambda t, _: math.sin(2 * math.pi * sweep(t, 0.08, 900, 350)) * 0.7)))

    def ding(t, _):                     # the door bell: two bright partials, ringing
        return (math.sin(2 * math.pi * 1568 * t) * 0.5 + math.sin(2 * math.pi * 2350 * t) * 0.25 +
                math.sin(2 * math.pi * 3920 * t) * 0.1) * math.exp(-5 * t)
    snd.append(('BELL', synth(0.7, ding)))

    def chop(t, i):                     # a knife on the board
        v = 0.0
        for t0 in (0.0, 0.12):
            u = t - t0
            if u >= 0:
                v += (noise[(i * 5) % SND_RATE] * 0.5 + math.sin(2 * math.pi * 180 * u) * 0.5) * math.exp(-45 * u)
        return v
    snd.append(('CHOP', synth(0.25, chop)))

    def clack(t, i):                    # a plate set down on the belt
        return (math.sin(2 * math.pi * 1150 * t) * 0.5 + math.sin(2 * math.pi * 2710 * t) * 0.3 +
                noise[i % SND_RATE] * 0.15) * math.exp(-30 * t)
    snd.append(('CLACK', synth(0.18, clack)))

    def coins(t, _):                    # paid: a little run of coins
        v = 0.0
        for k, f in enumerate((1975.5, 2349.3, 2637.0)):
            u = t - k * 0.06
            if u >= 0:
                v += math.sin(2 * math.pi * f * u) * math.exp(-14 * u) * 0.35
        return v
    snd.append(('COINS', synth(0.4, coins)))

    def yum(t, _):                      # taken from the belt: a happy rising chirp
        return math.sin(2 * math.pi * sweep(t, 0.2, 520, 1040)) * 0.6 * bell(t, 0.2)
    snd.append(('YUM', synth(0.2, yum)))
    saw = [(k, 1.0 / k) for k in range(1, 7)]
    snd.append(('GRUMBLE', synth(0.45, lambda t, _: _kira.tone(sweep(t, 0.45, 210, 120), saw) * 0.35 *
                                 bell(t, 0.45) * (0.6 + 0.4 * math.sin(2 * math.pi * 18 * t)))))

    def whoosh(t, i):                   # swept off the belt
        return noise[(i * 3) % SND_RATE] * 0.5 * bell(t, 0.22) * (0.4 + 0.6 * t / 0.22)
    snd.append(('WHOOSH', synth(0.22, whoosh)))

    def oops(t, _):                     # a cook's queue is full
        f = 660 if t < 0.1 else 440
        return math.sin(2 * math.pi * f * t) * 0.5 * bell(t % 0.1, 0.1)
    snd.append(('OOPS', synth(0.2, oops)))

    def gong(t, _):                     # the evening is over
        return sum(a * math.sin(2 * math.pi * f * t) for f, a in ((196, 0.5), (293.7, 0.3), (392, 0.2))) * math.exp(-2.5 * t)
    snd.append(('GONG', synth(1.2, gong)))
    return snd


def build(art, outdir):
    def png(name):
        return read_png(os.path.join(art, name + '.png'))

    rgb = []
    names = {}
    for line in open(os.path.join(art, 'palette.txt')):
        h, n = line.split()
        c = tuple(bytes.fromhex(h))
        names[n] = len(rgb)
        rgb.append(c)
    assert len(rgb) <= 255, 'the art uses %d colours: 255 at most' % len(rgb)
    index = {c: i for i, c in enumerate(rgb)}
    ncol = len(rgb)
    rgb += [(0, 0, 0)] * (256 - len(rgb))

    def indices(name):
        w, h, rows = png(name)
        return w, h, [[index[(r, g, b)] if a >= 128 else TRANSP for r, g, b, a in row] for row in rows]

    far = bytearray()
    eq = []                             # (name, value, comment)

    def put(data):
        assert len(far) % 8 == 0
        off = len(far)
        far.extend(pad8(bytes(data)))
        return off

    sprdir = bytearray()
    nspr = [0]

    def sprite(sym, w, h, img, anchored):
        assert h <= 128, sym
        cs = (h + 7) & ~7
        cols = bytearray()
        for x in range(w):
            cols += bytes(img[y][x] for y in range(h)) + bytes([TRANSP] * (cs - h))
        ox, oy = (w // 2, h) if anchored else (0, 0)
        sprdir.extend(struct.pack('<IHHhhHH', put(cols), w, h, ox, oy, cs, 0))
        eq.append(('SP_' + sym.upper(), nspr[0], ''))
        nspr[0] += 1

    def sprite_png(name, anchored):
        w, h, img = indices(name)
        sprite(name, w, h, img, anchored)

    for c in PLATES:
        sprite_png('plate_' + c, True)
    for c in PLATES:
        sprite_png('plate_side_' + c, True)
    for k, _, _, _ in KINDS:
        for s in range(3):
            sprite_png('sushi_%s_%d' % (k, s), True)
    for c in COOKS:
        for f in COOK_FRAMES:
            sprite_png('%s_%s' % (c, f), True)
        sprite_png(c + '_face', False)
    for c in CUSTS:
        for f in CUST_FRAMES:
            sprite_png('cust_%s_%s' % (c, f), True)
    sprite_png('bubble', True)
    sprite_png('bubble_sel', True)
    for n in SMALL:
        if n == 'panel':                # the board hangs over the room: its night is not drawn
            w, h, img = indices(n)
            sprite(n, w, h, [[TRANSP if v == names['night'] else v for v in r] for r in img], False)
        else:
            sprite_png(n, False)
    for font, chars, cw, ch in (('font_small', FONT_S, 6, 8), ('font_big', FONT_B, 10, 14)):
        w, h, img = indices(font)
        assert (w, h) == (cw * len(chars), ch), font
        for i in range(len(chars)):
            sprite('%s_%d' % (font, i), cw, ch, [r[i * cw:(i + 1) * cw] for r in img], False)

    w, h, img = indices('bar')
    assert (w, h) == (320, 32) and all(TRANSP not in r for r in img)
    f_bar = len(far)
    for s in range(10):
        put(b''.join(bytes(img[y][s * 32:s * 32 + 32]) for y in range(32)))

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
    for name in PICTURES:
        w, h, img = indices(name)
        assert (w, h) == (VW, VH) and all(TRANSP not in r for r in img), name
        if name == 'room':              # the belt's slats are the game's to draw (they move):
            for x0, y0, x1, y1 in BELT:  #   its surface is coded plain
                for y in range(y0, y1 + 1):
                    for x in range(x0, x1 + 1):
                        if img[y][x] == names['slate_d']:
                            img[y][x] = names['slate']
        eq.append(('PIC_' + name.upper(), len(picdir) // 80, ''))
        picdir += rle(img)

    snddir = bytearray()
    for i, (name, data) in enumerate(make_sounds()):
        snddir += struct.pack('<II', put(data), len(data))
        eq.append(('SN_' + name, i, ''))
    nsnd = len(snddir) // 8

    kinds = b''.join(struct.pack('<BBH', p, how, price) for _, p, how, price in KINDS)
    cooks = b''.join(struct.pack('<HHH', *t) + b'\0\0' for t in COOK_TICS)
    # each cook's lines of text, from their times: their card (name, role, how
    # long nigiri and rolls take, fast or slow among the three) and their two
    # lines on the second page of how to play
    ctext = bytearray()

    def line(t):
        assert len(t) < CTEXT and all(ch in FONT_S for ch in t), t
        return t.encode() + bytes(CTEXT - len(t))
    for i, ((name, role), tics) in enumerate(zip(COOK_NAMES, COOK_TICS)):
        word = []
        for how in (0, 1):
            ts = [c[how] for c in COOK_TICS]
            word.append('FAST' if tics[how] == min(ts) else 'SLOW' if tics[how] == max(ts) else '')
        secs = ['%d.%d S' % divmod(round(t * 10 / 35), 10) for t in tics[:2]]
        if word[0] == 'FAST':
            sum1, sum2 = name + ': FAST NIGIRI', word[1] and word[1] + ' ROLLS' or ''
        elif word[1] == 'FAST':
            sum1, sum2 = name + ': FAST ROLLS', word[0] and word[0] + ' NIGIRI' or ''
        else:
            sum1, sum2 = name + ': EVEN AT BOTH', 'NEVER FAST NEVER SLOW'
        ctext += b''.join(line(t) for t in (
            '%d %s' % (i + 1, name), role, ('NIGIRI ' + secs[0] + ' ' + word[0]).strip(),
            ('ROLLS  ' + secs[1] + ' ' + word[1]).strip(), sum1, sum2))
    fonts = bytearray(256)
    for i, ch in enumerate(FONT_S):
        fonts[ord(ch)] = i
    for i in range(128):
        fonts[128 + i] = 255
    for i, ch in enumerate(FONT_B):
        fonts[128 + ord(ch)] = i
    for ch in 'abcdefghijklmnopqrstuvwxyz':
        if ch != 'x':
            fonts[ord(ch)] = fonts[ord(ch.upper())]
    demos = bytearray()
    demodir = bytearray()
    for n in range(1, NDEMO + 1):
        demodir += struct.pack('<H', 2 * NDEMO + len(demos))
        for step in DEMOS.get(n, "1 .").split(','):
            t, k = step.split(' ', 1)
            t = int(t)
            while t > 255:              # a long wait: waits with no key first
                demos += bytes((255, 0))
                t -= 255
            if k.startswith('@'):       # a click
                x, y = k[1:].split(':')
                demos += bytes((int(t), 0xfe, int(x) // 2, int(y)))
            elif k.startswith('{'):     # what follows, up to }, so many times
                demos += bytes((int(t), 0xfb, int(k[1:]), 0))
            else:
                demos += bytes((int(t), KEYS.get(k, ord(k))))
        demos += b'\0\0'

    palb = b''.join(bytes((b, g, r, 0)) for r, g, b in rgb)
    parts = [('R_PAL', palb, 'the palette (XRGB8888)'),
             ('R_SPR', bytes(sprdir), 'sprites: u32 far offset, u16 w, h, s16 ox, oy, u16 column bytes, u16 0'),
             ('R_SND', pad8(bytes(snddir)), 'sounds: u32 far offset, u32 samples'),
             ('R_PIC', bytes(picdir), 'pictures: ten slabs each: u32 far offset, u16 coded bytes, u16 0'),
             ('R_KIND', pad8(kinds), 'the sushi: u8 plate colour, u8 how it is made (0 nigiri, 1 roll, 2 gunkan), u16 price'),
             ('R_COOK', cooks, 'the cooks: u16 tics for nigiri, a roll, gunkan; u16 0'),
             ('R_CTEXT', pad8(bytes(ctext)), 'the cooks\' text: six lines of CTEXT bytes each, NUL-padded: '
              'number and name, role, nigiri, rolls; the two lines of how to play'),
             ('R_FONT', bytes(fonts), 'characters to glyphs: 128 of the small font, 128 of the big one (255: none)'),
             ('R_DEMO', pad8(bytes(demodir) + bytes(demos)), 'the demos: NDEMO u16 offsets from here, then '
              'u8 tics, u8 key (1..4: up, down, left, right; 0xfe: a click, x / 2 and y follow; 0xfb: a loop '
              'begins, its count and 0 follow; 0xfc: it ends; 0xfa: the random numbers start over; 0xf9: the tics '
              'after it are not drawn, until the next) each; 0 ends one')]
    res = bytearray()
    lines = ['; dat.s: the layout of sushi.dat. Written by tools/sushi-assets.py: do not edit.', '']

    def equ(name, value, comment):
        lines.append(('%-9s = %-28s' % (name, value)).ljust(40) + '; ' + (comment or '...'))
    for name, data, comment in parts:
        assert len(res) % 8 == 0 and len(data) % 8 == 0, name
        equ(name, len(res), comment)
        res += data
    equ('R_SIZE', len(res), 'bytes of the resident block (the head of the file)')
    equ('F_SIZE', len(far), 'bytes of the far block (the rest of it)')
    equ('F_BAR', f_bar, 'far offset of the bar: ten 32 x 32 pieces')
    equ('NSPR', nspr[0], 'sprites')
    equ('NSND', nsnd, 'sounds')
    equ('NKIND', len(KINDS), 'kinds of sushi')
    equ('NCUST', len(CUSTS), 'kinds of customer')
    equ('NCOOKF', len(COOK_FRAMES) + 1, 'sprites per cook: the frames, then the face')
    equ('NCUSTF', len(CUST_FRAMES), 'sprites per customer')
    equ('NDEMO', NDEMO, 'demos')
    equ('CTEXT', CTEXT, 'bytes of a line of a cook\'s text')
    equ('SND_RATE', SND_RATE, 'samples per second')
    for n in ('ink', 'black', 'white', 'slate_d', 'slate', 'patience_green', 'patience_yellow',
              'patience_red', 'progress', 'gold', 'select', 'walnut_d', 'grey_d'):
        equ('C_' + n.upper(), names[n], 'palette indices: ' + n.replace('_', ' '))
    for name, value, comment in eq:
        equ(name, value, comment)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'sushi.dat'), 'wb').write(bytes(res) + bytes(far))
    open(os.path.join(outdir, 'dat.s'), 'w').write('\n'.join(lines) + '\n')
    print('sushi.dat: resident %d + far %d = %d bytes; %d colours, %d sprites, %d sounds' %
          (len(res), len(far), len(res) + len(far), ncol, nspr[0], nsnd))


if __name__ == '__main__':
    sushi = os.path.join(HERE, '..', 'os', 'progs', 'sushi')
    build(sys.argv[1] if len(sys.argv) > 1 else os.path.join(sushi, 'art'),
          sys.argv[2] if len(sys.argv) > 2 else sushi)
