#!/usr/bin/env python3
"""Draw Plat's original pixel art. Python 3, no dependencies or input assets.

All coordinates are native pixels; there is no antialiasing or resampling.
Run from any directory. Only the named outputs beside SPEC.md are written.
Only the logos, paper masthead and contact-sheet captions contain lettering.
"""
from pathlib import Path
import hashlib
import math
import struct
import zlib

OUT = Path(__file__).resolve().parents[1] / 'os/progs/plat/art'
# Named ramps, ordered from shadow to sunlight. Never blend RGB colours.
HEX = {
    'grass_d':'6c934c', 'grass':'94b966', 'grass_l':'b7cf7b',
    'leaf_d':'365f47', 'leaf':'4f8651', 'leaf_m':'71a45a', 'leaf_l':'a4c671',
    'soil_d':'927655', 'soil':'bc9c72', 'soil_l':'d8bd8c',
    'sand':'e7d5a3', 'sand_l':'f6e7bb',
    'water_d':'245868', 'water':'2c7180', 'water_m':'398b95',
    'water_l':'63aeb1', 'foam':'b1d8ce',
    'road_d':'666960', 'road':'85877a', 'road_l':'a6a797',
    'kerb':'dfd8b9', 'stripe':'f3dea0',
    'pave_d':'9b9c8b', 'pave':'c0c1ad', 'pave_l':'d6d7bf',
    'ink':'34494a', 'wood_d':'685443', 'wood':'9b7650', 'wood_l':'cba373',
    'cream_d':'b5aa8c', 'cream':'e2d7b4', 'white':'fff0d2',
    'red_d':'854f43', 'red':'b96850', 'red_l':'df916d',
    'coral_d':'a3594f', 'coral':'d98370', 'coral_l':'efad88',
    'slate_d':'415e6a', 'slate':'63838c', 'slate_l':'91afb1',
    'glass_d':'2d626d', 'glass':'4c969e', 'glass_l':'9bd0c5',
    'rust_d':'77543e', 'rust':'aa7349', 'rust_l':'d2a15f',
    'metal_d':'6a7b78', 'metal':'9eaca2', 'metal_l':'cfdbca',
    'amber_d':'a67437', 'amber':'e3ae4f', 'amber_l':'f7d27a',
    'res':'41916a', 'com':'479fb9', 'ind':'e5a34a',
    'mint':'a2d6ac', 'bad':'c4574b', 'good':'41916a',
    'panel':'e8e4d1', 'panel_light':'fff4dc', 'panel_dark':'b4b5a3',
    'text':'34494a', 'text_dim':'738275',
    'coal':'46514d', 'coal_l':'65716a', 'smoke':'c6cfbe',
}
P = {k: tuple(bytes.fromhex(v)) + (255,) for k, v in HEX.items()}
# Part two adds only these ramps; all first-part colours remain untouched.
EXTRA_HEX = {
    'solar_d':'293f61', 'solar':'385b86', 'solar_l':'648db0',
    'skin_d':'855947', 'skin':'b47b58', 'skin_l':'daa578',
    'skin_deep_d':'59453d', 'skin_deep':'805a48', 'skin_deep_l':'ac7a58',
    'skin_fair_d':'bd8d71', 'skin_fair':'e2b995', 'skin_fair_l':'f4d5ae',
    'flame_d':'c36337', 'flame':'ee903f', 'flame_l':'ffe69b',
}
assert not set(EXTRA_HEX) & set(HEX)
P.update({k: tuple(bytes.fromhex(v)) + (255,) for k, v in EXTRA_HEX.items()})
CLEAR = (0, 0, 0, 0)


class Image:
    def __init__(self, w, h, color=None):
        self.w, self.h = w, h
        self.p = [P[color] if isinstance(color, str) else color or CLEAR] * (w*h)

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.p[y*self.w+x] = P[c] if isinstance(c, str) else c

    def get(self, x, y):
        return self.p[y*self.w+x]

    def rect(self, x, y, w, h, c):
        for yy in range(y, y+h):
            for xx in range(x, x+w):
                self.put(xx, yy, c)

    def line(self, x, y, xx, yy, c):
        dx, dy = abs(xx-x), -abs(yy-y)
        sx, sy = (1 if x < xx else -1), (1 if y < yy else -1)
        err = dx+dy
        while True:
            self.put(x, y, c)
            if (x, y) == (xx, yy):
                break
            e = 2*err
            if e >= dy:
                err += dy
                x += sx
            if e <= dx:
                err += dx
                y += sy

    def poly(self, points, c):
        # Integer point-in-polygon, including a crisp Bresenham boundary.
        for y in range(min(p[1] for p in points), max(p[1] for p in points)+1):
            for x in range(min(p[0] for p in points), max(p[0] for p in points)+1):
                inside = False
                j = len(points)-1
                for i, (xi, yi) in enumerate(points):
                    xj, yj = points[j]
                    if (yi > y) != (yj > y) and x < (xj-xi)*(y-yi)/(yj-yi)+xi:
                        inside = not inside
                    j = i
                if inside:
                    self.put(x, y, c)
        for a, b in zip(points, points[1:]+points[:1]):
            self.line(*a, *b, c)

    def oval(self, x, y, w, h, c):
        for yy in range(h):
            for xx in range(w):
                if ((2*xx+1-w)*h)**2 + ((2*yy+1-h)*w)**2 <= (w*h)**2:
                    self.put(x+xx, y+yy, c)

    def blit(self, src, x, y):
        for yy in range(src.h):
            for xx in range(src.w):
                c = src.get(xx, yy)
                if c[3]:
                    self.put(x+xx, y+yy, c)

    def crop(self, x, y, w, h):
        assert 0 <= x <= self.w-w and 0 <= y <= self.h-h
        out = Image(w, h)
        for yy in range(h):
            out.p[yy*w:(yy+1)*w] = self.p[(y+yy)*self.w+x:(y+yy)*self.w+x+w]
        return out

    def scale(self, n):
        out = Image(self.w*n, self.h*n)
        for y in range(self.h):
            row = [c for c in self.p[y*self.w:(y+1)*self.w] for _ in range(n)]
            for k in range(n):
                out.p[(y*n+k)*out.w:(y*n+k+1)*out.w] = row
        return out

    def png(self):
        def chunk(tag, data):
            return struct.pack('>I', len(data))+tag+data+struct.pack('>I', zlib.crc32(tag+data)&0xffffffff)
        raw = b''.join(b'\0'+bytes(v for c in self.p[y*self.w:(y+1)*self.w] for v in c)
                       for y in range(self.h))
        return (b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', self.w, self.h, 8, 6, 0, 0, 0))
                +chunk(b'IDAT', zlib.compress(raw, 9))+chunk(b'IEND', b''))


ART = {}
EXPECTED = {}
TRANSPARENT = set()


def add(name, im, size, transparent=False):
    name += '.png'
    assert name not in ART
    assert (im.w, im.h) == size, (name, size)
    assert all(c[3] in (0, 255) for c in im.p), name
    if not transparent:
        assert all(c[3] == 255 for c in im.p), name
    else:
        assert any(c[3] == 0 for c in im.p), name
        TRANSPARENT.add(name)
    ART[name], EXPECTED[name] = im, size
    return im


def ground(v=0):
    im = Image(16, 16, 'grass')
    # All variants have identical, undecorated borders. Sparse deliberate tufts.
    positions = [((3,4),(11,11)), ((9,3),(4,12)), ((4,9),(12,5)), ((6,3),(10,12))][v]
    for x,y in positions:
        im.put(x,y,'grass_d'); im.put(x+1,y-1,'grass_l')
    if v == 2:
        im.put(3,3,'sand_l'); im.put(4,4,'grass_l')
    return im


