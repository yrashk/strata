#!/usr/bin/env python3
"""SushiBelt's pixel workshop: Python 3, standard library, no input assets.

Run from any directory. Coordinates are native pixels; rect/oval take x,y,w,h.
Every shape is rasterised directly, without antialiasing or colour blending.
The 64-colour palette is shared even by the mock-up and contact sheets.
"""
from pathlib import Path
import hashlib
import struct
import zlib

OUT = Path(__file__).resolve().parents[1] / 'os/progs/sushi/art'
HEX = {
    'ink':'292c38', 'black':'000000', 'white':'ffffff',
    'walnut_d':'403039', 'walnut':'63413d', 'walnut_l':'925b48',
    'wood_d':'b27c54', 'wood':'dbac72', 'wood_l':'f2cd91',
    'cream_d':'c8b99b', 'cream':'e9dcc0', 'ivory':'fff3d9',
    'slate_d':'3d4954', 'slate':'556371', 'slate_l':'829399', 'metal':'b9cbca',
    'indigo_d':'303b60', 'indigo':'465889', 'indigo_l':'6a7ca7',
    'blue_d':'295b70', 'blue':'3d889b', 'blue_l':'74b8bc',
    'green_d':'315e4e', 'green':'57935e', 'green_l':'a7cc73',
    'red_d':'883e49', 'red':'cb5054', 'red_l':'f78770',
    'coral_d':'bd554e', 'coral':'f17c68', 'coral_l':'ffb794',
    'gold_d':'a66c3c', 'gold':'edb94f', 'gold_l':'ffe69b',
    'orange_d':'ab5834', 'orange':'f08b3e', 'orange_l':'ffc16a',
    'skin_d':'b87360', 'skin':'e8a681', 'skin_l':'ffd2a4',
    'deep_d':'704743', 'deep':'a06a53', 'deep_l':'ce9470',
    'pink_d':'9b4d69', 'pink':'e4839d', 'pink_l':'ffc4c7',
    'lilac_d':'6c557f', 'lilac':'a183ae', 'lilac_l':'cfb4ce',
    'nori_d':'263f3c', 'nori':'3d6050', 'nori_l':'6c8860',
    'stale_d':'73745b', 'stale':'a1a482', 'stale_l':'c8c8a6',
    'grey_d':'606172', 'grey':'9897a3', 'grey_l':'d0ced2',
    'patience_green':'88bd61', 'patience_yellow':'f1cd67',
    'patience_red':'df6563', 'progress':'65b6b1', 'select':'ffe7a8',
    'night':'232c49',
}
P = {name: tuple(bytes.fromhex(value))+(255,) for name,value in HEX.items()}
CLEAR = (0,0,0,0)
assert len(P) == len(set(P.values())) == 64


class Image:
    def __init__(self, w, h, color=None):
        self.w,self.h = w,h
        self.p = [P[color] if isinstance(color,str) else color or CLEAR]*(w*h)

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.p[y*self.w+x] = P[c] if isinstance(c,str) else c

    def get(self, x, y):
        return self.p[y*self.w+x] if 0 <= x < self.w and 0 <= y < self.h else CLEAR

    def rect(self, x, y, w, h, c):
        for yy in range(max(0,y),min(self.h,y+h)):
            for xx in range(max(0,x),min(self.w,x+w)):
                self.put(xx,yy,c)

    def line(self, x, y, xx, yy, c):
        dx,dy = abs(xx-x),-abs(yy-y)
        sx,sy = (1 if x<xx else -1),(1 if y<yy else -1)
        err = dx+dy
        while True:
            self.put(x,y,c)
            if (x,y)==(xx,yy): break
            e = err*2
            if e>=dy: err+=dy; x+=sx
            if e<=dx: err+=dx; y+=sy

    def poly(self, points, c):
        for y in range(min(p[1] for p in points),max(p[1] for p in points)+1):
            for x in range(min(p[0] for p in points),max(p[0] for p in points)+1):
                inside=False
                for (xa,ya),(xb,yb) in zip(points,points[1:]+points[:1]):
                    if (ya>y)!=(yb>y) and x < (xb-xa)*(y-ya)/(yb-ya)+xa:
                        inside=not inside
                if inside: self.put(x,y,c)
        for a,b in zip(points,points[1:]+points[:1]): self.line(*a,*b,c)

    def oval(self, x, y, w, h, c):
        for yy in range(h):
            for xx in range(w):
                if ((2*xx+1-w)*h)**2+((2*yy+1-h)*w)**2 <= (w*h)**2:
                    self.put(x+xx,y+yy,c)

    def round(self, x, y, w, h, r, c):
        self.rect(x+r,y,w-2*r,h,c)
        self.rect(x,y+r,w,h-2*r,c)
        for xx in (x,x+w-2*r):
            for yy in (y,y+h-2*r): self.oval(xx,yy,r*2,r*2,c)

    def blit(self, src, x, y):
        for yy in range(src.h):
            for xx in range(src.w):
                c=src.get(xx,yy)
                if c[3]: self.put(x+xx,y+yy,c)

    def crop(self, x, y, w, h):
        im=Image(w,h)
        for yy in range(h):
            for xx in range(w): im.put(xx,yy,self.get(x+xx,y+yy))
        return im

    def scale(self, n):
        im=Image(self.w*n,self.h*n)
        for y in range(self.h):
            row=[c for c in self.p[y*self.w:(y+1)*self.w] for _ in range(n)]
            for dy in range(n): im.p[(y*n+dy)*im.w:(y*n+dy+1)*im.w]=row
        return im

    def png(self):
        def chunk(tag, data):
            return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
        raw=b''.join(b'\0'+bytes(v for c in self.p[y*self.w:(y+1)*self.w] for v in c)
                     for y in range(self.h))
        return (b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',self.w,self.h,8,6,0,0,0))
                +chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b''))


def shape(im, method, args, fill, edge='ink'):
    mask=Image(im.w,im.h)
    getattr(mask,method)(*args,'white')
    for y in range(im.h):
        for x in range(im.w):
            if mask.get(x,y)[3]:
                boundary=any(not mask.get(x+dx,y+dy)[3] for dx,dy in ((-1,0),(1,0),(0,-1),(0,1)))
                im.put(x,y,edge if boundary else fill)


def oval(im, x, y, w, h, fill, edge='ink'):
    shape(im,'oval',(x,y,w,h),fill,edge)


def poly(im, points, fill, edge='ink'):
    shape(im,'poly',(points,),fill,edge)


def box(im, x, y, w, h, fill, edge='ink', radius=2):
    shape(im,'round',(x,y,w,h,radius),fill,edge)


# Hand-drawn five-by-seven glyphs. Lowercase x is the multiplication sign;
# sheet captions use the same alphabet, folded to upper case.
FONT_DATA = {
 ' ':'00000/00000/00000/00000/00000/00000/00000',
 '0':'01110/11001/11001/11001/11001/11001/01110',
 '1':'00100/01100/00100/00100/00100/00100/01110',
 '2':'01110/10001/00001/00110/01000/10000/11111',
 '3':'11110/00001/00001/01110/00001/00001/11110',
 '4':'00010/00110/01010/10010/11111/00010/00010',
 '5':'11111/10000/10000/11110/00001/00001/11110',
 '6':'01110/10000/10000/11110/10001/10001/01110',
 '7':'11111/00001/00010/00100/00100/01000/01000',
 '8':'01110/10001/10001/01110/10001/10001/01110',
 '9':'01110/10001/10001/01111/00001/00001/01110',
 'A':'01110/10001/10001/11111/10001/10001/10001',
 'B':'11110/10001/10001/11110/10001/10001/11110',
 'C':'01111/10000/10000/10000/10000/10000/01111',
 'D':'11110/10001/10001/10001/10001/10001/11110',
 'E':'11111/10000/10000/11110/10000/10000/11111',
 'F':'11111/10000/10000/11110/10000/10000/10000',
 'G':'01111/10000/10000/10111/10001/10001/01111',
 'H':'10001/10001/10001/11111/10001/10001/10001',
 'I':'01110/00100/00100/00100/00100/00100/01110',
 'J':'00111/00010/00010/00010/10010/10010/01100',
 'K':'10001/10010/10100/11000/10100/10010/10001',
 'L':'10000/10000/10000/10000/10000/10000/11111',
 'M':'10001/11011/10101/10101/10001/10001/10001',
 'N':'10001/11001/11001/10101/10011/10011/10001',
 'O':'01110/10001/10001/10001/10001/10001/01110',
 'P':'11110/10001/10001/11110/10000/10000/10000',
 'Q':'01110/10001/10001/10001/10101/10010/01101',
 'R':'11110/10001/10001/11110/10100/10010/10001',
 'S':'01111/10000/10000/01110/00001/00001/11110',
 'T':'11111/00100/00100/00100/00100/00100/00100',
 'U':'10001/10001/10001/10001/10001/10001/01110',
 'V':'10001/10001/10001/10001/10001/01010/00100',
 'W':'10001/10001/10001/10101/10101/11011/10001',
 'X':'10001/10001/01010/00100/01010/10001/10001',
 'Y':'10001/10001/01010/00100/00100/00100/00100',
 'Z':'11111/00001/00010/00100/01000/10000/11111',
 '+':'00000/00100/00100/11111/00100/00100/00000',
 '-':'00000/00000/00000/11111/00000/00000/00000',
 'x':'00000/00000/10001/01010/00100/01010/10001',
 ':':'00000/00100/00100/00000/00100/00100/00000',
 '!':'00100/00100/00100/00100/00100/00000/00100',
 '?':'01110/10001/00001/00110/00100/00000/00100',
 '.':'00000/00000/00000/00000/00000/00110/00110',
 '%':'11001/11010/00010/00100/01000/01011/10011',
 '/':'00001/00010/00010/00100/01000/01000/10000',
 '¥':'10001/01010/00100/11111/00100/11111/00100',
 '_':'00000/00000/00000/00000/00000/00000/11111',
}
FONT={k:v.split('/') for k,v in FONT_DATA.items()}
SMALL=' 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-x:!?.%/¥'
BIG='0123456789+-x:¥'
KINDS=('salmon','tuna','tamago','ebi','kappa','ikura','unagi','uramaki')
PLATES=('green','blue','red','gold','black')
COOK_FRAMES=('idle_0','idle_1','slice_0','slice_1','rice_0','rice_1',
             'roll_0','roll_1','place_0','place_1','cheer','oops')
