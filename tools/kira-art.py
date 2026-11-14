#!/usr/bin/env python3
"""Princess Kira's pixel workshop. Python 3, standard library, no external assets.

All coordinates are inclusive. Artwork is drawn at its native resolution;
contact sheets use nearest-neighbour enlargement. Run from any directory.
"""
from pathlib import Path
import struct
import zlib
import hashlib

OUT = Path(__file__).resolve().parents[1] / 'os/progs/kira/art'
# Shared, deliberately short ramps: outline, shadow, body, light.
HEX = {
 'ink':'493453', 'violet_dark':'493064','violet_shadow':'69418c','violet':'8954b4','lilac':'b68bda','lavender':'d9b9ed','pale':'efe0f6',
 'hair_dark':'39234f','hair':'513074','hair_light':'77479a',
 'skin_dark':'a15e63','skin_shadow':'e7a082','skin':'ffd0a3','skin_light':'ffe4c2','blush':'f58e9d',
 'gold_dark':'9c613e','gold_shadow':'d99941','gold':'f7c957','gold_light':'ffe895',
 'pink_dark':'a24773','pink_shadow':'d56292','pink':'f496bc','pink_light':'ffd1df',
 'red_dark':'9e4150','red':'e96576','red_light':'ff9c9f',
 'orange_dark':'975338','orange_shadow':'d68247','orange':'f3aa58','orange_light':'ffd18a',
 'brown_dark':'684539','brown':'a97151','brown_light':'d29d70','tan':'eabe88',
 'cream_shadow':'d5b9aa','cream':'f8e4c9','cream_light':'fff2df','white':'fffaf4',
 'grey_dark':'626681','grey':'acb6c8','grey_light':'d7dfeb',
 'green_dark':'32674f','green_shadow':'458961','green':'6ab875','green_light':'a4d787','mint':'d1e9ac',
 'blue_dark':'3e608c','blue_shadow':'538dc0','blue':'77bce3','blue_light':'b7e4f4','sky':'d0eff9',
 'royal_dark':'444b99','royal':'6d7dd7','royal_light':'a6b6ef',
 'soil':'a77858','soil_light':'c4986e', 'black':'000000','paper':'ffffff',
}
C = {k:tuple(bytes.fromhex(v))+(255,) for k,v in HEX.items()}
CLEAR=(0,0,0,0)

def col(c): return C[c] if isinstance(c,str) else c

class Canvas:
    def __init__(self,w,h,bg=CLEAR):
        self.w,self.h=w,h
        self.p=[col(bg)]*(w*h)
    def put(self,x,y,c):
        if 0<=x<self.w and 0<=y<self.h: self.p[y*self.w+x]=col(c)
    def get(self,x,y): return self.p[y*self.w+x] if 0<=x<self.w and 0<=y<self.h else CLEAR
    def rect(self,x0,y0,x1,y1,c):
        for y in range(max(0,y0),min(self.h,y1+1)):
            for x in range(max(0,x0),min(self.w,x1+1)): self.put(x,y,c)
    def ellipse(self,x0,y0,x1,y1,c):
        # Integer pixel-centre test; exact, symmetric inclusive bounds.
        w,h=x1-x0+1,y1-y0+1
        for y in range(max(0,y0),min(self.h,y1+1)):
            for x in range(max(0,x0),min(self.w,x1+1)):
                if (2*x-x0-x1)**2*h*h+(2*y-y0-y1)**2*w*w<=w*w*h*h: self.put(x,y,c)
    def poly(self,pts,c):
        for y in range(max(0,min(p[1] for p in pts)),min(self.h,max(p[1] for p in pts)+1)):
            for x in range(max(0,min(p[0] for p in pts)),min(self.w,max(p[0] for p in pts)+1)):
                inside=False
                j=len(pts)-1
                for i,(xi,yi) in enumerate(pts):
                    xj,yj=pts[j]
                    if (yi>y)!=(yj>y) and x<(xj-xi)*(y-yi)/(yj-yi)+xi: inside=not inside
                    j=i
                if inside: self.put(x,y,c)
        for a,b in zip(pts,pts[1:]+pts[:1]): self.line(*a,*b,c)
    def line(self,x0,y0,x1,y1,c,width=1):
        dx,dy=abs(x1-x0),-abs(y1-y0); sx=1 if x0<x1 else -1; sy=1 if y0<y1 else -1; e=dx+dy
        while True:
            self.rect(x0-(width-1)//2,y0-(width-1)//2,x0+width//2,y0+width//2,c)
            if x0==x1 and y0==y1: break
            e2=2*e
            if e2>=dy:e+=dy;x0+=sx
            if e2<=dx:e+=dx;y0+=sy
    def round(self,x0,y0,x1,y1,r,c):
        self.rect(x0+r,y0,x1-r,y1,c); self.rect(x0,y0+r,x1,y1-r,c)
        for x in (x0,x1-2*r):
            for y in (y0,y1-2*r):self.ellipse(x,y,x+2*r,y+2*r,c)
    def paste(self,src,x,y,scale=1,flip=False):
        for yy in range(src.h):
            for xx in range(src.w):
                c=src.get(src.w-1-xx if flip else xx,yy)
                if c[3]:self.rect(x+xx*scale,y+yy*scale,x+(xx+1)*scale-1,y+(yy+1)*scale-1,c)
    def crop(self,x,y,w,h):
        out=Canvas(w,h)
        for yy in range(h):
            for xx in range(w):out.put(xx,yy,self.get(x+xx,y+yy))
        return out
    def png(self):
        def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
        raw=b''.join(b'\0'+bytes(v for c in self.p[y*self.w:(y+1)*self.w] for v in c) for y in range(self.h))
        return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',self.w,self.h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')

ART={}; GROUP={}; EXPECT={}; OPAQUE=set(); ANCHOR=set()
def save(name,im,group='sprites',opaque=False,anchor=True):
    assert name not in ART,name
    ART[name]=im; GROUP[name]=group; EXPECT[name]=(im.w,im.h)
    if opaque:OPAQUE.add(name)
    if anchor and not opaque:ANCHOR.add(name)

def outlined(im,method,args,fill,edge,thick=1):
    mask=Canvas(im.w,im.h);getattr(mask,method)(*args,'white')
    pts={(x,y) for y in range(im.h) for x in range(im.w) if mask.get(x,y)[3]}
    for x,y in pts:
        border=any((x+dx,y+dy) not in pts for dx,dy in ((-thick,0),(thick,0),(0,-thick),(0,thick)))
        im.put(x,y,edge if border else fill)

def E(im,box,fill,edge,thick=1):outlined(im,'ellipse',box,fill,edge,thick)
def P(im,pts,fill,edge,thick=1):outlined(im,'poly',(pts,),fill,edge,thick)
def R(im,box,fill,edge,r=3,thick=1):outlined(im,'round',(*box,r),fill,edge,thick)
def eye(im,x,y,blink=False,big=False):
    if blink:
        im.line(x-1,y,x+2,y,'ink');im.put(x-2,y-1,'ink')
    elif big:
        E(im,(x-1,y-1,x+3,y+5),'ink','ink');im.rect(x,y,x+1,y+1,'white')
    else:
        im.rect(x,y,x+1,y+2,'ink');im.put(x,y,'white')
def smile(im,x,y):
    im.put(x-2,y,'skin_dark');im.line(x-1,y+1,x+1,y+1,'skin_dark');im.put(x+2,y,'skin_dark')
