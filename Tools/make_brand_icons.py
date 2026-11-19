from PIL import Image, ImageDraw, ImageFilter, ImageFont
from pathlib import Path
import math, subprocess, shutil, os

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Resources' / 'Brand'
OUT.mkdir(parents=True, exist_ok=True)
FONT_CN = str(ROOT / 'Resources/fonts/NotoSansCJKsc-Regular.otf')
FONT_LAT = str(ROOT / 'Resources/fonts/osifont-lgpl3fe.ttf')

def rgba(hexstr, a=255):
    h=hexstr.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))+(a,)

def font_cn(size):
    return ImageFont.truetype(FONT_CN, size)
def font_lat(size):
    return ImageFont.truetype(FONT_LAT, size)

def vgrad(size, top, bottom):
    w,h=size
    im=Image.new('RGBA',(1,h))
    for y in range(h):
        t=y/max(1,h-1)
        im.putpixel((0,y), tuple(int(top[i]*(1-t)+bottom[i]*t) for i in range(4)))
    return im.resize((w,h), Image.Resampling.BILINEAR)

def rounded_mask(size, box, radius):
    m=Image.new('L',size,0)
    d=ImageDraw.Draw(m)
    d.rounded_rectangle(box, radius=radius, fill=255)
    return m

def shadow(size, box, radius, blur=54, offset=(0,18), alpha=120):
    sh=Image.new('RGBA',(size[0],size[1]), (0,0,0,0))
    d=ImageDraw.Draw(sh)
    b=(box[0]+offset[0],box[1]+offset[1],box[2]+offset[0],box[3]+offset[1])
    d.rounded_rectangle(b, radius=radius, fill=(0,0,0,alpha))
    return sh.filter(ImageFilter.GaussianBlur(blur))

def draw_grid(d, box, step, color):
    x=box[0]
    while x<box[2]:
        d.line([(x,box[1]),(x,box[3])], fill=color, width=2)
        x+=step
    y=box[1]
    while y<box[3]:
        d.line([(box[0],y),(box[2],y)], fill=color, width=2)
        y+=step

def arrow(d, tip, back, width, color, head=30):
    # tip points; back is the other end direction
    dx,dy=back
    L=math.hypot(dx,dy) or 1
    ux,uy=dx/L,dy/L
    # line from tip backwards
    start=(tip[0]+ux*L, tip[1]+uy*L)
    d.line([start,tip], fill=color, width=width)
    nx,ny=-uy,ux
    d.polygon([tip, (tip[0]+ux*head+nx*head*0.55, tip[1]+uy*head+ny*head*0.55),
               (tip[0]+ux*head-nx*head*0.55, tip[1]+uy*head-ny*head*0.55)], fill=color)

def dimension(d, x0, x1, y, color, width=10, tick=34, arrowhead=34):
    d.line([(x0,y),(x0,y-tick),(x0,y+tick)], fill=color, width=width)
    d.line([(x1,y),(x1,y-tick),(x1,y+tick)], fill=color, width=width)
    d.line([(x0+2,y),(x1-2,y)], fill=color, width=width)
    d.polygon([(x0,y),(x0+arrowhead,y-arrowhead*0.55),(x0+arrowhead,y+arrowhead*0.55)], fill=color)
    d.polygon([(x1,y),(x1-arrowhead,y-arrowhead*0.55),(x1-arrowhead,y+arrowhead*0.55)], fill=color)

def plan(d, box, wall_color, detail_color, wall=34, door=True):
    x0,y0,x1,y1=box
    d.rectangle([x0+wall/2,y0+wall/2,x1-wall/2,y1-wall/2], outline=wall_color, width=wall)
    px=x0+(x1-x0)*0.56
    gap0=y0+(y1-y0)*0.32; gap1=y0+(y1-y0)*0.60
    d.line([(px,y0+wall/2),(px,gap0)], fill=wall_color, width=int(wall*0.68))
    d.line([(px,gap1),(px,y1-wall/2)], fill=wall_color, width=int(wall*0.68))
    if door:
        # leaf and swing
        d.line([(px,gap1),(px+(gap1-gap0),gap1)], fill=detail_color, width=max(4,int(wall*0.45)))
        bb=[px, gap0, px+(gap1-gap0)*2, gap1+(gap1-gap0)]
        d.arc(bb, start=270, end=360, fill=detail_color, width=8)

def mark_plan(d, box, ink, accent, scale=1.0):
    x0,y0,x1,y1=box
    w=x1-x0; h=y1-y0
    plan(d,(x0,y0,x1,y1-w*0.12), ink, ink,
         wall=max(6,int(w*0.055*scale)))
    dimension(d, x0, x1, y1-w*0.04, accent,
              width=max(4,int(w*0.03*scale)), tick=int(w*0.07*scale),
              arrowhead=int(w*0.075*scale))