CUSTOMERS=('office','granny','student','tourist','artist','builder','kid','chef_fan')
CUST_FRAMES=('sit_0','sit_1','want','eat_0','eat_1','happy','angry')
ART={}
GROUP={}
EXPECTED={}
OPAQUE=set()


def add(name, im, size, group='sprites', opaque=False):
    assert name not in ART
    assert (im.w,im.h)==size,(name,size)
    ART[name]=im; GROUP[name]=group; EXPECTED[name]=size
    if opaque: OPAQUE.add(name)
    return im


def label(im, text, x, y, color='ink'):
    for i,ch in enumerate(text.upper()):
        for yy,row in enumerate(FONT[ch]):
            for xx,pixel in enumerate(row):
                if pixel=='1': im.put(x+i*6+xx,y+yy,color)


def fonts():
    small=Image(len(SMALL)*6,8)
    for i,ch in enumerate(SMALL):
        pts=[(x,y) for y,row in enumerate(FONT[ch]) for x,v in enumerate(row) if v=='1']
        for x,y in pts:
            small.put(i*6+x+1,y,'ink'); small.put(i*6+x,y+1,'ink')
        for x,y in pts: small.put(i*6+x,y,'ivory')
    add('font_small',small,(len(SMALL)*6,8))
    big=Image(len(BIG)*10,14)
    # Outline and fill are kept inside each ten-pixel cell. The broad stems
    # and clipped corners are constructed on a 7x11 interior grid.
    for i,ch in enumerate(BIG):
        mask=Image(10,14)
        for y in range(11):
            for x in range(7):
                if FONT[ch][y*7//11][x*5//7]=='1': mask.put(x+1,y+1,'gold')
        for y in range(14):
            for x in range(10):
                if mask.get(x,y)[3]:
                    for dx,dy in ((-1,0),(1,0),(0,-1),(0,1)): big.put(i*10+x+dx,y+dy,'ink')
        for y in range(14):
            for x in range(10):
                if mask.get(x,y)[3]:
                    c='white' if not mask.get(x,y-1)[3] else 'gold_d' if not mask.get(x,y+1)[3] else 'gold'
                    big.put(i*10+x,y,c)
    add('font_big',big,(len(BIG)*10,14))


def game_text(im, text, x, y, big=False):
    alphabet=BIG if big else SMALL
    cw,ch=(10,14) if big else (6,8)
    atlas=ART['font_big' if big else 'font_small']
    for i,c in enumerate(text):
        if c!=' ' or not big: im.blit(atlas.crop(alphabet.index(c)*cw,0,cw,ch),x+i*cw,y)


def plate(color):
    im=Image(18,8)
    edge='gold_d' if color=='black' else color+'_d'
    base='slate_d' if color=='black' else color
    light='gold' if color=='black' else color+'_l'
    im.line(5,7,12,7,'ink')
    oval(im,0,0,18,7,base,'ink')
    im.line(3,5,14,5,edge); im.line(5,6,12,6,base)
    im.line(4,1,13,1,light); im.put(2,2,light); im.put(15,2,edge)
    im.oval(3,1,12,4,'cream_d'); im.oval(3,1,11,3,'ivory')
    im.line(5,1,11,1,'white')
    return im


def food(kind, state):
    im=Image(14,10)
    # Fresh pieces are individually constructed; fatigue remaps only material
    # ramps, then lowers the exposed topping edge by exactly one native row.
    if kind in ('kappa','uramaki'):
        for x,y in ((0,2),(6,1)):
            oval(im,x,y,8,8,'nori' if kind=='kappa' else 'cream_d','nori_d' if kind=='kappa' else 'wood_d')
            im.line(x+2,y+6,x+5,y+6,'nori_l' if kind=='kappa' else 'cream')
            oval(im,x,y,8,6,'ivory','nori_d' if kind=='kappa' else 'cream_d')
            im.oval(x+2,y+1,4,3,'green_d' if kind=='kappa' else 'orange_d')
            im.rect(x+3,y+1,2,2,'green_l' if kind=='kappa' else 'orange')
            im.put(x+3,y+1,'white' if kind=='kappa' else 'orange_l')
            if kind=='uramaki':
                im.put(x+4,y+3,'green'); im.put(x+5,y+2,'green_l')
                for dx,dy in ((1,2),(6,3),(2,5),(5,5)): im.put(x+dx,y+dy,'gold_d')
    elif kind=='ikura':
        oval(im,1,2,12,8,'nori','nori_d')
        im.line(3,7,10,7,'nori_l'); im.put(2,5,'nori_l')
        im.oval(2,1,10,5,'ivory'); im.oval(2,1,10,4,'orange_d')
        for x,y in ((3,1),(6,0),(9,1),(2,3),(5,3),(8,3),(11,3)):
            im.rect(x,y,2,2,'orange'); im.put(x,y,'orange_l'); im.put(x+1,y+1,'coral_d')
        im.put(6,0,'white'); im.put(3,2,'gold_l')
    else:
        poly(im,[(1,5),(3,3),(10,3),(12,5),(12,8),(10,9),(3,9),(1,7)],'cream','cream_d')
        im.rect(3,5,7,3,'ivory')
        for x,y in ((2,6),(4,8),(7,7),(9,8),(11,6)): im.put(x,y,'white')
        if kind=='salmon':
            poly(im,[(0,3),(3,1),(10,1),(13,3),(12,6),(8,6),(4,5),(1,6)],'coral','coral_d')
            im.line(2,2,10,2,'coral_l')
            for x in (3,6,9): im.line(x,2,x+2,5,'ivory')
            im.put(2,3,'white')
        elif kind=='tuna':
            poly(im,[(0,3),(3,1),(10,1),(13,3),(12,6),(7,6),(1,5)],'red','red_d')
            im.line(3,2,9,2,'coral'); im.line(4,3,7,3,'red_l')
            im.put(3,2,'white'); im.line(10,3,11,4,'coral_d')
        elif kind=='tamago':
            poly(im,[(1,2),(10,1),(13,3),(12,6),(3,6),(0,4)],'gold','gold_d')
            im.line(2,2,9,2,'gold_l'); im.line(3,5,11,5,'orange_l')
            im.rect(6,2,3,6,'nori_d'); im.rect(6,2,1,5,'nori_l'); im.put(3,2,'white')
        elif kind=='ebi':
            poly(im,[(1,3),(3,1),(7,1),(10,3),(10,6),(3,6),(0,5)],'coral','orange_d')
            for x in (2,5,8):
                im.line(x,2,x+2,4,'ivory'); im.put(x+1,5,'coral_l')
            poly(im,[(9,4),(11,1),(13,0),(13,3),(12,4),(13,6),(11,6)],'red','red_d')
            im.put(12,1,'red_l'); im.put(2,2,'white')
        elif kind=='unagi':
            poly(im,[(0,3),(3,1),(10,1),(13,3),(12,6),(8,5),(3,6),(0,5)],'walnut_l','walnut_d')
            im.line(2,2,10,2,'orange_l')
            for x in (2,4,9,11): im.line(x,3,x,4,'walnut_d')
            im.rect(6,2,2,6,'nori_d'); im.line(6,2,6,6,'nori'); im.put(3,2,'white')
    if state:
        tired={'white':'cream','ivory':'cream','coral_l':'skin','coral':'skin_d',
               'red_l':'skin_d','red':'red_d','gold_l':'wood_l','gold':'wood',
               'orange_l':'wood','orange':'wood_d','green_l':'nori_l',
               'green':'nori','nori_l':'nori','blue_l':'grey'}
        stale={k:'stale' for k in ('coral','red','gold','orange','skin','skin_d','green','wood')}
        stale.update({k:'stale_l' for k in ('white','ivory','cream','coral_l','red_l','gold_l','orange_l','green_l')})
        stale.update({k:'stale_d' for k in ('coral_d','red_d','gold_d','orange_d','wood_d','cream_d','walnut_l')})
        mapping={P[a]:P[b] for a,b in (tired if state==1 else stale).items()}
        im.p=[mapping.get(c,c) for c in im.p]
        # Just the exposed leading/trailing edge wilts; rice keeps its anchor.
        for x in (1,2,11,12):
            ys=[y for y in range(6) if im.get(x,y)[3]]
            if ys:
                y=max(ys); im.put(x,y+1,im.get(x,y))
        if state==2:
            for x,y in ((3,5),(4,5),(9,6)): im.put(x,y,'stale_d')
    return im


def foods():
    for c in PLATES:
        add('plate_'+c,plate(c),(18,8))
        im=Image(14,3)
        im.line(0,0,13,0,'gold' if c=='black' else c+'_l')
        im.line(1,1,12,1,'slate_d' if c=='black' else c)
        im.line(3,2,10,2,'ink')
        add('plate_side_'+c,im,(14,3))
    for k in KINDS:
        for s in range(3): add(f'sushi_{k}_{s}',food(k,s),(14,10))


def eyes(im, x, y, separation=6, closed=False):
    for xx in (x,x+separation):
        if closed:
            im.line(xx,y+1,xx+2,y+1,'ink')
        else:
            im.rect(xx,y,2,2,'ink'); im.put(xx,y,'white')


def mouth(im, x, y, mood='smile'):
    if mood=='open':
        im.rect(x,y,3,3,'red_d'); im.put(x+1,y+2,'pink')
    elif mood=='grumpy':
        im.line(x,y+1,x+3,y+1,'skin_d'); im.put(x+1,y,'red_d'); im.put(x+2,y,'red_d')
    elif mood=='big':
        im.line(x-1,y,x+4,y,'red_d'); im.line(x,y+1,x+3,y+1,'red_d')
        im.line(x+1,y+2,x+2,y+2,'pink')
    else:
        im.put(x-1,y,'skin_d'); im.line(x,y+1,x+2,y+1,'red_d'); im.put(x+3,y,'skin_d')


def hand(im, x, y, deep=False, fingers=False):
    skin,light,dark=('deep','deep_l','deep_d') if deep else ('skin','skin_l','skin_d')
    box(im,x,y,7,5,skin,dark,2)
    im.line(x+2,y+1,x+4,y+1,light)
    im.put(x+1,y+2,light); im.put(x+5,y+3,dark)
    if fingers:
        im.put(x+3,y+3,dark); im.put(x+5,y+3,dark)


def cook_head(k, closed=False, mood='smile', nod=0):
    im=Image(26,25)
    dark,skin,light=('deep_d','deep','deep_l') if k==1 else ('skin_d','skin','skin_l')
    if k==1:
        poly(im,[(19,8),(23,8),(25,13),(23,18),(21,19),(21,13)],'walnut','walnut_d')
    oval(im,3,10+nod,20,9,skin,dark)
    poly(im,[(6,6+nod),(18,6+nod),(21,10+nod),(21,17+nod),(17,22+nod),
             (10,22+nod),(5,18+nod),(5,10+nod)],skin,dark)
    im.rect(7,10+nod,11,6,light)
    im.oval(8,13+nod,11,7,skin)
    im.put(6,13+nod,light); im.put(21,13+nod,light)
    if k==0:
        poly(im,[(5,10+nod),(5,6+nod),(9,3+nod),(17,3+nod),(21,7+nod),(21,11+nod),
                 (18,9+nod),(17,7+nod),(9,7+nod),(7,11+nod)],'grey','grey_d')
        im.line(9,4+nod,16,4+nod,'grey_l')
        im.rect(4,7+nod,18,3,'cream_d'); im.rect(4,7+nod,17,2,'ivory')
        poly(im,[(21,8+nod),(25,6+nod),(24,10+nod),(22,10+nod),(24,13+nod),(21,12+nod)],'ivory','grey_d')
    elif k==1:
        poly(im,[(5,11+nod),(4,6+nod),(8,2+nod),(16,1+nod),(21,5+nod),(22,10+nod),
                 (18,8+nod),(16,7+nod),(10,9+nod)],'red','red_d')
        im.line(8,4+nod,16,3+nod,'red_l'); im.line(6,7+nod,11,6+nod,'coral')
        im.rect(6,10+nod,2,3,'walnut_d'); im.put(19,10+nod,'walnut_d')
    else:
        oval(im,4,0,19,12,'ivory','slate_d')
        im.oval(6,1,13,7,'white')
        im.rect(6,8,15,3,'cream_d'); im.rect(6,8,14,2,'ivory')
        im.line(18,3,19,6,'cream'); im.put(7,11,'walnut')
    eyes(im,8,12+nod,8,closed)
    im.put(12,16+nod,dark); im.put(13,15+nod,light)
    if k==0:
        im.line(9,17+nod,12,17+nod,'grey_d'); im.line(14,17+nod,17,17+nod,'grey_d')
        im.line(9,17+nod,11,17+nod,'grey_l'); im.line(14,17+nod,16,17+nod,'grey_l')
        im.put(8,16+nod,'skin_d'); im.put(18,16+nod,'skin_d')
    else:
        im.line(7,16+nod,9,16+nod,'coral_d' if k==1 else 'red_l')
        im.line(17,16+nod,19,16+nod,'coral_d' if k==1 else 'red_l')
    mouth(im,12,19+nod,mood)
    return im


def cook(k, frame):
    im=Image(40,48)
    apron=('blue_d','indigo','green_d')[k]
    head_y=(2,3,0)[k]
    closed=frame in ('idle_1','cheer')
    # The fixed jacket ends at row 35. Below it, only articulated forearms,
    # hands and their tools can cover the kitchen's immutable cutting board.
    poly(im,[(7,26),(13,22),(26,22),(32,26),(35,35),(4,35)],'cream','slate_d')
    poly(im,[(8,26),(13,24),(26,24),(31,27),(32,34),(6,34)],'ivory','cream_d')
    im.line(8,27,7,31,'white'); im.line(27,26,30,29,'white')
    im.rect(13,28,14,8,apron)
    im.line(14,26,14,34,apron); im.line(25,26,25,34,apron)
    im.line(15,29,24,29,'indigo_l' if k==1 else 'blue' if k==0 else 'green')
    im.line(19,31,22,31,'cream'); im.put(20,33,'cream_d')
    im.poly([(14,23),(19,26),(17,29),(12,25)],'white')
    im.poly([(24,23),(20,26),(22,29),(27,25)],'white')
    im.blit(cook_head(k,closed,'big' if frame in ('cheer','place_1') else 'open' if frame=='oops' else 'smile',
                      1 if frame=='idle_1' else 0),7,head_y)

    def arm(side, hx, hy):
        sx=7 if side==0 else 30
        poly(im,[(sx-3,30),(sx+3,30),(hx+5,hy+2),(hx+1,hy+4)],'ivory','slate_d')
        im.line(sx-1,31,hx+2,hy+1,'white')
        hand(im,hx,hy,k==1,True)

    if frame.startswith('idle'):
        arm(0,6,36); arm(1,27,36)
    elif frame.startswith('slice'):
        im.blit(food('salmon',0),10,38)
        arm(0,9,38)
        if frame=='slice_0':
            arm(1,28,31)
            poly(im,[(24,24),(26,23),(30,35),(28,36)],'metal','slate_d')
            im.line(25,25,28,33,'white'); im.line(29,35,30,38,'walnut_d')
        else:
            arm(1,27,39)
            poly(im,[(17,41),(29,39),(30,42),(19,44),(16,43)],'metal','slate_d')
            im.line(18,41,27,40,'white'); im.line(29,40,33,39,'walnut_d')
            im.line(17,41,17,44,'coral_l'); im.put(15,44,'coral')
    elif frame=='rice_0':
        # Anatomical right reaches towards the tub, at screen left; the
        # other hand cups rice. Fingers stay inside the 40-pixel canvas.
        arm(0,2,40); arm(1,23,36)
        oval(im,23,35,8,6,'ivory','cream_d'); im.line(25,36,28,36,'white')
        im.put(25,38,'cream'); im.put(28,39,'cream')
    elif frame=='rice_1':
        oval(im,16,39,10,6,'ivory','cream_d')
        arm(0,12,39); arm(1,23,39)
        im.rect(18,39,6,2,'skin_d' if k!=1 else 'deep_d')
        im.line(18,39,22,39,'skin_l' if k!=1 else 'deep_l')
        im.line(18,41,22,41,'skin_l' if k!=1 else 'deep_l')
        im.put(20,43,'white')
    elif frame.startswith('roll'):
        y=38 if frame=='roll_0' else 40
        box(im,10,y,20,7 if frame=='roll_0' else 5,'green','green_d',2)
        for x in range(12,29,3): im.line(x,y+1,x,y+4,'green_l')
        im.line(12,y+5,27,y+5,'wood_l')
        if frame=='roll_0':
            im.line(14,y+1,25,y+1,'nori_d'); im.line(15,y+2,24,y+2,'ivory')
        else: im.put(28,y+2,'nori_d')
        arm(0,7,38); arm(1,27,38)
    elif frame.startswith('place'):
        y=38 if frame=='place_0' else 40
        arm(0,8,y+1); arm(1,26,y+1)
        im.blit(plate('green'),12,y); im.blit(food('salmon',0),14,y-4)
        im.put(12,y+4,'skin_l' if k!=1 else 'deep_l'); im.put(29,y+4,'skin' if k!=1 else 'deep')
    elif frame=='cheer':
        arm(0,3,18); arm(1,27,36)
        im.line(5,18,7,18,'skin_l' if k!=1 else 'deep_l')
    else:
        arm(0,2,24); arm(1,32,24)
        poly(im,[(32,12),(30,16),(30,18),(32,19),(34,17)],'blue_l','blue_d')
        im.put(31,16,'white')
    return im


def cooks():
    for k in range(3):
        for frame in COOK_FRAMES: add(f'cook{k}_{frame}',cook(k,frame),(40,48),'cooks')
        # Portraits are redrawn on a native 20x20 grid, never downsampled.
        im=Image(20,20)
        poly(im,[(2,19),(3,16),(8,13),(13,13),(17,16),(18,19)],'ivory','slate_d')
        im.rect(8,16,5,4,('blue_d','indigo','green_d')[k])
        deep=k==1
        sk,sh,hi=('deep','deep_d','deep_l') if deep else ('skin','skin_d','skin_l')
        oval(im,3,3,14,14,sk,sh); im.oval(5,4,9,8,hi)
        if k==0:
            im.oval(3,1,14,8,'grey_d'); im.oval(4,1,12,5,'grey')
            im.rect(3,5,14,2,'ivory'); im.line(17,5,19,7,'ivory')
            im.line(7,12,9,12,'grey_l'); im.line(11,12,13,12,'grey_l')
        elif k==1:
            poly(im,[(3,8),(3,3),(7,0),(13,0),(17,4),(17,7),(12,5),(7,7)],'red','red_d')
            im.line(6,2,12,1,'red_l'); im.rect(17,6,2,7,'walnut_d')
        else:
            oval(im,3,0,15,8,'ivory','slate_d'); im.oval(5,1,9,4,'white')
            im.rect(4,6,12,2,'cream')
        eyes(im,6,8,6)
        im.put(10,11,sh); im.put(5,12,'coral_d' if deep else 'red_l'); im.put(14,12,'coral_d' if deep else 'red_l')
        mouth(im,9,13)
        add(f'cook{k}_face',im,(20,20),'cooks')


def kid_customer(frame):
    im=Image(24,32)
    # A short striped tee and small hands leave room for a broad, round face.
    poly(im,[(4,31),(4,28),(7,25),(16,25),(19,28),(19,31)],'blue','blue_d')
    im.line(7,27,16,27,'ivory'); im.line(6,30,17,30,'ivory')
    im.rect(10,25,4,2,'skin'); im.line(10,27,13,27,'skin_d')
    head=Image(24,32)
    # The rear brim is behind the head, beside the cap's adjustment strap.
    poly(head,[(17,13),(20,14),(22,15),(22,16),(17,16)],'red','red_d')
    oval(head,5,10,14,8,'red','red_d')
    head.line(8,11,13,11,'red_l')
    for x in (3,17):
        oval(head,x,19,4,5,'skin','skin_d'); head.put(x+1,20,'skin_l')
    oval(head,5,14,14,13,'skin','skin_d')
    head.oval(6,15,10,8,'skin_l'); head.oval(7,19,10,7,'skin')
    head.line(6,15,8,15,'walnut'); head.line(16,15,17,16,'walnut')
    head.line(7,14,16,14,'red_d')
    head.rect(10,13,4,2,'walnut_d'); head.line(10,14,13,14,'red_l')
    head.put(13,14,'gold_l')
    ey=17 if frame=='want' else 18
    eyes(head,7,ey,7,frame in ('sit_1','eat_1','happy'))
    head.put(11,21,'skin_d'); head.put(12,20,'skin_l')
    if frame in ('angry','eat_1'):
        for x in (6,16):
            head.line(x,22,x+1,22,'red_l' if frame=='angry' else 'skin_d')
        if frame=='eat_1':
            head.put(5,22,'skin'); head.put(18,22,'skin')
        else:
            head.line(7,17,9,17,'walnut'); head.line(14,17,16,17,'walnut')
    mouth(head,10,23,'open' if frame=='want' else 'big' if frame=='happy'
          else 'grumpy' if frame=='angry' else 'smile')
    if frame=='eat_1': head.line(10,24,13,24,'skin_d')
    im.blit(head,0,1 if frame=='want' else 0)

    def small_hand(x,y):
        box(im,x,y,5,4,'skin','skin_d',1)
        im.line(x+1,y+1,x+2,y+1,'skin_l')

    if frame=='happy':
        for x in (2,17):
            box(im,x,25,5,6,'blue','blue_d',1)
            im.line(x+1,27,x+3,27,'ivory')
            small_hand(x,22)
    elif frame=='angry':
        poly(im,[(4,28),(7,27),(18,29),(18,31),(6,31)],'blue','blue_d')
        small_hand(11,28); small_hand(6,29)
    elif frame=='eat_0':
        small_hand(4,28); small_hand(17,26)
        im.line(18,26,13,23,'walnut_d'); im.line(19,27,14,24,'wood_l')
        im.rect(12,23,4,3,'cream'); im.line(12,23,15,23,'coral')
        im.put(13,23,'coral_l')
    else:
        small_hand(4,28); small_hand(15,28)
        im.line(18,29,20,25,'walnut_d'); im.line(20,30,22,26,'wood_l')
    im.line(5,31,18,31,'blue_d')
    return im


def customer(name, frame):
    if name=='kid': return kid_customer(frame)
    im=Image(24,32)
    deep=name in ('artist','builder')
    sk,sh,hi=('deep','deep_d','deep_l') if deep else ('skin','skin_d','skin_l')
    coat={'office':'indigo','granny':'lilac','student':'gold','tourist':'blue',
          'artist':'blue','builder':'orange','chef_fan':'red_d'}[name]
    edge={'office':'indigo_d','granny':'lilac_d','student':'gold_d','tourist':'blue_d',
          'artist':'blue_d','builder':'orange_d','chef_fan':'walnut_d'}[name]
    top=1 if name=='granny' else 3
    fy=top+5
    # Hair behind the shoulders, a bun, and a hat brim give each patron a
    # recognisable contour before any facial or clothing detail is added.
    if name=='chef_fan':
        box(im,4,2,16,26,'walnut_d','ink',5)
        im.line(5,8,5,24,'walnut'); im.line(18,8,18,25,'walnut')
    if name=='granny': oval(im,9,0,9,7,'grey','grey_d')
    body_y=21
    broad=name=='builder'
    poly(im,[(2 if broad else 4,31),(2 if broad else 3,body_y+3),(8,body_y),
             (16,body_y),(21 if broad else 20,body_y+3),(22 if broad else 21,31)],coat,edge)
    im.line(5,body_y+4,5,29,coat+'_l' if coat in ('lilac','blue','gold','red','orange') else 'indigo_l')
    im.rect(9,body_y-2,6,4,sh); im.rect(10,body_y-2,4,3,sk)
    oval(im,3,fy+4,18,7,sk,sh)
    oval(im,5,fy-2,14,15,sk,sh)
    im.oval(6,fy-1,10,10,hi)
    im.oval(7,fy+3,11,8,sk)
    im.put(4,fy+6,hi); im.put(19,fy+6,hi)
    if name=='office':
        poly(im,[(4,10),(4,5),(7,2),(16,2),(19,5),(19,10),(17,8),(16,5),(10,7),(6,7),(6,10)],'slate_d','ink')
        im.line(7,4,14,3,'slate'); im.line(9,5,16,4,'slate')
        im.poly([(7,22),(11,24),(8,27),(6,23)],'ivory')
        im.poly([(16,22),(12,24),(15,27),(18,23)],'cream')
        im.line(11,25,13,30,'red'); im.put(11,24,'red_l')
        im.put(18,27,'cream')
    elif name=='granny':
        for x,y,w,h in ((4,4,7,8),(8,3,9,5),(14,5,6,7)):
            oval(im,x,y,w,h,'grey_l','grey_d')
        im.line(10,2,14,2,'grey_l')
        im.line(8,23,10,26,'lilac_l'); im.line(16,23,13,26,'lilac_l')
        im.line(12,26,12,30,'lilac_d'); im.put(13,27,'gold_l'); im.put(13,30,'gold_l')
    elif name=='student':
        poly(im,[(3,11),(3,7),(5,6),(4,3),(8,4),(10,1),(12,3),(16,2),(16,4),(20,5),
                 (19,12),(17,10),(16,7),(12,9),(10,7),(7,9),(5,8)],'walnut','walnut_d')
        im.line(7,5,10,4,'walnut_l'); im.line(13,5,16,4,'walnut_l')
        im.line(7,23,9,26,'gold_l'); im.line(17,23,15,26,'gold_l')
        im.line(9,25,9,29,'ivory'); im.line(15,25,15,29,'ivory')
        im.line(6,22,9,25,'slate_d'); im.line(9,25,15,25,'slate_d'); im.line(15,25,18,22,'slate_d')
        box(im,5,21,4,5,'indigo_l','indigo_d',1); box(im,15,21,4,5,'indigo_l','indigo_d',1)
    elif name=='tourist':
        im.rect(5,9,2,7,'walnut'); im.rect(17,9,2,7,'walnut')
        oval(im,6,1,13,9,'wood','gold_d'); im.line(9,2,15,2,'wood_l')
        im.line(7,7,17,7,'red_d')
        oval(im,0,7,24,5,'wood_l','gold_d'); im.line(3,8,20,8,'gold_l')
        im.line(8,23,10,28,'walnut_d'); im.line(16,23,14,28,'walnut_d')
        box(im,8,26,9,6,'slate','ink',1); oval(im,10,27,5,4,'blue_l','slate_d'); im.put(11,27,'white')
    elif name=='artist':
        poly(im,[(3,19),(3,7),(6,3),(15,2),(19,6),(20,19),(17,20),(16,8),(12,7),(7,10),(7,19)],'green','green_d')
        im.line(6,6,9,4,'green_l'); im.line(17,8,18,16,'nori_l')
        im.put(18,19,'gold_l'); im.put(18,20,'gold')
        im.poly([(8,22),(11,24),(8,27),(6,24)],'blue_l')
        im.poly([(16,22),(12,24),(15,27),(18,24)],'blue_d')
        for x,y,c in ((6,27,'gold'),(18,25,'coral'),(16,29,'ivory'),(8,29,'green_l')): im.put(x,y,c)
    elif name=='builder':
        poly(im,[(5,10),(4,7),(6,4),(16,4),(19,7),(19,11),(16,8),(8,8)],'walnut','walnut_d')
        im.line(8,5,14,5,'walnut_l')
        im.line(7,23,7,30,'gold_l'); im.line(17,23,17,30,'gold_l')
        im.line(4,28,20,28,'ivory')
        im.poly([(7,21),(9,23),(10,27),(7,27),(6,22)],'cream')
        im.poly([(17,21),(15,23),(14,28),(17,28),(18,22)],'ivory')
        im.line(8,25,8,26,'cream_d')
    else:
        poly(im,[(5,13),(5,5),(9,2),(16,3),(19,7),(18,13),(16,9),(13,6),(9,9),(7,13)],'walnut_d','ink')
        im.line(7,6,10,4,'walnut'); im.line(15,5,17,7,'walnut')
        im.put(5,20,'ivory'); im.put(18,20,'ivory'); im.put(5,19,'white'); im.put(18,19,'white')
        im.line(9,23,14,23,'skin'); im.put(11,24,'ivory'); im.put(13,24,'ivory')
    ey=fy+4
    closed=frame in ('sit_1','eat_1','happy')
    eyes(im,7,ey-1 if frame=='want' else ey,7,closed)
    im.put(11,ey+3,sh); im.put(12,ey+2,hi)
    blush='coral_d' if deep else 'red_l' if frame=='angry' or name=='tourist' else 'skin_d'
    im.line(6,ey+4,8,ey+4,blush); im.line(16,ey+4,18,ey+4,blush)
    if name=='granny':
        for x in (5,12):
            # Wire rims leave the same two-pixel eyes visible inside.
            im.line(x+1,ey-1,x+4,ey-1,'grey_d'); im.line(x,ey,x,ey+2,'grey_d')
            im.line(x+5,ey,x+5,ey+2,'grey_d'); im.line(x+1,ey+3,x+4,ey+3,'grey_d')
        im.put(11,ey,'grey_d')
    if name=='builder':
        im.line(7,ey+5,8,ey+7,'walnut_d'); im.line(8,ey+7,15,ey+7,'walnut_d')
        im.line(15,ey+7,17,ey+5,'walnut_d'); im.line(9,ey+6,15,ey+6,'walnut')
    my=ey+5
    mouth(im,10,my,'open' if frame=='want' else 'big' if frame=='happy' else 'grumpy' if frame=='angry' else 'smile')
    if frame=='eat_1':
        im.put(5,ey+3,sk); im.put(19,ey+3,sk)
        im.line(10,my+1,13,my+1,sh)
    if frame=='want':
        # The head dips towards the belt while the pupils glance up. Keep
        # the waist and the resting forearms fixed at the shared anchor.
        h=22
        leaning=im.crop(0,0,24,h)
        im.rect(0,0,24,h,CLEAR)
        im.blit(leaning,0,1)
    # Distinct gestures change only the arms/face. Shirt, silhouette and
    # waist anchor stay in place in every animation frame.
    if frame=='happy':
        for x in (1,17):
            box(im,x,20,6,10,coat,edge,2); hand(im,x,17,deep)
    elif frame=='angry':
        poly(im,[(3,27),(6,26),(19,29),(19,31),(5,31),(3,30)],coat,edge)
        hand(im,12,27,deep); hand(im,5,28,deep)
    elif frame=='eat_0':
        hand(im,3,27,deep); hand(im,16,22,deep)
        im.line(17,23,12,my+1,'walnut_d'); im.line(18,24,12,my+2,'wood_l')
        im.rect(10,my,4,3,'cream'); im.line(10,my,13,my,'coral'); im.put(11,my,'coral_l')
    else:
        hand(im,3,27,deep); hand(im,15,27,deep)
        im.line(17,28,20,24,'walnut_d'); im.line(19,29,22,25,'wood_l')
        if frame=='want':
            im.put(8,ey-1,hi); im.put(15,ey-1,hi)
    # Both wrists meet the same bottom baseline, the stool remains hidden.
    im.line(5,31,18,31,edge)
    return im


def customers():
    for name in CUSTOMERS:
        for frame in CUST_FRAMES:
            add(f'cust_{name}_{frame}',customer(name,frame),(24,32),'customers')


def bubble(selected=False):
    im=Image(22,20)
    box(im,0,0,22,17,'ivory','ink',4)
    poly(im,[(8,15),(13,15),(10,19)],'ivory','ink')
    im.rect(9,14,4,2,'ivory'); im.line(9,16,11,16,'ivory'); im.put(10,17,'ivory')
    if selected:
        mask=Image(22,20)
        mask.round(1,1,20,15,3,'select'); mask.round(2,2,18,13,2,CLEAR)
        im.blit(mask,0,0)
    im.line(5,1,16,1,'select' if selected else 'white')
    return im


def selection(w,h):
    im=Image(w,h)
    im.round(0,0,w,h,5,'select')
    im.round(2,2,w-4,h-4,3,CLEAR)
    return im


def small_sprites():
    add('bubble',bubble(),(22,20)); add('bubble_sel',bubble(True),(22,20))
    add('select_cook',selection(44,52),(44,52)); add('select_seat',selection(28,36),(28,36))
    im=Image(16,16)
    # The leading dark tip is exactly (1,1), with no pixels above or left.
    im.line(1,1,12,13,'walnut_d'); im.line(3,2,14,12,'walnut_d')
    im.line(4,5,11,12,'wood_l'); im.line(6,5,13,11,'wood')
    poly(im,[(10,9),(12,8),(14,10),(15,13),(13,15),(10,14),(8,12),(8,10)],'skin','skin_d')
    im.line(10,10,12,12,'skin_l'); im.put(13,13,'skin_d')
    add('cursor',im,(16,16))
    for f in range(2):
        im=Image(7,5)
        for x in (0,4): oval(im,x,0 if f==0 else 2,3,3,'metal','slate_d')
        im.rect(2,2,3,2,'ink'); im.put(3,2,'slate'); im.put(1,4,'ink'); im.put(5,4,'ink')
        add(f'fly_{f}',im,(7,5))
        im=Image(10,8)
        for x in (2,7):
            pts=[(x,7),(x-1,6),(x-1,5),(x+1,3),(x+1,2),(x,1),(x,0)]
            if f: pts=[(2*x-xx,yy) for xx,yy in pts]
            for a,b in zip(pts,pts[1:]): im.line(*a,*b,'nori_l')
            im.put(x,1,'stale_l')
        add(f'stink_{f}',im,(10,8))
        im=Image(12,10)
        for x,y,w,h in ((0,3-f,6,5),(4,1+f,7,6),(3,4,8,5)):
            oval(im,x,y,w,h,'ivory','metal')
        im.rect(4,4,5,3,'white'); im.line(3,9,6,8,'metal')
        add(f'steam_{f}',im,(12,10))
        im=Image(9,9)
        pts=[(0,2),(2,0),(4,2),(6,0),(8,2),(8,4),(4,8),(0,4)]
        if f: pts=[(2+x//2,2+y//2) for x,y in pts]
        poly(im,pts,'pink','pink_d'); im.put(2 if not f else 3,2 if not f else 3,'pink_l')
        add(f'heart_{f}',im,(9,9))
        im=Image(9,9)
        if f:
            poly(im,[(4,1),(5,3),(7,4),(5,5),(4,7),(3,5),(1,4),(3,3)],'gold_l','gold')
            im.put(4,4,'white'); im.put(0,0,'gold'); im.put(8,8,'gold')
        else:
            poly(im,[(4,0),(5,3),(8,4),(5,5),(4,8),(3,5),(0,4),(3,3)],'gold_l','gold')
            im.line(4,2,4,5,'white')
        add(f'star_{f}',im,(9,9))
        im=Image(12,12)
        dx=f
        im.line(5,0,5,2,'walnut_d'); im.put(5,0,'gold_l')
        poly(im,[(4+dx,2),(7+dx,2),(9+dx,5),(9,7),(11,9),(1,9),(3,6),(3+dx,4)],'gold','gold_d')
        im.line(5+dx,3,4+dx,6,'gold_l'); im.line(3,8,9,8,'gold_l')
        im.line(2,10,10,10,'walnut'); im.put(6-f,11,'gold')
        add(f'bell_{f}',im,(12,12))
    for f in range(3):
        im=Image(16,16)
        parts=(((5,6,7,7),(3,8,6,5),(8,4,5,7)),
               ((1,6,8,7),(5,2,8,9),(8,7,7,7),(3,9,8,6)),
               ((0,5,4,4),(5,0,5,4),(12,6,4,5),(7,12,4,4)))
        for x,y,w,h in parts[f]:
            oval(im,x,y,w,h,'cream','cream_d'); im.put(x+w//2,y+1,'ivory')
        if f==1: im.rect(5,7,7,5,'ivory')
        add(f'poof_{f}',im,(16,16))
    im=Image(8,8)
    oval(im,0,0,8,8,'gold','gold_d'); im.line(2,1,5,1,'gold_l'); im.put(1,2,'white')
    im.line(3,2,4,3,'gold_d'); im.put(5,2,'gold_d'); im.line(4,3,4,6,'gold_d')
    im.line(2,4,5,4,'gold_d'); im.line(2,5,5,5,'gold_d')
    add('coin',im,(8,8))


def belt_tile(vertical=False, f=0):
    w,h=(12,8) if vertical else (8,12)
    im=Image(w,h,'slate')
    for y in range(h):
        for x in range(w):
            t=y if vertical else x
            if (t-f)%4==0: im.put(x,y,'slate_d')
    return im


def lantern(im, cx, y, large=False):
    w,h=(18,25) if large else (10,14)
    x=cx-w//2
    im.line(cx,y-5,cx,y,'walnut_d')
    oval(im,x,y,w,h,'red','red_d')
    im.oval(x+2,y+1,w-5,h-3,'coral')
    im.oval(cx-2,y+2,4,h-5,'red_l')
    for yy in range(y+3,y+h-2,4 if large else 3):
        im.line(x+1,yy,x+w-2,yy,'red')
        im.line(cx-2,yy,cx+1,yy,'coral_l')
    im.line(x+3,y,x+w-4,y,'walnut_d'); im.line(x+3,y+h-1,x+w-4,y+h-1,'walnut_d')
    im.line(cx-1,y+h,cx+1,y+h,'gold_d')


def curtain(im, x, y, w, h):
    im.rect(x,y,w,h,'indigo_d')
    for a,b in ((x+2,w//2-3),(x+w//2+1,w//2-3)):
        poly(im,[(a,y+2),(a+b-1,y+2),(a+b-1,y+h-5),(a+b-3,y+h-1),(a,y+h-3)],'indigo','indigo_d')
        im.line(a+1,y+3,a+1,y+h-7,'indigo_l')
        im.line(a+b-2,y+5,a+b-2,y+h-6,'indigo_d')
        # Repeated shallow concentric wave arcs, without any letterforms.
        yy=y+h-18
        for xx in range(a+2,a+b-1,6):
            im.line(xx-1,yy,xx,yy+2,'cream'); im.line(xx,yy+2,xx+2,yy+2,'cream')
            im.line(xx+2,yy+2,xx+3,yy,'cream')
            im.put(xx+1,yy+5,'cream')
    im.rect(x,y,w,3,'walnut'); im.line(x,y,x+w-1,y,'wood_d')


def kitchen_props(im):
    # All three appliances are outside the reserved head rectangles.
    box(im,29,84,18,9,'cream','slate_d',3)
    im.line(32,85,43,85,'white'); im.rect(30,87,16,2,'metal')
    im.rect(35,89,6,3,'slate_d'); im.put(36,90,'red_l')
    im.line(34,84,41,84,'slate_d'); im.line(36,84,39,84,'metal')
    oval(im,114,85,15,8,'metal','slate_d')
    im.line(117,86,123,86,'white'); im.line(119,84,123,84,'slate_d')
    im.line(116,87,111,84,'slate_d'); im.line(112,84,113,88,'metal')
    im.line(127,85,131,85,'slate_d'); im.line(131,85,131,90,'slate_d'); im.line(130,91,127,91,'slate_d')
    for y in (90,87,84):
        im.blit(ART['plate_side_blue'],274,y)


def room():
    im=Image(320,168,'cream')
    im.rect(0,0,320,12,'walnut_d'); im.line(0,1,319,1,'walnut')
    im.line(0,10,319,10,'walnut'); im.line(0,11,319,11,'wood_d')
    for x in (28,64,128,192,256,290):
        im.rect(x,12,2,58,'wood'); im.line(x,12,x,49,'wood_l')
    im.rect(0,50,320,20,'wood')
    im.line(0,49,319,49,'wood_d'); im.line(0,50,319,50,'wood_l')
    for x in range(0,320,32):
        im.line(x,52,x,68,'wood_d'); im.line(x+1,52,x+1,68,'wood_l')
    im.line(0,68,319,68,'wood_d'); im.line(0,69,319,69,'walnut')
    curtain(im,0,0,28,70)
    for x in (32,96,160,224,288): lantern(im,x,8)
    box(im,292,12,28,49,'walnut','walnut_d',1)
    im.rect(294,14,24,45,'wood_l')
    for i,c in enumerate(PLATES):
        # Miniature painted plate samples; the remaining right margin is plain.
        rim='slate_d' if c=='black' else c
        oval(im,295,16+i*8,12,5,rim,'gold_d' if c=='black' else c+'_d')
        im.line(298,17+i*8,303,17+i*8,'ivory')
    # Under the loop, the dining-room planks never intrude into the housing.
    im.rect(0,70,320,98,'walnut_d')
    im.rect(0,154,320,6,'walnut'); im.line(0,154,319,154,'walnut_l')
    for y in (160,164):
        im.line(0,y,319,y,'walnut_l')
        for x in range((y-160)*7,320,48): im.line(x,y,x,y+3,'walnut')
    # A radius-six outside corner and one-pixel rails. The straight lane
    # surfaces below are exact inclusive rectangles from SPEC.md.
    im.round(2,70,316,84,6,'white')
    im.round(3,71,314,82,5,'slate')
    outer=im.crop(0,0,320,168)
    for y in range(71,153):
        for x in range(3,317):
            if outer.get(x,y)==P['slate']:
                t=x if y<=82 or y>=141 else y
                im.put(x,y,'slate_d' if t%4==0 else 'slate')
    im.rect(16,84,288,56,'blue')
    # Continuous highlights follow each rail, including the rounded corners.
    im.line(16,83,303,83,'white'); im.line(16,140,303,140,'white')
    im.line(15,83,15,140,'white'); im.line(304,83,304,140,'white')
    for y in (94,103,111): im.line(16,y,303,y,'blue_d')
    for y in (95,104):
        for x in range(16+(8 if y==104 else 0),304,16):
            im.line(x,y,x,min(y+7,111),'blue_d'); im.line(x+1,y,min(x+14,303),y,'blue_l')
    im.rect(16,84,288,9,'metal')
    im.line(16,84,303,84,'white'); im.line(16,90,303,90,'slate_l')
    im.rect(16,91,288,2,'slate_d')
    for x in (49,132,212,270): im.line(x,85,x,89,'slate_l')
    kitchen_props(im)
    im.rect(16,112,288,24,'wood_l'); im.line(16,112,303,112,'ivory')
    im.line(16,114,303,114,'wood')
    im.rect(16,136,288,4,'wood_d'); im.line(16,136,303,136,'wood')
    im.line(16,139,303,139,'walnut')
    for x in (80,160,240):
        # Exactly 28x9, 12x7, and 4x3 respectively; no decoration is put in
        # the clear transfer strip at y=128..134.
        box(im,x-14,118,28,9,'wood','wood_d',1)
        im.line(x-12,119,x+10,119,'wood_l'); im.line(x-12,125,x+10,125,'gold_d')
        im.line(x-8,121,x-3,121,'wood_l'); im.line(x+3,123,x+8,123,'wood_l')
        oval(im,x-31,119,12,7,'wood','walnut_l')
        im.oval(x-30,119,10,4,'cream'); im.line(x-28,120,x-23,120,'ivory')
        im.put(x-28,123,'gold_d'); im.put(x-22,123,'gold_d')
        im.rect(x+18,121,4,3,'green_d'); im.rect(x+19,121,2,2,'green_l')
        im.put(x+19,121,'ivory')
    add('room',im,(320,168),'pictures',True)
    for f in range(4):
        add(f'belt_h_{f}',belt_tile(False,f),(8,12),opaque=True)
        add(f'belt_v_{f}',belt_tile(True,f),(12,8),opaque=True)


def bar():
    im=Image(320,32,'walnut')
    im.line(0,0,319,0,'wood_l'); im.line(0,1,319,1,'wood_d')
    im.line(0,31,319,31,'walnut_d')
    for x in (2,82,162,242):
        box(im,x,3,76,27,'walnut_d','wood_d',2)
        im.line(x+2,4,x+73,4,'ink')
        if x==2: continue
        oval(im,x+2,5,22,22,'cream','wood_d')
        im.oval(x+3,6,20,19,'ivory'); im.line(x+9,25,x+17,25,'cream_d')
        for xx in (x+27,x+43,x+59):
            im.rect(xx,6,16,16,'walnut_l'); im.rect(xx+1,7,14,14,'wood_d')
            im.line(xx+1,7,xx+14,7,'walnut'); im.line(xx+1,8,xx+1,20,'walnut')
        im.rect(x+27,24,48,2,'ink')
    add('bar',im,(320,32),'pictures',True)


def logo(im):
    # Nine individually placed block letters on an arch. Each is built from
    # its native pixel plan, with a coral extrusion and cream top face.
    for i,ch in enumerate('SUSHIBELT'):
        x=48+i*25
        y=15+(abs(i-4)**2)//2
        pts=set()
        for yy,row in enumerate(FONT[ch]):
            for xx,v in enumerate(row):
                if v=='1':
                    for dy in range(4):
                        for dx in range(4): pts.add((x+xx*4+dx,y+yy*4+dy))
        for xx,yy in sorted(pts):
            for dx,dy in ((-2,0),(2,0),(0,-2),(0,2),(1,3),(2,4),(-1,3)):
                im.put(xx+dx,yy+dy,'walnut_d')
        for xx,yy in sorted(pts): im.put(xx+1,yy+2,'coral_d')
        for xx,yy in sorted(pts):
            # Trim an exposed corner by one pixel for rounded letter ends.
            corner=(xx-1,yy) not in pts and (xx,yy-1) not in pts
            if not corner: im.put(xx,yy,'ivory' if (xx,yy-1) not in pts else 'cream')
        for xx,yy in sorted(pts):
            if (xx,yy-1) not in pts and (xx-1,yy) in pts: im.put(xx,yy,'white')


def title():
    im=Image(320,168,'night')
    # Quiet moonlit street and broad timber storefront, no borrowed signage.
    im.rect(18,8,284,144,'indigo_d')
    im.rect(25,12,270,139,'walnut_d')
    im.rect(30,18,260,129,'walnut')
    im.rect(36,61,248,73,'wood')
    im.rect(39,64,242,67,'wood_l')
    for x in (43,92,218,267):
        im.rect(x,67,10,64,'walnut'); im.line(x,67,x,129,'wood_d')
    # Warm windows: a few calm silhouettes, cutlery and a tiny fish motif.
    for x in (55,222):
        im.rect(x,69,43,52,'gold_d'); im.rect(x+2,71,39,48,'gold_l')
        im.rect(x+3,74,37,29,'wood_l')
        im.line(x+21,72,x+21,119,'wood_d'); im.line(x+2,98,x+39,98,'wood_d')
        im.rect(x+2,113,39,5,'walnut_l'); im.line(x+3,112,x+39,112,'ivory')
        for xx in (x+9,x+28):
            im.oval(xx,102,8,8,'orange_l'); im.rect(xx+3,100,2,3,'walnut_l')
    im.rect(107,61,106,71,'walnut_d'); im.rect(112,65,96,65,'gold_d')
    im.rect(115,68,90,62,'wood_l')
    curtain(im,118,64,84,60)
    im.rect(155,67,5,63,'walnut_d')
    im.line(114,129,207,129,'wood'); im.line(111,132,210,132,'walnut_d')
    # Roof fascia and restrained bracket details frame the arched wordmark.
    im.rect(25,56,270,6,'walnut_d'); im.line(27,57,292,57,'walnut_l')
    for x in (31,281):
        im.rect(x,60,7,72,'walnut_d'); im.line(x,62,x,130,'walnut_l')
        im.rect(x-3,62,13,4,'wood_d')
    lantern(im,47,69,True); lantern(im,274,69,True)
    for x in (66,238):
        im.oval(x,82,13,6,'gold_d')
        im.poly([(x+11,85),(x+16,81),(x+16,89)],'gold_d')
        im.put(x+3,84,'wood_l')
    # A little doorway planter and an umbrella stand are original street
    # details, deliberately subordinate to the logo and food.
    box(im,23,114,17,19,'walnut_l','walnut_d',2)
    for x,y in ((25,103),(30,99),(35,106)):
        im.line(31,116,x+2,y+4,'green_d'); im.oval(x,y,5,11,'green')
        im.line(x+1,y+2,x+1,y+7,'green_l')
    box(im,281,115,12,18,'indigo','indigo_d',2)
    im.line(284,119,282,101,'slate_l'); im.line(290,118,292,103,'red_d')
    im.line(281,101,284,99,'metal'); im.line(292,103,295,101,'coral')
    # Flat night sky behind the whole arch; logo stays inside rows 10..60.
    logo(im)
    im.rect(0,133,320,19,'walnut_d')
    im.round(14,133,292,17,6,'metal'); im.round(15,134,290,15,5,'slate')
    for x in range(20,301,4): im.line(x,135,x,147,'slate_d')
    im.line(20,133,297,133,'white'); im.line(20,150,297,150,'walnut_l')
    for i,k in enumerate(('salmon','kappa','tamago','ikura','ebi','tuna','uramaki')):
        x=39+i*40
        im.blit(ART['plate_'+PLATES[i%5]],x-9,141)
        im.blit(ART[f'sushi_{k}_0'],x-7,137)
    im.rect(0,152,320,16,'night')
    add('title',im,(320,168),'pictures',True)


def panel():
    im=Image(200,120,'night')
    for x in (29,169):
        im.line(x,0,x-3,16,'wood'); im.line(x+1,0,x-2,16,'wood_l')
        im.put(x-2,12,'walnut')
    box(im,4,12,192,108,'walnut','walnut_d',5)
    im.line(8,13,190,13,'wood_l'); im.line(5,18,5,112,'wood_d')
    im.rect(9,17,182,95,'wood_d')
    im.rect(11,19,178,91,'cream_d')
    im.rect(12,20,176,88,'cream')
    for x in (27,167):
        oval(im,x,14,5,4,'gold','walnut_d'); im.put(x+1,15,'gold_l')
    im.line(12,112,187,112,'walnut_l')
    im.line(12,115,187,115,'wood_d'); im.line(16,117,183,117,'walnut_d')
    add('panel',im,(200,120),'pictures',True)


def mock():
    im=Image(320,200)
    im.blit(ART['room'],0,0)
    # Six people on the eight exact seat anchors; empty seats give gestures
    # and one modest stack of eaten plates room to breathe.
    patrons=((0,'office','want'),(1,'granny','eat_0'),(2,'student','sit_0'),
             (4,'tourist','happy'),(6,'kid','want'),(7,'chef_fan','eat_1'))
    for seat,name,frame in patrons:
        im.blit(ART[f'cust_{name}_{frame}'],48+32*seat-12,38)
    for y in (65,62,59): im.blit(ART['plate_side_blue'],132,y)
    for seat,kind,length,c in ((0,'salmon',17,'patience_green'),(2,'tamago',12,'patience_yellow'),(6,'ikura',19,'patience_green')):
        x=48+32*seat
        im.blit(ART['bubble_sel' if seat==0 else 'bubble'],x-11,18)
        im.blit(ART[f'sushi_{kind}_0'],x-7,21)
        im.rect(x-10,38,20,2,'ink'); im.rect(x-9,38,length,1,c)
    im.blit(ART['heart_0'],186,42)
    for k,frame in enumerate(('slice_1','rice_1','place_1')):
        x=80+80*k
        if k==1: im.blit(ART['select_cook'],x-22,74)
        im.blit(ART[f'cook{k}_{frame}'],x-20,76)
    # Bottom-centre sushi anchor is exactly two rows above the plate anchor:
    # plate top y; sushi top y-4, so their last rows are y+7 and y+5.
    courses=((26,75,'green','kappa',0),(102,75,'red','salmon',0),
             (184,75,'blue','ebi',0),(215,75,'gold','tamago',1),(278,75,'black','ikura',0),
             (9,105,'blue','tuna',0),(311,116,'green','uramaki',1),
             (36,145,'gold','tamago',0),(87,145,'red','salmon',0),
             (137,145,'black','unagi',0),(192,145,'green','kappa',2),
             (244,145,'blue','ebi',0),(287,145,'red','ikura',0))
    for x,y,c,k,s in courses:
        im.blit(ART['plate_'+c],x-9,y); im.blit(ART[f'sushi_{k}_{s}'],x-7,y-4)
    im.blit(ART['fly_0'],183,133); im.blit(ART['fly_1'],202,137)
    im.blit(ART['stink_0'],189,131)
    im.blit(ART['bar'],0,168)
    for k in range(3):
        x=82+80*k
        im.blit(ART[f'cook{k}_face'],x+3,174)
        queue=(('salmon','tuna'),('tamago','kappa','uramaki'),('ikura',))[k]
        for i,kind in enumerate(queue): im.blit(ART[f'sushi_{kind}_0'],x+28+16*i,177)
        im.rect(x+27,192,(31,22,42)[k],2,'progress')
    game_text(im,'¥ 1250',9,174,True)
    game_text(im,'19:40',25,189)
    add('mock',im,(320,200),'preview',True)
    add('mock_3x',im.scale(3),(960,600),'preview',True)


def sheets():
    # Two grounds per sprite, both at precisely 3x. Row packing keeps the
    # files legible without scaling the tiny sprites into unrelated sizes.
    for group,width in (('sprites',1200),('cooks',1440),('customers',1200),('pictures',1920)):
        names=[n for n in ART if GROUP[n]==group]
        placements=[]; x=y=12; row_h=0
        for name in names:
            im=ART[name]
            copies=1 if name in OPAQUE else 2
            stacked=im.w*3*copies+12*(copies-1)+16>width-24
            columns=1 if stacked else copies
            rows=copies if stacked else 1
            w=max(im.w*3*columns+12*(columns-1)+16,len(name+'.png')*6+16)
            h=im.h*3*rows+12*(rows-1)+34
            assert w<=width-24,name
            if x+w>width:
                x=12; y+=row_h+12; row_h=0
            placements.append((name,x,y,w,h,stacked))
            x+=w+12; row_h=max(row_h,h)
        sh=Image(width,y+row_h+12,'cream_d')
        for name,x,y,w,h,stacked in placements:
            im=ART[name]
            sh.rect(x,y,w,h,'walnut_d')
            label(sh,name+'.png',x+8,y+8,'ivory')
            for i,bg in enumerate(('grey','cream') if name not in OPAQUE else ('cream',)):
                xx=x+8+(0 if stacked else i*(im.w*3+12))
                yy=y+22+(i*(im.h*3+12) if stacked else 0)
                sh.rect(xx,yy,im.w*3,im.h*3,bg)
                sh.blit(im.scale(3),xx,yy)
                assert xx+im.w*3<=sh.w and yy+im.h*3<=sh.h,name
        add('sheet_'+group,sh,(sh.w,sh.h),'sheet',True)


def required_sizes():
    sizes={'room':(320,168),'title':(320,168),'bar':(320,32),'panel':(200,120),
           'mock':(320,200),'mock_3x':(960,600),
           'bubble':(22,20),'bubble_sel':(22,20),'select_cook':(44,52),'select_seat':(28,36),
           'cursor':(16,16),'coin':(8,8),'font_small':(len(SMALL)*6,8),'font_big':(len(BIG)*10,14)}
    for f in range(4): sizes[f'belt_h_{f}']=(8,12); sizes[f'belt_v_{f}']=(12,8)
    for c in PLATES: sizes['plate_'+c]=(18,8); sizes['plate_side_'+c]=(14,3)
    for k in KINDS:
        for s in range(3): sizes[f'sushi_{k}_{s}']=(14,10)
    for k in range(3):
        sizes[f'cook{k}_face']=(20,20)
        for f in COOK_FRAMES: sizes[f'cook{k}_{f}']=(40,48)
    for name in CUSTOMERS:
        for f in CUST_FRAMES: sizes[f'cust_{name}_{f}']=(24,32)
    for name,size in (('fly',(7,5)),('stink',(10,8)),('steam',(12,10)),('heart',(9,9)),('star',(9,9)),('bell',(12,12))):
        for f in range(2): sizes[f'{name}_{f}']=size
    for f in range(3): sizes[f'poof_{f}']=(16,16)
    return sizes


def validate():
    required=required_sizes()
    assert set(ART)==set(required)|{'sheet_sprites','sheet_cooks','sheet_customers','sheet_pictures','palette'}
    assert all((ART[n].w,ART[n].h)==size for n,size in required.items())
    used=set()
    for name,im in ART.items():
        assert (im.w,im.h)==EXPECTED[name],name
        assert all(c[3] in (0,255) for c in im.p),name
        colors={c for c in im.p if c[3]}
        assert colors<=set(P.values()),name
        assert len(colors)<=64,(name,len(colors))
        used|=colors
        if name in OPAQUE: assert all(c[3]==255 for c in im.p),name
        else:
            assert any(c[3]==0 for c in im.p),name
            assert P['black'] not in colors,name
    assert len(used)<=200
    # Tile continuity and phase direction, independently checked against f=0.
    for f in range(4):
        h,v=ART[f'belt_h_{f}'],ART[f'belt_v_{f}']
        for y in range(12):
            for x in range(8):
                assert h.get(x,y)==ART['belt_h_0'].get((x-f)%8,y)
                assert v.get(y,x)==ART['belt_v_0'].get(y,(x-f)%8)
                assert h.get(x,y)==h.get((x+4)%8,y)==v.get(y,x)
    r=ART['room']
    for y in list(range(71,83))+list(range(141,153)):
        for x in range(16,304): assert r.get(x,y)==ART['belt_h_0'].get(x%8,y%12)
    for x in list(range(3,15))+list(range(305,317)):
        for y in range(84,140): assert r.get(x,y)==ART['belt_v_0'].get(x%12,y%8)
    for y in (70,83,140,153):
        assert all(r.get(x,y)==P['white'] for x in range(16,304))
    for x in (2,15,304,317):
        assert all(r.get(x,y)==P['white'] for y in range(84,140))
    assert all(r.get(x,y)==P['wood_l'] for y in range(128,135) for x in range(16,304))
    assert all(ART['panel'].get(x,y)==P['cream'] for y in range(20,108) for x in range(12,188))
    assert all(ART['title'].get(x,y)==P['night'] for y in range(152,168) for x in range(320))
    for k in range(3):
        for frame in COOK_FRAMES:
            im=ART[f'cook{k}_{frame}']
            # No apron/body rectangles may survive into the counter layer.
            assert all(im.get(x,y)[3]==0 for y in range(36,48) for x in (0,1,38,39)),(k,frame)
    for name in CUSTOMERS:
        images=[ART[f'cust_{name}_{f}'] for f in CUST_FRAMES]
        assert len({im.png() for im in images})==len(CUST_FRAMES),name
        if name=='kid':
            assert all(not im.get(x,y)[3] for im in images for y in range(10) for x in range(24))
    assert ART['mock_3x'].p==ART['mock'].scale(3).p
    assert all(ART['cursor'].get(x,0)[3]==0 for x in range(16))
    assert ART['cursor'].get(1,1)[3]==255
    assert len(SMALL)==len(set(SMALL)) and len(BIG)==len(set(BIG))
    return used


def main():
    fonts(); foods(); cooks(); customers(); small_sprites()
    room(); bar(); title(); panel(); mock(); sheets()
    palette=Image(16,4)
    for i,c in enumerate(P.values()): palette.put(i%16,i//16,c)
    add('palette',palette,(16,4),'palette',True)
    used=validate()
    OUT.mkdir(parents=True,exist_ok=True)
    digest=hashlib.sha256()
    for name,im in ART.items():
        data=im.png()
        (OUT/(name+'.png')).write_bytes(data)
        digest.update(name.encode('ascii')+b'\0'+data)
    palette_text=''.join(f'{value.upper()} {name}\n' for name,value in HEX.items())
    (OUT/'palette.txt').write_text(palette_text,encoding='ascii')
    digest.update(palette_text.encode('ascii'))
    print(f'Wrote {len(ART)} PNGs and palette.txt to {OUT}')
    print(f'{len(used)} opaque colours total; every image <=64; sizes, binary alpha, geometry and phases verified.')
    for name in ('room','title','bar','panel','mock'):
        print(f'  {name}: {ART[name].w} x {ART[name].h}, {len(set(ART[name].p))} colours')
    print('Content SHA-256:',digest.hexdigest())


if __name__=='__main__':
    main()