def heart(im,x,y,s,fill='pink',edge='pink_dark'):
    pts=[(x,y+s//4),(x+s//4,y),(x+s//2,y+s//4),(x+3*s//4,y),(x+s,y+s//4),(x+s,y+s//2),(x+s//2,y+s),(x,y+s//2)]
    P(im,pts,fill,edge)
def star(im,x,y,r,fill='gold_light'):
    P(im,[(x,y-r),(x+1,y-1),(x+r,y),(x+1,y+1),(x,y+r),(x-1,y+1),(x-r,y),(x-1,y-1)],fill,fill)
def flower(im,x,y,r=4,kind='daisy'):
    color={'daisy':'white','sunflower':'gold','tulip':'pink','rose':'pink'}[kind]
    edge={'daisy':'grey_dark','sunflower':'gold_dark','tulip':'pink_dark','rose':'pink_dark'}[kind]
    if kind=='tulip':
        P(im,[(x-r,y-r),(x-1,y-r+2),(x,y-r),(x+2,y-r+2),(x+r,y-r),(x+r,y+1),(x+2,y+r),(x-2,y+r),(x-r,y+1)],color,edge)
        im.line(x,y-r+3,x,y+r-2,'pink_light')
    elif kind=='rose':
        E(im,(x-r,y-r,x+r,y+r),color,edge)
        im.line(x-r+2,y-1,x+1,y-1,'pink_light');im.line(x+1,y-1,x+1,y+2,edge);im.line(x-1,y+2,x+1,y+2,edge)
    else:
        mask=Canvas(im.w,im.h)
        petal=max(2,r//2)
        for box in [(x-petal,y-r-2,x+petal,y+1),
                    (x-petal,y-1,x+petal,y+r+2),
                    (x-r-2,y-petal,x+1,y+petal),
                    (x-1,y-petal,x+r+2,y+petal)]:mask.ellipse(*box,'white')
        off=max(2,r-2)
        for dx,dy in [(-off,-off),(off,-off),(-off,off),(off,off)]:
            mask.ellipse(x+dx-petal,y+dy-petal,x+dx+petal,y+dy+petal,'white')
        for yy in range(im.h):
            for xx in range(im.w):
                if mask.get(xx,yy)[3]:
                    border=any(not mask.get(xx+dx,yy+dy)[3] for dx,dy in [(-1,0),(1,0),(0,-1),(0,1)])
                    im.put(xx,yy,edge if border else color)
        if r>=5:
            for sx in (-1,1):
                for sy in (-1,1):
                    im.line(x+sx*3,y+sy*4,x+sx*4,y+sy*6,'grey' if kind=='daisy' else 'gold_shadow')
                    im.line(x+sx*4,y+sy*3,x+sx*6,y+sy*4,'grey' if kind=='daisy' else 'gold_shadow')
        center=(4 if kind=='sunflower' else 3) if r>=5 else 2
        E(im,(x-center,y-center,x+center,y+center),'brown' if kind=='sunflower' else 'gold','gold_dark')


# Five-by-seven lettering, with a deliberately round-shouldered silhouette.
FONT={}
FONT_DATA={
'A':'01110/11011/11011/11111/11011/11011/11011','B':'11110/11011/11011/11110/11011/11011/11110',
'C':'01111/11000/11000/11000/11000/11000/01111','D':'11110/11011/11011/11011/11011/11011/11110',
'E':'11111/11000/11000/11110/11000/11000/11111','F':'11111/11000/11000/11110/11000/11000/11000',
'G':'01111/11000/11000/11011/11011/11011/01110','H':'11011/11011/11011/11111/11011/11011/11011',
'I':'11111/00100/00100/00100/00100/00100/11111','J':'00111/00011/00011/00011/11011/11011/01110',
'K':'11011/11011/11110/11100/11110/11011/11011','L':'11000/11000/11000/11000/11000/11000/11111',
'M':'10001/11011/11111/10101/10001/10001/10001','N':'11001/11101/11101/11011/11011/11011/11001',
'O':'01110/11011/11011/11011/11011/11011/01110','P':'11110/11011/11011/11110/11000/11000/11000',
'Q':'01110/11011/11011/11011/11011/01110/00011','R':'11110/11011/11011/11110/11100/11010/11011',
'S':'01111/11000/11000/01110/00011/00011/11110','T':'11111/00100/00100/00100/00100/00100/00100',
'U':'11011/11011/11011/11011/11011/11011/01110','V':'11011/11011/11011/11011/11011/01010/00100',
'W':'10001/10001/10001/10101/11111/11011/10001','X':'11011/11011/01010/00100/01010/11011/11011',
'Y':'11011/11011/11011/01110/00100/00100/00100','Z':'11111/00011/00110/01100/11000/11000/11111',
'1':'00100/01100/00100/00100/00100/00100/01110','2':'01110/11011/00011/00110/01100/11000/11111',
'3':'11110/00011/00011/01110/00011/00011/11110','4':'00011/00111/01011/11011/11111/00011/00011',
'5':'11111/11000/11000/11110/00011/00011/11110','6':'01110/11000/11000/11110/11011/11011/01110',
'7':'11111/00011/00011/00110/00110/01100/01100','8':'01110/11011/11011/01110/11011/11011/01110',
'9':'01110/11011/11011/01111/00011/00011/01110','0':'01110/11011/11011/11011/11011/11011/01110',
'!':'00100/00100/00100/00100/00100/00000/00100','_':'00000/00000/00000/00000/00000/00000/11111',
'.':'00000/00000/00000/00000/00000/00110/00110','-':'00000/00000/00000/11111/00000/00000/00000',' ':'00000/00000/00000/00000/00000/00000/00000'}
FONT={k:v.split('/') for k,v in FONT_DATA.items()}
def text_width(s,scale=1):return (6*len(s)-1)*scale

def lettering(im,s,x,y,scale=1,fill='white',edge=None,outer=None):
    pts=[]
    rainbow=['red','orange','gold','green','blue','royal','violet','pink']
    for i,ch in enumerate(s.upper()):
        for yy,row in enumerate(FONT.get(ch,FONT[' '])):
            for xx,p in enumerate(row):
                if p=='1':
                    for dy in range(scale):
                        for dx in range(scale):pts.append((x+i*6*scale+xx*scale+dx,y+yy*scale+dy,rainbow[i%8] if fill=='rainbow' else fill))
    for radius,c in [(2,outer),(1,edge)]:
        if c:
            for xx,yy,_ in pts:
                for dy in range(-radius,radius+1):
                    for dx in range(-radius,radius+1):
                        if dx*dx+dy*dy<=radius*radius+1:im.put(xx+dx,yy+dy,c)
    for xx,yy,c in pts:im.put(xx,yy,c)

# Tiny animals are drawn from native pixel maps, never reduced from portraits.
TINY={
'cat':[
'..oo......oo....','..oao....oao....','..oaaoooooaao...','..oaaaaaaaao....','.oaaaoaaaoaao...','.oaawoaawoaao...','.oaaaoaaaoaao...','..oaalnlaao.....','...oawwwao..oo..','..oaawwwaao.oao.','..oaawwwaao.oao.','..oaaawaaao.oao.','..oaaaaaaaooao..','..oaaaaaaaaoo...','..oaaaooaaao....','..oooo..oooo....'],
'dog':[
'...ooooooo......','..obbbbbbbbo....','.obbbwwwbbbbo...','obbbwwwwwbbbbo..','obbowowowobbbbo.','obbowowowobbbbo.','obbowwnwwobbbbo.','.ooowwwwwwoooo..','....owmwo.......','...obwwbbo......','..obbwwbbbo.....','..obbwwbbbo.oo..','..obbwwbbboobo..','..obbbbbbbboo...','..obbooobbbo....','..oooo.ooooo....'],
'bunny':[
'...ooo..ooo.....','...owo..owo.....','...olo..olo.....','...olo..olo.....','...owo..owo.....','..owwoooowwo....','..owwwwwwwwo....','.owwowwowwwwo...','.owwowwowwwwo...','..owwlnlwwwo....','...owwwwwwo.....','..owwwwwwwwo....','..owwsssswwo....','..owwsssswwo....','.owwwoooowwwo...','.ooooo..ooooo...'],
'duck':[
'......ooo.......','.....oyyoo......','....oyyyyyo.....','...oyyyyyyyo....','..oyyoyyoyyyo...','..oyyoyyoyyyo...','..oyyrrrryyyo...','...oyrrryyyo....','....oyyyyyo.....','...oyyyyyyyo....','..oyyyyyyyyyo...','.oyyqyyyyqyyyo..','.oyyyqqqqyyyyo..','..oyyyyyyyyyo...','...oroooooro....','..orrrr.rrrro...'],
'pony':[
'..oo......oo....','..owo....owo....','..owwooooowwo...','..owwlllllwwo...','..owlllllllwo...','..owwowwowwwo...','..owwowwowwwo...','..owwssssswwwo..','...owssnsswo.lo.','....owwwwwo.llo.','...owwwwwwoollo.','..owwwwwwwwo lo.','..owwowwowwo....','..owwowwowwo....','..ossossosso....','..oooooooooo....'],
'bird':[
'......oo........','.....occo.......','....occcco......','...occccccco....','..occccccccco...','.occcoccocccco..','.occcoccocccco..','.occcrrrccccco..','occccrrrcccccco.','occdwwwwwwdccco.','ocdwwwwwwwwdcco.','.ocwwwwwwwwcco..','..ocwwwwwwcco...','...occccccco....','....oroooro.....','...orr..orro....'],
'frog':[
'...ooo..ooo.....','..ogwgoogwgo....','..ogwgoogwgo....','.oggggggggggo...','.oggggggggggo...','.ogglgggglggo...','..ogommmoggo....','...oggggggo.....','..oggggggggo....','.ogggttttgggo...','ogggttttttgggo..','ogg gttttg gggo.','oggggttttgggggo.','.ogggggggggggo..','oggggoooogggggo.','oooooo..ooooooo.']}

def tiny_animal(name,frame=0):
    fill,edge={'cat':('orange','orange_dark'),'dog':('brown','brown_dark'),'bunny':('white','grey_dark'),'duck':('gold','gold_dark'),'pony':('white','grey_dark'),'bird':('blue','blue_dark'),'frog':('green','green_dark')}[name]
    pal={'o':edge,'a':'orange','b':'brown','w':'white','l':'pink','n':'pink_dark','m':'skin_dark','s':'grey_light','y':'gold','r':'orange','q':'gold_light','c':'blue','d':'blue_shadow','g':'green','t':'mint'}
    im=Canvas(16,16)
    assert len(TINY[name])==16 and all(len(row)==16 for row in TINY[name])
    for y,row in enumerate(TINY[name]):
        for x,ch in enumerate(row):
            if ch in pal:im.put(x,y,pal[ch])
    # Individually placed eye glints, with an eyelid in the idle frame.
    eyes={'cat':[(5,5),(9,5)],'dog':[(5,4),(8,4)],'bunny':[(5,7),(8,7)],'duck':[(5,4),(8,4)],'pony':[(5,5),(8,5)],'bird':[(5,5),(8,5)],'frog':[(4,1),(9,1)]}[name]
    for x,y in eyes:
        im.put(x,y,'ink'); im.put(x,y+1,fill if frame else 'ink')
        if frame:im.put(x+1,y,'ink')
    return im

def animal(name,frame=0,head=False):
    im=Canvas(48,48)
    base,edge={'cat':('orange','orange_dark'),'dog':('brown','brown_dark'),'bunny':('white','grey_dark'),'duck':('gold','gold_dark'),'pony':('white','grey_dark'),'bird':('blue','blue_dark'),'frog':('green','green_dark')}[name]
    if name=='cat':
        # Curled tail, two little hind feet, bib and mitten-like front paws.
        E(im,(32,26,46,44),'orange_shadow',edge,2);E(im,(33,25,41,36),CLEAR,edge)
        E(im,(11,24,37,46),base,edge,2);E(im,(17,29,31,44),'cream',edge)
        E(im,(8,40,22,47),base,edge);E(im,(26,40,39,47),base,edge)
        P(im,[(7,16),(7,2),(18,9),(30,9),(40,2),(40,18)],base,edge,2)
        P(im,[(10,6),(11,14),(16,11)],'pink','pink_dark');P(im,[(37,6),(36,14),(31,11)],'pink','pink_dark')
        E(im,(6,8,41,34),base,edge,2)
        im.line(20,10,21,14,'orange_shadow',2);im.line(26,10,25,14,'orange_shadow',2)
        E(im,(14,22,32,31),'orange_light','orange_light')
        for x in (15,29):eye(im,x,18,frame==1,True)
        E(im,(10,24,14,26),'blush','blush');E(im,(34,24,38,26),'blush','blush')
        P(im,[(21,24),(26,24),(24,27)],'pink_dark','pink_dark');smile(im,24,28)
        for x,sg in [(7,-1),(38,1)]:
            im.line(x,25,x+sg*4,24,edge);im.line(x,28,x+sg*3,29,edge)
        im.line(18,36,18,43,edge);im.line(30,36,30,43,edge)
    elif name=='dog':
        E(im,(33,27,46,34 if frame else 40),base,edge,2)
        E(im,(11,25,37,46),base,edge,2);E(im,(17,28,31,44),'white','cream_shadow')
        E(im,(8,40,23,47),'white',edge);E(im,(26,40,40,47),'white',edge)
        E(im,(8,6,39,35),'white',edge,2);E(im,(10,7,25,26),base,base)
        E(im,(3,7,14,30),'brown',edge,2);E(im,(34,7,45,30),'brown',edge,2)
        im.line(6,14,6,23,'brown_light',2);im.line(37,13,37,22,'brown_light',2)
        for x in (16,29):eye(im,x,17,frame==1,True)
        E(im,(15,24,33,33),'cream_light','cream_shadow');E(im,(21,24,27,28),'brown_dark','brown_dark');smile(im,24,30)
        im.rect(15,34,33,37,'pink_dark');E(im,(22,35,27,40),'gold','gold_dark')
        im.line(18,39,18,44,'cream_shadow');im.line(30,39,30,44,'cream_shadow')
    elif name=='bunny':
        E(im,(9,0,20,24),'white',edge,2);E(im,(27,0,38,24),'white',edge,2)
        E(im,(13,4,17,18),'pink_light','pink');E(im,(30,4,34,18),'pink_light','pink')
        E(im,(35,33,46,43),'white',edge)
        E(im,(11,25,37,46),'white',edge,2);E(im,(18,31,30,42),'pink_light','pink_light')
        E(im,(7,13,40,36),'white',edge,2)
        for x in (15,29):eye(im,x,23,frame==1,True)
        E(im,(10,29,15,31),'pink','pink');E(im,(33,29,38,31),'pink','pink')
        P(im,[(21,28),(26,28),(24,31)],'pink_dark','pink_dark');smile(im,24,32)
        E(im,(7,40,22,47),'white',edge);E(im,(26,40,41,47),'white',edge)
        im.line(16,43,16,45,'pink');im.line(32,43,32,45,'pink')
    elif name=='duck':
        P(im,[(12,40),(10,44),(5,47),(23,47),(21,41)],'orange','orange_dark')
        P(im,[(28,40),(27,47),(44,47),(38,43),(37,40)],'orange','orange_dark')
        P(im,[(35,26),(45,23),(43,36),(37,39)],'gold','gold_dark')
        E(im,(7,22,40,43),'gold','gold_dark',2)
        E(im,(5,5,39,33),'gold','gold_dark',2)
        P(im,[(18,8),(17,2),(21,4),(23,0),(26,5),(28,7)],'gold','gold_dark')
        for x in (13,27):eye(im,x,16,frame==1,True)
        E(im,(13,24,33,31),'orange','orange_dark');im.line(17,27,29,27,'orange_dark')
        E(im,(8,25,12,27),'blush','blush');E(im,(34,25,38,27),'blush','blush')
        P(im,[(9,32),(12,37),(20,39),(26,35),(23,32)],'gold_light','gold_dark')
    elif name=='bird':
        im.line(17,40,17,46,'orange_dark',2);im.line(31,40,31,46,'orange_dark',2)
        im.line(12,47,21,47,'orange_dark');im.line(27,47,36,47,'orange_dark')
        P(im,[(34,30),(46,25),(44,39),(35,41)],'blue_shadow','blue_dark')
        E(im,(5,8,42,43),'blue','blue_dark',2)
        P(im,[(17,10),(18,3),(23,6),(27,1),(28,9)],'blue','blue_dark')
        E(im,(13,23,35,41),'cream_light','blue_light')
        for x in (14,29):eye(im,x,17,frame==1,True)
        P(im,[(19,25),(24,22),(29,25),(24,30)],'gold','gold_dark')
        E(im,(8,25,12,27),'pink','pink');E(im,(35,25,39,27),'pink','pink')
        P(im,[(7,25),(3,31),(7,37),(12,34),(14,28)],'blue_shadow','blue_dark')
        im.line(7,29,9,32,'blue_light')
    elif name=='frog':
        E(im,(4,30,19,45),'green_shadow','green_dark',2);E(im,(29,30,44,45),'green_shadow','green_dark',2)
        E(im,(12,24,36,45),'green','green_dark',2);E(im,(18,29,30,42),'mint','green_shadow')
        E(im,(5,9,43,31),'green','green_dark',2)
        E(im,(8,3,22,20),'green','green_dark',2);E(im,(27,3,41,20),'green','green_dark',2)
        E(im,(12,7,20,17),'white','green_light');E(im,(29,7,37,17),'white','green_light')
        eye(im,15,10,frame==1,True);eye(im,31,10,frame==1,True)
        im.line(16,24,19,27,'green_dark');im.line(19,27,29,27,'green_dark');im.line(29,27,32,24,'green_dark')
        E(im,(9,22,14,24),'pink','pink');E(im,(35,22,40,24),'pink','pink')
        P(im,[(13,32),(10,44),(4,45),(3,47),(20,47),(19,43)],'green','green_dark')
        P(im,[(35,32),(38,44),(44,45),(45,47),(28,47),(29,43)],'green','green_dark')
    else: # Pony: long face, pricked ears, full pink forelock and a flowing tail.
        P(im,[(34,25),(43,22),(46,29),(44,43),(38,45),(39,31)],'pink','pink_dark',2)
        E(im,(12,25,36,41),'white',edge,2)
        for x in (12,27):
            R(im,(x,33,x+9,47),'white',edge,2);im.rect(x+1,44,x+8,46,'grey')
        P(im,[(11,13),(9,1),(18,7),(30,7),(38,1),(37,15)],'white',edge,2)
        im.line(13,6,14,11,'pink',2);im.line(34,6,33,11,'pink',2)
        E(im,(10,8,37,34),'white',edge,2)
        P(im,[(15,9),(21,4),(29,5),(35,10),(30,16),(25,15),(25,10),(21,17),(14,17)],'pink','pink_dark')
        im.line(21,8,18,13,'pink_light',2)
        for x in (15,29):eye(im,x,18,frame==1,True)
        E(im,(12,26,36,36),'cream','grey_dark');im.put(18,29,'grey_dark');im.put(30,29,'grey_dark');smile(im,24,32)
    return im

def animal_icon(name):
    # Native 20px head designs, with head-specific ears and markings.
    im=Canvas(20,20)
    base,edge={'cat':('orange','orange_dark'),'dog':('white','brown_dark'),'bunny':('white','grey_dark'),'duck':('gold','gold_dark'),'pony':('white','grey_dark'),'bird':('blue','blue_dark'),'frog':('green','green_dark')}[name]
    top=4
    if name in ('cat','pony'):
        P(im,[(2,10),(1,1),(7,5),(13,5),(18,1),(18,11)],base,edge)
        im.line(3,4,4,7,'pink');im.line(16,4,15,7,'pink')
    if name=='bunny':
        E(im,(3,0,7,10),base,edge);E(im,(12,0,16,10),base,edge)
        im.line(5,2,5,7,'pink');im.line(14,2,14,7,'pink');top=7
    E(im,(1,top,18,19),base,edge)
    if name=='dog':
        E(im,(0,3,5,14),'brown',edge);E(im,(14,3,19,14),'brown',edge);E(im,(4,5,10,11),'brown','brown')
    if name=='bird':P(im,[(6,5),(7,1),(10,3),(12,0),(13,5)],base,edge)
    if name=='duck':P(im,[(7,5),(8,1),(10,3),(12,1),(13,5)],base,edge)
    if name=='pony':P(im,[(5,5),(8,2),(13,3),(16,6),(12,9),(10,6),(6,9)],'pink','pink_dark')
    ey=10 if name!='bunny' else 12
    if name=='frog':
        E(im,(2,2,8,10),base,edge);E(im,(11,2,17,10),base,edge);ey=6
    for x in (5,13):eye(im,x,ey)
    if name in ('duck','bird'):E(im,(6,13,13,16),'orange','orange_dark')
    elif name=='pony':
        E(im,(4,14,15,18),'cream','cream_shadow');im.put(7,15,edge);im.put(12,15,edge);im.line(8,17,11,17,edge)
    else:
        if name!='frog':im.put(9,14 if name!='bunny' else 15,'pink_dark')
        smile(im,10,17)
    if name!='frog':im.put(3,14,'pink');im.put(16,14,'pink')
    return im

FRIENDS=['cat','dog','bunny','duck','pony','bird','frog']
def make_friends():
    for name in FRIENDS:
        for f in range(2):
            save(f'{name}_fp_{f}.png',animal(name,f));save(f'{name}_td_{f}.png',tiny_animal(name,f))
        save(f'{name}_icon.png',animal_icon(name))

# Kira's hair is one rope braid, with interlocking violet lobes and a bow.
def braid(im,x,y,length,wide=9):
    for j in range(0,length,5):
        E(im,(x+(j//5%2),y+j,x+wide-(j//5%2),y+j+7),'hair','hair_dark')
        im.line(x+2,y+j+2,x+wide-2,y+j+4,'hair_light')
    P(im,[(x+2,y+length),(x+wide-1,y+length),(x+wide//2,y+length+7)],'hair','hair_dark')
    im.rect(x+1,y+length-1,x+wide,y+length+1,'pink')
    im.put(x,y+length,'pink_light');im.put(x+wide+1,y+length,'pink_light')

def tiara(im,x,y,w):
    P(im,[(x,y+7),(x-1,y+1),(x+w//4,y+4),(x+w//2,y),(x+3*w//4,y+4),(x+w,y+1),(x+w-1,y+7)],'gold','gold_dark')
    im.line(x+2,y+6,x+w-3,y+6,'gold_light');im.put(x+w//2,y+3,'pink_dark')

def kira_big(frame):
    im=Canvas(64,96)
    # Slipper bottoms are identical in each pose, exactly on row 95.
    E(im,(20,86,30,95),'violet_shadow','violet_dark');E(im,(34,86,44,95),'violet_shadow','violet_dark')
    im.line(23,91,27,91,'pink_light');im.line(37,91,41,91,'pink_light')
    E(im,(12,12,51,47),'hair','hair_dark',2)
    # Arms: gently lowered, waving, then cheering, all within the same box.
    arms=[([(20,49),(15,49),(10,67),(13,72),(18,70),(24,55)],[(43,49),(48,50),(53,68),(50,72),(46,70),(40,55)]),
          ([(20,49),(15,49),(10,67),(13,72),(18,70),(24,55)],[(42,48),(48,48),(53,36),(51,28),(55,24),(60,27),(59,40),(51,58),(43,57)]),
          ([(21,49),(16,48),(10,31),(5,26),(3,20),(7,17),(12,20),(14,28),(25,45)],[(42,49),(47,48),(53,31),(58,26),(60,20),(56,17),(51,20),(49,28),(38,45)])][frame]
    for a in arms:P(im,a,'skin','skin_dark')
    P(im,[(23,44),(40,44),(44,62),(53,87),(48,91),(17,91),(11,87),(20,62)],'violet','violet_dark',2)
    P(im,[(24,62),(20,85),(31,87),(31,63)],'lilac','lilac')
    P(im,[(37,64),(35,86),(44,86)],'violet_shadow','violet_shadow')
    im.line(16,87,48,87,'gold',2)
    for x in (21,32,43):star(im,x,81,2,'lavender')
    E(im,(15,47,25,57),'lilac','violet_dark');E(im,(39,47,48,57),'lilac','violet_dark')
    im.rect(24,57,40,60,'gold');E(im,(29,56,35,62),'gold_light','gold_dark')
    E(im,(26,39,37,51),'skin','skin_dark')
    P(im,[(23,46),(31,50),(40,46),(38,52),(26,52)],'cream_light','violet_dark')
    E(im,(12,24,18,34),'skin','skin_dark');E(im,(46,24,52,34),'skin','skin_dark')
    E(im,(15,13,49,45),'skin','skin_dark',2)
    P(im,[(15,27),(14,17),(20,10),(31,8),(43,13),(49,22),(48,29),(43,22),(39,17),(32,19),(25,16),(21,24)],'hair','hair_dark')
    im.line(19,17,25,12,'hair_light',2);im.line(35,12,42,17,'hair_light',2)
    for x in (23,37):eye(im,x,27,False,True)
    im.line(22,25,25,24,'hair_dark');im.line(37,24,40,25,'hair_dark')
    E(im,(19,34,25,37),'blush','blush');E(im,(39,34,45,37),'blush','blush')
    im.put(32,34,'skin_shadow')
    if frame==2:
        E(im,(28,36,36,42),'skin_dark','skin_dark');im.rect(30,40,34,41,'pink')
    else:smile(im,32,38)
    braid(im,45,37,33,8)
    tiara(im,22,5,20)
    return im

def kira_face(f):
    im=Canvas(28,28)
    E(im,(3,4,24,26),'hair','hair_dark')
    P(im,[(7,23),(19,23),(24,27),(3,27)],'violet','violet_dark')
    E(im,(4,8,23,24),'skin','skin_dark')
    P(im,[(4,15),(3,9),(8,4),(15,4),(23,8),(24,15),(20,13),(17,9),(11,11),(9,9),(6,14)],'hair','hair_dark')
    im.line(6,9,10,6,'hair_light')
    for x in (8,17):eye(im,x,14,f==1)
    im.rect(6,19,8,20,'blush');im.rect(19,19,21,20,'blush')
    if f==2:E(im,(11,19,16,23),'skin_dark','skin_dark');im.line(12,22,15,22,'pink')
    else:smile(im,14,21)
    braid(im,22,18,5,3);tiara(im,8,0,11)
    return im

def kira_td(direction,frame):
    im=Canvas(16,24)
    # Native 16 x 24 silhouette: crown, round face, puff sleeves, flared skirt.
    P(im,[(5,12),(10,12),(12,17),(14,21),(11,22),(4,22),(1,21),(3,17)],'violet','violet_dark')
    im.line(4,20,11,20,'lilac');im.rect(5,14,10,15,'gold')
    im.rect(4,22,6,23,'violet_dark');im.rect(9,22,11,23,'violet_dark')
    im.rect(3,22,12,23,CLEAR)
    if frame:
        im.rect(3,22,6,23,'violet_dark');im.line(4,22,6,22,'pink_light');im.line(9,22,11,22,'violet_dark')
    else:
        im.line(4,22,6,22,'violet_dark');im.rect(9,22,12,23,'violet_dark');im.line(9,22,11,22,'pink_light')
    E(im,(1,12,4,17),'skin','skin_dark');E(im,(11,12,14,17),'skin','skin_dark')
    E(im,(2,2,13,13),'hair','hair_dark')
    if direction=='up':
        im.line(4,5,5,10,'hair_light');im.line(10,4,11,9,'hair_light')
        braid(im,6,9,9,3)
    else:
        E(im,(3,4,12,12),'skin','skin_dark')
        P(im,[(3,8),(2,5),(5,2),(10,2),(13,5),(12,8),(10,5),(7,6),(5,5)],'hair','hair_dark')
        if direction=='down':
            im.put(5,8,'ink');im.put(10,8,'ink');im.line(7,11,8,11,'skin_dark');braid(im,11,11,6,2)
        else:
            P(im,[(5,5),(9,5),(10,9),(8,12),(4,12),(3,10),(1,10),(1,8),(3,8)],'skin','skin_dark')
            im.put(4,7,'ink');im.put(3,10,'skin');im.put(4,11,'skin_dark');im.line(9,5,10,10,'hair');braid(im,11,10,7,2)
    P(im,[(4,4),(3,0),(6,2),(8,0),(10,2),(12,0),(11,4)],'gold','gold_dark')
    im.put(8,2,'pink_dark')
    if direction=='right':
        flipped=Canvas(16,24);flipped.paste(im,0,0,flip=True);im=flipped
    return im

def make_kira():
    for f in range(3):save(f'kira_big_{f}.png',kira_big(f));save(f'kira_face_{f}.png',kira_face(f))
    for d in ('down','up','left','right'):
        for f in range(2):save(f'kira_td_{d}_{f}.png',kira_td(d,f))

# Repeating textures: seams are intentionally part of the repeating masonry
# or the uninterrupted base colour; motifs never get clipped at a seam.
def stone(n):
    im=Canvas(n,n,'cream');step=n//4
    for y in range(n):
        row=y//step
        for x in range(n):
            brick=(x+(step if row%2 else 0))//(2*step)
            if brick%2==row%2:im.put(x,y,'pink_light')
    for y in range(0,n,step):
        im.line(0,y,n-1,y,'cream_shadow');im.line(0,y+1,n-1,y+1,'cream_light')
        for x in range(-(step if y//step%2 else 0),n,step*2):
            im.line(x,y,x,y+step-1,'cream_shadow')
            im.line(x+1,y+2,x+1,y+step-2,'cream_light')
    return im

def texture_wall(name,n):
    im=stone(n)
    if name in ('hedge','roses'):
        im=Canvas(n,n,'green_shadow')
        # Interlocking leaf sprays, wrapped across the texture boundaries.
        # No lighting ramp: all leaves share the same local material colours.
        if n==64:
            for gy in range(0,64,16):
                for gx in range(0,64,16):
                    xx=gx+(8 if gy//16%2 else 0)
                    leaf=Canvas(24,16)
                    P(leaf,[(1,7),(3,3),(9,2),(12,4),(8,8),(3,9)],'green','green')
                    P(leaf,[(10,12),(13,7),(19,6),(22,8),(18,12),(13,13)],'green','green')
                    leaf.line(4,5,8,4,'green_light');leaf.line(14,9,18,8,'green_light')
                    leaf.line(4,10,9,10,'green_dark');leaf.line(14,14,19,13,'green_dark')
                    for yy in range(16):
                        for x in range(24):
                            if leaf.get(x,yy)[3]:im.put((xx+x)%64,(gy+yy)%64,leaf.get(x,yy))
        else:
            im.rect(0,0,15,6,'green')
            for x,y in [(1,2),(8,1),(4,5),(11,5),(1,10),(8,9),(12,12)]:
                im.line(x,y,x+2,y,'green_light' if y<7 else 'green');im.put(x+1,y+1,'green_dark')
        if name=='roses':
            for x,y in ([(13,12),(41,9),(27,29),(51,36),(10,49),(35,54)] if n==64 else [(4,4),(11,8),(5,12)]):flower(im,x,y,4 if n==64 else 2,'rose')
        if n==16:im.rect(0,13,15,15,'green_dark');im.line(1,13,14,13,'green_shadow')
        return im
    if n==16:
        im.rect(0,0,15,3,'cream_light');im.line(0,4,15,4,'cream_shadow')
        if name=='window':
            E(im,(5,5,11,11),'blue','gold_dark');im.rect(5,8,11,13,'gold_dark');im.rect(6,8,10,12,'blue');im.line(8,6,8,12,'cream');im.line(6,9,10,9,'cream')
        elif name=='banner':P(im,[(5,5),(11,5),(11,12),(8,14),(5,12)],'violet','violet_dark');heart(im,6,7,4,'pink_light','pink')
        elif name=='shelf':
            im.rect(2,5,13,14,'brown_dark')
            for x,c in [(3,'pink'),(5,'blue'),(8,'gold'),(11,'green')]:im.rect(x,6,x+1,10,c)
            im.line(2,11,13,11,'tan');im.line(2,14,13,14,'tan');E(im,(5,12,8,13),'gold','gold_dark')
        return im
    if name=='window':
        E(im,(14,5,49,40),'gold_shadow','gold_dark',2);im.rect(14,22,49,55,'gold_dark');im.rect(16,22,47,53,'gold_shadow')
        E(im,(19,10,44,36),'blue_light','cream_light',2);im.rect(19,23,44,49,'cream_light');im.rect(21,23,42,47,'blue_light')
        E(im,(22,25,37,30),'white','white');E(im,(26,22,34,29),'white','white')
        im.rect(30,12,33,49,'cream');im.rect(20,30,43,33,'cream');im.rect(11,53,52,56,'cream_light');im.line(11,57,52,57,'cream_shadow')
    elif name=='banner':
        im.rect(11,8,52,10,'gold_dark');E(im,(9,6,13,12),'gold','gold_dark');E(im,(50,6,54,12),'gold','gold_dark')
        P(im,[(18,10),(45,10),(45,45),(32,55),(18,45)],'violet','violet_dark',2)
        im.line(21,12,21,44,'lilac');im.line(42,12,42,44,'violet_shadow');heart(im,23,23,18,'pink_light','pink_dark')
        im.line(23,43,32,49,'gold');im.line(32,49,40,43,'gold')
    elif name=='shelf':
        R(im,(5,4,58,61),'brown','brown_dark',2,2);im.rect(9,8,54,56,'brown_dark')
        for y in (10,32):
            for j,(x,w,c,h) in enumerate([(11,6,'pink',16),(18,5,'blue',18),(25,7,'gold',14),(34,5,'green',17),(41,4,'violet',16)]):
                im.rect(x,y+18-h,x+w-1,y+18,c);im.line(x+1,y+20-h,x+1,y+16,'white');im.line(x+1,y+15,x+w-2,y+15,'gold_light')
        for y in (29,53):im.rect(8,y,55,y+3,'tan');im.line(8,y+4,55,y+4,'brown_dark')
        E(im,(47,37,53,45),'orange','orange_dark');E(im,(46,33,49,36),'orange','orange_dark');E(im,(51,33,54,36),'orange','orange_dark');E(im,(46,35,54,41),'orange','orange_dark');im.put(48,37,'ink');im.put(52,37,'ink')
        E(im,(46,18,54,27),'pink','pink_dark');star(im,50,22,2,'pink_light')
    return im

def texture_floor(name,n):
    base={'castle':'cream','carpet':'lilac','grass':'green','path':'tan','water':'blue'}[name]
    im=Canvas(n,n,base)
    if name=='castle':
        s=n//2
        for y in range(0,n,s):
            for x in range(0,n,s):
                im.rect(x,y,x+s-1,y+s-1,'pink_light' if (x//s+y//s)%2 else 'cream')
                im.line(x,y,x+s-1,y,'cream_light');im.line(x,y,x,y+s-1,'cream_light')
                im.line(x+s-1,y,x+s-1,y+s-1,'cream_shadow');im.line(x,y+s-1,x+s-1,y+s-1,'cream_shadow')
    elif name=='carpet':
        for x,y in ((n//4,n//4),(3*n//4,3*n//4)):star(im,x,y,2,'lavender')
    elif name=='grass':
        for x,y in ([(5,6),(22,8),(13,22),(27,26)] if n==32 else [(4,5),(11,12)]):
            im.line(x-1,y-1,x,y+1,'green_shadow');im.line(x,y+1,x+2,y-2,'green_light')
    elif name=='path':
        for x,y,w,h in ([(2,2,12,8),(18,4,11,12),(4,17,13,11),(21,22,8,7)] if n==32 else [(2,2,5,4),(9,3,4,5),(3,10,7,4)]):
            P(im,[(x+2,y),(x+w-2,y),(x+w,y+2),(x+w-1,y+h-1),(x+2,y+h),(x,y+h-2),(x,y+2)],'cream','brown_light');im.line(x+2,y+1,x+w-2,y+1,'cream_light')
    elif name=='water':
        for x,y,w in ([(4,7,9),(17,19,10),(3,27,6)] if n==32 else [(3,4,5),(8,11,5)]):
            im.line(x,y,x+w,y,'blue_light');im.put(x-1,y-1,'blue_light');im.put(x+w+1,y-1,'blue_light')
    return im

def make_textures():
    for name in ('stone','window','banner','shelf','hedge','roses'):
        for view,n in [('fp',64),('td',16)]:save(f'wall_{name}_{view}.png',texture_wall(name,n),'world',True)
    for name in ('castle','carpet','grass','path','water'):
        for view,n in [('fp',32),('td',16)]:save(f'floor_{name}_{view}.png',texture_floor(name,n),'world',True)
    im=Canvas(32,32,'pale');star(im,8,9,2,'lavender');star(im,24,25,2,'lavender');save('ceil_castle_fp.png',im,'world',True)

# Furniture uses small decorative details and readable material-specific outlines.
def prop(name):
    w,h={'tree':(64,112),'bush':(48,32),'fountain':(64,56),'bed':(64,48),'table':(48,48),'throne':(48,72),'chest':(40,32),'picnic':(64,20)}[name]
    im=Canvas(w,h)
    if name=='tree':
        P(im,[(26,56),(37,56),(38,99),(45,109),(44,111),(18,111),(19,108),(25,99)],'brown','brown_dark',2)
        im.line(29,69,29,104,'brown_light',2);im.line(33,89,36,81,'brown_dark',2)
        for box in [(4,22,59,76),(0,14,35,52),(24,10,63,57),(13,0,49,41)]:E(im,box,'green','green_dark',2)
        E(im,(9,16,31,39),'green_light','green_light');E(im,(26,5,46,25),'green_light','green_light')
        im.line(7,52,11,58,'green_shadow',2);im.line(42,61,51,54,'green_shadow',2)
        for x,y in [(12,32),(37,23),(49,42),(26,56),(8,51)]:
            im.line(x+4,y-3,x+4,y,'brown_dark');E(im,(x,y,x+9,y+10),'red','red_dark');im.rect(x+2,y+2,x+3,y+3,'red_light');im.line(x+5,y-2,x+8,y-3,'green_dark')
    elif name=='bush':
        for box in [(1,12,23,31),(18,10,46,31),(8,1,32,26),(27,4,45,25)]:E(im,box,'green','green_dark',2)
        E(im,(14,5,25,12),'green_light','green_light')
        for x,y in [(8,21),(20,12),(34,17),(25,26)]:flower(im,x,y,3,'rose')
    elif name=='fountain':
        E(im,(4,37,59,55),'grey','grey_dark',2);E(im,(5,30,58,47),'grey_light','grey_dark',2);E(im,(10,32,53,42),'blue','blue_dark');im.line(16,36,24,36,'blue_light');im.line(38,38,47,38,'blue_light')
        P(im,[(28,18),(35,18),(37,40),(26,40)],'grey_light','grey_dark')
        E(im,(16,16,47,27),'grey','grey_dark');E(im,(17,12,46,21),'grey_light','grey_dark');E(im,(21,14,42,18),'blue','blue_dark')
        im.line(31,4,31,16,'blue_light',3);im.line(32,1,32,8,'blue',2)
        for pts in [[(29,4),(23,2),(18,5),(16,11)],[(35,4),(40,2),(45,5),(47,11)]]:
            for a,b in zip(pts,pts[1:]):im.line(*a,*b,'blue',2)
        im.line(19,22,19,34,'blue_light',2);im.line(45,23,45,35,'blue_light',2)
    elif name=='bed':
        for x in (5,53):R(im,(x,3,x+6,47),'cream','gold_dark',2);E(im,(x-1,0,x+7,8),'gold','gold_dark')
        R(im,(9,7,54,29),'cream','gold_dark',5,2);heart(im,25,10,13,'pink','pink_dark')
        P(im,[(10,23),(53,23),(58,40),(5,40)],'pink','pink_dark',2)
        R(im,(16,21,46,29),'white','cream_shadow',3);im.line(19,23,43,23,'cream_light')
        im.rect(9,31,54,42,'pink');im.line(9,31,54,31,'pink_light',2)
        for x in (17,31,45):heart(im,x,35,5,'pink_light','pink_light')
        im.rect(8,43,55,46,'cream');im.line(8,46,55,46,'gold_dark')
    elif name=='table':
        for x in (10,33):P(im,[(x,27),(x+5,27),(x+4,47),(x-1,47)],'brown','brown_dark')
        E(im,(2,17,45,34),'brown','brown_dark',2);E(im,(2,14,45,29),'tan','brown_dark',2);im.line(9,27,39,27,'brown_light')
        E(im,(10,16,37,25),'white','grey_dark')
        R(im,(13,8,34,21),'pink','pink_dark',2);E(im,(13,5,34,13),'cream_light','pink_dark');im.line(15,14,32,14,'white',2)
        for x in (17,24,30):E(im,(x-1,6,x+2,9),'red','red_dark')
        im.rect(23,1,24,6,'blue');im.put(24,0,'gold')
    elif name=='throne':
        for x in (7,34):im.rect(x,56,x+6,71,'gold_dark');im.rect(x+1,57,x+4,70,'gold')
        P(im,[(9,52),(9,13),(14,7),(18,9),(24,0),(30,9),(34,7),(39,13),(39,52)],'gold','gold_dark',2)
        R(im,(14,15,34,50),'violet','violet_dark',5,2);heart(im,19,21,11,'lilac','violet_shadow')
        im.line(17,18,17,44,'lilac');R(im,(10,47,38,59),'violet','violet_dark',3,2);im.line(14,50,34,50,'lilac')
        for x in (4,37):R(im,(x,38,x+6,61),'gold','gold_dark',2);E(im,(x-1,35,x+7,43),'gold_light','gold_dark')
        im.rect(9,60,39,64,'gold');im.line(9,65,39,65,'gold_dark');star(im,24,10,3,'gold_light')
    elif name=='chest':
        R(im,(2,2,37,20),'brown_light','brown_dark',4,2);im.line(5,5,34,5,'tan');im.rect(5,13,34,22,'brown_dark')
        # Teddy peeks over the open lid.
        E(im,(12,6,17,12),'tan','brown_dark');E(im,(23,6,28,12),'tan','brown_dark');E(im,(12,9,28,23),'tan','brown_dark')
        eye(im,16,13);eye(im,24,13);E(im,(18,16,23,20),'cream','brown_light');im.put(20,17,'brown_dark')
        R(im,(1,20,38,31),'brown_light','brown_dark',2,2);im.line(4,23,35,23,'tan')
        for x in (6,30):im.rect(x,21,x+2,29,'gold')
        R(im,(17,23,23,28),'gold','gold_dark',1);im.put(20,25,'brown_dark')
    else:
        P(im,[(7,4),(55,4),(63,19),(0,19)],'cream_light','red_dark')
        for y in range(6,19,4):
            for x in range(5,59,6):
                if (x//6+y//4)%2:im.rect(x,y,x+4,y+2,'red')
        E(im,(38,0,53,13),'tan','brown_dark');E(im,(41,2,50,10),CLEAR,'brown_dark');R(im,(34,7,57,17),'tan','brown_dark',3)
        im.line(37,10,54,10,'brown');im.line(36,14,55,14,'brown')
        for x in (40,46,52):im.line(x,8,x,16,'brown')
        E(im,(11,9,25,15),'white','grey_dark');E(im,(15,8,22,12),'red','red_dark')
    return im

def prop_td(name):
    im=Canvas(16,24 if name in ('tree','throne') else 16)
    if name=='tree':
        P(im,[(6,13),(9,13),(9,21),(12,23),(3,23),(6,21)],'brown','brown_dark')
        for b in [(0,4,15,17),(3,0,12,12)]:E(im,b,'green','green_dark')
        im.line(5,3,9,3,'green_light')
        for x,y in [(3,7),(10,5),(8,12)]:E(im,(x,y,x+3,y+3),'red','red_dark');im.put(x+1,y,'red_light')
    elif name=='bush':
        E(im,(0,5,15,15),'green','green_dark');E(im,(3,1,12,12),'green','green_dark')
        flower(im,4,9,2,'rose');flower(im,10,6,2,'rose')
    elif name=='fountain':
        E(im,(0,5,15,15),'grey','grey_dark');E(im,(1,4,14,12),'blue','grey_dark');E(im,(5,2,10,10),'grey_light','grey_dark');im.line(7,0,7,6,'blue_light',2);im.line(3,8,5,8,'blue_light');im.line(10,9,12,9,'blue_light')
    elif name=='bed':
        R(im,(1,1,14,15),'cream','gold_dark',2);im.rect(3,5,12,13,'pink');R(im,(3,2,12,5),'white','cream_shadow',1);heart(im,6,8,4,'pink_light','pink_dark');im.line(2,14,13,14,'gold')
    elif name=='table':
        im.rect(3,11,4,15,'brown_dark');im.rect(11,11,12,15,'brown_dark');E(im,(0,3,15,13),'tan','brown_dark');E(im,(3,4,12,10),'white','grey_dark');R(im,(5,3,10,8),'pink','pink_dark',1);im.put(7,2,'red')
    elif name=='throne':
        im.rect(3,19,5,23,'gold_dark');im.rect(10,19,12,23,'gold_dark');P(im,[(2,16),(2,5),(5,5),(7,0),(10,5),(13,5),(13,16)],'gold','gold_dark');R(im,(4,7,11,17),'violet','violet_dark',2);R(im,(2,16,13,21),'gold','gold_dark',1);im.rect(4,16,11,18,'lilac');star(im,7,10,2,'pink_light')
    elif name=='chest':
        R(im,(1,1,14,12),'tan','brown_dark',2);E(im,(5,3,10,9),'tan','brown_dark');im.put(5,3,'brown_dark');im.put(10,3,'brown_dark');im.put(6,5,'ink');im.put(9,5,'ink');R(im,(0,9,15,15),'brown_light','brown_dark',1);im.rect(7,11,9,13,'gold')
    else:
        R(im,(0,2,15,15),'cream_light','red_dark',1)
        for y in range(4,15,3):
            for x in range(2,15,3):
                if (x//3+y//3)%2:im.rect(x,y,x+1,y+1,'red')
        E(im,(8,0,13,7),'tan','brown_dark');R(im,(7,5,14,10),'tan','brown_dark',1);im.line(9,6,9,9,'brown')
    return im

def make_props():
    for name in ('tree','bush','fountain','bed','table','throne','chest','picnic'):
        save(f'{name}_fp.png',prop(name),'world');save(f'{name}_td.png',prop_td(name),'world')

def note(im,x,y,c='violet',edge='violet_dark',size=1):
    E(im,(x,y+6*size,x+4*size,y+9*size),c,edge)
    im.rect(x+3*size,y,x+4*size,y+7*size,c);im.line(x+3*size,y,x+4*size,y,edge)
    P(im,[(x+4*size,y),(x+7*size,y+2*size),(x+7*size,y+4*size),(x+4*size,y+3*size)],c,edge)

def butterfly(c,f):
    im=Canvas(16,12);fill,light,edge=[('pink','pink_light','pink_dark'),('blue','blue_light','blue_dark'),('gold','gold_light','gold_dark')][c]
    if not f:
        for b in [(0,1,6,7),(9,1,15,7),(2,6,6,10),(9,6,13,10)]:E(im,b,fill,edge)
        for x in (3,11):E(im,(x-1,3,x+1,5),light,light)
    else:
        E(im,(4,1,10,10),fill,edge);E(im,(7,2,12,8),light,edge)
    im.line(7,3,7,11,'violet_dark');im.line(8,3,8,10,'violet_dark');im.put(6,1,'violet_dark');im.put(9,1,'violet_dark');im.put(5,0,'violet_dark');im.put(10,0,'violet_dark')
    return im

def can(w=24,h=24):
    im=Canvas(w,h)
    E(im,(14,7,23,18),'blue','blue_dark');E(im,(16,9,21,16),CLEAR,'blue_dark')
    P(im,[(6,13),(1,9),(0,6),(3,5),(8,11)],'blue','blue_dark')
    R(im,(5,10,18,23),'blue','blue_dark',3);E(im,(5,8,18,13),'blue_light','blue_dark');im.line(7,12,7,19,'blue_light')
    P(im,[(0,5),(3,3),(5,7),(2,9)],'blue_light','blue_dark');flower(im,12,17,2,'daisy')
    return im

def plant(kind,stage):
    im=Canvas(32,48)
    # The stem base is precisely at (15,47)/(16,47), ready for soil overlap.
    top=[35,23,13][stage-1]
    im.line(15,top,15,47,'green_dark',2);im.line(16,top,16,46,'green',1)
    for x,y,side in [(14,40,-1),(17,34,1)]+([(14,27,-1)] if stage>1 else []):
        P(im,[(x,y),(x+side*7,y-7),(x+side*8,y-2),(x+side*4,y+2),(x,y+2)],'green','green_dark')
        im.line(x,y,x+side*5,y-3,'green_light')
    if stage==2:E(im,(12,16,20,27),'pink' if kind in ('rose','tulip') else 'gold','green_dark');P(im,[(11,23),(16,27),(21,23),(19,29),(13,29)],'green','green_dark')
    if stage==3:
        flower(im,16,12,7 if kind in ('rose','tulip') else 6,kind)
        if kind=='sunflower':
            for x,y in [(14,11),(18,11),(16,14)]:im.put(x,y,'tan')
    return im

def make_small():
    for f in range(2):
        im=Canvas(9,9);heart(im,0 if not f else 1,0 if not f else 2,8 if not f else 6);save(f'heart_{f}.png',im)
        im=Canvas(9,9);cy=4+f;r=4-f
        P(im,[(4,cy-r),(5,cy-1),(4+r,cy),(5,cy+1),(4,cy+r),(3,cy+1),(4-r,cy),(3,cy-1)],'gold','gold_dark');im.put(4,cy,'gold_light');save(f'star_{f}.png',im)
        im=Canvas(9,12);note(im,0,2,'violet' if not f else 'pink','violet_dark' if not f else 'pink_dark');save(f'note_{f}.png',im)
    for c in range(3):
        for f in range(2):save(f'butterfly_{chr(97+c)}_{f}.png',butterfly(c,f))
    im=Canvas(16,16)
    P(im,[(3,1),(5,1),(6,3),(6,7),(8,6),(10,7),(12,7),(14,9),(14,13),(11,15),(6,15),(3,12),(1,10),(1,8),(3,8)],'white','grey_dark')
    im.line(8,8,8,10,'grey');im.line(11,9,11,11,'grey');im.line(6,13,12,13,'grey');save('cursor.png',im,anchor=False)
    im=Canvas(28,28);R(im,(0,0,27,27),CLEAR,'gold',5,2);save('select.png',im,anchor=False)
    rainbow=['red','orange','gold','green','blue','royal','violet','pink']
    for n in range(1,8):
        im=Canvas(24,32);lettering(im,str(n),5,9,3,rainbow[n-1],'white','ink');save(f'num_{n}.png',im)
    for s in FRIENDS+['picnic']:
        word='PICNIC TIME!' if s=='picnic' else s.upper();w=text_width(word,2)+12
        im=Canvas(w,24);R(im,(0,0,w-1,23),'lilac','violet_dark',5);im.line(6,2,w-7,2,'lavender');lettering(im,word,6,5,2,'white','violet_dark');save(f'word_{s}.png',im,anchor=False)
    im=Canvas(136,32);lettering(im,'HOORAY!',6,9,3,'rainbow','white','violet_dark');save('word_hooray.png',im)
    im=Canvas(320,32,'lilac');im.rect(0,0,319,2,'pale');im.line(0,3,319,3,'violet_shadow');im.line(0,31,319,31,'violet_shadow')
    for x in (5,314):star(im,x,9,3,'gold_light');im.put(x,20,'lavender');im.put(x,25,'lavender')
    save('bar.png',im,'sprites',True)
    for kind in ('tulip','daisy','sunflower','rose'):
        im=Canvas(24,24);R(im,(3,0,20,23),'cream_light','gold_dark',2);im.rect(5,2,18,4,'pink_light');im.line(11,12,11,21,'green_dark',2);im.line(12,19,16,16,'green',2);flower(im,12,11,3,kind);save(f'icon_{kind}.png',im)
        for stage in (1,2,3):save(f'plant_{kind}_{stage}.png',plant(kind,stage))
    save('icon_can.png',can())
    for kind in ('home','eyes','map','next','song'):
        im=Canvas(24,24)
        if kind=='home':
            R(im,(4,10,20,23),'cream','gold_dark',1);P(im,[(1,11),(12,1),(23,11),(22,13),(12,5),(2,13)],'pink','pink_dark');R(im,(10,15,15,23),'violet','violet_dark',2);im.rect(6,13,8,16,'blue');im.put(13,19,'gold')
        elif kind=='eyes':
            for x in (0,12):
                E(im,(x,6,x+11,23),'white','violet_dark');E(im,(x+4,11,x+9,19),'blue','blue_dark');E(im,(x+5,12,x+8,17),'ink','ink');im.put(x+5,12,'white')
        elif kind=='map':
            P(im,[(1,4),(8,1),(16,4),(22,1),(23,20),(16,23),(8,20),(0,23)],'cream','gold_dark')
            im.line(8,3,8,19,'cream_shadow');im.line(16,5,16,21,'cream_shadow');im.line(3,18,7,12,'blue',2);im.line(7,12,13,15,'blue',2);im.line(13,15,20,8,'blue',2);E(im,(3,6,7,10),'green','green_dark');star(im,17,7,3,'pink_dark')
        else:
            E(im,(0,0,23,23),'gold' if kind=='next' else 'pink','gold_dark' if kind=='next' else 'pink_dark');im.line(6,3,16,3,'gold_light' if kind=='next' else 'pink_light')
            if kind=='next':P(im,[(5,9),(12,9),(12,5),(19,12),(12,19),(12,15),(5,15)],'white','gold_dark')
            else:note(im,3,6,'white','pink_dark');P(im,[(14,8),(20,12),(14,17)],'white','pink_dark')
        save(f'icon_{kind}.png',im)
    paint=['red','orange','gold','green','blue','royal','violet','pink','brown','white']
    for i,c in enumerate(paint):
        im=Canvas(20,24);R(im,(2,5,17,23),c,'ink',3);im.rect(5,10,14,18,'cream_light');E(im,(7,12,12,16),c,'cream_shadow');E(im,(1,1,18,8),c,'ink');E(im,(4,3,15,6),c,'ink');im.line(5,3,12,3,'white');im.line(4,9,4,18,'white');save(f'pot_{i}.png',im)
    im=Canvas(7,9);P(im,[(3,0),(6,5),(6,7),(4,8),(2,8),(0,7),(0,5)],'blue','blue_dark');im.line(2,4,2,6,'blue_light');save('drop.png',im)

BUTTONS=[(8,48,155,103),(164,48,311,103),(8,108,155,163),(164,108,311,163)]
BARS=[(28+34*i,64+3*i,57+34*i,160-3*i) for i in range(8)]
SOILS=[(x,y) for y in (104,150) for x in (40,88,136,184,232,280)]
RAINBOW=['red','orange','gold','green','blue','royal','violet','pink']
LIGHTS=['red_light','orange_light','gold_light','green_light','blue_light','royal_light','lilac','pink_light']

def cloud(im,x,y,w):
    im.round(x,y+5,x+w,y+15,5,'white');im.ellipse(x+w//5,y,x+3*w//5,y+14,'white');im.ellipse(x+w//2,y+2,x+4*w//5,y+14,'white')

def castle(im,x,y,s=1):
    # Tiny distant castle, two towers and a friendly heart above the door.
    base=Canvas(60,53)
    base.rect(8,15,51,52,'cream');base.rect(21,26,38,52,'pink_light')
    for xx in (3,43):
        R(base,(xx,13,xx+14,52),'cream','cream_shadow',1);P(base,[(xx-3,14),(xx+7,0),(xx+17,14)],'pink','pink_dark');R(base,(xx+4,20,xx+10,31),'blue','gold_dark',3)
        base.rect(xx-1,36,xx+15,39,'cream_shadow');base.rect(xx,36,xx+14,37,'cream_light')
    for xx in (20,28,36):base.rect(xx,20,xx+4,27,'cream')
    R(base,(24,37,35,52),'violet','violet_dark',5);im.paste(base,x,y,s);heart(im,x+27*s,y+29*s,5*s,'pink','pink_dark')

def xylo_bar(i,hit=False):
    h=97-6*i;im=Canvas(30,h, LIGHTS[i] if hit else RAINBOW[i]);im.rect(0,0,2,h-1,'white' if hit else LIGHTS[i]);im.line(29,0,29,h-1,RAINBOW[i] if hit else ['red_dark','orange_dark','gold_dark','green_dark','blue_dark','royal_dark','violet_dark','pink_dark'][i])
    for y in (9,h-10):E(im,(12,y-2,17,y+3),LIGHTS[i],'ink');im.put(14,y-1,'white')
    if hit:star(im,16,h//2,9,'white');star(im,7,h//2-13,3,'white')
    return im

def menu_picture():
    im=Canvas(320,168,'sky')
    castle(im,-13,0);castle(im,274,0)
    for x,y in [(61,9),(254,14),(83,34),(238,35)]:star(im,x,y,3,'gold')
    # Title fits wholly inside rows 0..43 and is readable at native resolution.
    lettering(im,'PRINCESS KIRA',(320-text_width('PRINCESS KIRA',3))//2,12,3,'gold','gold_dark')
    labels=['FRIENDS','GARDEN','PAINT','MUSIC']
    for i,(x0,y0,x1,y1) in enumerate(BUTTONS):
        R(im,(x0,y0,x1,y1),'cream_light','violet_dark',7,2)
        im.line(x0+9,y0+3,x1-9,y0+3,'white')
        # Pictures occupy 49px at the left; labels occupy 82px at the right.
        if i==0:
            im.paste(ART['kira_face_0.png'],x0+6,y0+7);im.paste(ART['cat_icon.png'],x0+29,y0+27)
        elif i==1:
            im.line(x0+19,y0+18,x0+19,y0+46,'green_dark',2);im.line(x0+19,y0+35,x0+12,y0+30,'green',2)
            flower(im,x0+19,y0+16,5,'daisy');im.paste(can(),x0+28,y0+27)
        elif i==2:
            # A broad flat rainbow, with a paintbrush crossing its lower end.
            for r,c in zip(range(21,6,-2),RAINBOW):im.ellipse(x0+27-r,y0+27-r,x0+27+r,y0+27+r,c)
            im.ellipse(x0+22,y0+22,x0+32,y0+32,'cream_light');im.rect(x0+4,y0+28,x0+50,y0+49,'cream_light')
            P(im,[(x0+14,y0+44),(x0+33,y0+24),(x0+37,y0+28),(x0+18,y0+47)],'tan','brown_dark')
            P(im,[(x0+32,y0+24),(x0+37,y0+19),(x0+44,y0+17),(x0+42,y0+25),(x0+37,y0+29)],'pink','pink_dark')
        else:
            for j,c in enumerate(RAINBOW[:6]):
                xx=x0+8+j*6;yy=y0+24+j;R(im,(xx,yy,xx+4,y0+46-j),c,'brown_dark',1)
            note(im,x0+12,y0+9,'violet','violet_dark');note(im,x0+35,y0+7,'pink','pink_dark')
        word=labels[i];lettering(im,word,x0+59+(82-text_width(word,2))//2,y0+22,2,'violet_dark')
    return im

def garden_picture():
    im=Canvas(320,168,'sky')
    E(im,(22,10,51,39),'gold','gold_dark');eye(im,30,20);eye(im,42,20);smile(im,37,29)
    for a,b in [((35,4),(35,0)),((16,23),(11,23)),((57,23),(62,23)),((20,8),(17,5)),((54,8),(57,5)),((22,42),(19,45))]:im.line(*a,*b,'gold',2)
    cloud(im,75,10,43);cloud(im,228,17,55);castle(im,143,17)
    im.poly([(0,69),(0,61),(40,52),(85,62),(120,54),(166,66),(215,56),(259,64),(300,54),(319,60),(319,79)],'green_light')
    im.rect(0,70,319,167,'green')
    # Distant flower border is kept away from every planting rectangle.
    for x in range(7,320,19):
        im.line(x,77,x,81,'green_dark');im.put(x-1,76,'pink_light');im.put(x,75,'gold_light');im.put(x+1,76,'pink_light')
    for x,y in SOILS:im.ellipse(x-20,y-7,x+19,y+6,'soil')
    return im

def music_picture():
    im=Canvas(320,168,'pale')
    im.rect(0,0,319,3,'violet_shadow');im.rect(0,4,319,55,'lavender');im.rect(0,56,319,60,'cream');im.line(0,61,319,61,'gold_dark')
    im.rect(0,62,319,167,'lilac')
    # Stand remains behind the precise rectangular bars.
    im.rect(20,77,301,83,'brown');im.rect(20,144,301,150,'brown');im.line(20,77,301,77,'tan')
    for x in (20,295):im.rect(x,145,x+5,167,'brown_dark')
    for i,(x0,y0,x1,y1) in enumerate(BARS):im.paste(xylo_bar(i),x0,y0)
    return im

def make_pictures():
    for n,im in [('menu',menu_picture()),('garden',garden_picture()),('music',music_picture())]:save(n+'.png',im,'pictures',True)
    for i in range(8):save(f'xylo_hit_{i}.png',xylo_bar(i,True),'world',True)

# Colouring art uses only opaque paper and black. Every outline is an inward
# two-pixel stroke. Small facial marks are solid black, never fill targets.
def ce(im,b):E(im,b,'paper','black',2)
def cp(im,p):P(im,p,'paper','black',2)
def cr(im,b,r=4):R(im,b,'paper','black',r,2)
def cl(im,a,b):im.line(*a,*b,'black',2)
def ceye(im,x,y):im.ellipse(x,y,x+3,y+5,'black')
def csmile(im,x,y):
    cl(im,(x-5,y),(x-2,y+3));cl(im,(x-2,y+3),(x+3,y+3));cl(im,(x+3,y+3),(x+6,y))
def ccloud(im,x,y,w=45):
    # A single outline rather than overlapping circles with trapped pockets.
    cp(im,[(x,y+9),(x+6,y+5),(x+12,y+5),(x+16,y),(x+27,y),(x+33,y+6),(x+w-5,y+6),(x+w,y+12),(x+w-3,y+19),(x+4,y+19),(x,y+15)])
def cflower(im,x,y):
    # Three broad regions: blossom and two leaves. Centre is a solid mark.
    cp(im,[(x-13,y-7),(x-8,y-13),(x-1,y-11),(x+6,y-14),(x+13,y-7),(x+11,y),(x+14,y+6),(x+7,y+13),(x,y+11),(x-8,y+13),(x-14,y+6),(x-11,y)])
    im.ellipse(x-3,y-3,x+3,y+3,'black')
    cl(im,(x,y+13),(x,y+35))
    cp(im,[(x-1,y+31),(x-15,y+31),(x-17,y+18),(x-8,y+19),(x-1,y+27)])
    cp(im,[(x+2,y+31),(x+16,y+31),(x+18,y+18),(x+10,y+19),(x+2,y+27)])
def cbutterfly(im,x,y):
    cp(im,[(x-2,y),(x-13,y-11),(x-22,y-9),(x-24,y),(x-20,y+7),(x-23,y+15),(x-17,y+22),(x-9,y+21),(x-2,y+12)])
    cp(im,[(x+2,y),(x+13,y-11),(x+22,y-9),(x+24,y),(x+20,y+7),(x+23,y+15),(x+17,y+22),(x+9,y+21),(x+2,y+12)])
    im.round(x-2,y-1,x+2,y+17,2,'black');cl(im,(x-1,y),(x-6,y-9));cl(im,(x+1,y),(x+6,y-9))
    # Split each wing into two large colourable sections.
    cl(im,(x-21,y+7),(x-3,y+8));cl(im,(x+3,y+8),(x+21,y+7))

def colouring_one():
    im=Canvas(320,168,'paper')
    # Three arch bands and their open white underside, with a closed baseline.
    for b in [(9,15,105,113),(22,29,92,113),(35,43,79,113),(48,57,66,113)]:ce(im,b)
    im.rect(8,85,106,115,'paper');cl(im,(9,84),(105,84))
    # Close arch ends exactly where the baseline cuts them.
    ccloud(im,8,88,47);ccloud(im,58,88,44)
    ce(im,(265,13,304,52));ceye(im,275,25);ceye(im,291,25);csmile(im,284,39)
    for a,b in [((284,6),(284,2)),((258,31),(252,31)),((311,31),(317,31)),((263,10),(259,6)),((306,10),(311,5)),((263,54),(259,58)),((306,55),(311,60))]:cl(im,a,b)
    ccloud(im,119,9,55);ccloud(im,205,17,42)
    # Hill reaches the picture frame, forming two large ground regions.
    cp(im,[(2,153),(32,135),(79,120),(124,112),(191,110),(242,118),(285,135),(317,153),(317,165),(2,165)])
    # Walls, towers and roofs, with generous windows.
    cr(im,(115,65,218,137),1)
    for x in (101,207):
        cr(im,(x,53,x+29,137),1)
        cp(im,[(x-5,53),(x+14,28),(x+34,53)])
        cr(im,(x+7,67,x+22,88),6);cr(im,(x+7,101,x+22,123),6)
    for x in (137,166,195):
        cr(im,(x,55,x+15,74),1)
    cr(im,(147,94,185,137),15);cl(im,(166,96),(166,136))
    cr(im,(141,78,156,92),4);cr(im,(178,78,193,92),4)
    cp(im,[(147,139),(184,139),(205,165),(125,165)])
    cl(im,(139,151),(195,151))
    for x,y in [(18,122),(49,115),(254,119),(284,131)]:ce(im,(x,y,x+16,y+15))
    return im

def colouring_two():
    im=Canvas(320,168,'paper')
    # Kira, with a single broad braid subdivided into five closed woven lobes.
    cp(im,[(89,87),(78,110),(72,115),(67,111),(68,104),(78,80)])
    cp(im,[(141,87),(153,105),(165,107),(169,114),(164,120),(151,118),(132,95)])
    # Small slippers are colourable, with 12px interiors.
    cr(im,(84,145,106,164),6);cr(im,(120,145,142,164),6)
    cp(im,[(97,77),(129,77),(137,106),(155,144),(143,151),(83,151),(73,144),(91,106)])
    cl(im,(94,110),(134,110));cl(im,(103,112),(94,149));cl(im,(124,112),(133,149))
    # Puff sleeves are large enough to touch at 3x scale.
    ce(im,(76,75,98,97));ce(im,(124,75,146,97))
    cp(im,[(100,76),(126,76),(123,93),(104,93)])
    ce(im,(91,31,140,79))
    cp(im,[(90,48),(91,32),(101,23),(122,23),(139,34),(142,49),(130,43),(120,35),(111,43),(102,39),(97,49)])
    ceye(im,102,53);ceye(im,126,53);csmile(im,115,66)
    cp(im,[(97,27),(94,9),(107,16),(115,5),(124,16),(137,9),(133,27)])
    # Braid outline is one connected shape; cross-lines are shared boundaries.
    cp(im,[(137,63),(154,67),(157,79),(153,91),(157,103),(153,115),(157,128),(150,142),(139,132),(138,116),(137,100),(137,83),(130,75),(134,70)])
    for y in (81,98,115):cl(im,(139,y),(154,y+3))
    # Kitten: curved tail, broad head, ear triangles, bib and soft paws.
    cp(im,[(263,118),(281,112),(288,99),(284,87),(277,89),(276,101),(270,105),(258,106)])
    ce(im,(202,103,270,157));ce(im,(219,117,251,151))
    cp(im,[(203,85),(200,61),(218,73),(247,73),(266,61),(264,87)])
    ce(im,(199,76,268,121))
    # Inner ears are solid decorative triangles, avoiding tiny fill pockets.
    im.poly([(205,69),(207,79),(215,76)],'black');im.poly([(261,69),(259,79),(251,76)],'black')
    ceye(im,216,92);ceye(im,246,92)
    im.poly([(229,102),(239,102),(234,108)],'black');csmile(im,234,110)
    for x,sg in ((206,-1),(260,1)):
        cl(im,(x,105),(x+sg*12,102));cl(im,(x,111),(x+sg*12,114))
    ce(im,(201,144,224,161));ce(im,(249,144,272,161))
    cflower(im,30,43);cflower(im,36,115);cflower(im,292,119)
    cbutterfly(im,237,23)
    # Close diagonal joins at the fringe, crown, braid and curled tail.
    for x,y in ((101,39),(107,15),(138,82),(275,101)):im.put(x,y,'black')
    return im

def colouring_three():
    im=Canvas(320,168,'paper')
    # Pony seen in three-quarter profile, with a round muzzle and flowing mane.
    cp(im,[(219,91),(238,82),(252,88),(259,105),(252,125),(246,142),(229,144),(236,123),(242,108),(234,102),(220,109)])
    cl(im,(246,91),(250,108));cl(im,(250,108),(239,140))
    for x in (144,180):
        cp(im,[(x,112),(x+16,112),(x+14,153),(x-2,153)])
        cl(im,(x-1,139),(x+14,139))
    ce(im,(110,81,234,129))
    for x in (120,199):
        cp(im,[(x,111),(x+20,112),(x+17,158),(x-3,158)])
        cl(im,(x-1,143),(x+17,143))
    # Head and body overlap naturally beneath the mane.
    cp(im,[(105,58),(102,28),(118,35),(127,53)])
    cp(im,[(139,49),(149,25),(161,31),(159,62)])
    ce(im,(91,52,160,103))
    cp(im,[(109,53),(114,38),(137,35),(159,42),(173,58),(177,80),(173,101),(181,117),(164,124),(149,112),(151,91),(155,73),(145,60),(133,54),(120,65)])
    cl(im,(151,45),(165,63));cl(im,(165,63),(166,98));cl(im,(166,98),(172,119))
    ce(im,(85,83,139,113));ceye(im,105,70);ceye(im,138,68)
    im.ellipse(97,92,101,95,'black');im.ellipse(123,92,127,95,'black');csmile(im,112,102)
    # A flower ornament sits completely inside the broad mane.
    # Two leaves and a flower make each meadow cluster easy to colour.
    cflower(im,31,114);cflower(im,285,112)
    cbutterfly(im,41,28);cbutterfly(im,216,27);cbutterfly(im,283,49)
    ccloud(im,69,6,48)
    for x,y in [(65,137),(81,150),(251,151)]:ce(im,(x,y,x+15,y+15))
    return im

def solidify_stroke_pockets(im):
    """Fill only <=8px pockets at intersecting strokes, like solid eye marks."""
    for area,b in regions(im):
        if area<=8:
            for y in range(b[1],b[3]+1):
                for x in range(b[0],b[2]+1):
                    if im.get(x,y)==C['paper']:im.put(x,y,'black')

def make_colouring():
    for i,fn in enumerate((colouring_one,colouring_two,colouring_three),1):
        im=fn();solidify_stroke_pockets(im);im.rect(0,0,319,1,'black');im.rect(0,166,319,167,'black');im.rect(0,0,1,167,'black');im.rect(318,0,319,167,'black');save(f'paint_{i}.png',im,'pictures',True)

def regions(im,diagonal=False):
    seen=set();out=[]
    offsets=[(-1,0),(1,0),(0,-1),(0,1)]
    if diagonal:offsets += [(-1,-1),(-1,1),(1,-1),(1,1)]
    for y in range(im.h):
        for x in range(im.w):
            if (x,y) in seen or im.get(x,y)!=C['paper']:continue
            stack=[(x,y)];seen.add((x,y));pts=[]
            while stack:
                px,py=stack.pop();pts.append((px,py))
                for dx,dy in offsets:
                    q=(px+dx,py+dy)
                    if q not in seen and 0<=q[0]<im.w and 0<=q[1]<im.h and im.get(*q)==C['paper']:
                        seen.add(q);stack.append(q)
            out.append((len(pts),(min(p[0] for p in pts),min(p[1] for p in pts),max(p[0] for p in pts),max(p[1] for p in pts))))
    return out

# A separate contract, so a mistake at a drawing call cannot redefine the size.
def contract():
    ex={}
    def add(n,w,h):ex[n+'.png']=(w,h)
    for d in ('down','up','left','right'):
        for f in (0,1):add(f'kira_td_{d}_{f}',16,24)
    for f in range(3):add(f'kira_face_{f}',28,28);add(f'kira_big_{f}',64,96)
    for n in FRIENDS:
        for f in (0,1):add(f'{n}_fp_{f}',48,48);add(f'{n}_td_{f}',16,16)
        add(f'{n}_icon',20,20)
    for n in ('stone','window','banner','shelf','hedge','roses'):
        add(f'wall_{n}_fp',64,64);add(f'wall_{n}_td',16,16)
    for n in ('castle','carpet','grass','path','water'):add(f'floor_{n}_fp',32,32);add(f'floor_{n}_td',16,16)
    add('ceil_castle_fp',32,32)
    for n,w,h in [('tree',64,112),('bush',48,32),('fountain',64,56),('bed',64,48),('table',48,48),('throne',48,72),('chest',40,32),('picnic',64,20)]:
        add(n+'_fp',w,h);add(n+'_td',16,24 if n in ('tree','throne') else 16)
    for n,w,h in [('heart',9,9),('star',9,9),('note',9,12)]:
        for f in (0,1):add(f'{n}_{f}',w,h)
    for c in 'abc':
        for f in (0,1):add(f'butterfly_{c}_{f}',16,12)
    add('cursor',16,16);add('select',28,28)
    for n in range(1,8):add(f'num_{n}',24,32)
    for n in FRIENDS+['picnic']:add('word_'+n,text_width('PICNIC TIME!' if n=='picnic' else n.upper(),2)+12,24)
    add('word_hooray',136,32);add('bar',320,32)
    for n in ('home','eyes','map','tulip','daisy','sunflower','rose','can','next','song'):add('icon_'+n,24,24)
    for n in range(10):add(f'pot_{n}',20,24)
    for k in ('tulip','daisy','sunflower','rose'):
        for n in (1,2,3):add(f'plant_{k}_{n}',32,48)
    add('drop',7,9)
    for n in ('menu','garden','music','paint_1','paint_2','paint_3'):add(n,320,168)
    for i in range(8):add(f'xylo_hit_{i}',30,97-6*i)
    return ex

def decode_png(path):
    b=path.read_bytes();assert b[:8]==b'\x89PNG\r\n\x1a\n';pos=8;data=b'';wh=None
    while pos<len(b):
        size=struct.unpack('>I',b[pos:pos+4])[0];typ=b[pos+4:pos+8];payload=b[pos+8:pos+8+size];crc=struct.unpack('>I',b[pos+8+size:pos+12+size])[0]
        assert zlib.crc32(typ+payload)&0xffffffff==crc,(path,'CRC')
        if typ==b'IHDR':
            w,h,depth,mode,comp,filt,inter=struct.unpack('>IIBBBBB',payload);assert (depth,mode,comp,filt,inter)==(8,6,0,0,0);wh=(w,h)
        if typ==b'IDAT':data+=payload
        pos+=12+size
    w,h=wh;raw=zlib.decompress(data);assert len(raw)==h*(1+4*w)
    im=Canvas(w,h);pool={}
    for y in range(h):
        off=y*(1+4*w);assert raw[off]==0
        row=[tuple(raw[off+1+4*x:off+5+4*x]) for x in range(w)]
        im.p[y*w:(y+1)*w]=[pool.setdefault(c,c) for c in row]
    return im

def contact_sheets():
    for group in ('sprites','world','pictures'):
        names=[n for n in ART if GROUP[n]==group]
        # All artwork is at 3x. Sprite entries show both requested grounds.
        columns=2 if group=='pictures' else 4
        cellw=980 if group=='pictures' else (450 if group=='sprites' else 400)
        rows=[]
        for start in range(0,len(names),columns):
            row=names[start:start+columns]
            rh=max(ART[n].h*3+(48 if group=='sprites' else 38) for n in row)
            # Very wide labels and bar receive a separate full-width row.
            rows.append((row,rh))
        if group=='sprites':
            wide=[n for n in names if ART[n].w*6+18>cellw]
            names=[n for n in names if n not in wide];rows=[]
            for st in range(0,len(names),columns):
                row=names[st:st+columns];rows.append((row,max(ART[n].h*3+48 for n in row)))
            rows += [([n],ART[n].h*3+48) for n in wide]
        sheet=Canvas(max(columns*cellw,1944 if group=='sprites' else 0),sum(h for _,h in rows)+16,'cream_light');y=8
        for row,rh in rows:
            for j,n in enumerate(row):
                im=ART[n];x=j*cellw+8
                lettering(sheet,n,x,y,1,'ink')
                grounds=['green_shadow','cream'] if group=='sprites' or n not in OPAQUE else ['cream']
                for g,bg in enumerate(grounds):
                    xx=x+g*(im.w*3+8);yy=y+18
                    sheet.rect(xx,yy,xx+im.w*3-1,yy+im.h*3-1,bg);sheet.paste(im,xx,yy,3)
            y+=rh
        # Contact sheets are presentation canvases, not game sprites.
        (OUT/f'sheet_{group}.png').write_bytes(sheet.png())

def verify():
    ex=contract();assert set(ART)==set(ex),(set(ex)-set(ART),set(ART)-set(ex))
    master=set();total=0
    for n,(w,h) in ex.items():
        im=decode_png(OUT/n);assert (im.w,im.h)==(w,h),(n,'size')
        assert im.p==ART[n].p,(n,'PNG round trip')
        assert all(p[3] in (0,255) for p in im.p),(n,'alpha')
        opaque={p for p in im.p if p[3]}
        if not n.startswith('paint_'):
            master|=opaque
            assert C['black'] not in opaque and C['paper'] not in opaque,(n,'reserved colouring colours')
        if n in OPAQUE:assert all(p[3]==255 for p in im.p),(n,'opacity')
        else:assert any(p[3]==0 for p in im.p),(n,'transparent surround')
        if n in ANCHOR:assert any(im.get(x,h-1)[3] for x in range(w)),(n,'bottom anchor')
        if n in ('menu.png','garden.png','music.png'):assert len(opaque)<=48,(n,len(opaque))
        if n.startswith('word_'):
            assert w<= (200 if n=='word_picnic.png' else 160 if n=='word_hooray.png' else 120)
        total+=w*h
    # The picture contact sheet reproduces the colouring pages as well.
    master|={C['black'],C['paper']}
    assert len(master)<=200,len(master)
    pal=decode_png(OUT/'palette.png');assert {p for p in pal.p if p[3]}==master
    assert pal.w==16 and pal.h==(len(master)+15)//16
    assert sum(p[3]==255 for p in pal.p)==len(master)
    for group in ('sprites','world','pictures'):
        sheet=decode_png(OUT/f'sheet_{group}.png')
        assert all(p[3]==255 and p in master for p in sheet.p),(group,'sheet palette/alpha')
    assert {p.name for p in OUT.glob('*.png')}==set(ex)|{'palette.png','sheet_sprites.png','sheet_world.png','sheet_pictures.png'},'PNG filename manifest'
    # Exact menu panel masks, including 2px border and rounded corners.
    assert BUTTONS==[(8,48,155,103),(164,48,311,103),(8,108,155,163),(164,108,311,163)]
    menu=ART['menu.png']
    for b in BUTTONS:
        m=Canvas(320,168);R(m,b,'cream_light','violet_dark',7,2)
        for y in range(b[1],b[3]+1):
            for x in range(b[0],b[2]+1):
                if m.get(x,y)==C['violet_dark']:assert menu.get(x,y)==C['violet_dark'],('button frame',b,x,y)
    garden=ART['garden.png'];expected_soil=set()
    for x,y in SOILS:
        m=Canvas(320,168);m.ellipse(x-20,y-7,x+19,y+6,'soil')
        pixels={(xx,yy) for yy in range(y-7,y+7) for xx in range(x-20,x+20) if m.get(xx,yy)==C['soil']}
        expected_soil|=pixels
        assert (max(p[0] for p in pixels)-min(p[0] for p in pixels)+1,max(p[1] for p in pixels)-min(p[1] for p in pixels)+1)==(40,14)
    assert {(x,y) for y in range(168) for x in range(320) if garden.get(x,y)==C['soil']}==expected_soil
    for i,(x0,y0,x1,y1) in enumerate(BARS):
        expected=xylo_bar(i);assert ART['music.png'].crop(x0,y0,x1-x0+1,y1-y0+1).p==expected.p,('bar',i)
        assert (ART[f'xylo_hit_{i}.png'].w,ART[f'xylo_hit_{i}.png'].h)==(x1-x0+1,y1-y0+1)
    cursor=ART['cursor.png'];assert cursor.get(3,1)[3] and not any(cursor.get(x,0)[3] for x in range(16))
    sel=ART['select.png'];assert all(sel.get(x,y)[3]==0 for y in range(3,25) for x in range(3,25))
    for k in ('tulip','daisy','sunflower','rose'):
        for stage in (1,2,3):assert ART[f'plant_{k}_{stage}.png'].get(15,47)[3]
    counts=[]
    for i in range(1,4):
        n=f'paint_{i}.png';im=ART[n];assert set(im.p)=={C['black'],C['paper']}
        for y in range(im.h):
            for x in range(im.w):
                if x<2 or x>=318 or y<2 or y>=166:assert im.get(x,y)==C['black']
        rs=regions(im);assert 25<=len(rs)<=60,(n,'region count',len(rs))
        assert len(rs)==(33,37,38)[i-1],(n,'changed region topology',len(rs))
        assert len(regions(im,diagonal=True))==len(rs),(n,'diagonal outline gap')
        tiny=[(area,b) for area,b in rs if b[2]-b[0]+1<10 or b[3]-b[1]+1<10 or area<65]
        assert not tiny,(n,'small regions',tiny)
        assert all(2<=b[0]<=b[2]<=317 and 2<=b[1]<=b[3]<=165 for _,b in rs),(n,'open region')
        counts.append(len(rs))
    # Every animation actually changes, with a fixed canvas and bottom anchor.
    for n in ART:
        if n.endswith('_0.png') and n.replace('_0.png','_1.png') in ART:
            other=ART[n.replace('_0.png','_1.png')];assert ART[n].p!=other.p,(n,'identical frames')
    print(f'Verified {len(ex)} game PNGs: RGBA8, exact sizes, binary alpha; {total:,} native pixels.')
    print(f'Master palette: {len(master)}/200 opaque colours. Picture colours: '+', '.join(f'{n}: {len(set(ART[n+".png"].p))}/48' for n in ('menu','garden','music'))+'.')
    print('Fixed geometry: 4 menu frames, 12 soil ellipses, 8 xylophone rectangles and hit overlays; cursor, selection, and plant anchors passed.')
    print('Colouring pages (four- and eight-neighbour fill checked): '+', '.join(f'paint_{i+1}: {n} closed white regions' for i,n in enumerate(counts))+'. Pure black/white and 2px page frames passed.')
    print('Three contact sheets at 3x; sprite entries on green and cream. Palette written with 16 swatches per row.')
    print('Deterministic PNG SHA-256: '+hashlib.sha256(b''.join((OUT/n).read_bytes() for n in sorted(ex))).hexdigest())

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    make_kira();make_friends();make_textures();make_props();make_small();make_pictures();make_colouring()
    for n,im in ART.items():(OUT/n).write_bytes(im.png())
    colors=sorted({p for im in ART.values() for p in im.p if p[3]})
    pal=Canvas(16,(len(colors)+15)//16)
    for i,c in enumerate(colors):pal.put(i%16,i//16,c)
    (OUT/'palette.png').write_bytes(pal.png())
    contact_sheets();verify()

if __name__=='__main__':main()