def mark_brackets(d, box, ink, accent):
    x0,y0,x1,y1=box; w=x1-x0; h=y1-y0
    L=int(min(w,h)*0.22); t=max(8,int(min(w,h)*0.035))
    for (cx,cy,sx,sy) in [(x0,y0,1,1),(x1,y0,-1,1),(x0,y1,1,-1),(x1,y1,-1,-1)]:
        d.line([(cx,cy),(cx+sx*L,cy)], fill=ink, width=t)
        d.line([(cx,cy),(cx,cy+sy*L)], fill=ink, width=t)
    # room fragment
    r=[x0+w*0.22,y0+h*0.25,x1-w*0.22,y1-h*0.22]
    plan(d,r,ink,ink,wall=max(8,int(w*0.035)),door=False)
    dimension(d, r[0], r[2], r[3]+h*0.10, accent, width=max(5,int(w*0.022)), tick=int(h*0.05), arrowhead=int(w*0.055))

def mark_arc(d, box, ink, accent):
    x0,y0,x1,y1=box; w=x1-x0; h=y1-y0
    t=max(10,int(w*0.075))
    cx=x0+t/2; cy=y1-t/2
    # L 形角尺：竖边 + 横边交于左下角。
    d.line([(cx,y0),(cx,cy)], fill=ink, width=t)
    d.line([(x0,cy),(x1-t*0.2,cy)], fill=ink, width=t)
    r=min(w,h)*0.74
    # 以角尺交点为圆心的四分之一圆弧，从正上方到正右方。
    d.arc([cx-r,cy-r,cx+r,cy+r], start=270, end=360, fill=accent,
          width=max(8,int(w*0.035)))
    d.line([(cx,cy),(cx+r,cy)], fill=accent, width=max(6,int(w*0.026)))
    rr=max(6,int(w*0.032))
    d.ellipse([cx-rr,cy-rr,cx+rr,cy+rr], fill=accent)
    # 右上角的小平面索引块，让“图纸”语义更明确。
    rw=int(w*0.24); rh=int(h*0.18)
    rx=x1-rw; ry=y0+int(h*0.08)
    d.rectangle([rx,ry,rx+rw,ry+rh], outline=rgba('#FFFFFF' if ink[0]>128 else '#163A6B',150), width=max(3,int(w*0.009)))
    d.line([(rx+rw*0.25,ry+rh*0.75),(rx+rw*0.75,ry+rh*0.25)], fill=rgba('#FFFFFF' if ink[0]>128 else '#163A6B',120), width=max(3,int(w*0.008)))

def mark_stack(d, box, paper, ink, accent):
    x0,y0,x1,y1=box; w=x1-x0; h=y1-y0
    # 三张错开的图纸，前一张才是内容；后面两张只露边。
    for i, (dx,dy) in enumerate(((int(w*0.10),int(h*0.12)),
                                  (int(w*0.05),int(h*0.06)), (0,0))):
        r=[x0+dx,y0+dy,x1-w*0.10+dx,y1-h*0.10+dy]
        fill=rgba('#FFFFFF', 16 if i<2 else 34)
        d.rounded_rectangle(r, radius=int(w*0.035), fill=fill,
                            outline=rgba('#FFFFFF', 120 if i<2 else 230), width=max(5,int(w*0.018)))
    front=[x0,y0,x1-w*0.10,y1-h*0.10]
    inner=[front[0]+w*0.12,front[1]+h*0.14,front[2]-w*0.12,front[3]-h*0.18]
    plan(d,inner,ink,ink,wall=max(5,int(w*0.018)),door=False)
    dimension(d, inner[0], inner[2], front[3]-h*0.06, accent,
              width=max(4,int(w*0.016)), tick=int(h*0.04), arrowhead=int(w*0.04))

CONCEPTS = {
 'a': dict(name='蓝图视界', en='BLUEPRINT', bg=('#163A63','#061426'), ink='#F2F7FF', accent='#37D67A', cyan='#4CC9F0', light=False),
 'b': dict(name='取景框', en='FOCUS FRAME', bg=('#161C26','#070A10'), ink='#E9FFF6', accent='#37D67A', cyan='#7CF0C0', light=False),
 'c': dict(name='量角弧', en='PRECISION ARC', bg=('#FBF7EC','#E7DECA'), ink='#163A6B', accent='#2F9E63', cyan='#2F6FDB', light=True),
 'd': dict(name='层叠图纸', en='SHEET STACK', bg=('#0E4A55','#05272E'), ink='#E8FBFF', accent='#63E6BE', cyan='#65D6FF', light=False),
}

