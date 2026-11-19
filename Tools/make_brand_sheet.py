from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'Resources/Brand'
CN=str(ROOT/'Resources/fonts/NotoSansCJKsc-Regular.otf')
LAT=str(ROOT/'Resources/fonts/osifont-lgpl3fe.ttf')
def rgba(h,a=255):
    h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))+(a,)
W,H=2680,1740
im=Image.new('RGBA',(W,H),rgba('#0B0F16')); d=ImageDraw.Draw(im)
# faint grid
for x in range(0,W,80): d.line([(x,0),(x,H)],fill=(255,255,255,8),width=2)
for y in range(0,H,80): d.line([(0,y),(W,y)],fill=(255,255,255,8),width=2)
f_title=ImageFont.truetype(CN,66); f_sub=ImageFont.truetype(CN,28)
f_name=ImageFont.truetype(CN,38); f_en=ImageFont.truetype(LAT,25)
f_tag=ImageFont.truetype(CN,24); f_small=ImageFont.truetype(CN,21)
d.text((70,42),'速看CAD · 发布图标方案',font=f_title,fill=rgba('#F4F8FF'))
d.text((72,152),'4 个方向 · 软件 Logo / macOS 应用图标 / 安装包图标',font=f_sub,fill=rgba('#9FB2C8'))
d.text((W-500,58),'CadLens  © 2026',font=ImageFont.truetype(LAT,22),fill=rgba('#8FA3B8'))

concepts=[('a','蓝图视界','BLUEPRINT'),('b','取景框','FOCUS FRAME'),('c','量角弧','PRECISION ARC'),('d','层叠图纸','SHEET STACK')]
colw=630; x0=60
for i,(key,name,en) in enumerate(concepts):
    x=x0+i*colw
    d.rounded_rectangle([x,210,x+590,1650],radius=28,fill=rgba('#111827'),outline=rgba('#FFFFFF',18),width=2)
    d.text((x+28,238),f'{chr(65+i)}  {name}',font=f_name,fill=rgba('#F4F8FF'))
    d.text((x+30,292),en,font=f_en,fill=rgba('#7C93AA'))
    # app icon
    app=Image.open(OUT/f'appicon-{key}.png').resize((250,250),Image.Resampling.LANCZOS)
    im.alpha_composite(app,(x+170,350)) if False else im.paste(app,(x+170,350),app)
    d.text((x+30,620),'APP ICON',font=f_small,fill=rgba('#7C93AA'))
    # package
    pkg=Image.open(OUT/f'package-{key}.png').resize((250,250),Image.Resampling.LANCZOS)
    im.paste(pkg,(x+170,700),pkg)
    d.text((x+30,970),'PACKAGE',font=f_small,fill=rgba('#7C93AA'))
    # dark logo
    logo=Image.open(OUT/f'logo-{key}.png').resize((530,155),Image.Resampling.LANCZOS)
    im.paste(logo,(x+30,1045),logo)
    d.text((x+30,1215),'LOGO · DARK BG',font=f_small,fill=rgba('#7C93AA'))
    # light logo on light card
    card=(x+24,1250,x+566,1510)
    d.rounded_rectangle(card,radius=18,fill=rgba('#FFFFFF'))
    logo_l=Image.open(OUT/f'logo-{key}-light.png').resize((520,152),Image.Resampling.LANCZOS)
    im.paste(logo_l,(x+35,1272),logo_l)
    d.text((x+30,1530),'LOGO · LIGHT BG',font=f_small,fill=rgba('#7C93AA'))
    d.text((x+30,1580),'深色版用于深色底，-light 用于浅色底',font=f_tag,fill=rgba('#5E7389'))

# footer
d.line([(70,1680),(W-70,1680)],fill=rgba('#FFFFFF',24),width=2)
d.text((70,1698),'文件：Resources/Brand/  ·  appicon-*.icns / package-*.icns / logo-*.png / logo-*-light.png',font=f_small,fill=rgba('#7C93AA'))
im.convert('RGB').save(OUT/'icon-options.png')
print(OUT/'icon-options.png')
