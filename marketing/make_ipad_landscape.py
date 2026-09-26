"""iPad App Store screenshots, landscape 13" (2752x2064), from photos taken on a 10.2" iPad
(2160x1620, the same 4:3 shape). Status bar cropped off; same style as the other sets."""
from PIL import Image, ImageDraw, ImageFont
W, H = 2752, 2064
BG = (9, 10, 12); FG = (232, 230, 225); MUTED = (139, 142, 150); LINE = (40, 44, 54); RECORD = (196, 84, 74)
AV = "/System/Library/Fonts/Supplemental/Avenir Next.ttc"
names = {i: ImageFont.truetype(AV, 20, index=i).getname()[1] for i in range(12)}
bold = next(i for i, n in names.items() if n == "Bold")
medium = next(i for i, n in names.items() if n == "Medium")
shots = [
    ("IMG_2969.PNG", "Pads and loops, side by side", "Play, record and shape it all on one screen"),
    ("IMG_2970.PNG", "Mix it, then bounce the session", "Levels, a limiter light and one-tap session recording"),
    ("IMG_2972.PNG", "Arrange your song", "Blocks, repeats and a playhead across the timeline"),
    ("IMG_2968.PNG", "Start from a groove", "Seven kits, 30 grooves, tape on everything"),
]
for n, (f, title, sub) in enumerate(shots, 1):
    c = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(c)
    d.rounded_rectangle([150, 118, 162, 232], radius=6, fill=RECORD)
    d.text((200, 96), title, font=ImageFont.truetype(AV, 128, index=bold), fill=FG)
    d.text((204, 262), sub, font=ImageFont.truetype(AV, 60, index=medium), fill=MUTED)
    raw = Image.open(f"incoming/{f}").convert("RGB")
    raw = raw.crop((0, 44, raw.width, raw.height))   # status bar (recording dot, battery) off
    sw = 2480; sh = int(raw.height * sw / raw.width)
    raw = raw.resize((sw, sh), Image.LANCZOS)
    top, x0 = 420, (W - sw) // 2
    mask = Image.new("L", (sw, sh), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh + 200], radius=64, fill=255)
    frame = Image.new("RGB", (sw + 8, sh + 8), LINE)
    fm = Image.new("L", (sw + 8, sh + 8), 0); ImageDraw.Draw(fm).rounded_rectangle([0, 0, sw + 7, sh + 300], radius=68, fill=255)
    c.paste(frame, (x0 - 4, top - 4), fm); c.paste(raw, (x0, top), mask)
    out = f"appstore-ipad/L{n:02d}-{f.split('.')[0].lower()}.png"
    c.save(out); print("wrote", out)
