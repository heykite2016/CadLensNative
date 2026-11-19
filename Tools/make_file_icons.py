#!/usr/bin/env python3
"""Draw macOS document icons for .dwg / .dxf in the selected '取景框' family."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from pathlib import Path
import subprocess, shutil

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Resources'
FONT = str(ROOT / 'Resources/fonts/osifont-lgpl3fe.ttf')

def rgba(h, a=255):
    h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))+(a,)

def font(size): return ImageFont.truetype(FONT, size)

def grad(size, top, bottom):
    w,h=size; im=Image.new('RGBA',(1,h))
    for y in range(h):
        t=y/max(1,h-1)
        im.putpixel((0,y), tuple(int(top[i]*(1-t)+bottom[i]*t) for i in range(4)))
    return im.resize((w,h), Image.Resampling.BILINEAR)

def page_shadow(S, box, radius=38):
    sh=Image.new('RGBA',(S,S),(0,0,0,0)); d=ImageDraw.Draw(sh)
    d.rounded_rectangle((box[0]+8,box[1]+18,box[2]+8,box[3]+18),radius=radius,fill=(0,0,0,95))
    return sh.filter(ImageFilter.GaussianBlur(26))

def page_base(S, dark):
    box=(150,55,874,969); radius=38; fold=132
    out=Image.new('RGBA',(S,S),(0,0,0,0)); out.alpha_composite(page_shadow(S,box))
    mask=Image.new('L',(S,S),0); md=ImageDraw.Draw(mask)
    md.rounded_rectangle(box,radius=radius,fill=255)
    if dark:
        paper=grad((box[2]-box[0],box[3]-box[1]),rgba('#111A24'),rgba('#070A0F'))
    else:
        paper=grad((box[2]-box[0],box[3]-box[1]),rgba('#FFFFFF'),rgba('#EEF3F8'))
    out.paste(paper,(box[0],box[1]),mask.crop(box))
    d=ImageDraw.Draw(out)
    # folded corner
    p=(box[2]-fold,box[1],box[2],box[1]+fold)
    d.polygon([(p[0],p[1]),(p[2],p[1]),(p[2],p[3])],
              fill=rgba('#1D2A36') if dark else rgba('#D7E2EC'))
    d.line([(p[0],p[1]),(p[2],p[3])], fill=rgba('#FFFFFF',60) if dark else rgba('#9CB0C4'), width=5)
    # faint grid
    gcol=rgba('#FFFFFF',12) if dark else rgba('#163A6B',14)
    for x in range(box[0]+52, box[2]-40, 58):
        d.line([(x,box[1]+40),(x,box[3]-40)],fill=gcol,width=2)
    for y in range(box[1]+52, box[3]-40, 58):
        d.line([(box[0]+40,y),(box[2]-40,y)],fill=gcol,width=2)
    d.rounded_rectangle(box,radius=radius,outline=rgba('#FFFFFF',90) if dark else rgba('#163A6B',35),width=4)
    return out,d,box

def bracket(d, box, ink, accent):
    x0,y0,x1,y1=box; w=x1-x0; h=y1-y0
    L=int(min(w,h)*0.22); t=12
    for cx,cy,sx,sy in ((x0,y0,1,1),(x1,y0,-1,1),(x0,y1,1,-1),(x1,y1,-1,-1)):
        d.line([(cx,cy),(cx+sx*L,cy)],fill=ink,width=t)
        d.line([(cx,cy),(cx,cy+sy*L)],fill=ink,width=t)

def plan(d, box, ink, accent):
    x0,y0,x1,y1=box
    wall=18
    d.rectangle([x0+wall/2,y0+wall/2,x1-wall/2,y1-wall/2],outline=ink,width=wall)
    px=x0+(x1-x0)*0.56
    d.line([(px,y0+wall/2),(px,y0+(y1-y0)*0.34)],fill=ink,width=12)
    d.line([(px,y0+(y1-y0)*0.62),(px,y1-wall/2)],fill=ink,width=12)
    # door swing
    d.arc([px-10,y0+(y1-y0)*0.34,px+130,y0+(y1-y0)*0.34+140],start=270,end=360,fill=accent,width=7)

def dimension(d, x0,x1,y,color):
    d.line([(x0,y),(x1,y)],fill=color,width=10)
    for x in (x0,x1):
        d.line([(x,y-30),(x,y+30)],fill=color,width=9)
    d.polygon([(x0,y),(x0+40,y-20),(x0+40,y+20)],fill=color)
    d.polygon([(x1,y),(x1-40,y-20),(x1-40,y+20)],fill=color)

def make(kind):
    S=1024; dark = kind=='DWG'
    out,d,box=page_base(S,dark)
    ink=rgba('#F4F8FF') if dark else rgba('#0E2A4A')
    accent=rgba('#37D67A')
    # content frame and B-family viewfinder brackets
    bracket(d,(252,185,772,690),rgba('#7CF0C0') if dark else rgba('#163A6B'),accent)
    plan(d,(330,250,694,555),ink,accent)
    dimension(d,330,694,635,accent)
    # extension label
    f=font(150)
    text=kind
    tw=d.textlength(text,font=f)
    d.text(((S-tw)/2,730),text,font=f,fill=ink)
    # small product line
    f2=font(34)
    sub='CAD DRAWING'
    tw2=d.textlength(sub,font=f2)
    d.text(((S-tw2)/2,905),sub,font=f2,fill=rgba('#B9C8D8') if dark else rgba('#52667E'))
    # accent bar
    d.rounded_rectangle([150,942,874,966],radius=12,fill=accent)
    return out

for kind in ('DWG','DXF'):
    im=make(kind)
    im.save(OUT/f'{kind}FileIcon-1024.png')
    iconset=OUT/f'{kind}FileIcon.iconset'
    if iconset.exists(): shutil.rmtree(iconset)
    iconset.mkdir()
    master=OUT/f'{kind}FileIcon-1024.png'
    for sz,name in [(16,'icon_16x16'),(32,'icon_16x16@2x'),(32,'icon_32x32'),(64,'icon_32x32@2x'),(128,'icon_128x128'),(256,'icon_128x128@2x'),(256,'icon_256x256'),(512,'icon_256x256@2x'),(512,'icon_512x512'),(1024,'icon_512x512@2x')]:
        subprocess.run(['sips','-z',str(sz),str(sz),str(master),'--out',str(iconset/f'{name}.png')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(OUT/f'{kind}FileIcon.icns')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    shutil.rmtree(iconset)
    print('wrote',kind)