def icon_body(c, body, bg=None):
    top=rgba(c['bg'][0]); bot=rgba(c['bg'][1])
    g=vgrad((body[2]-body[0],body[3]-body[1]), top, bot)
    card=Image.new('RGBA',(body[2]-body[0],body[3]-body[1]),(0,0,0,0))
    card.paste(g,(0,0))
    d=ImageDraw.Draw(card)
    if c['light']:
        draw_grid(d,(0,0,card.width,card.height),88, rgba('#163A6B',20))
    else:
        draw_grid(d,(0,0,card.width,card.height),92, rgba('#FFFFFF',14))
    return card

def make_app_icon(key):
    c=CONCEPTS[key]; S=2048; margin=170; body=(margin,margin,S-margin,S-margin)
    rad=int((body[2]-body[0])*0.2237)
    out=Image.new('RGBA',(S,S),(0,0,0,0))
    out.alpha_composite(shadow((S,S),body,rad,blur=58,offset=(0,22),alpha=110))
    mask=rounded_mask((S,S),body,rad)
    card=icon_body(c,body)
    out.paste(card,(body[0],body[1]),mask.crop((body[0],body[1],body[2],body[3])))
    d=ImageDraw.Draw(out)
    box=(440,460,1608,1500)
    if key=='a':
        draw_grid(d,body,184,rgba('#FFFFFF',10))
        mark_plan(d,(470,470,1570,1370),rgba(c['ink']),rgba(c['accent']))
    elif key=='b':
        # glow
        glow=Image.new('RGBA',(S,S),(0,0,0,0)); gd=ImageDraw.Draw(glow)
        gd.ellipse([500,500,1550,1550], fill=rgba(c['cyan'],28))
        glow=glow.filter(ImageFilter.GaussianBlur(110))
        out.alpha_composite(glow)
        d=ImageDraw.Draw(out)
        mark_brackets(d,(430,430,1618,1470),rgba(c['ink']),rgba(c['accent']))
    elif key=='c':
        mark_arc(d,(390,470,1630,1510),rgba(c['ink']),rgba(c['accent']))
    else:
        mark_stack(d,(400,430,1620,1480),rgba('#FFFFFF',230),rgba(c['ink']),rgba(c['accent']))
    # inner border highlight
    d.rounded_rectangle([body[0]+3,body[1]+3,body[2]-3,body[3]-3], radius=rad-2,
                        outline=rgba('#FFFFFF',80 if not c['light'] else 130), width=4)
    return out.resize((1024,1024), Image.Resampling.LANCZOS)

def make_package_icon(key):
    c=CONCEPTS[key]; S=2048
    out=Image.new('RGBA',(S,S),(0,0,0,0))
    cx=S//2
    # ground shadow
    sh=Image.new('RGBA',(S,S),(0,0,0,0)); sd=ImageDraw.Draw(sh)
    sd.ellipse([300,1550,1750,1800], fill=(0,0,0,100))
    out.alpha_composite(sh.filter(ImageFilter.GaussianBlur(50)))
    d=ImageDraw.Draw(out)

    # Clean software box: no loose sheet, so the silhouette stays readable at 16 px.
    # Soft, front-facing software box with a shallow isometric top/side.
    left,right=250,1660
    top,mid,bottom=620,760,1480
    radius=54
    top_col=tuple(min(255,int(v*1.32)) for v in rgba(c['bg'][0])[:3])+(255,)
    side_col=tuple(int(v*0.62) for v in rgba(c['bg'][0])[:3])+(255,)
    front_col=tuple(int(v*1.05) for v in rgba(c['bg'][1])[:3])+(255,)
    d.polygon([(left,top),(left+150,470),(right+80,470),(right,top)], fill=top_col)
    d.polygon([(right,top),(right+80,470),(right+80,1320),(right,bottom)], fill=side_col)
    d.rounded_rectangle([left,top,right,bottom], radius=radius, fill=front_col,
                        outline=rgba('#FFFFFF',80), width=5)
    d.line([(left+radius,top),(right-radius,top)], fill=rgba('#FFFFFF',90), width=4)

    # Front label plate.
    lab=(360,690,1550,1220)
    label_fill = '#F7FAFF' if key in ('a','c') else '#0B1118'
    label_outline = rgba('#FFFFFF',110) if key in ('b','d') else rgba('#163A6B',50)
    d.rounded_rectangle(lab, radius=34, fill=rgba(label_fill), outline=label_outline, width=5)
    ink = rgba('#12345A') if key in ('a','c') else rgba('#E9FFF6')
    accent = rgba(c['accent'])

    # Concept mark on the label.
    mbox=(430,730,1480,1050)
    if key=='a':
        mark_plan(d,mbox,ink,accent,scale=0.55)
    elif key=='b':
        mark_brackets(d,mbox,ink,accent)
    elif key=='c':
        mark_arc(d,mbox,ink,accent)
    else:
        mark_stack(d,mbox,rgba('#FFFFFF',230),ink,accent)

    # Product wordmark on the package.
    f=font_lat(108)
    label='CadLens'
    tw=d.textlength(label,font=f)
    d.text((cx-tw/2,1060), label, font=f, fill=ink)
    f2=font_cn(44)
    sub='CAD VIEWER'
    tw2=d.textlength(sub,font=f2)
    d.text((cx-tw2/2,1160), sub, font=f2, fill=ink[:3]+(170,))

    # Green measuring tape across the top edge: the brand's measurement cue.
    d.line([(left+40,top+18),(right-40,top+18)], fill=accent, width=16)
    for x in (left+40,right-40):
        d.line([(x,top-10),(x,top+46)], fill=accent, width=12)
    # A small tape seal on the side.
    d.rounded_rectangle([right+8,860,right+62,980], radius=14, fill=accent)
    d.line([(right+34,880),(right+34,960)], fill=rgba('#0B1524',200), width=5)
    return out.resize((1024,1024), Image.Resampling.LANCZOS)