def tree(im, x, y, s=9, shadow='grass_d'):
    im.oval(x+2,y+3,s,s-2,shadow)
    im.rect(x+s//2,y+s-2,2,3,'wood_d')
    im.oval(x,y,s,s-1,'leaf_d')
    im.oval(x,y,s-1,s-3,'leaf')
    im.oval(x+1,y,s-3,s-4,'leaf_m')
    im.line(x+2,y+1,x+s//2,y+1,'leaf_l')
    im.put(x+1,y+3,'leaf_l')
    im.put(x+s-3,y+s-4,'leaf_m')


def terrain():
    for i in range(4): add('ground_'+str(i),ground(i),(16,16))
    dirt=Image(16,16,'soil')
    for x,y in [(3,4),(11,2),(7,11),(12,13)]:
        dirt.rect(x,y,2,1,'soil_l'); dirt.put(x,y+1,'soil_d')
    add('dirt',dirt,(16,16))
    for v in range(2):
        im=dirt.crop(0,0,16,16)
        for x,y,w,c in [(2,4,4,'red'),(8,8,5,'cream_d'),(4,11,3,'red_d'),(10,3,3,'red_l'),(3,7,2,'metal')]:
            x=(x+v*3)%11+1
            im.rect(x+1,y+1,w,2,'soil_d'); im.rect(x,y,w,2,c); im.put(x,y,'soil_l')
        add('rubble_'+str(v),im,(16,16))
    for v in range(4):
        im=ground(v)
        for x,y,s in [[(1,1,8),(6,6,8)],[(6,1,8),(1,6,8)],[(1,2,7),(7,2,6),(4,8,6)],[(2,1,9),(7,8,6)]][v]:
            tree(im,x,y,s)
        add('woods_'+str(v),im,(16,16))


def normalize(m):
    for d,a,b in [(2,1,4),(8,4,16),(32,16,64),(128,64,1)]:
        if not (m&a and m&b): m &= ~d
    return m


MASKS=sorted({normalize(m) for m in range(256)})
assert len(MASKS)==47 and MASKS[0]==0 and MASKS[-1]==255
assert MASKS==sorted(set(MASKS))


def water(m):
    im=Image(16,16,'water')
    for y in range(16):
        for x in range(16):
            # Distance to land in the eight neighbouring cells. Pixel-centred
            # geometry yields matching bank tangents at tile boundaries.
            ds=[]
            for bit,d in [(1,y+1),(4,16-x),(16,16-y),(64,x+1)]:
                if not m&bit: ds.append(d*d)
            for bit,dx,dy in [(2,16-x,y+1),(8,16-x,16-y),(32,x+1,16-y),(128,x+1,y+1)]:
                if not m&bit: ds.append(dx*dx+dy*dy)
            d=min(ds,default=999)
            # Convex shore corners turn through a rounded eight-pixel quadrant.
            for a,b,xx,yy in [(1,64,x,y),(1,4,15-x,y),(16,64,x,15-y),(16,4,15-x,15-y)]:
                if not m&a and not m&b and xx<8 and yy<8:
                    distance=max(0,8-math.isqrt((8-xx)**2+(8-yy)**2))
                    d=min(d,distance*distance)
            c='grass' if d<=4 else 'sand' if d<=16 else 'water_l' if d<=25 else 'water_m' if d<=49 else 'water'
            im.put(x,y,c)
    for x,y in [(5,6),(10,11)]:
        if all(im.get(xx,y)==P['water'] for xx in range(x,x+3)):
            im.line(x,y,x+2,y,'water_m')
            if y==6:
                im.put(x+1,y,'foam'); im.put(x+2,y,'water_l')
    return im


def road(m):
    im=ground(0)
    inside=set()
    for y in range(16):
        for x in range(16):
            if (3<=x<=12 and 3<=y<=12 or m&1 and 3<=x<=12 and y<=8
                or m&2 and 3<=y<=12 and x>=7 or m&4 and 3<=x<=12 and y>=7
                or m&8 and 3<=y<=12 and x<=8): inside.add((x,y))
    for x,y in inside:
        border=any((xx,yy) not in inside for xx,yy in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] if 0<=xx<16 and 0<=yy<16)
        im.put(x,y,'kerb' if border else 'road')
    if m in (1,4,5):
        for y in range(16):
            if y in (2,3,4,10,11,12) and (7,y) in inside and im.get(7,y)==P['road']: im.put(7,y,'stripe')
    elif m in (2,8,10):
        for x in range(16):
            if x in (2,3,4,10,11,12) and (x,7) in inside and im.get(x,7)==P['road']: im.put(x,7,'stripe')
    elif m:
        for bit,x,y in [(1,7,1),(2,14,7),(4,7,14),(8,1,7)]:
            if m&bit: im.put(x,y,'stripe')
    return im


def cables(im,m,pole=True):
    for bit,x,y in [(1,7,0),(2,15,7),(4,7,15),(8,0,7)]:
        if m&bit:
            im.line(7,7,x,y,'wood_d')
            if bit in (1,4): im.line(9,7,9,y,'slate_d')
            else: im.line(7,9,x,9,'slate_d')
    if pole:
        im.rect(9,9,2,3,'grass_d'); im.rect(5,10,7,1,'grass_d')
        im.rect(7,6,2,5,'wood'); im.rect(4,6,8,2,'wood_d')
        im.line(4,6,10,6,'wood_l')
        for x in (4,7,10): im.put(x,5,'cream'); im.put(x,7,'glass_d')


def networks():
    w=Image(16,47*16)
    for i,m in enumerate(MASKS): w.blit(water(m),0,i*16)
    add('water',w,(16,752))
    r,l=Image(16,256),Image(16,256)
    for m in range(16):
        r.blit(road(m),0,m*16)
        im=ground(); cables(im,m); l.blit(im,0,m*16)
    add('road',r,(16,256)); add('line',l,(16,256))
    bridge=Image(32,16); crossing=Image(32,16); wetline=Image(32,16)
    for v in range(2):
        im=water(255)
        for y in range(16):
            for x in range(16):
                t=y if v==0 else x
                along=x if v==0 else y
                if 3<=t<=12: im.put(x,y,'road')
                if t in (2,13): im.put(x,y,'wood_d')
                if t in (3,12): im.put(x,y,'cream')
                if t in (2,13) and along%5==0: im.put(x,y,'white')
                if t==7 and along in (2,3,4,10,11,12): im.put(x,y,'stripe')
        bridge.blit(im,v*16,0)
        im=road(10 if v==0 else 5)
        if v==0:
            for x in (7,9): im.line(x,0,x,15,'wood_d' if x==7 else 'slate_d')
            for y in (1,14): im.line(4,y,11,y,'wood'); im.put(4,y,'cream'); im.put(11,y,'cream')
        else:
            for y in (7,9): im.line(0,y,15,y,'wood_d' if y==7 else 'slate_d')
            for x in (1,14): im.line(x,4,x,11,'wood'); im.put(x,4,'cream'); im.put(x,11,'cream')
        crossing.blit(im,v*16,0)
        im=water(255); cables(im,10 if v==0 else 5,False); wetline.blit(im,v*16,0)
    add('bridge',bridge,(32,16)); add('line_road',crossing,(32,16)); add('line_water',wetline,(32,16))


def lot(kind='res',size=48):
    im=Image(size,size,'grass')
    for y in range(0,size,16):
        for x in range(0,size,16): im.blit(ground((x//16+y//16)%4),x,y)
    if kind!='res':
        im.rect(2,2,size-4,size-4,'pave' if kind=='com' else 'soil')
        im.line(2,size-3,size-3,size-3,'pave_d' if kind=='com' else 'soil_d')
    return im


def windows(im,x,y,w,h,glass='glass',balcony=False):
    for yy in range(y,y+h-1,4):
        for xx in range(x,x+w-1,4):
            im.rect(xx,yy,2,2,'glass_d'); im.put(xx,yy,glass)
            if balcony:
                im.rect(xx-1,yy+2,4,1,'cream_d'); im.rect(xx-1,yy+3,4,1,'cream')
                im.rect(xx,yy+2,2,1,'res')


def block(im,x,y,w,d,h,roof='slate',wall='cream',shadow='grass_d',balcony=False,glass=False):
    """A roof plan and south elevation, with an inset service roof."""
    assert 2<=h<=8, ('south elevation',h)
    im.rect(x+2,y+3,w,d+h,shadow)
    im.rect(x,y+d,w,h,'cream_d' if not glass else 'glass_d')
    im.rect(x,y+d,w-2,h-1,wall if not glass else 'glass')
    im.rect(x,y,w,d,roof+'_d')
    im.rect(x+1,y+1,w-2,d-2,roof)
    im.line(x,y,x+w-2,y,roof+'_l'); im.line(x,y,x,y+d-1,roof+'_l')
    if d>7 and w>10:
        # An inset membrane, raised access housing and paired ventilation ducts.
        im.rect(x+2,y+2,w-4,d-4,roof+'_l')
        im.rect(x+3,y+3,w-6,d-6,roof)
        if w>=16 and d>=13:
            im.rect(x+4,y+4,6,5,roof+'_d')
            im.rect(x+4,y+4,5,3,'metal')
            im.line(x+4,y+4,x+8,y+4,'metal_l')
            im.rect(x+w-7,y+d-6,3,3,'metal_d')
            im.line(x+w-7,y+d-6,x+w-5,y+d-6,'metal_l')
            im.put(x+w-6,y+d-5,'metal')
        else:
            im.rect(x+w-6,y+d-5,3,2,'metal_d')
            im.line(x+w-6,y+d-5,x+w-4,y+d-5,'metal_l')
    windows(im,x+2,y+d+1,w-4,h-1,'glass_l',balcony)
    if glass:
        for xx in range(x+3,x+w-2,4): im.line(xx,y+d,xx,y+d+h-2,'glass_l')
        for yy in range(y+d+3,y+d+h-1,4): im.line(x+1,yy,x+w-3,yy,'glass_d')
    im.rect(x+w//2-1,y+d+h-3,3,3,'glass_d')
    im.put(x+w//2,y+d+h-2,'amber_l')


def house(im,x,y,w=11,d=7,roof='red'):
    im.rect(x+2,y+3,w,d+4,'grass_d')
    im.rect(x+1,y+d,w-2,4,'cream_d'); im.rect(x+1,y+d,w-3,3,'cream')
    im.poly([(x,y+2),(x+2,y),(x+w-3,y),(x+w-1,y+2),(x+w-1,y+d),(x,y+d)],roof+'_d')
    im.poly([(x,y+2),(x+2,y),(x+w-3,y),(x+w-1,y+2),(x+w-3,y+3),(x+2,y+3)],roof+'_l')
    im.rect(x+1,y+4,w-2,d-4,roof)
    im.line(x+2,y+3,x+w-3,y+3,roof+'_d')
    im.rect(x+w-4,y,2,3,'cream_d'); im.put(x+w-4,y,'white')
    im.put(x+2,y+d+1,'glass'); im.put(x+w-3,y+d+1,'glass')
    im.rect(x+w//2,y+d+1,2,3,'res')
    im.rect(x+w//2,y+d+4,2,2,'sand')


def car(im,x,y,c='coral',vertical=False,truck=False):
    w,h=(4,8 if truck else 6) if vertical else (9 if truck else 6,4)
    im.rect(x+1,y+1,w,h,'pave_d')
    im.rect(x,y,w,h,'ink'); im.rect(x,y,w-1,h-1,c)
    if vertical:
        im.rect(x+1,y+1,2,2,'glass_d'); im.put(x,y,'white')
    else:
        im.rect(x+1,y+1,2,2,'glass_d'); im.put(x,y,'white')
    if truck: im.rect(x+4,y,w-5,h-1,'cream')


def awning(im,x,y,w,c):
    im.rect(x,y+2,w,1,'glass_d')
    for xx in range(w):
        im.rect(x+xx,y,1,2,c if xx%4<2 else 'white')


def tank(im,x,y,s=10):
    im.oval(x+2,y+3,s,s,'soil_d')
    im.rect(x,y+s//2,s,4,'metal_d'); im.oval(x,y+3,s,s-2,'metal_d')
    im.oval(x,y,s,s-2,'metal_l'); im.oval(x+1,y+1,s-2,s-4,'metal')
    im.line(x+2,y+1,x+s//2,y+1,'white'); im.rect(x+s//2,y+2,2,2,'metal_d')


def chimney(im,x,y,h=17):
    im.rect(x+4,y+3,2,h,'soil_d')
    im.rect(x,y,5,h,'rust_d'); im.rect(x,y,3,h,'red')
    im.line(x,y,x,y+h-1,'red_l')
    for yy in range(y+5,y+h,6): im.rect(x,yy,4,2,'cream_d')
    im.rect(x-1,y,7,2,'cream'); im.rect(x,y,5,1,'wood_d')


def emblem(im,kind,x,y,color):
    if kind=='res':
        im.poly([(x,y+5),(x+5,y),(x+11,y+5)],color)
        im.rect(x+2,y+5,8,7,color); im.rect(x+5,y+8,3,4,'panel_light')
    elif kind=='com':
        im.rect(x+1,y+4,10,8,color)
        im.line(x+4,y+4,x+4,y+1,color); im.line(x+4,y+1,x+8,y+1,color); im.line(x+8,y+1,x+8,y+4,color)
        im.put(x+4,y+6,'panel_light'); im.put(x+8,y+6,'panel_light')
    else:
        im.oval(x+1,y+1,10,10,color)
        for xx,yy,w,h in [(4,0,4,12),(0,4,12,4),(1,1,3,3),(8,1,3,3),(1,8,3,3),(8,8,3,3)]: im.rect(x+xx,y+yy,w,h,color)
        im.oval(x+4,y+4,4,4,'panel_light')


def empty(kind):
    im=lot()
    for i in range(3,45,5):
        im.rect(i,1,3,1,kind); im.rect(i,46,3,1,kind)
        im.rect(1,i,1,3,kind); im.rect(46,i,1,3,kind)
    for x,y in [(1,1),(45,1),(1,44),(45,44)]:
        im.rect(x,y,2,3,'wood'); im.put(x,y,'white')
    im.oval(15,15,20,20,'grass_d'); im.oval(14,14,20,20,'panel_light')
    emblem(im,kind,18,18,kind)
    return im


def site(kind):
    im=lot('ind')
    im.rect(7,8,29,26,'soil_d'); im.rect(8,9,27,24,'cream_d')
    im.rect(10,11,23,20,'soil'); im.rect(20,11,2,20,'cream')
    im.rect(10,20,23,2,'cream'); im.line(8,9,34,9,'white')
    for x in (5,14,23,32):
        im.line(x,6,x,29,'wood_d'); im.line(x,6,x+8,17,'wood')
    for y in (7,17,28): im.line(4,y,37,y,'wood_l')
    for y in (36,39):
        for x in (7,12,17): im.rect(x,y,4,2,'red'); im.put(x,y,'red_l')
    im.rect(28,35,11,5,'metal_d')
    for x in range(28,39,3): im.line(x,35,x,39,'metal_l')
    for x in range(3,45,6): im.rect(x,43,4,2,kind); im.put(x,42,'white')
    return im


def hedge(im,x,y,w):
    im.rect(x,y+1,w,2,'leaf_d'); im.rect(x,y,w,2,'res')
    for xx in range(x+1,x+w,3): im.put(xx,y,'leaf_l')


def bench(im,x,y):
    im.rect(x,y,6,2,'wood_l'); im.line(x,y+1,x+5,y+1,'wood')
    im.put(x+1,y+2,'wood_d'); im.put(x+4,y+2,'wood_d')


def skylight(im,x,y,w=6,h=4):
    im.rect(x+1,y+1,w,h,'slate_d'); im.rect(x,y,w,h,'cream')
    im.rect(x+1,y+1,w-2,h-2,'glass')
    im.line(x+1,y+1,x+w-2,y+1,'glass_l')
    for xx in range(x+3,x+w-1,3): im.line(xx,y+1,xx,y+h-2,'slate_d')


def residential(n,v):
    im=lot()
    if n==1:
        im.rect(22,2,3,44,'sand'); im.rect(2,23,44,3,'sand')
        coords=[(4,4,12,7),(28,4,12,7),(4,29,12,7),(28,29,12,7)] if v==0 else [(3,3,10,6),(19,3,10,6),(33,3,10,6),(5,28,12,7),(29,28,12,7)]
        for i,(x,y,w,d) in enumerate(coords):
            house(im,x,y,w,d,['red','slate','coral'][i%3])
            hedge(im,x,y+d+7,w-2)
        tree(im,4 if v==0 else 18,17 if v==0 else 31,7)
        tree(im,34,17,7)
    elif n==2:
        im.rect(3,22,42,3,'sand'); im.rect(23,23,3,22,'sand')
        for i in range(4):
            house(im,3+i*10,4,10,11,'coral' if v==0 else 'slate')
            im.rect(6+i*10,8,3,3,'cream'); im.rect(7+i*10,9,2,2,'glass_d')
            hedge(im,4+i*10,20,6)
        if v==0:
            house(im,4,29,14,9,'red'); house(im,29,29,13,9,'red')
            tree(im,18,29,7)
        else:
            for x in (4,16): house(im,x,29,11,9,'red')
            tree(im,33,28,9); bench(im,34,41)
    elif n==3:
        if v==0:
            block(im,4,4,17,21,6,'red',balcony=True)
            block(im,26,4,16,21,6,'slate',balcony=True)
            skylight(im,8,16,8,4); skylight(im,29,16,8,4)
            im.rect(5,35,37,9,'pave'); tree(im,6,34,7,'pave_d'); tree(im,34,34,7,'pave_d')
            bench(im,19,38); hedge(im,17,43,13)
        else:
            block(im,4,4,36,14,6,'coral',balcony=True)
            block(im,4,27,18,10,6,'slate',balcony=True)
            for x in (10,23): skylight(im,x,8,8,5)
            im.rect(26,28,16,16,'pave'); tree(im,29,29,9,'pave_d'); bench(im,29,41)
    else:
        im.rect(3,3,42,42,'pave')
        if v==0:
            block(im,5,4,16,29,8,'slate',shadow='pave_d',balcony=True)
            block(im,26,7,15,26,8,'coral',shadow='pave_d',balcony=True)
            for x,y in ((8,15),(29,17)):
                skylight(im,x,y,8,6); im.rect(x+1,y+9,5,3,'metal_d')
                im.line(x+1,y+9,x+5,y+9,'metal_l')
        else:
            block(im,6,3,32,30,8,'red',shadow='pave_d',balcony=True)
            # Stepped roof pavilion, terrace walkway and a planted roof deck.
            block(im,12,8,18,11,3,'slate',shadow='red_d')
            im.rect(11,24,21,6,'cream_d'); im.rect(12,24,19,5,'cream')
            for x in (13,19,25): im.rect(x,25,4,3,'res'); im.put(x,25,'mint')
        for x in (4,39): tree(im,x,35,6,'pave_d')
        im.rect(22,41,3,4,'pave_l'); hedge(im,24,43,10)
    return im


def commercial(n,v):
    im=lot('com')
    if n==1:
        for x in (7,17,27,37): im.line(x,35,x,43,'kerb')
        if v==0:
            block(im,4,5,18,12,4,'slate',shadow='pave_d')
            block(im,27,8,15,10,4,'red',shadow='pave_d')
            awning(im,5,19,16,'amber'); awning(im,28,20,13,'mint')
        else:
            block(im,4,4,15,16,4,'red',shadow='pave_d')
            block(im,24,4,18,12,4,'slate',shadow='pave_d')
            awning(im,5,22,13,'coral'); awning(im,25,18,16,'mint')
        for x,y in [(28,28),(37,28)]:
            im.oval(x,y,5,4,'white'); im.put(x+2,y+4,'wood_d'); im.put(x-1,y+1,'coral')
        car(im,9,37,'com',True); car(im,29,37,'coral',True)
        tree(im,4,26,6,'pave_d')
    elif n==2:
        for x,c in zip((4,17,30),('coral','mint','amber')):
            block(im,x,4,12,12,5,'slate' if v else 'red',shadow='pave_d'); awning(im,x+1,19,10,c)
        block(im,4 if v==0 else 27,26,16,11,6,'slate',shadow='pave_d',glass=True)
        for x in (23,33):
            xx=x if v==0 else x-18
            im.line(xx,29,xx,43,'kerb'); car(im,xx+2,32,'white' if x==23 else 'com',True)
    elif n==3:
        if v==0:
            block(im,4,4,17,28,6,'slate',shadow='pave_d',glass=True)
            block(im,25,8,17,24,6,'slate',shadow='pave_d')
            skylight(im,8,17,9,9)
            im.rect(28,11,11,15,'grass_d'); im.rect(28,11,10,14,'grass')
            tree(im,29,12,7); bench(im,30,23)
            awning(im,26,36,15,'mint')
        else:
            block(im,4,4,38,15,6,'slate',shadow='pave_d',glass=True)
            block(im,5,26,24,12,6,'red',shadow='pave_d')
            skylight(im,23,8,13,7)
            im.rect(8,28,17,8,'grass'); tree(im,9,28,6); bench(im,18,31)
            tree(im,33,31,8,'pave_d'); awning(im,7,41,20,'coral')
        im.rect(6,44,34,1,'pave_l')
    else:
        if v==0:
            block(im,4,3,17,28,8,'slate',shadow='pave_d',glass=True)
            block(im,25,6,17,25,8,'slate',shadow='pave_d',glass=True)
            for x in (7,28): skylight(im,x,14,10,11)
        else:
            block(im,5,3,27,28,8,'slate',shadow='pave_d',glass=True)
            block(im,33,12,9,19,7,'slate',shadow='pave_d',glass=True)
            # A broad glass atrium sits within the large tower's roof parapet.
            skylight(im,10,10,17,16)
            for yy in (15,20): im.line(11,yy,25,yy,'slate_d')
        im.oval(19,39,12,6,'cream_d'); im.oval(20,39,10,4,'water_l')
        im.line(24,36,24,41,'white'); im.put(23,37,'foam'); im.put(25,38,'foam')
        hedge(im,4,43,10); hedge(im,34,43,8)
    im.rect(3,44,8,1,'com')
    return im


def sawroof(im,x,y,w,d,h):
    block(im,x,y,w,d,h,'rust',shadow='soil_d')
    for yy in range(y+1,y+d-2,5):
        im.rect(x+1,yy,w-3,3,'metal')
        im.line(x+1,yy,x+w-3,yy,'metal_l')
        im.line(x+1,yy+3,x+w-3,yy+3,'glass_d')
        for xx in range(x+3,x+w-2,5): im.put(xx,yy+3,'glass_l')
    im.rect(x+3,y+d+1,8,h-1,'wood_d')
    for yy in range(y+d+2,y+d+h-1,2): im.line(x+3,yy,x+10,yy,'metal')


def industrial(n,v):
    im=lot('ind')
    if n==1:
        block(im,5 if not v else 17,5,25,17,5,'rust',shadow='soil_d')
        im.rect(9 if not v else 21,23,8,4,'wood_d')
        for x,y in [(6,35),(12,38),(29,34),(35,37)]:
            im.rect(x+1,y+1,6,5,'soil_d'); im.rect(x,y,6,5,'wood'); im.line(x,y,x+5,y+4,'wood_l'); im.line(x,y,x+5,y,'cream')
        tank(im,33 if not v else 4,7,8)
        skylight(im,10 if not v else 22,12,11,5)
    elif n==2:
        if v==0:
            sawroof(im,4,4,38,25,6)
            im.rect(9,35,21,3,'pave_d'); car(im,29,39,'amber',truck=True)
        else:
            sawroof(im,4,4,23,30,6)
            block(im,29,5,12,16,5,'rust',shadow='soil_d')
            im.rect(29,30,12,12,'pave_d'); car(im,31,34,'white',truck=True)
        im.line(4,44,42,44,'ind')
    elif n==3:
        if v==0:
            sawroof(im,4,12,25,23,7)
            chimney(im,7,4,21); tank(im,32,9,10); tank(im,32,27,10)
            im.line(29,23,38,23,'metal_d'); im.line(29,22,38,22,'metal_l')
        else:
            sawroof(im,4,4,37,20,7); chimney(im,32,3,20)
            tank(im,5,33,10); tank(im,20,33,10)
            im.line(11,31,11,34,'metal_l'); im.line(11,32,33,32,'metal_l')
            car(im,33,38,'amber',truck=True)
    else:
        if v==0:
            sawroof(im,4,17,27,18,8)
            for x,y,h in [(5,4,22),(15,6,21),(25,3,23)]: chimney(im,x,y,h)
            tank(im,33,6,10); tank(im,34,24,9)
            for y in (38,41): im.line(30,y,42,y,'metal_d'); im.line(30,y-1,42,y-1,'metal_l')
            im.rect(37,16,3,9,'metal'); im.line(37,16,37,24,'white')
        else:
            sawroof(im,4,4,26,21,8); sawroof(im,22,28,20,11,5)
            for x,y,h in [(32,3,23),(40,6,21)]: chimney(im,x,y,h)
            tank(im,4,33,10); tank(im,14,30,9)
            im.line(8,29,20,29,'metal_l'); im.line(20,24,20,29,'metal_l')
            im.line(31,26,40,26,'metal_d'); im.line(31,25,40,25,'metal_l')
    im.rect(3,43,5,2,'ind')
    return im


def coal(frame):
    im=lot('ind',64)
    for y in (2,60):
        im.line(2,y,60,y,'metal_d')
        for x in range(2,62,4): im.rect(x,y-1,1,3,'metal_l')
    for x in (2,60):
        im.line(x,2,x,60,'metal_d')
        for y in range(4,60,4): im.rect(x-1,y,3,1,'metal_l')
    sawroof(im,8,27,32,22,8)
    block(im,39,34,15,14,8,'rust',shadow='soil_d')
    for x,y in [(15,11),(30,14)]: chimney(im,x,y,24)
    # Both frames share all solid geometry. Only these smoke regions differ.
    for x,y in [(15,11),(30,14)]:
        im.oval(x-3-frame,y-7,7,4,'smoke')
        im.oval(x-5-frame*2,y-10,8,4,'metal_l')
        im.oval(x-2-frame,y-5,6,3,'cream_d')
    im.poly([(43,20),(47,13),(52,12),(57,19),(57,27),(42,27)],'coal')
    im.poly([(43,20),(48,14),(52,13),(50,19)],'coal_l')
    im.line(42,28,57,28,'soil_d')
    for y in (30,32): im.line(37,y,54,y,'metal_d'); im.line(37,y-1,54,y-1,'metal_l')
    im.rect(45,49,9,3,'ind'); im.rect(46,48,7,1,'amber_l')
    return im


def zones():
    for k,fn in [('res',residential),('com',commercial),('ind',industrial)]:
        add('zone_'+k+'_empty',empty(k),(48,48)); add('zone_'+k+'_site',site(k),(48,48))
        for n in range(1,5):
            for v,suffix in enumerate(('a','b')): add(f'zone_{k}_{n}_{suffix}',fn(n,v),(48,48))
    for f in range(2): add('coal_'+str(f),coal(f),(64,64))


TOOLS=('bulldoze','road','line','res','com','ind','coal','query')


def bolt(im,x,y,c='amber_l'):
    im.poly([(x+5,y),(x+1,y+6),(x+4,y+6),(x+2,y+11),(x+8,y+4),(x+5,y+4)],c)


def button(down=False):
    im=Image(28,28)
    im.rect(3,0,22,28,'panel_dark'); im.rect(0,3,28,22,'panel_dark'); im.rect(1,1,26,26,'panel_dark')
    im.rect(3,2,22,24,'panel' if not down else 'pave'); im.rect(2,3,24,22,'panel' if not down else 'pave')
    c='panel_dark' if down else 'panel_light'
    im.line(3,1,24,1,c); im.line(1,3,1,24,c)
    im.line(3,26,24,26,'panel_light' if down else 'pave_d'); im.line(26,3,26,24,'panel_light' if down else 'pave_d')
    return im


def tool(name):
    im=Image(20,20)
    if name=='bulldoze':
        im.rect(3,12,12,5,'wood_d'); im.rect(4,13,10,3,'metal_d')
        for x in (5,8,11): im.put(x,14,'metal_l')
        im.rect(4,9,12,4,'amber'); im.rect(6,4,7,7,'amber_d'); im.rect(7,5,5,5,'glass_d'); im.rect(7,5,3,3,'glass_l')
        im.rect(4,8,2,4,'amber_l'); im.rect(15,11,2,2,'wood'); im.rect(17,8,2,8,'amber'); im.line(17,8,17,15,'amber_l')
    elif name=='road':
        im.rect(2,3,16,14,'kerb'); im.rect(2,5,16,10,'road')
        for x in (3,9,15): im.rect(x,9,3,1,'stripe')
    elif name=='line':
        im.line(10,6,18,2,'slate_d'); im.line(10,7,2,4,'slate_d'); im.rect(9,4,3,14,'wood')
        im.rect(3,6,14,2,'wood_d'); im.line(3,6,16,6,'wood_l')
        for x in (4,9,15): im.rect(x,4,2,2,'cream')
    elif name=='res':
        im.rect(4,9,12,8,'cream'); im.poly([(2,9),(9,3),(17,9)],'res'); im.line(3,9,9,4,'mint')
        im.rect(6,11,3,3,'glass'); im.rect(11,12,3,5,'wood_d')
    elif name=='com':
        im.rect(3,5,14,13,'cream'); im.rect(5,10,10,7,'glass_d'); im.rect(6,11,4,4,'glass_l')
        awning(im,2,7,16,'com'); im.rect(12,11,3,6,'glass'); im.line(3,4,16,4,'slate')
    elif name=='ind':
        im.rect(3,9,14,9,'rust'); im.poly([(3,9),(7,5),(7,9),(12,5),(12,9),(17,5),(17,10)],'metal_l')
        im.rect(14,2,3,6,'rust_d'); im.rect(13,2,5,1,'ind'); im.rect(5,12,4,6,'wood_d'); im.rect(11,12,4,2,'ind')
    elif name=='coal':
        im.rect(5,7,6,11,'red_d'); im.rect(5,7,3,11,'red'); im.rect(4,6,8,2,'cream')
        im.oval(4,2,7,4,'smoke'); im.oval(2,1,5,3,'metal_l'); bolt(im,9,7)
    else:
        im.line(11,12,17,18,'wood_d'); im.line(12,12,18,17,'wood')
        im.oval(2,2,13,13,'ink'); im.oval(4,4,9,9,'glass_l'); im.oval(5,5,7,7,'water_l'); im.line(6,5,9,5,'white'); im.put(5,6,'white')
    return im


def marks():
    im=Image(16,16); im.oval(0,0,16,16,'red_d'); im.oval(1,1,14,14,'bad'); im.oval(3,3,10,10,CLEAR)
    bolt(im,3,2); im.line(3,3,12,12,'red_d'); im.line(3,2,13,12,'bad'); im.line(2,3,12,13,'bad')
    add('nopower',im,(16,16),True)
    im=Image(16,16); im.rect(7,10,2,6,'wood'); im.rect(1,1,14,11,'slate_d'); im.rect(2,2,12,9,'cream')
    im.line(4,3,11,9,'bad'); im.line(4,9,11,3,'bad'); im.line(5,3,12,9,'bad'); im.line(5,9,12,3,'bad')
    add('noroad',im,(16,16),True)


def logo():
    im=Image(160,48)
    # Bespoke geometric capitals: broad road-like strokes and clipped corners.
    shapes=[[(7,38),(7,7),(11,3),(34,3),(39,8),(39,20),(34,25),(17,25),(17,38)],
            [(46,3),(56,3),(56,28),(76,28),(76,38),(46,38)],
            [(82,38),(82,11),(90,3),(108,3),(116,11),(116,38),(106,38),(106,25),(92,25),(92,38)],
            [(121,3),(155,3),(155,13),(143,13),(143,38),(133,38),(133,13),(121,13)]]
    for shape,c in zip(shapes,['res','road','com','ind']):
        im.poly([(x+2,y+3) for x,y in shape],'road_d'); im.poly(shape,c)
    im.rect(17,12,12,5,CLEAR); im.rect(92,13,14,5,CLEAR)
    for x in range(49,74,7): im.rect(x,32,3,1,'stripe')
    im.line(11,8,11,34,'mint'); im.line(11,8,32,8,'mint')
    im.line(86,13,86,34,'glass_l'); im.line(91,7,106,7,'glass_l')
    im.line(125,7,150,7,'amber_l'); im.line(137,12,137,34,'amber_l')
    # Three connected streets inset into the P; the counters stay transparent.
    im.rect(11,7,3,28,'road'); im.rect(11,7,23,3,'road')
    im.rect(11,21,23,3,'road')
    for yy in (10,16,23,30): im.put(12,yy,'stripe')
    for xx in (18,25,32): im.put(xx,8,'stripe'); im.put(xx,22,'stripe')
    im.rect(58,32,4,4,'grass'); im.rect(58,30,1,9,'kerb')
    return im


def ui():
    marks()
    for down,name in [(False,'button'),(True,'button_down')]: add(name,button(down),(28,28),True)
    for name in TOOLS: add('tool_'+name,tool(name),(20,20),True)
    for count,name in enumerate(('pause','slow','normal','fast')):
        im=Image(12,12)
        if count==0: im.rect(2,2,3,8,'text'); im.rect(7,2,3,8,'text')
        else:
            width=6 if count==1 else 4 if count==2 else 3
            start=(12-count*width)//2
            for i in range(count): im.poly([(start+i*width,2),(start+i*width,9),(start+(i+1)*width-1,6)],'text')
        add('speed_'+name,im,(12,12),True)
    for name in ('funds','date','pop'):
        im=Image(12,12)
        if name=='funds':
            im.oval(1,1,10,10,'amber_d'); im.oval(1,1,9,9,'amber'); im.oval(3,3,5,5,'amber_l'); im.line(5,3,5,7,'amber_d')
        elif name=='date':
            im.rect(1,2,10,9,'cream_d'); im.rect(2,3,8,7,'white'); im.rect(1,2,10,3,'coral'); im.rect(3,1,1,3,'text'); im.rect(8,1,1,3,'text')
            for x,y in [(3,6),(6,6),(8,6),(3,8),(6,8)]: im.put(x,y,'slate')
        else:
            im.oval(4,1,4,4,'wood_l'); im.rect(3,5,6,4,'res'); im.rect(4,9,2,2,'slate_d'); im.rect(7,9,2,2,'slate_d')
        add('icon_'+name,im,(12,12),True)
    add('logo',logo(),(160,48),True)
    app=Image(32,32,'grass'); app.blit(road(10),0,16); app.blit(road(10),16,16)
    house(app,2,2,12,7,'coral'); block(app,18,2,11,7,5,'slate'); tree(app,20,22,8)
    add('app',app,(32,32))


# A tiny original caption alphabet, used only on contact sheets, never sprites.
FONT = {
'a':'010/101/111/101/101','b':'110/101/110/101/110','c':'011/100/100/100/011',
'd':'110/101/101/101/110','e':'111/100/110/100/111','f':'111/100/110/100/100',
'g':'011/100/101/101/011','h':'101/101/111/101/101','i':'111/010/010/010/111',
'j':'001/001/001/101/010','k':'101/101/110/101/101','l':'100/100/100/100/111',
'm':'101/111/111/101/101','n':'101/111/111/111/101','o':'010/101/101/101/010',
'p':'110/101/110/100/100','q':'010/101/101/111/011','r':'110/101/110/101/101',
's':'011/100/010/001/110','t':'111/010/010/010/010','u':'101/101/101/101/111',
'v':'101/101/101/101/010','w':'101/101/111/111/101','x':'101/101/010/101/101',
'y':'101/101/010/010/010','z':'111/001/010/100/111',
'0':'111/101/101/101/111','1':'010/110/010/010/111','2':'110/001/010/100/111',
'3':'110/001/010/001/110','4':'101/101/111/001/001','5':'111/100/110/001/110',
'6':'011/100/110/101/010','7':'111/001/010/010/010','8':'010/101/010/101/010',
'9':'010/101/011/001/110','_':'000/000/000/000/111','.':'000/000/000/000/010',
' ':'000/000/000/000/000','-':'000/000/111/000/000',
}


def caption(im,s,x,y):
    for i,ch in enumerate(s):
        assert ch in FONT,ch
        for yy,row in enumerate(FONT[ch].split('/')):
            for xx,c in enumerate(row):
                if c=='1': im.put(x+i*4+xx,y+yy,'text')


def contact_sheets():
    entries=[]
    for name in ART:
        if name.startswith(('ground','woods','rubble')) or name=='dirt.png': entries.append((name,ART[name]))
    for name,count,across in [('water',47,False),('road',16,False),('bridge',2,True),('line',16,False),('line_road',2,True),('line_water',2,True)]:
        for i in range(count):
            src=ART[name+'.png'].crop(i*16 if across else 0,0 if across else i*16,16,16)
            entries.append((name+'.png '+str(MASKS[i] if name=='water' else i),src))
    cols,cw,ch=10,92,55
    sh=Image(cols*cw+16,math.ceil(len(entries)/cols)*ch+16,'panel')
    for i,(label,im) in enumerate(entries):
        x,y=8+i%cols*cw,8+i//cols*ch
        sh.blit(im.scale(2),x+(cw-32)//2,y); caption(sh,label,x+(cw-(len(label)*4-1))//2,y+37)
    add('sheet_terrain',sh,(936,566))
    sh=Image(1136,540,'panel')
    for row,k in enumerate(('res','com','ind')):
        names=[f'zone_{k}_empty.png',f'zone_{k}_site.png']+[f'zone_{k}_{n}_{v}.png' for n in range(1,5) for v in ('a','b')]
        for col,name in enumerate(names):
            x,y=12+col*112,12+row*122
            sh.blit(ART[name].scale(2),x,y); caption(sh,name,x,y+101)
    for i in range(2):
        name=f'coal_{i}.png'; x,y=12+i*160,386
        sh.blit(ART[name].scale(2),x,y); caption(sh,name,x,y+133)
    add('sheet_zones',sh,(1136,540))
    sh=Image(848,478,'panel')
    for i,name in enumerate(TOOLS):
        b=button(name=='road'); b.blit(ART['tool_'+name+'.png'],4,4)
        x=12+i*104; sh.blit(b.scale(3),x,12); caption(sh,'tool_'+name+'.png',x,103)
    sh.blit(button().scale(3),12,132); caption(sh,'button.png',12,221)
    sh.blit(button(True).scale(3),116,132); caption(sh,'button_down.png',116,221)
    names=['speed_'+s+'.png' for s in ('pause','slow','normal','fast')]+['icon_'+s+'.png' for s in ('funds','date','pop')]
    for i,name in enumerate(names):
        x=224+i*88; sh.blit(ART[name].scale(3),x,150); caption(sh,name,x-8,200)
    for i,name in enumerate(('nopower.png','noroad.png')):
        sh.blit(ART[name].scale(3),12+i*104,260); caption(sh,name,12+i*104,316)
    sh.blit(ART['logo.png'].scale(3),236,266); caption(sh,'logo.png',236,418)
    sh.blit(ART['app.png'].scale(3),12,348); caption(sh,'app.png',12,452)
    add('sheet_ui',sh,(848,478))


def sample_town():
    # Cell records are the only source of map pixels. Zones are cut at source.
    cells=[[('ground_'+str((x*3+y*7)%4)+'.png',0,0) for x in range(40)] for y in range(24)]
    watercells=set()
    for y in range(2,23):
        for x in range(1,9):
            if ((x-4.5)/4.0)**2+((y-8)/6.5)**2 < 1 or (4<=x<=6 and 10<=y<=18) or ((x-4)/3.2)**2+((y-19)/3.5)**2<1:
                watercells.add((x,y))
    for x,y in watercells:
        m=sum(bit for bit,dx,dy in [(1,0,-1),(2,1,-1),(4,1,0),(8,1,1),(16,0,1),(32,-1,1),(64,-1,0),(128,-1,-1)] if (x+dx,y+dy) in watercells)
        cells[y][x]=('water.png',0,MASKS.index(normalize(m))*16)
    for y in range(24):
        for x in range(40):
            if (x,y) not in watercells and (x<9 or y==0 or y==23 or x==39):
                if (x*7+y*3)%11<9: cells[y][x]=('woods_'+str((x+y)%4)+'.png',0,0)
    roads={(x,y) for y in (6,11,16,21) for x in range(9,39)}
    roads|={(x,y) for x in (9,14,19,24,29,34,38) for y in range(2,22)}
    roads|={(x,16) for x in range(1,10)}
    for x,y in roads:
        m=sum(bit for bit,dx,dy in [(1,0,-1),(2,1,0),(4,0,1),(8,-1,0)] if (x+dx,y+dy) in roads)
        cells[y][x]=('bridge.png',0,0) if (x,y) in watercells else ('road.png',0,m*16)
    # Small planted verges use the very same woods cells as the forest.
    for y in (5,10,20):
        for x in (10,12,15,17,20,22,25,27,30,32,35,37):
            if (x,y) not in roads:
                cells[y][x]=('woods_'+str((x+y)%4)+'.png',0,0)
    placements=[]
    def zone(name,x,y):
        src=ART[name+'.png']; assert src.w%16==src.h%16==0
        for yy in range(src.h//16):
            for xx in range(src.w//16):
                assert (x+xx,y+yy) not in roads and (x+xx,y+yy) not in watercells
                cells[y+yy][x+xx]=(name+'.png',xx*16,yy*16)
        placements.append((name,x,y))
    # North: a quiet residential neighbourhood, from cottages to towers.
    for x,n,v in [(10,1,'a'),(15,2,'b'),(20,3,'a'),(25,4,'b')]: zone(f'zone_res_{n}_{v}',x,2)
    zone('zone_res_empty',30,2); zone('zone_res_site',35,2)
    for x,n,v in [(10,1,'b'),(15,2,'a'),(20,3,'b'),(25,4,'a')]: zone(f'zone_com_{n}_{v}',x,7)
    zone('zone_com_empty',30,7); zone('zone_com_site',35,7)
    for x,n,v in [(10,1,'b'),(15,2,'a'),(20,3,'b'),(25,4,'a')]: zone(f'zone_ind_{n}_{v}',x,12)
    zone('zone_ind_empty',30,12); zone('zone_ind_site',35,12)
    zone('zone_res_1_b',10,17); zone('zone_res_2_a',15,17)
    zone('zone_res_3_b',20,17); zone('zone_com_1_a',25,17)
    zone('coal_0',30,17)
    for x,y in [(35,18),(36,18),(37,18),(35,19),(36,19),(37,19)]: cells[y][x]=('dirt.png',0,0)
    cells[18][36]=('rubble_0.png',0,0); cells[19][37]=('rubble_1.png',0,0)
    # A continuous pole route through the unused strips beside the roads.
    power={(x,15) for x in range(8,40)}|{(13,y) for y in range(1,23)}|{(28,y) for y in range(1,23)}|{(33,y) for y in range(15,17)}
    for x,y in power:
        m=sum(bit for bit,dx,dy in [(1,0,-1),(2,1,0),(4,0,1),(8,-1,0)] if (x+dx,y+dy) in power)
        if (x,y)==(33,16): m |= 4  # The plant receives the south cable.
        if (x,y) in roads:
            assert m in (5,10), (x,y,m)
            cells[y][x]=('line_road.png',0 if m==5 else 16,0)
        else:
            assert cells[y][x][0].startswith(('ground','woods'))
            cells[y][x]=('line.png',0,m*16)
    world=Image(640,384)
    for y,row in enumerate(cells):
        for x,(name,sx,sy) in enumerate(row): world.blit(ART[name].crop(sx,sy,16,16),x*16,y*16)
    world.blit(ART['nopower.png'],25*16,2*16)
    sample=Image(704,416,'panel'); sample.blit(world,64,0)
    sample.line(63,0,63,383,'panel_dark'); sample.line(0,384,703,384,'panel_dark')
    for i,name in enumerate(TOOLS):
        x,y=3+i%2*30,12+i//2*32
        sample.blit(ART['button_down.png' if name=='road' else 'button.png'],x,y)
        sample.blit(ART['tool_'+name+'.png'],x+4,y+4)
    sample.blit(ART['app.png'],16,164)
    for i,s in enumerate(('pause','slow','normal','fast')): sample.blit(ART['speed_'+s+'.png'],10+i*18,394)
    for i,s in enumerate(('funds','date','pop')): sample.blit(ART['icon_'+s+'.png'],118+i*100,394)
    for i,k in enumerate(('res','com','ind')): sample.rect(625+i*16,407-(i+1)*5,9,(i+1)*5,k)
    add('sample_town',sample,(704,416))
    add('sample_town_2x',world.crop(10*16,6*16,20*16,12*16).scale(2),(640,384))
    # The zoom is an exact nearest-neighbour crop, never a second rendering.
    assert ART['sample_town_2x.png'].p==sample.crop(224,96,320,192).scale(2).p
    assert {f'zone_{k}_{s}' for k in ('res','com','ind') for s in ('empty','site')} <= {p[0] for p in placements}


def validate():
    expected={f'{stem}_{i}.png' for stem in ('ground','woods') for i in range(4)}
    expected|={f'rubble_{i}.png' for i in range(2)}
    expected|={s+'.png' for s in ('dirt','water','road','bridge','line','line_road','line_water','nopower','noroad','button','button_down','logo','app','coal_0','coal_1')}
    expected|={f'zone_{k}_{s}.png' for k in ('res','com','ind') for s in ('empty','site','1_a','1_b','2_a','2_b','3_a','3_b','4_a','4_b')}
    expected|={f'tool_{s}.png' for s in TOOLS}
    expected|={f'speed_{s}.png' for s in ('pause','slow','normal','fast')}
    expected|={f'icon_{s}.png' for s in ('funds','date','pop')}
    expected|={s+'.png' for s in ('sheet_terrain','sheet_zones','sheet_ui','sample_town','sample_town_2x')}
    assert set(ART)==expected,(set(ART)-expected,expected-set(ART))
    # Ground can meet every other variant with an identical one-pixel border.
    for i in range(4):
        g=ART[f'ground_{i}.png']
        assert all(g.get(x,y)==P['grass'] for x in range(16) for y in range(16) if x in (0,15) or y in (0,15))
    for m in MASKS:
        tile=ART['water.png'].crop(0,MASKS.index(m)*16,16,16)
        for bit,x,y in [(1,8,0),(4,15,8),(16,8,15),(64,0,8)]:
            assert tile.get(x,y)==P['water'] if m&bit else tile.get(x,y)==P['grass']
        for bit,edge in [(1,[(x,0) for x in range(16)]),(4,[(15,y) for y in range(16)]),
                         (16,[(x,15) for x in range(16)]),(64,[(0,y) for y in range(16)])]:
            if not m&bit: assert all(tile.get(x,y)==P['grass'] for x,y in edge)
    assert P['sand'] not in water(255).p and P['grass'] not in water(255).p
    for name in ('road','line'):
        tiles=[ART[name+'.png'].crop(0,m*16,16,16) for m in range(16)]
        for a in range(16):
            for b in range(16):
                if a&2 and b&8: assert [tiles[a].get(15,y) for y in range(16)]==[tiles[b].get(0,y) for y in range(16)]
                if a&4 and b&1: assert [tiles[a].get(x,15) for x in range(16)]==[tiles[b].get(x,0) for x in range(16)]
    # Crossing and over-water cables use the same two lanes as ordinary lines.
    for horizontal,index in [(False,0),(True,1)]:
        cross=ART['line_road.png'].crop(index*16,0,16,16)
        wet=ART['line_water.png'].crop((1-index)*16,0,16,16)
        for lane in (7,9):
            for end in (0,15):
                x,y=(end,lane) if horizontal else (lane,end)
                assert cross.get(x,y)==P['wood_d' if lane==7 else 'slate_d']
                assert wet.get(x,y) in (P['wood_d'],P['slate_d'])
    a,b=ART['coal_0.png'],ART['coal_1.png']
    differences=[(i%64,i//64) for i,(x,y) in enumerate(zip(a.p,b.p)) if x!=y]
    assert differences and all(8<=x<=36 and 1<=y<=11 for x,y in differences)
    for k in ('res','com','ind'):
        for n in range(1,5): assert ART[f'zone_{k}_{n}_a.png'].p!=ART[f'zone_{k}_{n}_b.png'].p
    used={c for im in ART.values() for c in im.p if c[3]}
    used|={P[k] for k in ('panel','panel_light','panel_dark','text','text_dim','good','bad','res','com','ind')}
    assert len(used)<=200 and used<=set(P.values())
    assert (0,0,0,255) not in used
    return sorted(used)


CARDINAL = ((1,0,-1),(2,1,0),(4,0,1),(8,-1,0))
RAIL_MASKS = tuple(range(16))
NEW_TOOLS = ('rail','police','fire','park','solar','budget','map','zoom_in','zoom_out')
TIER2_SIZES = {
    'rail':(16,256), 'rail_bridge':(32,16), 'rail_road':(32,16),
    'line_rail':(32,16), 'traffic_light':(16,256), 'traffic_heavy':(16,256),
    'jam':(16,16), 'police':(48,48), 'fire':(48,48),
    'park_0':(16,16), 'park_1':(16,16), 'park_big':(48,48),
    'solar_0':(64,64), 'solar_1':(64,64), 'paper_head':(240,32),
    **{f'fire_{n}':(16,16) for n in range(4)},
    **{f'adv_{n}':(32,32) for n in ('clerk','engineer','shopkeeper','resident')},
    **{f'tool_{n}':(20,20) for n in NEW_TOOLS},
    'sheet_tier2':(1152,896), 'sample_town2':(640,384),
}
TRAFFIC_PIXELS = {}


def rail(mask):
    """Circular switch routes with a common ten-pixel ballast cross-section.

    The half-pixel centre keeps both rails symmetric. Ends deliberately use
    the same sleeper phase in all sixteen masks, including curved routes.
    """
    assert mask in RAIL_MASKS
    im = ground()
    routes = []
    if mask & 5 == 5: routes.append(('v',0,15))
    if mask & 10 == 10: routes.append(('h',0,15))
    # A turnout has one curved branch off a through track. Drawing every
    # possible pair would turn its centre into an unreadable knot of steel.
    bend = {3:3,6:6,9:9,12:12,7:3,11:9,13:12,14:6}.get(mask)
    for bits,cx,cy in ((3,15.5,-.5),(6,15.5,15.5),
                       (12,-.5,15.5),(9,-.5,-.5)):
        if bend==bits: routes.append(('arc',cx,cy))
    if not routes:
        if mask in (1,4,5): routes.append(('v',0 if mask&1 else 6,15 if mask&4 else 9))
        else: routes.append(('h',0 if mask&8 else 4,15 if mask&2 else 11))
    beds, ties, steels, lights = set(),set(),set(),set()
    for y in range(16):
        for x in range(16):
            for kind,a,b in routes:
                if kind == 'arc':
                    radius = math.hypot(x-a,y-b)
                    d = abs(radius-8)
                    phase = math.atan2(abs(y-b),abs(x-a))*8
                    sleeper = any(abs(phase-t)<.65 for t in (2,6,10))
                else:
                    along,across = (y,x) if kind=='v' else (x,y)
                    if not a <= along <= b: continue
                    d = abs(across-7.5)
                    sleeper = along in (2,6,10,14)
                if d <= 4.5: beds.add((x,y))
                if d <= 3.5 and sleeper: ties.add((x,y))
                if 1.9 <= d <= 3.5: steels.add((x,y))
                if kind!='arc' and 2 <= d <= 2.95: lights.add((x,y))
    # Trace circular rails as connected pixel paths. A narrow distance band
    # alone leaves pinholes at diagonal tangencies at this tiny resolution.
    for kind,cx,cy in routes:
        if kind!='arc': continue
        curve = Image(16,16)
        for radius in (5.5,10.5):
            points = [(round(cx+(-1 if cx>0 else 1)*radius*math.cos(i*math.pi/64)),
                       round(cy+(-1 if cy>0 else 1)*radius*math.sin(i*math.pi/64))) for i in range(33)]
            for a,b in zip(points,points[1:]): curve.line(*a,*b,'metal_l')
        lights |= {(x,y) for y in range(16) for x in range(16) if curve.get(x,y)[3]}
    for points,c in ((beds,'pave'),(ties,'wood_d'),(steels,'metal_d'),(lights,'metal_l')):
        for x,y in points: im.put(x,y,c)
    # Quiet ballast texture: isolated stones, never noise or a broken rail.
    for x,y in ((3,3),(12,12),(3,11),(11,3)):
        if (x,y) in beds and (x,y) not in ties|steels: im.put(x,y,'pave_l')
    for bit,dx,dy in CARDINAL:
        if not mask & bit: continue
        for t in range(16):
            x,y = (t,0 if dy<0 else 15) if dy else (0 if dx<0 else 15,t)
            c = ('grass' if t<3 or t>12 else 'metal_l' if t in (5,10)
                 else 'metal_d' if t in (4,11) else 'pave')
            im.put(x,y,c)
    if mask in (0,1,2,4,8):
        if mask in (1,4):
            y = 9 if mask==1 else 6
            im.rect(4,y,8,2,'wood_d'); im.line(4,y,11,y,'rust_l')
            im.put(5,y-1,'white'); im.put(10,y-1,'white')
        else:
            x = 4 if mask==2 else 11
            im.rect(x,4,2,8,'wood_d'); im.line(x,4,x,11,'rust_l')
            im.put(x-1,5,'white'); im.put(x-1,10,'white')
    return im


def rail_networks():
    strip = Image(16,256)
    for i,m in enumerate(RAIL_MASKS):
        assert i == m and sum(bit for bit,_,_ in CARDINAL if m&bit)==m
        strip.blit(rail(m),0,16*i)
    add('rail',strip,(16,256))
    bridge,cross,power = Image(32,16),Image(32,16),Image(32,16)
    for v in range(2):
        track = rail(10 if v==0 else 5)
        im = water(255)
        for y in range(16):
            for x in range(16):
                t,along = (y,x) if v==0 else (x,y)
                if 3<=t<=12: im.put(x,y,track.get(x,y))
                if t in (2,13): im.put(x,y,'slate_d')
                if t in (1,12): im.put(x,y,'metal_l')
                if t in (2,13) and along%4==1: im.put(x,y,'metal')
        bridge.blit(im,v*16,0)
        # Crossings have rail N-S first, E-W second (bridge order is reversed).
        im = road(10 if v==0 else 5)
        rt = rail(5 if v==0 else 10)
        for y in range(16):
            for x in range(16):
                t,along = (x,y) if v==0 else (y,x)
                if 3<=t<=12 and (along<=2 or along>=13): im.put(x,y,rt.get(x,y))
                if t in (4,5,10,11): im.put(x,y,'metal_l' if t in (5,10) else 'metal_d')
                # Rubber crossing panels between rails, flush with asphalt.
                if t in (6,9) and 4<=along<=11: im.put(x,y,'road_d')
        for x,y in ((1,1),(13,13)):
            if v: x,y=y,x
            im.rect(x,y,2,2,'red_d')
            im.rect(x,y,1,2,'white'); im.put(x,y+1,'bad')
            im.put(x+1,y,'amber_l')
        cross.blit(im,v*16,0)
        im = track.crop(0,0,16,16)
        # Exactly the original cable lanes and roadside cross-arm placement.
        if v==0:
            for x,c in ((7,'wood_d'),(9,'slate_d')): im.line(x,0,x,15,c)
            for y in (1,14):
                im.line(4,y,11,y,'wood'); im.put(4,y,'cream'); im.put(11,y,'cream')
        else:
            for y,c in ((7,'wood_d'),(9,'slate_d')): im.line(0,y,15,y,c)
            for x in (1,14):
                im.line(x,4,x,11,'wood'); im.put(x,4,'cream'); im.put(x,11,'cream')
        power.blit(im,v*16,0)
    for name,im in (('rail_bridge',bridge),('rail_road',cross),('line_rail',power)):
        add(name,im,(32,16))


def tiny_car(color='coral',vertical=False,reverse=False):
    im = Image(3,5) if vertical else Image(5,3)
    # One shared 3 by 5 silhouette; windows and roof are darker than the body.
    rows = ('_bb','bdb','bdb','bgb','_bl')
    colors = {'b':color,'d':'slate_d','g':'glass_d','l':'white'}
    for y,row in enumerate(rows):
        for x,c in enumerate(row):
            if c=='_': continue
            xx,yy = (2-x,4-y) if reverse else (x,y)
            im.put(xx if vertical else yy,yy if vertical else xx,colors[c])
    return im


def traffic():
    for heavy,name in ((False,'traffic_light'),(True,'traffic_heavy')):
        strip = Image(16,256)
        for m in range(16):
            base = ART['road.png'].crop(0,m*16,16,16)
            im = base.crop(0,0,16,16)
            # Each entry is inside an asphalt lane, including bends and stubs.
            spots = []
            if m&1: spots += [(4,0,True,False),(9,0,True,True)]
            if m&4: spots += [(4,11,True,False),(9,11,True,True)]
            if m&2: spots += [(11,4,False,False),(11,9,False,True)]
            if m&8: spots += [(0,4,False,False),(0,9,False,True)]
            if m in (0,1,4,5): spots += [(4,5,True,False),(9,5,True,True)]
            elif m in (2,8,10): spots += [(5,4,False,False),(5,9,False,True)]
            elif heavy: spots += [(5,5,False,False),(6,8,False,True)]
            if not heavy: spots = spots[::max(1,len(spots)//2)][:2 if m else 1]
            footprint = set()
            for i,(x,y,vertical,reverse) in enumerate(spots):
                sprite = tiny_car(('coral','com','amber_l','mint','white')[(i+m)%5],vertical,reverse)
                pixels = {(x+xx,y+yy) for yy in range(sprite.h) for xx in range(sprite.w) if sprite.get(xx,yy)[3]}
                assert not footprint & pixels, (name,m)
                assert all(base.get(xx,yy) in (P['road'],P['stripe']) for xx,yy in pixels), (name,m)
                footprint |= pixels
                im.blit(sprite,x,y)
            assert all(im.get(x,y)==base.get(x,y) for y in range(16) for x in range(16) if (x,y) not in footprint)
            TRAFFIC_PIXELS[name,m] = footprint
            strip.blit(im,0,m*16)
        add(name,strip,(16,256))
    im = Image(16,16)
    im.blit(tiny_car('amber_l'),1,5); im.blit(tiny_car('com'),4,10)
    im.rect(11,1,4,9,'red_d'); im.rect(11,1,3,8,'bad')
    im.rect(12,2,1,5,'white'); im.rect(11,12,3,3,'bad'); im.put(12,12,'white')
    add('jam',im,(16,16),True)


def flowerbed(im,x,y,w=6):
    im.rect(x+1,y+1,w,4,'grass_d'); im.rect(x,y,w,3,'leaf_d')
    for i in range(0,w,2):
        im.put(x+i,y,'leaf_m'); im.put(x+i,y+1,'coral_l' if i%4 else 'amber_l')


def parks():
    for v in range(2):
        im = ground(v)
        # Paths remain inset so arbitrary park neighbours share lawn borders.
        points = ([(2,13),(3,10),(6,9),(9,9),(12,6),(13,2)] if v==0 else
                  [(2,3),(5,4),(7,7),(7,10),(10,13),(13,13)])
        for a,b in zip(points,points[1:]):
            for dx,dy in ((0,0),(1,0),(0,1)): im.line(a[0]+dx,a[1]+dy,b[0]+dx,b[1]+dy,'sand')
        bench(im,3 if v==0 else 8,3 if v==0 else 8)
        flowerbed(im,8 if v==0 else 2,10,5)
        flowerbed(im,2 if v==0 else 9,7 if v==0 else 2,3)
        add(f'park_{v}',im,(16,16))
    im = lot()
    im.rect(22,1,4,46,'sand'); im.rect(1,22,46,4,'sand')
    for a,b in (((5,5),(40,40)),((40,5),(5,40))):
        for dx in (0,1,2): im.line(a[0]+dx,a[1],b[0]+dx,b[1],'sand')
    im.oval(15,16,20,20,'grass_d'); im.oval(14,14,20,20,'cream_d')
    im.oval(14,14,19,18,'cream'); im.oval(16,16,15,13,'water_d')
    im.oval(17,16,13,11,'water_l'); im.oval(19,18,9,7,'water')
    im.line(19,25,25,25,'foam'); im.line(18,19,21,19,'foam')
    im.oval(21,21,5,4,'cream'); im.line(23,15,23,23,'white')
    im.line(21,16,23,14,'foam'); im.line(23,14,26,18,'foam')
    for x,y in ((5,4),(33,4),(5,32),(34,32)): tree(im,x,y,9)
    for x,y in ((16,8),(28,35),(5,18),(35,26)): bench(im,x,y)
    for x,y in ((17,38),(28,6),(5,28),(35,18)): flowerbed(im,x,y,7)
    add('park_big',im,(48,48))


def services():
    im = lot('com')
    block(im,5,5,30,19,7,'slate',shadow='pave_d')
    # A shallow entrance canopy and a blue civic stripe below the windows.
    im.rect(16,28,10,3,'slate_d'); im.rect(16,27,10,2,'metal_l')
    im.rect(6,30,9,1,'com'); im.rect(28,30,6,1,'com')
    skylight(im,9,10,10,6)
    im.rect(26,10,5,3,'slate_d'); im.oval(26,8,4,4,'com'); im.put(27,8,'white')
    for x in (5,15):
        im.line(x,35,x,43,'pave_l'); im.line(x,43,x+8,43,'pave_l')
        car(im,x+2,36,'white',True)
        im.rect(x+2,39,3,2,'com'); im.put(x+2,37,'bad'); im.put(x+4,37,'glass_l')
    im.line(40,11,42,28,'pave_d'); im.line(39,5,39,27,'cream_d')
    im.line(38,5,38,27,'white'); im.oval(36,27,5,2,'cream_d')
    im.poly([(39,6),(44,7),(43,10),(39,9)],'com'); im.line(39,6,43,7,'glass_l')
    hedge(im,27,39,15); hedge(im,4,3,13)
    add('police',im,(48,48))
    im = lot('com')
    # A broad brick appliance hall plus a separate taller hose-drying tower.
    block(im,4,11,29,16,8,'red',wall='red',shadow='pave_d')
    for y in (28,31,34):
        for x in range(5+(y%2)*2,33,4): im.put(x,y,'red_l')
    for x in (6,15,24):
        im.rect(x,27,7,8,'red_d'); im.rect(x+1,28,5,7,'metal_d')
        for y in (28,30,32): im.line(x+1,y,x+5,y,'metal')
        im.rect(x+1,29,5,1,'glass_d'); im.put(x+3,33,'white')
        im.line(x,35,x+6,35,'cream')
    skylight(im,9,15,17,5)
    block(im,34,4,8,23,8,'red',wall='red',shadow='pave_d')
    im.rect(36,12,3,8,'red_d'); im.line(36,12,36,19,'slate_d')
    for y in (13,16,19,28,31): im.line(37,y,39,y,'cream_d')
    im.line(33,7,42,7,'cream'); im.line(34,25,41,25,'cream')
    im.rect(7,39,13,5,'pave_d'); im.rect(6,38,13,5,'red_d')
    im.rect(6,38,12,4,'bad'); im.rect(7,39,3,2,'glass_d')
    im.rect(11,39,7,2,'metal_l'); im.line(11,40,17,40,'metal_d')
    for x in (12,15): im.put(x,39,'white')
    im.put(6,38,'white'); im.put(9,38,'com'); im.put(10,38,'white')
    for x in (8,16): im.put(x,43,'ink')
    im.line(24,40,31,40,'pave_l'); hedge(im,34,40,9)
    add('fire',im,(48,48))


def solar_panel(im,x,y,w=15,h=9):
    im.rect(x+2,y+3,w,h,'grass_d')
    im.line(x+3,y+h,x+3,y+h+2,'metal_d')
    im.line(x+w-3,y+h,x+w-3,y+h+2,'metal_d')
    im.poly([(x+2,y),(x+w-1,y),(x+w-3,y+h-1),(x,y+h-1)],'metal_l')
    im.poly([(x+3,y+1),(x+w-2,y+1),(x+w-4,y+h-2),(x+1,y+h-2)],'solar_d')
    for yy in range(1,h-1):
        shift = 1 if yy<h//2 else 0
        for xx in range(2+shift,w-3+shift):
            im.put(x+xx,y+yy,'solar_l' if (xx-shift)%4==0 or yy==4 else 'solar')
    im.line(x,y+h-1,x+w-3,y+h-1,'metal_d')


def solar():
    base = lot(size=64)
    for y in (2,60):
        base.line(2,y,60,y,'metal_d')
        for x in range(2,61,4): base.rect(x,y-1,1,3,'metal_l')
    for x in (2,60):
        base.line(x,2,x,60,'metal_d')
        for y in range(5,60,4): base.rect(x-1,y,3,1,'metal_l')
    base.rect(5,47,54,11,'pave'); base.rect(49,5,7,47,'sand')
    for y in (6,20,34):
        for x in (6,26): solar_panel(base,x,y,18,10)
    block(base,6,47,23,7,4,'slate',shadow='pave_d')
    base.rect(10,49,5,3,'metal_l'); base.line(10,49,14,49,'white')
    for x in (34,40):
        base.rect(x+1,50,4,7,'pave_d'); base.rect(x,49,4,7,'metal_d')
        base.rect(x,49,3,6,'metal'); base.line(x,49,x+2,49,'metal_l')
        for y in (51,53): base.line(x+1,y,x+2,y,'slate_d')
    base.rect(49,59,7,3,'pave'); base.line(49,58,49,61,'metal_l'); base.line(56,58,56,61,'metal_l')
    glints = (((11,8),(35,22),(14,36)),((19,8),(41,22),(21,36)))
    for frame in range(2):
        im = base.crop(0,0,64,64)
        for x,y in glints[frame]:
            assert base.get(x,y) in (P['solar'],P['solar_l'])
            im.line(x,y,x+1,y,'white'); im.put(x,y+1,'glass_l')
        add(f'solar_{frame}',im,(64,64))
    diff = {i for i,(a,b) in enumerate(zip(ART['solar_0.png'].p,ART['solar_1.png'].p)) if a!=b}
    allowed = {yy*64+xx for frame in glints for x,y in frame for xx,yy in ((x,y),(x+1,y),(x,y+1))}
    assert diff==allowed and len(diff)==18


def fires():
    for frame in range(4):
        im = ART['rubble_0.png'].crop(0,0,16,16)
        im.oval(1,5,14,10,'coal'); im.oval(2,8,11,6,'coal_l')
        # Four circular phases, not independent pictures: tongues sway a pixel
        # around their fixed roots and smoke rises, thins and is replenished.
        sway = (0,1,0,-1)[frame]
        rise = (0,0,1,1)[frame]
        im.oval(5+sway,1,7,5,'metal_d'); im.oval(3+sway,0,7,4-rise,'smoke')
        im.oval(7-sway,3,6,5,'metal'); im.oval(6-sway,3,4,3,'smoke')
        im.poly([(2,12),(2,8),(4+sway,4),(5,8),(7,6),(8-sway,2),
                 (10,7),(12+sway,5),(13,10),(14,12),(11,14),(4,14)],'flame_d')
        im.poly([(3,12),(4,8),(5,10),(7,8),(8-sway,5),(9,9),
                 (11+sway,7),(12,11),(11,13),(5,13)],'flame')
        im.poly([(5,12),(6,9),(7,11),(9,7),(10,11),(9,13),(6,13)],'amber_l')
        im.poly([(7,12),(8,10),(9,12),(8,13)],'flame_l')
        im.put(3,14,'red_d'); im.put(12,14,'rust_d')
        add(f'fire_{frame}',im,(16,16))


def portrait(role):
    im = Image(32,32,'panel')
    im.oval(2,3,29,29,'panel_dark'); im.oval(1,1,29,29,'panel_light')
    im.oval(3,3,25,25,'panel')
    deep = role=='engineer'
    fair = role in ('clerk','resident')
    skin = 'skin_deep' if deep else 'skin_fair' if fair else 'skin'
    coat = {'clerk':'slate','engineer':'rust','shopkeeper':'coral','resident':'res'}[role]
    hair = {'clerk':'metal','engineer':'wood_d','shopkeeper':'wood_d','resident':'metal_l'}[role]
    # A different shoulder line, hair silhouette and accessories for each role.
    im.poly([(4,29),(5,25),(10,22),(13,21),(21,21),(26,24),(28,29)],coat+'_d' if coat!='res' else 'leaf_d')
    im.poly([(5,29),(6,25),(11,23),(15,22),(19,22),(24,25),(25,29)],coat)
    im.rect(13,19,6,5,skin+'_d'); im.rect(13,19,4,4,skin)
    im.oval(8,7,16,17,hair)
    if role=='resident':
        for x,y in ((8,7),(7,11),(8,16),(20,8),(21,13),(20,17)):
            im.oval(x,y,5,6,'metal')
    im.oval(8,13,4,6,skin+'_d'); im.oval(21,13,3,6,skin+'_d')
    im.put(9,14,skin+'_l')
    im.poly([(11,9),(20,9),(22,12),(22,18),(19,22),(14,22),(10,18),(10,12)],skin+'_d')
    im.poly([(11,10),(19,10),(20,13),(20,18),(18,21),(14,21),(11,18)],skin)
    im.line(11,12,11,16,skin+'_l'); im.line(12,11,16,11,skin+'_l')
    im.line(12,13,14,13,'wood_d'); im.line(18,13,20,13,'wood_d')
    for x in (13,19):
        im.put(x,15,'ink'); im.put(x-1,15,skin+'_l')
    im.line(16,15,16,17,skin+'_d'); im.put(15,17,skin+'_l')
    im.line(14,19,17,19,'red_d'); im.put(18,18,skin+'_d')
    im.line(15,20,17,20,skin+'_l')
    if role=='clerk':
        im.oval(9,7,6,5,'metal'); im.oval(18,7,5,5,'metal_d')
        im.line(11,8,14,8,'metal_l'); im.line(14,9,19,9,skin+'_l')
        for x in (10,17):
            im.line(x,13,x+5,13,'slate_d'); im.line(x,16,x+5,16,'slate_d')
            im.line(x,13,x,16,'slate_d'); im.line(x+5,13,x+5,16,'slate_d')
            im.put(x+1,14,'white')
        im.line(15,14,17,14,'slate_d')
        im.poly([(11,23),(15,25),(13,27)],'cream')
        im.poly([(19,23),(16,25),(18,27)],'cream'); im.line(16,25,16,29,'amber')
        im.poly([(3,24),(10,23),(12,29),(4,30)],'wood_d')
        im.poly([(4,24),(9,24),(10,28),(5,29)],'cream')
        im.line(5,25,8,25,'wood_l'); im.line(6,27,9,27,'wood_l')
        im.oval(9,27,4,3,skin)
    elif role=='engineer':
        im.oval(7,4,18,11,'amber_d'); im.oval(8,4,15,9,'amber')
        im.line(10,6,13,5,'amber_l'); im.rect(15,4,3,8,'amber_l')
        im.line(18,5,18,10,'amber_d')
        im.rect(6,11,20,3,'amber_d'); im.line(7,11,24,11,'amber_l')
        im.line(11,24,12,29,'slate_d'); im.line(21,24,20,29,'slate_d')
        im.rect(12,26,8,4,'slate'); im.put(12,26,'metal_l'); im.put(19,26,'metal_l')
        im.line(15,28,18,28,'slate_l')
        im.put(10,18,'amber_l'); im.put(22,18,'amber_l')
    elif role=='shopkeeper':
        im.poly([(9,12),(9,7),(12,5),(19,5),(23,8),(23,13),(20,10),(16,9),(12,11)],'wood_d')
        im.line(11,7,16,6,'wood'); im.line(18,7,21,9,'wood')
        im.line(14,18,18,18,'wood_d'); im.put(16,19,skin)
        im.line(11,23,13,26,'cream'); im.line(21,23,19,26,'cream')
        im.poly([(13,24),(19,24),(22,30),(10,30)],'cream_d')
        im.poly([(13,24),(18,24),(20,29),(11,29)],'cream')
        im.rect(14,27,4,2,'red_l'); im.line(14,27,17,27,'white')
    else:
        for x,y in ((9,7),(12,5),(16,5),(19,7)):
            im.oval(x,y,5,5,'metal_l'); im.put(x+1,y,'white')
        im.line(12,13,14,13,'metal_d'); im.line(18,13,20,13,'metal_d')
        im.put(12,17,'coral_l'); im.put(20,17,'coral_l')
        im.poly([(10,22),(14,23),(21,22),(21,25),(17,26),(19,30),(15,30),(13,26),(10,25)],'com')
        im.line(11,23,16,24,'glass_l'); im.line(15,26,17,29,'glass_d')
        im.put(11,18,'amber_l'); im.put(22,18,'amber_l')
    return im


def paper_head():
    im = Image(240,32)
    # Original cut-corner letter plans, drawn at native resolution. Their wide
    # stems and counters echo the PLAT logo without borrowing a typeface.
    plans = {
        'P':(18,[(0,22),(0,3),(3,0),(14,0),(18,4),(18,11),(14,15),(5,15),(5,22)],
             [[(5,5),(12,5),(13,6),(13,9),(12,10),(5,10)]]),
        'L':(16,[(0,0),(5,0),(5,17),(16,17),(16,22),(0,22)],[]),
        'A':(20,[(0,22),(0,6),(6,0),(14,0),(20,6),(20,22),(15,22),(15,15),(5,15),(5,22)],
             [[(5,6),(7,4),(13,4),(15,6),(15,10),(5,10)]]),
        'T':(18,[(0,0),(18,0),(18,5),(12,5),(12,22),(6,22),(6,5),(0,5)],[]),
        'E':(16,[(0,0),(16,0),(16,5),(5,5),(5,9),(14,9),(14,13),(5,13),(5,17),(16,17),(16,22),(0,22)],[]),
        'D':(19,[(0,0),(12,0),(19,6),(19,16),(12,22),(0,22)],
             [[(5,5),(10,5),(14,8),(14,14),(10,17),(5,17)]]),
        'G':(19,[(5,0),(17,0),(19,5),(7,5),(5,7),(5,15),(7,17),(14,17),(14,13),(10,13),(10,9),(19,9),(19,19),(16,22),(5,22),(0,17),(0,5)],[]),
        'R':(19,[(0,22),(0,0),(14,0),(18,4),(18,10),(13,14),(19,22),(12,22),(6,14),(5,14),(5,22)],
             [[(5,5),(12,5),(13,6),(13,8),(12,9),(5,9)]]),
    }
    word = 'PLAT LEDGER'
    width = sum(9 if c==' ' else plans[c][0]+4 for c in word)-4
    x = (240-width)//2
    for c in word:
        if c==' ': x+=9; continue
        w,outline,holes = plans[c]
        glyph = Image(w+2,25)
        glyph.poly([(xx+1,yy+1) for xx,yy in outline],'panel_dark')
        glyph.poly(outline,'ink')
        for hole in holes: glyph.poly(hole,CLEAR)
        # Restrained one-pixel top-left highlights, never a gradient.
        for yy in range(23):
            for xx in range(w+1):
                if glyph.get(xx,yy)==P['ink'] and (yy==0 or not glyph.get(xx,yy-1)[3]):
                    glyph.put(xx,yy,'slate')
        im.blit(glyph,x,2); x+=w+4
    im.line(8,29,231,29,'ink')
    return im


def new_tool(name):
    im = Image(20,20)
    if name=='rail':
        for y in (4,8,12,16):
            im.rect(3,y,14,2,'wood_d'); im.line(3,y,15,y,'wood_l')
        for x in (6,12):
            im.rect(x,2,2,17,'metal_d'); im.line(x,2,x,17,'metal_l')
    elif name=='police':
        im.poly([(3,3),(7,3),(10,1),(13,3),(17,3),(16,12),(13,16),(10,18),(6,15),(4,11)],'slate_d')
        im.poly([(4,4),(8,4),(10,3),(12,4),(15,4),(14,12),(10,16),(6,12)],'com')
        im.line(4,4,5,10,'glass_l')
        im.poly([(10,5),(11,8),(14,8),(12,10),(13,13),(10,11),(7,13),(8,10),(6,8),(9,8)],'amber_l')
    elif name=='fire':
        im.oval(4,4,13,12,'red_d'); im.oval(4,3,12,11,'bad')
        im.rect(9,3,3,10,'coral_l'); im.line(12,4,12,10,'red_d')
        im.poly([(3,11),(16,11),(18,14),(16,16),(2,15),(1,13)],'red_d')
        im.line(3,12,16,12,'coral_l'); im.line(3,13,16,13,'bad')
        im.rect(8,7,5,5,'amber_d'); im.rect(9,7,3,4,'amber_l')
    elif name=='park':
        tree(im,3,2,10,'panel_dark'); bench(im,11,15)
        im.line(4,17,10,17,'grass'); im.put(5,16,'leaf_l')
    elif name=='solar':
        im.oval(12,2,5,5,'amber_l')
        for a,b in (((14,0),(14,0)),((18,4),(19,4)),((10,3),(10,3)),((17,0),(17,1))): im.line(*a,*b,'amber')
        im.line(6,14,5,18,'metal_d'); im.line(15,14,15,18,'metal_d')
        im.poly([(5,7),(18,7),(15,15),(2,15)],'metal_l')
        im.poly([(6,8),(16,8),(14,14),(4,14)],'solar')
        im.line(5,11,15,11,'solar_l')
        for x in (8,12): im.line(x+1,8,x-1,14,'solar_l')
        im.line(2,15,15,15,'solar_d')
    elif name=='budget':
        im.poly([(2,4),(8,3),(10,5),(12,3),(18,4),(18,16),(12,15),(10,17),(8,15),(2,16)],'wood_d')
        im.poly([(3,5),(8,4),(9,6),(9,14),(8,13),(3,14)],'cream')
        im.poly([(10,6),(12,4),(17,5),(17,14),(12,13),(10,15)],'white')
        for y in (7,10):
            im.line(4,y,7,y,'wood_l'); im.line(12,y,15,y,'cream_d')
        im.oval(12,12,7,7,'amber_d'); im.oval(12,12,6,6,'amber')
        im.line(14,13,14,16,'amber_l'); im.put(13,13,'white')
    elif name=='map':
        im.poly([(2,4),(7,2),(13,4),(18,2),(18,15),(13,18),(7,16),(2,18)],'slate_d')
        im.poly([(3,5),(7,3),(12,5),(17,3),(17,14),(13,16),(7,14),(3,16)],'cream')
        im.poly([(3,6),(6,4),(6,9),(3,10)],'res')
        im.poly([(8,5),(11,6),(12,10),(8,10)],'com')
        im.poly([(14,5),(16,4),(16,10),(14,11)],'ind')
        im.poly([(8,12),(11,11),(12,15),(8,14)],'coral')
        im.line(3,13,16,9,'white'); im.line(7,3,7,15,'cream_d'); im.line(13,5,13,16,'white')
    else:
        assert name in ('zoom_in','zoom_out')
        im.rect(5,3,10,14,'slate_d'); im.rect(3,5,14,10,'slate_d')
        im.rect(4,4,12,12,'slate_d'); im.rect(5,5,10,10,'panel_light')
        im.line(6,4,13,4,'metal_l'); im.line(4,6,4,13,'metal_l')
        im.rect(6,9,8,2,'com')
        if name=='zoom_in': im.rect(9,6,2,8,'com')
        for x,y,dx,dy in ((1,1,1,1),(18,1,-1,1),(1,18,1,-1),(18,18,-1,-1)):
            im.line(x,y,x+2*dx,y,'slate'); im.line(x,y,x,y+2*dy,'slate')
    return im


def tier2_ui():
    for role in ('clerk','engineer','shopkeeper','resident'):
        add('adv_'+role,portrait(role),(32,32))
    add('paper_head',paper_head(),(240,32),True)
    for name in NEW_TOOLS: add('tool_'+name,new_tool(name),(20,20),True)


def tier2_sheet():
    sh = Image(1152,896,'panel')
    shown = set()
    for row,name in enumerate(('rail','traffic_light','traffic_heavy')):
        y = 12+row*74
        for m in range(16):
            x = 16+m*70
            sh.blit(ART[name+'.png'].crop(0,m*16,16,16).scale(2),x,y)
            caption(sh,str(m),x+12,y+36)
        caption(sh,name+'.png',16,y+49); shown.add(name)
    names = ('rail_bridge','rail_road','line_rail','jam','park_0','park_1',
             'fire_0','fire_1','fire_2','fire_3')
    for i,name in enumerate(names):
        x,y = 16+i*112,242
        sh.blit(ART[name+'.png'].scale(2),x,y)
        caption(sh,name+'.png',x,y+40); shown.add(name)
    for i,name in enumerate(('police','fire','park_big','solar_0','solar_1')):
        x,y = 16+i*224,316
        sh.blit(ART[name+'.png'].scale(2),x,y)
        caption(sh,name+'.png',x,y+137); shown.add(name)
    for i,role in enumerate(('clerk','engineer','shopkeeper','resident')):
        x,y = 16+i*224,492
        name = 'adv_'+role
        sh.blit(ART[name+'.png'].scale(3),x,y)
        caption(sh,name+'.png',x,y+104); shown.add(name)
    for i,name in enumerate(NEW_TOOLS):
        x,y = 16+i*126,644
        b = button(); b.blit(ART['tool_'+name+'.png'],4,4)
        sh.blit(b.scale(3),x,y)
        caption(sh,'tool_'+name+'.png',x,y+92); shown.add('tool_'+name)
    sh.blit(ART['paper_head.png'].scale(2),16,794)
    caption(sh,'paper_head.png',16,866); shown.add('paper_head')
    assert shown == set(TIER2_SIZES)-{'sheet_tier2','sample_town2'}
    add('sheet_tier2',sh,(1152,896))


def sample_town2():
    cells = [[(f'ground_{(x*3+y*7)%4}.png',0,0) for x in range(40)] for y in range(24)]
    watercells = set()
    # River bend on the left, broad enough that the rail bridge has visible
    # water beside every girder and joins the banks at its two abutments.
    for y in range(24):
        for x in range(9):
            if 2<=x<=5 or (y<6 and 1<=x<=6) or (y>18 and 3<=x<=7): watercells.add((x,y))
    for x,y in watercells:
        m = sum(bit for bit,dx,dy in ((1,0,-1),(2,1,-1),(4,1,0),(8,1,1),(16,0,1),(32,-1,1),(64,-1,0),(128,-1,-1))
                if (x+dx,y+dy) in watercells or y+dy<0 or y+dy>=24)
        cells[y][x] = ('water.png',0,MASKS.index(normalize(m))*16)
    for y in range(24):
        for x in range(40):
            if (x,y) not in watercells and (x<8 or y in (0,23) or x==39):
                cells[y][x] = (f'woods_{(x+y)%4}.png',0,0)
    roads = {(x,y) for y in (5,12,18,22) for x in range(9,39)}
    roads -= {(x,18) for x in range(31,38)}  # Four-cell solar lot beside the east road.
    roads |= {(x,y) for x in (9,16,23,30,38) for y in range(1,23)}
    rails = {(x,9) for x in range(40)}
    # A curved freight siding proves two quarter-circle masks in context.
    rails |= {(35,y) for y in range(9,16)} | {(x,15) for x in range(35,38)}
    power = {(28,y) for y in range(8,22)} | {(x,21) for x in range(28,35)}
    for x,y in roads:
        m = sum(bit for bit,dx,dy in CARDINAL if (x+dx,y+dy) in roads)
        name = ('traffic_heavy' if y==12 or x==23 and y>12 else
                'traffic_light' if y in (5,18) or x==16 else 'road')
        cells[y][x] = (name+'.png',0,m*16)
    for x,y in rails:
        m = sum(bit for bit,dx,dy in CARDINAL if (x+dx,y+dy) in rails or x+dx<0 or x+dx>=40)
        if (x,y) in watercells:
            assert m==10; cells[y][x] = ('rail_bridge.png',0,0)
        elif (x,y) in roads:
            assert m in (5,10); cells[y][x] = ('rail_road.png',16 if m==10 else 0,0)
        else: cells[y][x] = ('rail.png',0,16*m)
    for x,y in power:
        m = sum(bit for bit,dx,dy in CARDINAL if (x+dx,y+dy) in power)
        if (x,y)==(34,21): m|=1  # Feed up to the solar plant's southern fence.
        if (x,y) in rails:
            assert m==5; cells[y][x] = ('line_rail.png',0,0)
        elif (x,y) in roads:
            assert m in (5,10); cells[y][x] = ('line_road.png',0 if m==5 else 16,0)
        else: cells[y][x] = ('line.png',0,16*m)
    occupied = set()
    placements = set()
    def place(name,x,y):
        src = ART[name+'.png']
        assert src.w%16==src.h%16==0
        for yy in range(src.h//16):
            for xx in range(src.w//16):
                q = x+xx,y+yy
                assert 0<=q[0]<40 and 0<=q[1]<24
                assert q not in roads|rails|power|watercells|occupied,(name,q)
                occupied.add(q)
                cells[q[1]][q[0]] = (name+'.png',xx*16,yy*16)
        placements.add(name)
    for name,x,y in (
        ('zone_res_1_a',10,2),('zone_res_2_b',17,2),('zone_res_3_a',24,2),('zone_res_4_b',31,2),
        ('police',10,6),('park_big',17,6),('fire',24,6),('zone_com_1_b',31,6),
        ('zone_com_3_a',10,14),('zone_com_4_b',17,14),('zone_res_2_a',24,14),
        ('zone_com_2_b',10,19),('zone_res_1_b',17,19),('zone_ind_2_a',24,19),
        ('zone_ind_3_a',34,2),('zone_ind_1_b',31,13),('solar_0',34,17)):
        place(name,x,y)
    for x,y in ((14,3),(14,4),(21,3),(21,4),(21,7),(21,8),(14,7),(14,8),
                (29,3),(29,4),(36,6),(36,7),(36,8),(14,15),(21,15),(29,16),(32,19),(32,20)):
        place('park_'+str((x+y)%2),x,y)
    place('rubble_1',36,14); place('fire_0',37,14)
    world = Image(640,384)
    for y,row in enumerate(cells):
        for x,(name,sx,sy) in enumerate(row):
            world.blit(ART[name].crop(sx,sy,16,16),x*16,y*16)
    world.blit(ART['jam.png'],23*16,12*16)
    assert {'police','fire','park_big','solar_0','fire_0','park_0','park_1'} <= placements
    assert all(any(n.startswith('zone_'+k) for n in placements) for k in ('res','com','ind'))
    assert {'rail_road.png','rail_bridge.png','line_rail.png','traffic_light.png','traffic_heavy.png'} <= {c[0] for row in cells for c in row}
    add('sample_town2',world,(640,384))


def validate_tier2(original):
    assert set(ART)-set(original)=={n+'.png' for n in TIER2_SIZES}
    assert all((ART[n+'.png'].w,ART[n+'.png'].h)==size for n,size in TIER2_SIZES.items())
    assert all(ART[n].png()==data for n,data in original.items()), 'first-part art changed'
    assert RAIL_MASKS==tuple(range(16)) and CARDINAL==((1,0,-1),(2,1,0),(4,0,1),(8,-1,0))
    tiles = [ART['rail.png'].crop(0,m*16,16,16) for m in RAIL_MASKS]
    for a in RAIL_MASKS:
        assert tiles[a].p==rail(a).p  # Also verify the strip's mask order.
        for b in RAIL_MASKS:
            if a&2 and b&8: assert [tiles[a].get(15,y) for y in range(16)]==[tiles[b].get(0,y) for y in range(16)]
            if a&4 and b&1: assert [tiles[a].get(x,15) for x in range(16)]==[tiles[b].get(x,0) for x in range(16)]
        assert len(TRAFFIC_PIXELS['traffic_heavy',a])>len(TRAFFIC_PIXELS['traffic_light',a])
    for name in ('rail_bridge','rail_road','line_rail'):
        for v in range(2):
            im = ART[name+'.png'].crop(v*16,0,16,16)
            vertical = v==0 if name=='rail_road' else v==1
            for lane in (4,5,10,11):
                for end in (0,15):
                    x,y = (lane,end) if vertical else (end,lane)
                    assert im.get(x,y)==P['metal_l' if lane in (5,10) else 'metal_d'],(name,v,lane)
    for name in ('park_0','park_1','police','fire','solar_0','solar_1'):
        im = ART[name+'.png']
        assert all(im.get(x,y)==P['grass'] for x in range(im.w) for y in range(im.h)
                   if x in (0,im.w-1) or y in (0,im.h-1)),name
    assert len({bytes(v for c in ART[f'fire_{i}.png'].p for v in c) for i in range(4)})==4
    used = {c for im in ART.values() for c in im.p if c[3]}
    used |= {P[k] for k in ('panel','panel_light','panel_dark','text','text_dim','good','bad','res','com','ind')}
    assert len(used)<=200 and used<=set(P.values()) and (0,0,0,255) not in used
    return used


def main():
    terrain(); networks(); zones(); ui(); contact_sheets(); sample_town()
    colors=validate()
    original = {n:im.png() for n,im in ART.items()}
    masks_text = ''.join(str(m)+'\n' for m in MASKS)
    ui_names=('panel','panel_light','panel_dark','text','text_dim','good','bad','res','com','ind')
    ui_text = ''.join(k+' '+HEX[k].upper()+'\n' for k in ui_names)
    # Frozen from the first-part outputs: a deterministic build checks itself
    # without depending on external files or on a particular BEFORE directory.
    frozen = {**original,'water_masks.txt':masks_text.encode('ascii'),'ui_colours.txt':ui_text.encode('ascii')}
    assert hashlib.sha256(b''.join(frozen[n] for n in sorted(frozen))).hexdigest() == 'e70cf008be69958f996359db4a496b6a3dee04c6edd0b0c9c84b11557e7680de'
    rail_networks(); traffic(); parks(); services(); solar(); fires(); tier2_ui()
    tier2_sheet(); sample_town2()
    used = validate_tier2(original)
    # Keep every original palette swatch at its exact index; only append.
    colors += sorted(used-set(colors))
    pal=Image(16,math.ceil(len(colors)/16))
    for i,c in enumerate(colors): pal.put(i%16,i//16,c)
    # Unused slots are transparent; each opaque palette swatch appears once.
    add('palette',pal,(16,math.ceil(len(colors)/16)),len(colors)%16!=0)
    OUT.mkdir(parents=True,exist_ok=True)
    for name,im in ART.items():
        assert (im.w,im.h)==EXPECTED[name]
        assert all(c[3] in (0,255) for c in im.p)
        (OUT/name).write_bytes(im.png())
    (OUT/'water_masks.txt').write_text(masks_text,encoding='ascii')
    (OUT/'ui_colours.txt').write_text(ui_text,encoding='ascii')
    digest=hashlib.sha256(b''.join(ART[n].png() for n in sorted(ART))).hexdigest()
    print(f'Wrote {len(ART)} PNGs and 2 text files to {OUT}')
    print(f'{len(colors)} opaque colours; 47 ascending water masks; all size/alpha/join assertions passed.')
    print('PNG content SHA-256:',digest)


if __name__=='__main__':
    main()