def make_logo(key, dark=True):
    c=CONCEPTS[key]; W,H=2400,700
    out=Image.new('RGBA',(W,H),(0,0,0,0)); d=ImageDraw.Draw(out)
    ink=rgba('#F4F8FF') if dark else rgba('#12243B')
    muted=(ink[:3]+(180,)) if dark else rgba('#52667E')
    accent=rgba(c['accent'])
    cad=rgba(c['cyan']) if dark else rgba(c['cyan'])
    # mark tile
    mbox=(80,70,650,640); rad=120
    # The mark tile keeps the brand colour in both variants; only the wordmark
    # switches to dark ink for light backgrounds.
    tile=rgba(c['bg'][0],255) if not c['light'] else rgba('#FBF7EC',255)
    border=rgba('#FFFFFF',70) if dark else rgba('#163A6B',45)
    d.rounded_rectangle(mbox, radius=rad, fill=tile, outline=border, width=4)
    if key=='a':
        mark_plan(d,(145,150,585,555),rgba(c['ink']),accent)
    elif key=='b':
        mark_brackets(d,(135,130,595,595),rgba(c['ink']),accent)
    elif key=='c':
        mark_arc(d,(125,145,600,590),rgba(c['ink']),accent)
    else:
        mark_stack(d,(135,135,595,590),rgba('#FFFFFF',230),rgba(c['ink']),accent)
    # wordmark
    x=735
    f_cn=font_cn(180)
    f_cad=font_lat(158)
    f_en=font_lat(66)
    f_tag=font_cn(46)
    d.text((x,95),'速看',font=f_cn,fill=ink,stroke_width=2,stroke_fill=ink)
    tw=d.textlength('速看',font=f_cn)
    d.text((x+tw+18,100),'CAD',font=f_cad,fill=cad,stroke_width=2,stroke_fill=cad)
    d.text((x,365),'CadLens',font=f_en,fill=ink)
    d.text((x,455),'图纸查看 · 现场测量',font=f_tag,fill=muted)
    d.line([(x,565),(x+1320,565)], fill=accent[:3]+(150,), width=3)
    d.text((x,600),'DWG  ·  DXF  ·  PDF',font=font_lat(30),fill=muted)
    return out

for key in CONCEPTS:
    app=make_app_icon(key); app.save(OUT/f'appicon-{key}.png')
    pkg=make_package_icon(key); pkg.save(OUT/f'package-{key}.png')
    logo=make_logo(key, dark=True); logo.save(OUT/f'logo-{key}.png')
    make_logo(key, dark=False).save(OUT/f'logo-{key}-light.png')
    print('wrote',key)

# icns for each
for kind in ('appicon','package'):
    for key in CONCEPTS:
        iconset=OUT/f'{kind}-{key}.iconset'
        if iconset.exists(): shutil.rmtree(iconset)
        iconset.mkdir()
        src=OUT/f'{kind}-{key}.png'
        for sz,name in [(16,'icon_16x16'),(32,'icon_16x16@2x'),(32,'icon_32x32'),(64,'icon_32x32@2x'),(128,'icon_128x128'),(256,'icon_128x128@2x'),(256,'icon_256x256'),(512,'icon_256x256@2x'),(512,'icon_512x512'),(1024,'icon_512x512@2x')]:
            subprocess.run(['sips','-z',str(sz),str(sz),str(src),'--out',str(iconset/f'{name}.png')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(OUT/f'{kind}-{key}.icns')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        shutil.rmtree(iconset)
print('done')
